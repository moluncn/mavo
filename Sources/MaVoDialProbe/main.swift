import CModemBridge
import CUACProbe
import Darwin
import Foundation

private let usage = """
Usage:
  MaVoDialProbe --number NUMBER --confirm-live-call [options]

Required:
  --number NUMBER          Dial exactly this voice number (digits, optional leading +).
  --confirm-live-call      Acknowledge that ATD will place a real cellular call.

Options:
  --observe-seconds N      Wait 5...180 seconds for CONNECT/active CLCC (default: 45).
  --media-seconds N        After connection, wait 5...60 seconds for PCM/UAC evidence
                           (default: 15).
  --probe-voice-interface  Open and immediately close USB voice interface 1; no PCM I/O.
  --full-flow              Exercise QPCMV plus USB PCM using silent uplink/discarded downlink.
  --full-flow-after-connect
                           Diagnostic fallback: require active CLCC, then try QPCMV/PCM.
  --qdc-external-pcm-flow  QDC507/external-route mode: require a module-side helper
                           already routing call audio, then use USB interface 1 without
                           sending QPCMV or changing the GPS outport.
  --uac-flow               Require an enumerated modem UAC device, then exercise
                           QPCMV=1,2 and bidirectional CoreAudio IOProc frames.
  --uac-flow-no-qpcmv      Diagnostic for customized firmware: use the verified
                           UAC pair without sending any QPCMV command.
  --uac-device-uid UID     Disambiguate a matched USB audio pair using either member's
                           exact CoreAudio UID; valid only with a UAC flow.
  --log PATH               Mirror the timestamped evidence to PATH.
  --help                   Show this help without opening the modem.

The default network-only mode never enables QPCMV or touches PCM. --full-flow
explicitly runs QPCMV=1,0, voice-interface open, ATD, silent PCM I/O,
ATH/CLCC confirmation, and final QPCMV=0. --full-flow-after-connect instead
runs ATD first and will not enable QPCMV/open interface 1 until an active
outgoing voice call is proved by CLCC. Neither mode uses the Mac microphone or
speaker. --qdc-external-pcm-flow opens interface 1 before dialing, writes silent
uplink, and requires active outgoing CLCC plus a nonzero little-endian PCM16
downlink sample. Its external module-side route remains caller-managed. --uac-flow
zero-fills the selected UAC output (silent uplink), consumes its input, and
requires callbacks plus a nonzero downlink signal after active CLCC. Quectel's
standard PCMV order is --full-flow; after-connect is an explicit diagnostic
experiment for nonstandard firmware. Once ATD may have been sent, all
recoverable exits attempt cleanup.
"""

private enum CLIError: Error, CustomStringConvertible {
    case help
    case invalid(String)

    var description: String {
        switch self {
        case .help: return ""
        case let .invalid(message): return message
        }
    }
}

private struct Options {
    let number: String
    let observeSeconds: Int
    let mediaSeconds: Int
    let probeVoiceInterface: Bool
    let fullFlow: Bool
    let fullFlowAfterConnect: Bool
    let qdcExternalPCMFlow: Bool
    let uacFlow: Bool
    let uacFlowNoQPCMV: Bool
    let uacDeviceUID: String?
    let logPath: String?

    var usesManagedPCMFlow: Bool { fullFlow || fullFlowAfterConnect }
    var usesPCMFlow: Bool { usesManagedPCMFlow || qdcExternalPCMFlow }
    var usesUACFlow: Bool { uacFlow || uacFlowNoQPCMV }
    var usesMediaFlow: Bool { usesPCMFlow || usesUACFlow }

    static func parse(_ arguments: [String]) throws -> Options {
        var number: String?
        var observeSeconds = 45
        var mediaSeconds = 15
        var probeVoiceInterface = false
        var fullFlow = false
        var fullFlowAfterConnect = false
        var qdcExternalPCMFlow = false
        var uacFlow = false
        var uacFlowNoQPCMV = false
        var uacDeviceUID: String?
        var logPath: String?
        var confirmed = false
        var index = 0

        func requireValue(after flag: String) throws -> String {
            guard index + 1 < arguments.count else {
                throw CLIError.invalid("missing value after \(flag)")
            }
            index += 1
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h":
                throw CLIError.help
            case "--number":
                guard number == nil else {
                    throw CLIError.invalid("--number may be supplied only once")
                }
                number = try requireValue(after: argument)
            case "--observe-seconds":
                let value = try requireValue(after: argument)
                guard let parsed = Int(value), (5 ... 180).contains(parsed) else {
                    throw CLIError.invalid("--observe-seconds must be an integer from 5 through 180")
                }
                observeSeconds = parsed
            case "--media-seconds":
                let value = try requireValue(after: argument)
                guard let parsed = Int(value), (5 ... 60).contains(parsed) else {
                    throw CLIError.invalid("--media-seconds must be an integer from 5 through 60")
                }
                mediaSeconds = parsed
            case "--probe-voice-interface":
                guard !probeVoiceInterface else {
                    throw CLIError.invalid("--probe-voice-interface may be supplied only once")
                }
                probeVoiceInterface = true
            case "--full-flow":
                guard !fullFlow else {
                    throw CLIError.invalid("--full-flow may be supplied only once")
                }
                fullFlow = true
            case "--full-flow-after-connect":
                guard !fullFlowAfterConnect else {
                    throw CLIError.invalid("--full-flow-after-connect may be supplied only once")
                }
                fullFlowAfterConnect = true
            case "--qdc-external-pcm-flow":
                guard !qdcExternalPCMFlow else {
                    throw CLIError.invalid("--qdc-external-pcm-flow may be supplied only once")
                }
                qdcExternalPCMFlow = true
            case "--uac-flow":
                guard !uacFlow else {
                    throw CLIError.invalid("--uac-flow may be supplied only once")
                }
                uacFlow = true
            case "--uac-flow-no-qpcmv":
                guard !uacFlowNoQPCMV else {
                    throw CLIError.invalid("--uac-flow-no-qpcmv may be supplied only once")
                }
                uacFlowNoQPCMV = true
            case "--uac-device-uid":
                guard uacDeviceUID == nil else {
                    throw CLIError.invalid("--uac-device-uid may be supplied only once")
                }
                let value = try requireValue(after: argument)
                guard !value.isEmpty, value.utf8.count <= 1_024,
                      !value.contains(where: { $0.isNewline }) else {
                    throw CLIError.invalid("--uac-device-uid must be a nonempty single-line CoreAudio UID")
                }
                uacDeviceUID = value
            case "--log":
                guard logPath == nil else {
                    throw CLIError.invalid("--log may be supplied only once")
                }
                let value = try requireValue(after: argument)
                guard !value.isEmpty else { throw CLIError.invalid("--log path cannot be empty") }
                logPath = value
            case "--confirm-live-call":
                guard !confirmed else {
                    throw CLIError.invalid("--confirm-live-call may be supplied only once")
                }
                confirmed = true
            default:
                throw CLIError.invalid("unknown argument: \(argument)")
            }
            index += 1
        }

        guard let rawNumber = number else {
            throw CLIError.invalid("--number is required; there is no default destination")
        }
        guard confirmed else {
            throw CLIError.invalid("--confirm-live-call is required because this sends a real ATD command")
        }
        guard let normalized = CallProtocol.normalizedDialNumber(rawNumber) else {
            throw CLIError.invalid("invalid --number; use digits with at most one leading +")
        }
        let transportModes = [
            probeVoiceInterface,
            fullFlow,
            fullFlowAfterConnect,
            qdcExternalPCMFlow,
            uacFlow,
            uacFlowNoQPCMV
        ]
            .filter { $0 }
        guard transportModes.count <= 1 else {
            throw CLIError.invalid(
                "choose only one transport mode"
            )
        }
        guard uacDeviceUID == nil || uacFlow || uacFlowNoQPCMV else {
            throw CLIError.invalid("--uac-device-uid is valid only with a UAC flow")
        }
        return Options(
            number: normalized,
            observeSeconds: observeSeconds,
            mediaSeconds: mediaSeconds,
            probeVoiceInterface: probeVoiceInterface,
            fullFlow: fullFlow,
            fullFlowAfterConnect: fullFlowAfterConnect,
            qdcExternalPCMFlow: qdcExternalPCMFlow,
            uacFlow: uacFlow,
            uacFlowNoQPCMV: uacFlowNoQPCMV,
            uacDeviceUID: uacDeviceUID,
            logPath: logPath
        )
    }
}

private final class EvidenceLogger {
    private let lock = NSLock()
    private let mirror: FileHandle?
    private let formatter: ISO8601DateFormatter

