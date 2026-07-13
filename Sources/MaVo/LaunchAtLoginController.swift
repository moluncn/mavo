import Foundation

enum LaunchAtLoginStatus: Equatable {
    case disabled
    case enabled
    case unavailable

    var isRegistered: Bool {
        self == .enabled
    }
}

enum LaunchAtLoginControllerError: LocalizedError {
    case unavailable
    case launchctl(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "当前应用位置或用户会话不支持登录启动。"
        case let .launchctl(message):
            return message.isEmpty ? "launchctl 未能更新登录启动服务。" : message
        }
    }
}

struct LaunchAtLoginController {
    static let label = "app.mavo.mac.launch-at-login"

    private let fileManager = FileManager.default

    private var userID: uid_t {
        getuid()
    }

    private var launchAgentsDirectory: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    private var propertyListURL: URL {
        launchAgentsDirectory.appendingPathComponent("\(Self.label).plist")
    }

    private var applicationURL: URL {
        Bundle.main.bundleURL.standardizedFileURL
    }

    private var domainTarget: String {
        "gui/\(userID)"
    }

    private var serviceTarget: String {
        "\(domainTarget)/\(Self.label)"
    }

    var status: LaunchAtLoginStatus {
        guard isAvailable else { return .unavailable }
        guard configurationMatchesCurrentApplication, isLoaded else { return .disabled }
        return .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        guard isAvailable else { throw LaunchAtLoginControllerError.unavailable }
        if enabled {
            guard status != .enabled else { return }
            try installAndBootstrap()
        } else {
            try removeAndBootout()
        }
    }

    static func propertyList(appBundlePath: String) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-g", appBundlePath],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
            "ThrottleInterval": 10,
        ]
    }

    private var isAvailable: Bool {
        applicationURL.pathExtension.lowercased() == "app" &&
            fileManager.isExecutableFile(atPath: "/bin/launchctl") &&
            fileManager.isExecutableFile(atPath: "/usr/bin/open")
    }

    private var configurationMatchesCurrentApplication: Bool {
        guard let data = try? Data(contentsOf: propertyListURL),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let propertyList = object as? [String: Any],
              propertyList["Label"] as? String == Self.label,
              propertyList["ProgramArguments"] as? [String] == [
                  "/usr/bin/open", "-g", applicationURL.path,
              ],
              propertyList["RunAtLoad"] as? Bool == true else {
            return false
        }
        return true
    }

    private var isLoaded: Bool {
        runLaunchctl(["print", serviceTarget]).status == 0
    }

    private func installAndBootstrap() throws {
        if isLoaded {
            let bootout = runLaunchctl(["bootout", serviceTarget])
            guard bootout.status == 0 else {
                throw LaunchAtLoginControllerError.launchctl(bootout.output)
            }
        }

        try fileManager.createDirectory(
            at: launchAgentsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: Self.propertyList(appBundlePath: applicationURL.path),
            format: .xml,
            options: 0
        )
        try data.write(to: propertyListURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: propertyListURL.path)

        _ = runLaunchctl(["enable", serviceTarget])
        let bootstrap = runLaunchctl(["bootstrap", domainTarget, propertyListURL.path])
        guard bootstrap.status == 0, isLoaded else {
            try? fileManager.removeItem(at: propertyListURL)
            throw LaunchAtLoginControllerError.launchctl(bootstrap.output)
        }
    }

    private func removeAndBootout() throws {
        if isLoaded {
            let bootout = runLaunchctl(["bootout", serviceTarget])
            guard bootout.status == 0 else {
                throw LaunchAtLoginControllerError.launchctl(bootout.output)
            }
        }
        if fileManager.fileExists(atPath: propertyListURL.path) {
            try fileManager.removeItem(at: propertyListURL)
        }
        guard !isLoaded else {
            throw LaunchAtLoginControllerError.launchctl("登录启动服务仍处于加载状态。")
        }
    }

    private func runLaunchctl(_ arguments: [String]) -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return CommandResult(status: process.terminationStatus, output: output)
        } catch {
            return CommandResult(status: -1, output: error.localizedDescription)
        }
    }

    private struct CommandResult {
        let status: Int32
        let output: String
    }
}
