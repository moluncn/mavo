import Foundation

struct DeletedMessageRegistry {
    private let fileURL: URL
    private let limit: Int
    private var entries: [SMSMessage.ID: Date]

    init(fileURL: URL, limit: Int = 10_000) {
        self.fileURL = fileURL
        self.limit = max(1, limit)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? decoder.decode([SMSMessage.ID: Date].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
        trimIfNeeded()
    }

    func contains(_ id: SMSMessage.ID) -> Bool {
        entries[id] != nil
    }

    mutating func insert(_ id: SMSMessage.ID, at date: Date = Date()) {
        entries[id] = date
        trimIfNeeded()
        save()
    }

    private mutating func trimIfNeeded() {
        guard entries.count > limit else { return }
        entries = Dictionary(
            uniqueKeysWithValues: entries
                .sorted { $0.value > $1.value }
                .prefix(limit)
                .map { ($0.key, $0.value) }
        )
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
