import Darwin
import Foundation
import MaVoNetworkIPC
import Security
import SystemConfiguration

private final class NetworkHelperService: NSObject, MaVoNetworkHelperProtocol {
    private let queue = DispatchQueue(label: "app.mavo.mac.network-helper.mutation")
    private let mutator = RootNetworkMutator()

    func ping(reply: @escaping (Int, String) -> Void) {
        reply(MaVoNetworkIPC.protocolVersion, "MaVo Network Helper")
    }

    func setCellularNetworking(
        _ enabled: Bool,
        reply: @escaping (Bool, String) -> Void
    ) {
        queue.async { [mutator] in
            let result = mutator.setCellularNetworking(enabled: enabled)
            reply(result.succeeded, result.message)
        }
    }
}

private final class NetworkHelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = NetworkHelperService()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard ClientValidator.isAllowed(connection) else {
            NSLog("MaVoNetworkHelper rejected XPC client pid=%d uid=%d",
                  connection.processIdentifier,
                  connection.effectiveUserIdentifier)
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: MaVoNetworkHelperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

private enum ClientValidator {
    static func isAllowed(_ connection: NSXPCConnection) -> Bool {
        let pid = connection.processIdentifier
        guard pid > 0,
              let consoleUID = consoleUserID(),
              consoleUID != 0,
              connection.effectiveUserIdentifier == consoleUID,
              let processPath = processExecutablePath(pid: pid),
              isAllowedExecutablePath(processPath, consoleUID: consoleUID),
              hasExpectedSigningIdentifier(pid: pid, executablePath: processPath) else {
            return false
        }
        return true
    }

    private static func consoleUserID() -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?,
              name != "loginwindow",
              !name.isEmpty else {
            return nil
        }
        return uid
    }

    private static func processExecutablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN * 4))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func isAllowedExecutablePath(_ path: String, consoleUID: uid_t) -> Bool {
        guard let passwordEntry = getpwuid(consoleUID),
              let homePointer = passwordEntry.pointee.pw_dir else {
            return false
        }
        let home = String(cString: homePointer)
        let allowedPaths = [
            "/Applications/MaVo.app/Contents/MacOS/MaVo",
            URL(fileURLWithPath: home)
                .appendingPathComponent("Applications/MaVo.app/Contents/MacOS/MaVo")
                .path
        ]
        let canonicalPath = canonical(path)
        return allowedPaths.contains { canonical($0) == canonicalPath }
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private static func hasExpectedSigningIdentifier(
        pid: pid_t,
        executablePath: String
    ) -> Bool {
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else {
            return false
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            "identifier \"app.mavo.mac\"" as CFString,
            [],
            &requirement
        ) == errSecSuccess,
        let requirement,
        SecCodeCheckValidity(code, [], requirement) == errSecSuccess else {
            return false
        }

        var staticCode: SecStaticCode?
        var signedPath: CFURL?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecCodeCopyPath(staticCode, [], &signedPath) == errSecSuccess,
              let signedPath else {
            return false
        }
        let executableURL = URL(fileURLWithPath: executablePath)
        let appBundleURL = executableURL
            .deletingLastPathComponent() // MacOS
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // MaVo.app
        let canonicalSignedPath = canonical((signedPath as URL).path)
        return canonicalSignedPath == canonical(executablePath) ||
            canonicalSignedPath == canonical(appBundleURL.path)
    }
}

guard geteuid() == 0 else {
    NSLog("MaVoNetworkHelper must run as root")
    exit(EXIT_FAILURE)
}

// Ensure state-file and atomic temporary-file creation are root-only by default.
_ = umask(S_IRWXG | S_IRWXO)

private let delegate = NetworkHelperListenerDelegate()
let listener = NSXPCListener(machServiceName: MaVoNetworkIPC.helperLabel)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
