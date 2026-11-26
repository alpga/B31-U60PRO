import SwiftUI

/// WireGuard client status for the router. The agent owns the tunnel; this screen
/// reports what it is doing and lists the profiles it holds.
struct VPNPassthroughView: View {
    @Bindable var viewModel: VPNPassthroughViewModel

    var body: some View {
        List {
            if let msg = viewModel.message {
                Section {
                    Text(msg)
                        .font(.subheadline)
                        .foregroundStyle(viewModel.messageIsError ? .red : .green)
                        .textSelection(.enabled)
                }
            }

            Section("连接状态") {
                row("状态", value: statusText, tint: viewModel.status.connected ? .green : .secondary)
                if !viewModel.status.endpoint.isEmpty {
                    row("服务器", value: viewModel.status.endpoint)
                }
                if !viewModel.status.address.isEmpty {
                    row("地址", value: viewModel.status.address)
                }
                if viewModel.status.handshake > 0 {
                    row("最近握手", value: relative(viewModel.status.handshake))
                }
                if viewModel.status.connected {
                    row("流量", value: "↓ \(bytes(viewModel.status.rxBytes))  ↑ \(bytes(viewModel.status.txBytes))")
                }
            }

            Section("配置") {
                if viewModel.status.profiles.isEmpty {
                    Text("路由器上没有 WireGuard 配置")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.status.profiles, id: \.self) { name in
                        Text(name)
                    }
                }
            }
        }
        .navigationTitle("VPN 客户端")
        .refreshable { await viewModel.refresh() }
        .overlay {
            if viewModel.isLoading {
                ProgressView()
                    .padding()
                    .background(Color(.systemBackground).opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .task { await viewModel.refresh() }
    }

    private var statusText: String {
        if viewModel.status.connected { return "已连接" }
        return viewModel.status.enabled ? "已启用，未连接" : "未启用"
    }

    private func row(_ label: String, value: String, tint: Color = .secondary) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(tint)
                .multilineTextAlignment(.trailing)
        }
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
    }

    private func relative(_ epoch: UInt64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epoch))
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds) 秒前" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        return "\(seconds / 3600) 小时前"
    }
}
