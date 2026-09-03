import Foundation
import Network
import Observation
import SwiftUI
import UIKit
import UserNotifications

struct Row: Identifiable, Hashable {
    let label: String
    let value: String
    var id: String { label }

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

struct InterfaceGroup: Identifiable {
    let name: String
    let rows: [Row]
    var id: String { name }
}

struct OpenEvent: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var url: String
    var date: Date
    var latencyMS: Double?
    var cold: Bool
    var openID: String

    var timeText: String { date.formatted(date: .omitted, time: .standard) }
    var latencyText: String { latencyMS.map { String(format: "%.0f ms", $0) } ?? "no t" }
}

private enum Keys {
    static let topic = "topic"
    static let history = "history"
    static let launchCount = "launchCount"
}

@MainActor
@Observable
final class AppModel {
    // Test
    var topic: String
    var sendResult = ""
    var burstResult = ""
    var lastOpen: OpenEvent?
    var history: [OpenEvent] = []

    // Network
    var pathRows: [Row] = [Row("Status", "waiting…")]
    var interfaceGroups: [InterfaceGroup] = []
    var publicIP = "not fetched"
    var latencyHost = "1.1.1.1"
    var latencyPort = "443"
    var latencyResult = "not run"

    // App
    var appMemoryRows: [Row] = []
    var appCPURows: [Row] = []
    var lifecycleRows: [Row] = []
    var signingRows: [Row] = []
    var buildRows: [Row] = []
    var permissionRows: [Row] = [Row("Notification authorization", "checking…")]

    // Device
    var modelRows: [Row] = []
    var chipRows: [Row] = []
    var systemLiveRows: [Row] = []
    var storageRows: [Row] = []
    var displayRows: [Row] = []
    var powerRows: [Row] = []

    let launchDate = Date()

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var burstTask: Task<Void, Never>?
    @ObservationIgnored private var previousBytes: [String: (UInt64, UInt64)] = [:]
    @ObservationIgnored private var previousTicks: [[UInt32]] = []
    @ObservationIgnored private var launchCount = 0
    @ObservationIgnored private var memoryWarnings = 0
    @ObservationIgnored private var scenePhaseText = "active"
    @ObservationIgnored private var backgroundTimeText = "not observed"

