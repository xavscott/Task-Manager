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
import WidgetKit
import ServiceManagement

@main
struct MacTaskManagerApp: App {
    static let isAccessoryMonitorMode = CommandLine.arguments.contains("--accessory-monitor")

    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appLifecycleDelegate
    @StateObject private var monitor = SystemMonitor()
    @StateObject private var displayTheme = DisplayThemeStore()

    var body: some Scene {
        WindowGroup {
            if Self.isAccessoryMonitorMode {
                AccessoryMonitorLaunchView()
            } else {
                ContentView()
                    .environmentObject(monitor)
                    .environmentObject(displayTheme)
                    .preferredColorScheme(displayTheme.preferredColorScheme)
                    .frame(width: 1080, height: 768)
                    .background(FixedSizeWindowConfigurator())
            }
        }
        .defaultSize(width: 1080, height: 768)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("View") {
                Button("Refresh Now") { monitor.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }

        Settings {
            if Self.isAccessoryMonitorMode {
                EmptyView()
            } else {
                DisplaySettingsView()
                    .environmentObject(displayTheme)
                    .preferredColorScheme(displayTheme.preferredColorScheme)
                    .frame(width: 660, height: 520)
            }
        }
        .windowResizability(.contentSize)
    }
}

private struct AccessoryMonitorLaunchView: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                DispatchQueue.main.async {
                    NSApp.windows.filter { !($0 is NSPanel) }.forEach { $0.close() }
                }
            }
    }
}

private enum DisplayAppearance: String, CaseIterable, Identifiable {
    case system = "Auto"
    case light = "Light"
    case dark = "Dark"
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

private enum AccentChoice: String, CaseIterable, Identifiable {
    case multicolor, blue, purple, pink, red, orange, yellow, green, gray
    var id: String { rawValue }
    var title: String { self == .multicolor ? "Multicolor" : rawValue.capitalized }
    var darkColor: Color {
        switch self {
        case .multicolor, .blue: Color(red: 0.38, green: 0.65, blue: 0.96)
        case .purple: Color(red: 0.69, green: 0.53, blue: 0.91)
        case .pink: Color(red: 0.91, green: 0.48, blue: 0.68)
        case .red: Color(red: 0.96, green: 0.34, blue: 0.37)
        case .orange: Color(red: 0.94, green: 0.59, blue: 0.31)
        case .yellow: Color(red: 0.94, green: 0.75, blue: 0.18)
        case .green: Color(red: 0.34, green: 0.70, blue: 0.43)
        case .gray: Color(red: 0.62, green: 0.64, blue: 0.67)
        }
    }
    var lightColor: Color {
        switch self {
        case .multicolor, .blue: Color(red: 0.12, green: 0.39, blue: 0.78)
        case .purple: Color(red: 0.43, green: 0.27, blue: 0.68)
        case .pink: Color(red: 0.72, green: 0.24, blue: 0.45)
        case .red: Color(red: 0.78, green: 0.12, blue: 0.16)
        case .orange: Color(red: 0.73, green: 0.34, blue: 0.08)
        case .yellow: Color(red: 0.58, green: 0.43, blue: 0.02)
        case .green: Color(red: 0.18, green: 0.49, blue: 0.27)
        case .gray: Color(red: 0.38, green: 0.40, blue: 0.43)
        }
    }
}

@MainActor
private final class DisplayThemeStore: ObservableObject {
    private static let sharedDefaults = UserDefaults(suiteName: "com.codex.mactaskmanager.preferences")!

    @Published var appearance: DisplayAppearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "displayAppearance")
            Self.sharedDefaults.set(appearance.rawValue, forKey: "displayAppearance")
        }
    }
    @Published var accentChoice: AccentChoice {
        didSet {
            UserDefaults.standard.set(accentChoice.rawValue, forKey: "displayAccentV2")
            Self.sharedDefaults.set(accentChoice.rawValue, forKey: "displayAccentV2")
        }
    }
    private let originalIcon: NSImage
    var iconImage: NSImage { originalIcon }

    var preferredColorScheme: ColorScheme? { appearance.colorScheme }
    func accent(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? accentChoice.darkColor : accentChoice.lightColor
    }

    init() {
        let defaults = UserDefaults.standard
        let configuredAppearance = DisplayAppearance(rawValue: defaults.string(forKey: "displayAppearance") ?? "System") ?? .system
        // Start this display-theme revision with the brand green instead of carrying forward
        // the earlier purple selection; future changes persist under the new preference key.
        let configuredAccent = AccentChoice(rawValue: defaults.string(forKey: "displayAccentV2") ?? "green") ?? .green
        appearance = configuredAppearance
        accentChoice = configuredAccent
        Self.sharedDefaults.set(configuredAppearance.rawValue, forKey: "displayAppearance")
        Self.sharedDefaults.set(configuredAccent.rawValue, forKey: "displayAccentV2")
        originalIcon = NSApp.applicationIconImage.copy() as? NSImage ?? NSImage(size: NSSize(width: 128, height: 128))
    }
}

@MainActor
private final class FloatingPerformanceOverlayController: ObservableObject {
    private var panel: NSPanel?

    func show(monitor: SystemMonitor) {
        if let panel {
            panel.orderFrontRegardless()
            return
        }

        let size = NSSize(width: 310, height: 230)
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: visibleFrame.maxX - size.width - 24, y: visibleFrame.maxY - size.height - 28)
        let overlay = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        overlay.isFloatingPanel = true
        overlay.level = .statusBar
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        overlay.backgroundColor = .clear
        overlay.isOpaque = false
        overlay.hasShadow = true
        overlay.isMovableByWindowBackground = true
        overlay.hidesOnDeactivate = false
        overlay.contentView = NSHostingView(rootView: FloatingPerformanceOverlayView(monitor: monitor))
        overlay.orderFrontRegardless()
        panel = overlay
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct FixedSizeWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = FixedSizeWindowView()
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        lockWindow(nsView.window)
    }

    private func lockWindow(_ window: NSWindow?) {
        guard let window else { return }
        window.styleMask.remove(.resizable)
        window.standardWindowButton(.zoomButton)?.isEnabled = false
    }
}

private final class FixedSizeWindowView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.styleMask.remove(.resizable)
        window.standardWindowButton(.zoomButton)?.isEnabled = false
    }
}

