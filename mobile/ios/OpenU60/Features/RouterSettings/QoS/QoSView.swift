import SwiftUI

struct QoSView: View {
    @Bindable var viewModel: QoSViewModel

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

            Section("服务质量") {
                Toggle("启用 QoS", isOn: Binding(
                    get: { viewModel.config.enabled },
                    set: { enabled in Task { await viewModel.toggle(enabled: enabled) } }
                ))
                .disabled(viewModel.isLoading)
            }

            if viewModel.config.enabled {
                Section("总带宽限制") {
                    limitRow(title: "下载",
                             rate: $viewModel.editDownloadRate,
                             unit: $viewModel.editDownloadUnit)
                    limitRow(title: "上传",
                             rate: $viewModel.editUploadRate,
                             unit: $viewModel.editUploadUnit)
                    Text("0 表示不限速")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("智能 QoS") {
                    Toggle("启用智能 QoS", isOn: $viewModel.editSmart)
                }

                Section {
                    Button {
                        Task { await viewModel.apply() }
                    } label: {
                        Text("应用限速设置")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(viewModel.isLoading)
                }
            }
        }
        .navigationTitle("QoS")
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

    private func limitRow(title: String, rate: Binding<String>, unit: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                TextField("0", text: rate)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                Picker("", selection: unit) {
                    Text("Kbps").tag(0)
                    Text("Mbps").tag(1)
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }
}
