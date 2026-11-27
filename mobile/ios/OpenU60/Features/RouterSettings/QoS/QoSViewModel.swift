import SwiftUI

@Observable
@MainActor
final class QoSViewModel {
    var config: QoSConfig = .empty
    var isLoading: Bool = false
    var message: String?
    var messageIsError: Bool = false

    // Editable limits. Units follow the firmware: 0 = Kbps, 1 = Mbps.
    var editDownloadRate: String = "0"
    var editDownloadUnit: Int = 0
    var editUploadRate: String = "0"
    var editUploadUnit: Int = 0
    var editSmart: Bool = false

    private let client: AgentClient
    private let authManager: AuthManager

    init(client: AgentClient, authManager: AuthManager) {
        self.client = client
        self.authManager = authManager
    }

    func refresh() async {
        isLoading = true
        message = nil

        do {
            let data = try await client.getJSON("/api/router/qos")
            config = QoSParser.parse(data)
            editDownloadRate = String(config.downloadRate)
            editDownloadUnit = config.downloadUnit
            editUploadRate = String(config.uploadRate)
            editUploadUnit = config.uploadUnit
            editSmart = config.smartEnabled
        } catch {
            showMessage("加载 QoS 设置失败：\(error.localizedDescription)", isError: true)
        }

        isLoading = false
    }

    func toggle(enabled: Bool) async {
        isLoading = true
        do {
            let _ = try await client.putJSON("/api/router/qos", body: body(switchOn: enabled))
            showMessage("QoS 已\(enabled ? "启用" : "停用")", isError: false)
            config.enabled = enabled
        } catch {
            showMessage("失败：\(error.localizedDescription)", isError: true)
        }
        isLoading = false
    }

    func apply() async {
        isLoading = true
        do {
            let _ = try await client.putJSON("/api/router/qos", body: body(switchOn: true))
            showMessage("限速设置已应用", isError: false)
            config.downloadRate = Int(editDownloadRate) ?? 0
            config.downloadUnit = editDownloadUnit
            config.uploadRate = Int(editUploadRate) ?? 0
            config.uploadUnit = editUploadUnit
            config.smartEnabled = editSmart
        } catch {
            showMessage("失败：\(error.localizedDescription)", isError: true)
        }
        isLoading = false
    }

    /// The firmware replaces the whole record, so every field is sent each time.
    private func body(switchOn: Bool) -> [String: Any] {
        [
            "qos_switch": switchOn ? "1" : "0",
            "qos_smart_switch": editSmart ? 1 : 0,
            "qos_smart_pri_type": config.smartPriType,
            "download_total_limit_rate": Int(editDownloadRate) ?? 0,
            "download_total_limit_unit": editDownloadUnit,
            "upload_total_limit_rate": Int(editUploadRate) ?? 0,
            "upload_total_limit_unit": editUploadUnit,
        ]
    }

    private func showMessage(_ text: String, isError: Bool) {
        message = text
        messageIsError = isError
    }
}
