import Foundation

@MainActor
final class MessageStore: ObservableObject {
    @Published private(set) var messages: [SMSMessage] = []

    private let fileURL: URL
    private let backupURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var deletedMessages: DeletedMessageRegistry

    init(fileManager: FileManager = .default) {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = root.appendingPathComponent("MaVo", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("messages.json")
        backupURL = directory.appendingPathComponent("messages.backup.json")
        deletedMessages = DeletedMessageRegistry(
            fileURL: directory.appendingPathComponent("deleted-message-ids.json")
        )

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        load()
    }

    var unreadCount: Int {
        messages.lazy.filter { !$0.isRead }.count
    }

    @discardableResult
    func merge(_ incoming: [SMSMessage]) -> [SMSMessage] {
        let visibleIncoming = incoming.filter { !deletedMessages.contains($0.id) }
        let result = SMSMessageMerger.merge(existing: messages, incoming: visibleIncoming)
        let updated = result.messages
        if updated != messages {
            messages = updated
            save()
        }
        return result.newlyDiscovered
    }

    func markRead(id: SMSMessage.ID, at date: Date = Date()) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        guard !messages[index].isRead || messages[index].readAt == nil else { return }
        messages[index].isRead = true
        if messages[index].readAt == nil {
            messages[index].readAt = date
        }
        save()
    }

    func markAllRead(at date: Date = Date()) {
        var changed = false
        for index in messages.indices {
            if !messages[index].isRead {
                messages[index].isRead = true
                changed = true
            }
            if messages[index].readAt == nil {
                messages[index].readAt = date
                changed = true
            }
        }
        if changed { save() }
    }

    func resetVerificationReadDates(at date: Date = Date()) {
        var changed = false
        for index in messages.indices where
            messages[index].isRead && messages[index].verificationCode != nil {
            if messages[index].readAt != date {
                messages[index].readAt = date
                changed = true
            }
        }
        if changed { save() }
    }

    func fillMissingVerificationReadDates(at date: Date = Date()) {
        var changed = false
        for index in messages.indices where
            messages[index].isRead &&
                messages[index].verificationCode != nil &&
                messages[index].readAt == nil {
            messages[index].readAt = date
            changed = true
        }
        if changed { save() }
    }

    func remove(id: SMSMessage.ID, at date: Date = Date()) {
        deletedMessages.insert(id, at: date)
        let originalCount = messages.count
        messages.removeAll { $0.id == id }
        if messages.count != originalCount { save() }
    }

    func invalidateModemReferences() {
        var changed = false
        for index in messages.indices where
            !messages[index].effectiveModemReferences.isEmpty ||
                !messages[index].modemIndices.isEmpty ||
                messages[index].modemStorage != nil {
            messages[index].clearModemReferences()
            changed = true
        }
        if changed { save() }
    }

    private func load() {
        let decoded = decodeMessages(at: fileURL) ?? decodeMessages(at: backupURL)
        guard let decoded else {
            messages = []
            return
        }
        messages = decoded.filter { !deletedMessages.contains($0.id) }.map { message in
            var detached = message
            detached.clearModemReferences()
            return detached
        }.sorted { $0.timestamp > $1.timestamp }
    }

    private func save() {
        guard let data = try? encoder.encode(messages) else { return }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: fileURL.path), decodeMessages(at: fileURL) != nil {
            try? fileManager.removeItem(at: backupURL)
            try? fileManager.copyItem(at: fileURL, to: backupURL)
        }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func decodeMessages(at url: URL) -> [SMSMessage]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode([SMSMessage].self, from: data)
    }

}
