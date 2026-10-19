import SwiftUI
import WidgetKit
import IOKit
import Darwin

private struct MetricsEntry: TimelineEntry {
    let date: Date
    let cpu: Double?
    let gpu: Double?
    let memory: Double?
    let temperature: Double?
    let power: Double?
    let memoryText: String
}

private struct MetricsProvider: TimelineProvider {
    func placeholder(in context: Context) -> MetricsEntry {
        MetricsEntry(date: .now, cpu: 18, gpu: 12, memory: 64, temperature: 43, power: 10.4, memoryText: "10.2 / 16 GB")
    }

    func getSnapshot(in context: Context, completion: @escaping (MetricsEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : readEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MetricsEntry>) -> Void) {
        let entry = readEntry()
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60))))
    }

    private func readEntry() -> MetricsEntry {
        let memory = MetricsReader.memoryUsage()
        return MetricsEntry(
            date: .now,
            cpu: MetricsReader.cpuUsage(),
            gpu: MetricsReader.gpuUsage(),
            memory: memory.percent,
            temperature: MetricsReader.temperature(),
            power: MetricsReader.power(),
            memoryText: memory.detail
        )
    }
}

private struct MetricsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MetricsEntry

    var body: some View {
        Group {
            if family == .systemLarge {
                VStack(spacing: 14) {
                    HStack(spacing: 10) {
                        ForEach(0..<3, id: \.self) { metric(at: $0) }
                    }
                    HStack(spacing: 10) {
                        ForEach(3..<5, id: \.self) { metric(at: $0) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            } else {
                HStack(spacing: 5) {
                    ForEach(0..<5, id: \.self) { metric(at: $0) }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [
                    Color(red: 0.13, green: 0.19, blue: 0.20),
                    Color(red: 0.06, green: 0.10, blue: 0.12)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.25), lineWidth: 0.8)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func metric(at index: Int) -> some View {
        switch index {
        case 0:
            gauge("CPU", entry.cpu, suffix: "%", symbol: "cpu", color: .cyan, scale: 100)
        case 1:
            gauge("GPU", entry.gpu, suffix: "%", symbol: "display", color: .orange, scale: 100)
        case 2:
            gauge("Memory", entry.memory, suffix: "%", symbol: "memorychip", color: .purple, scale: 100, detail: entry.memoryText)
        case 3:
            gauge("Temperature", entry.temperature, suffix: "°", symbol: "thermometer.medium", color: .orange, scale: 100)
        case 4:
            gauge("Power", entry.power, suffix: " W", symbol: "bolt.fill", color: .yellow, scale: 40)
        default:
            EmptyView()
        }
    }

    private func gauge(_ title: String, _ value: Double?, suffix: String, symbol: String, color: Color, scale: Double, detail: String? = nil) -> some View {
        let diameter: CGFloat = family == .systemLarge ? 76 : 54
        let lineWidth: CGFloat = family == .systemLarge ? 6 : 5
        return VStack(spacing: family == .systemLarge ? 8 : 5) {
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: min(max((value ?? 0) / scale, 0), 1))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: symbol)
                    .font(.system(size: family == .systemLarge ? 22 : 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(width: diameter, height: diameter)
            .accessibilityHidden(true)

            Text(value.map { String(format: "%.0f%@", $0, suffix) } ?? "—")
                .font(.system(size: family == .systemLarge ? 16 : 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            VStack(spacing: 1) {
                Text(title).font(.system(size: family == .systemLarge ? 10 : 9, weight: .medium))
                if family == .systemLarge, let detail {
                    Text(detail).font(.system(size: 8)).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(.white.opacity(0.9))
        .accessibilityElement(children: .combine)
    }
}

@main
struct MacTaskManagerWidgetBundle: WidgetBundle {
    var body: some Widget {
        MacTaskManagerMetricsWidget()
    }
}

private struct MacTaskManagerMetricsWidget: Widget {
    let kind = "MacTaskManagerMetricsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MetricsProvider()) { entry in
            MetricsWidgetView(entry: entry)
        }
        .configurationDisplayName("Mac Task Manager")
        .description("CPU, GPU, memory, temperature, and power at a glance.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

private enum MetricsReader {
    private static let thermalReader = WidgetThermalReader()

    static func cpuUsage() -> Double? {
        guard let first = cpuTicks() else { return nil }
        Thread.sleep(forTimeInterval: 0.18)
        guard let second = cpuTicks() else { return nil }
        let user = second.user &- first.user
        let system = second.system &- first.system
        let idle = second.idle &- first.idle
        let nice = second.nice &- first.nice
        let total = user &+ system &+ idle &+ nice
        guard total > 0 else { return nil }
        return min(100, Double(user &+ system &+ nice) / Double(total) * 100)
    }

    private struct CPUTicks {
        let user: UInt64
        let system: UInt64
        let idle: UInt64
        let nice: UInt64
    }

    private static func cpuTicks() -> CPUTicks? {
        var load = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUTicks(user: UInt64(load.cpu_ticks.0), system: UInt64(load.cpu_ticks.1), idle: UInt64(load.cpu_ticks.2), nice: UInt64(load.cpu_ticks.3))
    }

    static func memoryUsage() -> (percent: Double?, detail: String) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let total = ProcessInfo.processInfo.physicalMemory
        guard result == KERN_SUCCESS, total > 0 else { return (nil, "") }
        let used = UInt64(stats.active_count + stats.wire_count + stats.compressor_page_count) * UInt64(getpagesize())
        let percent = min(100, Double(used) / Double(total) * 100)
        return (percent, "\(bytes(used)) / \(bytes(total))")
    }

    static func gpuUsage() -> Double? {
        guard let matching = IOServiceMatching("IOAccelerator") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var readings: [Double] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
                  let value = (stats["Device Utilization %"] ?? stats["GPU Activity(%)"]) as? NSNumber else { continue }
            readings.append(value.doubleValue)
        }
        return readings.max().map { min(max($0, 0), 100) }
    }

    static func temperature() -> Double? { thermalReader.averageTemperature() }

    static func power() -> Double? {
        guard let matching = IOServiceMatching("AppleSmartBattery") else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let telemetry = IORegistryEntryCreateCFProperty(service, "PowerTelemetryData" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
              let milliwatts = (telemetry["SystemPowerIn"] as? NSNumber)?.doubleValue,
              milliwatts > 0, milliwatts < 500_000 else { return nil }
        return milliwatts / 1_000
    }

    private static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .memory)
    }
}

private final class WidgetThermalReader: @unchecked Sendable {
    private typealias CreateClient = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    private typealias SetMatching = @convention(c) (UnsafeRawPointer, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (UnsafeRawPointer) -> UnsafeMutableRawPointer?
    private typealias CopyEvent = @convention(c) (UnsafeRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias GetFloatValue = @convention(c) (UnsafeRawPointer, Int32) -> Double

    private let library: UnsafeMutableRawPointer?
    private let client: UnsafeMutableRawPointer?
    private let services: UnsafeMutableRawPointer?
    private let copyEvent: CopyEvent?
    private let getFloatValue: GetFloatValue?

    init() {
        library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        guard let library,
              let createSymbol = dlsym(library, "IOHIDEventSystemClientCreate"),
              let matchSymbol = dlsym(library, "IOHIDEventSystemClientSetMatching"),
              let servicesSymbol = dlsym(library, "IOHIDEventSystemClientCopyServices") else {
            client = nil; services = nil; copyEvent = nil; getFloatValue = nil
            return
        }
        let createClient = unsafeBitCast(createSymbol, to: CreateClient.self)
        let setMatching = unsafeBitCast(matchSymbol, to: SetMatching.self)
        let copyServices = unsafeBitCast(servicesSymbol, to: CopyServices.self)
        copyEvent = dlsym(library, "IOHIDServiceClientCopyEvent").map { unsafeBitCast($0, to: CopyEvent.self) }
        getFloatValue = dlsym(library, "IOHIDEventGetFloatValue").map { unsafeBitCast($0, to: GetFloatValue.self) }
        client = createClient(kCFAllocatorDefault)
        if let client {
            _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 0x0005] as CFDictionary)
            services = copyServices(client)
        } else {
            services = nil
        }
    }

    deinit {
        if let services { Unmanaged<CFTypeRef>.fromOpaque(services).release() }
        if let client { Unmanaged<CFTypeRef>.fromOpaque(client).release() }
        if let library { dlclose(library) }
    }

    func averageTemperature() -> Double? {
        guard let services, let copyEvent, let getFloatValue else { return nil }
        let array = unsafeBitCast(services, to: CFArray.self)
        var values: [Double] = []
        for index in 0..<CFArrayGetCount(array) {
            guard let service = CFArrayGetValueAtIndex(array, index),
                  let event = copyEvent(service, 15, 0, 0) else { continue }
            let value = getFloatValue(event, Int32(15 << 16))
            Unmanaged<CFTypeRef>.fromOpaque(event).release()
            if value.isFinite, (10...110).contains(value) { values.append(value) }
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
