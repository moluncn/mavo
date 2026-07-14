import SwiftUI

enum MenuContentPresentation {
    case menuBar
    case window
}

struct MenuContentView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    let presentation: MenuContentPresentation
    @State private var deletionConfirmation = SMSDeletionConfirmationState()
    @State private var dialNumber = ""
    @State private var isDTMFKeypadVisible = false
    @State private var dtmfDigits = ""
    @State private var isComposerPresented = false
    @State private var composerDestination = ""
    @State private var isATConsolePresented = false
    @State private var isSettingsPresented = false
    @State private var isInitialSetupPresented = false
    @State private var isMessageDetailPresented = false
    @State private var selectedMessage: SMSMessage?
    @FocusState private var deletionCancelFocused: Bool
    @FocusState private var dtmfKeypadFocused: Bool

    init(presentation: MenuContentPresentation = .menuBar) {
        self.presentation = presentation
    }

    var body: some View {
        ZStack {
            if presentation == .menuBar {
                // MenuBarExtra already supplies its own system glass panel.
                // Adding another full-window glass layer makes the popover
                // look denser than the standalone window.
                Color.clear
                    .ignoresSafeArea()
            } else {
                AdaptiveGlassBackdrop()
                    .ignoresSafeArea()
            }

            content
                .disabled(deletionConfirmation.isPresented)
                .allowsHitTesting(!deletionConfirmation.isPresented)
                .accessibilityHidden(deletionConfirmation.isPresented)

            if deletionConfirmation.isPresented {
                Color.black.opacity(0.11)
                    .contentShape(Rectangle())
                    .onTapGesture { }
                    .accessibilityHidden(true)
                    .zIndex(1)
                if let pendingDeletion = deletionConfirmation.resolve(in: appState.messages) {
                    deletionConfirmation(for: pendingDeletion)
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                        .zIndex(2)
                }
            }
        }
        .frame(
            minWidth: presentation == .window ? 520 : 430,
            maxWidth: presentation == .window ? .infinity : 430,
            minHeight: presentation == .window ? 680 : 740,
            maxHeight: presentation == .window ? .infinity : 740
        )
        .animation(.easeInOut(duration: 0.15), value: deletionConfirmation.isPresented)
        .onChange(of: appState.call.phase) { _, phase in
            if phase != .active {
                isDTMFKeypadVisible = false
                dtmfDigits = ""
                dtmfKeypadFocused = false
            }
        }
        .onChange(of: appState.initialSetupRequestSerial) { _, _ in
            if presentation == .window {
                isInitialSetupPresented = true
            }
        }
        .onChange(of: appState.initialSetupCompletionSerial) { _, _ in
            if presentation == .window {
                isInitialSetupPresented = false
            }
        }
        .onChange(of: appState.messageDetailRequestSerial) { _, _ in
            guard presentation == .window,
                  let messageID = appState.requestedMessageDetailID,
                  let message = appState.messages.first(where: { $0.id == messageID }) else {
                return
            }
            selectedMessage = message
            isMessageDetailPresented = true
        }
        .onChange(of: deletionConfirmation.isPresented) { _, isPresented in
            if isPresented {
                DispatchQueue.main.async { deletionCancelFocused = true }
            }
        }
        .onChange(of: appState.messages) { _, messages in
            deletionConfirmation.reconcile(with: messages)
        }
        .onExitCommand {
            if deletionConfirmation.isPresented { deletionConfirmation.cancel() }
        }
        .onDisappear {
            deletionConfirmation.cancel()
            appState.dismissTransientMessage()
        }
        .sheet(isPresented: $isComposerPresented, onDismiss: presentedFlowDidDismiss) {
            SMSComposerView(destination: composerDestination)
                .environmentObject(appState)
        }
        .sheet(isPresented: $isATConsolePresented, onDismiss: presentedFlowDidDismiss) {
            ATConsoleView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $isSettingsPresented, onDismiss: presentedFlowDidDismiss) {
            MaVoSettingsView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $isInitialSetupPresented, onDismiss: appState.initialSetupDidDismiss) {
            MaVoInitialSetupView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $isMessageDetailPresented, onDismiss: messageDetailDidDismiss) {
            if let selectedMessage {
                SMSDetailView(message: selectedMessage)
                    .environmentObject(appState)
            }
        }
    }

    private var content: some View {
        AdaptiveGlassContainer(spacing: 14) {
            VStack(spacing: 14) {
                moduleStatusCard
                if let message = appState.transientMessage {
                    notice(message, isError: appState.transientIsError)
                }
                if let error = appState.modem.lastError ?? appState.network.lastError {
                    notice(error, isError: true, dismissible: false)
                }
                networkCard
                callCard
                messageSection
            }
        }
        .padding(16)
    }

    private func deletionConfirmation(for message: SMSMessage) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: 32, height: 32)
                    .background(Color.red.opacity(0.11), in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text("删除这条短信？")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text("删除后这条短信将不再出现在 MaVo 中，此操作无法撤销。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("取消", role: .cancel) {
                    deletionConfirmation.cancel()
                }
                .keyboardShortcut(.cancelAction)
                .focused($deletionCancelFocused)
                .adaptiveGlassButton()
                .frame(minWidth: 72)

                Button("删除", role: .destructive) {
                    confirmDeletion(message)
                }
                .adaptiveGlassButton(.prominent)
                .tint(.red)
                .frame(minWidth: 72)
            }
            .controlSize(.regular)
        }
        .frame(width: 292)
        .adaptiveGlassSurface(
            cornerRadius: 17,
            padding: 18
        )
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("删除短信确认")
    }

    private func confirmDeletion(_ message: SMSMessage) {
        guard let confirmedID = deletionConfirmation.takeConfirmedMessageID(id: message.id),
              let currentMessage = appState.messages.first(where: { $0.id == confirmedID }) else {
            return
        }
        appState.delete(currentMessage)
    }

    private var moduleStatusCard: some View {
        VStack(spacing: 11) {
            HStack(spacing: 12) {
                SignalBarsView(bars: appState.modem.signalBars, active: appState.modem.isConnected)
                    .frame(width: 46, height: 38)
                    .help(appState.modem.signalDetail ?? appState.modem.endpointDescription ?? "暂无信号详情")

                VStack(alignment: .leading, spacing: 3) {
                    Text(appState.modem.operatorName ?? (appState.modem.isConnected ? "等待运营商" : "蜂窝模块"))
                        .font(.headline)
                        .lineLimit(1)
                    Text(signalSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                .layoutPriority(2)

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(statusText)
                        .font(.caption.weight(.semibold))
                }
                .fixedSize()
            }

            HStack(alignment: .center, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: appState.modem.simReady ? "simcard.fill" : "simcard")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 17)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(simStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let simDetailText {
                            Text(simDetailText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
                .layoutPriority(2)

                Spacer(minLength: 6)

                if presentation == .menuBar {
                    ModuleQuickActionButton(
                        title: "打开主窗口",
                        systemImage: "arrow.up.forward.square",
                        accessibilityIdentifier: "OpenMainWindowButton"
                    ) {
                        transitionFromMenuBar {
                            appState.showMainWindow()
                        }
                    }
                }

                ModuleQuickActionButton(
                    title: "AT 控制台",
                    systemImage: "terminal",
                    accessibilityIdentifier: "OpenATConsoleButton"
                ) {
                    presentATConsole()
                }

                ModuleQuickActionButton(
                    title: "刷新状态",
                    systemImage: "arrow.clockwise",
                    accessibilityIdentifier: "RefreshModemButton"
                ) {
                    appState.refresh()
                }

                ModuleQuickActionButton(
                    title: "设置",
                    systemImage: "gearshape",
                    accessibilityIdentifier: "OpenSettingsButton"
                ) {
                    presentSettings()
                }
            }
        }
        .adaptiveGlassCard(treatment: contentGlassTreatment)
    }

    private var simStatusText: String {
        appState.modem.simReady ? "SIM 就绪" : "SIM 未就绪"
    }

    private var simDetailText: String? {
        guard appState.modem.simReady else { return nil }
        if let number = appState.modem.simPhoneNumber {
            return formattedPhoneNumber(number)
        }
        if let iccid = appState.modem.simICCID, iccid.count >= 4 {
            return "卡号尾号 \(iccid.suffix(4))"
        }
        return nil
    }

    private func formattedPhoneNumber(_ number: String) -> String {
        let hasChinaPrefix = number.hasPrefix("+86")
        let localNumber = hasChinaPrefix ? String(number.dropFirst(3)) : number
        guard localNumber.count == 11,
              localNumber.allSatisfy({ $0 >= "0" && $0 <= "9" }) else {
            return number
        }
        let first = localNumber.prefix(3)
        let middle = localNumber.dropFirst(3).prefix(4)
        let last = localNumber.suffix(4)
        return (hasChinaPrefix ? "+86 " : "") + "\(first) \(middle) \(last)"
    }

    private var networkCard: some View {
        VStack(spacing: 12) {
            HStack {
                Label("蜂窝网络", systemImage: "network")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if appState.isChangingNetwork {
                    ProgressView().controlSize(.small)
                } else {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { appState.network.isEnabled },
                            set: { appState.setCellularNetworking($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!canToggleNetwork)
                }
            }

            HStack(spacing: 12) {
                metric(
                    icon: networkConnectionIcon,
                    title: networkConnectionTitle,
                    detail: networkConnectionDetail
                )
                Divider().frame(height: 34)
                metric(
                    icon: appState.network.isPrioritized ? "antenna.radiowaves.left.and.right" : "wifi",
                    title: networkPriorityTitle,
                    detail: networkPriorityDetail
                )
            }

            if appState.network.isEnabled,
               appState.network.isHardwarePresent,
                !appState.network.isPrioritized {
                HStack {
                    Text("蜂窝网络已开启，但 Wi‑Fi 目前仍然优先")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("让蜂窝优先") { appState.setCellularNetworking(true) }
                        .adaptiveGlassButton()
                        .controlSize(.small)
                        .disabled(appState.isChangingNetwork)
                }
            }

            if appState.modem.isConnected, appState.modem.usbNetMode != 1 {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("当前 usbnet=\(appState.modem.usbNetMode.map(String.init) ?? "未知")")
                            .font(.caption.weight(.semibold))
                        Text("macOS 联网需要 CDC‑ECM（usbnet=1）")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("切换为 ECM") { appState.configureECM() }
                        .adaptiveGlassButton()
                        .controlSize(.small)
                        .disabled(appState.isConfiguringECM)
                }
                .padding(10)
                .adaptiveGlassSurface(
                    cornerRadius: 12,
                    treatment: .clear,
                    tint: Color.orange.opacity(0.10)
                )
            }
        }
        .adaptiveGlassCard(treatment: contentGlassTreatment)
    }

    private var callCard: some View {
        VStack(spacing: 10) {
            HStack {
                Label("电话", systemImage: "phone.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if appState.isChangingCall {
                    ProgressView().controlSize(.small)
                } else {
                    Text(callPhaseText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(callPhaseColor)
                }
            }

            switch appState.call.phase {
            case .idle:
                HStack(spacing: 8) {
                    TextField("输入手机号", text: $dialNumber)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { dialIfPossible() }
                    Button {
                        dialIfPossible()
                    } label: {
                        Label("拨打", systemImage: "phone.arrow.up.right.fill")
                    }
                    .adaptiveGlassButton(.prominent)
                    .disabled(dialNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        !appState.call.canDial || appState.isChangingCall)
                }
                if let reason = appState.call.lastEndReason {
                    Text(reason.localizedDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .incoming:
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appState.call.number ?? "未知号码")
                            .font(.headline)
                        Text("蜂窝来电")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("拒接", role: .destructive) { appState.hangUp() }
                        .adaptiveGlassButton()
                        .tint(.red)
                        .disabled(appState.isChangingCall)
                    Button("接听") { appState.answerCall() }
                        .adaptiveGlassButton(.prominent)
                        .tint(.green)
                        .disabled(!appState.call.voiceOverUSBSupported || appState.isChangingCall)
                }
            case .dialing, .alerting:
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appState.call.number ?? "正在拨号")
                            .font(.headline)
                        Text(appState.call.phase == .alerting ? "对方正在响铃" : "正在建立通话")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("挂断", role: .destructive) { appState.hangUp() }
                        .adaptiveGlassButton()
                        .tint(.red)
                        .disabled(appState.isChangingCall)
                }
            case .active:
                VStack(spacing: 14) {
                    VStack(spacing: 3) {
                        Text(appState.call.number ?? "通话中")
                            .font(.title3.weight(.semibold))
                        if let startedAt = appState.call.startedAt {
                            Text(startedAt, style: .timer)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    HStack(spacing: 28) {
                        CallControlButton(
                            title: appState.call.muted ? "取消静音" : "静音",
                            systemImage: appState.call.muted ? "mic.slash.fill" : "mic.fill",
                            isSelected: appState.call.muted
                        ) {
                            appState.setCallMuted(!appState.call.muted)
                        }

                        CallControlButton(
                            title: "拨号盘",
                            systemImage: "circle.grid.3x3.fill",
                            isSelected: isDTMFKeypadVisible
                        ) {
                            let willShow = !isDTMFKeypadVisible
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isDTMFKeypadVisible.toggle()
                            }
                            if willShow {
                                DispatchQueue.main.async { dtmfKeypadFocused = true }
                            } else {
                                dtmfKeypadFocused = false
                            }
                        }

                        CallControlButton(
                            title: "挂断",
                            systemImage: "phone.down.fill",
                            tint: .red,
                            isEnabled: !appState.isChangingCall
                        ) {
                            appState.hangUp()
                        }
                    }

                    if isDTMFKeypadVisible {
                        DTMFReadout(digits: dtmfDigits) {
                            dtmfDigits = ""
                        }
                        DTMFKeypadView(isEnabled: appState.call.canSendDTMF) {
                            sendDTMFTone($0)
                        }
                        .focusable()
                        .focused($dtmfKeypadFocused)
                        .focusEffectDisabled()
                        .onKeyPress(phases: .down) { press in
                            handleDTMFKeyPress(press)
                        }
                        .onAppear {
                            DispatchQueue.main.async { dtmfKeypadFocused = true }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            case .ending, .recovering:
                HStack {
                    ProgressView().controlSize(.small)
                    Text(appState.call.phase == .recovering ? "正在核对通话状态…" : "正在结束通话…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if appState.call.phase == .recovering {
                        Button("重试挂断", role: .destructive) { appState.hangUp() }
                            .adaptiveGlassButton()
                            .tint(.red)
                            .disabled(appState.isChangingCall)
                    }
                }
            case .unavailable, .error:
                HStack(spacing: 8) {
                    Image(systemName: "phone.down.fill")
                        .foregroundStyle(.secondary)
                    Text(appState.call.lastError ?? (appState.modem.isConnected
                        ? "模块未报告 USB 语音能力"
                        : "插入模块后可使用蜂窝电话"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .adaptiveGlassCard(treatment: contentGlassTreatment)
    }

    private var messageSection: some View {
        VStack(spacing: 10) {
            HStack {
                Label("短信", systemImage: "message.fill")
                    .font(.headline)
                if appState.unreadCount > 0 {
                    Text("\(appState.unreadCount)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.blue, in: Capsule())
                }
                Spacer()
                if appState.unreadCount > 0 {
                    Button("全部已读") { appState.markAllRead() }
                        .adaptiveGlassButton()
                        .controlSize(.small)
                        .font(.caption)
                }
                Button {
                    presentSMSComposer()
                } label: {
                    Label("新短信", systemImage: "square.and.pencil")
                }
                .adaptiveGlassButton()
                .controlSize(.small)
                .font(.caption)
                .disabled(!appState.modem.isConnected || appState.call.hasCall)
                .help(appState.call.hasCall ? "通话期间暂不发送短信" : "撰写并发送短信")
                .accessibilityIdentifier("ComposeSMSButton")
            }

            if appState.messages.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text(appState.modem.isConnected ? "模块中暂无短信" : "插入模块后会在后台接收短信")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(appState.messages) { message in
                            messageRow(message)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .adaptiveGlassCard(treatment: contentGlassTreatment)
    }

    private func messageRow(_ message: SMSMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(message.isRead ? Color.clear : Color.blue)
                .frame(width: 7, height: 7)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                Button {
                    presentMessageDetail(message)
                } label: {
                    HStack {
                        Text(message.sender)
                            .font(.subheadline.weight(message.isRead ? .medium : .bold))
                            .lineLimit(1)
                        Spacer()
                        Text(message.timestamp, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())

                if let code = message.verificationCode {
                    VerificationCodeBadge(code: code) {
                        appState.markRead(message)
                    }
                    .fixedSize()
                }

                Button {
                    presentMessageDetail(message)
                } label: {
                    Text(message.preview)
                        .font(.caption)
                        .foregroundStyle(message.isRead ? .secondary : .primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .help("点击正文查看完整短信")

            Menu {
                Button("回复", systemImage: "arrowshape.turn.up.left") {
                    presentSMSComposer(to: message.sender)
                }
                .disabled(!SMSPDUEncoder.isValidDestination(message.sender))
                Button("复制", systemImage: "doc.on.doc") { appState.copy(message) }
                Button("标为已读", systemImage: "envelope.open") { appState.markRead(message) }
                Divider()
                Button("删除", systemImage: "trash", role: .destructive) {
                    DispatchQueue.main.async {
                        deletionConfirmation.request(message)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("短信操作，来自 \(message.sender)")
        }
        .padding(10)
        .background(
            message.isRead ? Color.clear : Color.blue.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private func metric(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(Color.blue)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.medium)).lineLimit(1)
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func notice(_ text: String, isError: Bool = false, dismissible: Bool = true) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            Text(text).lineLimit(2)
            Spacer()
            if dismissible {
                Button {
                    appState.dismissTransientMessage()
                } label: {
                    Image(systemName: "xmark")
                }
                .adaptiveGlassButton()
                .controlSize(.mini)
            }
        }
        .font(.caption)
        .foregroundStyle(isError ? Color.red : Color.primary)
        .padding(9)
        .adaptiveGlassSurface(
            cornerRadius: 12,
            treatment: .clear,
            tint: (isError ? Color.red : Color.green).opacity(0.10)
        )
    }

    private var signalSummary: String {
        let parts = [
            appState.modem.accessTechnology,
            appState.modem.signalDBm.map { "\($0) dBm" }
        ].compactMap { $0 }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        switch appState.modem.state {
        case .connected: return "正在读取信号"
        case .connecting: return "正在初始化模块"
        case .error: return "AT 接口异常"
        case .disconnected: return "等待插入 QDC507"
        }
    }

    private var statusText: String {
        switch appState.modem.state {
        case .connected: return "已连接"
        case .connecting: return "连接中"
        case .error: return "异常"
        case .disconnected: return "未插入"
        }
    }

    private var statusColor: Color {
        switch appState.modem.state {
        case .connected: return .green
        case .connecting: return .orange
        case .error: return .red
        case .disconnected: return .gray
        }
    }

    private var canToggleNetwork: Bool {
        appState.network.isEnabled || (
            appState.modem.isConnected &&
            appState.modem.usbNetMode == 1 &&
            appState.network.isHardwarePresent
        )
    }

    private var networkConnectionIcon: String {
        if !appState.network.isEnabled { return "antenna.radiowaves.left.and.right.slash" }
        if appState.isRecoveringNetworkLink { return "arrow.clockwise.circle.fill" }
        return appState.network.isActive ? "checkmark.circle.fill" : "clock"
    }

    private var networkConnectionTitle: String {
        if !appState.network.isEnabled { return "蜂窝网络未启用" }
        if appState.isRecoveringNetworkLink { return "正在恢复蜂窝数据" }
        return appState.network.isActive ? "蜂窝数据已连接" : "正在连接蜂窝数据"
    }

    private var networkConnectionDetail: String {
        if !appState.network.isEnabled {
            return appState.network.isHardwarePresent ? "模块已就绪" : "等待插入模块"
        }
        if appState.network.isActive {
            return appState.modem.operatorName ?? "正在通过蜂窝网络联网"
        }
        if appState.isRecoveringNetworkLink || !appState.network.isLinkActive {
            return "正在重新连接模块与 Mac"
        }
        return "正在从模块获取网络地址"
    }

    private var networkPriorityTitle: String {
        appState.network.isPrioritized ? "蜂窝网络优先" : "Wi‑Fi 保持优先"
    }

    private var networkPriorityDetail: String {
        if appState.network.isPrioritized {
            return "已排在 Wi‑Fi 之前"
        }
        return appState.network.isEnabled
            ? "可切换为蜂窝优先"
            : "开启后自动切换为蜂窝优先"
    }

    private var contentGlassTreatment: AdaptiveGlassTreatment {
        presentation == .menuBar ? .clear : .regular
    }

    private var callPhaseText: String {
        switch appState.call.phase {
        case .unavailable: return "不可用"
        case .idle: return "可拨号"
        case .incoming: return "来电"
        case .dialing: return "拨号中"
        case .alerting: return "响铃中"
        case .active: return "通话中"
        case .ending: return "结束中"
        case .recovering: return "恢复中"
        case .error: return "异常"
        }
    }

    private var callPhaseColor: Color {
        switch appState.call.phase {
        case .incoming: return .orange
        case .active: return .green
        case .dialing, .alerting, .ending, .recovering: return .blue
        case .error: return .red
        case .unavailable, .idle: return .secondary
        }
    }

    private func dialIfPossible() {
        guard appState.call.canDial, !appState.isChangingCall else { return }
        appState.dial(dialNumber)
    }

    private func presentSMSComposer(to destination: String = "") {
        if presentation == .menuBar {
            transitionFromMenuBar {
                appState.showStandaloneSMSComposer(to: destination)
            }
        } else {
            composerDestination = destination
            isComposerPresented = true
        }
    }

    private func presentATConsole() {
        if presentation == .menuBar {
            transitionFromMenuBar {
                appState.showStandaloneATConsole()
            }
        } else {
            isATConsolePresented = true
        }
    }

    private func presentSettings() {
        if presentation == .menuBar {
            transitionFromMenuBar {
                appState.showStandaloneSettings()
            }
        } else {
            isSettingsPresented = true
        }
    }

    private func presentedFlowDidDismiss() {
        guard presentation == .window else { return }
        appState.presentedFlowDidDismiss()
    }

    private func presentMessageDetail(_ message: SMSMessage) {
        if presentation == .menuBar {
            transitionFromMenuBar {
                appState.showStandaloneMessageDetail(message)
            }
        } else {
            appState.markRead(message)
            selectedMessage = appState.messages.first(where: { $0.id == message.id }) ?? message
            isMessageDetailPresented = true
        }
    }

    private func messageDetailDidDismiss() {
        selectedMessage = nil
        presentedFlowDidDismiss()
    }

    private func transitionFromMenuBar(_ action: @escaping () -> Void) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: action)
    }

    private func sendDTMFTone(_ tone: String) {
        guard appState.call.canSendDTMF else { return }
        dtmfDigits.append(tone)
        if dtmfDigits.count > 48 {
            dtmfDigits.removeFirst(dtmfDigits.count - 48)
        }
        appState.sendDTMF(tone)
    }

    private func handleDTMFKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.intersection([.command, .control, .option]).isEmpty,
              let tone = CallATParser.normalizedDTMFTone(press.characters) else {
            return .ignored
        }
        sendDTMFTone(tone)
        return .handled
    }
}

private struct ModuleQuickActionButton: View {
    let title: String
    let systemImage: String
    let accessibilityIdentifier: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .adaptiveGlassButton()
        .controlSize(.small)
        .foregroundStyle(isHovered ? Color.accentColor : Color.primary)
        .scaleEffect(isHovered ? 1.07 : 1)
        .shadow(color: Color.accentColor.opacity(isHovered ? 0.22 : 0), radius: 7, y: 2)
        .overlay(alignment: .top) {
            if isHovered {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.30), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.14), radius: 7, y: 3)
                    .offset(y: -32)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .zIndex(isHovered ? 10 : 0)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct DTMFReadout: View {
    let digits: String
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(digits.isEmpty ? "点击按键，或直接使用 Mac 键盘" : digits)
                    .font(digits.isEmpty ? .caption : .title3.monospaced().weight(.medium))
                    .foregroundStyle(digits.isEmpty ? Color.secondary : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .defaultScrollAnchor(.trailing)
            .frame(maxWidth: .infinity, minHeight: 26)

            if !digits.isEmpty {
                Button {
                    clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清空按键显示（不会撤回已发送的按键）")
                .accessibilityLabel("清空按键显示")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .adaptiveGlassSurface(cornerRadius: 12, treatment: .clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(digits.isEmpty ? "尚未输入通话按键" : "已输入 \(digits)")
    }
}

private struct DTMFKeypadView: View {
    let isEnabled: Bool
    let send: (String) -> Void

    private let tones: [(tone: String, letters: String)] = [
        ("1", ""), ("2", "ABC"), ("3", "DEF"),
        ("4", "GHI"), ("5", "JKL"), ("6", "MNO"),
        ("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ"),
        ("*", ""), ("0", "+"), ("#", "")
    ]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(tones, id: \.tone) { key in
                Button {
                    send(key.tone)
                } label: {
                    VStack(spacing: 0) {
                        Text(key.tone)
                            .font(.title3.monospaced().weight(.semibold))
                        Text(key.letters.isEmpty ? " " : key.letters)
                            .font(.system(size: 7, weight: .semibold))
                            .tracking(1)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(DTMFKeyButtonStyle())
                .disabled(!isEnabled)
                .accessibilityLabel(accessibilityLabel(for: key.tone))
            }
        }
        .padding(.top, 2)
    }

    private func accessibilityLabel(for tone: String) -> String {
        switch tone {
        case "*": return "星号"
        case "#": return "井号"
        default: return tone
        }
    }
}

private struct DTMFKeyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .adaptiveGlassSurface(
                cornerRadius: 12,
                treatment: .clear,
                tint: configuration.isPressed ? Color.blue.opacity(0.16) : nil,
                isInteractive: true
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        configuration.isPressed ? Color.blue.opacity(0.55) : Color.primary.opacity(0.08),
                        lineWidth: 1
                    )
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private struct CallControlButton: View {
    let title: String
    let systemImage: String
    var tint: Color = .blue
    var isSelected = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                controlIcon
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var controlIcon: some View {
        let icon = Image(systemName: systemImage)
            .font(.system(size: 16, weight: .semibold))
            .frame(width: 38, height: 38)

        if isSelected || tint == .red {
            icon
                .foregroundStyle(Color.white)
                .background(tint, in: Circle())
        } else if #available(macOS 26.0, *) {
            icon
                .foregroundStyle(tint)
                .glassEffect(.clear.tint(tint.opacity(0.10)).interactive(), in: Circle())
        } else {
            icon
                .foregroundStyle(tint)
                .background(tint.opacity(0.13), in: Circle())
        }
    }
}

private struct SignalBarsView: View {
    let bars: Int
    let active: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(1 ... 4, id: \.self) { index in
                Capsule()
                    .fill(index <= bars && active ? Color.blue : Color.secondary.opacity(0.18))
                    .frame(width: 7, height: CGFloat(8 + index * 6))
            }
        }
        .accessibilityLabel("信号 \(bars) 格")
    }
}