    init() {
        let store = UserDefaults.standard
        let savedTopic = store.string(forKey: Keys.topic)
        topic = savedTopic ?? AppModel.randomTopic()

        if savedTopic == nil { store.set(topic, forKey: Keys.topic) }
        launchCount = store.integer(forKey: Keys.launchCount) + 1
        store.set(launchCount, forKey: Keys.launchCount)
        if let data = store.data(forKey: Keys.history),
           let decoded = try? JSONDecoder().decode([OpenEvent].self, from: data) {
            history = decoded
        }
        UIDevice.current.isBatteryMonitoringEnabled = true

        buildStaticRows()
        observeMemoryWarnings()
        refreshNotificationStatus()
        startPathMonitor()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: - Test tab

    static func randomTopic() -> String {
        let characters = "abcdefghijklmnopqrstuvwxyz0123456789"
        return "ntfytest-" + String((0..<12).compactMap { _ in characters.randomElement() })
    }

    func persistTopic() {
        UserDefaults.standard.set(topic, forKey: Keys.topic)
    }

    var lastOpenRows: [Row] {
        guard let event = lastOpen else { return [Row("Status", "no URL opened yet")] }
        var rows = [
            Row("URL", event.url),
            Row("Received", event.timeText),
            Row("Launch", event.cold ? "cold launch" : "warm"),
            Row("id", event.openID.isEmpty ? "none" : event.openID)
        ]
        if event.latencyMS != nil { rows.append(Row("Latency", event.latencyText)) }
        return rows
    }

    func handleOpen(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let openID = items.first { $0.name == "id" }?.value ?? ""
        let now = Date()
        var latency: Double?
        if let raw = items.first(where: { $0.name == "t" })?.value, let sent = Double(raw) {
            latency = now.timeIntervalSince1970 * 1_000 - sent
        }
        let event = OpenEvent(url: url.absoluteString,
                              date: now,
                              latencyMS: latency,
                              cold: now.timeIntervalSince(launchDate) < 3,
                              openID: openID)
        lastOpen = event
        history.insert(event, at: 0)
        if history.count > 20 { history = Array(history.prefix(20)) }
        saveHistory()
    }

    func clearHistory() {
        history = []
        saveHistory()
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: Keys.history)
        }
    }

    private func post(titleSuffix: String, id: String) async -> String {
        guard let escaped = topic.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://ntfy.sh/\(escaped)") else { return "invalid topic" }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("Tap to open NtfyTest".utf8)
        request.setValue("NtfyTest call\(titleSuffix)", forHTTPHeaderField: "Title")
        request.setValue("urgent", forHTTPHeaderField: "Priority")
        request.setValue("phone", forHTTPHeaderField: "Tags")
        let stamp = Int(Date().timeIntervalSince1970 * 1_000)
        request.setValue("ntfytest://open?id=\(id)&t=\(stamp)", forHTTPHeaderField: "Click")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
        } catch {
            return error.localizedDescription
        }
    }

    func sendOne() {
        Task {
            self.sendResult = "sending…"
            self.sendResult = await self.post(titleSuffix: "", id: UUID().uuidString)
        }
    }

    func sendBurst() {
        if let running = burstTask {
            running.cancel()
            burstTask = nil
            burstResult = "cancelled"
            return
        }
        let id = UUID().uuidString
        burstTask = Task {
            for number in 1...5 {
                if Task.isCancelled { break }
                let result = await self.post(titleSuffix: " (\(number)/5)", id: id)
                self.burstResult = "\(number)/5: \(result)"
                if number < 5 {
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { break }
                }
            }
            self.burstTask = nil
        }
    }

    // MARK: - Network tab

    private func startPathMonitor() {
        monitor.pathUpdateHandler = { [weak self] path in
            let rows = makePathRows(for: path)
            Task { @MainActor in self?.pathRows = rows }
        }
        monitor.start(queue: DispatchQueue(label: "com.example.ntfytest.path"))
    }

    private func refreshInterfaces() {
        var groups: [InterfaceGroup] = []
        for sample in interfaceSamples() where !sample.addresses.isEmpty {
            var rows = [Row("Interface", sample.name)]
            if sample.name.hasPrefix("utun") { rows.append(Row("Kind", "VPN tunnel")) }
            rows.append(Row("Addresses", sample.addresses.joined(separator: ", ")))
            var flags: [String] = []
            if sample.up { flags.append("UP") }
            if sample.running { flags.append("RUNNING") }
            rows.append(Row("Flags", flags.isEmpty ? "none" : flags.joined(separator: " ")))
            rows.append(Row("Bytes in", formatMB(sample.bytesIn)))
            rows.append(Row("Bytes out", formatMB(sample.bytesOut)))
            let previous = previousBytes[sample.name]
            let inRate = previous.map { Double(sample.bytesIn &- $0.0) / 1_024 } ?? 0
            let outRate = previous.map { Double(sample.bytesOut &- $0.1) / 1_024 } ?? 0
            rows.append(Row("Rate in", String(format: "%.1f KB/s", inRate)))
            rows.append(Row("Rate out", String(format: "%.1f KB/s", outRate)))
            if sample.addresses.contains(where: isCarrierGradeNAT) {
                rows.append(Row("Tailscale-range address", "yes"))
            }
            previousBytes[sample.name] = (sample.bytesIn, sample.bytesOut)
            groups.append(InterfaceGroup(name: sample.name, rows: rows))
        }
        interfaceGroups = groups
    }

    func refreshPublicIP() async {
        publicIP = "loading…"
        guard let url = URL(string: "https://api64.ipify.org") else {
            publicIP = "bad url"
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let text = String(data: data, encoding: .utf8) ?? ""
            publicIP = text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            publicIP = error.localizedDescription
        }
    }

    func runLatencyTest() async {
        guard let port = UInt16(latencyPort) else {
            latencyResult = "invalid port"
            return
        }
        latencyResult = "testing…"
        var times: [Double] = []
        var lastError = ""
        for _ in 0..<3 {
            let attempt = await tcpProbe(host: latencyHost, port: port, timeout: 3)
            if let ms = attempt.ms { times.append(ms) } else { lastError = attempt.error ?? "failed" }
        }
        guard let last = times.last, let best = times.min() else {
            latencyResult = lastError.isEmpty ? "no result" : lastError
            return
        }
        let average = times.reduce(0, +) / Double(times.count)
        var text = String(format: "last %.1f ms · min %.1f ms · avg %.1f ms", last, best, average)
        if !lastError.isEmpty { text += " · \(lastError)" }
        latencyResult = text
    }

    // MARK: - Live refresh

    func tick() {
        refreshInterfaces()
        refreshAppMemory()
        refreshAppCPU()
        refreshLifecycle()
        refreshSystemLive()
        refreshPower()
    }

    private func refreshAppMemory() {
        guard let memory = appMemoryInfo() else {
            appMemoryRows = [Row("Memory", "unavailable")]
            return
        }
        appMemoryRows = [
            Row("phys_footprint", formatMB(memory.footprint)),
            Row("resident_size", formatMB(memory.resident)),
            Row("virtual_size", formatMB(memory.virtualSize)),
            Row("Memory warnings", "\(memoryWarnings)")
        ]
    }

    private func refreshAppCPU() {
        let cpu = appCPUInfo()
        var usage = rusage()
        getrusage(Int32(RUSAGE_SELF), &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        let top = cpu.topThreads.map { String(format: "%.1f%%", $0) }.joined(separator: ", ")
        appCPURows = [
            Row("App CPU", String(format: "%.1f %%", cpu.total)),
            Row("Threads", "\(cpu.threadCount)"),
            Row("Top 5 threads", top.isEmpty ? "none" : top),
            Row("User CPU time", String(format: "%.2f s", user)),
            Row("System CPU time", String(format: "%.2f s", system))
        ]
    }

    private func refreshLifecycle() {
        lifecycleRows = [
            Row("Scene phase", scenePhaseText),
            Row("Process uptime", formatDuration(Date().timeIntervalSince(launchDate))),
            Row("Launch date", launchDate.formatted(date: .abbreviated, time: .standard)),
            Row("Launch count", "\(launchCount)"),
            Row("Background time left", backgroundTimeText)
        ]
    }

    private func refreshSystemLive() {
        var rows: [Row] = []
        let ticks = hostCPUTicks()
        if !previousTicks.isEmpty, previousTicks.count == ticks.count {
            var usedTotal = 0.0
            var allTotal = 0.0
            for (index, core) in ticks.enumerated() {
                let previous = previousTicks[index]
                guard core.count == previous.count else { continue }
                var used = 0.0
                var total = 0.0
                for state in 0..<core.count {
                    let delta = Double(core[state] &- previous[state])
                    total += delta
                    if state != Int(CPU_STATE_IDLE) { used += delta }
                }
                usedTotal += used
                allTotal += total
                rows.append(Row("Core \(index)", String(format: "%.0f %%", total > 0 ? used / total * 100 : 0)))
            }
            let overall = allTotal > 0 ? usedTotal / allTotal * 100 : 0
            rows.insert(Row("Overall CPU", String(format: "%.0f %%", overall)), at: 0)
        } else {
            rows.append(Row("Overall CPU", "sampling…"))
        }
        previousTicks = ticks
        if let memory = hostMemoryInfo() {
            rows.append(Row("Free", formatMB(memory.free)))
            rows.append(Row("Active", formatMB(memory.active)))
            rows.append(Row("Inactive", formatMB(memory.inactive)))
            rows.append(Row("Wired", formatMB(memory.wired)))
            rows.append(Row("Compressed", formatMB(memory.compressed)))
        }
        systemLiveRows = rows
    }

    private func refreshPower() {
        let device = UIDevice.current
        let level = device.batteryLevel
        var rows = [
            Row("Battery level", level < 0 ? "unknown" : String(format: "%.0f %%", level * 100)),
            Row("Battery state", batteryStateText(device.batteryState)),
            Row("Low power mode", ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off"),
            Row("Thermal state", thermalStateText(ProcessInfo.processInfo.thermalState)),
            Row("System uptime", formatDuration(ProcessInfo.processInfo.systemUptime))
        ]
        if let boot = bootDate() {
            rows.append(Row("Boot time", boot.formatted(date: .abbreviated, time: .standard)))
        }
        powerRows = rows
    }

    // MARK: - Lifecycle and static rows

    func setScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            scenePhaseText = "active"
        case .inactive:
            scenePhaseText = "inactive"
        case .background:
            scenePhaseText = "background"
            let remaining = UIApplication.shared.backgroundTimeRemaining
            backgroundTimeText = remaining > 1_000_000 ? "unlimited" : String(format: "%.0f s", remaining)
        @unknown default:
            scenePhaseText = "unknown"
        }
    }

    private func observeMemoryWarnings() {
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in self?.memoryWarnings += 1 }
        }
    }

    private func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let text = authorizationText(settings.authorizationStatus)
            Task { @MainActor in
                self?.permissionRows = [Row("Notification authorization", text)]
            }
        }
    }

    private func buildStaticRows() {
        let info = Bundle.main.infoDictionary ?? [:]
        buildRows = [
            Row("Bundle id", Bundle.main.bundleIdentifier ?? "unknown"),
            Row("Version", info["CFBundleShortVersionString"] as? String ?? "unknown"),
            Row("Build", info["CFBundleVersion"] as? String ?? "unknown"),
            Row("Commit", BuildInfo.commit),
            Row("Built", BuildInfo.date)
        ]
        signingRows = AppModel.provisioningRows()

        let identifier = machineIdentifier()
        let naming = deviceNaming(for: identifier)
        modelRows = [
            Row("Identifier", identifier),
            Row("Model", naming.name),
            Row("Chip", naming.chip),
            Row("iOS", UIDevice.current.systemVersion),
            Row("Kernel", kernelVersion()),
            Row("Device name", UIDevice.current.name),
            Row("Vendor id", UIDevice.current.identifierForVendor?.uuidString ?? "unavailable")
        ]

        var chip = [
            Row("hw.ncpu", sysctlInt("hw.ncpu").map { "\($0)" } ?? "unknown"),
            Row("hw.physicalcpu", sysctlInt("hw.physicalcpu").map { "\($0)" } ?? "unknown"),
            Row("hw.logicalcpu", sysctlInt("hw.logicalcpu").map { "\($0)" } ?? "unknown"),
            Row("Architecture", architectureName())
        ]
        if let metal = metalInfo() {
            chip.append(Row("Metal device", metal.name))
            chip.append(Row("GPU family", metal.family))
            chip.append(Row("Recommended working set", metal.workingSet))
            chip.append(Row("Max threads per threadgroup", metal.maxThreadsPerThreadgroup))
        } else {
            chip.append(Row("Metal device", "unavailable"))
        }
        chip.append(Row("Physical memory", formatGB(ProcessInfo.processInfo.physicalMemory)))
        chip.append(Row("vm_page_size", "\(vm_page_size) bytes"))
        chipRows = chip

        var storage: [Row] = []
        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()) {
            if let total = attributes[.systemSize] as? NSNumber {
                storage.append(Row("Total", formatGB(UInt64(truncating: total))))
            }
            if let free = attributes[.systemFreeSize] as? NSNumber {
                storage.append(Row("Free", formatGB(UInt64(truncating: free))))
            }
        }
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey,
                                         .volumeAvailableCapacityForOpportunisticUsageKey]
        if let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: keys) {
            if let important = values.volumeAvailableCapacityForImportantUsage {
                storage.append(Row("Available (important)", formatGB(UInt64(max(0, important)))))
            }
            if let opportunistic = values.volumeAvailableCapacityForOpportunisticUsage {
                storage.append(Row("Available (opportunistic)", formatGB(UInt64(max(0, opportunistic)))))
            }
        }
        storageRows = storage.isEmpty ? [Row("Storage", "unavailable")] : storage

        let screen = UIScreen.main
        displayRows = [
            Row("Bounds (points)", "\(Int(screen.bounds.width)) x \(Int(screen.bounds.height))"),
            Row("Native (pixels)", "\(Int(screen.nativeBounds.width)) x \(Int(screen.nativeBounds.height))"),
            Row("Scale", "\(screen.scale)"),
            Row("Native scale", "\(screen.nativeScale)"),
            Row("Max frames per second", "\(screen.maximumFramesPerSecond)"),
            Row("Brightness", String(format: "%.0f %%", screen.brightness * 100))
        ]
    }

    private static func provisioningRows() -> [Row] {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return [Row("Profile", "No provisioning profile (unsigned build)")]
        }
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)),
              let plist = try? PropertyListSerialization.propertyList(
                  from: Data(data[start.lowerBound..<end.upperBound]), options: [], format: nil),
              let dictionary = plist as? [String: Any] else {
            return [Row("Profile", "found, but the embedded plist could not be read")]
        }
        var rows = [
            Row("Name", dictionary["Name"] as? String ?? "unknown"),
            Row("Team", dictionary["TeamName"] as? String ?? "unknown")
        ]
        if let expiry = dictionary["ExpirationDate"] as? Date {
            rows.append(Row("Expires", expiry.formatted(date: .abbreviated, time: .shortened)))
            rows.append(Row("Expires in", "\(Int(expiry.timeIntervalSinceNow / 86_400)) days"))
        }
        let devices = dictionary["ProvisionedDevices"] as? [String] ?? []
        rows.append(Row("Provisioned devices", "\(devices.count)"))
        let entitlements = dictionary["Entitlements"] as? [String: Any] ?? [:]
        rows.append(Row("application-identifier", entitlements["application-identifier"] as? String ?? "unknown"))
        rows.append(Row("Entitlement keys", entitlements.keys.sorted().joined(separator: ", ")))
        return rows
    }
}

