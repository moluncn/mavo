import Foundation

struct ATConsoleExecutionResult: Equatable, Identifiable {
    let id = UUID()
    let command: String
    let output: String
    let error: String?
    let elapsedMilliseconds: Int
    let timestamp: Date

    var isSuccess: Bool { error == nil }
}

enum ATConsoleCommandError: LocalizedError, Equatable {
    case empty
    case tooLong
    case multiline
    case nonASCII
    case missingPrefix
    case interactivePrompt(String)
    case managedCallCommand

    var errorDescription: String? {
        switch self {
        case .empty:
            return "请输入 AT 命令。"
        case .tooLong:
            return "单条 AT 命令不能超过 512 个字符。"
        case .multiline:
            return "这里只支持单行 AT 命令，不能包含换行或 NUL。"
        case .nonASCII:
            return "AT 命令只能包含可打印 ASCII 字符。"
        case .missingPrefix:
            return "命令必须以 AT 开头。"
        case let .interactivePrompt(name):
            return "\(name) 会进入数据提示符；请使用应用内对应功能，控制台不发送后续载荷。"
        case .managedCallCommand:
            return "拨号、接听、挂断和 DTMF 必须使用电话界面，避免绕过通话音频和状态管理。"
        }
    }
}

enum ATConsoleCommandValidator {
    static func validate(_ rawValue: String) throws -> String {
        guard !rawValue.contains("\r"),
              !rawValue.contains("\n"),
              !rawValue.contains("\0") else {
            throw ATConsoleCommandError.multiline
        }
        let command = rawValue.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { throw ATConsoleCommandError.empty }
        guard command.utf8.count <= 512 else { throw ATConsoleCommandError.tooLong }
        guard command.unicodeScalars.allSatisfy({ (0x20 ... 0x7E).contains($0.value) }) else {
            throw ATConsoleCommandError.nonASCII
        }

        let uppercase = command.uppercased()
        guard uppercase.hasPrefix("AT") else { throw ATConsoleCommandError.missingPrefix }

        let compact = uppercase.replacingOccurrences(of: " ", with: "")
        if compact == "ATA" || compact == "ATH" || compact.hasPrefix("ATD") ||
            compact.hasPrefix("AT+VTS") {
            throw ATConsoleCommandError.managedCallCommand
        }

        let promptCommands = [
            "AT+CMGS", "AT+CMGW", "AT+QFUPL", "AT+QHTTPURL",
            "AT+QHTTPPOST", "AT+QHTTPPUT", "AT+QISEND", "AT+QSSLSEND",
            "AT+QSMTPBODY", "AT+QFTPPUT"
        ]
        if let promptCommand = promptCommands.first(where: {
            compact.hasPrefix($0 + "=") && !compact.hasPrefix($0 + "=?")
        }) {
            throw ATConsoleCommandError.interactivePrompt(promptCommand)
        }
        return command
    }
}
