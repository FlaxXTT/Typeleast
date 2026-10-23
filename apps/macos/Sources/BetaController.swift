import Foundation

struct BetaPending {
    let sessionId: String
    let info: BetaInfo
    let llm: LLMRoute?
    let language: String
    let variants: String?
    let appBundleId: String
    let field: FocusedField?
}

/// Owns the clarification session and presentation. It does not record, paste, or own the app.
final class BetaController {
    struct Host {
        let show: (BetaInfo, String) -> Void
        let hide: () -> Void
        let busy: (String?) -> Void
        let cancel: (BetaPending) -> Void
    }
    private let host: Host
    private(set) var pending: BetaPending?
    init(host: Host) { self.host = host }

    func accept(info: BetaInfo, sessionId: String, llm: LLMRoute?, language: String,
                variants: String?, appBundleId: String, field: FocusedField?) {
        let old = pending
        pending = BetaPending(sessionId: sessionId, info: info, llm: old?.llm ?? llm,
                              language: old?.language ?? language,
                              variants: old == nil ? variants : old?.variants,
                              appBundleId: old?.appBundleId ?? appBundleId,
                              field: old == nil ? field : old?.field)
    }
    func show(hotkey: String) {
        guard let pending else { return }
        host.show(pending.info, hotkey)
    }
    func setBusy(_ text: String?) { host.busy(text) }
    func hide() { host.hide() }
    func clear() { pending = nil; host.hide() }
    func cancel() {
        guard let old = pending else { return }
        clear() // Clear first: late cancellation cannot target a subsequent conversation.
        host.cancel(old)
    }
}
