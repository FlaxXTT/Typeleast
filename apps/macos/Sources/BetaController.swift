import AppKit

struct BetaPending {
    let sessionId: String
    let info: BetaInfo
    let llm: LLMRoute?
    let language: String
    let variants: String?
    let appBundleId: String
    let field: FocusedField?
    /// Started without a text field (the onboarding's sample): the prompt is copied, not pasted.
    var copyResult = false
}

/// Owns the clarification session and presentation. It does not record, paste, or own the app.
final class BetaController {
    struct Host {
        /// The questions, the key that answers them, and the cursor the prompt goes to.
        let show: (BetaInfo, String, NSRect?) -> Void
        let hide: () -> Void
        let busy: (String?) -> Void
        let cancel: (BetaPending) -> Void
    }
    private let host: Host
    private(set) var pending: BetaPending?
    init(host: Host) { self.host = host }

    func accept(info: BetaInfo, sessionId: String, llm: LLMRoute?, language: String,
                variants: String?, appBundleId: String, field: FocusedField?, copyResult: Bool = false) {
        let old = pending
        pending = BetaPending(sessionId: sessionId, info: info, llm: old?.llm ?? llm,
                              language: old?.language ?? language,
                              variants: old == nil ? variants : old?.variants,
                              appBundleId: old?.appBundleId ?? appBundleId,
                              field: old == nil ? field : old?.field,
                              copyResult: old?.copyResult ?? copyResult)
    }
    func show(hotkey: String) {
        guard let pending else { return }
        host.show(pending.info, hotkey, pending.field.flatMap(FieldContextReader.caretRect))
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
