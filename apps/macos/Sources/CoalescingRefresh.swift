import Foundation

/// A result may update a form only if both the request and its inputs still match.
/// The context stays in memory; it must never be persisted or logged.
struct FormRequest<Context: Equatable> {
    private var active: (id: UUID, context: Context)?
    var isActive: Bool { active != nil }

    mutating func begin(context: Context) -> UUID {
        let id = UUID()
        active = (id, context)
        return id
    }

    mutating func invalidate() { active = nil }

    mutating func finish(_ id: UUID, context: Context) -> Bool {
        guard let active, active.id == id else { return false }
        self.active = nil
        return active.context == context
    }
}

/// Main-thread refresh requests share one worker. A burst requests at most one
/// follow-up, using the latest closure. Invalidation discards old service results.
final class CoalescingRefresh<Value> {
    private var running = false
    private var revision: UInt64 = 0
    private var pending: (() -> Void)?

    func invalidate() {
        precondition(Thread.isMainThread)
        revision &+= 1
        pending = nil
    }

    func request(work: @escaping () throws -> Value,
                 completion: @escaping (Result<Value, Error>) -> Void) {
        precondition(Thread.isMainThread)
        guard !running else {
            pending = { [weak self] in self?.request(work: work, completion: completion) }
            return
        }
        running = true
        let token = revision
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try work() }
            DispatchQueue.main.async {
                if self.revision == token { completion(result) }
                self.running = false
                let next = self.pending
                self.pending = nil
                next?()
            }
        }
    }
}