// MARK: - Free functions

private func architectureName() -> String {
    #if arch(arm64)
    return "arm64"
    #elseif arch(x86_64)
    return "x86_64"
    #else
    return "unknown"
    #endif
}

private func makePathRows(for path: NWPath) -> [Row] {
    let types: [(NWInterface.InterfaceType, String)] = [
        (.wifi, "wifi"), (.cellular, "cellular"), (.wiredEthernet, "wiredEthernet"), (.other, "other")
    ]
    let inUse = types.filter { path.usesInterfaceType($0.0) }.map { $0.1 }
    let gateways = path.gateways.map { "\($0)" }
    return [
        Row("Status", pathStatusText(path.status)),
        Row("Interfaces in use", inUse.isEmpty ? "none" : inUse.joined(separator: ", ")),
        Row("isExpensive", path.isExpensive ? "yes" : "no"),
        Row("isConstrained", path.isConstrained ? "yes" : "no"),
        Row("supportsIPv4", path.supportsIPv4 ? "yes" : "no"),
        Row("supportsIPv6", path.supportsIPv6 ? "yes" : "no"),
        Row("Gateways", gateways.isEmpty ? "none" : gateways.joined(separator: ", "))
    ]
}

private func pathStatusText(_ status: NWPath.Status) -> String {
    switch status {
    case .satisfied: return "satisfied"
    case .unsatisfied: return "unsatisfied"
    case .requiresConnection: return "requiresConnection"
    @unknown default: return "unknown"
    }
}

