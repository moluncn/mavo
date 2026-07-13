import Foundation

enum VerificationMessageAutoDeletePolicy {
    static let delay: TimeInterval = 30 * 60

    static func deletionDate(for message: SMSMessage, enabled: Bool) -> Date? {
        guard enabled,
              message.isRead,
              message.verificationCode != nil,
              let readAt = message.readAt else {
            return nil
        }
        return readAt.addingTimeInterval(delay)
    }
}
