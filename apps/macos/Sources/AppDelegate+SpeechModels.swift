import Foundation

extension AppDelegate {
    func manageSpeechModel(id: String, download: Bool, cancel: Bool) {
        guard cancel || phase == .idle else { return }
        let mirror = settings.modelMirror
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                try self.client.speechModelActionSync(id: id, download: download, cancel: cancel, endpoint: mirror)
                DispatchQueue.main.async { self.refreshHealth() }
            } catch {
                DispatchQueue.main.async { self.setHint(L10n.text("模型操作失败，请重试。当前模型保留。"), warning: true) }
            }
        }
    }
}
