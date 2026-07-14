import Foundation

enum CallPhase: String, Equatable {
    case unavailable
    case idle
    case incoming
    case dialing
    case alerting
    case active
    case ending
    case recovering
    case error
}

enum CallDirection: String, Equatable {
    case outgoing
    case incoming
}

enum CallEndReason: String, Equatable {
    case localHangup
    case remoteHangup
    case busy
    case noAnswer
    case noDialTone
    case deviceDisconnected
    case failed

    var localizedDescription: String {
        switch self {
        case .localHangup: return "通话已结束"
        case .remoteHangup: return "对方已挂断"
        case .busy: return "对方忙线"
        case .noAnswer: return "无人接听"
        case .noDialTone: return "网络未提供拨号音"
        case .deviceDisconnected: return "模块已拔出，通话结束"
        case .failed: return "通话失败"
        }
    }
}

struct UACMediaSnapshot: Equatable {
    var inputFrames: UInt64 = 0
    var outputFrames: UInt64 = 0
    var inputTotalSamples: UInt64 = 0
    var inputSignalSamples: UInt64 = 0
    var inputPeakPCM16: UInt32 = 0
    var inputSignalThresholdPCM16: UInt32 = 0
}

struct CallSnapshot: Equatable {
    var phase: CallPhase = .unavailable
    var direction: CallDirection?
    var number: String?
    var voiceOverUSBSupported = false
    var audioActive = false
    var muted = false
    var startedAt: Date?
    var lastEndReason: CallEndReason?
    var lastError: String?
    var controlInterfaceBusy = false
    var mediaCleanupPending = false
    var uacMedia: UACMediaSnapshot?

    var hasCall: Bool {
        switch phase {
        case .incoming, .dialing, .alerting, .active, .ending, .recovering:
            return true
        case .unavailable, .idle, .error:
            return false
        }
    }

    var canDial: Bool {
        phase == .idle && voiceOverUSBSupported && !mediaCleanupPending
    }

    var canSendDTMF: Bool {
        phase == .active
    }
}

enum ModemCallStatus: Int, Equatable {
    case active = 0
    case held = 1
    case dialing = 2
    case alerting = 3
    case incoming = 4
    case waiting = 5
}

struct ModemCallInfo: Equatable {
    let index: Int
    let direction: CallDirection
    let status: ModemCallStatus
    let isVoice: Bool
    let isMultiparty: Bool
    let number: String?
}

enum ModemCallEvent: Equatable {
    case ring
    case callerID(String)
    case callInfo(ModemCallInfo)
    case connected
    case ended(CallEndReason)
    case pcmFlowReady(Bool)
}
