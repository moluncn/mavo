import CryptoKit
import Foundation

enum SMSPDUDecoderError: LocalizedError {
    case invalidHex
    case truncated(String)
    case unsupportedMessageType(Int)

    var errorDescription: String? {
        switch self {
        case .invalidHex:
            return "短信 PDU 不是有效的十六进制数据"
        case let .truncated(field):
            return "短信 PDU 在 \(field) 处不完整"
        case let .unsupportedMessageType(type):
            return "暂不支持的短信 PDU 类型：\(type)"
        }
    }
}

enum SMSPDUDecoder {
    static func decode(_ rawPDU: String) throws -> DecodedPDU {
        guard let bytes = bytes(fromHex: rawPDU), !bytes.isEmpty else {
            throw SMSPDUDecoderError.invalidHex
        }

        var cursor = 0
        let smscLength = Int(bytes[cursor])
        cursor += 1
        guard cursor + smscLength <= bytes.count else {
            throw SMSPDUDecoderError.truncated("SMSC")
        }
        cursor += smscLength

        guard cursor < bytes.count else { throw SMSPDUDecoderError.truncated("TPDU") }
        let firstOctet = bytes[cursor]
        cursor += 1
        let messageType = Int(firstOctet & 0x03)
        guard messageType == 0 else {
            throw SMSPDUDecoderError.unsupportedMessageType(messageType)
        }
        let hasUserDataHeader = firstOctet & 0x40 != 0

        guard cursor + 2 <= bytes.count else { throw SMSPDUDecoderError.truncated("发件人") }
        let senderLength = Int(bytes[cursor])
        cursor += 1
        let senderType = bytes[cursor]
        cursor += 1
        let isAlphanumericSender = senderType & 0x70 == 0x50
        let senderByteCount = isAlphanumericSender
            ? (senderLength + 1) / 2
            : (senderLength + 1) / 2
        guard cursor + senderByteCount <= bytes.count else {
            throw SMSPDUDecoderError.truncated("发件人地址")
        }
        let senderBytes = Array(bytes[cursor ..< cursor + senderByteCount])
        cursor += senderByteCount
        let sender: String
        if isAlphanumericSender {
            sender = decodeGSM7(
                senderBytes,
                septetCount: senderLength * 4 / 7,
                bitOffset: 0
            )
        } else {
            sender = decodePhoneNumber(senderBytes, digits: senderLength, type: senderType)
        }

        guard cursor + 2 + 7 + 1 <= bytes.count else {
            throw SMSPDUDecoderError.truncated("PID/DCS/时间")
        }
        cursor += 1 // PID
        let dataCodingScheme = bytes[cursor]
        cursor += 1
        let timestampBytes = Array(bytes[cursor ..< cursor + 7])
        cursor += 7
        let timestamp = decodeTimestamp(timestampBytes)
        let userDataLength = Int(bytes[cursor])
        cursor += 1

        let alphabet = alphabet(for: dataCodingScheme)
        let expectedUserDataOctets: Int
        switch alphabet {
        case .gsm7:
            expectedUserDataOctets = (userDataLength * 7 + 7) / 8
        case .eightBit, .ucs2:
            expectedUserDataOctets = userDataLength
        }
        guard cursor + expectedUserDataOctets <= bytes.count else {
            throw SMSPDUDecoderError.truncated("用户数据")
        }
        let availableUserData = Array(bytes[cursor ..< cursor + expectedUserDataOctets])
        var headerByteCount = 0
        var concatenation: ConcatenationInfo?
        if hasUserDataHeader {
            guard let userDataHeaderLength = availableUserData.first.map(Int.init),
                  userDataHeaderLength + 1 <= availableUserData.count else {
                throw SMSPDUDecoderError.truncated("用户数据头")
            }
            headerByteCount = userDataHeaderLength + 1
            concatenation = parseConcatenationHeader(
                Array(availableUserData.prefix(headerByteCount))
            )
        }

        let body: String
        switch alphabet {
        case .gsm7:
            let headerSeptets = hasUserDataHeader ? (headerByteCount * 8 + 6) / 7 : 0
            let textSeptets = max(0, userDataLength - headerSeptets)
            let bitOffset = headerSeptets * 7
            body = decodeGSM7(availableUserData, septetCount: textSeptets, bitOffset: bitOffset)
        case .eightBit:
            let payload = availableUserData.dropFirst(headerByteCount)
            body = payload.isEmpty
                ? ""
                : "[二进制短信] " + payload.map { String(format: "%02X", $0) }.joined()
        case .ucs2:
            let payload = Array(availableUserData.dropFirst(headerByteCount))
            guard payload.count.isMultiple(of: 2) else {
                throw SMSPDUDecoderError.truncated("UCS2 用户数据")
            }
            body = decodeUCS2(payload)
        }

        return DecodedPDU(
            sender: sender.isEmpty ? "未知号码" : sender,
            body: body,
            timestamp: timestamp,
            concatenation: concatenation,
            dataCodingScheme: dataCodingScheme,
            rawPDU: rawPDU.uppercased()
        )
    }

