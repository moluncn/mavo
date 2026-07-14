import Foundation
import IOKit
import IOKit.network
import IOKit.usb
import SystemConfiguration

final class NetworkServiceController {
    var onStatus: ((CellularNetworkStatus) -> Void)?

    private let queue = DispatchQueue(label: "app.mavo.mac.network", qos: .userInitiated)
    private let helperClient = NetworkHelperClient()
    private var timer: DispatchSourceTimer?
    private var lastPublishedStatus: CellularNetworkStatus?
    private let serviceRecordKey = "MaVo.modemNetworkServiceRecord"
    private let knownNames = ["baiwang", "qdc507", "quectel", "ec25", "eg25"]

    func startMonitoring() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .seconds(5), leeway: .milliseconds(750))
            timer.setEventHandler { [weak self] in self?.refreshNow() }
            self.timer = timer
            timer.resume()
        }
    }

    func stopMonitoring() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    func refresh() {
        queue.async { [weak self] in self?.refreshNow() }
    }

    func setEnabled(_ enabled: Bool, completion: @escaping (ModemActionResult) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            if enabled && self.findLiveModemInterface() == nil {
                DispatchQueue.main.async {
                    completion(.failure(
                        "没有找到实时 QDC507 CDC-ECM 接口；未安装 helper，也未修改网络配置。"
                    ))
                }
                return
            }
            self.helperClient.setCellularNetworking(enabled) { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    self.refreshNow()
                    DispatchQueue.main.async { completion(result) }
                }
            }
        }
    }

    private func refreshNow() {
        let status = readStatus()
        guard lastPublishedStatus != status else { return }
        lastPublishedStatus = status
        DispatchQueue.main.async { [weak self] in self?.onStatus?(status) }
    }

    private func readStatus() -> CellularNetworkStatus {
        guard let preferences = SCPreferencesCreate(nil, "MaVo" as NSString, nil),
              let networkSet = SCNetworkSetCopyCurrent(preferences) else {
            return CellularNetworkStatus(lastError: systemConfigurationError("无法读取网络配置"))
        }
        let liveInterface = findLiveModemInterface()
        let liveService = findLiveModemService(in: networkSet)
        let service = liveService ?? recordedService(in: networkSet) ?? namedDisplayService(in: networkSet)
        guard let service else {
            return CellularNetworkStatus(
                bsdName: liveInterface.flatMap { SCNetworkInterfaceGetBSDName($0) as String? },
                isHardwarePresent: liveInterface != nil
            )
        }

        let serviceID = SCNetworkServiceGetServiceID(service) as String?
        let serviceName = SCNetworkServiceGetName(service) as String?
        let interface = SCNetworkServiceGetInterface(service)
        let bsdName = interface.flatMap { SCNetworkInterfaceGetBSDName($0) as String? }
        let order = (SCNetworkSetGetServiceOrder(networkSet) as? [String]) ?? []
        let activeIPv4 = bsdName.flatMap(activeIPv4Address)
        let activeIPv6 = bsdName.flatMap(activeGlobalIPv6Address)
        let linkActive = bsdName.flatMap(activeLinkStatus) ??
            (activeIPv4 != nil || activeIPv6 != nil)
        if liveService != nil,
           let serviceID,
           let bsdName,
           let setID = SCNetworkSetGetSetID(networkSet) as String? {
            saveServiceRecord(ServiceRecord(setID: setID, serviceID: serviceID, bsdName: bsdName))
        }

        return CellularNetworkStatus(
            serviceID: serviceID,
            serviceName: serviceName,
            bsdName: bsdName,
            isEnabled: SCNetworkServiceGetEnabled(service),
            isActive: linkActive && (activeIPv4 != nil || activeIPv6 != nil),
            isLinkActive: linkActive,
            isPrioritized: serviceID.map { order.first == $0 } ?? false,
            isHardwarePresent: liveInterface != nil,
            ipv4Address: activeIPv4,
            ipv6Address: activeIPv6,
            lastError: nil
        )
    }

    private func services(in networkSet: SCNetworkSet) -> [SCNetworkService] {
        guard let rawServices = SCNetworkSetCopyServices(networkSet) else { return [] }
        return (rawServices as? [SCNetworkService]) ?? []
    }

    private func findLiveModemService(in networkSet: SCNetworkSet) -> SCNetworkService? {
        services(in: networkSet).first { service in
            guard let interface = SCNetworkServiceGetInterface(service),
                  (SCNetworkInterfaceGetInterfaceType(interface) as String?) == (kSCNetworkInterfaceTypeEthernet as String),
                  let bsdName = SCNetworkInterfaceGetBSDName(interface) as String? else {
                return false
            }
            return usbIdentity(forBSDName: bsdName) == USBIdentity(vendorID: 0x2C7C, productID: 0x0125)
        }
    }

    private func recordedService(in networkSet: SCNetworkSet) -> SCNetworkService? {
        guard let record = loadServiceRecord(),
              (SCNetworkSetGetSetID(networkSet) as String?) == record.setID else {
            return nil
        }
        return services(in: networkSet).first {
            (SCNetworkServiceGetServiceID($0) as String?) == record.serviceID &&
                (SCNetworkServiceGetInterface($0).flatMap { SCNetworkInterfaceGetBSDName($0) as String? }) == record.bsdName
        }
    }

    private func namedDisplayService(in networkSet: SCNetworkSet) -> SCNetworkService? {
        services(in: networkSet).first { service in
            guard let interface = SCNetworkServiceGetInterface(service),
                  (SCNetworkInterfaceGetInterfaceType(interface) as String?) == (kSCNetworkInterfaceTypeEthernet as String) else {
                return false
            }
            let serviceName = (SCNetworkServiceGetName(service) as String?) ?? ""
            let interfaceName = (SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?) ?? ""
            return isKnownModemName(serviceName) || isKnownModemName(interfaceName)
        }
    }

    private func findLiveModemInterface() -> SCNetworkInterface? {
        let rawInterfaces = SCNetworkInterfaceCopyAll()
        let interfaces = (rawInterfaces as? [SCNetworkInterface]) ?? []
        return interfaces.first { interface in
            guard (SCNetworkInterfaceGetInterfaceType(interface) as String?) == (kSCNetworkInterfaceTypeEthernet as String),
                  let bsdName = SCNetworkInterfaceGetBSDName(interface) as String? else { return false }
            return usbIdentity(forBSDName: bsdName) == USBIdentity(vendorID: 0x2C7C, productID: 0x0125)
        }
    }

    private func isKnownModemName(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return knownNames.contains { normalized.contains($0) }
    }

    private func activeIPv4Address(forBSDName bsdName: String) -> String? {
        let key = "State:/Network/Interface/\(bsdName)/IPv4" as NSString
        guard let value = SCDynamicStoreCopyValue(nil, key),
              let dictionary = value as? [String: Any],
              let addresses = dictionary["Addresses"] as? [String] else {
            return nil
        }
        return addresses.first
    }

    private func activeGlobalIPv6Address(forBSDName bsdName: String) -> String? {
        let key = "State:/Network/Interface/\(bsdName)/IPv6" as NSString
        guard let value = SCDynamicStoreCopyValue(nil, key),
              let dictionary = value as? [String: Any],
              let addresses = dictionary["Addresses"] as? [String] else {
            return nil
        }
        return addresses.first { address in
            let normalized = address.lowercased()
            return normalized != "::1" && !normalized.hasPrefix("fe80:")
        }
    }

    private func activeLinkStatus(forBSDName bsdName: String) -> Bool? {
        let key = "State:/Network/Interface/\(bsdName)/Link" as NSString
        guard let value = SCDynamicStoreCopyValue(nil, key),
              let dictionary = value as? [String: Any] else {
            return nil
        }
        return dictionary["Active"] as? Bool
    }

    private func systemConfigurationError(_ prefix: String) -> String {
        let code = SCError()
        guard code != kSCStatusOK else { return prefix }
        return "\(prefix)：\(String(cString: SCErrorString(code)))"
    }

    private struct ServiceRecord: Codable {
        let setID: String
        let serviceID: String
        let bsdName: String
    }

    private func saveServiceRecord(_ record: ServiceRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        UserDefaults.standard.set(data, forKey: serviceRecordKey)
    }

    private func loadServiceRecord() -> ServiceRecord? {
        guard let data = UserDefaults.standard.data(forKey: serviceRecordKey) else { return nil }
        return try? JSONDecoder().decode(ServiceRecord.self, from: data)
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
