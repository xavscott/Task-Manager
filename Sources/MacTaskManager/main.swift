import SwiftUI
import Charts
import Darwin
import IOKit
import IOKit.ps
import IOKit.hid
import IOBluetooth
import ObjectiveC.runtime
import AppKit
import Metal

@main
struct MacTaskManagerApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appLifecycleDelegate
    @StateObject private var monitor = SystemMonitor()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(monitor)
                .frame(minWidth: 840, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 850)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("View") {
                Button("Refresh Now") { monitor.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

private final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum Page: String, CaseIterable, Identifiable {
    case summary = "Summary", performance = "Performance", processes = "Processes", appleDevices = "Ecosystem", systemInfo = "System Info", startupApps = "Startup apps", users = "Users"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .summary: "gauge.with.dots.needle.50percent"
        case .performance: "waveform.path"
        case .processes: "list.bullet.rectangle"
        case .appleDevices: "apple.logo"
        case .systemInfo: "info.circle"
        case .startupApps: "power"
        case .users: "person.2"
        }
    }
}

struct StartupItem: Identifiable {
    let name: String
    let location: String
    let program: String
    var id: String { location }
}

struct ProcessRow: Identifiable {
    let pid: Int32
    let name: String
    let user: String
    let memory: UInt64
    let cpu: Double
    let threads: Int
    var id: Int32 { pid }
}

struct Sample: Identifiable {
    let id = UUID()
    let time: Date
    let value: Double
}

struct ExternalVolume: Identifiable {
    let name: String
    let path: String
    let total: Int64
    let free: Int64
    var id: String { path }
}

struct AppleDevice: Identifiable {
    let name: String
    let model: String
    let connection: String
    let batteryPercent: Int?
    let batteryLevels: [String: Int]
    var id: String { name.lowercased() }
}

struct EnergyStatus {
    let batteryPercent: Double?
    let batteryHealth: String?
    let cycleCount: Int?
    let adapterWatts: Double?
    let powerSource: String
    let charging: Bool
    let lowPowerMode: Bool
}

struct DiskCounters {
    let read: UInt64
    let written: UInt64
}

struct HardwareInfo {
    let model: String
    let chip: String
    let cores: Int
    let physicalCores: Int
    let memory: UInt64
    let memoryVendor: String
    let memoryType: String
    let gpuCores: String
    let macOS: String

    static func read() -> HardwareInfo {
        let model = sysctlString("hw.model") ?? "Mac"
        let chip = sysctlString("machdep.cpu.brand_string") ?? model
        let cores = Int(ProcessInfo.processInfo.processorCount)
        let physicalCores = sysctlInteger("hw.physicalcpu") ?? cores
        let memory = ProcessInfo.processInfo.physicalMemory
        let profiler = readSystemProfiler()
        let memorySection = (profiler as? [String: Any])?["SPMemoryDataType"]
        let displaySection = (profiler as? [String: Any])?["SPDisplaysDataType"]
        let memoryVendor = profilerValue(in: memorySection, matching: ["dimm_manufacturer", "memory_manufacturer", "manufacturer"])
            ?? "Not exposed by macOS"
        let reportedMemoryType = profilerValue(in: memorySection, matching: ["dimm_type", "memory_type", "memory type"])
        let memoryType = reportedMemoryType ?? "Unified memory (DDR version not exposed)"
        let gpuCores = profilerValue(in: displaySection, matching: ["gpu_cores", "spdisplays_cores", "sppci_cores", "total_number_of_cores", "core_count"])
            ?? "Not reported by macOS"
        return HardwareInfo(model: model, chip: chip.trimmingCharacters(in: .whitespacesAndNewlines), cores: cores,
                            physicalCores: physicalCores, memory: memory, memoryVendor: memoryVendor,
                            memoryType: memoryType, gpuCores: gpuCores, macOS: ProcessInfo.processInfo.operatingSystemVersionString)
    }
}

private func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
    return String(cString: bytes)
}

private func sysctlInteger(_ name: String) -> Int? {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0, value > 0 else { return nil }
    return Int(value)
}

private func readSystemProfiler() -> Any? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    process.arguments = ["-json", "SPMemoryDataType", "SPDisplaysDataType"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return try JSONSerialization.jsonObject(with: data)
    } catch {
        return nil
    }
}

private func profilerValue(in root: Any?, matching needles: [String]) -> String? {
    func visit(_ value: Any) -> [String] {
        if let dictionary = value as? [String: Any] {
            var matches: [String] = []
            for (key, nested) in dictionary {
                let normalizedKey = key.lowercased().replacingOccurrences(of: " ", with: "_")
                if needles.contains(where: normalizedKey.contains),
                   let text = nested as? String,
                   !text.isEmpty,
                   !text.localizedCaseInsensitiveContains("unknown") {
                    matches.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    matches.append(contentsOf: visit(nested))
                }
            }
            return matches
        }
        if let array = value as? [Any] { return array.flatMap(visit) }
        return []
    }
    let values = visit(root ?? NSNull())
    let unique = Array(NSOrderedSet(array: values)) as? [String] ?? values
    guard !unique.isEmpty else { return nil }
    return unique.joined(separator: ", ")
}

final class SystemMonitor: ObservableObject {
    @Published var processes: [ProcessRow] = []
    @Published var cpuHistory: [Sample] = []
    @Published var memoryHistory: [Sample] = []
    @Published var networkHistory: [Sample] = []
    @Published var diskHistory: [Sample] = []
    @Published var diskReadRate = 0.0
    @Published var diskWriteRate = 0.0
    @Published var gpuHistory: [Sample] = []
    @Published var gpuUsage: Double?
    @Published var externalVolumes: [ExternalVolume] = []
    @Published var appleDevices: [AppleDevice] = []
    @Published var energyStatus = EnergyStatus(batteryPercent: nil, batteryHealth: nil, cycleCount: nil, adapterWatts: nil, powerSource: "Checking…", charging: false, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    @Published var batteryHistory: [Sample] = []
    @Published var cpuUsage = 0.0
    @Published var memoryUsed: UInt64 = 0
    @Published var networkRate = 0.0
    @Published var uptime: TimeInterval = 0
    @Published var lastUpdated = Date()
    let hardware = HardwareInfo.read()
    private var timer: Timer?
    private var previousCPU: [Int32: UInt64] = [:]
    private var previousNetwork: UInt64 = 0
    private var previousDisk: DiskCounters?
    private var previousDate = Date()

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        let now = Date()
        let interval = max(now.timeIntervalSince(previousDate), 0.1)
        let (rows, totals) = Self.readProcesses(previous: previousCPU, interval: interval)
        previousCPU = totals
        processes = rows.sorted { $0.cpu > $1.cpu }
        cpuUsage = min(100, processes.reduce(0) { $0 + $1.cpu } / Double(max(hardware.cores, 1)))
        memoryUsed = Self.readMemoryUsed()
        let net = Self.readNetworkBytes()
        // Ignore loopback and cap counter discontinuities at a 10 Gbit/s physical link rate.
        let measuredNetworkRate = Double(net >= previousNetwork ? net - previousNetwork : 0) / interval
        networkRate = min(measuredNetworkRate, 1_250_000_000)
        previousNetwork = net
        uptime = ProcessInfo.processInfo.systemUptime
        append(cpuUsage, to: &cpuHistory, at: now)
        let total = max(Double(hardware.memory), 1)
        append(Double(memoryUsed) / total * 100, to: &memoryHistory, at: now)
        append(networkRate * 8 / 1_000_000, to: &networkHistory, at: now)
        let disk = Self.readDiskCounters()
        if let previousDisk {
            diskReadRate = Double(disk.read >= previousDisk.read ? disk.read - previousDisk.read : 0) / interval
            diskWriteRate = Double(disk.written >= previousDisk.written ? disk.written - previousDisk.written : 0) / interval
        }
        previousDisk = disk
        append((diskReadRate + diskWriteRate) * 8 / 1_000_000, to: &diskHistory, at: now)
        gpuUsage = Self.readGPUUsage()
        if let gpuUsage { append(gpuUsage, to: &gpuHistory, at: now) }
        externalVolumes = Self.readExternalVolumes()
        energyStatus = Self.readEnergyStatus()
        if let battery = energyStatus.batteryPercent { append(battery, to: &batteryHistory, at: now) }
        previousDate = now
        lastUpdated = now
    }

