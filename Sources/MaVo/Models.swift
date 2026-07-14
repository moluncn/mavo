import Foundation

enum ModemConnectionState: String, Codable, Equatable {
    case disconnected
    case connecting
    case connected
    case error
}

struct ModemUSBConfiguration: Equatable {
    let vendorID: Int
    let productID: Int
    let diagnosticEnabled: Bool
    let nmeaEnabled: Bool
    let atPortEnabled: Bool
    let modemEnabled: Bool
    let networkEnabled: Bool
    let adbEnabled: Bool
    let audioEnabled: Bool

    static let maVoTarget = ModemUSBConfiguration(
        vendorID: 0x2C7C,
        productID: 0x0125,
        diagnosticEnabled: true,
        nmeaEnabled: true,
        atPortEnabled: true,
        modemEnabled: true,
        networkEnabled: true,
        adbEnabled: false,
        audioEnabled: true
    )

    var isSafeDJISource: Bool {
        vendorID == 0x2CA3 && productID == 0x4006 &&
            diagnosticEnabled && nmeaEnabled && atPortEnabled && modemEnabled && networkEnabled &&
            !adbEnabled && !audioEnabled
    }

    var isMaVoTarget: Bool {
        self == Self.maVoTarget
    }

    var identity: String {
        String(format: "%04X:%04X", vendorID, productID)
    }

    var compactDescription: String {
        "\(identity) · diag=\(diagnosticEnabled ? 1 : 0) · nmea=\(nmeaEnabled ? 1 : 0) · " +
            "at=\(atPortEnabled ? 1 : 0) · modem=\(modemEnabled ? 1 : 0) · " +
            "net=\(networkEnabled ? 1 : 0) · adb=\(adbEnabled ? 1 : 0) · audio=\(audioEnabled ? 1 : 0)"
    }
}

struct ModemSnapshot: Equatable {
    var state: ModemConnectionState = .disconnected
    var usbIdentity: String?
    var operatorName: String?
    var accessTechnology: String?
    var signalDBm: Int?
    var signalDetail: String?
    var simReady: Bool = false
    var simPhoneNumber: String?
    var simICCID: String?
    var usbNetMode: Int?
    var imsMode: Int?
    var usbConfiguration: ModemUSBConfiguration?
    var endpointDescription: String?
    var lastError: String?

    var signalBars: Int {
        guard let signalDBm else { return 0 }
        switch signalDBm {
        case ...(-121): return 0
        case -120...(-111): return 1
        case -110...(-101): return 2
        case -100...(-91): return 3
        default: return 4
        }
    }

    var isConnected: Bool {
        state == .connected
    }

    var initialSetupState: ModemInitialSetupState {
        switch state {
        case .disconnected:
            return .insertModule
        case .connecting:
            return .inspecting
        case .error:
            return .failed(lastError ?? "模块连接异常")
        case .connected:
            break
        }

        guard let usbIdentity else { return .inspecting }
        let normalizedIdentity = usbIdentity.uppercased()
        if normalizedIdentity == "2CA3:4006" {
            guard let usbConfiguration else {
                return .unsupportedIdentity(normalizedIdentity)
            }
            if usbConfiguration.isSafeDJISource || usbConfiguration.isMaVoTarget {
                return .needsIdentityConversion
            }
            return .unsupportedUSBConfiguration(usbConfiguration.compactDescription)
        }
        guard normalizedIdentity == "2C7C:0125" else {
            return .unsupportedIdentity(normalizedIdentity)
        }
        guard let usbNetMode else { return .inspecting }
        switch usbNetMode {
        case 0:
            return .needsECM
        case 1:
            return .ready
        default:
            return .unsupportedUSBNetMode(usbNetMode)
        }
    }
}

enum ModemInitialSetupState: Equatable {
    case insertModule
    case inspecting
    case needsIdentityConversion
    case needsECM
    case ready
    case unsupportedIdentity(String)
    case unsupportedUSBConfiguration(String)
    case unsupportedUSBNetMode(Int)
    case failed(String)
}

struct CellularNetworkStatus: Equatable {
    var serviceID: String?
    var serviceName: String?
    var higherPriorityServiceName: String?
    var bsdName: String?
    var isEnabled = false
    var isActive = false
    var isLinkActive = false
    var isPrioritized = false
    var isHardwarePresent = false
    var ipv4Address: String?
    var ipv4Router: String?
    var ipv6Address: String?
    var lastError: String?

    var isAvailable: Bool {
        serviceID != nil
    }
}

