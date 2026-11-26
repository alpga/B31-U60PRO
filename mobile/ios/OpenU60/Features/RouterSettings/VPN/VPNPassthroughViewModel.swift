import SwiftUI

@Observable
@MainActor
final class VPNPassthroughViewModel {
    var config: VPNPassthroughConfig = .empty
    var isLoading: Bool = false
    var message: String?
    var messageIsError: Bool = false

    /// This firmware exposes one passthrough flag — SIP ALG — so the screen
    /// drives that single switch instead of three that do not exist.
    var editSipAlg: Bool = false

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
            let data = try await client.getJSON("/api/router/vpn")
            config = VPNPassthroughParser.parse(data)
            editSipAlg = (data["alg_sip_enable"] as? String) == "1"
                || (data["alg_sip_enable"] as? Bool ?? false)
        } catch {
            showMessage("加载 VPN 设置失败：\(error.localizedDescription)", isError: true)
        }

        isLoading = false
    }

    func apply() async {
        isLoading = true

        do {
            let _ = try await client.putJSON("/api/router/vpn", body: [
                "alg_sip_enable": editSipAlg ? "1" : "0"
            ])
            showMessage("VPN 透传设置已更新", isError: false)
            config = VPNPassthroughConfig(l2tp: editSipAlg, pptp: editSipAlg, ipsec: editSipAlg)
        } catch {
            showMessage("失败：\(error.localizedDescription)", isError: true)
        }

        isLoading = false
    }

    private func showMessage(_ text: String, isError: Bool) {
        message = text
        messageIsError = isError
    }
}
