import SwiftUI

struct MaVoSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    private let onClose: (() -> Void)?
    @State private var pendingIncomingCallsEnabled: Bool?
    @State private var isConfirmingVerificationAutoDelete = false

    init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            AdaptiveGlassBackdrop()
                .ignoresSafeArea()

            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "gearshape.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MaVo 设置")
                            .font(.title3.weight(.semibold))
                        Text("蜂窝模块与本机显示偏好")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                ScrollView {
                    VStack(spacing: 14) {
                        VStack(spacing: 12) {
                            HStack(alignment: .center, spacing: 14) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("接收来电")
                                        .font(.headline)
                                    Text(incomingCallDetail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 16)
                                if appState.isChangingIncomingCallSetting {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Toggle("", isOn: incomingCallsBinding)
                                        .labelsHidden()
                                        .toggleStyle(.switch)
                                        .disabled(!canChangeIncomingCalls)
                                }
                            }

                            Divider()

                            HStack(spacing: 8) {
                                Image(systemName: "info.circle.fill")
                                    .foregroundStyle(Color.blue)
                                Text("更改此设置时模块会重启，蜂窝网络将短暂中断。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                        }
                        .adaptiveTranslucentCard()

                        displaySettingsCard
                        notificationSettingsCard
                        verificationAutoDeleteSettingsCard
                        launchAtLoginSettingsCard
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color.clear)

                HStack {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(settingStatusColor)
                            .frame(width: 7, height: 7)
                        Text(settingStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 24) {
                        Button(role: .destructive) {
                            appState.quit()
                        } label: {
                            Label("完全退出", systemImage: "power")
                        }
                        .adaptiveGlassButton()
                        .tint(.red)
                        .help("完全退出 MaVo，并停止后台短信、来电和模块监测")

                        Button("完成") { close() }
                            .adaptiveGlassButton(.prominent)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(22)
        }
        .frame(width: 500, height: 650)
        .onAppear { appState.refreshSystemSettingsStatus() }
        .alert(
            pendingIncomingCallsEnabled == true ? "开启接收来电？" : "关闭接收来电？",
            isPresented: Binding(
                get: { pendingIncomingCallsEnabled != nil },
                set: { if !$0 { pendingIncomingCallsEnabled = nil } }
            )
        ) {
            Button("取消", role: .cancel) {
                pendingIncomingCallsEnabled = nil
            }
            Button(
                pendingIncomingCallsEnabled == true ? "重启并开启" : "重启并关闭",
                role: pendingIncomingCallsEnabled == false ? .destructive : nil
            ) {
                guard let enabled = pendingIncomingCallsEnabled else { return }
                pendingIncomingCallsEnabled = nil
                appState.setIncomingCallsEnabled(enabled)
            }
        } message: {
            Text("MaVo 会先写入并回读 IMS=\(pendingIncomingCallsEnabled == true ? 1 : 0)，校验成功后再重启模块。")
        }
    }

    private var displaySettingsCard: some View {
        VStack(spacing: 12) {
            settingRow(
                title: "未插模块时隐藏菜单栏图标",
                detail: appState.hideMenuBarIconWhenDisconnected
                    ? "模块拔出后自动隐藏，重新插入后恢复"
                    : "模块拔出后仍显示断开状态图标"
            ) {
                Toggle("", isOn: Binding(
                    get: { appState.hideMenuBarIconWhenDisconnected },
                    set: { appState.setHideMenuBarIconWhenDisconnected($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "menubar.rectangle")
                    .foregroundStyle(Color.blue)
                Text("图标隐藏后 MaVo 仍在后台接收热插拔事件；插回模块会自动重新显示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .adaptiveTranslucentCard()
    }

    private var notificationSettingsCard: some View {
        settingRow(title: "系统通知", detail: notificationDetail) {
            if appState.isRequestingNotificationAuthorization {
                ProgressView().controlSize(.small)
            } else {
                switch appState.notificationAuthorizationStatus {
                case .notDetermined, .unknown:
                    Button("允许通知") { appState.requestNotificationAuthorization() }
                        .adaptiveGlassButton()
                        .controlSize(.small)
                case .denied:
                    Button("系统设置") { appState.openNotificationSettings() }
                        .adaptiveGlassButton()
                        .controlSize(.small)
                case .authorized:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .adaptiveTranslucentCard()
    }

    private var verificationAutoDeleteSettingsCard: some View {
        settingRow(
            title: "已读验证码自动删除",
            detail: appState.autoDeleteReadVerificationMessages
                ? "已开启；标记已读 30 分钟后从模块/SIM和本地永久删除"
                : "默认关闭；开启后，已读验证码短信保留 30 分钟"
        ) {
            Toggle("", isOn: Binding(
                get: { appState.autoDeleteReadVerificationMessages },
                set: { enabled in
                    if enabled {
                        isConfirmingVerificationAutoDelete = true
                    } else {
                        appState.setAutoDeleteReadVerificationMessages(false)
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .adaptiveTranslucentCard()
        .alert("开启验证码自动删除？", isPresented: $isConfirmingVerificationAutoDelete) {
            Button("取消", role: .cancel) { }
            Button("开启", role: .destructive) {
                appState.setAutoDeleteReadVerificationMessages(true)
            }
        } message: {
            Text("验证码短信被标记已读 30 分钟后，将从模块/SIM和本地永久删除，无法撤销。")
        }
    }

    private var launchAtLoginSettingsCard: some View {
        VStack(spacing: 10) {
            settingRow(title: "登录时启动", detail: launchAtLoginDetail) {
                if appState.isChangingLaunchAtLogin {
                    ProgressView().controlSize(.small)
                } else {
                    Toggle("", isOn: Binding(
                        get: { appState.launchAtLoginStatus.isRegistered },
                        set: { appState.setLaunchAtLogin($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(appState.launchAtLoginStatus == .unavailable)
                }
            }

            if let error = appState.launchAtLoginError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .adaptiveTranslucentCard()
    }

    private func settingRow<Accessory: View>(
        title: String,
        detail: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            accessory()
        }
    }

    private var notificationDetail: String {
        switch appState.notificationAuthorizationStatus {
        case .unknown: return "正在读取通知权限"
        case .notDetermined: return "允许后可收到来电和新短信提醒"
        case .denied: return "通知已关闭，请在系统设置中允许"
        case .authorized: return "已允许来电和新短信通知"
        }
    }

    private var launchAtLoginDetail: String {
        switch appState.launchAtLoginStatus {
        case .disabled: return "默认关闭；开启后通过当前用户的 LaunchAgent 自动运行"
        case .enabled: return "已开启，将在登录 Mac 时后台运行 MaVo"
        case .unavailable: return "无法访问当前用户的 LaunchAgents 环境"
        }
    }

    private var incomingCallsBinding: Binding<Bool> {
        Binding(
            get: { appState.modem.imsMode.map { $0 != 0 } ?? false },
            set: { pendingIncomingCallsEnabled = $0 }
        )
    }

    private var canChangeIncomingCalls: Bool {
        appState.modem.isConnected &&
            appState.modem.imsMode != nil &&
            !appState.call.hasCall &&
            !appState.isChangingIncomingCallSetting
    }

    private var incomingCallDetail: String {
        guard appState.modem.isConnected else { return "插入模块后可更改" }
        guard let mode = appState.modem.imsMode else { return "正在读取 IMS 状态" }
        return mode == 0 ? "已关闭 · IMS=0" : "已开启 · IMS=\(mode)"
    }

    private var settingStatusText: String {
        if appState.isChangingIncomingCallSetting { return "模块正在应用设置" }
        if appState.call.hasCall { return "通话期间不可更改" }
        if !appState.modem.isConnected { return "模块未连接" }
        guard let mode = appState.modem.imsMode else { return "IMS 状态未知" }
        return mode == 0 ? "当前不接收来电" : "当前接收来电"
    }

    private var settingStatusColor: Color {
        if appState.isChangingIncomingCallSetting { return .orange }
        guard appState.modem.isConnected, let mode = appState.modem.imsMode else { return .gray }
        return mode == 0 ? .gray : .green
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
}
