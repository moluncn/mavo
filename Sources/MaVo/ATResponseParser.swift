import Foundation

enum ATResponseParser {
    static func normalizedLines(_ response: String) -> [String] {
        response
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func parseUSBNetMode(_ response: String) -> Int? {
        guard let line = normalizedLines(response).first(where: { $0.contains("+QCFG:") && $0.contains("usbnet") }) else {
            return nil
        }
        let values = line.split(separator: ",")
        guard let last = values.last else { return nil }
        return Int(last.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func parseUSBConfiguration(_ response: String) -> ModemUSBConfiguration? {
        guard let line = normalizedLines(response).first(where: {
            $0.lowercased().contains("+qcfg:") && $0.lowercased().contains("\"usbcfg\"")
        }) else {
            return nil
        }
        let payload = String(line.dropFirst("+QCFG:".count))
        let fields = splitCSV(payload)
        guard fields.count == 10,
              unquote(fields[0]).lowercased() == "usbcfg",
              let vendorID = parseFlexibleInteger(fields[1]),
              let productID = parseFlexibleInteger(fields[2]) else {
            return nil
        }
        let flags = fields[3 ... 9].compactMap(parseBooleanInteger)
        guard flags.count == 7 else { return nil }
        return ModemUSBConfiguration(
            vendorID: vendorID,
            productID: productID,
            diagnosticEnabled: flags[0],
            nmeaEnabled: flags[1],
            atPortEnabled: flags[2],
            modemEnabled: flags[3],
            networkEnabled: flags[4],
            adbEnabled: flags[5],
            audioEnabled: flags[6]
        )
    }

    static func parseIMSMode(_ response: String) -> Int? {
        guard let line = normalizedLines(response).first(where: {
            $0.uppercased().contains("+QCFG:") && $0.lowercased().contains("\"ims\"")
        }) else {
            return nil
        }
        let payload = String(line.dropFirst("+QCFG:".count))
        let fields = splitCSV(payload)
        guard fields.count >= 2,
              unquote(fields[0]).lowercased() == "ims",
              let mode = Int(fields[1].trimmingCharacters(in: .whitespaces)),
              (0 ... 2).contains(mode) else {
            return nil
        }
        return mode
    }

    static func parseVoLTEDisabled(_ response: String) -> Bool? {
        guard let line = normalizedLines(response).first(where: {
            let normalized = $0.lowercased().replacingOccurrences(of: "_", with: "/")
            return normalized.contains("+qcfg:") && normalized.contains("\"volte/disable\"")
        }) else {
            return nil
        }
        let payload = String(line.dropFirst("+QCFG:".count))
        let fields = splitCSV(payload)
        guard fields.count >= 2,
              unquote(fields[0]).lowercased().replacingOccurrences(of: "_", with: "/") == "volte/disable",
              let value = Int(fields[1].trimmingCharacters(in: .whitespaces)),
              value == 0 || value == 1 else {
            return nil
        }
        return value == 1
    }

    static func parseSIMReady(_ response: String) -> Bool {
        normalizedLines(response).contains { line in
            line.uppercased().contains("+CPIN: READY")
        }
    }

    static func parseSubscriberNumber(_ response: String) -> String? {
        for line in normalizedLines(response) where line.uppercased().hasPrefix("+CNUM:") {
            let fields = splitCSV(String(line.dropFirst("+CNUM:".count)))
            guard fields.count >= 2 else { continue }
            let rawNumber = unquote(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            let digits = rawNumber.unicodeScalars.compactMap { scalar -> Character? in
                guard scalar.value >= 48, scalar.value <= 57 else { return nil }
                return Character(String(scalar))
            }
            guard (5 ... 20).contains(digits.count) else { continue }

            let typeOfNumber = fields.count > 2
                ? Int(fields[2].trimmingCharacters(in: .whitespacesAndNewlines))
                : nil
            let normalizedDigits = String(digits)
            if rawNumber.hasPrefix("+") || typeOfNumber == 145 {
                return "+" + normalizedDigits
            }
            return normalizedDigits
        }
        return nil
    }

    static func parseICCID(_ response: String) -> String? {
        for line in normalizedLines(response) {
            let uppercased = line.uppercased()
            let candidate: String
            if uppercased.hasPrefix("+QCCID:") {
                candidate = String(line.dropFirst("+QCCID:".count))
            } else if uppercased.hasPrefix("+CCID:") {
                candidate = String(line.dropFirst("+CCID:".count))
            } else {
                candidate = line
            }
            let normalized = unquote(candidate)
                .filter { $0 >= "0" && $0 <= "9" }
            if (15 ... 24).contains(normalized.count) {
                return normalized
            }
        }
        return nil
    }

    static func parseOperator(_ response: String) -> (name: String?, technology: String?) {
        guard let line = normalizedLines(response).first(where: { $0.hasPrefix("+COPS:") }) else {
            return (nil, nil)
        }

        let payload = line.dropFirst("+COPS:".count)
        let fields = splitCSV(String(payload))
        let rawName = fields.count > 2 ? unquote(fields[2]) : ""
        let name = rawName.isEmpty ? nil : CarrierNameFormatter.localized(rawName)
        let technologyCode = fields.count > 3 ? Int(fields[3].trimmingCharacters(in: .whitespaces)) : nil
        return (name, accessTechnologyName(technologyCode))
    }

    static func parseQCSQ(_ response: String) -> (dbm: Int, technology: String, detail: String)? {
        guard let line = normalizedLines(response).first(where: { $0.hasPrefix("+QCSQ:") }) else {
            return nil
        }
        let payload = String(line.dropFirst("+QCSQ:".count))
        let fields = splitCSV(payload)
        guard fields.count >= 2 else { return nil }

        let technology = unquote(fields[0]).uppercased()
        let numbers = fields.dropFirst().compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let rssi = numbers.first, rssi != -125 else { return nil }

        if technology.contains("LTE"), numbers.count >= 4 {
            let rsrp = numbers[1]
            let rsrq = numbers[3]
            let primary = (-140 ... -44).contains(rsrp) ? rsrp : rssi
            return (primary, technology, "RSSI \(rssi) · RSRP \(rsrp) · RSRQ \(rsrq)")
        }

        return (rssi, technology, "RSSI \(rssi) dBm")
    }

    static func parseCSQ(_ response: String) -> Int? {
        guard let line = normalizedLines(response).first(where: { $0.hasPrefix("+CSQ:") }) else {
            return nil
        }
        let payload = line.dropFirst("+CSQ:".count)
        guard let first = payload.split(separator: ",").first,
              let rssi = Int(first.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        if (0 ... 31).contains(rssi) {
            return -113 + (2 * rssi)
        }
        if (100 ... 191).contains(rssi) {
            return rssi - 216
        }
        return nil
    }

    static func parseCMGL(_ response: String) -> [ModemStoredPDU] {
        let lines = normalizedLines(response)
        var result: [ModemStoredPDU] = []
        var position = 0

        while position < lines.count {
            let line = lines[position]
            guard line.hasPrefix("+CMGL:") else {
                position += 1
                continue
            }

            let payload = String(line.dropFirst("+CMGL:".count))
            let fields = splitCSV(payload)
            guard fields.count >= 4,
                  let index = Int(fields[0].trimmingCharacters(in: .whitespaces)),
                  let status = parseMessageStatus(fields[1]),
                  let declaredLength = fields.last.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }),
                  declaredLength >= 0 else {
                position += 1
                continue
            }

            var pduLinePosition = position + 1
            while pduLinePosition < lines.count {
                let candidate = lines[pduLinePosition]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate.hasPrefix("+CMGL:") || candidate == "OK" || candidate == "ERROR" {
                    break
                }
                if isHex(candidate) {
                    if let trimmed = trimPDU(candidate, tpduLength: declaredLength) {
                        result.append(
                            ModemStoredPDU(
                                index: index,
                                status: status,
                                declaredLength: declaredLength,
                                rawPDU: trimmed,
                                storage: nil
                            )
                        )
                    }
                    position = pduLinePosition
                    break
                }
                pduLinePosition += 1
            }
            position += 1
        }

        return result
    }

    static func parseCMGR(_ response: String) -> String? {
        let lines = normalizedLines(response)
        guard let headerIndex = lines.firstIndex(where: { $0.hasPrefix("+CMGR:") }) else {
            return nil
        }
        let payload = String(lines[headerIndex].dropFirst("+CMGR:".count))
        let fields = splitCSV(payload)
        guard fields.count >= 2,
              let declaredLength = fields.last.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }),
              declaredLength >= 0 else {
            return nil
        }
        for candidate in lines.dropFirst(headerIndex + 1) {
            if candidate == "OK" || candidate == "ERROR" || candidate.hasPrefix("+") {
                break
            }
            if isHex(candidate) {
                return trimPDU(candidate, tpduLength: declaredLength)
            }
        }
        return nil
    }

    static func parseCMTI(_ response: String) -> [(storage: String, index: Int)] {
        normalizedLines(response).compactMap { line in
            guard line.hasPrefix("+CMTI:") else { return nil }
            let fields = splitCSV(String(line.dropFirst("+CMTI:".count)))
            guard fields.count >= 2,
                  let index = Int(fields[1].trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            let storage = unquote(fields[0]).uppercased()
            guard ["SM", "ME", "MT"].contains(storage) else { return nil }
            return (storage, index)
        }
    }

    static func parseDirectCMT(_ response: String) -> [String] {
        let lines = normalizedLines(response)
        var pdus: [String] = []
        for index in lines.indices where lines[index].hasPrefix("+CMT:") {
            let fields = splitCSV(String(lines[index].dropFirst("+CMT:".count)))
            guard let length = fields.last.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }),
                  length >= 0,
                  index + 1 < lines.count,
                  isHex(lines[index + 1]),
                  let pdu = trimPDU(lines[index + 1], tpduLength: length) else {
                continue
            }
            pdus.append(pdu)
        }
        return pdus
    }