    static func assemble(_ storedPDUs: [ModemStoredPDU], now: Date = Date()) -> [SMSMessage] {
        struct Part {
            let stored: ModemStoredPDU
            let decoded: DecodedPDU
        }

        var singles: [Part] = []
        struct GroupKey: Hashable {
            let sender: String
            let reference: Int
            let referenceBits: Int
            let total: Int
            let dataCodingScheme: UInt8
        }
        var groups: [GroupKey: [Part]] = [:]

        for stored in storedPDUs {
            guard let decoded = try? decode(stored.rawPDU) else { continue }
            let part = Part(stored: stored, decoded: decoded)
            if let concat = decoded.concatenation {
                let key = GroupKey(
                    sender: decoded.sender,
                    reference: concat.reference,
                    referenceBits: concat.referenceBits,
                    total: concat.total,
                    dataCodingScheme: decoded.dataCodingScheme
                )
                groups[key, default: []].append(part)
            } else {
                singles.append(part)
            }
        }

        var messages = singles.map { part in
            let isRead = part.stored.status == 1
            var message = SMSMessage(
                id: stableID(for: [part.decoded.rawPDU]),
                modemIndices: [],
                modemStorage: part.stored.storage,
                sender: part.decoded.sender,
                body: part.decoded.body,
                timestamp: part.decoded.timestamp ?? now,
                rawPDUs: [part.decoded.rawPDU],
                isRead: isRead,
                readAt: isRead ? now : nil,
                firstSeenAt: now
            )
            message.replaceModemReferences(
                with: [part.stored].compactMap(ModemPDUReference.init(storedPDU:))
            )
            return message
        }

        for parts in groups.values {
            let sortedParts = parts.sorted { lhs, rhs in
                let leftDate = lhs.decoded.timestamp ?? now
                let rightDate = rhs.decoded.timestamp ?? now
                if leftDate == rightDate { return lhs.stored.index < rhs.stored.index }
                return leftDate < rightDate
            }
            var clusters: [[Part]] = []
            for part in sortedParts {
                guard let sequence = part.decoded.concatenation?.sequence else { continue }
                let partDate = part.decoded.timestamp ?? now
                let candidates = clusters.indices.filter { index in
                    let cluster = clusters[index]
                    let sequences = Set(cluster.compactMap { $0.decoded.concatenation?.sequence })
                    guard !sequences.contains(sequence) else { return false }
                    let latestDate = cluster.compactMap(\.decoded.timestamp).max() ?? now
                    return abs(partDate.timeIntervalSince(latestDate)) <= 12 * 60 * 60
                }
                if let best = candidates.min(by: { lhs, rhs in
                    let leftDate = clusters[lhs].compactMap(\.decoded.timestamp).max() ?? now
                    let rightDate = clusters[rhs].compactMap(\.decoded.timestamp).max() ?? now
                    return abs(partDate.timeIntervalSince(leftDate)) <
                        abs(partDate.timeIntervalSince(rightDate))
                }) {
                    clusters[best].append(part)
                } else {
                    clusters.append([part])
                }
            }
            for cluster in clusters {
                guard let first = cluster.first,
                      let info = first.decoded.concatenation else { continue }
                let bySequence = Dictionary(
                    uniqueKeysWithValues: cluster.compactMap { part -> (Int, Part)? in
                        guard let sequence = part.decoded.concatenation?.sequence else { return nil }
                        return (sequence, part)
                    }
                )
                guard Set(bySequence.keys) == Set(1 ... info.total) else { continue }
                let ordered = (1 ... info.total).compactMap { bySequence[$0] }
                let rawPDUs = ordered.map(\.decoded.rawPDU)
                let isRead = ordered.allSatisfy { $0.stored.status == 1 }
                var message = SMSMessage(
                        id: stableID(for: rawPDUs),
                        modemIndices: [],
                        modemStorage: nil,
                        sender: first.decoded.sender,
                        body: ordered.map(\.decoded.body).joined(),
                        timestamp: ordered.compactMap(\.decoded.timestamp).min() ?? now,
                        rawPDUs: rawPDUs,
                        isRead: isRead,
                        readAt: isRead ? now : nil,
                        firstSeenAt: now
                    )
                message.replaceModemReferences(
                    with: ordered.compactMap {
                        ModemPDUReference(storedPDU: $0.stored)
                    }
                )
                messages.append(message)
            }
        }

        return messages.sorted { $0.timestamp > $1.timestamp }
    }

