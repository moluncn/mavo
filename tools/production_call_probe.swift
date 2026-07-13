import Darwin
import Foundation

private enum ProbeError: LocalizedError {
    case usage(String)
    case failed(String)
    case interrupted

    var errorDescription: String? {
        switch self {
        case let .usage(message), let .failed(message): return message
        case .interrupted: return "probe interrupted"
        }
    }
}

@main
struct ProductionCallProbe {
    private static var interrupted = false

    static func main() {
        setlinebuf(stdout)
        setlinebuf(stderr)
        do {
            try run()
        } catch {
            fputs("MaVo production call probe failed: \(error.localizedDescription)\n", stderr)
            exit(error is ProbeError ? 1 : 70)
        }
    }

    private static func run() throws {
        let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interruptSource.setEventHandler { interrupted = true }
        interruptSource.resume()
        let terminateSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminateSource.setEventHandler { interrupted = true }
        terminateSource.resume()

        let service = ModemService()
        var modem = ModemSnapshot()
        var call = CallSnapshot()
        var lastCallDescription = ""
        var shutdownSucceeded = false

        service.onSnapshot = { snapshot in
            modem = snapshot
            print("MODEM state=\(snapshot.state) error=\(snapshot.lastError ?? "none")")
        }
        service.onCallSnapshot = { snapshot in
            call = snapshot
            let description = describe(snapshot)
            if description != lastCallDescription {
                lastCallDescription = description
                print("CALL \(description)")
            }
        }
        service.onMessages = { _, _ in }
        service.start()

        defer {
            var completed = false
            service.shutdown { success in
                shutdownSucceeded = success
                completed = true
            }
            _ = waitUntil(timeout: 45) { completed }
            if !shutdownSucceeded {
                fputs("WARN production service shutdown did not confirm call cleanup\n", stderr)
            }
        }

        guard waitUntil(timeout: 75, condition: {
            modem.isConnected && call.canDial
        }) else {
            try checkInterrupted()
            throw ProbeError.failed(
                call.lastError ?? modem.lastError ?? "module did not become ready for production dialing"
            )
        }
        try checkInterrupted()
        print("READY production ModemService reports dial capability")

        var dialResult: ModemActionResult?
        service.dial(options.number) { result in dialResult = result }
        guard waitUntil(timeout: 45, condition: { dialResult != nil }) else {
            try checkInterrupted()
            throw ProbeError.failed("production dial completion timed out")
        }
        guard case let .success(message) = dialResult! else {
            if case let .failure(message) = dialResult! {
                throw ProbeError.failed(message)
            }
            throw ProbeError.failed("production dial failed")
        }
        print("DIAL accepted: \(message ?? "no detail")")

        guard waitUntil(timeout: TimeInterval(options.observeSeconds), condition: {
            call.phase == .active && call.audioActive && call.uacMedia != nil
        }) else {
            try checkInterrupted()
            throw ProbeError.failed(
                call.lastError ?? "outgoing call never reached active CLCC plus verified UAC media start"
            )
        }
        guard var baseline = call.uacMedia else {
            throw ProbeError.failed("production UAC media baseline is unavailable")
        }
        print(
            "ACTIVE production call reached active CLCC and UAC; baseline " +
                "inputFrames=\(baseline.inputFrames) outputFrames=\(baseline.outputFrames) " +
                "signalSamples=\(baseline.inputSignalSamples) peakPCM16=\(baseline.inputPeakPCM16)"
        )

        if !options.dtmfSequence.isEmpty {
            let readyDeadline = Date().addingTimeInterval(TimeInterval(options.dtmfDelaySeconds))
            while Date() < readyDeadline {
                try checkInterrupted()
                guard call.phase == .active, call.audioActive, call.uacMedia != nil else {
                    throw ProbeError.failed("call or production audio stopped before DTMF validation")
                }
                runMainLoopSlice(0.05)
            }

            for (offset, tone) in options.dtmfSequence.enumerated() {
                guard call.canSendDTMF, call.audioActive, call.uacMedia != nil else {
                    throw ProbeError.failed("call stopped before DTMF key \(offset + 1)")
                }
                var dtmfResult: ModemActionResult?
                service.sendDTMF(tone) { result in dtmfResult = result }
                guard waitUntil(timeout: 6, condition: { dtmfResult != nil }) else {
                    throw ProbeError.failed("DTMF key \(offset + 1) completion timed out")
                }
                guard case .success = dtmfResult! else {
                    if case let .failure(message) = dtmfResult! {
                        throw ProbeError.failed("DTMF key \(offset + 1) failed: \(message)")
                    }
                    throw ProbeError.failed("DTMF key \(offset + 1) failed")
                }
                print("DTMF MODEM ACCEPTED index=\(offset + 1) of \(options.dtmfSequence.count)")

                if offset + 1 < options.dtmfSequence.count {
                    let gapDeadline = Date().addingTimeInterval(
                        TimeInterval(options.dtmfGapMilliseconds) / 1_000
                    )
                    while Date() < gapDeadline {
                        try checkInterrupted()
                        guard call.phase == .active, call.audioActive else {
                            throw ProbeError.failed("call stopped between DTMF keys")
                        }
                        runMainLoopSlice(0.05)
                    }
                }
            }
            guard call.phase == .active, call.audioActive, let postDTMF = call.uacMedia else {
                throw ProbeError.failed("call or production audio stopped after DTMF validation")
            }
            baseline = postDTMF
            print("DTMF PROVED modem accepted \(options.dtmfSequence.count) key(s); validating post-DTMF media")
        }

        let mediaDeadline = Date().addingTimeInterval(TimeInterval(options.mediaSeconds))
        var latest = baseline
        while Date() < mediaDeadline {
            try checkInterrupted()
            guard call.phase == .active, call.audioActive, let media = call.uacMedia else {
                throw ProbeError.failed(call.lastError ?? "call or production audio stopped during media window")
            }
            latest = media
            runMainLoopSlice(0.05)
        }
        let inputFrameDelta = latest.inputFrames >= baseline.inputFrames
            ? latest.inputFrames - baseline.inputFrames : 0
        let outputFrameDelta = latest.outputFrames >= baseline.outputFrames
            ? latest.outputFrames - baseline.outputFrames : 0
        let signalSampleDelta = latest.inputSignalSamples >= baseline.inputSignalSamples
            ? latest.inputSignalSamples - baseline.inputSignalSamples : 0
        guard inputFrameDelta > 0,
              outputFrameDelta > 0,
              signalSampleDelta > 0,
              latest.inputPeakPCM16 > latest.inputSignalThresholdPCM16 else {
            throw ProbeError.failed(
                "production UAC media proof failed: " +
                    "inputFrames=\(inputFrameDelta) " +
                    "outputFrames=\(outputFrameDelta) " +
                    "signalSamples=\(signalSampleDelta) " +
                    "peakPCM16=\(latest.inputPeakPCM16) " +
                    "thresholdPCM16=\(latest.inputSignalThresholdPCM16)"
            )
        }
        print(
            "MEDIA PROVED inputFrames=\(inputFrameDelta) " +
                "outputFrames=\(outputFrameDelta) " +
                "signalSamples=\(signalSampleDelta) " +
                "peakPCM16=\(latest.inputPeakPCM16)"
        )

        var hangupResult: ModemActionResult?
        service.hangUp { result in hangupResult = result }
        guard waitUntil(timeout: 45, condition: { hangupResult != nil }) else {
            throw ProbeError.failed("production hangup completion timed out")
        }
        guard case .success = hangupResult! else {
            if case let .failure(message) = hangupResult! {
                throw ProbeError.failed(message)
            }
            throw ProbeError.failed("production hangup failed")
        }
        guard waitUntil(timeout: 20, condition: { !call.hasCall }) else {
            throw ProbeError.failed("production service did not return to an idle call state")
        }
        let dtmfProof = options.dtmfSequence.isEmpty
            ? ""
            : ", \(options.dtmfSequence.count) DTMF command(s) accepted"
        print(
            "RESULT PASS production ModemService proved active CLCC\(dtmfProof), " +
                "nonzero UAC media, and confirmed hangup"
        )
    }