    init(logPath: String?) throws {
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let logPath else {
            mirror = nil
            return
        }
        let url = URL(fileURLWithPath: logPath)
        let directory = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CLIError.invalid("log directory does not exist: \(directory.path)")
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CLIError.invalid("could not create log: \(url.path)")
        }
        mirror = try FileHandle(forWritingTo: url)
    }

    deinit {
        try? mirror?.close()
    }

    func event(_ message: String) {
        write("[\(timestamp())] \(message)\n")
    }

    func transmit(_ command: String) {
        event("TX >> \(escapedAT(command + "\r"))")
    }

    func receive(_ source: String, _ text: String) {
        event("RX << [\(source)] \(escapedAT(text))")
    }

    private func timestamp() -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: Date())
    }

    private func write(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        try? FileHandle.standardOutput.write(contentsOf: data)
        try? mirror?.write(contentsOf: data)
        try? mirror?.synchronize()
    }

    private func escapedAT(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0D: result += "\\r"
            case 0x0A: result += "\\n"
            case 0x09: result += "\\t"
            case 0x5C: result += "\\\\"
            case 0x20 ... 0x7E: result.unicodeScalars.append(scalar)
            default:
                result += String(format: "\\u{%04X}", scalar.value)
            }
        }
        return result
    }
}

private final class StopRequest {
    private let lock = NSLock()
    private var requestedSignal: Int32?

    func request(_ signal: Int32) {
        lock.lock()
        if requestedSignal == nil { requestedSignal = signal }
        lock.unlock()
    }

    var signal: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return requestedSignal
    }
}

private struct CLCCCall: Equatable {
    let index: Int
    let direction: Int
    let status: Int
    let mode: Int
    let number: String?

    var isVoice: Bool { mode == 0 }
    var isOutgoing: Bool { direction == 0 }
    var isActive: Bool { status == 0 }
}

// Kept behavior-equivalent to the app's CallATParser without making the UI
// target part of this executable. The USB implementation itself is shared via
// CModemBridge, so the probe exercises the same transport as the production app.
private enum CallProtocol {
    static func normalizedDialNumber(_ value: String) -> String? {
        guard !value.contains(where: { $0.isNewline || ($0.isWhitespace && $0 != " ") }) else {
            return nil
        }
        let compact = value.filter { $0 != " " && !"-()".contains($0) }
        guard !compact.isEmpty, compact.count <= 32 else { return nil }
        for (offset, character) in compact.enumerated() {
            if character.isASCII, character.isNumber { continue }
            if character == "+", offset == 0 { continue }
            return nil
        }
        guard compact.contains(where: { $0.isASCII && $0.isNumber }) else { return nil }
        return compact
    }

    static func lines(_ text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func terminalFailure(in text: String) -> String? {
        for line in lines(text).map({ $0.uppercased() }) {
            if line == "ERROR" || line.hasPrefix("+CME ERROR:") || line.hasPrefix("+CMS ERROR:") {
                return line
            }
            if ["BUSY", "NO CARRIER", "NO ANSWER", "NO DIALTONE", "NO DIAL TONE"].contains(line) {
                return line
            }
        }
        return nil
    }

    static func commandError(in text: String) -> String? {
        lines(text).map { $0.uppercased() }.first {
            $0 == "ERROR" || $0.hasPrefix("+CME ERROR:") || $0.hasPrefix("+CMS ERROR:")
        }
    }

    static func hasCommandOK(_ text: String) -> Bool {
        lines(text).contains { $0.uppercased() == "OK" }
    }

    static func hasConnect(_ text: String) -> Bool {
        lines(text).contains {
            let upper = $0.uppercased()
            return upper == "CONNECT" || upper == "MO CONNECTED"
        }
    }

    static func hasNoCarrier(_ text: String) -> Bool {
        lines(text).contains { $0.uppercased() == "NO CARRIER" }
    }

    static func latestPCMFlowReady(_ text: String) -> Bool? {
        var latest: Bool?
        for line in lines(text) {
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "+QPCMV" else {
                continue
            }
            let first = line[line.index(after: colon)...]
                .split(separator: ",", maxSplits: 1)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if first == "0" { latest = false }
            if first == "1" { latest = true }
        }
        return latest
    }

    static func latestQPCMVState(_ text: String) -> (enabled: Bool, option: Int?)? {
        var latest: (enabled: Bool, option: Int?)?
        for line in lines(text) {
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "+QPCMV" else {
                continue
            }
            let fields = splitCSV(String(line[line.index(after: colon)...]))
            guard let first = fields.first, let enabled = Int(first), enabled == 0 || enabled == 1 else {
                continue
            }
            let option = fields.count > 1 ? Int(fields[1]) : nil
            latest = (enabled == 1, option)
        }
        return latest
    }

    static func parseCLCC(_ text: String) -> [CLCCCall] {
        lines(text).compactMap { line in
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "+CLCC" else {
                return nil
            }
            let fields = splitCSV(String(line[line.index(after: colon)...]))
            guard fields.count >= 5,
                  let index = Int(fields[0]),
                  let direction = Int(fields[1]),
                  let status = Int(fields[2]),
                  let mode = Int(fields[3]),
                  direction == 0 || direction == 1,
                  (0 ... 5).contains(status) else {
                return nil
            }
            let number: String?
            if fields.count > 5 {
                let value = unquoted(fields[5])
                number = value.isEmpty ? nil : value
            } else {
                number = nil
            }
            return CLCCCall(index: index, direction: direction, status: status, mode: mode, number: number)
        }
    }

    static func simIsReady(_ text: String) -> Bool {
        lines(text).contains {
            $0.replacingOccurrences(of: " ", with: "").uppercased() == "+CPIN:READY"
        }
    }

    static func registrationState(_ text: String, prefix: String) -> Int? {
        let wanted = prefix.uppercased()
        for line in lines(text) {
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == wanted else {
                continue
            }
            let fields = splitCSV(String(line[line.index(after: colon)...]))
            if fields.count >= 2 { return Int(fields[1]) }
            if let first = fields.first { return Int(first) }
        }
        return nil
    }

    static func gpsIsActive(_ text: String) -> Bool {
        lines(text).contains {
            $0.replacingOccurrences(of: " ", with: "").uppercased() == "+QGPS:1"
        }
    }

    static func gpsOutport(_ text: String) -> String? {
        for line in lines(text) {
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "+QGPSCFG" else {
                continue
            }
            let fields = splitCSV(String(line[line.index(after: colon)...]))
            guard fields.count >= 2,
                  unquoted(fields[0]).lowercased() == "outport" else {
                continue
            }
            let value = unquoted(fields[1]).lowercased()
            guard !value.isEmpty,
                  value.count <= 32,
                  value.allSatisfy({
                      $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
                  }) else {
                return nil
            }
            return value
        }
        return nil
    }

    static func supportsRawPCM(_ text: String) -> Bool {
        supportsPCMOption(0, in: text)
    }

    static func supportsUAC(_ text: String) -> Bool {
        supportsPCMOption(2, in: text)
    }

    private static func supportsPCMOption(_ option: Int, in text: String) -> Bool {
        lines(text).contains { line in
            guard line.uppercased().hasPrefix("+QPCMV:") else { return false }
            let compact = line.replacingOccurrences(of: " ", with: "")
            var groups: [String] = []
            var groupStart: String.Index?
            for index in compact.indices {
                if compact[index] == "(" {
                    groupStart = compact.index(after: index)
                } else if compact[index] == ")", let start = groupStart {
                    groups.append(String(compact[start ..< index]))
                    groupStart = nil
                }
            }
            guard groups.count >= 2 else { return false }
            return groups[1].split(separator: ",").contains { token in
                if String(token) == String(option) { return true }
                let bounds = token.split(separator: "-", maxSplits: 1)
                guard bounds.count == 2,
                      let lower = Int(bounds[0]),
                      let upper = Int(bounds[1]) else {
                    return false
                }
                return lower <= option && option <= upper
            }
        }
    }

    private static func splitCSV(_ value: String) -> [String] {
        var fields: [String] = []
        var field = ""
        var quoted = false
        for character in value {
            if character == "\"" {
                quoted.toggle()
                field.append(character)
            } else if character == ",", !quoted {
                fields.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
                field = ""
            } else {
                field.append(character)
            }
        }
        fields.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
        return fields
    }

    private static func unquoted(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2, value.first == "\"", value.last == "\"" else { return value }
        return String(value.dropFirst().dropLast())
    }
}

private struct CommandResult {
    let code: Int32
    let output: String
    let bridgeError: String?

    var completedWithOK: Bool {
        code == MAVO_MODEM_OK && bridgeError == nil && CallProtocol.hasCommandOK(output) &&
            CallProtocol.commandError(in: output) == nil
    }
}

private struct UACStats {
    var inputCallbacks: UInt64 = 0
    var outputCallbacks: UInt64 = 0
    var inputFrames: UInt64 = 0
    var outputFrames: UInt64 = 0
    var inputBytes: UInt64 = 0
    var outputBytes: UInt64 = 0
    var inputTotalSamples: UInt64 = 0
    var inputSignalSamples: UInt64 = 0
    var inputPeakPCM16: UInt32 = 0
    var inputSignalThresholdPCM16: UInt32 = 0
}

private enum DialOutcome: CustomStringConvertible {
    case connected(String)
    case rejected(String)
    case ended(String)
    case timedOut
    case interrupted(Int32)
    case transport(String)

