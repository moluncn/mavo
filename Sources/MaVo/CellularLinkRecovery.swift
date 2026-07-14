import Foundation

enum CellularLinkRecoveryPolicy {
    static let maximumAttempts = 3

    static func shouldAttempt(
        network: CellularNetworkStatus,
        modem: ModemSnapshot,
        hasCall: Bool,
        isInFlight: Bool,
        completedAttempts: Int
    ) -> Bool {
        network.isEnabled &&
            network.isHardwarePresent &&
            !network.isActive &&
            modem.isConnected &&
            modem.usbNetMode == 1 &&
            !hasCall &&
            !isInFlight &&
            completedAttempts < maximumAttempts
    }

    static func delayNanoseconds(completedAttempts: Int) -> UInt64 {
        switch completedAttempts {
        case ...0: return 3_000_000_000
        case 1: return 15_000_000_000
        default: return 30_000_000_000
        }
    }
}