    private static func parseOptions(_ arguments: [String]) throws -> (
        number: String,
        observeSeconds: Int,
        mediaSeconds: Int,
        dtmfSequence: [String],
        dtmfDelaySeconds: Int,
        dtmfGapMilliseconds: Int
    ) {
        var number: String?
        var observeSeconds = 45
        var mediaSeconds = 10
        var dtmfSequence: [String]?
        var dtmfDelaySeconds = 3
        var dtmfGapMilliseconds = 500
        var confirmed = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            func value() throws -> String {
                guard index + 1 < arguments.count else {
                    throw ProbeError.usage("missing value after \(argument)")
                }
                return arguments[index + 1]
            }
            switch argument {
            case "--number":
                number = try value()
                index += 1
            case "--observe-seconds":
                guard let parsed = Int(try value()), (5 ... 180).contains(parsed) else {
                    throw ProbeError.usage("--observe-seconds must be 5...180")
                }
                observeSeconds = parsed
                index += 1
            case "--media-seconds":
                guard let parsed = Int(try value()), (5 ... 60).contains(parsed) else {
                    throw ProbeError.usage("--media-seconds must be 5...60")
                }
                mediaSeconds = parsed
                index += 1
            case "--dtmf-sequence":
                guard dtmfSequence == nil else {
                    throw ProbeError.usage("--dtmf-sequence may be supplied only once")
                }
                let raw = try value()
                let tones = raw.map(String.init)
                guard (1 ... 31).contains(tones.count),
                      tones.allSatisfy({ CallATParser.normalizedDTMFTone($0) != nil }) else {
                    throw ProbeError.usage("--dtmf-sequence must contain 1...31 ASCII 0-9, * or # keys")
                }
                dtmfSequence = tones
                index += 1
            case "--dtmf-delay-seconds":
                guard let parsed = Int(try value()), (0 ... 30).contains(parsed) else {
                    throw ProbeError.usage("--dtmf-delay-seconds must be 0...30")
                }
                dtmfDelaySeconds = parsed
                index += 1
            case "--dtmf-gap-ms":
                guard let parsed = Int(try value()), (100 ... 2_000).contains(parsed) else {
                    throw ProbeError.usage("--dtmf-gap-ms must be 100...2000")
                }
                dtmfGapMilliseconds = parsed
                index += 1
            case "--confirm-live-call":
                confirmed = true
            default:
                throw ProbeError.usage("unknown argument: \(argument)")
            }
            index += 1
        }
        guard confirmed else {
            throw ProbeError.usage("--confirm-live-call is required")
        }
        guard let number, let normalized = CallATParser.normalizedDialNumber(number) else {
            throw ProbeError.usage("a valid --number is required")
        }
        return (
            normalized,
            observeSeconds,
            mediaSeconds,
            dtmfSequence ?? [],
            dtmfDelaySeconds,
            dtmfGapMilliseconds
        )
    }

    private static func waitUntil(
        timeout: TimeInterval,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            if interrupted { return false }
            runMainLoopSlice(0.05)
        }
        return condition()
    }

    private static func runMainLoopSlice(_ seconds: TimeInterval) {
        _ = RunLoop.main.run(
            mode: .default,
            before: Date().addingTimeInterval(seconds)
        )
    }

    private static func checkInterrupted() throws {
        if interrupted { throw ProbeError.interrupted }
    }

    private static func describe(_ snapshot: CallSnapshot) -> String {
        "phase=\(snapshot.phase) number=\(snapshot.number ?? "none") " +
            "audio=\(snapshot.audioActive) muted=\(snapshot.muted) " +
            "error=\(snapshot.lastError ?? "none")"
    }
}