enum NetworkAddressClassifier {
    static func isUsableIPv4(_ address: String) -> Bool {
        let octets = address.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        let values = octets.compactMap { component -> Int? in
            guard !component.isEmpty,
                  component.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let value = Int(component),
                  (0 ... 255).contains(value) else {
                return nil
            }
            return value
        }
        guard values.count == 4 else { return false }
        if values[0] == 0 || values[0] == 127 || values[0] >= 224 { return false }
        if values[0] == 169 && values[1] == 254 { return false }
        return true
    }
}

enum CellularNetworkPriorityPolicy {
    static func shouldAutoPromote(
        network: CellularNetworkStatus,
        modem: ModemSnapshot,
        isChangingNetwork: Bool,
        attemptedServiceID: String?
    ) -> Bool {
        guard let serviceID = network.serviceID else { return false }
        return network.isEnabled &&
            network.isHardwarePresent &&
            !network.isPrioritized &&
            modem.isConnected &&
            modem.usbNetMode == 1 &&
            !isChangingNetwork &&
            attemptedServiceID != serviceID
    }
}

enum ModuleVoiceInitializationRetryPolicy {
    private static let delays: [TimeInterval] = [2, 5, 10, 30, 60]

    static func delay(forCompletedAttempts attempts: Int) -> TimeInterval? {
        guard delays.indices.contains(attempts) else { return nil }
        return delays[attempts]
    }
}

struct ConcatenationInfo: Hashable {
    let reference: Int
    let referenceBits: Int
    let total: Int
    let sequence: Int
}

struct DecodedPDU {
    let sender: String
    let body: String
    let timestamp: Date?
    let concatenation: ConcatenationInfo?
    let dataCodingScheme: UInt8
    let rawPDU: String
}

struct ModemStoredPDU {
    let index: Int
    let status: Int
    let declaredLength: Int?
    let rawPDU: String
    let storage: String?
}

struct ModemPDUReference: Codable, Hashable {
    let storage: String
    let index: Int
    let rawPDU: String

    init?(storedPDU: ModemStoredPDU) {
        guard let storage = storedPDU.storage?.uppercased(),
              ["SM", "ME", "MT"].contains(storage),
              storedPDU.index >= 0 else {
            return nil
        }
        self.storage = storage
        index = storedPDU.index
        rawPDU = storedPDU.rawPDU.uppercased()
    }
}

enum SMSDeletionPlanner {
    static func orderedTargets(from references: [ModemPDUReference]) -> [ModemPDUReference] {
        var seen: Set<ModemPDUReference> = []
        return references
            .filter { seen.insert($0).inserted }
            .sorted { lhs, rhs in
                if lhs.storage != rhs.storage { return lhs.storage < rhs.storage }
                if lhs.index != rhs.index { return lhs.index > rhs.index }
                return lhs.rawPDU < rhs.rawPDU
            }
    }

    static func isBareEmptyCMGR(_ lines: [String], index: Int) -> Bool {
        lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty && $0 != "AT+CMGR=\(index)" } == ["OK"]
    }
}

struct ModemMessageLocation: Hashable {
    let storage: String
    let index: Int
}

struct ModemURCBatch {
    var messageLocations: [ModemMessageLocation] = []
    var directPDUs: [String] = []
}

/// Frames modem URCs as a byte stream rather than assuming one USB read is one event.
/// A direct `+CMT` consists of a header line followed by one PDU line, so that header
/// must also survive across reads and across an intervening AT command response.
struct ModemURCStreamFramer {
    private var pendingLine = ""
    private var pendingDirectCMTHeader: String?
    private var pendingDirectCMTIgnoredLines = 0

