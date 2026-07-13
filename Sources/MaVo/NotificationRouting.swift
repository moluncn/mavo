import Foundation

enum AppNotificationIdentifier {
    static let incomingCallCategory = "app.mavo.notification.incoming-call"
    static let messageCategory = "app.mavo.notification.message"
    static let answerCallAction = "app.mavo.notification.answer-call"
    static let rejectCallAction = "app.mavo.notification.reject-call"
    static let openMessageAction = "app.mavo.notification.open-message"
}

enum AppNotificationRoute: Equatable {
    case answerCall
    case rejectCall
    case openCallWindow
    case openMessage(String)
    case ignore
}

enum AppNotificationRouter {
    static func route(
        actionIdentifier: String,
        categoryIdentifier: String,
        messageID: String?,
        defaultActionIdentifier: String,
        dismissActionIdentifier: String
    ) -> AppNotificationRoute {
        switch actionIdentifier {
        case AppNotificationIdentifier.answerCallAction:
            return .answerCall
        case AppNotificationIdentifier.rejectCallAction:
            return .rejectCall
        case AppNotificationIdentifier.openMessageAction:
            return messageID.map(AppNotificationRoute.openMessage) ?? .ignore
        case defaultActionIdentifier:
            if categoryIdentifier == AppNotificationIdentifier.incomingCallCategory {
                return .openCallWindow
            }
            if categoryIdentifier == AppNotificationIdentifier.messageCategory, let messageID {
                return .openMessage(messageID)
            }
            return .ignore
        case dismissActionIdentifier:
            return .ignore
        default:
            return .ignore
        }
    }
}
