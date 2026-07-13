import CModemBridge
import Foundation

private struct StoredReference: Decodable, Hashable {
    let storage: String
    let index: Int
    let rawPDU: String
}

private struct StoredMessage: Decodable {
    let id: String
    let sender: String
    let modemReferences: [StoredReference]?
}

private struct CommandResult {
    let code: Int32
    let output: String
    let bridgeError: String?

    var lines: [String] {
        output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var isSuccess: Bool {
        let upper = lines.map { $0.uppercased() }
        return code == MAVO_MODEM_OK && bridgeError == nil && upper.contains("OK") &&
            !upper.contains(where: { $0 == "ERROR" || $0.hasPrefix("+CMS ERROR:") || $0.hasPrefix("+CME ERROR:") })
    }
}

private enum Inspection {
    case exact
    case absent
    case different
    case unknown(String)
}

private final class Probe {
    private let modem: OpaquePointer

    init() throws {
        guard let modem = mavo_modem_create() else {
            throw NSError(domain: "MaVoSMSDeleteProbe", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "无法创建 AT 桥接器"
            ])
        }
        self.modem = modem
    }

    deinit {
        mavo_modem_close(modem)
        mavo_modem_destroy(modem)
    }

    func runVoiceDiagnostics() -> Int32 {
        let openCode = mavo_modem_open(modem)
        guard openCode == MAVO_MODEM_OK else {
            print("FAIL 无法打开 AT 接口 code=\(openCode) error=\(lastError())")
            return 31
        }
        print(String(
            format: "DEVICE %04X:%04X location=0x%08X AT_OUT=0x%02X AT_IN=0x%02X",
            mavo_modem_vendor_id(modem),
            mavo_modem_product_id(modem),
            mavo_modem_location_id(modem),
            mavo_modem_output_endpoint(modem),
            mavo_modem_input_endpoint(modem)
        ))
        _ = command("ATE0", timeout: 2_000)
        _ = command("AT+CMEE=2", timeout: 2_000)
        let commands = [
            "AT+CPIN?",
            "AT+COPS?",
            "AT+CREG?",
            "AT+CGREG?",
            "AT+CEREG?",
            "AT+QNWINFO",
            "AT+QCSQ",
            "AT+QENG=\"servingcell\"",
            "AT+CLIP?",
            "AT+CRC?",
            "AT+QCFG=\"ims\"",
            "AT+QCFG=\"volte_disable\"",
            "AT+QMBNCFG=\"AutoSel\"",
            "AT+QMBNCFG=\"List\"",
            "AT+CGDCONT?",
            "AT+QIMSREG?",
            "AT$QCPDPIMSCFGE?",
            "AT+CLCC",
            "AT+CEER"
        ]
        for value in commands {
            let result = command(value, timeout: value.contains("QMBNCFG") ? 8_000 : 5_000)
            let response = result.lines
                .filter { $0.uppercased() != value.uppercased() }
                .joined(separator: " | ")
            print("QUERY \(value) => code=\(result.code) \(response.isEmpty ? terminalDescription(result) : response)")
            if result.code != MAVO_MODEM_OK {
                print("RESULT INCOMPLETE transport failed during read-only diagnostics")
                return 32
            }
        }
        print("RESULT PASS read-only voice registration diagnostics complete")
        return 0
    }