private final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    private var accessoryMonitorProcess: Process?
    private var accessoryMonitorActivity: NSObjectProtocol?
    private let accessoryMonitorBundleIdentifier = "com.codex.mactaskmanager.accessory-monitor"

    func applicationDidFinishLaunching(_ notification: Notification) {
        if MacTaskManagerApp.isAccessoryMonitorMode {
            NSApp.setActivationPolicy(.accessory)
            // A UIElement can otherwise be App Nap'ed when no window is visible.
            // The helper is deliberately long-lived: it must notice accessories
            // while the main Task Manager window is closed or in the background.
            accessoryMonitorActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .automaticTerminationDisabled, .suddenTerminationDisabled],
                reason: "Monitor Apple accessory connections"
            )
            AccessoryConnectionPopupController.shared.startMonitoring()
            return
        }

        WidgetCenter.shared.reloadAllTimelines()
        registerAccessoryMonitorLoginItem()
        startAccessoryMonitorProcess()
    }

    private func registerAccessoryMonitorLoginItem() {
        // The installer owns startup registration through the user's LaunchAgent.
        // Do not register a second SMAppService item for package installs; two
        // startup mechanisms can launch duplicate hidden monitor processes.
        let installedAgentURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.codex.mactaskmanager.accessory-monitor.plist")
        if FileManager.default.fileExists(atPath: installedAgentURL.path) {
            return
        }

        // Older builds registered this helper as an embedded launch agent. Remove
        // that registration when upgrading so launchd cannot start two helpers.
        let legacyAgent = SMAppService.agent(plistName: "com.codex.mactaskmanager.accessory-monitor.plist")
        if legacyAgent.status == .enabled {
            try? legacyAgent.unregister()
        }

        let loginItem = SMAppService.loginItem(identifier: accessoryMonitorBundleIdentifier)
        guard loginItem.status != .enabled else { return }

        do {
            try loginItem.register()
            // Registration can complete without becoming enabled when macOS
            // requires approval. Keep the launch-agent fallback active in that
            // case so the monitor still survives the next login.
            if loginItem.status != .enabled {
                registerEmbeddedAccessoryMonitorAgent()
            }
        } catch {
            NSLog("Could not register the accessory monitor login item: %@", error.localizedDescription)
            registerEmbeddedAccessoryMonitorAgent()
        }
    }

    private func registerEmbeddedAccessoryMonitorAgent() {
        // The embedded launch agent is a supported fallback for systems that
        // reject SMAppService.loginItem (for example, an ad-hoc signed build).
        // The plist is packaged in Contents/Library/LaunchAgents by the build
        // script, so launchd resolves BundleProgram relative to this app.
        let agent = SMAppService.agent(plistName: "com.codex.mactaskmanager.accessory-monitor.plist")
        guard agent.status != .enabled else { return }

        do {
            try agent.register()
        } catch {
            NSLog("Could not register the accessory monitor launch agent: %@", error.localizedDescription)
        }
    }

    @MainActor
    private func startAccessoryMonitorProcess() {
        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LoginItems/MacTaskManagerAccessory.app/Contents/MacOS/MacTaskManager")
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            // Keep popups working in development builds that do not include the
            // packaged helper app.
            AccessoryConnectionPopupController.shared.startMonitoring()
            return
        }

        // The LoginItems helper is normally already running after login. Only
        // launch it here when the user opens the app during the current session.
        if !NSRunningApplication.runningApplications(withBundleIdentifier: accessoryMonitorBundleIdentifier).isEmpty {
            return
        }

        let process = Process()
        process.executableURL = helperURL
        process.arguments = ["--accessory-monitor"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            accessoryMonitorProcess = process
        } catch {
            NSLog("Could not start the accessory monitor: %@", error.localizedDescription)
            AccessoryConnectionPopupController.shared.startMonitoring()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !MacTaskManagerApp.isAccessoryMonitorMode
    }
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
    let chargingStates: [String: Bool]
    var id: String { name.lowercased() }
}

private struct BluetoothAccessoryCandidate {
    let device: IOBluetoothDevice
    let name: String
    let model: String
    let aliases: [String]
}

private enum AccessoryPopupKind {
    case airPods, mouse, keyboard, trackpad, generic

    var symbol: String {
        switch self {
        case .airPods: "airpodspro"
        case .mouse: "computermouse"
        case .keyboard: "keyboard"
        case .trackpad: "rectangle.and.hand.point.up.left"
        case .generic: "wave.3.right"
        }
    }

    static func forName(_ name: String) -> Self? {
        let name = name.lowercased()
        if name.contains("airpods") { return .airPods }
        if name.contains("magic mouse") || name.contains("apple wireless mouse") { return .mouse }
        if name.contains("magic keyboard") || name.contains("apple wireless keyboard") { return .keyboard }
        if name.contains("magic trackpad") { return .trackpad }
        if name.contains("beats") { return .generic }
        return nil
    }
}

@MainActor
private final class AccessoryConnectionPopupController: ObservableObject {
    static let shared = AccessoryConnectionPopupController()

    @Published var accentColor: Color = .blue
    @Published var displayedDevice: AppleDevice?
    @Published var connectedDevices: [AppleDevice] = []
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private var monitoringTask: Task<Void, Never>?
    private var pendingDevices: [AppleDevice] = []
    private var queuedIDs = Set<String>()
    private var connectedIDs = Set<String>()
    private var displayedDeviceID: String?

