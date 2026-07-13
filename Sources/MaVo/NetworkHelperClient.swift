import Foundation
import MaVoNetworkIPC

final class NetworkHelperClient {
    private enum PingResult {
        case ready
        case unavailable(String)
        case incompatible(Int)
    }

    private let queue = DispatchQueue(label: "app.mavo.mac.network-helper.client")
    private let installer = NetworkHelperInstaller()

    func setCellularNetworking(
        _ enabled: Bool,
        completion: @escaping (ModemActionResult) -> Void
    ) {
        queue.async { [weak self] in
            self?.ensureHelperThenSet(enabled, completion: completion)
        }
    }

    private func ensureHelperThenSet(
        _ enabled: Bool,
        completion: @escaping (ModemActionResult) -> Void
    ) {
        ping { [weak self] result in
            guard let self else { return }
            switch result {
            case .ready:
                self.invokeSet(enabled, completion: completion)
            case .unavailable, .incompatible:
                switch self.installer.install() {
                case .success:
                    self.waitForInstalledHelper(enabled: enabled, attemptsRemaining: 12, completion: completion)
                case let .failure(error):
                    completion(.failure(error.localizedDescription))
                }
            }
        }
    }

    private func waitForInstalledHelper(
        enabled: Bool,
        attemptsRemaining: Int,
        completion: @escaping (ModemActionResult) -> Void
    ) {
        ping { [weak self] result in
            guard let self else { return }
            switch result {
            case .ready:
                self.invokeSet(enabled, completion: completion)
            case let .incompatible(version):
                completion(.failure(
                    "已安装的网络 helper 协议版本为 \(version)，但 MaVo 需要 " +
                        "\(MaVoNetworkIPC.protocolVersion)。请重新安装最新版。"
                ))
            case let .unavailable(message):
                guard attemptsRemaining > 1 else {
                    completion(.failure("网络 helper 已安装，但未能启动：\(message)"))
                    return
                }
                self.queue.asyncAfter(deadline: .now() + .milliseconds(250)) {
                    self.waitForInstalledHelper(
                        enabled: enabled,
                        attemptsRemaining: attemptsRemaining - 1,
                        completion: completion
                    )
                }
            }
        }
    }

    private func ping(completion: @escaping (PingResult) -> Void) {
        let connection = makeConnection()
        let gate = OneShot<PingResult> { [queue] result in
            connection.invalidate()
            queue.async { completion(result) }
        }
        connection.resume()
        queue.asyncAfter(deadline: .now() + .seconds(4)) {
            gate.resolve(.unavailable("连接超时"))
        }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            gate.resolve(.unavailable(error.localizedDescription))
        }) as? MaVoNetworkHelperProtocol else {
            gate.resolve(.unavailable("无法建立 XPC 代理"))
            return
        }
        proxy.ping { version, _ in
            if version == MaVoNetworkIPC.protocolVersion {
                gate.resolve(.ready)
            } else {
                gate.resolve(.incompatible(version))
            }
        }
    }

    private func invokeSet(
        _ enabled: Bool,
        completion: @escaping (ModemActionResult) -> Void
    ) {
        let connection = makeConnection()
        let gate = OneShot<ModemActionResult> { [queue] result in
            connection.invalidate()
            queue.async { completion(result) }
        }
        connection.resume()
        queue.asyncAfter(deadline: .now() + .seconds(15)) {
            gate.resolve(.failure("网络 helper 操作超时；未继续重试，以免重复修改。"))
        }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            gate.resolve(.failure("网络 helper 连接中断：\(error.localizedDescription)"))
        }) as? MaVoNetworkHelperProtocol else {
            gate.resolve(.failure("无法建立网络 helper XPC 代理。"))
            return
        }
        proxy.setCellularNetworking(enabled) { succeeded, message in
            gate.resolve(succeeded ? .success(message) : .failure(message))
        }
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: MaVoNetworkIPC.helperLabel,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: MaVoNetworkHelperProtocol.self)
        return connection
    }
}

private final class OneShot<Value> {
    private let lock = NSLock()
    private var action: ((Value) -> Void)?

    init(_ action: @escaping (Value) -> Void) {
        self.action = action
    }

    func resolve(_ value: Value) {
        let callback: ((Value) -> Void)? = lock.withLock {
            defer { action = nil }
            return action
        }
        callback?(value)
    }
}