    func setIMSModeAndRestart(_ targetMode: Int) -> Int32 {
        guard targetMode == 0 || targetMode == 1 else {
            print("RESULT FAIL unsupported IMS mode \(targetMode)")
            return 40
        }
        let openCode = mavo_modem_open(modem)
        guard openCode == MAVO_MODEM_OK else {
            print("FAIL 无法打开 AT 接口 code=\(openCode) error=\(lastError())")
            return 41
        }
        print(String(
            format: "DEVICE %04X:%04X location=0x%08X AT_OUT=0x%02X AT_IN=0x%02X",
            mavo_modem_vendor_id(modem),
            mavo_modem_product_id(modem),
            mavo_modem_location_id(modem),
            mavo_modem_output_endpoint(modem),
            mavo_modem_input_endpoint(modem)
        ))
        _ = command("ATE0", timeout: 2_000)
        _ = command("AT+CMEE=2", timeout: 2_000)
        guard noActiveCall() else {
            print("RESULT FAIL IMS was not changed")
            return 42
        }

        let before = command("AT+QCFG=\"ims\"", timeout: 5_000)
        guard before.isSuccess, let beforeMode = parseIMSMode(before.output) else {
            print("RESULT FAIL cannot read current IMS mode; no write sent")
            return 43
        }
        print("IMS BEFORE mode=\(beforeMode)")
        if beforeMode != targetMode {
            let write = command("AT+QCFG=\"ims\",\(targetMode)", timeout: 8_000)
            guard write.isSuccess else {
                print("RESULT FAIL IMS mode write rejected: \(terminalDescription(write))")
                return 44
            }
            print("WRITE PASS AT+QCFG=\"ims\",\(targetMode)")
        } else {
            print("WRITE SKIP IMS already mode=\(targetMode)")
        }

        let verified = command("AT+QCFG=\"ims\"", timeout: 5_000)
        guard verified.isSuccess, parseIMSMode(verified.output) == targetMode else {
            print("RESULT FAIL IMS write did not read back as mode \(targetMode); restart not sent")
            return 45
        }
        print("VERIFY PASS IMS mode=\(targetMode)")

        if targetMode == 1 {
            let volte = command("AT+QCFG=\"volte_disable\"", timeout: 5_000)
            guard volte.isSuccess,
                  volte.lines.contains(where: {
                      let compact = $0.replacingOccurrences(of: " ", with: "").lowercased()
                      return compact.contains("volte/disable\",0") || compact.contains("volte_disable\",0")
                  }) else {
                print("RESULT FAIL VoLTE-disable state is not confirmed as 0; restart not sent")
                return 46
            }
            print("VERIFY PASS VoLTE disable=0")
        }

        print("RESTART sending AT+CFUN=1,1")
        let restart = command("AT+CFUN=1,1", timeout: 12_000)
        if restart.isSuccess {
            print("RESTART ACK OK")
            return 0
        }
        // USB can disappear before the terminal OK reaches the host. The caller
        // must verify re-enumeration and read back IMS after this point.
        print("RESTART ACK AMBIGUOUS code=\(restart.code) error=\(terminalDescription(restart))")
        return 47
    }