    mutating func consume(_ text: String) -> ModemURCBatch {
        guard !text.isEmpty else { return ModemURCBatch() }

        pendingLine += text
        let normalized = pendingLine
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let endedAtLineBoundary = pendingLine.last == "\r" || pendingLine.last == "\n"
        var lines = normalized.components(separatedBy: "\n")
        if endedAtLineBoundary {
            pendingLine = ""
        } else {
            pendingLine = lines.popLast() ?? ""
            if pendingLine.utf8.count > 16 * 1_024 {
                pendingLine = String(pendingLine.suffix(4 * 1_024))
            }
        }

        var batch = ModemURCBatch()
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if let header = pendingDirectCMTHeader {
                if line.hasPrefix("+CMT:") {
                    // A new direct-message header supersedes an older malformed
                    // or incomplete one.
                    pendingDirectCMTHeader = line
                    pendingDirectCMTIgnoredLines = 0
                    continue
                }
                if let pdu = ATResponseParser.parseDirectCMT(
                    "\(header)\r\n\(line)\r\n"
                ).first,
                   (try? SMSPDUDecoder.decode(pdu)) != nil {
                    batch.directPDUs.append(pdu)
                    pendingDirectCMTHeader = nil
                    pendingDirectCMTIgnoredLines = 0
                    continue
                }
                // Command responses and other URCs can be interleaved between the
                // header and PDU. Keep the header for a bounded number of complete
                // lines, and only accept a PDU that fully decodes as SMS-DELIVER.
                pendingDirectCMTIgnoredLines += 1
                if pendingDirectCMTIgnoredLines >= 32 {
                    pendingDirectCMTHeader = nil
                    pendingDirectCMTIgnoredLines = 0
                }
            }

            if line.hasPrefix("+CMTI:") {
                batch.messageLocations += ATResponseParser.parseCMTI(line).map {
                    ModemMessageLocation(storage: $0.storage, index: $0.index)
                }
            } else if line.hasPrefix("+CMT:") {
                pendingDirectCMTHeader = line
                pendingDirectCMTIgnoredLines = 0
            }
        }
        return batch
    }

    mutating func reset() {
        pendingLine = ""
        pendingDirectCMTHeader = nil
        pendingDirectCMTIgnoredLines = 0
    }
}

struct MessageStorageSyncTracker {
    private var synchronizedStorages: Set<String> = []

    mutating func markSuccessfulPoll(of storage: String) -> Bool {
        synchronizedStorages.insert(storage.uppercased()).inserted
    }

    mutating func reset() {
        synchronizedStorages.removeAll()
    }
}

/// Keeps concatenated SMS parts that arrive in separate `+CMT`/`+CMTI` events.
/// Complete CMGL snapshots can use the same path; exact duplicate parts replace their
/// stored modem reference without creating duplicate messages.
struct BufferedSMSAssembler {
    private struct GroupKey: Hashable {
        let sender: String
        let reference: Int
        let referenceBits: Int
        let total: Int
        let dataCodingScheme: UInt8
    }

    private struct Fragment {
        var storedPDUs: [ModemStoredPDU]
        let decoded: DecodedPDU
        let receivedAt: Date

        mutating func addReference(_ stored: ModemStoredPDU) {
            guard !storedPDUs.contains(where: {
                $0.storage == stored.storage &&
                    $0.index == stored.index &&
                    $0.rawPDU.caseInsensitiveCompare(stored.rawPDU) == .orderedSame
            }) else {
                return
            }
            storedPDUs.append(stored)
        }
    }

    private struct FragmentIdentity: Hashable {
        let storage: String?
        let index: Int
        let rawPDU: String
    }

    private struct Cluster {
        var fragmentsBySequence: [Int: Fragment] = [:]

        var mostRecentReceipt: Date {
            fragmentsBySequence.values.map(\.receivedAt).max() ?? .distantPast
        }

        var mostRecentMessageDate: Date? {
            fragmentsBySequence.values.compactMap { $0.decoded.timestamp }.max()
        }
    }

    private var groups: [GroupKey: [Cluster]] = [:]
    private var firstSeenByFragment: [FragmentIdentity: Date] = [:]
    private let retentionInterval: TimeInterval = 24 * 60 * 60
    private let groupingWindow: TimeInterval = 12 * 60 * 60

