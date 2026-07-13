import Foundation
import MaVoNetworkIPC
import Security

enum NetworkHelperInstallationError: LocalizedError {
    case invalidAppLocation
    case missingBundledFile(String)
    case invalidBundledHelper
    case cancelled
    case launchFailed(String)
    case installationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidAppLocation:
            return "MaVo 必须位于“应用程序”文件夹中，才能安全安装网络 helper。"
        case let .missingBundledFile(name):
            return "当前 MaVo 安装包缺少 \(name)，请重新安装最新版。"
        case .invalidBundledHelper:
            return "安装包内的网络 helper 签名校验失败，未请求管理员权限。"
        case .cancelled:
            return "你取消了网络 helper 的首次安装。"
        case let .launchFailed(message):
            return "无法启动 helper 安装程序：\(message)"
        case let .installationFailed(message):
            return "网络 helper 安装失败：\(message)"
        }
    }
}

struct NetworkHelperInstaller {
    private let fileManager = FileManager.default

    func install() -> Result<Void, NetworkHelperInstallationError> {
        guard isRunningFromAllowedAppLocation else {
            return .failure(.invalidAppLocation)
        }

        let helperSource = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/PrivilegedHelperTools")
            .appendingPathComponent(MaVoNetworkIPC.helperExecutableName)
        let plistSource = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons")
            .appendingPathComponent(MaVoNetworkIPC.launchDaemonPlistName)

        guard fileManager.isExecutableFile(atPath: helperSource.path) else {
            return .failure(.missingBundledFile(MaVoNetworkIPC.helperExecutableName))
        }
        guard fileManager.fileExists(atPath: plistSource.path) else {
            return .failure(.missingBundledFile(MaVoNetworkIPC.launchDaemonPlistName))
        }
        guard validateBundledHelper(at: helperSource) else {
            return .failure(.invalidBundledHelper)
        }

        let helperDestination = "/Library/PrivilegedHelperTools/\(MaVoNetworkIPC.helperExecutableName)"
        let plistDestination = "/Library/LaunchDaemons/\(MaVoNetworkIPC.launchDaemonPlistName)"
        let serviceTarget = "system/\(MaVoNetworkIPC.helperLabel)"
        let commands = [
            "set -e",
            "/bin/launchctl bootout \(shellQuote(serviceTarget)) >/dev/null 2>&1 || true",
            "/usr/bin/install -d -o root -g wheel -m 0755 /Library/PrivilegedHelperTools",
            "/usr/bin/install -d -o root -g wheel -m 0755 /Library/LaunchDaemons",
            "/usr/bin/install -o root -g wheel -m 0755 \(shellQuote(helperSource.path)) \(shellQuote(helperDestination))",
            "/usr/bin/install -o root -g wheel -m 0644 \(shellQuote(plistSource.path)) \(shellQuote(plistDestination))",
            "/bin/launchctl bootstrap system \(shellQuote(plistDestination))",
            "/bin/launchctl kickstart -k \(shellQuote(serviceTarget))"
        ]
        let shellCommand = commands.joined(separator: "; ")
        let script = "do shell script \(appleScriptLiteral(shellCommand)) " +
            "with administrator privileges with prompt " +
            appleScriptLiteral("MaVo 需要安装一次网络 helper。以后切换蜂窝网络将不再要求密码。")

        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = Pipe()
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = standardError.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "未知错误"
            if detail.localizedCaseInsensitiveContains("cancel") || detail.contains("-128") {
                return .failure(.cancelled)
            }
            return .failure(.installationFailed(detail.isEmpty ? "未知错误" : detail))
        }
        return .success(())
    }

    private var isRunningFromAllowedAppLocation: Bool {
        let appPath = canonical(Bundle.main.bundleURL.path)
        let allowed = [
            "/Applications/MaVo.app",
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/MaVo.app")
                .path
        ]
        return allowed.contains { canonical($0) == appPath }
    }

    private func validateBundledHelper(at url: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return false
        }
        return SecStaticCodeCheckValidity(staticCode, [], nil) == errSecSuccess
    }

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
