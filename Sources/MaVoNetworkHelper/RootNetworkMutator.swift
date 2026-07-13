import Foundation
import IOKit
import IOKit.network
import IOKit.usb
import SystemConfiguration

struct HelperActionResult {
    let succeeded: Bool
    let message: String

    static func success(_ message: String) -> HelperActionResult {
        HelperActionResult(succeeded: true, message: message)
    }

    static func failure(_ message: String) -> HelperActionResult {
        HelperActionResult(succeeded: false, message: message)
    }
}

final class RootNetworkMutator {
    private let stateStore = NetworkHelperStateStore()
    private let targetUSBIdentity = USBIdentity(vendorID: 0x2C7C, productID: 0x0125)

    func setCellularNetworking(enabled: Bool) -> HelperActionResult {
        guard geteuid() == 0 else {
            return .failure("网络 helper 没有以 root 身份运行，已拒绝修改。")
        }
        if enabled && findLiveModemInterface() == nil {
            return .failure("没有找到实时 QDC507 CDC-ECM 接口；未修改网络配置。")
        }

        guard let preferences = SCPreferencesCreate(
            nil,
            "MaVo Network Helper" as NSString,
            nil
        ) else {
            return .failure(systemConfigurationError("无法建立网络配置会话"))
        }
        guard SCPreferencesLock(preferences, true) else {
            return .failure(systemConfigurationError("系统网络配置正被其他程序占用"))
        }
        defer { SCPreferencesUnlock(preferences) }

        guard let networkSet = SCNetworkSetCopyCurrent(preferences),
              let setID = SCNetworkSetGetSetID(networkSet) as String? else {
            return .failure(systemConfigurationError("找不到当前网络位置"))
        }

        var state = stateStore.load()
        let originalState = state
        let service: SCNetworkService?
        if enabled {
            guard let interface = findLiveModemInterface() else {
                return .failure("没有找到 QDC507 的 CDC-ECM 网络接口。")
            }
            if let existing = findLiveModemService(in: networkSet) {
                service = existing
            } else {
                guard let created = SCNetworkServiceCreate(preferences, interface) else {
                    return .failure(systemConfigurationError("无法为 ECM 接口创建网络服务"))
                }
                guard SCNetworkServiceEstablishDefaultConfiguration(created),
                      SCNetworkServiceSetName(created, "QDC507 蜂窝网络" as NSString),
                      SCNetworkSetAddService(networkSet, created) else {
                    return .failure(systemConfigurationError("无法初始化 QDC507 网络服务"))
                }
                service = created
            }
        } else {
            service = findLiveModemService(in: networkSet) ?? recordedService(in: networkSet, state: state)
        }

        guard let service,
              let serviceID = SCNetworkServiceGetServiceID(service) as String? else {
            return enabled
                ? .failure("未找到模块网络服务。")
                : .success("模块网络服务尚不存在，无需禁用。")
        }

        let currentOrder = completeServiceOrder(networkSet)
        var didRestoreOrder = false
        if enabled {
            let promotedOrder = [serviceID] + currentOrder.filter { $0 != serviceID }
            let originalOrder: [String]
            if let saved = state.orderSnapshot,
               saved.setID == setID,
               saved.targetServiceID == serviceID,
               relativeOrderMatches(currentOrder, saved.promoted) {
                originalOrder = saved.original
            } else {
                originalOrder = currentOrder
            }
            state.orderSnapshot = NetworkOrderSnapshot(
                setID: setID,
                targetServiceID: serviceID,
                original: originalOrder,
                promoted: promotedOrder
            )
            if let interface = SCNetworkServiceGetInterface(service),
               let bsdName = SCNetworkInterfaceGetBSDName(interface) as String? {
                state.serviceRecord = NetworkServiceRecord(
                    setID: setID,
                    serviceID: serviceID,
                    bsdName: bsdName
                )
            }

            do {
                // Persist the restoration data before changing system order. If
                // the process is interrupted after this point, a later disable
                // still knows the user's prior order.
                try stateStore.save(state)
            } catch {
                return .failure("无法保存网络顺序恢复记录：\(error.localizedDescription)")
            }
            guard SCNetworkServiceSetEnabled(service, true),
                  SCNetworkSetSetServiceOrder(networkSet, promotedOrder as NSArray) else {
                try? stateStore.save(originalState)
                return .failure(systemConfigurationError("无法启用模块或调整网络服务顺序"))
            }
        } else {
            guard SCNetworkServiceSetEnabled(service, false) else {
                return .failure(systemConfigurationError("无法禁用模块网络服务"))
            }
            if let saved = state.orderSnapshot,
               saved.setID == setID,
               saved.targetServiceID == serviceID {
                if relativeOrderMatches(currentOrder, saved.promoted) {
                    let currentIDs = Set(currentOrder)
                    let validOriginal = saved.original.filter { currentIDs.contains($0) }
                    let newlyObserved = currentOrder.filter { !validOriginal.contains($0) }
                    guard SCNetworkSetSetServiceOrder(
                        networkSet,
                        (validOriginal + newlyObserved) as NSArray
                    ) else {
                        return .failure(systemConfigurationError("无法恢复原网络服务顺序"))
                    }
                    didRestoreOrder = true
                }
                // If the user changed the service set/order while cellular was
                // enabled, preserve that order instead of guessing positions.
                state.orderSnapshot = nil
            }
        }

        guard SCPreferencesCommitChanges(preferences) else {
            if enabled { try? stateStore.save(originalState) }
            return .failure(systemConfigurationError("保存系统网络配置失败"))
        }
        guard SCPreferencesApplyChanges(preferences) else {
            return .failure(systemConfigurationError("应用系统网络配置失败"))
        }

        if enabled, let interface = SCNetworkServiceGetInterface(service) {
            _ = SCNetworkInterfaceForceConfigurationRefresh(interface)
        } else {
            try? stateStore.save(state)
        }

        if enabled {
            return .success("已启用模块网络，并把它置于 Wi-Fi 之前。")
        }
        return didRestoreOrder
            ? .success("已从系统层禁用模块网络，并恢复原服务顺序。")
            : .success("已从系统层禁用模块网络；当前网络服务顺序保持不变。")
    }