    mutating func ingest(_ storedPDUs: [ModemStoredPDU], now: Date = Date()) -> [SMSMessage] {
        removeExpiredFragments(now: now)
        var singlePDUs: [ModemStoredPDU] = []
        var completedMessages: [SMSMessage] = []

        for stored in storedPDUs {
            guard let decoded = try? SMSPDUDecoder.decode(stored.rawPDU) else { continue }
            guard let concatenation = decoded.concatenation else {
                singlePDUs.append(stored)
                continue
            }

            let key = GroupKey(
                sender: decoded.sender,
                reference: concatenation.reference,
                referenceBits: concatenation.referenceBits,
                total: concatenation.total,
                dataCodingScheme: decoded.dataCodingScheme
            )
            var clusters = groups[key] ?? []
            let identity = FragmentIdentity(
                storage: stored.storage?.uppercased(),
                index: stored.index,
                rawPDU: decoded.rawPDU
            )
            if firstSeenByFragment[identity] == nil,
               firstSeenByFragment.count >= 4096,
               let oldest = firstSeenByFragment.min(by: { $0.value < $1.value })?.key {
                firstSeenByFragment.removeValue(forKey: oldest)
            }
            let firstSeen = firstSeenByFragment[identity] ?? now
            firstSeenByFragment[identity] = firstSeen
            guard now.timeIntervalSince(firstSeen) <= retentionInterval else {
                continue
            }
            let fragment = Fragment(storedPDUs: [stored], decoded: decoded, receivedAt: firstSeen)

            if let duplicateCluster = clusters.firstIndex(where: { cluster in
                cluster.fragmentsBySequence.values.contains {
                    $0.decoded.rawPDU.caseInsensitiveCompare(decoded.rawPDU) == .orderedSame
                }
            }) {
                clusters[duplicateCluster].fragmentsBySequence[concatenation.sequence]?
                    .addReference(stored)
            } else {
                let messageDate = decoded.timestamp ?? now
                let candidates = clusters.indices.filter { index in
                    let cluster = clusters[index]
                    guard cluster.fragmentsBySequence[concatenation.sequence] == nil else {
                        return false
                    }
                    let clusterDate = cluster.mostRecentMessageDate ?? cluster.mostRecentReceipt
                    return abs(messageDate.timeIntervalSince(clusterDate)) <= groupingWindow
                }
                if let best = candidates.min(by: { lhs, rhs in
                    let leftDate = clusters[lhs].mostRecentMessageDate ?? clusters[lhs].mostRecentReceipt
                    let rightDate = clusters[rhs].mostRecentMessageDate ?? clusters[rhs].mostRecentReceipt
                    return abs(messageDate.timeIntervalSince(leftDate)) <
                        abs(messageDate.timeIntervalSince(rightDate))
                }) {
                    clusters[best].fragmentsBySequence[concatenation.sequence] = fragment
                } else {
                    var cluster = Cluster()
                    cluster.fragmentsBySequence[concatenation.sequence] = fragment
                    clusters.append(cluster)
                }
            }

            var retainedClusters: [Cluster] = []
            for cluster in clusters {
                let requiredSequences = Set(1 ... concatenation.total)
                guard Set(cluster.fragmentsBySequence.keys) == requiredSequences else {
                    retainedClusters.append(cluster)
                    continue
                }
                let ordered = (1 ... concatenation.total).compactMap {
                    cluster.fragmentsBySequence[$0]?.storedPDUs.first
                }
                var assembled = SMSPDUDecoder.assemble(ordered, now: now)
                if assembled.isEmpty {
                    retainedClusters.append(cluster)
                } else {
                    let completedStoredPDUs = (1 ... concatenation.total)
                        .compactMap { cluster.fragmentsBySequence[$0] }
                        .flatMap(\.storedPDUs)
                    let references = completedStoredPDUs
                        .compactMap(ModemPDUReference.init(storedPDU:))
                    for index in assembled.indices {
                        assembled[index].replaceModemReferences(with: references)
                    }
                    for completed in completedStoredPDUs {
                        firstSeenByFragment.removeValue(forKey: FragmentIdentity(
                            storage: completed.storage?.uppercased(),
                            index: completed.index,
                            rawPDU: completed.rawPDU.uppercased()
                        ))
                    }
                    completedMessages += assembled
                }
            }
            if retainedClusters.isEmpty {
                groups.removeValue(forKey: key)
            } else {
                groups[key] = retainedClusters
            }
        }

        let singles = SMSPDUDecoder.assemble(singlePDUs, now: now)
        return (singles + completedMessages).sorted { $0.timestamp > $1.timestamp }
    }

    mutating func reset() {
        groups.removeAll()
        firstSeenByFragment.removeAll()
    }

    private mutating func removeExpiredFragments(now: Date) {
        for key in Array(groups.keys) {
            let retained = (groups[key] ?? []).compactMap { cluster -> Cluster? in
                var cluster = cluster
                cluster.fragmentsBySequence = cluster.fragmentsBySequence.filter {
                    now.timeIntervalSince($0.value.receivedAt) <= retentionInterval
                }
                return cluster.fragmentsBySequence.isEmpty ? nil : cluster
            }
            if retained.isEmpty {
                groups.removeValue(forKey: key)
            } else {
                groups[key] = retained
            }
        }
    }
}

struct SMSMessage: Identifiable, Codable, Equatable {
    let id: String
    var modemIndices: [Int]
    var modemStorage: String? = nil
    var modemReferences: [ModemPDUReference]? = nil
    let sender: String
    let body: String
    var timestamp: Date
    let rawPDUs: [String]
    var isRead: Bool
    var readAt: Date? = nil
    var firstSeenAt: Date

    var preview: String {
        let collapsed = body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? "（空短信）" : collapsed
    }