    func startMonitoring() {
        guard monitoringTask == nil else { return }
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let devices = SystemMonitor.readAppleDevices()
                connectedDevices = devices
                observe(devices: devices, accentColor: configuredAccentColor)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var configuredAccentColor: Color {
        let defaults = UserDefaults(suiteName: "com.codex.mactaskmanager.preferences") ?? .standard
        let choice = AccentChoice(rawValue: defaults.string(forKey: "displayAccentV2") ?? "green") ?? .green
        let appearance = DisplayAppearance(rawValue: defaults.string(forKey: "displayAppearance") ?? "Auto") ?? .system
        let isDark: Bool
        switch appearance {
        case .dark: isDark = true
        case .light: isDark = false
        case .system:
            isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        return isDark ? choice.darkColor : choice.lightColor
    }

    func observe(devices: [AppleDevice], accentColor: Color) {
        self.accentColor = accentColor
        let supported = devices.filter { AccessoryPopupKind.forName("\($0.name) \($0.model)") != nil }
        let currentIDs = Set(supported.map(\.id))
        let newlyConnected = supported.filter { !connectedIDs.contains($0.id) }
        connectedIDs = currentIDs
        if let displayedDeviceID, let updatedDevice = supported.first(where: { $0.id == displayedDeviceID }) {
            displayedDevice = updatedDevice
        }

        for device in newlyConnected where queuedIDs.insert(device.id).inserted {
            pendingDevices.append(device)
        }
        pendingDevices.removeAll { !currentIDs.contains($0.id) }
        queuedIDs.formIntersection(currentIDs)
        presentNextIfNeeded()
    }

    private func presentNextIfNeeded() {
        guard panel == nil, !pendingDevices.isEmpty else { return }
        let device = pendingDevices.removeFirst()
        queuedIDs.remove(device.id)
        show(device)
    }

    private func show(_ device: AppleDevice) {
        let size = NSSize(width: 430, height: 112)
        let screen = NSApp.mainWindow?.screen ?? NSScreen.main
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Anchor to the physical top-center of the display (the notch area), not the
        // visible frame, which begins below the menu bar and makes the pill float lower.
        let origin = NSPoint(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height)
        displayedDevice = device
        displayedDeviceID = device.id
        let overlay = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        overlay.isFloatingPanel = true
        overlay.level = .statusBar
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        overlay.backgroundColor = .clear
        overlay.isOpaque = false
        overlay.hasShadow = false
        overlay.hidesOnDeactivate = false
        overlay.becomesKeyOnlyIfNeeded = true
        let hostingView = NSHostingView(rootView: AccessoryConnectionPopupView(initialDevice: device, popup: self))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false
        overlay.contentView = hostingView
        panel = overlay
        overlay.orderFrontRegardless()

        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.dismissCurrent()
        }
    }

    private func dismissCurrent() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        panel = nil
        displayedDevice = nil
        displayedDeviceID = nil

        if !pendingDevices.isEmpty {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                self?.presentNextIfNeeded()
            }
        }
    }
}

private struct AccessoryBatteryComponent: Identifiable {
    let name: String
    let title: String
    let percent: Int?
    let isCharging: Bool?

    var id: String { name }
}

private struct AccessoryBatteryIndicators: View {
    let device: AppleDevice
    let accentColor: Color
    let compact: Bool
    var alignRight = false

    private var components: [AccessoryBatteryComponent] {
        if "\(device.name) \(device.model)".localizedCaseInsensitiveContains("AirPods") {
            return ["Left", "Right", "Case"].map { component in
                let title = component == "Left" ? "L" : component == "Right" ? "R" : "Case"
                return AccessoryBatteryComponent(name: component, title: title,
                    percent: device.batteryLevels[component], isCharging: device.chargingStates[component])
            }
        }
        let percent = device.batteryPercent ?? device.batteryLevels["Battery"]
        return [AccessoryBatteryComponent(name: "Battery", title: "Battery", percent: percent,
            isCharging: device.chargingStates["Battery"])]
    }

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 4 : 8) {
            ForEach(components) { component in
                BatteryIndicator(component: component, accentColor: accentColor, compact: compact)
            }
        }
        .frame(maxWidth: compact && !alignRight ? .infinity : nil, alignment: alignRight ? .trailing : .leading)
    }
}

private struct BatteryIndicator: View {
    let component: AccessoryBatteryComponent
    let accentColor: Color
    let compact: Bool

    private var diameter: CGFloat { compact ? 24 : 34 }
    private var batteryColor: Color {
        (component.percent ?? 100) <= 20 ? .orange : accentColor
    }
    private var chargingLabel: String? {
        switch component.isCharging {
        case true: "Charging"
        case false: "Not charging"
        case nil: nil
        }
    }

    private var batterySymbol: String {
        guard let percent = component.percent else { return "battery.0" }
        switch percent {
        case 0...20: return "battery.0"
        case 21...45: return "battery.25"
        case 46...70: return "battery.50"
        case 71...90: return "battery.75"
        default: return "battery.100"
        }
    }