    var description: String {
        switch self {
        case let .connected(evidence): return "connected (\(evidence))"
        case let .rejected(reason): return "rejected (\(reason))"
        case let .ended(reason): return "ended before connection (\(reason))"
        case .timedOut: return "observation timeout"
        case let .interrupted(signal): return "interrupted by signal \(signal)"
        case let .transport(error): return "transport failure (\(error))"
        }
    }

    var provedConnection: Bool {
        if case .connected = self { return true }
        return false
    }
}

private final class DialProbe {
    private let options: Options
    private let log: EvidenceLogger
    private let stop: StopRequest
    private let modem: OpaquePointer
    private var expectedVendor: UInt16 = 0
    private var expectedProduct: UInt16 = 0
    private var expectedLocation: UInt32 = 0
    private var expectedRegistry: UInt64 = 0
    private var dialMayHaveStarted = false
    private var cleanupConfirmed = false
    private var voice: OpaquePointer?
    private var pcmSessionEnabled = false
    private var pcmFlowReady = true
    private var pcmBytesRead: UInt64 = 0
    private var pcmBytesWritten: UInt64 = 0
    private var pcmSamplesRead: UInt64 = 0
    private var pcmNonzeroSamples: UInt64 = 0
    private var pcmPeakPCM16: UInt32 = 0
    private var pcmPendingLowByte: UInt8?
    private var nextPCMWriteNanoseconds: UInt64 = 0
    private var pcmPreparationError: String?
    private var pcmTransportError: String?
    private var pcmCleanupConfirmed = true
    private var originalGPSOutport: String?
    private var gpsOutportChanged = false
    private var gpsOutportCleanupConfirmed = true
    private var postConnectMediaProved = false
    private var uac: OpaquePointer?
    private var uacSessionEnabled = false
    private var uacPreparationError: String?
    private var uacTransportError: String?
    private var uacCleanupConfirmed = true
    private var uacFlowReady = true
    private var cleanupConfirmedByEmptyCLCC = false

    init(options: Options, logger: EvidenceLogger, stop: StopRequest) throws {
        self.options = options
        log = logger
        self.stop = stop
        guard let modem = mavo_modem_create() else {
            throw CLIError.invalid("could not allocate CModemBridge modem")
        }
        self.modem = modem
    }

    deinit {
        if let uac { mavo_uac_probe_destroy(uac) }
        if let voice { mavo_voice_destroy(voice) }
        mavo_modem_destroy(modem)
    }

    func run() -> Int32 {
        let mode: String
        if options.uacFlowNoQPCMV {
            mode = "uac-flow-no-qpcmv"
        } else if options.uacFlow {
            mode = "uac-flow"
        } else if options.qdcExternalPCMFlow {
            mode = "qdc-external-pcm-flow"
        } else if options.fullFlowAfterConnect {
            mode = "full-flow-after-connect"
        } else if options.fullFlow {
            mode = "full-flow"
        } else if options.probeVoiceInterface {
            mode = "interface-probe"
        } else {
            mode = "network-only"
        }
        log.event(
            "LIVE DIAL PROBE START number=\(options.number) observe=\(options.observeSeconds)s " +
                "media=\(options.mediaSeconds)s mode=\(mode)"
        )
        defer {
            if dialMayHaveStarted { cleanupConfirmed = hangUpAndConfirm() }
            finishPCMFlow()
            finishUACFlow()
            mavo_modem_close(modem)
            log.event("AT interface closed")
        }

        let openCode = mavo_modem_open(modem)
        guard openCode == MAVO_MODEM_OK else {
            log.event("FAIL open AT interface code=\(openCode) error=\(lastBridgeError())")
            return 20
        }
        captureIdentity()
        log.event(String(
            format: "DEVICE usb=%04X:%04X location=0x%08X registry=%llu AT_OUT=0x%02X AT_IN=0x%02X",
            expectedVendor,
            expectedProduct,
            expectedLocation,
            expectedRegistry,
            mavo_modem_output_endpoint(modem),
            mavo_modem_input_endpoint(modem)
        ))
        drainPending(label: "open/resync")

        guard expectedLocation != 0 else {
            log.event("RESULT preflight failed: USB location is unavailable, so safe same-device cleanup cannot be guaranteed")
            return 21
        }

        guard performReadOnlyPreflight() else {
            log.event("RESULT preflight failed; ATD was not sent")
            return 21
        }
        if options.fullFlow, !prepareFullFlow() {
            log.event("RESULT full-flow preparation failed; ATD was not sent")
            return 22
        }
        if options.fullFlowAfterConnect, !prepareGPSOutportForVoice() {
            log.event("RESULT after-connect full-flow GPS preparation failed; ATD was not sent")
            return 22
        }
        if options.qdcExternalPCMFlow, !prepareQDCExternalPCMFlow() {
            log.event("RESULT QDC external PCM preparation failed; ATD was not sent")
            return 22
        }
        if options.usesUACFlow, !prepareUACFlow() {
            log.event("RESULT UAC flow preparation failed; ATD was not sent")
            return 22
        }
        guard stop.signal == nil else {
            log.event("RESULT interrupted before ATD; no call was placed")
            return 130
        }

        log.event("PREFLIGHT PASS no existing call; sending the only call-creating command")
        dialMayHaveStarted = true
        let dial = command("ATD\(options.number);", timeoutMS: 12_000, acceptsCallResults: true)
        let immediateFailure = CallProtocol.terminalFailure(in: dial.output)
        if immediateFailure != nil {
            captureCEER(reconnectIfNeeded: true)
        }
        let outcome: DialOutcome
        if let signal = stop.signal {
            outcome = .interrupted(signal)
        } else if CallProtocol.hasConnect(dial.output) {
            if options.fullFlowAfterConnect || options.qdcExternalPCMFlow || options.usesUACFlow {
                let reason: String
                if options.usesUACFlow {
                    reason = "UAC mode requires outgoing active CLCC before starting CoreAudio"
                } else if options.qdcExternalPCMFlow {
                    reason = "QDC external PCM mode requires outgoing active CLCC before accepting media"
                } else {
                    reason = "after-connect mode still requires outgoing active CLCC before QPCMV"
                }
                log.event("ATD returned CONNECT; \(reason)")
                outcome = observeCall(initialCalls: CallProtocol.parseCLCC(dial.output))
            } else {
                outcome = observeCall(
                    initialCalls: CallProtocol.parseCLCC(dial.output),
                    initialConnectionEvidence: "CONNECT in ATD response"
                )
            }
        } else if let immediateFailure {
            log.event("ATD terminal result=\(immediateFailure); CEER captured; performing CLCC reconciliation")
            let calls = queryCLCC(reconnectIfNeeded: true)
            if let calls, calls.contains(where: { $0.isVoice && $0.isOutgoing }) {
                outcome = observeCall(initialCalls: calls)
            } else {
                outcome = .rejected(immediateFailure)
            }
        } else if dial.code != MAVO_MODEM_OK {
            log.event("ATD transport result is ambiguous; reconciling on the original USB location")
            outcome = reconcileAmbiguousDial()
        } else {
            outcome = observeCall(initialCalls: CallProtocol.parseCLCC(dial.output))
        }

        log.event("DIAL OUTCOME \(outcome.description)")
        let confirmed = hangUpAndConfirm()
        cleanupConfirmed = confirmed
        // Four ATH/CLCC attempts have completed. Do not repeat them after the
        // required final QPCMV reset, which must remain the last modem cleanup.
        dialMayHaveStarted = false
        finishPCMFlow()
        finishUACFlow()
        guard confirmed else {
            log.event("RESULT FAIL call cleanup could not be confirmed")
            return 31
        }
        if (options.usesUACFlow || options.qdcExternalPCMFlow), !cleanupConfirmedByEmptyCLCC {
            let mode = options.qdcExternalPCMFlow ? "QDC external PCM" : "UAC"
            log.event("RESULT FAIL \(mode) acceptance requires ATH followed by a successful empty CLCC")
            return 31
        }
        if outcome.provedConnection {
            if options.usesPCMFlow {
                log.event(
                    "PCM TOTAL rx=\(pcmBytesRead) tx=\(pcmBytesWritten) samples=\(pcmSamplesRead) " +
                        "nonzeroSamples=\(pcmNonzeroSamples) peakPCM16=\(pcmPeakPCM16) " +
                        "preparationError=\(pcmPreparationError ?? "none") transportError=\(pcmTransportError ?? "none")"
                )
                let downlinkProved = options.qdcExternalPCMFlow
                    ? pcmNonzeroSamples > 0
                    : pcmBytesRead > 0
                guard downlinkProved,
                      pcmBytesWritten > 0,
                      pcmPreparationError == nil,
                      pcmTransportError == nil,
                      postConnectMediaProved,
                      pcmCleanupConfirmed,
                      gpsOutportCleanupConfirmed else {
                    let requirement = options.qdcExternalPCMFlow
                        ? "nonzero PCM16 downlink plus silent uplink"
                        : "bidirectional USB PCM bytes"
                    log.event("RESULT FAIL call connected, but \(requirement) evidence is incomplete; hangup confirmed")
                    return 32
                }
            }
            if options.usesUACFlow {
                let stats = uacStats()
                log.event(
                    "UAC TOTAL inputCallbacks=\(stats.inputCallbacks) outputCallbacks=\(stats.outputCallbacks) " +
                        "inputFrames=\(stats.inputFrames) outputFrames=\(stats.outputFrames) " +
                        "inputBytes=\(stats.inputBytes) outputBytes=\(stats.outputBytes) " +
                        "inputSamples=\(stats.inputTotalSamples) signalSamples=\(stats.inputSignalSamples) " +
                        "peakPCM16=\(stats.inputPeakPCM16) thresholdPCM16=\(stats.inputSignalThresholdPCM16) " +
                        "flowReady=\(uacFlowReady) preparationError=\(uacPreparationError ?? "none") " +
                        "transportError=\(uacTransportError ?? "none")"
                )
                guard stats.inputFrames > 0,
                      stats.outputFrames > 0,
                      stats.inputSignalSamples > 0,
                      uacPreparationError == nil,
                      uacTransportError == nil,
                      uacFlowReady,
                      postConnectMediaProved,
                      uacCleanupConfirmed else {
                    log.event("RESULT FAIL call connected, but UAC callbacks/downlink signal evidence is incomplete; hangup confirmed")
                    return 32
                }
            }
            if options.usesUACFlow {
                log.event(
                    "RESULT PASS active cellular voice call, UAC downlink signal, silent-uplink callback, " +
                        "and hangup proved; audible Mac microphone/speaker path was not tested"
                )
            } else if options.qdcExternalPCMFlow {
                log.event(
                    "RESULT PASS active outgoing CLCC, nonzero PCM16 USB downlink, silent USB uplink, " +
                        "and ATH plus empty CLCC cleanup proved; external module-side route was not modified"
                )
            } else {
                log.event("RESULT PASS network-connected voice call proved; hangup confirmed")
            }
            return 0
        }
        log.event("RESULT FAIL call did not reach CONNECT/active CLCC; hangup confirmed")
        return 30
    }