    func run(message: StoredMessage) -> Int32 {
        guard var references = message.modemReferences, !references.isEmpty else {
            print("FAIL 本地记录没有模块短信引用")
            return 20
        }
        var seen: Set<StoredReference> = []
        references = references
            .filter { seen.insert($0).inserted }
            .sorted {
                if $0.storage.uppercased() != $1.storage.uppercased() {
                    return $0.storage.uppercased() < $1.storage.uppercased()
                }
                return $0.index > $1.index
            }
        guard references.allSatisfy({ reference in
            ["SM", "ME", "MT"].contains(reference.storage.uppercased()) &&
                reference.index >= 0 && isHex(reference.rawPDU)
        }) else {
            print("FAIL 本地短信引用格式无效")
            return 20
        }

        let openCode = mavo_modem_open(modem)
        guard openCode == MAVO_MODEM_OK else {
            print("FAIL 无法打开 AT 接口 code=\(openCode) error=\(lastError())")
            return 21
        }
        print(String(
            format: "DEVICE %04X:%04X location=0x%08X AT_OUT=0x%02X AT_IN=0x%02X",
            mavo_modem_vendor_id(modem),
            mavo_modem_product_id(modem),
            mavo_modem_location_id(modem),
            mavo_modem_output_endpoint(modem),
            mavo_modem_input_endpoint(modem)
        ))

        _ = command("ATE0", timeout: 2_000)
        _ = command("AT+CMEE=2", timeout: 2_000)
        guard noActiveCall() else { return 22 }

        print("TARGET sender=\(message.sender) fragments=\(references.count) order=" +
            references.map { "\($0.storage.uppercased()):\($0.index)" }.joined(separator: ","))

        // Complete the entire read-only preflight before the first deletion.
        for reference in references {
            guard selectStorage(reference.storage) else { return 23 }
            switch inspect(index: reference.index, expectedPDU: reference.rawPDU) {
            case .exact:
                print("PREFLIGHT PASS \(reference.storage.uppercased()):\(reference.index) exact PDU")
            case .absent:
                print("PREFLIGHT SKIP \(reference.storage.uppercased()):\(reference.index) already absent")
            case .different:
                print("PREFLIGHT FAIL \(reference.storage.uppercased()):\(reference.index) contains another SMS; no deletion sent")
                return 24
            case let .unknown(error):
                print("PREFLIGHT FAIL \(reference.storage.uppercased()):\(reference.index) \(error); no deletion sent")
                return 24
            }
        }

        for reference in references {
            guard noActiveCall(), selectStorage(reference.storage) else { return 25 }
            var targetIndex = reference.index
            switch inspect(index: targetIndex, expectedPDU: reference.rawPDU) {
            case .exact:
                break
            case .absent, .different:
                let matches = matchingIndexes(storage: reference.storage, expectedPDU: reference.rawPDU)
                guard matches.count <= 1 else {
                    print("DELETE ABORT \(reference.storage.uppercased()):\(reference.index) found multiple exact PDU matches")
                    return 26
                }
                guard let relocated = matches.first else {
                    print("DELETE SKIP \(reference.storage.uppercased()):\(reference.index) already absent")
                    continue
                }
                targetIndex = relocated
                print("DELETE RELOCATED \(reference.storage.uppercased()):\(reference.index) -> \(targetIndex)")
            case let .unknown(error):
                print("DELETE ABORT \(reference.storage.uppercased()):\(reference.index) \(error)")
                return 26
            }

            var deleted = false
            for attempt in 1...4 {
                guard noActiveCall(), selectStorage(reference.storage) else { return 25 }
                switch inspect(index: targetIndex, expectedPDU: reference.rawPDU) {
                case .absent, .different:
                    deleted = matchingIndexes(storage: reference.storage, expectedPDU: reference.rawPDU).isEmpty
                    if deleted { break }
                case .exact:
                    Thread.sleep(forTimeInterval: 0.12)
                    let result = command("AT+CMGD=\(targetIndex),0", timeout: 6_000)
                    print("DELETE attempt=\(attempt) \(reference.storage.uppercased()):\(targetIndex) result=\(result.isSuccess ? "OK" : terminalDescription(result))")
                    guard result.code == MAVO_MODEM_OK else {
                        print("FAIL 删除响应不明确；不盲目重发")
                        return 27
                    }
                    Thread.sleep(forTimeInterval: 0.35)
                    deleted = matchingIndexes(storage: reference.storage, expectedPDU: reference.rawPDU).isEmpty
                    if deleted { break }
                case let .unknown(error):
                    print("VERIFY attempt=\(attempt) unknown=\(error)")
                }
                Thread.sleep(forTimeInterval: 0.4)
            }
            guard deleted else {
                print("FAIL 分片仍存在 \(reference.storage.uppercased()):\(reference.index)")
                return 28
            }
            print("VERIFY PASS fragment absent \(reference.storage.uppercased()):\(reference.index)")
        }

        Thread.sleep(forTimeInterval: 0.5)
        for reference in references {
            guard matchingIndexes(storage: reference.storage, expectedPDU: reference.rawPDU).isEmpty else {
                print("FINAL FAIL exact PDU remains for \(reference.storage.uppercased()):\(reference.index)")
                return 29
            }
        }
        print("RESULT PASS all exact PDU fragments are absent")
        return 0
    }

    private func noActiveCall() -> Bool {
        let result = command("AT+CLCC", timeout: 3_000)
        guard result.isSuccess else {
            print("CALL PREFLIGHT FAIL \(terminalDescription(result)); no deletion sent")
            return false
        }
        let callLines = result.lines.filter { $0.uppercased().hasPrefix("+CLCC:") }
        var hasVoiceCall = false
        for line in callLines {
            let fields = line.dropFirst("+CLCC:".count).split(separator: ",")
            let safeFields = fields.prefix(5).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            print("CALL STATE index,dir,status,mode,mpty=" + safeFields.joined(separator: ","))
            if fields.count >= 4,
               Int(fields[3].trimmingCharacters(in: .whitespacesAndNewlines)) == 0 {
                hasVoiceCall = true
            }
        }
        if hasVoiceCall {
            print("CALL PREFLIGHT FAIL active voice call present")
            return false
        }
        print(callLines.isEmpty
            ? "CALL PREFLIGHT PASS no active call"
            : "CALL PREFLIGHT PASS data sessions present, no voice call")
        return true
    }

