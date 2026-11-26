import SwiftUI

/// The VPN client screen: the router's WireGuard state, read from `/api/wireguard`.
///
/// The passthrough switch that used to live here is a firewall setting on this
/// firmware, so it now sits in the firewall screen next to DMZ.
@Observable
@MainActor
final class VPNPassthroughViewModel {
    struct Status: Equatable {
        var enabled = false
        var connected = false
        var endpoint = ""
        var address = ""
        var dns = ""
        var handshake: UInt64 = 0
        var rxBytes: UInt64 = 0
        var txBytes: UInt64 = 0
        var profiles: [String] = []

        static let empty = Status()
    }

    var status: Status = .empty
    var isLoading: Bool = false
    var message: String?
    var messageIsError: Bool = false

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
            let data = try await client.getJSON("/api/wireguard")
            status = Status(
                enabled: data["enabled"] as? Bool ?? false,
                connected: data["connected"] as? Bool ?? false,
                endpoint: data["endpoint"] as? String ?? "",
                address: data["address"] as? String ?? "",
                dns: data["dns"] as? String ?? "",
                handshake: (data["latest_handshake"] as? NSNumber)?.uint64Value ?? 0,
                rxBytes: (data["rx_bytes"] as? NSNumber)?.uint64Value ?? 0,
                txBytes: (data["tx_bytes"] as? NSNumber)?.uint64Value ?? 0,
                profiles: (data["profiles"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            )
        } catch {
            showMessage("加载 VPN 状态失败：\(error.localizedDescription)", isError: true)
        }

        isLoading = false
    }

    private func showMessage(_ text: String, isError: Bool) {
        message = text
        messageIsError = isError
    }
}
