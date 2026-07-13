import Darwin
import Foundation

@main
struct ADBModuleProbe {
    static func main() {
        do {
            try run()
        } catch {
            fputs("ADB module probe failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let operation = arguments.first else {
            usage()
            exit(64)
        }
        let controller = ADBModuleController(locationID: 0x01100000)
        switch operation {
        case "probe" where arguments.count == 1:
            let runtime = try ModuleVoiceRuntime(locationID: 0x01100000)
            try runtime.probeControlChannel()
            print("QDC507 ADB root control channel is ready.")
        case "prepare" where arguments.count == 1:
            let runtime = try ModuleVoiceRuntime(locationID: 0x01100000)
            let version = try runtime.prepare()
            print("QDC507 voice runtime prepared: \(version)")
        case "start" where arguments.count == 1:
            let runtime = try ModuleVoiceRuntime(locationID: 0x01100000)
            try runtime.startBridge()
            print("QDC507 voice route and PCM bridge are running.")
        case "stop" where arguments.count == 1:
            let runtime = try ModuleVoiceRuntime(locationID: 0x01100000)
            try runtime.stopBridge()
            print("QDC507 voice route and PCM bridge are stopped.")
        case "stop-with-log" where arguments.count == 1:
            let runtime = try ModuleVoiceRuntime(locationID: 0x01100000)
            let output = try runtime.bridgeLog()
            if !output.isEmpty { print(output) }
            try runtime.stopBridge()
            print("QDC507 voice route and PCM bridge are stopped.")
        case "route-start" where arguments.count == 1:
            let runtime = try ModuleVoiceRuntime(locationID: 0x01100000)
            try runtime.startRouteOnly()
            print("QDC507 voice route is running for UAC.")
        case "route-reset-start" where arguments.count == 1:
            let runtime = try ModuleVoiceRuntime(locationID: 0x01100000)
            try runtime.stopBridge()
            try runtime.startRouteOnly()
            print("QDC507 stale bridge was cleared and the UAC route is running.")
        case "route-stop" where arguments.count == 1:
            let runtime = try ModuleVoiceRuntime(locationID: 0x01100000)
            try runtime.stopRouteOnly()
            print("QDC507 voice route is stopped.")
        case "log" where arguments.count == 1:
            let runtime = try ModuleVoiceRuntime(locationID: 0x01100000)
            let output = try runtime.bridgeLog()
            if !output.isEmpty { print(output) }
        case "shell" where arguments.count == 2:
            let result = try controller.shellChecked(arguments[1], timeout: 30)
            if !result.output.isEmpty { print(result.output) }
            print("remote_status=\(result.status)")
            if result.status != 0 { exit(Int32(result.status)) }
        case "push" where arguments.count == 3:
            let localURL = URL(fileURLWithPath: arguments[1])
            let data = try Data(contentsOf: localURL, options: .mappedIfSafe)
            try controller.push(data, to: arguments[2])
            print("pushed_bytes=\(data.count) remote=\(arguments[2])")
        case "pull" where arguments.count == 3:
            let data = try controller.pull(arguments[1])
            let localURL = URL(fileURLWithPath: arguments[2])
            try data.write(to: localURL, options: .atomic)
            print("pulled_bytes=\(data.count) remote=\(arguments[1]) local=\(localURL.path)")
        case "run-with-bridge" where arguments.count >= 3 && arguments[1] == "--":
            try runSupervised(
                mode: .bridge,
                executable: arguments[2],
                arguments: Array(arguments.dropFirst(3))
            )
        case "run-with-route" where arguments.count >= 3 && arguments[1] == "--":
            try runSupervised(
                mode: .route,
                executable: arguments[2],
                arguments: Array(arguments.dropFirst(3))
            )
        default:
            usage()
            exit(64)
        }
    }

    private enum SupervisedMode {
        case bridge
        case route
    }

    private static func runSupervised(
        mode: SupervisedMode,
        executable: String,
        arguments: [String]
    ) throws {
        guard executable.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: executable) else {
            throw ADBModuleController.ControllerError.protocolViolation(
                "监督运行需要绝对路径的可执行子进程。"
            )
        }
        let runtime = try ModuleVoiceRuntime(locationID: 0x01100000)
        switch mode {
        case .bridge:
            try runtime.startBridge()
            print("QDC507 voice route and PCM bridge are running.")
        case .route:
            try runtime.stopBridge()
            try runtime.startRouteOnly()
            print("QDC507 stale bridge was cleared and the UAC route is running.")
        }
        fflush(stdout)

        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.standardInput = FileHandle.standardInput
        child.standardOutput = FileHandle.standardOutput
        child.standardError = FileHandle.standardError

        for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
            signal(signalNumber, SIG_IGN)
        }
        do {
            try child.run()
        } catch {
            try? cleanup(runtime: runtime, mode: mode)
            throw error
        }

        let signalQueue = DispatchQueue(label: "app.mavo.mac.adb-probe.signals")
        let signalLock = NSLock()
        var receivedSignal: Int32 = 0
        let signalSources = [SIGINT, SIGTERM, SIGHUP].map { signalNumber in
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: signalQueue
            )
            source.setEventHandler {
                signalLock.withLock {
                    if receivedSignal == 0 { receivedSignal = signalNumber }
                }
                if child.isRunning {
                    _ = Darwin.kill(child.processIdentifier, signalNumber)
                }
            }
            source.resume()
            return source
        }

        child.waitUntilExit()
        signalSources.forEach { $0.cancel() }
        let forwardedSignal = signalLock.withLock { receivedSignal }
        var cleanupError: Error?
        do {
            try cleanup(runtime: runtime, mode: mode)
        } catch {
            cleanupError = error
            fputs("ADB module cleanup failed: \(error.localizedDescription)\n", stderr)
        }

        if cleanupError != nil { exit(1) }
        if forwardedSignal != 0 { exit(128 + forwardedSignal) }
        if child.terminationReason == .uncaughtSignal {
            exit(128 + child.terminationStatus)
        }
        exit(child.terminationStatus)
    }

    private static func cleanup(
        runtime: ModuleVoiceRuntime,
        mode: SupervisedMode
    ) throws {
        switch mode {
        case .bridge:
            var failures: [String] = []
            do {
                let output = try runtime.bridgeLog()
                if !output.isEmpty { print(output) }
            } catch {
                failures.append("读取 PCM 日志失败：\(error.localizedDescription)")
            }
            do {
                try runtime.stopBridge()
                print("QDC507 voice route and PCM bridge are stopped.")
            } catch {
                failures.append(error.localizedDescription)
            }
            if !failures.isEmpty {
                throw ADBModuleController.ControllerError.remoteFailure(
                    failures.joined(separator: "\n")
                )
            }
        case .route:
            try runtime.stopRouteOnly()
            print("QDC507 voice route is stopped.")
        }
    }

    private static func usage() {
        fputs(
            "Usage: adb_module_probe probe | prepare | start | stop | " +
                "stop-with-log | route-start | route-reset-start | route-stop | log | " +
                "shell COMMAND | push LOCAL REMOTE | pull REMOTE LOCAL | " +
                "run-with-bridge -- EXECUTABLE [ARG ...] | " +
                "run-with-route -- EXECUTABLE [ARG ...]\n",
            stderr
        )
    }
}
