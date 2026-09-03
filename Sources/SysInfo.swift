import Darwin
import Foundation
import Metal

// MARK: - Formatting

func formatMB(_ bytes: UInt64) -> String {
    String(format: "%.1f MB", Double(bytes) / 1_048_576)
}

func formatGB(_ bytes: UInt64) -> String {
    String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(max(0, seconds))
    let days = total / 86_400
    let hours = (total % 86_400) / 3_600
    let minutes = (total % 3_600) / 60
    let secs = total % 60
    if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
    if hours > 0 { return "\(hours)h \(minutes)m \(secs)s" }
    return "\(minutes)m \(secs)s"
}

// MARK: - sysctl

func sysctlInt(_ name: String) -> Int? {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return Int(value)
}

func machineIdentifier() -> String {
    var sys = utsname()
    uname(&sys)
    let size = MemoryLayout.size(ofValue: sys.machine)
    return withUnsafePointer(to: &sys.machine) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: size) { String(cString: $0) }
    }
}

func kernelVersion() -> String {
    var sys = utsname()
    uname(&sys)
    let size = MemoryLayout.size(ofValue: sys.version)
    let full = withUnsafePointer(to: &sys.version) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: size) { String(cString: $0) }
    }
    return String(full.prefix(60))
}

func bootDate() -> Date? {
    var tv = timeval()
    var size = MemoryLayout<timeval>.size
    guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return nil }
    return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
}

// MARK: - This process

struct AppMemoryInfo {
    var footprint: UInt64
    var resident: UInt64
    var virtualSize: UInt64
}

func appMemoryInfo() -> AppMemoryInfo? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    return AppMemoryInfo(footprint: UInt64(info.phys_footprint),
                         resident: UInt64(info.resident_size),
                         virtualSize: UInt64(info.virtual_size))
}

struct AppCPUInfo {
    var total: Double
    var threadCount: Int
    var topThreads: [Double]
}

func appCPUInfo() -> AppCPUInfo {
    var list: thread_act_array_t?
    var listCount: mach_msg_type_number_t = 0
    guard task_threads(mach_task_self_, &list, &listCount) == KERN_SUCCESS, let threads = list else {
        return AppCPUInfo(total: 0, threadCount: 0, topThreads: [])
    }
    var usages: [Double] = []
    for index in 0..<Int(listCount) {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            usages.append(Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100)
        }
    }
    vm_deallocate(mach_task_self_,
                  vm_address_t(UInt(bitPattern: UnsafeRawPointer(threads))),
                  vm_size_t(Int(listCount) * MemoryLayout<thread_t>.size))
    return AppCPUInfo(total: usages.reduce(0, +),
                      threadCount: Int(listCount),
                      topThreads: Array(usages.sorted(by: >).prefix(5)))
}

// MARK: - Whole system

func hostCPUTicks() -> [[UInt32]] {
    var cpuCount: natural_t = 0
    var info: processor_info_array_t?
    var infoCount: mach_msg_type_number_t = 0
    let result = host_processor_info(mach_host_self(),
                                     processor_flavor_t(PROCESSOR_CPU_LOAD_INFO),
                                     &cpuCount, &info, &infoCount)
    guard result == KERN_SUCCESS, let array = info else { return [] }
    let states = Int(CPU_STATE_MAX)
    var cores: [[UInt32]] = []
    for core in 0..<Int(cpuCount) {
        var ticks: [UInt32] = []
        for state in 0..<states {
            ticks.append(UInt32(bitPattern: array[core * states + state]))
        }
        cores.append(ticks)
    }
    vm_deallocate(mach_task_self_,
                  vm_address_t(UInt(bitPattern: UnsafeRawPointer(array))),
                  vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.size))
    return cores
}

struct HostMemoryInfo {
    var free: UInt64
    var active: UInt64
    var inactive: UInt64
    var wired: UInt64
    var compressed: UInt64
}

func hostMemoryInfo() -> HostMemoryInfo? {
    var stats = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &stats) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), host_flavor_t(HOST_VM_INFO64), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    let page = UInt64(vm_page_size)
    return HostMemoryInfo(free: UInt64(stats.free_count) * page,
                          active: UInt64(stats.active_count) * page,
                          inactive: UInt64(stats.inactive_count) * page,
                          wired: UInt64(stats.wire_count) * page,
                          compressed: UInt64(stats.compressor_page_count) * page)
}

// MARK: - Interfaces

struct InterfaceSample {
    var name: String
    var addresses: [String] = []
    var up = false
    var running = false
    var bytesIn: UInt64 = 0
    var bytesOut: UInt64 = 0
}