    private var accessibilityDescription: String {
        [component.title, component.percent.map { "\($0) percent" }, chargingLabel]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    var body: some View {
        VStack(spacing: compact ? 1 : 2) {
            Image(systemName: batterySymbol)
                .font(.system(size: compact ? 18 : 25, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(batteryColor)
                .frame(width: diameter, height: diameter)

            Text(component.percent.map { "\($0)%" } ?? "—")
                .font(.system(size: compact ? 8 : 10, weight: .semibold, design: .rounded))
                .foregroundStyle((component.percent ?? 100) <= 20 ? Color.orange : Color.primary)
            Text(component.title)
                .font(.system(size: compact ? 7 : 8, weight: .medium))
                .foregroundStyle(.secondary)
            if !compact, let chargingLabel {
                Text(chargingLabel)
                    .font(.system(size: 7, weight: component.isCharging == true ? .semibold : .regular))
                    .foregroundStyle(component.isCharging == true ? accentColor : Color.primary.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(minWidth: compact ? 30 : 50)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }
}

private struct AccessoryConnectionPopupView: View {
    let initialDevice: AppleDevice
    @ObservedObject var popup: AccessoryConnectionPopupController

    @State private var isVisible = false

    private var device: AppleDevice { popup.displayedDevice ?? initialDevice }
    private var kind: AccessoryPopupKind { AccessoryPopupKind.forName("\(device.name) \(device.model)") ?? .generic }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind.symbol)
                .font(.system(size: 22, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(popup.accentColor)
                .frame(width: 42, height: 42)
                .background(popup.accentColor.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("Connected")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(device.name)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text("Ready to use with your Mac")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            AccessoryBatteryIndicators(device: device, accentColor: popup.accentColor, compact: true, alignRight: true)
        }
        .padding(.horizontal, 16)
        .frame(width: 430, height: 112)
        .tint(popup.accentColor)
        .background(
            Color.black,
            in: UnevenRoundedRectangle(
                cornerRadii: RectangleCornerRadii(
                    topLeading: 0,
                    bottomLeading: 24,
                    bottomTrailing: 24,
                    topTrailing: 0
                ),
                style: .continuous
            )
        )
        .scaleEffect(isVisible ? 1 : 0.94)
        .opacity(isVisible ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) { isVisible = true }
        }
    }
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

private struct CPUTickTotals {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64
}

private final class ThermalSensorReader {
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
            let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 0x0005] as CFDictionary
            _ = setMatching(client, matching)
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

    func averageTemperature() -> (name: String, value: Double)? {
        guard let services, let copyEvent, let getFloatValue else { return nil }
        let serviceArray = unsafeBitCast(services, to: CFArray.self)
        var readings: [Double] = []
        for index in 0..<CFArrayGetCount(serviceArray) {
            guard let service = CFArrayGetValueAtIndex(serviceArray, index),
                  let event = copyEvent(service, 15, 0, 0) else { continue }
            let value = getFloatValue(event, Int32(15 << 16))
            Unmanaged<CFTypeRef>.fromOpaque(event).release()
            guard value.isFinite, (10...110).contains(value) else { continue }
            readings.append(value)
        }
        guard !readings.isEmpty else { return nil }
        return ("Sensor average", readings.reduce(0, +) / Double(readings.count))
    }
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
    @Published var systemPowerWatts: Double?
    @Published var powerHistory: [Sample] = []
    @Published var thermalTemperature: Double?
    @Published var thermalSensorLabel = "Sensor average"
    @Published var thermalPressure = "Unknown"
    @Published var thermalHistory: [Sample] = []
    @Published var cpuUsage = 0.0
    @Published var memoryUsed: UInt64 = 0
    @Published var networkRate = 0.0
    @Published var uptime: TimeInterval = 0
    @Published var lastUpdated = Date()
    let hardware = HardwareInfo.read()
    private var timer: Timer?
    private var previousCPU: [Int32: UInt64] = [:]
    private var previousSystemCPUTicks: CPUTickTotals?
    private let thermalSensorReader = ThermalSensorReader()
    private var previousNetwork: UInt64 = 0
    private var previousDisk: DiskCounters?
    private var previousDate = Date()

    init() {
        refresh()
        // Common modes keep the monitor ticking while menus, sheets, or other
        // run-loop modes are active instead of making updates appear foreground-only.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        let now = Date()
        let interval = max(now.timeIntervalSince(previousDate), 0.1)
        let (rows, totals) = Self.readProcesses(previous: previousCPU, interval: interval)
        previousCPU = totals
        processes = rows.sorted { $0.cpu > $1.cpu }
        cpuUsage = readSystemCPUUsage()
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
        systemPowerWatts = Self.readSystemPowerWatts()
        if let systemPowerWatts { append(systemPowerWatts, to: &powerHistory, at: now) }
        if let thermalReading = thermalSensorReader.averageTemperature() {
            thermalSensorLabel = thermalReading.name
            thermalTemperature = thermalReading.value
        } else {
            thermalTemperature = nil
        }
        if let thermalTemperature { append(thermalTemperature, to: &thermalHistory, at: now) }
        thermalPressure = Self.thermalPressureLabel(ProcessInfo.processInfo.thermalState)
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

    private func readSystemCPUUsage() -> Double {
        var load = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return cpuUsage }
        let current = CPUTickTotals(
            user: UInt64(load.cpu_ticks.0),
            system: UInt64(load.cpu_ticks.1),
            idle: UInt64(load.cpu_ticks.2),
            nice: UInt64(load.cpu_ticks.3)
        )
        defer { previousSystemCPUTicks = current }
        guard let previous = previousSystemCPUTicks else { return 0 }
        let user = current.user &- previous.user
        let system = current.system &- previous.system
        let idle = current.idle &- previous.idle
        let nice = current.nice &- previous.nice
        let total = user &+ system &+ idle &+ nice
        guard total > 0 else { return 0 }
        return min(100, Double(user &+ system &+ nice) / Double(total) * 100)
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
            let cpu = Double(delta) / 1_000_000_000 / interval * 100 / Double(max(ProcessInfo.processInfo.processorCount, 1))
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

    fileprivate static func readAppleDevices() -> [AppleDevice] {
        var devices: [String: AppleDevice] = [:]
        let registryBatteries = readAppleAccessoryBatteries()
        let bluetoothBatteryCache = readBluetoothBatteryCache()
        let bluetoothDevices = connectedBluetoothDevices(batteryCache: bluetoothBatteryCache)
        for candidate in bluetoothDevices {
            guard let model = appleAccessoryModel(from: candidate.aliases) else { continue }
            let device = candidate.device
            let name = candidate.name
            let key = name.lowercased()
            let address = normalizeBluetoothAddress(device.addressString)
            // Control Center can keep the last case level in Bluetooth's DeviceCache
            // under the accessory's user-assigned name, even when the live case getter
            // reports 0 (the case is asleep). Resolve by address first, then cache aliases.
            var levels = bluetoothBatteryCache.levels(forAddress: address, names: candidate.aliases)
            let registryBattery = registryBatteries[address]
            if levels["Battery"] == nil, let percent = registryBattery?.percent {
                levels["Battery"] = percent
            }
            var chargingStates = bluetoothBatteryCache.chargingStates(forAddress: address, names: candidate.aliases)
            for (label, property) in [("Left", "batteryPercentLeft"), ("Right", "batteryPercentRight"), ("Case", "batteryPercentCase"), ("Battery", "batteryPercentSingle")] {
                if let liveLevel = privateBluetoothBatteryLevel(device, property: property) {
                    levels[label] = liveLevel
                }
                if let isCharging = privateBluetoothChargingStatus(device, component: label) {
                    chargingStates[label] = isCharging
                }
            }
            if let isCharging = registryBattery?.isCharging { chargingStates["Battery"] = isCharging }
            let aggregate = levels["Battery"] ?? levels["Left"].flatMap { left in levels["Right"].map { (left + $0) / 2 } }
            devices[key] = AppleDevice(name: name, model: model, connection: "Bluetooth",
                                       batteryPercent: aggregate ?? registryBattery?.percent,
                                       batteryLevels: levels, chargingStates: chargingStates)
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

    private static func privateBluetoothChargingStatus(_ device: IOBluetoothDevice, component: String) -> Bool? {
        let properties = [
            "batteryIsCharging\(component)", "isBatteryCharging\(component)",
            "batteryCharging\(component)", "isCharging\(component)"
        ]
        for property in properties {
            let selector = NSSelectorFromString(property)
            guard device.responds(to: selector),
                  let value = device.value(forKey: property) as? NSNumber else { continue }
            return value.boolValue
        }
        return nil
    }

    private static func connectedBluetoothDevices(batteryCache: BluetoothBatteryCache) -> [BluetoothAccessoryCandidate] {
        // Prefer macOS's live connected-device list. If unavailable or empty, use paired
        // devices only when IOBluetooth reports them connected; never show every paired
        // accessory as if it were currently active.
        var liveConnected: [IOBluetoothDevice] = []
        let selector = NSSelectorFromString("connectedDevices")
        if let method = class_getClassMethod(IOBluetoothDevice.self, selector) {
            typealias ConnectedDevicesFunction = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
            let implementation = method_getImplementation(method)
            let function = unsafeBitCast(implementation, to: ConnectedDevicesFunction.self)
            if let result = function(IOBluetoothDevice.self, selector)?.takeUnretainedValue() as? [IOBluetoothDevice] {
                liveConnected = result
            }
        }
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        let activeDevices = liveConnected.isEmpty ? paired.filter { $0.isConnected() } : liveConnected
        let pairedByAddress = Dictionary(grouping: paired, by: { normalizeBluetoothAddress($0.addressString) })

        var candidates: [BluetoothAccessoryCandidate] = []
        var seen = Set<String>()
        for device in activeDevices {
            let address = normalizeBluetoothAddress(device.addressString)
            let pairedMatches = address.isEmpty ? [] : (pairedByAddress[address] ?? [])
            let sources = [device] + pairedMatches
            let aliases = uniqueStrings(sources.flatMap { [$0.nameOrAddress, $0.name] }
                .compactMap { bluetoothName($0, excludingAddress: address) }
                + batteryCache.aliases(forAddress: address))
            guard !aliases.isEmpty,
                  let model = appleAccessoryModel(from: aliases) else { continue }
            let displayName = aliases.first ?? model
            let key = address.isEmpty ? displayName.lowercased() : address
            guard seen.insert(key).inserted else { continue }
            candidates.append(BluetoothAccessoryCandidate(device: device, name: displayName,
                                                           model: model, aliases: aliases))
        }
        return candidates
    }

    private static func bluetoothName(_ value: String?, excludingAddress address: String) -> String? {
        guard let value else { return nil }
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let normalized = normalizeBluetoothAddress(name)
        guard address.isEmpty || normalized != address else { return nil }
        return name
    }

    private static func uniqueStrings(_ strings: [String]) -> [String] {
        var seen = Set<String>()
        return strings.filter { seen.insert($0.lowercased()).inserted }
    }

    private static func appleAccessoryModel(from names: [String]) -> String? {
        let joined = names.joined(separator: " ").lowercased()
        if joined.contains("airpods") {
            return names.first(where: { $0.localizedCaseInsensitiveContains("AirPods") }) ?? "AirPods"
        }
        if joined.contains("magic mouse") || joined.contains("apple wireless mouse") { return "Magic Mouse" }
        if joined.contains("magic keyboard") || joined.contains("apple wireless keyboard") { return "Magic Keyboard" }
        if joined.contains("magic trackpad") { return "Magic Trackpad" }
        if joined.contains("beats") {
            return names.first(where: { $0.localizedCaseInsensitiveContains("Beats") }) ?? "Beats"
        }
        return nil
    }

    private struct AccessoryBatteryReading {
        let percent: Int?
        let isCharging: Bool?
    }

    private static func readAppleAccessoryBatteries() -> [String: AccessoryBatteryReading] {
        // Apple publishes accessory battery data on this I/O Registry service, rather than
        // as a standard IOHIDDevice property on some macOS and accessory combinations.
        guard let matching = IOServiceMatching("AppleDeviceManagementHIDEventService") else { return [:] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }

        var batteries: [String: AccessoryBatteryReading] = [:]
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            let transport = IORegistryEntryCreateCFProperty(service, "Transport" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            let manufacturer = IORegistryEntryCreateCFProperty(service, "Manufacturer" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            guard transport == "Bluetooth", manufacturer?.localizedCaseInsensitiveContains("Apple") == true,
                  let address = IORegistryEntryCreateCFProperty(service, "DeviceAddress" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else { continue }
            let percent = IORegistryEntryCreateCFProperty(service, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
            let flags = IORegistryEntryCreateCFProperty(service, "BatteryStatusFlags" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
            guard percent != nil || flags != nil else { continue }
            batteries[normalizeBluetoothAddress(address)] = AccessoryBatteryReading(
                percent: percent.map { min(max($0.intValue, 0), 100) },
                isCharging: flags.map { ($0.intValue & (1 << 1)) != 0 }
            )
        }
        return batteries
    }

    private static func normalizeBluetoothAddress(_ address: String?) -> String {
        (address ?? "").filter(\.isHexDigit).lowercased()
    }

    private struct BluetoothBatteryCache {
        var byAddress: [String: [String: Int]] = [:]
        var byName: [String: [String: Int]] = [:]
        var chargingByAddress: [String: [String: Bool]] = [:]
        var chargingByName: [String: [String: Bool]] = [:]
        var aliasesByAddress: [String: [String]] = [:]

        func aliases(forAddress address: String) -> [String] {
            aliasesByAddress[address] ?? []
        }

        func levels(forAddress address: String, names: [String]) -> [String: Int] {
            if let levels = byAddress[address], !levels.isEmpty { return levels }
            for name in names where !name.isEmpty {
                if let levels = byName[name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()], !levels.isEmpty {
                    return levels
                }
            }
            return [:]
        }

        func chargingStates(forAddress address: String, names: [String]) -> [String: Bool] {
            if let states = chargingByAddress[address], !states.isEmpty { return states }
            for name in names where !name.isEmpty {
                if let states = chargingByName[name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()], !states.isEmpty {
                    return states
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
        let chargingKeys = [
            ("Left", ["BatteryIsChargingLeft", "BatteryChargingLeft", "IsChargingLeft"]),
            ("Right", ["BatteryIsChargingRight", "BatteryChargingRight", "IsChargingRight"]),
            ("Case", ["BatteryIsChargingCase", "BatteryChargingCase", "IsChargingCase"]),
            ("Battery", ["BatteryIsCharging", "BatteryCharging", "IsCharging"])
        ]
        let chargingFlagKeys = [
            ("Left", ["BatteryStatusFlagsLeft", "BatteryFlagsLeft"]),
            ("Right", ["BatteryStatusFlagsRight", "BatteryFlagsRight"]),
            ("Case", ["BatteryStatusFlagsCase", "BatteryFlagsCase"]),
            ("Battery", ["BatteryStatusFlags", "BatteryFlags"])
        ]
        for (address, value) in deviceCache {
            guard let record = value as? [String: Any] else { continue }
            let normalizedAddress = normalizeBluetoothAddress(address)
            let recordAliases = uniqueStrings(["Name", "DeviceName", "UserName", "ProductName", "Product", "Model", "ModelName"]
                .compactMap { record[$0] as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty })
            if !recordAliases.isEmpty { result.aliasesByAddress[normalizedAddress] = recordAliases }
            var levels: [String: Int] = [:]
            for (label, key) in keys {
                if let percent = (record[key] as? NSNumber)?.intValue { levels[label] = min(max(percent, 0), 100) }
            }
            var chargingStates: [String: Bool] = [:]
            for (label, aliases) in chargingKeys {
                if let status = aliases.compactMap({ record[$0] as? NSNumber }).first {
                    chargingStates[label] = status.boolValue
                }
            }
            for (label, aliases) in chargingFlagKeys where chargingStates[label] == nil {
                if let flags = aliases.compactMap({ record[$0] as? NSNumber }).first {
                    chargingStates[label] = (flags.intValue & (1 << 1)) != 0
                }
            }
            guard !levels.isEmpty || !chargingStates.isEmpty else { continue }
            if !levels.isEmpty { result.byAddress[normalizedAddress] = levels }
            if !chargingStates.isEmpty { result.chargingByAddress[normalizedAddress] = chargingStates }
            // Bluetooth stores the friendly name separately from the IOBluetooth model
            // name (for example, “Xyna” versus “AirPods 4”). Index those names too.
            for alias in recordAliases {
                let normalizedAlias = alias.lowercased()
                if !levels.isEmpty { result.byName[normalizedAlias] = levels }
                if !chargingStates.isEmpty { result.chargingByName[normalizedAlias] = chargingStates }
            }
        }
        return result
    }

    private static func readEnergyStatus() -> EnergyStatus {
        let lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return EnergyStatus(batteryPercent: nil, batteryHealth: nil, cycleCount: nil, adapterWatts: adapterWatts(), powerSource: "—", charging: false, lowPowerMode: lowPowerMode)
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

    private static func readSystemPowerWatts() -> Double? {
        guard let matching = IOServiceMatching("AppleSmartBattery") else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(service, "PowerTelemetryData" as CFString, kCFAllocatorDefault, 0),
              let telemetry = property.takeRetainedValue() as? [String: Any],
              let milliwatts = (telemetry["SystemPowerIn"] as? NSNumber)?.doubleValue,
              milliwatts > 0, milliwatts < 500_000 else { return nil }
        return milliwatts / 1_000
    }

    private static func thermalPressureLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
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
    case cpu = "CPU", memory = "Memory", disk = "Disk", network = "Wi-Fi", gpu = "GPU", energy = "Energy", thermals = "Thermals"
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .cpu: Color(red: 0.12, green: 0.57, blue: 0.72)
        case .memory: Color(red: 0.27, green: 0.40, blue: 0.84)
        case .disk: Color(red: 0.32, green: 0.58, blue: 0.23)
        case .network: Color(red: 0.42, green: 0.32, blue: 0.78)
        case .gpu: Color(red: 0.78, green: 0.36, blue: 0.22)
        case .energy: Color(red: 0.94, green: 0.70, blue: 0.12)
        case .thermals: Color(red: 0.94, green: 0.40, blue: 0.16)
        }
    }
    var icon: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .network: "wifi"
        case .gpu: "display"
        case .energy: "bolt"
        case .thermals: "thermometer.medium"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var displayTheme: DisplayThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("floatingPerformanceOverlay") private var floatingOverlayEnabled = false
    @StateObject private var floatingOverlay = FloatingPerformanceOverlayController()
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
    private var accent: Color { displayTheme.accent(for: colorScheme) }
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
        .frame(width: 1080, height: 768)
        .background {
            ZStack {
                surface
                RadialGradient(colors: [accent.opacity(isDark ? 0.12 : 0.06), .clear], center: .topLeading, startRadius: 20, endRadius: 620)
                RadialGradient(colors: [Color.blue.opacity(isDark ? 0.12 : 0.07), .clear], center: .bottomTrailing, startRadius: 10, endRadius: 560)
            }
        }
        .foregroundStyle(ink)
        .tint(accent)
        .onAppear {
            startupItems = readStartupItems()
            if floatingOverlayEnabled { floatingOverlay.show(monitor: monitor) }
        }
        .onChange(of: floatingOverlayEnabled) { _, enabled in
            if enabled {
                floatingOverlay.show(monitor: monitor)
            } else {
                floatingOverlay.hide()
            }
        }
        .onDisappear { floatingOverlay.hide() }
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
            .foregroundStyle(selected ? accent : ink)
            .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(selected ? accent.opacity(isDark ? 0.18 : 0.10) : .clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
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
            .frame(width: 260)
            .background(panel)
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
                        ContentUnavailableView("No GPU reading", systemImage: "gpu", description: Text("This Mac does not expose a GPU utilization counter to apps."))
                            .frame(height: 270)
                    } else if resource == .energy && monitor.systemPowerWatts == nil {
                        ContentUnavailableView("No energy reading", systemImage: "bolt", description: Text("This Mac is not currently reporting system power telemetry."))
                            .frame(height: 270)
                    } else if resource == .thermals && monitor.thermalTemperature == nil {
                        ContentUnavailableView("No temperature reading", systemImage: "thermometer.medium", description: Text("macOS did not provide temperature readings for this Mac."))
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
                    else if resource == .energy { energyStats }
                    else { thermalsStats }
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
        case .energy: "Live system power"
        case .thermals: "Average temperature across available sensors and thermal pressure"
        }
    }

    private var resourceMetricLabel: String {
        switch resource {
        case .cpu, .gpu: "Utilization (%)"
        case .memory: "Memory composition"
        case .disk: "Disk read/write throughput"
        case .network: "Throughput"
        case .energy: "System power draw (W)"
        case .thermals: "Temperature (°C) · thermal pressure"
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
                if monitor.appleDevices.isEmpty {
                    ContentUnavailableView("No connected Apple accessories", systemImage: "apple.logo",
                        description: Text("Connect an Apple accessory such as AirPods, Magic Mouse, Magic Keyboard, or Magic Trackpad, then refresh."))
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], alignment: .leading, spacing: 14) {
                        ForEach(monitor.appleDevices) { device in
                            appleDeviceCard(device)
                        }
                    }
                }
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
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: appleDeviceIcon("\(device.name) \(device.model)"))
                    .font(.system(size: 24)).foregroundStyle(accent)
                    .frame(width: 48, height: 48)
                    .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                        .frame(height: 36, alignment: .top)
                    Text("Model: \(device.model)")
                        .font(.system(size: 11))
                        .foregroundStyle(muted)
                        .lineLimit(2)
                        .frame(height: 32, alignment: .top)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Spacer(minLength: 0)
                AccessoryBatteryIndicators(device: device, accentColor: accent, compact: true, alignRight: true)
            }
        }
        .padding(16)
        // Keep every accessory tile the same height, even when its name/model wraps.
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 170, alignment: .topLeading)
        .background(cardFill, in: Rectangle())
        .modifier(AdaptiveLiquidGlass(enabled: false, cornerRadius: 0))
        // Apply the size constraint outside the glass effect as well, so the
        // rendered tile stays fixed even if the effect changes its layout.
        .frame(height: 170, alignment: .topLeading)
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
        ScrollView {
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
                    }
                    .background(cardFill, in: Rectangle())
                }
            }
            .padding(24)
        }
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
            .background(selected ? accent.opacity(isDark ? 0.12 : 0.07) : .clear, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(selected ? accent.opacity(0.46) : hairline.opacity(0.55), lineWidth: selected ? 1 : 0.6))
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
        .chartYScale(domain: 0...([.cpu, .gpu, .memory, .thermals].contains(resource) ? 100 : max((series.map(\.value).max() ?? 1) * 1.15, 1)))
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
            AxisValueLabel {
                if let n = value.as(Double.self) { Text(chartAxisLabel(n)).font(.system(size: 10)).foregroundColor(muted) }
            }
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
            stat("Utilization", monitor.gpuUsage.map { String(format: "%.0f%%", $0) } ?? "—", large: true)
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
            VStack(alignment: .leading, spacing: 18) {
                stat("System power", monitor.systemPowerWatts.map { String(format: "%.1f W", $0) } ?? "—", large: true)
                stat("Battery", monitor.energyStatus.batteryPercent.map { String(format: "%.0f%%", $0) } ?? "No battery")
            }
            VStack(alignment: .leading, spacing: 12) {
                detail("Power source", monitor.energyStatus.powerSource)
                detail("Charging", monitor.energyStatus.charging ? "Yes" : "No")
                detail("Charger rating", monitor.energyStatus.adapterWatts.map { String(format: "%.0f W", $0) } ?? "—")
                detail("Battery health", monitor.energyStatus.batteryHealth ?? "—")
                detail("Battery cycle count", monitor.energyStatus.cycleCount.map(String.init) ?? "—")
                detail("Low Power Mode", monitor.energyStatus.lowPowerMode ? "On" : "Off")
            }
        }.padding(.top, 4)
    }

    private var thermalsStats: some View {
        HStack(alignment: .top, spacing: 48) {
            stat("\(monitor.thermalSensorLabel) temperature", monitor.thermalTemperature.map { String(format: "%.1f°C", $0) } ?? "—", large: true)
            VStack(alignment: .leading, spacing: 12) {
                detail("Thermal pressure", monitor.thermalPressure)
                detail("Sensor source", "Apple temperature sensors")
                detail("Sampling", "Live · 1 second")
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
        case .energy: monitor.powerHistory
        case .thermals: monitor.thermalHistory
        }
    }
    private func chartAxisLabel(_ value: Double) -> String {
        if [.network, .disk].contains(resource) { return bitRateLabel(value * 1_000_000) }
        if [.cpu, .gpu].contains(resource) { return String(format: "%.0f%%", value) }
        if resource == .energy { return String(format: "%.0f W", value) }
        if resource == .thermals { return String(format: "%.0f°C", value) }
        return String(format: "%.0f", value)
    }
    private func resourceValue(_ item: PerformanceResource) -> String {
        switch item {
        case .cpu: String(format: "%.1f%%", monitor.cpuUsage)
        case .memory: "\(bytes(monitor.memoryUsed)) / \(bytes(monitor.hardware.memory))"
        case .disk: "R \(rate(monitor.diskReadRate)) · W \(rate(monitor.diskWriteRate))"
        case .network: rate(monitor.networkRate)
        case .gpu: monitor.gpuUsage.map { String(format: "%.1f%%", $0) } ?? "—"
        case .energy: monitor.systemPowerWatts.map { String(format: "%.1f W", $0) } ?? "—"
        case .thermals: monitor.thermalTemperature.map { String(format: "%.1f°C", $0) } ?? monitor.thermalPressure
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

private struct FloatingPerformanceOverlayView: View {
    @ObservedObject var monitor: SystemMonitor
    @AppStorage("floatingPerformanceOverlay") private var enabled = true
    @AppStorage("floatingPerformanceOverlayOpacity") private var glassOpacity = 0.68

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                Image(systemName: "waveform.path")
                    .foregroundStyle(.green)
                Text("Task Manager Overlay")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    enabled = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close performance overlay")
            }

            VStack(spacing: 7) {
                metric("CPU", String(format: "%.1f%%", monitor.cpuUsage), "cpu", .cyan)
                Divider()
                metric("GPU", monitor.gpuUsage.map { String(format: "%.1f%%", $0) } ?? "—", "display", .orange)
                Divider()
                metric("Memory", memoryValue, "memorychip", .purple)
                Divider()
                metric(monitor.thermalSensorLabel, monitor.thermalTemperature.map { String(format: "%.1f°C", $0) } ?? "—", "thermometer.medium", .orange)
                Divider()
                metric("Power", monitor.systemPowerWatts.map { String(format: "%.1f W", $0) } ?? "—", "bolt", .yellow)
            }
        }
        .padding(14)
        .frame(width: 310, height: 230)
        .modifier(PerformanceOverlayGlass(opacity: glassOpacity, cornerRadius: 17))
    }

    private var memoryValue: String {
        let used = ByteCountFormatter.string(fromByteCount: Int64(clamping: monitor.memoryUsed), countStyle: .memory)
        let total = ByteCountFormatter.string(fromByteCount: Int64(clamping: monitor.hardware.memory), countStyle: .memory)
        let percent = Double(monitor.memoryUsed) / max(Double(monitor.hardware.memory), 1) * 100
        return String(format: "%.0f%% · %@ / %@", percent, used, total)
    }

    private func metric(_ title: String, _ value: String, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 15)
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(height: 19)
    }
}

private struct PerformanceOverlayGlass: ViewModifier {
    let opacity: Double
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            content
                .background(Color.white.opacity(opacity * 0.035), in: shape)
                .glassEffect(.regular.tint(Color.white.opacity(opacity * 0.16)).interactive(), in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.14 + opacity * 0.08), lineWidth: 0.8))
        } else {
            content
                .background(.ultraThinMaterial.opacity(opacity), in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.14 + opacity * 0.08), lineWidth: 0.8))
        }
    }
}