    var verificationCode: String? {
        SMSVerificationCodeExtractor.extract(from: body)
    }

    var effectiveModemReferences: [ModemPDUReference] {
        if let modemReferences {
            return modemReferences
        }
        guard let storage = modemStorage?.uppercased(),
              modemIndices.count == rawPDUs.count else {
            return []
        }
        return zip(modemIndices, rawPDUs).compactMap { index, rawPDU in
            ModemPDUReference(
                storedPDU: ModemStoredPDU(
                    index: index,
                    status: 0,
                    declaredLength: nil,
                    rawPDU: rawPDU,
                    storage: storage
                )
            )
        }
    }

    mutating func replaceModemReferences(with references: [ModemPDUReference]) {
        var seen: Set<ModemPDUReference> = []
        let unique = references.filter { seen.insert($0).inserted }
        modemReferences = unique
        modemIndices = unique.map(\.index)
        let storages = Set(unique.map(\.storage))
        modemStorage = storages.count == 1 ? storages.first : nil
    }

    mutating func clearModemReferences() {
        modemReferences = []
        modemIndices = []
        modemStorage = nil
    }
}

struct SMSDeletionConfirmationState {
    private(set) var pendingMessageID: SMSMessage.ID?

    var isPresented: Bool { pendingMessageID != nil }

    mutating func request(_ message: SMSMessage) {
        pendingMessageID = message.id
    }

    mutating func cancel() {
        pendingMessageID = nil
    }

    func resolve(in messages: [SMSMessage]) -> SMSMessage? {
        guard let pendingMessageID else { return nil }
        return messages.first { $0.id == pendingMessageID }
    }

    mutating func reconcile(with messages: [SMSMessage]) {
        guard pendingMessageID != nil, resolve(in: messages) == nil else { return }
        pendingMessageID = nil
    }

    mutating func takeConfirmedMessageID(id: SMSMessage.ID) -> SMSMessage.ID? {
        guard pendingMessageID == id else { return nil }
        pendingMessageID = nil
        return id
    }
}

struct SMSMessageMergeResult {
    let messages: [SMSMessage]
    let newlyDiscovered: [SMSMessage]
}

enum SMSMessageMerger {
    static func merge(
        existing: [SMSMessage],
        incoming: [SMSMessage],
        limit: Int = 500
    ) -> SMSMessageMergeResult {
        var byID: [SMSMessage.ID: SMSMessage] = [:]
        for message in existing where byID[message.id] == nil {
            byID[message.id] = message
        }
        var newlyDiscovered: [SMSMessage] = []

        for var candidate in incoming {
            if let previous = byID[candidate.id] {
                candidate.isRead = previous.isRead
                candidate.readAt = previous.readAt
                candidate.timestamp = previous.timestamp
                candidate.firstSeenAt = previous.firstSeenAt
                candidate.replaceModemReferences(
                    with: previous.effectiveModemReferences + candidate.effectiveModemReferences
                )
                byID[candidate.id] = candidate
            } else {
                byID[candidate.id] = candidate
                newlyDiscovered.append(candidate)
            }
        }

        let merged = byID.values
            .sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp { return lhs.firstSeenAt > rhs.firstSeenAt }
                return lhs.timestamp > rhs.timestamp
            }
            .prefix(max(0, limit))
            .map { $0 }
        let retainedIDs = Set(merged.map(\.id))
        return SMSMessageMergeResult(
            messages: merged,
            newlyDiscovered: newlyDiscovered
                .filter { retainedIDs.contains($0.id) }
                .sorted { $0.timestamp < $1.timestamp }
        )
    }
}

enum ModemMessageStorageCapabilities {
    static func readableStorages(from response: String) -> [String] {
        guard let line = ATResponseParser.normalizedLines(response)
            .first(where: { $0.hasPrefix("+CPMS:") }),
              let opening = line.firstIndex(of: "("),
              let closing = line[opening...].firstIndex(of: ")") else {
            return []
        }

        let firstGroup = line[line.index(after: opening) ..< closing]
        var result: [String] = []
        var token = ""
        var insideQuotes = false
        for character in firstGroup {
            if character == "\"" {
                if insideQuotes {
                    let storage = token.uppercased()
                    if ["SM", "ME", "MT"].contains(storage), !result.contains(storage) {
                        result.append(storage)
                    }
                    token = ""
                }
                insideQuotes.toggle()
            } else if insideQuotes {
                token.append(character)
            }
        }
        return result
    }
}

enum ModemActionResult: Equatable {
    case success(String? = nil)
    case failure(String)
}
