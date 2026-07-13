import Foundation

enum CarrierNameFormatter {
    static func localized(_ rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let canonical = trimmed.uppercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()

        switch canonical {
        case "46000", "46002", "46004", "46007", "46008",
             "CMCC", "CHNCMCC", "CHINAMOBILE", "CHINAMOBILECOMMUNICATIONS":
            return "中国移动"
        case "46001", "46006", "46009",
             "CUCC", "UNICOM", "CHNUNICOM", "CHINAUNICOM":
            return "中国联通"
        case "46003", "46005", "46011", "46012",
             "CTCC", "CHNCT", "CHINACT", "CHNTELECOM", "CHINATELECOM":
            return "中国电信"
        case "46015", "CBN", "CHNBROADNET", "CHINABROADNET", "CHINABROADCASTNETWORK":
            return "中国广电"
        case "CMHK", "CHINAMOBILEHK", "CHINAMOBILEHONGKONG":
            return "中国移动香港"
        default:
            if canonical.hasPrefix("CHNCT") { return "中国电信" }
            if canonical.hasPrefix("CHNCMCC") { return "中国移动" }
            if canonical.hasPrefix("CHNUNICOM") { return "中国联通" }
            return trimmed
        }
    }
}
