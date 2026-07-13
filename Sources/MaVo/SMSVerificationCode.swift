import Foundation

enum SMSVerificationCodeExtractor {
    private static let keywordExpression = try? NSRegularExpression(
        pattern: #"验证码|校验码|动态码|认证码|安全码|确认码|登录码|激活码|一次性密码|verification\s+code|verify\s+code|security\s+code|one[-\s]*time\s+(?:password|code)|\botp\b|\bpasscode\b|\bcode\b"#,
        options: [.caseInsensitive]
    )
    private static let candidateExpression = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])([A-Za-z0-9]{4,8})(?![A-Za-z0-9])"#
    )

    static func extract(from text: String) -> String? {
        guard let keywordExpression,
              let candidateExpression,
              !text.isEmpty else {
            return nil
        }

        let fullRange = NSRange(text.startIndex ..< text.endIndex, in: text)
        let keywordRanges = keywordExpression.matches(in: text, range: fullRange).map(\.range)
        guard !keywordRanges.isEmpty else { return nil }

        let candidates = candidateExpression.matches(in: text, range: fullRange).compactMap { match -> Candidate? in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            let code = String(text[range])
            guard code.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains) else {
                return nil
            }
            return Candidate(code: code, range: match.range(at: 1))
        }

        return candidates.compactMap { candidate -> (String, Int)? in
            let proximityScores = keywordRanges.compactMap { keywordRange -> Int? in
                let gap: Int
                let directionScore: Int
                if candidate.range.location >= NSMaxRange(keywordRange) {
                    gap = candidate.range.location - NSMaxRange(keywordRange)
                    directionScore = 1_000
                } else {
                    gap = keywordRange.location - NSMaxRange(candidate.range)
                    directionScore = 900
                }
                guard gap >= 0, gap <= 64 else { return nil }
                return directionScore - gap * 10
            }
            guard let proximityScore = proximityScores.max() else { return nil }
            let numericBonus = candidate.code.allSatisfy(\.isNumber) ? 20 : 0
            let lengthBonus = candidate.code.count == 6 ? 25 : 0
            return (candidate.code, proximityScore + numericBonus + lengthBonus)
        }
        .max { lhs, rhs in lhs.1 < rhs.1 }?
        .0
    }

    private struct Candidate {
        let code: String
        let range: NSRange
    }
}