    private func captureIdentity() {
        expectedVendor = mavo_modem_vendor_id(modem)
        expectedProduct = mavo_modem_product_id(modem)
        expectedLocation = mavo_modem_location_id(modem)
        expectedRegistry = mavo_modem_registry_id(modem)
    }

    private func performReadOnlyPreflight() -> Bool {
        log.event("PREFLIGHT read-only queries begin")
        let at = command("AT", timeoutMS: 2_000)
        let sim = command("AT+CPIN?", timeoutMS: 3_000)
        _ = command("AT+COPS?", timeoutMS: 3_000)
        let creg = command("AT+CREG?", timeoutMS: 3_000)
        let cereg = command("AT+CEREG?", timeoutMS: 3_000)
        _ = command("AT+CSQ", timeoutMS: 3_000)
        _ = command("AT+QNWINFO", timeoutMS: 3_000)
        _ = command("AT+QCFG=\"ims\"", timeoutMS: 3_000)
        _ = command("AT+QCFG=\"servicedomain\"", timeoutMS: 3_000)
        _ = command("AT+QCFG=\"volte_disable\"", timeoutMS: 3_000)
        _ = command("AT+QMBNCFG=\"AutoSel\"", timeoutMS: 3_000)
        _ = command("AT+QMBNCFG=\"List\"", timeoutMS: 5_000)
        // The QDC external route is owned by ModuleVoiceRuntime. Keep this
        // probe entirely outside both QPCMV and GPS-outport state, including
        // capability/read-back commands that are irrelevant to that route.
        let gpsOutport = options.qdcExternalPCMFlow
            ? nil
            : command("AT+QGPSCFG=\"outport\"", timeoutMS: 3_000)
        let pcm = options.qdcExternalPCMFlow
            ? nil
            : command("AT+QPCMV=?", timeoutMS: 3_000)
        let gps = options.qdcExternalPCMFlow
            ? nil
            : command("AT+QGPS?", timeoutMS: 3_000)
        let clcc = command("AT+CLCC", timeoutMS: 3_000)

        guard at.completedWithOK else {
            log.event("PREFLIGHT FAIL basic AT transaction")
            return false
        }
        guard sim.completedWithOK, CallProtocol.simIsReady(sim.output) else {
            log.event("PREFLIGHT FAIL SIM is not READY")
            return false
        }
        let registrationStates = [
            CallProtocol.registrationState(creg.output, prefix: "+CREG"),
            CallProtocol.registrationState(cereg.output, prefix: "+CEREG")
        ].compactMap { $0 }
        guard registrationStates.contains(where: { $0 == 1 || $0 == 5 }) else {
            log.event("PREFLIGHT FAIL neither CREG nor CEREG reports registered (1/5): \(registrationStates)")
            return false
        }
        guard clcc.completedWithOK else {
            log.event("PREFLIGHT FAIL cannot establish initial CLCC state")
            return false
        }
        let existingCalls = CallProtocol.parseCLCC(clcc.output).filter(\.isVoice)
        guard existingCalls.isEmpty else {
            log.event("PREFLIGHT FAIL existing voice call(s)=\(describe(existingCalls)); refusing ATD and refusing ATH")
            return false
        }
        if options.probeVoiceInterface || options.usesManagedPCMFlow {
            guard let pcm, pcm.completedWithOK, CallProtocol.supportsRawPCM(pcm.output) else {
                log.event("PREFLIGHT FAIL QPCMV test response does not advertise raw option 0")
                return false
            }
            guard let gps, !CallProtocol.gpsIsActive(gps.output) else {
                log.event("PREFLIGHT FAIL QGPS is active on the shared interface 1")
                return false
            }
            if options.usesManagedPCMFlow {
                guard let gpsOutport, gpsOutport.completedWithOK,
                      let outport = CallProtocol.gpsOutport(gpsOutport.output) else {
                    log.event("PREFLIGHT FAIL cannot read the current QGPS outport for reversible voice setup")
                    return false
                }
                originalGPSOutport = outport
                log.event("PREFLIGHT GPS outport=\(outport); selected PCM flow will restore this exact value")
            }
            if options.probeVoiceInterface {
                guard probeVoiceInterface() else { return false }
            }
        }
        if options.qdcExternalPCMFlow {
            log.event(
                "PREFLIGHT QDC external route is caller-managed; QPCMV and GPS-outport commands were intentionally skipped"
            )
        }
        if options.uacFlow {
            guard let pcm, pcm.completedWithOK, CallProtocol.supportsUAC(pcm.output) else {
                log.event("PREFLIGHT FAIL QPCMV test response does not advertise UAC option 2")
                return false
            }
        }
        log.event("PREFLIGHT read-only queries complete")
        return true
    }

    private func probeVoiceInterface() -> Bool {
        guard expectedLocation != 0, let voice = mavo_voice_create() else {
            log.event("VOICE PROBE FAIL missing USB location or could not allocate voice bridge")
            return false
        }
        defer { mavo_voice_destroy(voice) }
        log.event("VOICE PROBE opening interface 1 only; no read, write, playback, or recording")
        let code = mavo_voice_open_for_location(voice, expectedLocation)
        guard code == MAVO_MODEM_OK else {
            let error = mavo_voice_last_error(voice).map { String(cString: $0) } ?? "unknown voice bridge error"
            log.event("VOICE PROBE FAIL code=\(code) error=\(error)")
            return false
        }
        log.event(String(
            format: "VOICE PROBE PASS OUT=0x%02X IN=0x%02X; closing without PCM I/O",
            mavo_voice_output_endpoint(voice),
            mavo_voice_input_endpoint(voice)
        ))
        mavo_voice_close(voice)
        return true
    }

