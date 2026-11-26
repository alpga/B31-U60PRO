import SwiftUI

@Observable
@MainActor
final class LANSettingsViewModel {
    var config: LANConfig = .empty
    var isLoading: Bool = false
    var message: String?
    var messageIsError: Bool = false

    // Editable fields
    var editLanIP: String = ""
    var editNetmask: String = ""
    var editDhcpEnabled: Bool = false
    var editDhcpStart: String = ""
    var editDhcpEnd: String = ""
    var editLeaseTime: String = ""

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
            let data = try await client.getJSON("/api/router/lan")
            config = LANParser.parse(data)
            syncEditFields()
        } catch {
            showMessage("加载 LAN 设置失败：\(error.localizedDescription)", isError: true)
        }

        isLoading = false
    }

    func apply() async {
        guard !editLanIP.isEmpty else {
            showMessage("LAN IP 不能为空", isError: true)
            return
        }

        isLoading = true

        do {
            // The agent takes the firmware's own field names: ipaddr/netmask and a
            // boolean dhcp_enabled, plus the lease in seconds.
            let lease = Int(editLeaseTime) ?? 86400
            let body: [String: Any] = [
                "ipaddr": editLanIP,
                "netmask": editNetmask,
                "dhcp_enabled": editDhcpEnabled,
                "dhcp_start": editDhcpStart,
                "dhcp_end": editDhcpEnd,
                "lease_seconds": lease,
            ]
            let _ = try await client.putJSON("/api/router/lan", body: body)
            showMessage("LAN 设置已更新", isError: false)
            config = LANConfig(lanIP: editLanIP, netmask: editNetmask, dhcpEnabled: editDhcpEnabled,
                               dhcpStart: editDhcpStart, dhcpEnd: editDhcpEnd, dhcpLeaseTime: editLeaseTime)
        } catch {
            showMessage("失败：\(error.localizedDescription)", isError: true)
        }

        isLoading = false
    }

    private func syncEditFields() {
        editLanIP = config.lanIP
        editNetmask = config.netmask
        editDhcpEnabled = config.dhcpEnabled
        editDhcpStart = config.dhcpStart
        editDhcpEnd = config.dhcpEnd
        editLeaseTime = config.dhcpLeaseTime
    }

    private func showMessage(_ text: String, isError: Bool) {
        message = text
        messageIsError = isError
    }
}
