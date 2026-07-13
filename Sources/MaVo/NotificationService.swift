import AppKit
import Foundation
import UserNotifications

enum AppNotificationAuthorizationStatus: Equatable {
    case unknown
    case notDetermined
    case denied
    case authorized
}

final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    private let center = UNUserNotificationCenter.current()
    private var onAnswerCall: (() -> Void)?
    private var onRejectCall: (() -> Void)?
    private var onOpenCallWindow: (() -> Void)?
    private var onOpenMessage: ((String) -> Void)?

    private override init() {
        super.init()
        center.delegate = self
        registerCategories()
    }

    func configure(
        onAnswerCall: @escaping () -> Void,
        onRejectCall: @escaping () -> Void,
        onOpenCallWindow: @escaping () -> Void,
        onOpenMessage: @escaping (String) -> Void
    ) {
        self.onAnswerCall = onAnswerCall
        self.onRejectCall = onRejectCall
        self.onOpenCallWindow = onOpenCallWindow
        self.onOpenMessage = onOpenMessage
    }

    func authorizationStatus(
        completion: @escaping (AppNotificationAuthorizationStatus) -> Void
    ) {
        center.getNotificationSettings { settings in
            let status = Self.authorizationStatus(from: settings.authorizationStatus)
            DispatchQueue.main.async { completion(status) }
        }
    }

    func requestAuthorization(
        completion: @escaping (AppNotificationAuthorizationStatus, String?) -> Void
    ) {
        center.requestAuthorization(options: [.alert, .badge, .sound]) { [weak self] _, error in
            guard let self else { return }
            self.center.getNotificationSettings { settings in
                let status = Self.authorizationStatus(from: settings.authorizationStatus)
                DispatchQueue.main.async {
                    completion(status, error?.localizedDescription)
                }
            }
        }
    }

    func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=app.mavo.mac"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private static func authorizationStatus(
        from status: UNAuthorizationStatus
    ) -> AppNotificationAuthorizationStatus {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized, .provisional, .ephemeral:
            return .authorized
        @unknown default:
            return .unknown
        }
    }

    func postNewMessage(_ message: SMSMessage) {
        let content = UNMutableNotificationContent()
        content.title = message.sender
        content.subtitle = "收到新短信"
        content.body = message.preview
        content.sound = .default
        content.userInfo = ["messageID": message.id]
        content.categoryIdentifier = AppNotificationIdentifier.messageCategory
        content.threadIdentifier = "app.mavo.messages"
        content.interruptionLevel = .active

        let request = UNNotificationRequest(
            identifier: "sms-\(message.id)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    func postIncomingCall(number: String?) {
        let content = UNMutableNotificationContent()
        content.title = number ?? "未知号码"
        content.subtitle = "蜂窝来电"
        content.body = "可直接接听或拒接，也可以打开 MaVo 查看。"
        content.sound = .default
        content.categoryIdentifier = AppNotificationIdentifier.incomingCallCategory
        content.threadIdentifier = "app.mavo.calls"
        content.interruptionLevel = .timeSensitive
        center.add(UNNotificationRequest(
            identifier: "call-incoming",
            content: content,
            trigger: nil
        ))
    }

    func clearIncomingCall() {
        center.removeDeliveredNotifications(withIdentifiers: ["call-incoming"])
        center.removePendingNotificationRequests(withIdentifiers: ["call-incoming"])
    }

    private func registerCategories() {
        let answer = UNNotificationAction(
            identifier: AppNotificationIdentifier.answerCallAction,
            title: "接听",
            options: [.foreground]
        )
        let reject = UNNotificationAction(
            identifier: AppNotificationIdentifier.rejectCallAction,
            title: "拒接",
            options: [.destructive]
        )
        let incomingCall = UNNotificationCategory(
            identifier: AppNotificationIdentifier.incomingCallCategory,
            actions: [answer, reject],
            intentIdentifiers: [],
            options: []
        )
        let openMessage = UNNotificationAction(
            identifier: AppNotificationIdentifier.openMessageAction,
            title: "查看短信",
            options: [.foreground]
        )
        let message = UNNotificationCategory(
            identifier: AppNotificationIdentifier.messageCategory,
            actions: [openMessage],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([incomingCall, message])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        let route = AppNotificationRouter.route(
            actionIdentifier: response.actionIdentifier,
            categoryIdentifier: content.categoryIdentifier,
            messageID: content.userInfo["messageID"] as? String,
            defaultActionIdentifier: UNNotificationDefaultActionIdentifier,
            dismissActionIdentifier: UNNotificationDismissActionIdentifier
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch route {
            case .answerCall:
                self.onAnswerCall?()
            case .rejectCall:
                self.onRejectCall?()
            case .openCallWindow:
                self.onOpenCallWindow?()
            case let .openMessage(messageID):
                self.onOpenMessage?(messageID)
            case .ignore:
                break
            }
        }
        completionHandler()
    }
}