    private func selectStorage(_ storage: String) -> Bool {
        let normalized = storage.uppercased()
        let result = command("AT+CPMS=\"\(normalized)\"", timeout: 4_000)
        if !result.isSuccess {
            print("STORAGE FAIL \(normalized) \(terminalDescription(result))")
        }
        return result.isSuccess
    }

    private func inspect(index: Int, expectedPDU: String) -> Inspection {
        let result = command("AT+CMGR=\(index)", timeout: 4_000)
        if result.isSuccess {
            if let pdu = parseCMGR(result.output) {
                return pdu.caseInsensitiveCompare(expectedPDU) == .orderedSame ? .exact : .different
            }
            let lines = result.lines
                .map { $0.uppercased() }
                .filter { $0 != "AT+CMGR=\(index)" }
            if lines == ["OK"] { return .absent }
            let summary = result.lines.map { line in
                isHex(line) ? "<hex chars=\(line.count)>" : line
            }.joined(separator: " | ")
            return .unknown("无法解析 CMGR [\(summary)]")
        }
        let upper = result.lines.map { $0.uppercased() }
        if upper.contains(where: { $0.contains("+CMS ERROR: 321") || $0.contains("INVALID MEMORY INDEX") }) {
            return .absent
        }
        return .unknown(terminalDescription(result))
    }

    private func matchingIndexes(storage: String, expectedPDU: String) -> [Int] {
        guard selectStorage(storage) else { return [] }
        let result = command("AT+CMGL=4", timeout: 10_000, capacity: 256 * 1_024)
        guard result.isSuccess else {
            print("ENUMERATE FAIL \(storage.uppercased()) \(terminalDescription(result))")
            return []
        }
        return parseCMGL(result.output)
            .filter { $0.pdu.caseInsensitiveCompare(expectedPDU) == .orderedSame }
            .map(\.index)
    }

    private func command(_ value: String, timeout: Int, capacity: Int = 64 * 1_024) -> CommandResult {
        var buffer = [CChar](repeating: 0, count: capacity)
        let code = buffer.withUnsafeMutableBufferPointer { pointer in
            mavo_modem_command(modem, value, Int32(timeout), pointer.baseAddress, pointer.count)
        }
        return CommandResult(
            code: code,
            output: String(cString: buffer),
            bridgeError: code == MAVO_MODEM_OK ? nil : lastError()
        )
    }

    private func lastError() -> String {
        guard let value = mavo_modem_last_error(modem) else { return "unknown bridge error" }
        return String(cString: value)
    }
}

private func parseCMGR(_ response: String) -> String? {
    let lines = normalizedLines(response)
    guard let header = lines.firstIndex(where: { $0.hasPrefix("+CMGR:") }),
          let length = Int(lines[header].split(separator: ",").last?.trimmingCharacters(in: .whitespaces) ?? ""),
          let pdu = lines.dropFirst(header + 1).first(where: isHex) else { return nil }
    return trimPDU(pdu, tpduLength: length)
}

private func parseIMSMode(_ response: String) -> Int? {
    for line in normalizedLines(response) where line.uppercased().hasPrefix("+QCFG:") {
        let fields = line.split(separator: ",")
        guard fields.count >= 2,
              fields[0].lowercased().contains("ims"),
              let mode = Int(fields[1].trimmingCharacters(in: .whitespacesAndNewlines)) else {
            continue
        }
        return mode
    }
    return nil
}

