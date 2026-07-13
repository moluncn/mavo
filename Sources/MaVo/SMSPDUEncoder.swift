import Foundation

enum SMSPDUEncoderError: LocalizedError, Equatable {
    case invalidDestination
    case emptyBody
    case tooLong(Int)

    var errorDescription: String? {
        switch self {
        case .invalidDestination:
            return "收件号码无效；只允许数字和开头的 +。"
        case .emptyBody:
            return "短信内容不能为空。"
        case let .tooLong(parts):
            return "短信过长，需要拆分为 \(parts) 条；最多支持 255 条。"
        }
    }
}

struct SMSSubmitSegment: Equatable {
    let pdu: String
    let tpduLength: Int
    let sequence: Int
    let total: Int
}

enum SMSPDUEncoder {
    static func encode(
        destination rawDestination: String,
        body: String,
        concatenationReference: UInt8 = .random(in: .min ... .max)
    ) throws -> [SMSSubmitSegment] {
        guard let destination = normalizedDestination(rawDestination) else {
            throw SMSPDUEncoderError.invalidDestination
        }
        guard !body.isEmpty else { throw SMSPDUEncoderError.emptyBody }

        let units = Array(body.utf16)
        guard !units.isEmpty else { throw SMSPDUEncoderError.emptyBody }
        let chunks: [[UInt16]]
        if units.count <= 70 {
            chunks = [units]
        } else {
            chunks = splitUTF16(units, maximumUnits: 67)
        }
        guard chunks.count <= 255 else {
            throw SMSPDUEncoderError.tooLong(chunks.count)
        }

        let isInternational = destination.hasPrefix("+")
        let digits = isInternational ? String(destination.dropFirst()) : destination
        let address = semiOctetAddress(digits)
        let total = chunks.count

        return chunks.enumerated().map { offset, chunk in
            let sequence = offset + 1
            var userData: [UInt8] = []
            if total > 1 {
                userData += [
                    0x05, 0x00, 0x03,
                    concatenationReference,
                    UInt8(total),
                    UInt8(sequence),
                ]
            }
            for unit in chunk {
                userData.append(UInt8((unit >> 8) & 0xFF))
                userData.append(UInt8(unit & 0xFF))
            }

            var bytes: [UInt8] = [
                0x00, // Use the SMSC stored on the SIM/network.
                total > 1 ? 0x41 : 0x01, // SMS-SUBMIT, with UDHI for multipart.
                0x00, // TP-MR: let the modem assign a reference.
                UInt8(digits.count),
                isInternational ? 0x91 : 0x81,
            ]
            bytes += address
            bytes += [
                0x00, // TP-PID
                0x08, // TP-DCS: UCS-2
                UInt8(userData.count),
            ]
            bytes += userData

            return SMSSubmitSegment(
                pdu: bytes.map { String(format: "%02X", $0) }.joined(),
                tpduLength: bytes.count - 1,
                sequence: sequence,
                total: total
            )
        }
    }

    static func segmentCount(destination: String, body: String) -> Int? {
        try? encode(
            destination: destination,
            body: body,
            concatenationReference: 0
        ).count
    }

    static func isValidDestination(_ value: String) -> Bool {
        normalizedDestination(value) != nil
    }

    private static func normalizedDestination(_ value: String) -> String? {
        guard let normalized = CallATParser.normalizedDialNumber(value) else { return nil }
        let digitCount = normalized.filter { $0 >= "0" && $0 <= "9" }.count
        guard (1 ... 20).contains(digitCount) else { return nil }
        return normalized
    }

    private static func semiOctetAddress(_ digits: String) -> [UInt8] {
        let values = digits.utf8.map { $0 - 48 }
        var result: [UInt8] = []
        result.reserveCapacity((values.count + 1) / 2)
        var index = 0
        while index < values.count {
            let low = values[index]
            let high = index + 1 < values.count ? values[index + 1] : 0x0F
            result.append(low | (high << 4))
            index += 2
        }
        return result
    }

    private static func splitUTF16(_ units: [UInt16], maximumUnits: Int) -> [[UInt16]] {
        var result: [[UInt16]] = []
        var start = 0
        while start < units.count {
            var end = min(start + maximumUnits, units.count)
            if end < units.count,
               end > start,
               isHighSurrogate(units[end - 1]),
               isLowSurrogate(units[end]) {
                end -= 1
            }
            result.append(Array(units[start ..< end]))
            start = end
        }
        return result
    }

    private static func isHighSurrogate(_ value: UInt16) -> Bool {
        (0xD800 ... 0xDBFF).contains(value)
    }

    private static func isLowSurrogate(_ value: UInt16) -> Bool {
        (0xDC00 ... 0xDFFF).contains(value)
    }
}