private struct DisplaySettingsView: View {
    @EnvironmentObject private var theme: DisplayThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("floatingPerformanceOverlay") private var floatingOverlayEnabled = false
    @AppStorage("floatingPerformanceOverlayOpacity") private var floatingOverlayOpacity = 0.68
    private var accent: Color { theme.accent(for: colorScheme) }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [accent.opacity(colorScheme == .dark ? 0.16 : 0.08), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .zIndex(0)

            VStack(alignment: .leading, spacing: 14) {
                Text("Theme").font(.system(size: 22, weight: .semibold))

                VStack(spacing: 0) {
                    HStack(alignment: .center, spacing: 12) {
                        Text("Appearance")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 112, alignment: .leading)
                        HStack(spacing: 8) {
                            ForEach(DisplayAppearance.allCases) { option in
                                appearanceOption(option)
                            }
                        }
                    }
                    .padding(.vertical, 15)

                    Divider()

                    HStack(alignment: .center, spacing: 12) {
                        Text("Color")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 112, alignment: .leading)
                        HStack(spacing: 5) {
                            ForEach(AccentChoice.allCases) { choice in
                                accentOption(choice)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 12)

                    Divider()

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Fullscreen performance overlay")
                                .font(.system(size: 14, weight: .medium))
                            Text("Show live system stats above fullscreen apps when supported.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Toggle("", isOn: $floatingOverlayEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .accessibilityLabel("Fullscreen performance overlay")
                    }
                    .padding(.vertical, 12)

                    Divider()

                    HStack(spacing: 12) {
                        Text("Glass opacity")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 112, alignment: .leading)
                        Slider(value: $floatingOverlayOpacity, in: 0.35...1.0, step: 0.05)
                            .accessibilityLabel("Floating overlay glass opacity")
                        Text("\(Int(floatingOverlayOpacity * 100))%")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .frame(width: 38, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 12)
                }
                .padding(.horizontal, 17)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .modifier(AdaptiveLiquidGlass(enabled: true, cornerRadius: 18))
                .zIndex(2)

                Spacer(minLength: 0)
            }
            .padding(24)
            .zIndex(1)
        }
        .frame(width: 660, height: 520)
        .background(.regularMaterial)
        .tint(accent)
    }

    private func appearanceOption(_ option: DisplayAppearance) -> some View {
        let selected = theme.appearance == option
        return Button {
            theme.appearance = option
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.18, green: 0.59, blue: 0.86), Color(red: 0.10, green: 0.28, blue: 0.60)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    if option == .system {
                        previewWindow(dark: false)
                            .frame(width: 67, height: 43)
                            .offset(x: -13, y: -5)
                            .zIndex(1)
                        previewWindow(dark: true)
                            .frame(width: 67, height: 43)
                            .offset(x: 13, y: 5)
                            .zIndex(2)
                    } else {
                        previewWindow(dark: option == .dark)
                            .frame(width: 75, height: 48)
                    }
                }
                .frame(width: 100, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(selected ? accent : Color.white.opacity(0.18), lineWidth: selected ? 2.5 : 0.8)
                }
                Text(option.rawValue)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? accent : .secondary)
            }
            .frame(width: 106, height: 85)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.rawValue) appearance")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func previewWindow(dark: Bool) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                Circle().fill(Color(red: 1, green: 0.34, blue: 0.31))
                Circle().fill(Color(red: 1, green: 0.75, blue: 0.20))
                Circle().fill(Color(red: 0.20, green: 0.78, blue: 0.33))
                Spacer(minLength: 0)
            }
            .frame(height: 5)
            RoundedRectangle(cornerRadius: 2)
                .fill(accent.opacity(0.72))
                .frame(height: 7)
            Spacer(minLength: 0)
        }
        .padding(4)
        .background(dark ? Color(red: 0.12, green: 0.14, blue: 0.20) : Color.white, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.16), lineWidth: 0.6))
        .shadow(color: .black.opacity(0.24), radius: 3, y: 2)
    }

    private func accentOption(_ choice: AccentChoice) -> some View {
        let selected = theme.accentChoice == choice
        return Button {
            theme.accentChoice = choice
        } label: {
            Circle()
                .fill(choice == .multicolor
                    ? AnyShapeStyle(AngularGradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red], center: .center))
                    : AnyShapeStyle(colorScheme == .dark ? choice.darkColor : choice.lightColor))
                .frame(width: 31, height: 31)
                .overlay {
                    if selected {
                        Circle().stroke(colorScheme == .dark ? Color.white.opacity(0.9) : Color.black.opacity(0.78), lineWidth: 1.5)
                            .padding(4)
                    }
                }
                .frame(width: 39, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(choice.title) theme color")
        .accessibilityAddTraits(selected ? .isSelected : [])
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