private func parseCMGL(_ response: String) -> [(index: Int, pdu: String)] {
    let lines = normalizedLines(response)
    var result: [(Int, String)] = []
    for index in lines.indices where lines[index].hasPrefix("+CMGL:") {
        let fields = lines[index].dropFirst("+CMGL:".count).split(separator: ",")
        guard let messageIndex = fields.first.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }),
              let length = fields.last.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }),
              index + 1 < lines.count,
              let pduLine = lines[(index + 1)...].first(where: { isHex($0) }),
              let pdu = trimPDU(pduLine, tpduLength: length) else { continue }
        result.append((messageIndex, pdu))
    }
    return result
}

private func normalizedLines(_ value: String) -> [String] {
    value.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

private func trimPDU(_ pdu: String, tpduLength: Int) -> String? {
    guard let bytes = hexBytes(pdu), let smscLength = bytes.first.map(Int.init) else { return nil }
    let expected = 1 + smscLength + tpduLength
    guard expected > 0, expected <= bytes.count else { return nil }
    return bytes.prefix(expected).map { String(format: "%02X", $0) }.joined()
}

private func hexBytes(_ value: String) -> [UInt8]? {
    let value = value.uppercased()
    guard isHex(value) else { return nil }
    var result: [UInt8] = []
    var cursor = value.startIndex
    while cursor < value.endIndex {
        let next = value.index(cursor, offsetBy: 2)
        guard let byte = UInt8(value[cursor..<next], radix: 16) else { return nil }
        result.append(byte)
        cursor = next
    }
    return result
}

private func isHex(_ value: String) -> Bool {
    !value.isEmpty && value.count.isMultiple(of: 2) &&
        value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789ABCDEFabcdef").contains($0) }
}

private func terminalDescription(_ result: CommandResult) -> String {
    result.bridgeError ?? result.lines.first(where: {
        let upper = $0.uppercased()
        return upper == "ERROR" || upper.hasPrefix("+CMS ERROR:") || upper.hasPrefix("+CME ERROR:")
    }) ?? "unknown response"
}

private func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else {
        return nil
    }
    return CommandLine.arguments[index + 1]
}

private func removeLocalMessage(id: String, at filePath: String) throws {
    let url = URL(fileURLWithPath: filePath)
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let data = try Data(contentsOf: url)
    guard let messages = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        throw NSError(domain: "MaVoSMSDeleteProbe", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "本地短信文件不是有效数组"
        ])
    }
    let retained = messages.filter { ($0["id"] as? String) != id }
    guard retained.count != messages.count else { return }
    let updated = try JSONSerialization.data(
        withJSONObject: retained,
        options: [.prettyPrinted, .sortedKeys]
    )
    try updated.write(to: url, options: .atomic)
    print("LOCAL REMOVE PASS \(url.lastPathComponent)")
}

do {
    let probe = try Probe()
    if CommandLine.arguments.contains("--voice-diagnostics") {
        exit(probe.runVoiceDiagnostics())
    }
    if CommandLine.arguments.contains("--enable-ims") {
        exit(probe.setIMSModeAndRestart(1))
    }
    if CommandLine.arguments.contains("--restore-ims-zero") {
        exit(probe.setIMSModeAndRestart(0))
    }

    guard let messageID = argument("--message-id") else {
        fputs("usage: MaVoSMSDeleteProbe --voice-diagnostics | --enable-ims | --restore-ims-zero | --message-id ID [--messages-file PATH]\n", stderr)
        exit(64)
    }
    let defaultFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MaVo/messages.json").path
    let filePath = argument("--messages-file") ?? defaultFile
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
          let messages = try? JSONDecoder().decode([StoredMessage].self, from: data),
          let message = messages.first(where: { $0.id == messageID }) else {
        fputs("FAIL 找不到指定短信或无法读取消息文件\n", stderr)
        exit(65)
    }

    let result = probe.run(message: message)
    if result == 0, CommandLine.arguments.contains("--remove-local-on-success") {
        try removeLocalMessage(id: messageID, at: filePath)
        let backupPath = URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("messages.backup.json").path
        try removeLocalMessage(id: messageID, at: backupPath)
    }
    exit(result)
} catch {
    fputs("FAIL \(error.localizedDescription)\n", stderr)
    exit(70)
}