    private func prepareUACFlow() -> Bool {
        guard uac == nil, let candidate = mavo_uac_probe_create() else {
            uacPreparationError = "could not allocate CoreAudio UAC probe"
            log.event("UAC FLOW FAIL: \(uacPreparationError!)")
            return false
        }
        uac = candidate
        let openCode: Int32
        if let preferredUID = options.uacDeviceUID {
            openCode = preferredUID.withCString {
                mavo_uac_probe_open_for_usb(
                    candidate,
                    expectedVendor,
                    expectedProduct,
                    expectedLocation,
                    $0
                )
            }
        } else {
            openCode = mavo_uac_probe_open_for_usb(
                candidate,
                expectedVendor,
                expectedProduct,
                expectedLocation,
                nil
            )
        }
        guard openCode == MAVO_UAC_OK else {
            uacPreparationError = "enumerate/select UAC code=\(openCode) error=\(lastUACError(candidate))"
            log.event("UAC FLOW FAIL before QPCMV: \(uacPreparationError!)")
            return false
        }
        guard mavo_uac_probe_usb_binding_verified(candidate) != 0 else {
            uacPreparationError = "selected UAC pair was not verified against the modem USB identity"
            log.event("UAC FLOW FAIL before QPCMV: \(uacPreparationError!)")
            return false
        }
        let inputName = String(cString: mavo_uac_probe_input_name(candidate))
        let outputName = String(cString: mavo_uac_probe_output_name(candidate))
        let inputUID = String(cString: mavo_uac_probe_input_uid(candidate))
        let outputUID = String(cString: mavo_uac_probe_output_uid(candidate))
        log.event(
            "UAC ENUMERATED binding=verified-same-USB-location " +
                "input={id=\(mavo_uac_probe_input_device_id(candidate)),name=\"\(inputName)\",uid=\"\(inputUID)\"," +
                "channels=\(mavo_uac_probe_input_channels(candidate)),rate=\(Int(mavo_uac_probe_input_sample_rate(candidate)))} " +
                "output={id=\(mavo_uac_probe_output_device_id(candidate)),name=\"\(outputName)\",uid=\"\(outputUID)\"," +
                "channels=\(mavo_uac_probe_output_channels(candidate)),rate=\(Int(mavo_uac_probe_output_sample_rate(candidate)))}"
        )

        if options.uacFlowNoQPCMV {
            log.event("UAC FLOW diagnostic mode: verified UAC pair selected; no QPCMV command will be sent")
            return true
        }

        // A lost AT response may mean the modem accepted the command, so all
        // later exits must attempt one QPCMV=0 reset.
        uacSessionEnabled = true
        uacCleanupConfirmed = false
        log.event("UAC FLOW enabling QPCMV=1,2 only after CoreAudio enumeration")
        let enable = command("AT+QPCMV=1,2", timeoutMS: 3_000)
        guard enable.completedWithOK else {
            uacPreparationError = "QPCMV=1,2 was not confirmed"
            log.event("UAC FLOW FAIL: \(uacPreparationError!)")
            return false
        }
        let verify = command("AT+QPCMV?", timeoutMS: 3_000)
        guard verify.completedWithOK,
              let state = CallProtocol.latestQPCMVState(verify.output),
              state.enabled,
              state.option == 2 else {
            uacPreparationError = "QPCMV read-back did not confirm enabled UAC option 2"
            log.event("UAC FLOW FAIL: \(uacPreparationError!)")
            return false
        }
        uacFlowReady = true
        log.event("UAC FLOW QPCMV=1,2 and read-back confirmed; CoreAudio remains stopped until outgoing active CLCC")
        return true
    }

    private func startUACAfterActiveCLCC() -> Bool {
        guard let uac else {
            uacPreparationError = "selected UAC device is unavailable"
            return false
        }
        let code = mavo_uac_probe_start_silence(uac)
        guard code == MAVO_UAC_OK else {
            uacPreparationError = "start CoreAudio IOProc code=\(code) error=\(lastUACError(uac))"
            log.event("UAC FLOW FAIL after active CLCC: \(uacPreparationError!)")
            return false
        }
        log.event(
            "UAC IO STARTED inputRate=\(Int(mavo_uac_probe_input_sample_rate(uac))) Hz " +
                "outputRate=\(Int(mavo_uac_probe_output_sample_rate(uac))) Hz; " +
                "input is consumed and output is zero-filled silence; no Mac microphone/speaker bridge"
        )
        return true
    }

    private func finishUACFlow() {
        guard options.usesUACFlow, let uac,
              uacSessionEnabled || mavo_uac_probe_is_running(uac) != 0 else {
            return
        }
        log.event(
            uacSessionEnabled
                ? "UAC FLOW cleanup after call cleanup: stop CoreAudio -> final QPCMV=0"
                : "UAC FLOW cleanup after call cleanup: stop CoreAudio; QPCMV was never sent"
        )
        let wasRunning = mavo_uac_probe_is_running(uac) != 0
        let stopCode = mavo_uac_probe_stop(uac)
        if stopCode == MAVO_UAC_OK {
            if wasRunning {
                log.event("UAC IO stopped; any changed nominal sample rate was restored")
            }
        } else {
            uacTransportError = "stop/restore CoreAudio code=\(stopCode) error=\(lastUACError(uac))"
            log.event("UAC IO STOP FAIL \(uacTransportError!)")
        }
        if uacSessionEnabled {
            if !isOpen { _ = reconnectOriginalDevice() }
            if isOpen {
                let reset = command("AT+QPCMV=0", timeoutMS: 3_000)
                // Prevent the outer defer from repeating a modem write.
                uacSessionEnabled = false
                if reset.completedWithOK {
                    uacCleanupConfirmed = true
                    log.event("UAC FLOW QPCMV reset confirmed")
                } else {
                    uacCleanupConfirmed = false
                    log.event("UAC FLOW QPCMV reset not confirmed")
                }
            } else {
                uacSessionEnabled = false
                uacCleanupConfirmed = false
                log.event("UAC FLOW QPCMV reset impossible because original AT interface is unreachable")
            }
        }
    }

    private func uacStats() -> UACStats {
        guard let uac else { return UACStats() }
        return UACStats(
            inputCallbacks: mavo_uac_probe_input_callbacks(uac),
            outputCallbacks: mavo_uac_probe_output_callbacks(uac),
            inputFrames: mavo_uac_probe_input_frames(uac),
            outputFrames: mavo_uac_probe_output_frames(uac),
            inputBytes: mavo_uac_probe_input_bytes(uac),
            outputBytes: mavo_uac_probe_output_bytes(uac),
            inputTotalSamples: mavo_uac_probe_input_total_samples(uac),
            inputSignalSamples: mavo_uac_probe_input_signal_samples(uac),
            inputPeakPCM16: mavo_uac_probe_input_peak_pcm16(uac),
            inputSignalThresholdPCM16: mavo_uac_probe_input_signal_threshold_pcm16(uac)
        )
    }

    private func lastUACError(_ uac: OpaquePointer) -> String {
        let value = String(cString: mavo_uac_probe_last_error(uac))
        return value.isEmpty ? "unknown CoreAudio UAC error" : value
    }

    private func prepareQDCExternalPCMFlow() -> Bool {
        guard voice == nil, !pcmSessionEnabled, !gpsOutportChanged else {
            pcmPreparationError = "voice or modem-managed PCM state was already prepared"
            log.event("QDC EXTERNAL PCM FAIL: \(pcmPreparationError!)")
            return false
        }
        guard let candidate = mavo_voice_create() else {
            pcmPreparationError = "could not allocate voice bridge"
            log.event("QDC EXTERNAL PCM FAIL: \(pcmPreparationError!)")
            return false
        }
        let code = mavo_voice_open_interface_for_location(candidate, expectedLocation, 1)
        guard code == MAVO_MODEM_OK else {
            let error = mavo_voice_last_error(candidate).map { String(cString: $0) }
                ?? "unknown voice bridge error"
            pcmPreparationError = "open USB interface 1 code=\(code) error=\(error)"
            log.event("QDC EXTERNAL PCM FAIL: \(pcmPreparationError!)")
            mavo_voice_destroy(candidate)
            return false
        }
        voice = candidate
        // The module helper cannot open its hostless D5/D6 endpoints until a
        // cellular call is active.  Keep both USB directions idle before the
        // active CLCC so ttyGS0 cannot fill up while the helper is waiting.
        pcmFlowReady = false
        nextPCMWriteNanoseconds = 0
        log.event(String(
            format: "QDC EXTERNAL PCM interface 1 open OUT=0x%02X IN=0x%02X; I/O remains paused until outgoing active CLCC; no QPCMV or GPS-outport command was sent; external route remains caller-managed",
            mavo_voice_output_endpoint(candidate),
            mavo_voice_input_endpoint(candidate)
        ))
        return true
    }

    private func prepareFullFlow() -> Bool {
        guard prepareGPSOutportForVoice() else { return false }
        log.event("FULL FLOW prepare: GPS outport none -> QPCMV=1,0 -> open voice interface 1")
        return enablePCMAndOpenVoice(context: "pre-dial")
    }

