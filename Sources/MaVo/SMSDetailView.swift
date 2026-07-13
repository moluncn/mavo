import SwiftUI

struct SMSDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    let message: SMSMessage
    private let onClose: (() -> Void)?

    init(message: SMSMessage, onClose: (() -> Void)? = nil) {
        self.message = message
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            AdaptiveGlassBackdrop()
                .ignoresSafeArea()

            VStack(spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "message.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(message.sender)
                            .font(.title3.weight(.semibold))
                        Text(fullTimestamp)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .textSelection(.enabled)
                    Spacer()
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let code = message.verificationCode {
                            VerificationCodeBadge(code: code) {
                                appState.markRead(message)
                            }
                        }
                        Text(message.body)
                            .font(.body)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(16)
                }
                .adaptiveGlassSurface(cornerRadius: 16, treatment: .clear)

                HStack(spacing: 10) {
                    Text("\(message.body.count) 个字符")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        appState.showStandaloneSMSComposer(to: message.sender)
                    } label: {
                        Label("回复", systemImage: "arrowshape.turn.up.left")
                    }
                    .adaptiveGlassButton()
                    .disabled(!SMSPDUEncoder.isValidDestination(message.sender))
                    .help(SMSPDUEncoder.isValidDestination(message.sender)
                        ? "回复这条短信"
                        : "该发件人地址不能直接回复")

                    Button {
                        appState.copy(message)
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                    .adaptiveGlassButton()

                    Button("完成") { close() }
                        .adaptiveGlassButton(.prominent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(22)
        }
        .frame(width: 500, height: 500)
        .accessibilityLabel("短信详情，来自 \(message.sender)")
    }

    private var fullTimestamp: String {
        message.timestamp.formatted(
            .dateTime
                .year()
                .month(.wide)
                .day()
                .hour()
                .minute()
                .second()
        )
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
}