    private func services(in networkSet: SCNetworkSet) -> [SCNetworkService] {
        guard let rawServices = SCNetworkSetCopyServices(networkSet) else { return [] }
        return (rawServices as? [SCNetworkService]) ?? []
    }

    private func findLiveModemService(in networkSet: SCNetworkSet) -> SCNetworkService? {
        services(in: networkSet).first { service in
            guard let interface = SCNetworkServiceGetInterface(service),
                  (SCNetworkInterfaceGetInterfaceType(interface) as String?) ==
                    (kSCNetworkInterfaceTypeEthernet as String),
                  let bsdName = SCNetworkInterfaceGetBSDName(interface) as String? else {
                return false
            }
            return usbIdentity(forBSDName: bsdName) == targetUSBIdentity
        }
    }

    private func recordedService(
        in networkSet: SCNetworkSet,
        state: NetworkHelperState
    ) -> SCNetworkService? {
        guard let record = state.serviceRecord,
              (SCNetworkSetGetSetID(networkSet) as String?) == record.setID else {
            return nil
        }
        return services(in: networkSet).first { service in
            guard (SCNetworkServiceGetServiceID(service) as String?) == record.serviceID,
                  let interface = SCNetworkServiceGetInterface(service),
                  (SCNetworkInterfaceGetBSDName(interface) as String?) == record.bsdName else {
                return false
            }
            return true
        }
    }

    private func findLiveModemInterface() -> SCNetworkInterface? {
        let interfaces = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? []
        return interfaces.first { interface in
            guard (SCNetworkInterfaceGetInterfaceType(interface) as String?) ==
                    (kSCNetworkInterfaceTypeEthernet as String),
                  let bsdName = SCNetworkInterfaceGetBSDName(interface) as String? else {
                return false
            }
            return usbIdentity(forBSDName: bsdName) == targetUSBIdentity
        }
    }

    private func completeServiceOrder(_ networkSet: SCNetworkSet) -> [String] {
        let identifiers = services(in: networkSet)
            .compactMap { SCNetworkServiceGetServiceID($0) as String? }
        let validIdentifiers = Set(identifiers)
        var order = ((SCNetworkSetGetServiceOrder(networkSet) as? [String]) ?? [])
            .filter { validIdentifiers.contains($0) }
        for identifier in identifiers where !order.contains(identifier) {
            order.append(identifier)
        }
        return order
    }

    private func relativeOrderMatches(_ current: [String], _ expected: [String]) -> Bool {
        let expectedIDs = Set(expected)
        guard current.allSatisfy(expectedIDs.contains) else { return false }
        let currentIDs = Set(current)
        return current == expected.filter { currentIDs.contains($0) }
    }

    private func systemConfigurationError(_ prefix: String) -> String {
        let code = SCError()
        guard code != kSCStatusOK else { return prefix }
        return "\(prefix)：\(String(cString: SCErrorString(code)))"
    }

    private struct USBIdentity: Equatable {
        let vendorID: Int
        let productID: Int
    }

    private func usbIdentity(forBSDName bsdName: String) -> USBIdentity? {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
        let networkInterface = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard networkInterface != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(networkInterface) }

        let options = IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively)
        func integerProperty(_ key: String) -> Int? {
            (IORegistryEntrySearchCFProperty(
                networkInterface,
                kIOServicePlane,
                key as CFString,
                kCFAllocatorDefault,
                options
            ) as? NSNumber)?.intValue
        }

        guard let vendorID = integerProperty(kUSBVendorID),
              let productID = integerProperty(kUSBProductID) else {
            return nil
        }
        return USBIdentity(vendorID: vendorID, productID: productID)
    }
}