    private func enablePCMAndOpenVoice(context: String) -> Bool {
        guard !pcmSessionEnabled, voice == nil else {
            pcmPreparationError = "QPCMV/voice session was already prepared"
            log.event("FULL FLOW FAIL \(context): \(pcmPreparationError!)")
            return false
        }
        // Mark the session as possibly enabled before sending: a transport
        // timeout can lose the response after the module accepted the command.
        pcmSessionEnabled = true
        pcmCleanupConfirmed = false
        pcmFlowReady = true
        log.event("FULL FLOW \(context): enabling QPCMV=1,0")
        let enable = command("AT+QPCMV=1,0", timeoutMS: 3_000)
        guard enable.completedWithOK else {
            pcmPreparationError = "QPCMV=1,0 was not confirmed"
            log.event("FULL FLOW FAIL \(context): \(pcmPreparationError!)")
            return false
        }
        guard let candidate = mavo_voice_create() else {
            pcmPreparationError = "could not allocate voice bridge"
            log.event("FULL FLOW FAIL \(context): \(pcmPreparationError!)")
            return false
        }
        let code = mavo_voice_open_for_location(candidate, expectedLocation)
        guard code == MAVO_MODEM_OK else {
            let error = mavo_voice_last_error(candidate).map { String(cString: $0) } ?? "unknown voice bridge error"
            pcmPreparationError = "open voice interface code=\(code) error=\(error)"
            log.event("FULL FLOW FAIL \(context): \(pcmPreparationError!)")
            mavo_voice_destroy(candidate)
            return false
        }
        voice = candidate
        nextPCMWriteNanoseconds = DispatchTime.now().uptimeNanoseconds + 100_000_000
        log.event(String(
            format: "FULL FLOW %@ voice interface open OUT=0x%02X IN=0x%02X; uplink is zero-filled silence and downlink is discarded",
            context,
            mavo_voice_output_endpoint(candidate),
            mavo_voice_input_endpoint(candidate)
        ))
        return true
    }

    private func prepareGPSOutportForVoice() -> Bool {
        guard let originalGPSOutport else {
            log.event("FULL FLOW FAIL original GPS outport was not captured")
            return false
        }
        guard originalGPSOutport != "none" else {
            log.event("FULL FLOW GPS outport is already none")
            return true
        }
        log.event("FULL FLOW temporarily changing GPS outport \(originalGPSOutport) -> none")
        // Treat the setting as changed before the write. If the USB response
        // is lost after the module accepted it, cleanup still restores the
        // captured value instead of leaving interface 1 reassigned.
        gpsOutportChanged = true
        gpsOutportCleanupConfirmed = false
        let write = command("AT+QGPSCFG=\"outport\",\"none\"", timeoutMS: 3_000)
        guard write.completedWithOK else {
            log.event("FULL FLOW FAIL setting GPS outport to none")
            return false
        }
        let verify = command("AT+QGPSCFG=\"outport\"", timeoutMS: 3_000)
        guard verify.completedWithOK,
              CallProtocol.gpsOutport(verify.output) == "none" else {
            log.event("FULL FLOW FAIL GPS outport none read-back verification")
            return false
        }
        log.event("FULL FLOW GPS outport none verified")
        return true
    }

    private func finishPCMFlow() {
        if options.qdcExternalPCMFlow {
            guard let voice else { return }
            log.event(
                "QDC EXTERNAL PCM cleanup after call cleanup: closing interface 1; " +
                    "external route remains caller-managed and no QPCMV/GPS command will be sent"
            )
            mavo_voice_destroy(voice)
            self.voice = nil
            pcmPendingLowByte = nil
            return
        }
        guard pcmSessionEnabled || voice != nil || gpsOutportChanged else { return }
        log.event("FULL FLOW cleanup after call cleanup: final QPCMV=0, close voice, restore GPS outport")
        if pcmSessionEnabled {
            if !isOpen { _ = reconnectOriginalDevice() }
            if isOpen {
                let reset = command("AT+QPCMV=0", timeoutMS: 3_000)
                // One explicit reset attempt is enough. Preserve the failed
                // confirmation in pcmCleanupConfirmed, but do not emit the
                // same modem write again from the outer defer path.
                pcmSessionEnabled = false
                if reset.completedWithOK {
                    pcmCleanupConfirmed = true
                    log.event("FULL FLOW QPCMV reset confirmed")
                } else {
                    pcmCleanupConfirmed = false
                    log.event("FULL FLOW QPCMV reset not confirmed")
                }
            } else {
                pcmCleanupConfirmed = false
                log.event("FULL FLOW QPCMV reset impossible because original AT interface is unreachable")
            }
        }
        if let voice {
            mavo_voice_destroy(voice)
            self.voice = nil
            log.event("FULL FLOW voice interface closed")
        }
        if gpsOutportChanged {
            guard let originalGPSOutport else {
                gpsOutportCleanupConfirmed = false
                log.event("FULL FLOW GPS outport restore impossible because the original value is missing")
                return
            }
            if !isOpen { _ = reconnectOriginalDevice() }
            guard isOpen else {
                gpsOutportCleanupConfirmed = false
                log.event("FULL FLOW GPS outport restore impossible because the original module is unreachable")
                return
            }
            log.event("FULL FLOW restoring GPS outport none -> \(originalGPSOutport)")
            let restore = command(
                "AT+QGPSCFG=\"outport\",\"\(originalGPSOutport)\"",
                timeoutMS: 3_000
            )
            let verify = restore.completedWithOK
                ? command("AT+QGPSCFG=\"outport\"", timeoutMS: 3_000)
                : restore
            if restore.completedWithOK,
               verify.completedWithOK,
               CallProtocol.gpsOutport(verify.output) == originalGPSOutport {
                gpsOutportChanged = false
                gpsOutportCleanupConfirmed = true
                log.event("FULL FLOW GPS outport restore confirmed")
            } else {
                gpsOutportCleanupConfirmed = false
                log.event("FULL FLOW GPS outport restore not confirmed")
            }
        }
    }

    private func pumpPCM() {
        guard options.usesPCMFlow,
              pcmTransportError == nil,
              let voice,
              mavo_voice_is_open(voice) != 0 else {
            return
        }
        if options.qdcExternalPCMFlow, !pcmFlowReady { return }

        let now = DispatchTime.now().uptimeNanoseconds
        if pcmFlowReady, now >= nextPCMWriteNanoseconds {
            let silence = [UInt8](repeating: 0, count: 1_600)
            let code = silence.withUnsafeBufferPointer {
                mavo_voice_write(voice, 80, $0.baseAddress, $0.count)
            }
            if code == MAVO_MODEM_OK {
                pcmBytesWritten += UInt64(silence.count)
                log.event("PCM TX silent bytes=\(silence.count) total=\(pcmBytesWritten)")
                nextPCMWriteNanoseconds = now + 100_000_000
            } else {
                recordPCMError("write code=\(code) error=\(lastVoiceError(voice))")
                return
            }
        }

        // The module emits 256-byte periods but may coalesce a backlog into a
        // bulk transaction larger than the 640-byte playback cadence.  The
        // IOKit synchronous API reports that as kIOReturnOverrun and provides
        // no valid partial data, so the transport request must absorb bursts.
        var receive = [UInt8](repeating: 0, count: 4_096)
        let read = receive.withUnsafeMutableBufferPointer {
            mavo_voice_read(voice, 40, $0.baseAddress, $0.count)
        }
        if read > 0, mavo_voice_is_open(voice) != 0 {
            let byteCount = min(Int(read), receive.count)
            pcmBytesRead += UInt64(byteCount)
            observePCM16Downlink(receive, count: byteCount)
            log.event(
                "PCM RX discarded bytes=\(byteCount) total=\(pcmBytesRead) " +
                    "samples=\(pcmSamplesRead) nonzeroSamples=\(pcmNonzeroSamples) peakPCM16=\(pcmPeakPCM16)"
            )
        } else if read < 0 || (read > 0 && mavo_voice_is_open(voice) == 0) {
            recordPCMError("read code=\(read) error=\(lastVoiceError(voice))")
        }
    }

    private func observePCM16Downlink(_ bytes: [UInt8], count: Int) {
        guard count > 0 else { return }
        var offset = 0
        if let lowByte = pcmPendingLowByte {
            recordPCM16(lowByte: lowByte, highByte: bytes[0])
            pcmPendingLowByte = nil
            offset = 1
        }
        while offset + 1 < count {
            recordPCM16(lowByte: bytes[offset], highByte: bytes[offset + 1])
            offset += 2
        }
        if offset < count {
            pcmPendingLowByte = bytes[offset]
        }
    }

    private func recordPCM16(lowByte: UInt8, highByte: UInt8) {
        let bits = UInt16(lowByte) | (UInt16(highByte) << 8)
        let sample = Int32(Int16(bitPattern: bits))
        let magnitude = UInt32(sample < 0 ? -sample : sample)
        pcmSamplesRead += 1
        if magnitude > 0 { pcmNonzeroSamples += 1 }
        if magnitude > pcmPeakPCM16 { pcmPeakPCM16 = magnitude }
    }

    private func recordPCMError(_ error: String) {
        guard pcmTransportError == nil else { return }
        pcmTransportError = error
        log.event("PCM TRANSPORT FAIL \(error)")
    }