    static func parseCPMSStorage(_ response: String) -> String? {
        guard let line = normalizedLines(response).first(where: { $0.hasPrefix("+CPMS:") }) else {
            return nil
        }
        let fields = splitCSV(String(line.dropFirst("+CPMS:".count)))
        guard let first = fields.first else { return nil }
        let storage = unquote(first).uppercased()
        return ["SM", "ME", "MT"].contains(storage) ? storage : nil
    }

    static func splitCSV(_ value: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var isQuoted = false

        for character in value {
            if character == "\"" {
                isQuoted.toggle()
                current.append(character)
            } else if character == "," && !isQuoted {
                fields.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))
        return fields
    }

    private static func unquote(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.first == "\"", trimmed.last == "\"" else {
            return trimmed
        }
        return String(trimmed.dropFirst().dropLast())
    }

    private static func parseFlexibleInteger(_ value: String) -> Int? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("0x") {
            return Int(normalized.dropFirst(2), radix: 16)
        }
        return Int(normalized)
    }

    private static func parseBooleanInteger(_ value: String) -> Bool? {
        guard let parsed = parseFlexibleInteger(value), parsed == 0 || parsed == 1 else { return nil }
        return parsed == 1
    }

    private static func accessTechnologyName(_ code: Int?) -> String? {
        switch code {
        case 0: return "GSM"
        case 2: return "UTRAN"
        case 3: return "EDGE"
        case 4: return "HSDPA"
        case 5: return "HSUPA"
        case 6: return "HSPA"
        case 7: return "LTE"
        case 8: return "EC-GSM-IoT"
        case 9: return "NB-IoT"
        case 10: return "LTE-M"
        case 11: return "NR 5G"
        default: return nil
        }
    }

    private static func isHex(_ value: String) -> Bool {
        guard !value.isEmpty, value.count.isMultiple(of: 2) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48 ... 57, 65 ... 70, 97 ... 102: return true
            default: return false
            }
        }
    }

    private static func parseMessageStatus(_ value: String) -> Int? {
        let normalized = unquote(value).uppercased()
        if let numeric = Int(normalized) { return numeric }
        switch normalized {
        case "REC UNREAD": return 0
        case "REC READ": return 1
        case "STO UNSENT": return 2
        case "STO SENT": return 3
        case "ALL": return 4
        default: return nil
        }
    }

    private static func trimPDU(_ pdu: String, tpduLength: Int) -> String? {
        let uppercase = pdu.uppercased()
        guard let bytes = hexBytes(uppercase),
              let smscLength = bytes.first.map(Int.init) else {
            return nil
        }
        let expected = 1 + smscLength + tpduLength
        guard expected > 0, expected <= bytes.count else { return nil }
        return bytes.prefix(expected).map { String(format: "%02X", $0) }.joined()
    }

    private static func hexBytes(_ value: String) -> [UInt8]? {
        guard isHex(value) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