    func refreshAppleDevices() {
        appleDevices = Self.readAppleDevices()
    }

    func terminate(_ process: ProcessRow) -> Bool {
        guard process.pid != getpid(), kill(process.pid, SIGTERM) == 0 else { return false }
        refresh()
        return true
    }

    private func append(_ value: Double, to samples: inout [Sample], at date: Date) {
        samples.append(Sample(time: date, value: value))
        if samples.count > 60 { samples.removeFirst(samples.count - 60) }
    }

    private static func readProcesses(previous: [Int32: UInt64], interval: Double) -> ([ProcessRow], [Int32: UInt64]) {
        var count = proc_listallpids(nil, 0)
        guard count > 0 else { return ([], [:]) }
        var pids = [pid_t](repeating: 0, count: Int(count) + 16)
        count = pids.withUnsafeMutableBufferPointer { proc_listallpids($0.baseAddress, Int32($0.count) * Int32(MemoryLayout<pid_t>.size)) }
        guard count > 0 else { return ([], [:]) }
        var rows: [ProcessRow] = []
        var totals: [Int32: UInt64] = [:]
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var task = proc_taskinfo()
            let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize else { continue }
            var bsd = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            _ = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize)
            var nameBuffer = [CChar](repeating: 0, count: 256)
            let name = nameBuffer.withUnsafeMutableBufferPointer { proc_name(pid, $0.baseAddress, UInt32($0.count)) > 0 ? String(cString: $0.baseAddress!) : "Process" }
            let ticks = task.pti_total_user + task.pti_total_system
            totals[pid] = ticks
            let delta = ticks >= previous[pid, default: ticks] ? ticks - previous[pid, default: ticks] : 0
            let cpu = Double(delta) / 1_000_000_000 / interval * 100
            let username = getpwuid(bsd.pbi_uid).map { String(cString: $0.pointee.pw_name) } ?? "—"
            rows.append(ProcessRow(pid: pid, name: name, user: username, memory: task.pti_resident_size, cpu: cpu, threads: Int(task.pti_threadnum)))
        }
        return (rows, totals)
    }

    private static func readMemoryUsed() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pageSize = UInt64(getpagesize())
        let active = UInt64(stats.active_count + stats.wire_count + stats.compressor_page_count)
        return active * pageSize
    }

    private static func readNetworkBytes() -> UInt64 {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return 0 }
        defer { freeifaddrs(list) }
        var total: UInt64 = 0
        var item: UnsafeMutablePointer<ifaddrs>? = first
        while let current = item {
            let data = current.pointee.ifa_data
            let interfaceName = String(cString: current.pointee.ifa_name)
            if interfaceName.hasPrefix("en"),
               current.pointee.ifa_addr.pointee.sa_family == UInt8(AF_LINK), let data {
                let stats = data.assumingMemoryBound(to: if_data.self).pointee
                total += UInt64(stats.ifi_ibytes) + UInt64(stats.ifi_obytes)
            }
            item = current.pointee.ifa_next
        }
        return total
    }

    private static func readGPUUsage() -> Double? {
        guard let matching = IOServiceMatching("IOAccelerator") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var readings: [Double] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            guard let property = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] else { continue }
            if let value = (property["Device Utilization %"] ?? property["GPU Activity(%)"]) as? NSNumber {
                readings.append(value.doubleValue)
            }
        }
        return readings.max().map { min(max($0, 0), 100) }
    }

    private static func readExternalVolumes() -> [ExternalVolume] {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        return (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? [])
            .compactMap { url -> ExternalVolume? in
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.volumeIsInternal == false || values.volumeIsRemovable == true || values.volumeIsEjectable == true,
                      let total = values.volumeTotalCapacity else { return nil }
                return ExternalVolume(name: values.volumeName ?? url.lastPathComponent, path: url.path,
                                      total: Int64(total), free: Int64(values.volumeAvailableCapacity ?? 0))
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func readAppleDevices() -> [AppleDevice] {
        var devices: [String: AppleDevice] = [:]
        let registryBatteries = readAppleAccessoryBatteries()
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        if IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess {
            defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
            let hidDevices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
            for device in hidDevices {
                let product = (IOHIDDeviceGetProperty(device, "Product" as CFString) as? String) ?? "Apple accessory"
                let manufacturer = (IOHIDDeviceGetProperty(device, "Manufacturer" as CFString) as? String) ?? ""
                let vendorID = (IOHIDDeviceGetProperty(device, "VendorID" as CFString) as? NSNumber)?.intValue
                guard (manufacturer.localizedCaseInsensitiveContains("Apple") || vendorID == 1452),
                      !product.localizedCaseInsensitiveContains("internal") else { continue }
                let battery = (IOHIDDeviceGetProperty(device, "BatteryPercent" as CFString) as? NSNumber)?.intValue
                    ?? (IOHIDDeviceGetProperty(device, "BatteryLevel" as CFString) as? NSNumber)?.intValue
                let transport = (IOHIDDeviceGetProperty(device, "Transport" as CFString) as? String) ?? "Connected"
                let level = battery.map { min(max($0, 0), 100) }
                let item = AppleDevice(name: product, model: product, connection: transport.capitalized,
                                       batteryPercent: level, batteryLevels: level.map { ["Battery": $0] } ?? [:])
                devices[product.lowercased()] = item
            }
        }

        let bluetoothDevices = connectedBluetoothDevices()
        let bluetoothBatteryCache = readBluetoothBatteryCache()
        for device in bluetoothDevices where device.isConnected() {
            let name = device.name ?? device.nameOrAddress ?? "Bluetooth accessory"
            guard isAppleAccessory(name) else { continue }
            let key = name.lowercased()
            let existing = devices[key]
            let address = normalizeBluetoothAddress(device.addressString)
            // Control Center can keep the last case level in Bluetooth's DeviceCache
            // under the accessory's user-assigned name, even when the live case getter
            // reports 0 (the case is asleep). Resolve by address first, then cache aliases.
            var levels = bluetoothBatteryCache.levels(forAddress: address, names: [name, device.nameOrAddress ?? "", existing?.model ?? ""])
            if levels.isEmpty { levels = existing?.batteryLevels ?? [:] }
            for (label, property) in [("Left", "batteryPercentLeft"), ("Right", "batteryPercentRight"), ("Case", "batteryPercentCase"), ("Battery", "batteryPercentSingle")] {
                if let liveLevel = privateBluetoothBatteryLevel(device, property: property) {
                    levels[label] = liveLevel
                }
            }
            let aggregate = levels["Battery"] ?? levels["Left"].flatMap { left in levels["Right"].map { (left + $0) / 2 } } ?? existing?.batteryPercent
            devices[key] = AppleDevice(name: name, model: existing?.model ?? name, connection: "Bluetooth",
                                       batteryPercent: aggregate ?? registryBatteries[address], batteryLevels: levels)
        }
        return devices.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func privateBluetoothBatteryLevel(_ device: IOBluetoothDevice, property: String) -> Int? {
        let selector = NSSelectorFromString(property)
        guard device.responds(to: selector),
              let value = device.value(forKey: property) as? NSNumber else { return nil }
        let percent = value.intValue
        // A zero case value commonly means the case is asleep and hasn't reported recently.
        guard percent > 0, percent <= 100 else { return nil }
        return percent
    }

    private static func connectedBluetoothDevices() -> [IOBluetoothDevice] {
        // macOS keeps live AirPods battery fields on connected-device objects. This class
        // method is private, so retain the public paired-device path as a fallback.
        let selector = NSSelectorFromString("connectedDevices")
        if let method = class_getClassMethod(IOBluetoothDevice.self, selector) {
            typealias ConnectedDevicesFunction = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
            let implementation = method_getImplementation(method)
            let function = unsafeBitCast(implementation, to: ConnectedDevicesFunction.self)
            if let result = function(IOBluetoothDevice.self, selector)?.takeUnretainedValue() as? [IOBluetoothDevice] {
                return result
            }
        }
        return IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
    }

    private static func readAppleAccessoryBatteries() -> [String: Int] {
        // Apple publishes accessory battery data on this I/O Registry service, rather than
        // as a standard IOHIDDevice property on some macOS and accessory combinations.
        guard let matching = IOServiceMatching("AppleDeviceManagementHIDEventService") else { return [:] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }

        var batteries: [String: Int] = [:]
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            let transport = IORegistryEntryCreateCFProperty(service, "Transport" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            let manufacturer = IORegistryEntryCreateCFProperty(service, "Manufacturer" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            guard transport == "Bluetooth", manufacturer?.localizedCaseInsensitiveContains("Apple") == true,
                  let address = IORegistryEntryCreateCFProperty(service, "DeviceAddress" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                  let percent = IORegistryEntryCreateCFProperty(service, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber else { continue }
            batteries[normalizeBluetoothAddress(address)] = min(max(percent.intValue, 0), 100)
        }
        return batteries
    }

    private static func normalizeBluetoothAddress(_ address: String?) -> String {
        (address ?? "").filter(\.isHexDigit).lowercased()
    }

    private struct BluetoothBatteryCache {
        var byAddress: [String: [String: Int]] = [:]
        var byName: [String: [String: Int]] = [:]

        func levels(forAddress address: String, names: [String]) -> [String: Int] {
            if let levels = byAddress[address], !levels.isEmpty { return levels }
            for name in names where !name.isEmpty {
                if let levels = byName[name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()], !levels.isEmpty {
                    return levels
                }
            }
            return [:]
        }
    }

    private static func readBluetoothBatteryCache() -> BluetoothBatteryCache {
        let url = URL(fileURLWithPath: "/Library/Preferences/com.apple.Bluetooth.plist")
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let deviceCache = root["DeviceCache"] as? [String: Any] else { return BluetoothBatteryCache() }

        var result = BluetoothBatteryCache()
        let keys = [("Left", "BatteryPercentLeft"), ("Right", "BatteryPercentRight"), ("Case", "BatteryPercentCase"),
                    ("Battery", "BatteryPercent"), ("Battery", "BatteryPercentCombined"), ("Battery", "BatteryPercentSingle")]
        for (address, value) in deviceCache {
            guard let record = value as? [String: Any] else { continue }
            var levels: [String: Int] = [:]
            for (label, key) in keys {
                if let percent = (record[key] as? NSNumber)?.intValue { levels[label] = min(max(percent, 0), 100) }
            }
            guard !levels.isEmpty else { continue }
            result.byAddress[normalizeBluetoothAddress(address)] = levels
            // Bluetooth stores the friendly name separately from the IOBluetooth model
            // name (for example, “Xyna” versus “AirPods 4”). Index those names too.
            for field in ["Name", "DeviceName", "UserName", "ProductName", "Product", "Model", "ModelName"] {
                if let alias = record[field] as? String {
                    result.byName[alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = levels
                }
            }
        }
        return result
    }

    private static func isAppleAccessory(_ name: String) -> Bool {
        let name = name.lowercased()
        return ["airpods", "magic mouse", "magic keyboard", "magic trackpad", "beats"].contains { name.contains($0) }
    }

    private static func readEnergyStatus() -> EnergyStatus {
        let lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return EnergyStatus(batteryPercent: nil, batteryHealth: nil, cycleCount: nil, adapterWatts: adapterWatts(), powerSource: "AC power or unavailable", charging: false, lowPowerMode: lowPowerMode)
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  let type = description[kIOPSTypeKey as String] as? String,
                  type == kIOPSInternalBatteryType else { continue }
            let current = (description[kIOPSCurrentCapacityKey as String] as? NSNumber)?.doubleValue
            let maximum = (description[kIOPSMaxCapacityKey as String] as? NSNumber)?.doubleValue
            let percent: Double? = if let current, let maximum, maximum > 0 { current / maximum * 100 } else { nil }
            let charging = description[kIOPSIsChargingKey as String] as? Bool ?? false
            let maximumCapacity = readBatteryMaximumCapacity()
            let batteryHealth = maximumCapacity.map { "\($0)%" }
            let state = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as? String
            return EnergyStatus(batteryPercent: percent, batteryHealth: batteryHealth, cycleCount: readBatteryCycleCount(), adapterWatts: adapterWatts(), powerSource: state == kIOPSBatteryPowerValue ? "Battery" : "Power adapter",
                                charging: charging, lowPowerMode: lowPowerMode)
        }
        return EnergyStatus(batteryPercent: nil, batteryHealth: nil, cycleCount: nil, adapterWatts: adapterWatts(), powerSource: "Power adapter", charging: false, lowPowerMode: lowPowerMode)
    }

    private static func readBatteryCycleCount() -> Int? {
        guard let matching = IOServiceMatching("AppleSmartBattery") else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(service, "CycleCount" as CFString, kCFAllocatorDefault, 0) else { return nil }
        return (property.takeRetainedValue() as? NSNumber)?.intValue
    }

    private static func readBatteryMaximumCapacity() -> Int? {
        guard let matching = IOServiceMatching("AppleSmartBattery") else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(service, "MaxCapacity" as CFString, kCFAllocatorDefault, 0) else { return nil }
        let capacity = (property.takeRetainedValue() as? NSNumber)?.intValue
        return capacity.flatMap { (0...100).contains($0) ? $0 : nil }
    }

    private static func adapterWatts() -> Double? {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] else { return nil }
        return (details[kIOPSPowerAdapterWattsKey as String] as? NSNumber)?.doubleValue
    }

    private static func readDiskCounters() -> DiskCounters {
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else { return DiskCounters(read: 0, written: 0) }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return DiskCounters(read: 0, written: 0) }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0
        var written: UInt64 = 0
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] else { continue }
            read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            written += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return DiskCounters(read: read, written: written)
    }
}

enum PerformanceResource: String, CaseIterable, Identifiable {
    case cpu = "CPU", memory = "Memory", disk = "Disk", network = "Wi-Fi", gpu = "GPU", energy = "Energy"
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .cpu: Color(red: 0.12, green: 0.57, blue: 0.72)
        case .memory: Color(red: 0.27, green: 0.40, blue: 0.84)
        case .disk: Color(red: 0.32, green: 0.58, blue: 0.23)
        case .network: Color(red: 0.42, green: 0.32, blue: 0.78)
        case .gpu: Color(red: 0.78, green: 0.36, blue: 0.22)
        case .energy: Color(red: 0.24, green: 0.62, blue: 0.38)
        }
    }
    var icon: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .network: "wifi"
        case .gpu: "gpu"
        case .energy: "bolt"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @Environment(\.colorScheme) private var colorScheme
    @State private var page: Page = .performance
    @State private var resource: PerformanceResource = .cpu
    @State private var query = ""
    @State private var selectedProcess: ProcessRow?
    @State private var processSortColumn: ProcessSortColumn = .cpu
    @State private var processSortAscending = false
    @State private var showTerminateConfirm = false
    @State private var terminateMessage: String?
    @State private var startupItems: [StartupItem] = []

    private var isDark: Bool { colorScheme == .dark }
    private var ink: Color { isDark ? .white : Color(red: 0.11, green: 0.12, blue: 0.14) }
    private var muted: Color { isDark ? Color.white.opacity(0.66) : Color(red: 0.38, green: 0.40, blue: 0.43) }
    private var rail: Color { isDark ? Color(red: 0.12, green: 0.13, blue: 0.15) : Color(red: 0.95, green: 0.96, blue: 0.97) }
    private var surface: Color { isDark ? Color(red: 0.10, green: 0.11, blue: 0.13) : .white }
    private var panel: Color { isDark ? Color(red: 0.15, green: 0.16, blue: 0.18) : Color(red: 0.985, green: 0.987, blue: 0.99) }
    private var cardFill: Color { isDark ? Color.white.opacity(0.055) : Color.black.opacity(0.035) }
    private var hairline: Color { isDark ? Color.white.opacity(0.13) : Color.black.opacity(0.12) }
    private var chartSurface: Color { isDark ? Color(red: 0.12, green: 0.13, blue: 0.15) : Color(red: 0.995, green: 0.997, blue: 1) }

    var body: some View {
        ZStack(alignment: .leading) {
            VStack(spacing: 0) {
                switch page {
                case .summary: summaryPage
                case .performance: performancePage
                case .processes: processesPage
                case .appleDevices: appleDevicesPage
                case .systemInfo: systemInfoPage
                case .startupApps: startupAppsPage
                case .users: usersPage
                }
            }
            .padding(.leading, 205)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
            .background(surface.opacity(0.78))

            sidebar
                .padding(.leading, 8)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .zIndex(2)
        }
        .frame(minWidth: 840, minHeight: 600)
        .background {
            ZStack {
                surface
                RadialGradient(colors: [Color.purple.opacity(isDark ? 0.19 : 0.10), .clear], center: .topLeading, startRadius: 20, endRadius: 620)
                RadialGradient(colors: [Color.blue.opacity(isDark ? 0.12 : 0.07), .clear], center: .bottomTrailing, startRadius: 10, endRadius: 560)
            }
        }
        .foregroundStyle(ink)
        .onAppear { startupItems = readStartupItems() }
        .alert("End process?", isPresented: $showTerminateConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("End task", role: .destructive) {
                if let selectedProcess {
                    let ok = monitor.terminate(selectedProcess)
                    terminateMessage = ok ? "Termination signal sent to \(selectedProcess.name)." : "Could not end this process. It may require administrator access."
                }
            }
        } message: { Text("This sends a termination signal to \(selectedProcess?.name ?? "the selected process"). Unsaved work may be lost.") }
        .alert("Process", isPresented: Binding(get: { terminateMessage != nil }, set: { if !$0 { terminateMessage = nil } })) {
            Button("OK") { terminateMessage = nil }
        } message: { Text(terminateMessage ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Page.allCases) { item in
                navButton(item, selected: page == item) { page = item }
            }
            Spacer(minLength: 12)
        }
        .padding(.top, 48)
        .frame(width: 195)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(rail.opacity(isDark ? 0.38 : 0.48), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(isDark ? 0.11 : 0.24), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
    }

    private func navButton(_ item: Page, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: item.icon).font(.system(size: 16)).frame(width: 20)
                Text(item.rawValue).font(.system(size: 14, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? (isDark ? Color(red: 0.94, green: 0.79, blue: 0.97) : Color(red: 0.35, green: 0.19, blue: 0.37)) : ink)
            .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(selected ? Color.purple.opacity(isDark ? 0.17 : 0.09) : .clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 9)
        .contentShape(Rectangle())
    }

    private var performancePage: some View {
        HStack(spacing: 0) {
            VStack(spacing: 7) {
                ForEach(PerformanceResource.allCases) { item in resourceTile(item) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 12)
            .frame(width: 250)
            .background(panel)
            Rectangle().fill(hairline).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(resource.rawValue).font(.system(size: 26, weight: .regular))
                        Spacer()
                        Text(resourceSubtitle)
                            .font(.system(size: 16)).foregroundStyle(ink).lineLimit(1)
                    }
                    Text(resourceMetricLabel)
                        .font(.system(size: 11)).foregroundStyle(muted)
                    if resource == .gpu && monitor.gpuUsage == nil {
                        ContentUnavailableView("GPU usage unavailable", systemImage: "gpu", description: Text("This Mac does not expose a GPU utilization counter to apps."))
                            .frame(height: 270)
                    } else if resource == .energy && monitor.energyStatus.batteryPercent == nil {
                        ContentUnavailableView("No battery telemetry", systemImage: "bolt", description: Text("This Mac has no built-in battery. macOS does not expose system-wide power draw to regular apps."))
                            .frame(height: 270)
                    } else {
                        performanceChart.frame(height: 270)
                    }
                    HStack {
                        Text("60 seconds ago").font(.system(size: 10)).foregroundStyle(muted)
                        Spacer()
                        Text("Now").font(.system(size: 10)).foregroundStyle(muted)
                    }.padding(.top, -12)
                    if resource == .cpu { cpuStats }
                    else if resource == .memory { memoryStats }
                    else if resource == .disk { diskStats }
                    else if resource == .network { networkStats }
                    else if resource == .gpu { gpuStats }
                    else { energyStats }
                }
                .padding(.horizontal, 28).padding(.top, 25).padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(surface)
        }
    }

    private var resourceSubtitle: String {
        switch resource {
        case .cpu: monitor.hardware.chip
        case .memory: "Physical memory"
        case .disk: "Read and write activity"
        case .network: "Network interfaces"
        case .gpu: MTLCreateSystemDefaultDevice()?.name ?? "Graphics processor"
        case .energy: "Battery and power source"
        }
    }

    private var resourceMetricLabel: String {
        switch resource {
        case .cpu, .gpu: "Utilization"
        case .memory: "Memory composition"
        case .disk: "Disk read/write throughput"
        case .network: "Throughput"
        case .energy: "Battery charge (%) · system power draw unavailable"
        }
    }


    private var summaryPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 13) {
                    summaryMetric("CPU", String(format: "%.1f%%", monitor.cpuUsage), "Utilization", .cyan, monitor.cpuHistory)
                    summaryMetric("Memory", percentUsed, "\(bytes(monitor.memoryUsed)) in use", .purple, monitor.memoryHistory, fixedMaximum: 100)
                    summaryMetric("Network", rate(monitor.networkRate), "Current throughput", .green, monitor.networkHistory)
                }
                Text("Your device").font(.system(size: 17, weight: .semibold))
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 11) {
                    informationCard("Model", monitor.hardware.model, "laptopcomputer")
                    informationCard("Processor", monitor.hardware.chip, "cpu")
                    informationCard("Installed memory", bytes(monitor.hardware.memory), "memorychip")
                    informationCard("CPU cores", "\(monitor.hardware.physicalCores) cores · \(monitor.hardware.cores) logical processors", "square.stack.3d.up")
                    informationCard("Operating system", monitor.hardware.macOS, "apple.logo")
                    informationCard("Uptime", duration(monitor.uptime), "clock")
                }
            }
            .padding(24)
        }
    }

    private var systemInfoPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Hardware and software details for this Mac.").font(.system(size: 12)).foregroundStyle(muted)
                Group {
                    systemSection("Hardware") {
                        detail("Model identifier", monitor.hardware.model)
                        detail("Chip / processor", monitor.hardware.chip)
                        detail("CPU cores", "\(monitor.hardware.physicalCores) physical · \(monitor.hardware.cores) logical")
                        detail("Logical processors", "\(monitor.hardware.cores)")
                        detail("Physical memory", bytes(monitor.hardware.memory))
                        detail("Memory vendor", monitor.hardware.memoryVendor)
                        detail("Memory type", monitor.hardware.memoryType)
                        detail("GPU cores", monitor.hardware.gpuCores)
                    }
                    systemSection("macOS") {
                        detail("Version", monitor.hardware.macOS)
                        detail("Computer name", Host.current().localizedName ?? monitor.hardware.model)
                        detail("Architecture", architecture)
                        detail("System uptime", duration(monitor.uptime))
                    }
                    systemSection("Current usage") {
                        detail("CPU utilization", String(format: "%.1f%%", monitor.cpuUsage))
                        detail("Memory in use", "\(bytes(monitor.memoryUsed)) (\(percentUsed))")
                        detail("Running processes", "\(monitor.processes.count)")
                        detail("Thread count", "\(monitor.processes.reduce(0) { $0 + $1.threads })")
                    }
                }
            }.padding(25)
        }
    }

    private var appleDevicesPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Connected Apple accessories detected over Bluetooth or USB/HID. Bluetooth access is requested only when you open this page.")
                    .font(.system(size: 12)).foregroundStyle(muted)
                if monitor.appleDevices.isEmpty {
                    ContentUnavailableView("No connected Apple accessories", systemImage: "apple.logo",
                        description: Text("Connect an Apple accessory such as AirPods, Magic Mouse, Magic Keyboard, or Magic Trackpad, then refresh."))
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                        ForEach(monitor.appleDevices) { device in
                            appleDeviceCard(device)
                        }
                    }
                }
                Text("Model and battery details depend on what the accessory reports to macOS.")
                    .font(.system(size: 11)).foregroundStyle(muted)
            }
            .padding(24)
        }
        .task {
            while !Task.isCancelled {
                monitor.refreshAppleDevices()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func appleDeviceCard(_ device: AppleDevice) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: appleDeviceIcon(device.name))
                    .font(.system(size: 24)).foregroundStyle(.blue)
                    .frame(width: 48, height: 48)
                    .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    Text("Model: \(device.model)").font(.system(size: 11)).foregroundStyle(muted).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Label(device.connection, systemImage: device.connection.localizedCaseInsensitiveContains("bluetooth") ? "wave.3.right" : "cable.connector")
                    .font(.system(size: 11)).foregroundStyle(muted)
            }
            if device.name.localizedCaseInsensitiveContains("AirPods") && ["Left", "Right", "Case"].contains(where: { device.batteryLevels[$0] != nil }) {
                HStack(spacing: 12) {
                    accessoryBattery("L", device.batteryLevels["Left"])
                    accessoryBattery("R", device.batteryLevels["Right"])
                    accessoryBattery("Case", device.batteryLevels["Case"])
                }
            } else if let battery = device.batteryPercent {
                Label("\(battery)%", systemImage: battery > 20 ? "battery.75percent" : "battery.25percent")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(battery <= 20 ? .orange : ink)
            } else {
                Text("Battery unavailable").font(.system(size: 11)).foregroundStyle(muted)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 14))
        .modifier(AdaptiveLiquidGlass(enabled: true, cornerRadius: 16))
    }

    private func accessoryBattery(_ title: String, _ percent: Int?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: percent.map { $0 <= 20 ? "battery.25percent" : "battery.75percent" } ?? "battery.0percent")
            Text("\(title) \(percent.map { "\($0)%" } ?? "—")")
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle((percent ?? 100) <= 20 ? Color.orange : ink)
    }

    private func appleDeviceIcon(_ name: String) -> String {
        let name = name.lowercased()
        if name.contains("airpods") || name.contains("beats") { return "airpodspro" }
        if name.contains("mouse") { return "computermouse" }
        if name.contains("keyboard") { return "keyboard" }
        if name.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        return "apple.logo"
    }

    private var startupAppsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Login items and background services").font(.system(size: 16, weight: .semibold))
                    Text("Launch agents and services found in macOS startup folders.").font(.system(size: 11)).foregroundStyle(muted)
                }
                Spacer()
                Button { startupItems = readStartupItems() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.buttonStyle(.bordered)
                Button { openLoginItemsSettings() } label: { Label("Login Items Settings", systemImage: "gearshape") }.buttonStyle(.borderedProminent)
            }
            if startupItems.isEmpty {
                ContentUnavailableView("No startup services found", systemImage: "power", description: Text("No launch agents or services were found in the standard startup folders."))
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("ITEM").frame(maxWidth: .infinity, alignment: .leading)
                        Text("SOURCE").frame(width: 170, alignment: .leading)
                    }.font(.system(size: 10, weight: .semibold)).foregroundStyle(muted).padding(12)
                    Divider()
                    ForEach(startupItems) { item in
                        HStack(spacing: 12) {
                            Image(systemName: "gearshape.2").foregroundStyle(.secondary).frame(width: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(item.program).font(.system(size: 10, design: .monospaced)).foregroundStyle(muted).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text(item.location.contains(NSHomeDirectory()) ? "User" : "System")
                                .font(.system(size: 11)).foregroundStyle(muted).frame(width: 170, alignment: .leading)
                        }.padding(12)
                        Divider()
                    }
                }.background(cardFill, in: RoundedRectangle(cornerRadius: 8))
            }
            Spacer(minLength: 0)
        }.padding(24)
    }

    private var usersPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Local home folders on this Mac").font(.system(size: 12)).foregroundStyle(muted)
            let currentUser = NSUserName()
            let accounts = (try? FileManager.default.contentsOfDirectory(atPath: "/Users")) ?? []
            if accounts.isEmpty {
                ContentUnavailableView("No users found", systemImage: "person.2")
            } else {
                ForEach(accounts.filter { $0 != "Shared" && !$0.hasPrefix(".") }.sorted(), id: \.self) { account in
                    HStack(spacing: 13) {
                        Image(systemName: "person.crop.circle.fill").font(.system(size: 27)).foregroundStyle(account == currentUser ? .blue : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(account).font(.system(size: 13, weight: .medium))
                            Text(account == currentUser ? "Current user" : "Local account").font(.system(size: 11)).foregroundStyle(muted)
                        }
                        Spacer()
                        if account == currentUser { Text("ACTIVE").font(.system(size: 9, weight: .bold)).tracking(0.7).foregroundStyle(.green) }
                    }.padding(13).background(cardFill, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            Text("This lists local home folders. macOS does not expose other users’ live sessions to regular apps.")
                .font(.system(size: 10)).foregroundStyle(muted)
            Spacer(minLength: 0)
        }.padding(24)
    }

    private var architecture: String {
        #if arch(arm64)
        "Apple Silicon (arm64)"
        #elseif arch(x86_64)
        "Intel (x86_64)"
        #else
        "Unknown"
        #endif
    }

    private func summaryMetric(_ title: String, _ value: String, _ detail: String, _ color: Color, _ samples: [Sample], fixedMaximum: Double? = nil) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.7).foregroundStyle(muted)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded))
            Text(detail).font(.system(size: 10)).foregroundStyle(muted).lineLimit(1)
            MiniChart(samples: samples, color: color, fixedMaximum: fixedMaximum).frame(height: 38)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(cardFill, in: RoundedRectangle(cornerRadius: 9))
            .modifier(AdaptiveLiquidGlass(enabled: true, cornerRadius: 12))
    }

    private func informationCard(_ title: String, _ value: String, _ icon: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon).foregroundStyle(.blue).frame(width: 30, height: 30).background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 10)).foregroundStyle(muted)
                Text(value).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }.padding(12).background(cardFill, in: RoundedRectangle(cornerRadius: 8))
            .modifier(AdaptiveLiquidGlass(enabled: true, cornerRadius: 11))
    }

    private func systemSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title).font(.system(size: 14, weight: .semibold))
            content()
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(cardFill, in: RoundedRectangle(cornerRadius: 9))
            .modifier(AdaptiveLiquidGlass(enabled: true, cornerRadius: 12))
    }

    private func readStartupItems() -> [StartupItem] {
        let manager = FileManager.default
        let folders = ["/Library/LaunchAgents", "/Library/LaunchDaemons", "\(NSHomeDirectory())/Library/LaunchAgents"]
        var items: [StartupItem] = []
        for folder in folders {
            guard let files = try? manager.contentsOfDirectory(atPath: folder) else { continue }
            for file in files where file.hasSuffix(".plist") {
                let path = URL(fileURLWithPath: folder).appendingPathComponent(file)
                guard let data = try? Data(contentsOf: path),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
                let args = plist["ProgramArguments"] as? [String]
                let program = (plist["Program"] as? String) ?? args?.first ?? "Managed by launchd"
                let name = (plist["Label"] as? String) ?? file.replacingOccurrences(of: ".plist", with: "")
                items.append(StartupItem(name: name, location: path.path, program: program))
            }
        }
        return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func resourceTile(_ item: PerformanceResource) -> some View {
        let selected = resource == item
        return Button { resource = item } label: {
            HStack(spacing: 11) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(item.rawValue, systemImage: item.icon).font(.system(size: 14, weight: .medium)).foregroundStyle(ink)
                    Text(resourceValue(item)).font(.system(size: 11)).foregroundStyle(muted).lineLimit(1)
                    if item == .cpu { Text(String(format: "%.0f%% utilization", monitor.cpuUsage)).font(.system(size: 10)).foregroundStyle(muted) }
                }
                Spacer(minLength: 0)
                MiniChart(samples: samples(item), color: item.color, fixedMaximum: item == .memory ? 100 : nil).frame(width: 72, height: 41)
            }
            .padding(.horizontal, 11).padding(.vertical, 10).frame(maxWidth: .infinity, minHeight: 82)
            .background(selected ? Color.purple.opacity(isDark ? 0.10 : 0.055) : .clear, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(selected ? ink.opacity(0.18) : hairline.opacity(0.55), lineWidth: selected ? 1 : 0.6))
            .contentShape(RoundedRectangle(cornerRadius: 11))
            .modifier(AdaptiveLiquidGlass(enabled: selected, cornerRadius: 11))
        }.buttonStyle(.plain).contentShape(Rectangle())
    }

    @ViewBuilder private var performanceChart: some View {
        let series = samples(resource)
        Chart(series) { sample in
            AreaMark(x: .value("Time", sample.time), y: .value("Usage", sample.value))
                .foregroundStyle(resource.color.opacity(0.25)).interpolationMethod(.linear)
            LineMark(x: .value("Time", sample.time), y: .value("Usage", sample.value))
                .foregroundStyle(resource.color).lineStyle(StrokeStyle(lineWidth: 1.5)).interpolationMethod(.linear)
        }
        .chartYScale(domain: 0...([.cpu, .gpu, .memory].contains(resource) ? 100 : max((series.map(\.value).max() ?? 1) * 1.15, 1)))
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
            AxisValueLabel { if let n = value.as(Double.self) { Text([.network, .disk].contains(resource) ? bitRateLabel(n * 1_000_000) : ([.cpu, .gpu, .energy].contains(resource) ? String(format: "%.0f%%", n) : String(format: "%.0f", n))).font(.system(size: 10)).foregroundStyle(muted) } }
            AxisGridLine().foregroundStyle(hairline)
        } }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 7)) { _ in AxisGridLine().foregroundStyle(hairline) } }
        .background(chartSurface)
        .overlay(Rectangle().stroke(hairline, lineWidth: 1))
    }

    private var cpuStats: some View {
        HStack(alignment: .top, spacing: 50) {
            VStack(alignment: .leading, spacing: 18) {
                stat("Utilization", String(format: "%.0f%%", monitor.cpuUsage), large: true)
                stat("Processes", "\(monitor.processes.count)")
                stat("Threads", "\(monitor.processes.reduce(0) { $0 + $1.threads })")
                stat("Uptime", duration(monitor.uptime), large: true)
            }
            VStack(alignment: .leading, spacing: 12) {
                detail("Base speed", "—")
                detail("CPU cores", "\(monitor.hardware.physicalCores)")
                detail("Logical processors", "\(monitor.hardware.cores)")
                detail("Virtualization", "Available")
                detail("macOS", monitor.hardware.macOS)
                detail("Model", monitor.hardware.model)
            }
        }.padding(.top, 4)
    }

    private var memoryStats: some View {
        HStack(alignment: .top, spacing: 48) {
            stat("In use", "\(bytes(monitor.memoryUsed)) (\(percentUsed))", large: true)
            VStack(alignment: .leading, spacing: 12) {
                detail("Available", bytes(monitor.hardware.memory > monitor.memoryUsed ? monitor.hardware.memory - monitor.memoryUsed : 0))
                detail("Installed", bytes(monitor.hardware.memory))
                detail("Vendor", monitor.hardware.memoryVendor)
                detail("Memory type", monitor.hardware.memoryType)
                detail("Memory pressure", "See Activity Monitor")
            }
        }.padding(.top, 4)
    }

    private var diskStats: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 48) {
                stat("Read", rate(monitor.diskReadRate), large: true)
                stat("Write", rate(monitor.diskWriteRate), large: true)
            }
            detail("Sampling", "System disk activity · 1 second")
            Text("External disks").font(.system(size: 14, weight: .semibold)).padding(.top, 5)
            if monitor.externalVolumes.isEmpty {
                Text("No external or removable volumes are mounted.").font(.system(size: 11)).foregroundStyle(muted)
            } else {
                ForEach(monitor.externalVolumes) { volume in
                    HStack(spacing: 12) {
                        Image(systemName: "externaldrive").foregroundStyle(.blue).frame(width: 25)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(volume.name).font(.system(size: 12, weight: .medium))
                            Text(volume.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(12).background(cardFill, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }.padding(.top, 4)
    }

    private var networkStats: some View {
        HStack(alignment: .top, spacing: 48) {
            stat("Throughput", rate(monitor.networkRate), large: true)
            VStack(alignment: .leading, spacing: 12) { detail("Interface", "Active network interfaces"); detail("Received / sent", "Combined interface counters"); detail("Sampling", "1 second") }
        }.padding(.top, 4)
    }

    private var gpuStats: some View {
        HStack(alignment: .top, spacing: 48) {
            stat("Utilization", monitor.gpuUsage.map { String(format: "%.0f%%", $0) } ?? "Unavailable", large: true)
            VStack(alignment: .leading, spacing: 12) {
                detail("Graphics processor", MTLCreateSystemDefaultDevice()?.name ?? "Not detected")
                detail("GPU cores", monitor.hardware.gpuCores)
                detail("Memory", "Shared system memory")
                detail("Data source", "IORegistry performance counters")
            }
        }.padding(.top, 4)
    }

    private var energyStats: some View {
        HStack(alignment: .top, spacing: 48) {
            stat("Battery", monitor.energyStatus.batteryPercent.map { String(format: "%.0f%%", $0) } ?? "No battery", large: true)
            VStack(alignment: .leading, spacing: 12) {
                detail("Power source", monitor.energyStatus.powerSource)
                detail("Charging", monitor.energyStatus.charging ? "Yes" : "No")
                detail("Battery health", monitor.energyStatus.batteryHealth ?? "Unavailable")
                detail("Battery cycle count", monitor.energyStatus.cycleCount.map(String.init) ?? "Unavailable")
                detail("Charger wattage", monitor.energyStatus.adapterWatts.map { String(format: "%.0f W adapter rating", $0) } ?? "Unavailable")
                detail("Low Power Mode", monitor.energyStatus.lowPowerMode ? "On" : "Off")
            }
        }.padding(.top, 4)
    }

    private var processesPage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("\(filteredProcesses.count) processes")
                    .font(.system(size: 11)).foregroundStyle(muted)
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(muted)
                    TextField("Search by name, PID, or user", text: $query)
                        .textFieldStyle(.plain)
                        .frame(width: 220)
                }
                .font(.system(size: 12))
                .padding(9)
                .background(cardFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Button(role: .destructive) { showTerminateConfirm = true } label: {
                    Label("End task", systemImage: "stop.fill")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .disabled(selectedProcess == nil || selectedProcess?.pid == getpid())
                .help("Select a process, then end it")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            HStack {
                processSortHeader("NAME", column: .name, width: nil, alignment: .leading)
                processSortHeader("PID", column: .pid, width: 70, alignment: .trailing)
                    .help("PID means Process ID. Windows Task Manager uses the same identifier.")
                processSortHeader("USER", column: .user, width: 115, alignment: .trailing)
                processSortHeader("CPU", column: .cpu, width: 75, alignment: .trailing)
                processSortHeader("MEMORY", column: .memory, width: 95, alignment: .trailing)
            }.font(.system(size: 10, weight: .semibold)).foregroundStyle(muted).padding(.horizontal, 18).padding(.vertical, 11)
                .overlay(alignment: .bottom) { Rectangle().fill(hairline).frame(height: 1) }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredProcesses) { process in
                        processRow(process)
                    }
                }
            }
            HStack {
                Text("Select a process to end it")
                    .font(.system(size: 11)).foregroundStyle(muted)
                Spacer()
            }.padding(14).overlay(alignment: .top) { Rectangle().fill(hairline).frame(height: 1) }
        }.background(surface)
    }

    private var filteredProcesses: [ProcessRow] {
        let rows = query.isEmpty ? monitor.processes : monitor.processes.filter { $0.name.localizedCaseInsensitiveContains(query) || String($0.pid).contains(query) || $0.user.localizedCaseInsensitiveContains(query) }
        let sortColumn = processSortColumn
        let ascending = processSortAscending
        return rows.sorted { lhs, rhs in
            func isAscending(_ first: ProcessRow, _ second: ProcessRow) -> Bool {
                switch sortColumn {
                case .name: first.name.localizedCaseInsensitiveCompare(second.name) == .orderedAscending
                case .pid: first.pid < second.pid
                case .user: first.user.localizedCaseInsensitiveCompare(second.user) == .orderedAscending
                case .cpu: first.cpu < second.cpu
                case .memory: first.memory < second.memory
                }
            }
            return ascending ? isAscending(lhs, rhs) : isAscending(rhs, lhs)
        }
    }

    private func processSortHeader(_ title: String, column: ProcessSortColumn, width: CGFloat?, alignment: Alignment) -> some View {
        Button {
            if processSortColumn == column {
                processSortAscending.toggle()
            } else {
                processSortColumn = column
                processSortAscending = column == .name || column == .user
            }
        } label: {
            HStack(spacing: 4) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(title)
                if processSortColumn == column {
                    Image(systemName: processSortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .frame(width: width, alignment: alignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sort by \(title.lowercased())")
    }

    private func processRow(_ process: ProcessRow) -> some View {
        Button { selectedProcess = process } label: {
            HStack {
                Text(process.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text("\(process.pid)").frame(width: 70, alignment: .trailing)
                if page == .processes {
                    Text(process.user).lineLimit(1).frame(width: 115, alignment: .trailing)
                }
                Text(String(format: "%.1f%%", process.cpu)).frame(width: 75, alignment: .trailing)
                Text(bytes(process.memory)).frame(width: 95, alignment: .trailing)
            }.font(.system(size: 12)).foregroundStyle(ink).padding(.horizontal, page == .processes ? 18 : 11).padding(.vertical, 8)
                .background(selectedProcess?.pid == process.pid ? Color.blue.opacity(0.1) : .clear)
                .contentShape(Rectangle())
                .modifier(AdaptiveLiquidGlass(enabled: selectedProcess?.pid == process.pid, cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                selectedProcess = process
                showTerminateConfirm = true
            } label: { Label("End task", systemImage: "stop.fill") }
            .disabled(process.pid == getpid())
        }
    }
    private func samples(_ item: PerformanceResource) -> [Sample] {
        switch item {
        case .cpu: monitor.cpuHistory
        case .memory: monitor.memoryHistory
        case .disk: monitor.diskHistory
        case .network: monitor.networkHistory
        case .gpu: monitor.gpuHistory
        case .energy: monitor.batteryHistory
        }
    }
    private func resourceValue(_ item: PerformanceResource) -> String {
        switch item {
        case .cpu: String(format: "%.1f%%", monitor.cpuUsage)
        case .memory: "\(bytes(monitor.memoryUsed)) / \(bytes(monitor.hardware.memory))"
        case .disk: "R \(rate(monitor.diskReadRate)) · W \(rate(monitor.diskWriteRate))"
        case .network: rate(monitor.networkRate)
        case .gpu: monitor.gpuUsage.map { String(format: "%.1f%%", $0) } ?? "Unavailable"
        case .energy: monitor.energyStatus.batteryPercent.map { String(format: "%.0f%% battery", $0) } ?? monitor.energyStatus.powerSource
        }
    }
    private var percentUsed: String { String(format: "%.1f%%", Double(monitor.memoryUsed) / max(Double(monitor.hardware.memory), 1) * 100) }
    private func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory) }
    private func rate(_ value: Double) -> String {
        bitRateLabel(value * 8)
    }
    private func bitRateLabel(_ bitsPerSecond: Double) -> String {
        if bitsPerSecond >= 1_000_000_000 { return String(format: "%.2f Gbps", bitsPerSecond / 1_000_000_000) }
        if bitsPerSecond >= 1_000_000 { return String(format: "%.1f Mbps", bitsPerSecond / 1_000_000) }
        if bitsPerSecond >= 1_000 { return String(format: "%.1f Kbps", bitsPerSecond / 1_000) }
        return String(format: "%.0f bps", bitsPerSecond)
    }
    private func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds), days = total / 86_400, hours = (total % 86_400) / 3_600, minutes = (total % 3_600) / 60
        return days > 0 ? "\(days)d \(hours)h \(minutes)m" : "\(hours)h \(minutes)m"
    }
    private func stat(_ title: String, _ value: String, large: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(muted)
            Text(value).font(.system(size: large ? 21 : 16, weight: .regular, design: .rounded)).foregroundStyle(ink)
        }
    }
    private func detail(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(title).font(.system(size: 12)).foregroundStyle(muted).frame(width: 150, alignment: .leading)
            Text(value).font(.system(size: 12)).foregroundStyle(ink)
        }
    }
}

private enum ProcessSortColumn {
    case name, pid, user, cpu, memory
}

private struct AdaptiveLiquidGlass: ViewModifier {
    let enabled: Bool
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                content
            }
        } else {
            content
        }
    }
}

struct MiniChart: View {
    let samples: [Sample]
    let color: Color
    var fixedMaximum: Double? = nil
    var body: some View {
        Chart(samples) { sample in
            AreaMark(x: .value("Time", sample.time), y: .value("Usage", sample.value))
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.3), color.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.catmullRom)
            LineMark(x: .value("Time", sample.time), y: .value("Usage", sample.value))
                .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .interpolationMethod(.catmullRom)
        }
        .chartXAxis(.hidden).chartYAxis(.hidden)
        .chartYScale(domain: 0...(fixedMaximum ?? max(samples.map(\.value).max() ?? 1, 1)))
    }
}