    private enum Alphabet {
        case gsm7
        case eightBit
        case ucs2
    }

    private static func alphabet(for dcs: UInt8) -> Alphabet {
        if dcs & 0xC0 == 0x00 {
            switch (dcs >> 2) & 0x03 {
            case 1: return .eightBit
            case 2: return .ucs2
            default: return .gsm7
            }
        }
        if dcs & 0xF0 == 0xE0 { return .ucs2 }
        if dcs & 0xF0 == 0xF0 { return dcs & 0x04 == 0 ? .gsm7 : .eightBit }
        return .gsm7
    }

    private static func parseConcatenationHeader(_ header: [UInt8]) -> ConcatenationInfo? {
        guard header.count >= 2 else { return nil }
        let declaredLength = min(Int(header[0]), header.count - 1)
        var cursor = 1
        let end = 1 + declaredLength
        while cursor + 2 <= end {
            let identifier = header[cursor]
            let length = Int(header[cursor + 1])
            cursor += 2
            guard cursor + length <= end else { break }
            if identifier == 0x00, length == 3 {
                let total = Int(header[cursor + 1])
                let sequence = Int(header[cursor + 2])
                guard total > 1, (1 ... total).contains(sequence) else { return nil }
                return ConcatenationInfo(
                    reference: Int(header[cursor]),
                    referenceBits: 8,
                    total: total,
                    sequence: sequence
                )
            }
            if identifier == 0x08, length == 4 {
                let total = Int(header[cursor + 2])
                let sequence = Int(header[cursor + 3])
                guard total > 1, (1 ... total).contains(sequence) else { return nil }
                return ConcatenationInfo(
                    reference: Int(header[cursor]) << 8 | Int(header[cursor + 1]),
                    referenceBits: 16,
                    total: total,
                    sequence: sequence
                )
            }
            cursor += length
        }
        return nil
    }

    private static func decodePhoneNumber(_ bytes: [UInt8], digits: Int, type: UInt8) -> String {
        let symbols: [Character] = Array("0123456789*#abc")
        var result = ""
        result.reserveCapacity(digits + 1)
        if type & 0x70 == 0x10 {
            result.append("+")
        }
        var emitted = 0
        for byte in bytes {
            for nibble in [Int(byte & 0x0F), Int((byte >> 4) & 0x0F)] where emitted < digits {
                if nibble < symbols.count {
                    result.append(symbols[nibble])
                }
                emitted += 1
            }
        }
        return result
    }

