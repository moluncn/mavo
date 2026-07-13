import SwiftUI

struct SMSComposerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    private let onClose: (() -> Void)?
    private let isReply: Bool
    @State private var destination: String
    @State private var messageBody = ""
    @State private var localError: String?
    @FocusState private var destinationFocused: Bool
    @FocusState private var messageFocused: Bool

    init(destination: String = "", onClose: (() -> Void)? = nil) {
        self.onClose = onClose
        isReply = !destination.isEmpty
        _destination = State(initialValue: destination)
    }

    var body: some View {
        ZStack {
            AdaptiveGlassBackdrop()
                .ignoresSafeArea()

            AdaptiveGlassContainer(spacing: 14) {
                composerContent
            }
            .padding(24)
        }
        .frame(width: 520, height: 440)
        .onAppear {
            if isReply {
                messageFocused = true
            } else {
                destinationFocused = true
            }
        }
    }

    private var composerContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isReply ? "回复短信" : "新短信")
                        .font(.title2.weight(.semibold))
                    Text("通过当前 SIM 卡发送")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 18, height: 18)
                }
                .adaptiveGlassButton()
                .controlSize(.small)
                .disabled(appState.isSendingMessage)
                .accessibilityLabel("关闭")
            }

            recipientSection
            messageSection

            if let localError {
                Label(localError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let segmentCount, segmentCount > 1 {
                Label("运营商会按 \(segmentCount) 条长短信分片计费。", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(appState.modem.isConnected ? "模块已连接" : "模块未连接")
                    .font(.caption)
                    .foregroundStyle(appState.modem.isConnected ? Color.secondary : Color.red)
                Spacer()
                Button("取消", role: .cancel) { close() }
                    .adaptiveGlassButton()
                    .disabled(appState.isSendingMessage)
                Button {
                    send()
                } label: {
                    if appState.isSendingMessage {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("发送中")
                        }
                    } else {
                        Label(sendButtonTitle, systemImage: "paperplane.fill")
                    }
                }
                .adaptiveGlassButton(.prominent)
                .disabled(!canSend)
            }
        }
    }

    private var recipientSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("收件人")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("手机号，例如 13800138000", text: $destination)
                .textFieldStyle(.roundedBorder)
                .focused($destinationFocused)
                .disabled(appState.isSendingMessage)
        }
    }

    private var messageSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("内容")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(compositionSummary)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ZStack(alignment: .topLeading) {
                if messageBody.isEmpty {
                    Text("输入短信内容…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $messageBody)
                    .font(.body)
                    .focused($messageFocused)
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .disabled(appState.isSendingMessage)
            }
            .frame(minHeight: 150)
            .adaptiveGlassSurface(cornerRadius: 13, treatment: .clear)
        }
    }

    private var segmentCount: Int? {
        SMSPDUEncoder.segmentCount(destination: destination, body: messageBody)
    }

    private var compositionSummary: String {
        let units = messageBody.utf16.count
        guard let segmentCount else { return "\(units) 个 UCS-2 单元" }
        return "\(units) 个单元 · \(segmentCount) 条"
    }

    private var sendButtonTitle: String {
        guard let segmentCount, segmentCount > 1 else { return "发送" }
        return "发送（\(segmentCount) 条）"
    }

    private var canSend: Bool {
        appState.modem.isConnected &&
            !appState.call.hasCall &&
            !appState.isSendingMessage &&
            segmentCount != nil &&
            !messageBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        localError = nil
        appState.sendSMS(to: destination, body: messageBody) { result in
            switch result {
            case .success:
                close()
            case let .failure(message):
                localError = message
            }
        }
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
}
