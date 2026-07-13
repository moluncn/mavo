import AppKit
import SwiftUI

struct ATConsoleView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    private let onClose: (() -> Void)?
    @State private var command = "AT"
    @State private var results: [ATConsoleExecutionResult] = []
    @State private var localError: String?
    @FocusState private var commandFocused: Bool

    private let suggestions = [
        "AT", "ATI", "AT+CSQ", "AT+QCSQ", "AT+COPS?", "AT+CPIN?"
    ]

    init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            AdaptiveGlassBackdrop()
                .ignoresSafeArea()

            AdaptiveGlassContainer(spacing: 14) {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    commandArea
                    outputArea
                    footer
                }
            }
            .padding(22)
        }
        .frame(width: 700, height: 560)
        .onAppear { commandFocused = true }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal.fill")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 38, height: 38)
                .adaptiveGlassSurface(cornerRadius: 12, treatment: .clear)
            VStack(alignment: .leading, spacing: 2) {
                Text("AT 控制台")
                    .font(.title2.weight(.semibold))
                Text("通过当前模块的 interface 2 执行单行命令")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(appState.modem.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(appState.modem.isConnected ? "模块已连接" : "模块未连接")
                    .font(.caption.weight(.medium))
            }
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 18, height: 18)
            }
            .adaptiveGlassButton()
            .controlSize(.small)
            .disabled(appState.isExecutingAT)
            .accessibilityLabel("关闭 AT 控制台")
        }
    }

    private var commandArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("例如 AT+QCSQ", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .focused($commandFocused)
                    .onSubmit { execute() }
                Button {
                    execute()
                } label: {
                    if appState.isExecutingAT {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("执行中")
                        }
                    } else {
                        Label("执行", systemImage: "play.fill")
                    }
                }
                .adaptiveGlassButton(.prominent)
                .disabled(!canExecute)
                .keyboardShortcut(.return, modifiers: .command)
            }

            HStack(spacing: 7) {
                Text("常用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(suggestions, id: \.self) { suggestion in
                    Button(suggestion) {
                        command = suggestion
                        localError = nil
                        commandFocused = true
                    }
                    .adaptiveGlassButton()
                    .controlSize(.small)
                    .font(.caption.monospaced())
                }
            }

            if let localError {
                Label(localError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if appState.call.hasCall {
                Label("通话期间暂停手动 AT，避免改变通话和音频状态。", systemImage: "phone.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .adaptiveGlassCard()
    }

    private var outputArea: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("执行记录", systemImage: "text.alignleft")
                    .font(.headline)
                Spacer()
                if !results.isEmpty {
                    Button("清空") { results.removeAll() }
                        .adaptiveGlassButton()
                        .controlSize(.small)
                }
            }

            if results.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("尚未执行命令")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(results) { result in
                            resultRow(result)
                        }
                    }
                }
                .defaultScrollAnchor(.top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .adaptiveGlassCard()
    }

    private func resultRow(_ result: ATConsoleExecutionResult) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("> \(result.command)")
                    .font(.subheadline.monospaced().weight(.semibold))
                    .textSelection(.enabled)
                Spacer()
                Circle()
                    .fill(result.isSuccess ? Color.green : Color.red)
                    .frame(width: 7, height: 7)
                Text(result.isSuccess ? "完成" : "失败")
                    .font(.caption.weight(.medium))
                Text("\(result.elapsedMilliseconds) ms")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    copy(result)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .adaptiveGlassButton()
                .controlSize(.mini)
                .help("复制命令和返回")
            }

            Text(result.output.isEmpty ? "（模块没有返回文本）" : result.output)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(result.isSuccess ? Color.primary : Color.red)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let error = result.error,
               !result.output.localizedCaseInsensitiveContains(error) {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(11)
        .adaptiveGlassSurface(
            cornerRadius: 12,
            treatment: .clear,
            tint: (result.isSuccess ? Color.green : Color.red).opacity(0.045)
        )
    }

    private var footer: some View {
        HStack {
            Label("命令直接作用于模块，不自动重试；不支持需要 > 载荷的数据命令。", systemImage: "exclamationmark.shield")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button("关闭") { close() }
                .adaptiveGlassButton()
                .disabled(appState.isExecutingAT)
        }
    }

    private var canExecute: Bool {
        appState.modem.isConnected &&
            !appState.call.hasCall &&
            !appState.isExecutingAT &&
            !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func execute() {
        localError = nil
        do {
            command = try ATConsoleCommandValidator.validate(command)
        } catch {
            localError = error.localizedDescription
            return
        }
        guard canExecute else { return }
        let submittedCommand = command
        appState.executeAT(submittedCommand) { result in
            results.insert(result, at: 0)
            if results.count > 50 {
                results.removeLast(results.count - 50)
            }
            if !result.isSuccess, result.output.isEmpty {
                localError = result.error
            }
            commandFocused = true
        }
    }

    private func copy(_ result: ATConsoleExecutionResult) {
        let text = [
            "> \(result.command)",
            result.output,
            result.error.map { "错误：\($0)" }
        ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
}