    private func lastVoiceError(_ voice: OpaquePointer) -> String {
        guard let pointer = mavo_voice_last_error(voice) else { return "unknown voice bridge error" }
        let value = String(cString: pointer)
        return value.isEmpty ? "unknown voice bridge error" : value
    }

    private func captureCEER(reconnectIfNeeded: Bool) {
        if !isOpen {
            guard reconnectIfNeeded, reconnectOriginalDevice() else {
                log.event("CEER unavailable because the original module could not be reopened")
                return
            }
        }
        log.event("ATD FAILURE EVIDENCE: issuing AT+CEER before CLCC or any other explicit AT command")
        _ = command("AT+CEER", timeoutMS: 3_000)
    }

    private func reconcileAmbiguousDial() -> DialOutcome {
        guard reconnectOriginalDevice() else {
            return .transport("could not reopen the original module after ATD ambiguity")
        }
        captureCEER(reconnectIfNeeded: false)
        guard let calls = queryCLCC(reconnectIfNeeded: false) else {
            return .transport("CLCC unavailable after reopening original module")
        }
        guard !calls.isEmpty else {
            return .ended("ATD response lost and CLCC is empty")
        }
        return observeCall(initialCalls: calls)
    }

    private func observeCall(
        initialCalls: [CLCCCall],
        initialConnectionEvidence: String? = nil
    ) -> DialOutcome {
        let deadline = Date().addingTimeInterval(TimeInterval(options.observeSeconds))
        var observedCall = false
        var calls = initialCalls.filter(\.isVoice)
        var lastPoll = Date.distantPast
        var urcStream = ""
        var connectionEvidence = initialConnectionEvidence
        var mediaDeadline: Date?
        var rxAtConnection = pcmBytesRead
        var txAtConnection = pcmBytesWritten
        var nonzeroSamplesAtConnection = pcmNonzeroSamples
        var uacAtConnection = uacStats()
        var connectAwaitingCLCCLogged = false

        func recordConnection(_ evidence: String) -> DialOutcome? {
            guard connectionEvidence == nil else { return nil }
            connectionEvidence = evidence
            log.event("CALL CONNECTION PROVED \(evidence)")
            if options.fullFlowAfterConnect {
                log.event("AFTER-CONNECT FLOW active outgoing CLCC proved; now QPCMV=1,0 -> open voice interface 1")
                guard enablePCMAndOpenVoice(context: "after active CLCC") else {
                    let error = pcmPreparationError ?? "unknown QPCMV/voice preparation failure"
                    // Return directly to run(), whose next explicit AT action
                    // is ATH followed by CLCC. QPCMV reset/outport restore are
                    // deliberately deferred until those call-cleanup attempts.
                    return .connected("\(evidence); PCM preparation failed: \(error)")
                }
            }
            if options.usesUACFlow {
                log.event("UAC FLOW active outgoing CLCC proved; starting CoreAudio IOProc")
                guard startUACAfterActiveCLCC() else {
                    let error = uacPreparationError ?? "unknown CoreAudio UAC preparation failure"
                    return .connected("\(evidence); UAC preparation failed: \(error)")
                }
            }
            if options.qdcExternalPCMFlow {
                pcmFlowReady = true
                nextPCMWriteNanoseconds =
                    DispatchTime.now().uptimeNanoseconds + 500_000_000
                log.event(
                    "QDC EXTERNAL PCM active outgoing CLCC proved; " +
                        "enabling USB PCM after a 500 ms module-side settle"
                )
            }
            rxAtConnection = pcmBytesRead
            txAtConnection = pcmBytesWritten
            nonzeroSamplesAtConnection = pcmNonzeroSamples
            uacAtConnection = uacStats()
            mediaDeadline = Date().addingTimeInterval(TimeInterval(options.mediaSeconds))
            if options.usesPCMFlow {
                log.event(
                    "POST-CONNECT PCM baseline rx=\(rxAtConnection) tx=\(txAtConnection) " +
                        "nonzeroSamples=\(nonzeroSamplesAtConnection)"
                )
            } else if options.usesUACFlow {
                log.event(
                    "POST-CONNECT UAC baseline inputFrames=\(uacAtConnection.inputFrames) " +
                        "outputFrames=\(uacAtConnection.outputFrames) " +
                        "signalSamples=\(uacAtConnection.inputSignalSamples)"
                )
            }
            return nil
        }

        if let initialConnectionEvidence {
            mediaDeadline = Date().addingTimeInterval(TimeInterval(options.mediaSeconds))
            let suffix = options.usesPCMFlow ? "; awaiting post-connect PCM evidence" : ""
            log.event("CALL CONNECTION PROVED \(initialConnectionEvidence)\(suffix)")
        }
        if !calls.isEmpty {
            observedCall = true
            log.event("CLCC initial \(describe(calls))")
        }
        if let active = calls.first(where: { $0.isOutgoing && $0.isActive }) {
            if let failure = recordConnection("CLCC index \(active.index) status 0") {
                return failure
            }
        }

        // The connection-observation budget ends an unanswered attempt, but
        // must not truncate the separately requested post-connect media window.
        while Date() < max(deadline, mediaDeadline ?? deadline) {
            if let signal = stop.signal { return .interrupted(signal) }

            // A 256-byte period at 8 kHz mono PCM16 arrives every 16 ms.  Do
            // not spend 25 ms waiting on the independent AT pipe before each
            // PCM drain, or ttyGS0 will inevitably build a bulk backlog.
            let urcTimeout: Int32 = options.usesMediaFlow ? 5 : 200
            let urc = readPending(timeoutMS: urcTimeout, label: "URC")
            urcStream += urc
            if urcStream.utf8.count > 64 * 1_024 {
                urcStream = String(urcStream.suffix(16 * 1_024))
            }
            if CallProtocol.hasConnect(urcStream) {
                if options.fullFlowAfterConnect || options.qdcExternalPCMFlow || options.usesUACFlow {
                    if !connectAwaitingCLCCLogged {
                        connectAwaitingCLCCLogged = true
                        let mode: String
                        if options.usesUACFlow {
                            mode = "UAC"
                        } else if options.qdcExternalPCMFlow {
                            mode = "QDC external PCM"
                        } else {
                            mode = "after-connect"
                        }
                        log.event("CONNECT URC observed; \(mode) mode is still waiting for outgoing active CLCC")
                    }
                } else {
                    if let failure = recordConnection("CONNECT URC") { return failure }
                }
            }
            if let failure = CallProtocol.terminalFailure(in: urcStream) {
                captureCEER(reconnectIfNeeded: true)
                if let connectionEvidence {
                    return .connected("\(connectionEvidence); later terminal \(failure)")
                }
                return .ended(failure)
            }

            if let pcmPreparationError, let connectionEvidence {
                return .connected("\(connectionEvidence); PCM preparation failed: \(pcmPreparationError)")
            }
            if let uacPreparationError, let connectionEvidence {
                return .connected("\(connectionEvidence); UAC preparation failed: \(uacPreparationError)")
            }
            pumpPCM()
            if let pcmTransportError {
                if let connectionEvidence {
                    return .connected("\(connectionEvidence); PCM transport failed: \(pcmTransportError)")
                }
                return .transport("PCM transport failed: \(pcmTransportError)")
            }
            if let uacTransportError {
                if let connectionEvidence {
                    return .connected("\(connectionEvidence); UAC transport failed: \(uacTransportError)")
                }
                return .transport("UAC transport failed: \(uacTransportError)")
            }
            if let connectionEvidence {
                if !options.usesMediaFlow {
                    return .connected(connectionEvidence)
                }
                if options.usesPCMFlow {
                    let downlinkProved = options.qdcExternalPCMFlow
                        ? pcmNonzeroSamples > nonzeroSamplesAtConnection
                        : pcmBytesRead > rxAtConnection
                    if downlinkProved, pcmBytesWritten > txAtConnection {
                        postConnectMediaProved = true
                        if options.qdcExternalPCMFlow {
                            log.event(
                                "QDC external PCM post-connect signal proved " +
                                    "nonzeroSamples=\(pcmNonzeroSamples - nonzeroSamplesAtConnection) " +
                                    "peakPCM16=\(pcmPeakPCM16) silentUplinkBytes=\(pcmBytesWritten - txAtConnection)"
                            )
                        } else {
                            log.event("PCM post-connect bidirectional byte evidence proved")
                        }
                        return .connected(connectionEvidence)
                    }
                }
                if options.usesUACFlow {
                    let stats = uacStats()
                    if uacFlowReady,
                       stats.inputFrames > uacAtConnection.inputFrames,
                       stats.outputFrames > uacAtConnection.outputFrames,
                       stats.inputSignalSamples > uacAtConnection.inputSignalSamples {
                        postConnectMediaProved = true
                        log.event(
                            "UAC post-connect input/output callbacks and downlink signal proved " +
                                "input=\(stats.inputFrames - uacAtConnection.inputFrames) " +
                                "output=\(stats.outputFrames - uacAtConnection.outputFrames) " +
                                "signalSamples=\(stats.inputSignalSamples - uacAtConnection.inputSignalSamples) " +
                                "peakPCM16=\(stats.inputPeakPCM16)"
                        )
                        return .connected(connectionEvidence)
                    }
                }
                if let mediaDeadline, Date() >= mediaDeadline {
                    let medium = options.usesUACFlow ? "UAC" : "PCM"
                    return .connected("\(connectionEvidence); post-connect \(medium) window expired")
                }
            }

            if Date().timeIntervalSince(lastPoll) >= 0.5 {
                lastPoll = Date()
                guard let polled = queryCLCC(reconnectIfNeeded: true) else {
                    return .transport("CLCC query/reconnect failed during observation")
                }
                calls = polled.filter(\.isVoice)
                if let active = calls.first(where: { $0.isOutgoing && $0.isActive }) {
                    if let failure = recordConnection("CLCC index \(active.index) status 0") {
                        return failure
                    }
                }
                if !calls.isEmpty {
                    observedCall = true
                    log.event("CLCC state \(describe(calls))")
                } else if observedCall {
                    if let connectionEvidence { return .connected(connectionEvidence) }
                    return .ended("CLCC became empty")
                }
            }
        }
        if let connectionEvidence { return .connected(connectionEvidence) }
        return .timedOut
    }

