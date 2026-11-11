import Foundation

extension AppDelegate {
    func clearSpeechModelStorage(id: String, partialOnly: Bool) {
        guard phase == .idle else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                _ = try self.client.localModelActionSync(path: "storage/delete", body: ["modelId": id, "partialOnly": partialOnly])
                DispatchQueue.main.async { self.refreshHealth() }
            } catch {
                DispatchQueue.main.async { self.setHint(L10n.text("清理失败，请确认没有模型正在使用或下载。"), warning: true); self.refreshHealth() }
            }
        }
    }

    func manageSpeechModel(id: String, download: Bool, cancel: Bool) {
        guard cancel || phase == .idle else { return }
        let mirror = settings.modelMirror
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                try self.client.speechModelActionSync(id: id, download: download, cancel: cancel, endpoint: mirror)
                DispatchQueue.main.async { self.refreshHealth() }
            } catch {
                DispatchQueue.main.async { self.setHint(L10n.text("模型操作失败，请重试。"), warning: true) }
            }
        }
    }
}
