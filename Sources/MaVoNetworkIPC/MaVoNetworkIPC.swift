import Foundation

public enum MaVoNetworkIPC {
    public static let protocolVersion = 4
    public static let helperLabel = "app.mavo.mac.network-helper"
    public static let helperExecutableName = "MaVoNetworkHelper"
    public static let launchDaemonPlistName = "app.mavo.mac.network-helper.plist"
}

@objc(MaVoNetworkHelperProtocol)
public protocol MaVoNetworkHelperProtocol {
    func ping(reply: @escaping (Int, String) -> Void)

    func setCellularNetworking(
        _ enabled: Bool,
        reply: @escaping (Bool, String) -> Void
    )
}
