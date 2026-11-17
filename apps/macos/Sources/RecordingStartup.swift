import Foundation

/// Opens an audio device away from the UI thread. All public methods and the
/// completion run on main; discarded devices close on the same serial worker
/// before another open can begin. Cancellation never adopts a late result.
final class RecordingStartup {
    private let queue = DispatchQueue(label: "com.dsh.voice.recording-start", qos: .userInitiated)
    private var generation: UInt64 = 0
    private(set) var isPending = false

    func begin<Resource>(open: @escaping () throws -> Resource,
                         discard: @escaping (Resource) -> Void,
                         completion: @escaping (Result<Resource, Error>) -> Void) {
        precondition(Thread.isMainThread)
        generation &+= 1
        let token = generation
        isPending = true
        queue.async {
            let result = Result { try open() }
            var accepted = false
            // Never wait for this queue on main. Waiting here instead ensures
            // an abandoned device closes before the next queued open starts.
            DispatchQueue.main.sync {
                guard self.generation == token, self.isPending else { return }
                self.isPending = false
                accepted = true
                completion(result)
            }
            if !accepted, case .success(let resource) = result { discard(resource) }
        }
    }

    func cancel() {
        precondition(Thread.isMainThread)
        generation &+= 1
        isPending = false
    }
}