private func batteryStateText(_ state: UIDevice.BatteryState) -> String {
    switch state {
    case .unknown: return "unknown"
    case .unplugged: return "unplugged"
    case .charging: return "charging"
    case .full: return "full"
    @unknown default: return "unknown"
    }
}

private func thermalStateText(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
}

private func authorizationText(_ status: UNAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: return "not determined"
    case .denied: return "denied"
    case .authorized: return "authorized"
    case .provisional: return "provisional"
    case .ephemeral: return "ephemeral"
    @unknown default: return "unknown"
    }
}

private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

func tcpProbe(host: String, port: UInt16, timeout: TimeInterval) async -> (ms: Double?, error: String?) {
    guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return (nil, "invalid port") }
    let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
    let queue = DispatchQueue(label: "com.example.ntfytest.latency")
    let once = ResumeGuard()
    let start = DispatchTime.now()
    return await withCheckedContinuation { (continuation: CheckedContinuation<(ms: Double?, error: String?), Never>) in
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if once.claim() {
                    let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
                    connection.cancel()
                    continuation.resume(returning: (Double(elapsed) / 1_000_000, nil))
                }
            case .failed(let error):
                if once.claim() {
                    connection.cancel()
                    continuation.resume(returning: (nil, error.localizedDescription))
                }
            case .waiting(let error):
                if once.claim() {
                    connection.cancel()
                    continuation.resume(returning: (nil, error.localizedDescription))
                }
            default:
                break
            }
        }
        queue.asyncAfter(deadline: .now() + timeout) {
            if once.claim() {
                connection.cancel()
                continuation.resume(returning: (nil, "timeout"))
            }
        }
        connection.start(queue: queue)
    }
}
