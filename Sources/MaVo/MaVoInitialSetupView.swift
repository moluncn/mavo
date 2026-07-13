import SwiftUI

struct MaVoInitialSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @State private var isInitializationConfirmationPresented = false
    @State private var isIdentityConversionConfirmationPresented = false

    var body: some View {
        ZStack {
            AdaptiveGlassBackdrop()
                .ignoresSafeArea()

            VStack(spacing: 20) {
                VStack(spacing: 9) {
                    Image(systemName: setupIcon)
                        .font(.system(size: 42, weight: .medium))
                        .foregroundStyle(setupColor)
                        .symbolEffect(.pulse, isActive: isBusy)
                    Text(setupTitle)
                        .font(.title2.weight(.semibold))
                    Text(setupDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)

                setupStatusCard

                HStack(spacing: 10) {
                    Button("稍后") { dismiss() }
                        .adaptiveGlassButton()

                    Spacer()

                    if appState.modem.initialSetupState == .needsIdentityConversion {
                        Button {
                            isIdentityConversionConfirmationPresented = true
                        } label: {
                            if appState.isConvertingModuleIdentity {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("一键转换", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                        .adaptiveGlassButton(.prominent)
                        .disabled(appState.isConvertingModuleIdentity || appState.call.hasCall)
                    } else if appState.modem.initialSetupState == .needsECM {
                        Button {
                            isInitializationConfirmationPresented = true
                        } label: {
                            if appState.isConfiguringECM {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("初始化模块", systemImage: "wand.and.stars")
                            }
                        }
                        .adaptiveGlassButton(.prominent)
                        .disabled(appState.isConfiguringECM || appState.call.hasCall)
                    } else if appState.modem.initialSetupState == .ready {
                        Button("开始使用") {
                            appState.completeInitialSetup()
                            dismiss()
                        }
                        .adaptiveGlassButton(.prominent)
                        .keyboardShortcut(.defaultAction)
                    } else if appState.modem.isConnected {
                        Button("重新检测") { appState.refresh() }
                            .adaptiveGlassButton(.prominent)
                            .disabled(isBusy)
                    }
                }
            }
            .padding(26)
        }
        .frame(width: 500, height: 430)
        .interactiveDismissDisabled()
        .alert("初始化并重启模块？", isPresented: $isInitializationConfirmationPresented) {
            Button("取消", role: .cancel) { }
            Button("初始化") { appState.configureECM() }
        } message: {
            Text("MaVo 将把 usbnet 从 0 切换为 1。写入回读成功后模块会重启一次，蜂窝网络将短暂中断。")
        }
        .alert("一键转换 DJI 模块？", isPresented: $isIdentityConversionConfirmationPresented) {
            Button("取消", role: .cancel) { }
            Button("转换并重启", role: .destructive) {
                appState.convertDJIModuleIdentity()
            }
        } message: {
            Text("仅当原值精确匹配 2CA3:4006,1,1,1,1,1,0,0 时执行。MaVo 会转换为 2C7C:0125、开启 CDC‑ECM 与 USB 通话音频，逐项回读成功后才重启模块。")
        }
    }

    @ViewBuilder
    private var setupStatusCard: some View {
        VStack(spacing: 10) {
            setupRow(
                title: "USB 模块",
                value: appState.modem.usbIdentity ?? usbStatusText,
                systemImage: "cable.connector"
            )
            Divider()
            setupRow(
                title: "联网模式",
                value: appState.modem.usbNetMode.map { "usbnet=\($0)" } ?? "等待检测",
                systemImage: "network"
            )
            Divider()
            setupRow(
                title: "设备配置",
                value: usbConfigurationStatusText,
                systemImage: "slider.horizontal.3"
            )
            Divider()
            setupRow(
                title: "SIM 卡",
                value: appState.modem.simReady ? "已就绪" : "尚未就绪",
                systemImage: appState.modem.simReady ? "simcard.fill" : "simcard"
            )
        }
        .adaptiveGlassCard()
    }

    private func setupRow(title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            Text(title)
                .font(.subheadline.weight(.medium))
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var setupTitle: String {
        switch appState.modem.initialSetupState {
        case .insertModule: return "请插入蜂窝模块"
        case .inspecting: return "正在识别模块"
        case .needsIdentityConversion: return "识别到 DJI 原始配置"
        case .needsECM: return "模块尚未初始化"
        case .ready: return "模块已准备好"
        case .unsupportedIdentity: return "识别到不兼容的 USB 身份"
        case .unsupportedUSBConfiguration: return "DJI 配置未通过校验"
        case .unsupportedUSBNetMode: return "联网模式不受支持"
        case .failed: return "模块检测失败"
        }
    }

    private var setupDetail: String {
        switch appState.modem.initialSetupState {
        case .insertModule:
            return "连接 QDC507 后，MaVo 会自动检查 USB 身份、联网模式和 SIM 状态。"
        case .inspecting:
            return "请保持模块连接，检测完成后会自动显示下一步。"
        case .needsIdentityConversion:
            return "已精确确认原值 2CA3:4006,1,1,1,1,1,0,0，可以一键转换为 MaVo 兼容配置。"
        case .needsECM:
            return "已识别 QDC507，但 macOS 联网所需的 CDC‑ECM 尚未开启。"
        case .ready:
            return appState.modem.simReady
                ? "USB 身份和 CDC‑ECM 均已通过检查，可以开始使用。"
                : "USB 身份和 CDC‑ECM 已通过检查；请再确认 SIM 卡已正确插入。"
        case let .unsupportedIdentity(identity):
            return identity == "2CA3:4006"
                ? "识别到 DJI 身份，但无法读取精确 USBCFG，因此不会提供写入。请重新检测。"
                : "当前身份为 \(identity)，MaVo 只处理已验证的 DJI/QDC507 模块。"
        case let .unsupportedUSBConfiguration(configuration):
            return "当前值为 \(configuration)。它不等于已记录的 DJI 原值，MaVo 已拒绝一键转换。"
        case let .unsupportedUSBNetMode(mode):
            return "检测到 usbnet=\(mode)。一键初始化只处理已验证的 usbnet=0 → 1。"
        case let .failed(error):
            return error
        }
    }

    private var setupIcon: String {
        switch appState.modem.initialSetupState {
        case .insertModule: return "cable.connector.slash"
        case .inspecting: return "wave.3.right.circle"
        case .needsIdentityConversion: return "arrow.triangle.2.circlepath.circle.fill"
        case .needsECM: return "wrench.and.screwdriver.fill"
        case .ready: return "checkmark.circle.fill"
        case .unsupportedIdentity, .unsupportedUSBConfiguration, .unsupportedUSBNetMode, .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var setupColor: Color {
        switch appState.modem.initialSetupState {
        case .ready: return .green
        case .needsIdentityConversion, .needsECM: return .orange
        case .unsupportedIdentity, .unsupportedUSBConfiguration, .unsupportedUSBNetMode, .failed: return .red
        case .insertModule, .inspecting: return Color.accentColor
        }
    }

    private var isBusy: Bool {
        appState.modem.initialSetupState == .inspecting ||
            appState.isConfiguringECM || appState.isConvertingModuleIdentity
    }

    private var usbStatusText: String {
        switch appState.modem.state {
        case .disconnected: return "未插入"
        case .connecting: return "连接中"
        case .connected: return "正在读取"
        case .error: return "异常"
        }
    }

    private var usbConfigurationStatusText: String {
        guard let configuration = appState.modem.usbConfiguration else { return "等待检测" }
        if configuration.isSafeDJISource { return "DJI 原值已确认" }
        if configuration.isMaVoTarget { return "MaVo 目标值" }
        return configuration.identity
    }
}
