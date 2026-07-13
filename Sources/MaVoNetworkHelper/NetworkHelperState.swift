import Darwin
import Foundation

struct NetworkOrderSnapshot: Codable, Equatable {
    let setID: String
    let targetServiceID: String
    let original: [String]
    let promoted: [String]
}

struct NetworkServiceRecord: Codable, Equatable {
    let setID: String
    let serviceID: String
    let bsdName: String
}

struct NetworkHelperState: Codable, Equatable {
    var orderSnapshot: NetworkOrderSnapshot?
    var serviceRecord: NetworkServiceRecord?

    static let empty = NetworkHelperState(orderSnapshot: nil, serviceRecord: nil)
}

final class NetworkHelperStateStore {
    private let directoryURL = URL(
        fileURLWithPath: "/Library/Application Support/MaVo",
        isDirectory: true
    )
    private lazy var fileURL = directoryURL.appendingPathComponent("network-helper-state.json")

    func load() -> NetworkHelperState {
        guard let data = try? Data(contentsOf: fileURL) else { return .empty }
        return (try? JSONDecoder().decode(NetworkHelperState.self, from: data)) ?? .empty
    }

    func save(_ state: NetworkHelperState) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let data = try JSONEncoder().encode(state)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [
                .ownerAccountID: NSNumber(value: 0),
                .groupOwnerAccountID: NSNumber(value: 0),
                .posixPermissions: NSNumber(value: 0o600)
            ],
            ofItemAtPath: fileURL.path
        )
    }
}