func interfaceSamples() -> [InterfaceSample] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return [] }
    defer { freeifaddrs(head) }

    var byName: [String: InterfaceSample] = [:]
    var order: [String] = []
    var cursor = head
    while let current = cursor {
        let entry = current.pointee
        cursor = entry.ifa_next
        let name = String(cString: entry.ifa_name)
        if byName[name] == nil {
            byName[name] = InterfaceSample(name: name)
            order.append(name)
        }
        if entry.ifa_flags & UInt32(IFF_UP) != 0 { byName[name]?.up = true }
        if entry.ifa_flags & UInt32(IFF_RUNNING) != 0 { byName[name]?.running = true }
        guard let address = entry.ifa_addr else { continue }
        let family = address.pointee.sa_family
        if family == UInt8(AF_INET) || family == UInt8(AF_INET6) {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(address.pointee.sa_len)
            if getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, Int32(NI_NUMERICHOST)) == 0 {
                var text = host.withUnsafeBufferPointer { buffer -> String in
                    guard let base = buffer.baseAddress else { return "" }
                    return String(cString: base)
                }
                if let percent = text.firstIndex(of: "%") { text = String(text[text.startIndex..<percent]) }
                if !text.isEmpty { byName[name]?.addresses.append(text) }
            }
        } else if family == UInt8(AF_LINK), let data = entry.ifa_data {
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            byName[name]?.bytesIn = UInt64(counters.ifi_ibytes)
            byName[name]?.bytesOut = UInt64(counters.ifi_obytes)
        }
    }
    return order.compactMap { byName[$0] }
}

func isCarrierGradeNAT(_ address: String) -> Bool {
    let parts = address.split(separator: ".")
    guard parts.count == 4, let first = Int(parts[0]), let second = Int(parts[1]) else { return false }
    return first == 100 && (64...127).contains(second)
}

// MARK: - Device naming

func deviceNaming(for identifier: String) -> (name: String, chip: String) {
    let table: [String: (String, String)] = [
        "iPhone12,1": ("iPhone 11", "A13 Bionic"),
        "iPhone12,3": ("iPhone 11 Pro", "A13 Bionic"),
        "iPhone12,5": ("iPhone 11 Pro Max", "A13 Bionic"),
        "iPhone12,8": ("iPhone SE (2nd gen)", "A13 Bionic"),
        "iPhone13,1": ("iPhone 12 mini", "A14 Bionic"),
        "iPhone13,2": ("iPhone 12", "A14 Bionic"),
        "iPhone13,3": ("iPhone 12 Pro", "A14 Bionic"),
        "iPhone13,4": ("iPhone 12 Pro Max", "A14 Bionic"),
        "iPhone14,2": ("iPhone 13 Pro", "A15 Bionic"),
        "iPhone14,3": ("iPhone 13 Pro Max", "A15 Bionic"),
        "iPhone14,4": ("iPhone 13 mini", "A15 Bionic"),
        "iPhone14,5": ("iPhone 13", "A15 Bionic"),
        "iPhone14,6": ("iPhone SE (3rd gen)", "A15 Bionic"),
        "iPhone14,7": ("iPhone 14", "A15 Bionic"),
        "iPhone14,8": ("iPhone 14 Plus", "A15 Bionic"),
        "iPhone15,2": ("iPhone 14 Pro", "A16 Bionic"),
        "iPhone15,3": ("iPhone 14 Pro Max", "A16 Bionic"),
        "iPhone15,4": ("iPhone 15", "A16 Bionic"),
        "iPhone15,5": ("iPhone 15 Plus", "A16 Bionic"),
        "iPhone16,1": ("iPhone 15 Pro", "A17 Pro"),
        "iPhone16,2": ("iPhone 15 Pro Max", "A17 Pro"),
        "iPhone17,1": ("iPhone 16 Pro", "A18 Pro"),
        "iPhone17,2": ("iPhone 16 Pro Max", "A18 Pro"),
        "iPhone17,3": ("iPhone 16", "A18"),
        "iPhone17,4": ("iPhone 16 Plus", "A18"),
        "iPhone17,5": ("iPhone 16e", "A18"),
        "iPhone18,1": ("iPhone 17 Pro", "A19 Pro"),
        "iPhone18,2": ("iPhone 17 Pro Max", "A19 Pro"),
        "iPhone18,3": ("iPhone 17", "A19"),
        "iPhone18,4": ("iPhone Air", "A19 Pro")
    ]
    if let match = table[identifier] { return match }
    return (identifier, "unknown")
}

// MARK: - Metal

struct MetalInfo {
    var name: String
    var family: String
    var workingSet: String
    var maxThreadsPerThreadgroup: String
}

func metalInfo() -> MetalInfo? {
    guard let device = MTLCreateSystemDefaultDevice() else { return nil }
    let families: [(MTLGPUFamily, String)] = [
        (.apple9, "Apple9"), (.apple8, "Apple8"), (.apple7, "Apple7"),
        (.apple6, "Apple6"), (.apple5, "Apple5"), (.apple4, "Apple4")
    ]
    let family = families.first { device.supportsFamily($0.0) }?.1 ?? "unknown"
    let size = device.maxThreadsPerThreadgroup
    return MetalInfo(name: device.name,
                     family: family,
                     workingSet: formatMB(device.recommendedMaxWorkingSetSize),
                     maxThreadsPerThreadgroup: "\(size.width) x \(size.height) x \(size.depth)")
}