    private static func decodeTimestamp(_ bytes: [UInt8]) -> Date? {
        guard bytes.count == 7 else { return nil }
        func decimal(_ byte: UInt8) -> Int? {
            let tens = Int(byte & 0x0F)
            let units = Int((byte >> 4) & 0x0F)
            guard tens <= 9, units <= 9 else { return nil }
            return tens * 10 + units
        }

        guard let shortYear = decimal(bytes[0]),
              let month = decimal(bytes[1]),
              let day = decimal(bytes[2]),
              let hour = decimal(bytes[3]),
              let minute = decimal(bytes[4]),
              let second = decimal(bytes[5]) else {
            return nil
        }

        let timezoneByte = bytes[6]
        let timezoneTens = Int(timezoneByte & 0x07)
        let timezoneUnits = Int((timezoneByte >> 4) & 0x0F)
        guard timezoneTens <= 9, timezoneUnits <= 9 else { return nil }
        let isNegative = timezoneByte & 0x08 != 0
        let quarterHours = timezoneTens * 10 + timezoneUnits
        let timezoneSeconds = quarterHours * 15 * 60 * (isNegative ? -1 : 1)
        guard let timeZone = TimeZone(secondsFromGMT: timezoneSeconds) else { return nil }

        var components = DateComponents()
        components.year = shortYear >= 70 ? 1900 + shortYear : 2000 + shortYear
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = timeZone

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard components.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: components)
    }

    private static func decodeUCS2(_ bytes: [UInt8]) -> String {
        guard bytes.count >= 2 else { return "" }
        var codeUnits: [UInt16] = []
        codeUnits.reserveCapacity(bytes.count / 2)
        var cursor = 0
        while cursor + 1 < bytes.count {
            codeUnits.append(UInt16(bytes[cursor]) << 8 | UInt16(bytes[cursor + 1]))
            cursor += 2
        }
        return String(decoding: codeUnits, as: UTF16.self)
    }

    private static func decodeGSM7(_ bytes: [UInt8], septetCount: Int, bitOffset: Int) -> String {
        guard septetCount > 0 else { return "" }
        var septets: [UInt8] = []
        septets.reserveCapacity(septetCount)
        for index in 0 ..< septetCount {
            let bitIndex = bitOffset + index * 7
            let byteIndex = bitIndex / 8
            let shift = bitIndex % 8
            guard byteIndex < bytes.count else { break }
            var value = UInt16(bytes[byteIndex]) >> UInt16(shift)
            if shift > 1, byteIndex + 1 < bytes.count {
                value |= UInt16(bytes[byteIndex + 1]) << UInt16(8 - shift)
            }
            septets.append(UInt8(value & 0x7F))
        }

        var output = ""
        var escaped = false
        for septet in septets {
            if escaped {
                output += gsmExtension[Int(septet)] ?? "�"
                escaped = false
            } else if septet == 0x1B {
                escaped = true
            } else {
                output += gsmDefault[Int(septet)] ?? "�"
            }
        }
        return output
    }

    private static func stableID(for rawPDUs: [String]) -> String {
        let payload = rawPDUs.joined(separator: "|").data(using: .utf8) ?? Data()
        return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    private static func bytes(fromHex value: String) -> [UInt8]? {
        let compact = value.filter { !$0.isWhitespace }
        guard !compact.isEmpty, compact.count.isMultiple(of: 2) else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(compact.count / 2)
        var cursor = compact.startIndex
        while cursor < compact.endIndex {
            let next = compact.index(cursor, offsetBy: 2)
            guard let byte = UInt8(compact[cursor ..< next], radix: 16) else { return nil }
            result.append(byte)
            cursor = next
        }
        return result
    }

    private static let gsmExtension: [Int: String] = [
        0x0A: "\u{000C}", 0x14: "^", 0x28: "{", 0x29: "}", 0x2F: "\\",
        0x3C: "[", 0x3D: "~", 0x3E: "]", 0x40: "|", 0x65: "€"
    ]

    private static let gsmDefault: [Int: String] = {
        let values = [
            "@", "£", "$", "¥", "è", "é", "ù", "ì", "ò", "Ç", "\n", "Ø", "ø", "\r", "Å", "å",
            "Δ", "_", "Φ", "Γ", "Λ", "Ω", "Π", "Ψ", "Σ", "Θ", "Ξ", "", "Æ", "æ", "ß", "É",
            " ", "!", "\"", "#", "¤", "%", "&", "'", "(", ")", "*", "+", ",", "-", ".", "/",
            "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ":", ";", "<", "=", ">", "?",
            "¡", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O",
            "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "Ä", "Ö", "Ñ", "Ü", "§",
            "¿", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o",
            "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "ä", "ö", "ñ", "ü", "à"
        ]
        return Dictionary(uniqueKeysWithValues: values.enumerated().map { ($0.offset, $0.element) })
    }()
}
