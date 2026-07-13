import AppKit
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var modem = ModemSnapshot()
    @Published private(set) var network = CellularNetworkStatus()
    @Published private(set) var messages: [SMSMessage] = []
    @Published private(set) var call = CallSnapshot()
    @Published var isChangingNetwork = false
    @Published var isConfiguringECM = false
    @Published var isConvertingModuleIdentity = false
    @Published var isChangingCall = false
    @Published var isChangingIncomingCallSetting = false
    @Published var isSendingMessage = false
    @Published var isExecutingAT = false
    @Published private(set) var transientMessage: String?
    @Published private(set) var transientIsError = false
    @Published private(set) var initialSetupRequestSerial = 0
    @Published private(set) var initialSetupCompletionSerial = 0
    @Published private(set) var messageDetailRequestSerial = 0
    @Published private(set) var requestedMessageDetailID: SMSMessage.ID?
    @Published private(set) var hideMenuBarIconWhenDisconnected: Bool
    @Published private(set) var autoDeleteReadVerificationMessages: Bool
    @Published private(set) var isMenuBarExtraInserted: Bool
    @Published private(set) var notificationAuthorizationStatus: AppNotificationAuthorizationStatus = .unknown
    @Published private(set) var isRequestingNotificationAuthorization = false
    @Published private(set) var launchAtLoginStatus: LaunchAtLoginStatus
    @Published private(set) var isChangingLaunchAtLogin = false
    @Published private(set) var launchAtLoginError: String?

    private let modemService = ModemService()
    private let networkController = NetworkServiceController()
    private let messageStore = MessageStore()
    private let launchAtLoginController = LaunchAtLoginController()
    private var started = false
    private var deletingMessageIDs: Set<SMSMessage.ID> = []
    private var verificationAutoDeleteTask: Task<Void, Never>?
    private var verificationAutoDeleteRetryDates: [SMSMessage.ID: Date] = [:]
    private var transientDismissalTask: Task<Void, Never>?
    private var initialSetupPromptTask: Task<Void, Never>?
    private var initialSetupWasPresentedForCurrentInsertion = false
    private var initialSetupPresentationIsActive = false
    private static let initialSetupCompletedKey = "MaVoInitialSetupCompleted.v1"
    private static let networkServiceRecordKey = "MaVo.modemNetworkServiceRecord"
    private static let hideDisconnectedMenuBarIconKey = "HideMenuBarIconWhenDisconnected.v1"
    private static let autoDeleteReadVerificationMessagesKey =
        "AutoDeleteReadVerificationMessages.v1"

    init() {
        let shouldHide = UserDefaults.standard.bool(forKey: Self.hideDisconnectedMenuBarIconKey)
        hideMenuBarIconWhenDisconnected = shouldHide
        autoDeleteReadVerificationMessages = UserDefaults.standard.bool(
            forKey: Self.autoDeleteReadVerificationMessagesKey
        )
        isMenuBarExtraInserted = !shouldHide
        launchAtLoginStatus = launchAtLoginController.status
    }

    var unreadCount: Int {
        messages.lazy.filter { !$0.isRead }.count
    }

    func start() {
        guard !started else { return }
        started = true
        MainWindowController.shared.configure(appState: self)
        StandaloneFlowWindowController.shared.configure(appState: self)
        AppTerminationCoordinator.shared.cleanup = { [weak self] completion in
            guard let self else {
                completion(true)
                return
            }
            self.modemService.shutdown(completion: completion)
        }
        messages = messageStore.messages
        if autoDeleteReadVerificationMessages {
            messageStore.fillMissingVerificationReadDates()
            messages = messageStore.messages
            scheduleVerificationAutoDelete()
        }
        if !hasCompletedInitialSetup,
           !messages.isEmpty || UserDefaults.standard.data(forKey: Self.networkServiceRecordKey) != nil {
            recordInitialSetupSuccess()
        }
        NotificationService.shared.configure(
            onAnswerCall: { [weak self] in
                guard let self, self.call.phase == .incoming else { return }
                self.showMainWindow()
                self.answerCall()
            },
            onRejectCall: { [weak self] in
                guard let self, self.call.phase == .incoming else { return }
                self.hangUp()
            },
            onOpenCallWindow: { [weak self] in
                self?.showMainWindow()
            },
            onOpenMessage: { [weak self] messageID in
                guard let self else { return }
                if let message = self.messages.first(where: { $0.id == messageID }) {
                    self.showMainWindowAndMessageDetail(message)
                } else {
                    self.showMainWindow()
                }
            }
        )
        requestNotificationAuthorization()

        modemService.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            let previousSnapshot = self.modem
            let wasPhysicallyPresent = self.modem.state != .disconnected
            let wasDisconnected = self.modem.state == .disconnected
            self.modem = snapshot
            if snapshot.state == .disconnected, wasPhysicallyPresent {
                self.initialSetupWasPresentedForCurrentInsertion = false
            } else if wasDisconnected,
                      snapshot.state != .disconnected,
                      !self.initialSetupPresentationIsActive {
                self.initialSetupWasPresentedForCurrentInsertion = false
            }
            self.updateMenuBarIconVisibility()
            self.handleInitialSetupSnapshot(snapshot)
            if !snapshot.isConnected {
                self.messageStore.invalidateModemReferences()
                self.messages = self.messageStore.messages
            }
            if previousSnapshot.state != snapshot.state ||
                previousSnapshot.usbNetMode != snapshot.usbNetMode ||
                previousSnapshot.usbIdentity != snapshot.usbIdentity {
                self.networkController.refresh()
            }
        }
        modemService.onMessages = { [weak self] incoming, isInitialSync in
            guard let self else { return }
            let newMessages = self.messageStore.merge(incoming)
            if self.autoDeleteReadVerificationMessages {
                self.messageStore.fillMissingVerificationReadDates()
            }
            let updatedMessages = self.messageStore.messages
            if self.messages != updatedMessages {
                self.messages = updatedMessages
                self.scheduleVerificationAutoDelete()
            }
            if !isInitialSync {
                for message in newMessages {
                    NotificationService.shared.postNewMessage(message)
                }
            }
        }
        modemService.onCallSnapshot = { [weak self] snapshot in
            guard let self else { return }
            let shouldNotify = snapshot.phase == .incoming &&
                (self.call.phase != .incoming || self.call.number != snapshot.number)
            self.call = snapshot
            if snapshot.phase == .incoming {
                IncomingCallWindowController.shared.show(
                    number: snapshot.number,
                    canAnswer: snapshot.voiceOverUSBSupported,
                    onAnswer: { [weak self] in
                        guard let self, self.call.phase == .incoming else { return }
                        self.showMainWindow()
                        self.answerCall()
                    },
                    onReject: { [weak self] in
                        guard let self, self.call.phase == .incoming else { return }
                        self.hangUp()
                    }
                )
                if shouldNotify {
                    NotificationService.shared.postIncomingCall(number: snapshot.number)
                }
            } else {
                IncomingCallWindowController.shared.dismiss()
                NotificationService.shared.clearIncomingCall()
            }
        }
        networkController.onStatus = { [weak self] status in
            self?.network = status
        }

        networkController.startMonitoring()
        modemService.start()

        scheduleInitialSetupPromptIfNeeded()
    }

    func refresh() {
        modemService.refresh()
        networkController.refresh()
    }

    func setCellularNetworking(_ enabled: Bool) {
        guard !isChangingNetwork else { return }
        if enabled && (!modem.isConnected || modem.usbNetMode != 1 || !network.isHardwarePresent) {
            presentTransientMessage("ECM 接口尚未就绪，不能启用蜂窝网络。", isError: true)
            return
        }
        isChangingNetwork = true
        dismissTransientMessage()
        networkController.setEnabled(enabled) { [weak self] result in
            guard let self else { return }
            self.isChangingNetwork = false
            self.show(result)
        }
    }

    func configureECM() {
        guard !isConfiguringECM else { return }
        isConfiguringECM = true
        dismissTransientMessage()
        modemService.configureECM { [weak self] result in
            guard let self else { return }
            self.isConfiguringECM = false
            self.show(result)
        }
    }

    func convertDJIModuleIdentity() {
        guard !isConvertingModuleIdentity else { return }
        isConvertingModuleIdentity = true
        dismissTransientMessage()
        modemService.convertDJIModuleIdentity { [weak self] result in
            guard let self else { return }
            self.isConvertingModuleIdentity = false
            self.show(result)
        }
    }

    func setHideMenuBarIconWhenDisconnected(_ enabled: Bool) {
        guard hideMenuBarIconWhenDisconnected != enabled else { return }
        hideMenuBarIconWhenDisconnected = enabled
        UserDefaults.standard.set(enabled, forKey: Self.hideDisconnectedMenuBarIconKey)
        updateMenuBarIconVisibility()
    }

    func setAutoDeleteReadVerificationMessages(_ enabled: Bool) {
        guard autoDeleteReadVerificationMessages != enabled else { return }
        autoDeleteReadVerificationMessages = enabled
        UserDefaults.standard.set(enabled, forKey: Self.autoDeleteReadVerificationMessagesKey)
        verificationAutoDeleteRetryDates.removeAll()
        if enabled {
            messageStore.resetVerificationReadDates()
            messages = messageStore.messages
        }
        scheduleVerificationAutoDelete()
    }

    func setMenuBarExtraInsertedFromSystem(_ inserted: Bool) {
        guard isMenuBarExtraInserted != inserted else { return }
        isMenuBarExtraInserted = inserted
    }

    func refreshSystemSettingsStatus() {
        launchAtLoginStatus = launchAtLoginController.status
        NotificationService.shared.authorizationStatus { [weak self] status in
            self?.notificationAuthorizationStatus = status
        }
    }

    func requestNotificationAuthorization() {
        guard !isRequestingNotificationAuthorization else { return }
        isRequestingNotificationAuthorization = true
        NotificationService.shared.requestAuthorization { [weak self] status, error in
            guard let self else { return }
            self.isRequestingNotificationAuthorization = false
            self.notificationAuthorizationStatus = status
            if let error {
                self.presentTransientMessage(error, isError: true)
            }
        }
    }

    func openNotificationSettings() {
        NotificationService.shared.openSystemSettings()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard !isChangingLaunchAtLogin else { return }
        isChangingLaunchAtLogin = true
        launchAtLoginError = nil
        do {
            try launchAtLoginController.setEnabled(enabled)
            launchAtLoginStatus = launchAtLoginController.status
        } catch {
            launchAtLoginStatus = launchAtLoginController.status
            launchAtLoginError = error.localizedDescription
        }
        isChangingLaunchAtLogin = false
    }

    func setIncomingCallsEnabled(_ enabled: Bool) {
        guard !isChangingIncomingCallSetting else { return }
        isChangingIncomingCallSetting = true
        dismissTransientMessage()
        modemService.setIncomingCallsEnabled(enabled) { [weak self] result in
            guard let self else { return }
            self.isChangingIncomingCallSetting = false
            self.show(result)
        }
    }

    func dial(_ number: String) {
        guard !isChangingCall else { return }
        isChangingCall = true
        dismissTransientMessage()
        modemService.dial(number) { [weak self] result in
            guard let self else { return }
            self.isChangingCall = false
            self.show(result)
        }
    }

    func answerCall() {
        guard !isChangingCall else { return }
        IncomingCallWindowController.shared.dismiss()
        isChangingCall = true
        modemService.answerCall { [weak self] result in
            guard let self else { return }
            self.isChangingCall = false
            self.show(result)
        }
    }

    func hangUp() {
        guard !isChangingCall else { return }
        if call.phase == .incoming {
            IncomingCallWindowController.shared.dismiss()
        }
        isChangingCall = true
        modemService.hangUp { [weak self] result in
            guard let self else { return }
            self.isChangingCall = false
            self.show(result)
        }
    }

    func setCallMuted(_ muted: Bool) {
        modemService.setCallMuted(muted)
    }

    func sendDTMF(_ tone: String) {
        modemService.sendDTMF(tone) { [weak self] result in
            self?.show(result)
        }
    }

    func executeAT(
        _ command: String,
        completion: @escaping (ATConsoleExecutionResult) -> Void
    ) {
        guard !isExecutingAT else { return }
        isExecutingAT = true
        modemService.executeAT(command) { [weak self] result in
            guard let self else { return }
            self.isExecutingAT = false
            completion(result)
        }
    }

    func sendSMS(
        to destination: String,
        body: String,
        completion: @escaping (ModemActionResult) -> Void
    ) {
        guard !isSendingMessage else { return }
        isSendingMessage = true
        dismissTransientMessage()
        modemService.sendMessage(to: destination, body: body) { [weak self] result in
            guard let self else { return }
            self.isSendingMessage = false
            self.show(result)
            completion(result)
        }
    }

    func showMainWindow() {
        MainWindowController.shared.show()
    }

    func showStandaloneSMSComposer(to destination: String = "") {
        StandaloneFlowWindowController.shared.showSMSComposer(to: destination)
    }

    func showStandaloneATConsole() {
        StandaloneFlowWindowController.shared.showATConsole()
    }

    func showStandaloneSettings() {
        StandaloneFlowWindowController.shared.showSettings()
    }

    func showStandaloneMessageDetail(_ message: SMSMessage) {
        markRead(message)
        StandaloneFlowWindowController.shared.showMessageDetail(message)
    }

    func showMainWindowAndInitialSetup() {
        MainWindowController.shared.show()
        initialSetupRequestSerial &+= 1
    }

    func showMainWindowAndMessageDetail(_ message: SMSMessage) {
        markRead(message)
        requestedMessageDetailID = message.id
        MainWindowController.shared.showForPresentedFlow()
        messageDetailRequestSerial &+= 1
    }

    func completeInitialSetup() {
        recordInitialSetupSuccess()
    }

    func initialSetupDidDismiss() {
        initialSetupPresentationIsActive = false
    }

    func presentedFlowDidDismiss() {
        MainWindowController.shared.presentedFlowDidDismiss()
    }

    func markRead(_ message: SMSMessage) {
        messageStore.markRead(id: message.id)
        messages = messageStore.messages
        scheduleVerificationAutoDelete()
    }

    func markAllRead() {
        messageStore.markAllRead()
        messages = messageStore.messages
        scheduleVerificationAutoDelete()
    }

    func delete(_ message: SMSMessage) {
        delete(message, automatically: false)
    }

    private func delete(_ message: SMSMessage, automatically: Bool) {
        guard let currentMessage = messageStore.messages.first(where: { $0.id == message.id }),
              deletingMessageIDs.insert(currentMessage.id).inserted else {
            return
        }
        let references = currentMessage.effectiveModemReferences
        if !automatically {
            messageStore.remove(id: currentMessage.id)
            messages = messageStore.messages
            verificationAutoDeleteRetryDates.removeValue(forKey: currentMessage.id)
            presentTransientMessage("短信已删除。")
            if references.isEmpty {
                deletingMessageIDs.remove(currentMessage.id)
                DispatchQueue.main.async { [weak self] in self?.scheduleVerificationAutoDelete() }
                return
            }
        }
        if automatically, references.isEmpty {
            messageStore.remove(id: currentMessage.id)
            messages = messageStore.messages
            deletingMessageIDs.remove(currentMessage.id)
            verificationAutoDeleteRetryDates.removeValue(forKey: currentMessage.id)
            DispatchQueue.main.async { [weak self] in self?.scheduleVerificationAutoDelete() }
            return
        }
        modemService.deleteMessage(
            references: references
        ) { [weak self] result in
            guard let self else { return }
            self.deletingMessageIDs.remove(currentMessage.id)
            if automatically, case .success = result {
                self.messageStore.remove(id: currentMessage.id)
                self.messages = self.messageStore.messages
                self.verificationAutoDeleteRetryDates.removeValue(forKey: currentMessage.id)
            } else if automatically, case .failure = result {
                self.verificationAutoDeleteRetryDates[currentMessage.id] =
                    Date().addingTimeInterval(5 * 60)
            }
            if !automatically, case let .failure(message) = result {
                NSLog("MaVo hid a deleted SMS locally but module cleanup failed: %@", message)
            }
            self.scheduleVerificationAutoDelete()
        }
    }

    func copy(_ message: SMSMessage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(message.sender)\n\(message.body)", forType: .string)
        presentTransientMessage("短信已复制。")
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    func dismissTransientMessage() {
        transientDismissalTask?.cancel()
        transientDismissalTask = nil
        transientMessage = nil
        transientIsError = false
    }

    private func show(_ result: ModemActionResult) {
        switch result {
        case let .success(message):
            if let message, !message.isEmpty {
                presentTransientMessage(message)
            } else {
                dismissTransientMessage()
            }
        case let .failure(message):
            presentTransientMessage(message, isError: true)
        }
    }

    private func presentTransientMessage(_ message: String, isError: Bool = false) {
        transientDismissalTask?.cancel()
        transientMessage = message
        transientIsError = isError

        let delay: UInt64 = isError ? 6_000_000_000 : 4_000_000_000
        transientDismissalTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.dismissTransientMessage()
        }
    }

    private func scheduleVerificationAutoDelete(now: Date = Date()) {
        verificationAutoDeleteTask?.cancel()
        verificationAutoDeleteTask = nil
        guard autoDeleteReadVerificationMessages else { return }

        let messageIDs = Set(messageStore.messages.map(\.id))
        verificationAutoDeleteRetryDates = verificationAutoDeleteRetryDates.filter {
            messageIDs.contains($0.key)
        }
        let candidates = messageStore.messages.compactMap { message -> (SMSMessage, Date)? in
            guard !deletingMessageIDs.contains(message.id),
                  let policyDate = VerificationMessageAutoDeletePolicy.deletionDate(
                      for: message,
                      enabled: true
                  ) else {
                return nil
            }
            let deletionDate = max(policyDate, verificationAutoDeleteRetryDates[message.id] ?? policyDate)
            return (message, deletionDate)
        }
        guard let next = candidates.min(by: { $0.1 < $1.1 }) else { return }

        let delay = next.1.timeIntervalSince(now)
        if delay > 0 {
            scheduleVerificationAutoDeleteWake(after: delay)
            return
        }
        if !deletingMessageIDs.isEmpty {
            scheduleVerificationAutoDeleteWake(after: 5)
            return
        }

        let moduleIsBusy = !modem.isConnected ||
            call.hasCall ||
            isChangingCall ||
            isSendingMessage ||
            isExecutingAT ||
            isChangingIncomingCallSetting ||
            isConfiguringECM ||
            isConvertingModuleIdentity
        if moduleIsBusy {
            verificationAutoDeleteRetryDates[next.0.id] = now.addingTimeInterval(60)
            scheduleVerificationAutoDelete(now: now)
            return
        }
        delete(next.0, automatically: true)
    }

    private func scheduleVerificationAutoDeleteWake(after delay: TimeInterval) {
        let boundedDelay = min(max(delay, 0.1), 7 * 24 * 60 * 60)
        verificationAutoDeleteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(boundedDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.scheduleVerificationAutoDelete()
        }
    }

    private func updateMenuBarIconVisibility() {
        let shouldInsert = !hideMenuBarIconWhenDisconnected || modem.state != .disconnected
        guard isMenuBarExtraInserted != shouldInsert else { return }
        isMenuBarExtraInserted = shouldInsert
    }

    private var hasCompletedInitialSetup: Bool {
        UserDefaults.standard.bool(forKey: Self.initialSetupCompletedKey)
    }

    private func handleInitialSetupSnapshot(_ snapshot: ModemSnapshot) {
        switch snapshot.initialSetupState {
        case .ready:
            recordInitialSetupSuccess()
        case .inspecting:
            if !hasCompletedInitialSetup {
                scheduleInitialSetupPromptIfNeeded(afterNanoseconds: 1_500_000_000)
            }
        case .insertModule:
            if !hasCompletedInitialSetup {
                scheduleInitialSetupPromptIfNeeded()
            }
        case .needsIdentityConversion, .needsECM, .unsupportedIdentity,
             .unsupportedUSBConfiguration, .unsupportedUSBNetMode:
            presentInitialSetupIfNeeded(forUninitializedModule: true)
        case .failed:
            if snapshot.usbIdentity != nil {
                presentInitialSetupIfNeeded(forUninitializedModule: true)
            } else if !hasCompletedInitialSetup {
                presentInitialSetupIfNeeded()
            }
        }
    }

    private func scheduleInitialSetupPromptIfNeeded(
        afterNanoseconds delay: UInt64 = 2_500_000_000
    ) {
        guard !hasCompletedInitialSetup,
              !initialSetupWasPresentedForCurrentInsertion,
              initialSetupPromptTask == nil else {
            return
        }
        initialSetupPromptTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            self.initialSetupPromptTask = nil
            guard !self.hasCompletedInitialSetup else { return }
            switch self.modem.initialSetupState {
            case .ready:
                self.recordInitialSetupSuccess()
            case .inspecting:
                self.scheduleInitialSetupPromptIfNeeded(afterNanoseconds: 1_500_000_000)
            case .insertModule, .needsIdentityConversion, .needsECM, .unsupportedIdentity,
                 .unsupportedUSBConfiguration, .unsupportedUSBNetMode, .failed:
                self.presentInitialSetupIfNeeded()
            }
        }
    }

    private func presentInitialSetupIfNeeded(forUninitializedModule: Bool = false) {
        guard (forUninitializedModule || !hasCompletedInitialSetup),
              !initialSetupWasPresentedForCurrentInsertion,
              !initialSetupPresentationIsActive else {
            return
        }
        initialSetupWasPresentedForCurrentInsertion = true
        initialSetupPresentationIsActive = true
        showMainWindowAndInitialSetup()
    }

    private func recordInitialSetupSuccess() {
        if !hasCompletedInitialSetup {
            UserDefaults.standard.set(true, forKey: Self.initialSetupCompletedKey)
        }
        initialSetupPromptTask?.cancel()
        initialSetupPromptTask = nil
        if initialSetupPresentationIsActive {
            initialSetupCompletionSerial &+= 1
        }
    }
}