    private func hangUpAndConfirm() -> Bool {
        guard dialMayHaveStarted else { return cleanupConfirmed }
        cleanupConfirmedByEmptyCLCC = false
        log.event("CLEANUP begin: ATH plus CLCC confirmation")
        var sawNoCarrier = false
        for attempt in 1 ... 4 {
            if !isOpen, !reconnectOriginalDevice() {
                log.event("CLEANUP attempt=\(attempt) cannot reach original module")
                Thread.sleep(forTimeInterval: 0.25)
                continue
            }
            let hangup = command("ATH", timeoutMS: 3_000, acceptsCallResults: true)
            sawNoCarrier = sawNoCarrier || CallProtocol.hasNoCarrier(hangup.output)
            if sawNoCarrier {
                log.event("CLEANUP observed NO CARRIER; still querying CLCC for independent confirmation")
            }
            if let calls = queryCLCC(reconnectIfNeeded: true) {
                let voiceCalls = calls.filter(\.isVoice)
                if voiceCalls.isEmpty {
                    cleanupConfirmedByEmptyCLCC = true
                    log.event("CLEANUP CONFIRMED by empty CLCC\(sawNoCarrier ? " plus NO CARRIER" : "")")
                    return true
                }
                log.event("CLEANUP attempt=\(attempt) call remains \(describe(voiceCalls))")
            } else if sawNoCarrier {
                log.event("CLEANUP CONFIRMED by explicit NO CARRIER; CLCC was attempted but unavailable")
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        log.event("CLEANUP UNCONFIRMED after 4 ATH/CLCC attempts")
        return false
    }

    private func queryCLCC(reconnectIfNeeded: Bool) -> [CLCCCall]? {
        if !isOpen {
            guard reconnectIfNeeded, reconnectOriginalDevice() else { return nil }
        }
        let result = command("AT+CLCC", timeoutMS: 3_000)
        guard result.completedWithOK else { return nil }
        return CallProtocol.parseCLCC(result.output)
    }

    private func reconnectOriginalDevice() -> Bool {
        guard expectedLocation != 0 else {
            log.event("RECONNECT REFUSED original USB location is unknown")
            return false
        }
        if isOpen { return identityMatches() }
        log.event(String(format: "RECONNECT original location=0x%08X", expectedLocation))
        let code = mavo_modem_open_for_location(modem, expectedLocation)
        guard code == MAVO_MODEM_OK else {
            log.event("RECONNECT FAIL code=\(code) error=\(lastBridgeError())")
            return false
        }
        guard identityMatches() else {
            log.event("RECONNECT REFUSED USB identity/registry does not match original module")
            mavo_modem_close(modem)
            return false
        }
        drainPending(label: "reconnect/resync")
        log.event("RECONNECT PASS original module identity matched")
        return true
    }

    private func identityMatches() -> Bool {
        guard mavo_modem_vendor_id(modem) == expectedVendor,
              mavo_modem_product_id(modem) == expectedProduct,
              mavo_modem_location_id(modem) == expectedLocation else {
            return false
        }
        let registry = mavo_modem_registry_id(modem)
        return expectedRegistry == 0 || registry == 0 || registry == expectedRegistry
    }

    private var isOpen: Bool { mavo_modem_is_open(modem) != 0 }

    private func command(
        _ value: String,
        timeoutMS: Int32,
        acceptsCallResults: Bool = false
    ) -> CommandResult {
        guard isOpen else {
            return CommandResult(code: Int32(MAVO_MODEM_NOT_OPEN), output: "", bridgeError: "AT interface is closed")
        }
        log.transmit(value)
        var buffer = [CChar](repeating: 0, count: 64 * 1_024)
        let code: Int32 = buffer.withUnsafeMutableBufferPointer { pointer in
            if acceptsCallResults {
                return mavo_modem_call_command(modem, value, timeoutMS, pointer.baseAddress, pointer.count)
            }
            return mavo_modem_command(modem, value, timeoutMS, pointer.baseAddress, pointer.count)
        }
        let output = String(cString: buffer)
        if !output.isEmpty {
            log.receive("command", output)
            observePCMFlow(in: output)
        }
        let bridgeError: String?
        if code == MAVO_MODEM_OK {
            bridgeError = nil
        } else {
            bridgeError = lastBridgeError()
            log.event("COMMAND transport code=\(code) error=\(bridgeError ?? "unknown") open=\(isOpen)")
        }
        return CommandResult(code: code, output: output, bridgeError: bridgeError)
    }

    @discardableResult
    private func readPending(timeoutMS: Int32, label: String) -> String {
        guard isOpen else { return "" }
        var buffer = [CChar](repeating: 0, count: 64 * 1_024)
        let code = buffer.withUnsafeMutableBufferPointer {
            mavo_modem_read(modem, timeoutMS, $0.baseAddress, $0.count)
        }
        if code > 0 {
            let output = String(cString: buffer)
            log.receive(label, output)
            observePCMFlow(in: output)
            return output
        }
        if code != MAVO_MODEM_OK {
            log.event("RX transport code=\(code) error=\(lastBridgeError()) open=\(isOpen)")
        }
        return ""
    }

    private func observePCMFlow(in output: String) {
        guard let ready = CallProtocol.latestPCMFlowReady(output) else { return }
        if options.uacFlow, ready != uacFlowReady {
            uacFlowReady = ready
            log.event("UAC FLOW ready=\(ready)")
        }
        if options.usesManagedPCMFlow, ready != pcmFlowReady {
            pcmFlowReady = ready
            log.event("PCM FLOW ready=\(ready)")
            if ready {
                nextPCMWriteNanoseconds = DispatchTime.now().uptimeNanoseconds
            }
        }
    }

    private func drainPending(label: String) {
        for _ in 0 ..< 64 {
            let value = readPending(timeoutMS: 25, label: label)
            if value.isEmpty { return }
        }
        log.event("RX drain stopped at safety limit")
    }

    private func lastBridgeError() -> String {
        guard let pointer = mavo_modem_last_error(modem) else { return "unknown CModemBridge error" }
        let value = String(cString: pointer)
        return value.isEmpty ? "unknown CModemBridge error" : value
    }

    private func describe(_ calls: [CLCCCall]) -> String {
        calls.map {
            "{idx=\($0.index),dir=\($0.direction),stat=\($0.status),mode=\($0.mode),number=\($0.number ?? "-")}" 
        }.joined(separator: ",")
    }
}

private enum Main {
    static func main() {
        let options: Options
        do {
            options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
        } catch CLIError.help {
            print(usage)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n\n\(usage)\n".utf8))
            exit(64)
        }

        let logger: EvidenceLogger
        do {
            logger = try EvidenceLogger(logPath: options.logPath)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(73)
        }

        let stop = StopRequest()
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .userInitiated))
        let terminateSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .userInitiated))
        interruptSource.setEventHandler {
            stop.request(SIGINT)
            logger.event("SIGNAL SIGINT received; cleanup requested")
        }
        terminateSource.setEventHandler {
            stop.request(SIGTERM)
            logger.event("SIGNAL SIGTERM received; cleanup requested")
        }
        interruptSource.resume()
        terminateSource.resume()
        defer {
            interruptSource.cancel()
            terminateSource.cancel()
        }

        do {
            let probe = try DialProbe(options: options, logger: logger, stop: stop)
            let code = probe.run()
            exit(code)
        } catch {
            logger.event("FATAL \(error)")
            exit(70)
        }
    }
}

Main.main()
