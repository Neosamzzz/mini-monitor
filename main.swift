import SwiftUI
import Darwin
import ServiceManagement
import UserNotifications

// MARK: - 数据采集

struct CPUSampler {
    private var prev: (busy: UInt64, total: UInt64)?

    private static func ticks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), sys = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + sys + nice, user + sys + nice + idle)
    }

    /// 返回距上次调用以来的 CPU 使用率(0–100),首次调用返回 nil
    mutating func sample() -> Double? {
        guard let now = Self.ticks() else { return nil }
        defer { prev = now }
        guard let p = prev, now.total > p.total else { return nil }
        return Double(now.busy - p.busy) / Double(now.total - p.total) * 100
    }
}

struct MemoryReading {
    var usedGB: Double
    var totalGB: Double
    var pressure: Int   // 1 正常 / 2 警告 / 4 紧张
    var freePercent: Int // 系统判断的可用余量(同 memory_pressure 命令的 free percentage)
    var swapGB: Double

    /// Mac 会尽量把内存用满，已用量高不代表不够用;压力 = 100 − 可用余量，才是"离出问题还有多远"
    var pressurePercent: Double { Double(100 - freePercent) }

    static func read() -> MemoryReading? {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        // 与活动监视器的"已使用内存"口径一致:App 内存 + 联动 + 压缩
        let page = Double(vm_kernel_page_size)
        let app = Double(vm.internal_page_count) - Double(vm.purgeable_count)
        let used = (app + Double(vm.wire_count) + Double(vm.compressor_page_count)) * page
        let gb = 1024.0 * 1024 * 1024

        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        var free: Int32 = 100
        size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_level", &free, &size, nil, 0)
        var swap = xsw_usage()
        size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)

        return MemoryReading(usedGB: used / gb,
                             totalGB: Double(ProcessInfo.processInfo.physicalMemory) / gb,
                             pressure: Int(level),
                             freePercent: Int(free),
                             swapGB: Double(swap.xsu_used) / gb)
    }
}

/// Apple 芯片温度:走 IOKit 的非公开 HID 传感器接口,取不到时返回 nil
final class TempReader {
    private typealias CreateFn = @convention(c) (UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    private typealias SetMatchingFn = @convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer) -> Int32
    private typealias CopyServicesFn = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
    private typealias CopyPropertyFn = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> UnsafeMutableRawPointer?
    private typealias CopyEventFn = @convention(c) (UnsafeRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias GetFloatFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double

    private var copyEvent: CopyEventFn?
    private var getFloat: GetFloatFn?
    private var services: CFArray?
    private var cpuIndexes: [Int] = []

    private static let temperatureType: Int64 = 15
    private static var temperatureField: Int32 { Int32(temperatureType << 16) }

    init() {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let create = dlsym(h, "IOHIDEventSystemClientCreate"),
              let setMatching = dlsym(h, "IOHIDEventSystemClientSetMatching"),
              let copyServices = dlsym(h, "IOHIDEventSystemClientCopyServices"),
              let copyProperty = dlsym(h, "IOHIDServiceClientCopyProperty"),
              let copyEvent = dlsym(h, "IOHIDServiceClientCopyEvent"),
              let getFloat = dlsym(h, "IOHIDEventGetFloatValue")
        else { return }

        self.copyEvent = unsafeBitCast(copyEvent, to: CopyEventFn.self)
        self.getFloat = unsafeBitCast(getFloat, to: GetFloatFn.self)

        guard let client = unsafeBitCast(create, to: CreateFn.self)(nil) else { return }
        // 0xff00 / 5 = Apple 厂商定义的温度传感器
        let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
        _ = unsafeBitCast(setMatching, to: SetMatchingFn.self)(client, Unmanaged.passUnretained(matching).toOpaque())
        guard let arr = unsafeBitCast(copyServices, to: CopyServicesFn.self)(client) else { return }
        let services = Unmanaged<CFArray>.fromOpaque(arr).takeRetainedValue()
        self.services = services

        // 优先用 CPU 晶粒传感器(名字含 tdie),没有则退回全部传感器
        let getProp = unsafeBitCast(copyProperty, to: CopyPropertyFn.self)
        let key = Unmanaged.passUnretained("Product" as CFString).toOpaque()
        for i in 0..<CFArrayGetCount(services) {
            guard let svc = CFArrayGetValueAtIndex(services, i),
                  let raw = getProp(svc, key) else { continue }
            let name = Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue() as? String ?? ""
            if name.lowercased().contains("tdie") { cpuIndexes.append(i) }
        }
        if cpuIndexes.isEmpty { cpuIndexes = Array(0..<CFArrayGetCount(services)) }
    }

    /// CPU 传感器的平均温度(°C)
    func read() -> Double? {
        guard let services, let copyEvent, let getFloat else { return nil }
        var values: [Double] = []
        for i in cpuIndexes {
            guard let svc = CFArrayGetValueAtIndex(services, i),
                  let ev = copyEvent(svc, Self.temperatureType, 0, 0) else { continue }
            let v = getFloat(ev, Self.temperatureField)
            Unmanaged<AnyObject>.fromOpaque(ev).release()
            if v > 10, v < 130 { values.append(v) }
        }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

struct ProcInfo: Identifiable {
    var id: pid_t
    var name: String
    var cpu: Double      // 占单核的百分比，口径同活动监视器(可超过 100)
    var memBytes: UInt64 // 自己的进程取 phys_footprint(同活动监视器"内存"列);系统进程只能拿到 RSS
    var owner: pid_t     // 所属 App(责任进程);Helper、WebContent 等归到启动它的 App,系统服务就是自己
    var ownerName: String
    var appPath: String? // 所属 .app 的路径，用来取图标;系统服务为 nil
}

/// 一个 App 名下所有进程的合计
struct AppUsage: Identifiable {
    var id: pid_t
    var name: String
    var appPath: String?
    var cpu: Double = 0
    var memBytes: UInt64 = 0 // 各进程相加，共享内存会重复计算，略偏大

    static func group(_ procs: [ProcInfo]) -> [AppUsage] {
        var d: [pid_t: AppUsage] = [:]
        for p in procs {
            d[p.owner, default: AppUsage(id: p.owner, name: p.ownerName, appPath: p.appPath)].cpu += p.cpu
            d[p.owner]!.memBytes += p.memBytes
        }
        return Array(d.values)
    }
}

/// 进程采样。进程列表和系统进程的数据来自 /bin/ps(setuid root,普通 App 自己读不到其他用户的进程);
/// 能用 proc_pid_rusage 读到的(当前用户的进程)改用它，CPU 时间更精确、内存口径同活动监视器
struct ProcessSampler {
    /// CPU 统计窗口：和最近一份至少这么久之前的快照比，同活动监视器默认的 5 秒
    var window: UInt64 = 5_000_000_000
    private var history: [(time: UInt64, cpu: [pid_t: UInt64])] = []
    private var names: [pid_t: String] = [:]
    private var owners: [pid_t: (pid: pid_t, name: String, app: String?)] = [:]
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return (UInt64(tb.numer), UInt64(tb.denom))
    }()

    /// 首次调用只建立基线，返回的 cpu 全为 0
    mutating func sample() -> [ProcInfo] {
        let rows = Self.runPS()
        let now = mach_absolute_time() * Self.timebase.numer / Self.timebase.denom
        var cur: [pid_t: UInt64] = [:]
        var mems: [pid_t: UInt64] = [:]
        var comms: [pid_t: String] = [:]
        for row in rows {
            var t = row.cpuNs, mem = row.rss
            var ri = rusage_info_v2()
            let r = withUnsafeMutablePointer(to: &ri) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(row.pid, RUSAGE_INFO_V2, $0) }
            }
            if r == 0 {
                t = (ri.ri_user_time + ri.ri_system_time) * Self.timebase.numer / Self.timebase.denom
                mem = ri.ri_phys_footprint
            }
            cur[row.pid] = t
            mems[row.pid] = mem
            comms[row.pid] = row.comm
        }
        let base = history.last { now - $0.time >= window } ?? history.first
        history.append((now, cur))
        if let i = history.lastIndex(where: { now - $0.time >= window }) { history.removeFirst(i) }
        names = names.filter { cur[$0.key] != nil }
        owners = owners.filter { cur[$0.key] != nil }

        let elapsed = base.map { now - $0.time } ?? 0
        return cur.map { pid, t in
            let cpu = elapsed > 0 ? base?.cpu[pid].map { Double(t &- $0) / Double(elapsed) * 100 } ?? 0 : 0
            let o = owner(pid, comms: comms)
            return ProcInfo(id: pid, name: name(pid, comm: comms[pid] ?? ""), cpu: max(cpu, 0), memBytes: mems[pid] ?? 0,
                            owner: o.pid, ownerName: o.name, appPath: o.app)
        }
    }

    /// 非公开但稳定的 libsystem 接口，活动监视器类工具都用它把 XPC/Helper 进程归到所属 App
    private static let responsibleFor: (@convention(c) (pid_t) -> pid_t)? = {
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    private mutating func owner(_ pid: pid_t, comms: [pid_t: String]) -> (pid: pid_t, name: String, app: String?) {
        if let o = owners[pid] { return o }
        var r = Self.responsibleFor?(pid) ?? pid
        if r <= 0 { r = pid }
        var path = comms[r] ?? ""
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(r, &buf, UInt32(buf.count)) > 0 { path = String(cString: buf) }
        // 取路径里最外层的 .app,Helper 嵌在主 App 包里时也能找到主 App
        let app = path.range(of: ".app/").map { String(path[..<$0.lowerBound]) + ".app" }
        var n = NSRunningApplication(processIdentifier: r)?.localizedName ?? ""
        if n.isEmpty, let app { n = FileManager.default.displayName(atPath: app).replacingOccurrences(of: ".app", with: "") }
        if n.isEmpty { n = name(r, comm: path) }
        let o = (r, n, app)
        owners[pid] = o
        return o
    }

    private mutating func name(_ pid: pid_t, comm: String) -> String {
        if let n = names[pid] { return n }
        var n = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
        if n.isEmpty { n = (comm as NSString).lastPathComponent }
        if n.isEmpty { n = "pid \(pid)" }
        names[pid] = n
        return n
    }

    /// ps 输出：pid、累计 CPU 时间([d-][h:]m:s.cs)、RSS(KB)、可执行路径。排除 ps 自己
    private static func runPS() -> [(pid: pid_t, cpuNs: UInt64, rss: UInt64, comm: String)] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,time=,rss=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let self_ = p.processIdentifier
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard f.count == 4, let pid = pid_t(f[0]), pid != self_, let rss = UInt64(f[2]) else { return nil }
            return (pid, parseTime(f[1]), rss * 1024, f[3].trimmingCharacters(in: .whitespaces))
        }
    }

    private static func parseTime(_ s: Substring) -> UInt64 {
        var days = 0.0, rest = s
        if let dash = s.firstIndex(of: "-") { days = Double(s[..<dash]) ?? 0; rest = s[s.index(after: dash)...] }
        var secs = days * 86400, mul = 1.0
        for part in rest.split(separator: ":").reversed() { secs += (Double(part) ?? 0) * mul; mul *= 60 }
        return UInt64(secs * 1e9)
    }
}

/// 让采样器能被后台队列持有和修改(只在 Monitor.procQueue 上访问)
final class SamplerBox: @unchecked Sendable {
    var sampler = ProcessSampler()
}

// MARK: - 预警

/// 系统通知预警。做法参照 Stats(exelban/stats):连续 N 次超阈值才发，回落后才会再次提醒
@MainActor
final class Alerts: NSObject, UNUserNotificationCenterDelegate {
    private var streak: [String: Int] = [:]
    private var fired: Set<String> = []

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// over 为真累计一次，满 times 次发一条;over 为假则清零并允许下次再提醒
    func check(_ id: String, over: Bool, times: Int, title: String, body: @autoclosure () -> String) {
        guard over else { streak[id] = 0; fired.remove(id); return }
        let n = (streak[id] ?? 0) + 1
        streak[id] = n
        guard n >= times, !fired.contains(id) else { return }
        fired.insert(id)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body()
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// 已退出进程的计数清掉
    func forget(prefixes: [String], keeping: Set<String>) {
        let stale = { (id: String) in prefixes.contains { id.hasPrefix($0) } && !keeping.contains(id) }
        streak = streak.filter { !stale($0.key) }
        fired = fired.filter { !stale($0) }
    }

    // 菜单栏应用也照常弹横幅
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - 状态

@MainActor
final class Monitor: ObservableObject {
    @Published var cpu: Double?
    @Published var temp: Double?
    @Published var mem: MemoryReading?
    @Published var labelImage = NSImage()
    @Published var topCPU: [AppUsage] = []
    @Published var topMem: [AppUsage] = []

    private var cpuSampler = CPUSampler()
    private let tempReader = TempReader()
    // 进程采样要跑 ps(约 30ms),放后台串行队列;采样器只在这个队列上读写
    private let procQueue = DispatchQueue(label: "minimonitor.procs")
    private let panelProcs = SamplerBox()
    private let alertProcs = SamplerBox()
    private var panelGen = 0
    private let alerts = Alerts()
    private var timer: Timer?
    private var procTimer: Timer?
    private var interval: TimeInterval = 2
    private var panelOpen = false
    private var tick = 0
    private var labelText = ""
    // 最新读数;面板关着时不写 @Published,免得每次刷新都触发 SwiftUI 重算
    private var rawCPU: Double?
    private var rawTemp: Double?
    private var rawMem: MemoryReading?

    init() {
        _ = cpuSampler.sample()
        refresh()
        schedule(interval: 2)
        // 进程级预警每分钟扫一次;首次只建基线
        procQueue.async { [alertProcs] in _ = alertProcs.sampler.sample() }
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkProcesses() }
        }
        RunLoop.main.add(t, forMode: .common)
        procTimer = t
    }

    func refresh() {
        rawCPU = cpuSampler.sample() ?? rawCPU
        // 温度变化慢，面板关着时每 3 次(6 秒)才读一次传感器
        if panelOpen || tick % 3 == 0 { rawTemp = tempReader.read() }
        tick += 1
        rawMem = MemoryReading.read()
        checkSystem()
        if panelOpen {
            cpu = rawCPU; temp = rawTemp; mem = rawMem
            let gen = panelGen
            procQueue.async { [panelProcs] in
                let list = panelProcs.sampler.sample()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.panelOpen, gen == self.panelGen else { return }
                    self.apply(list)
                }
            }
        } else {
            // 面板打开时换标签图会让状态栏按钮丢掉"已打开"状态,再点图标偶尔关不掉,所以先冻结
            let label = MenuBarLabel(cpu: rawCPU, temp: rawTemp, mem: rawMem)
            let text = label.lines.joined(separator: "\n")
            if text != labelText { labelText = text; labelImage = render(label) }
        }
    }

    /// 菜单栏和面板都是 2 秒刷新(面板 1 秒时进程排名跳得太厉害)
    func panelOpened() { panelOpen = true; refresh() }
    func panelClosed() {
        panelOpen = false
        panelGen += 1
        topCPU = []; topMem = []
        procQueue.async { [panelProcs] in panelProcs.sampler = ProcessSampler() }
        refresh()
    }

    /// 更新面板的两张榜单;CPU 还没有基线(全为 0)时留空显示占位
    func apply(_ procs: [ProcInfo]) {
        let list = AppUsage.group(procs)
        topCPU = list.contains { $0.cpu > 0 } ? Self.rank(list, prev: topCPU, margin: 0.5) { $0.cpu } : []
        topMem = Self.rank(list, prev: topMem, margin: 20) { Double($0.memBytes) / 1048576 }
    }

    /// 取前 4 名，但带滞后：已在榜上的保持原来的位置，新值比前一名高出 15% 且超过 margin 才往上换，
    /// 免得数值相近的进程每次刷新都来回互换
    private static func rank(_ list: [AppUsage], prev: [AppUsage], margin: Double,
                             by key: (AppUsage) -> Double) -> [AppUsage] {
        func beats(_ a: AppUsage, _ b: AppUsage) -> Bool { key(a) > key(b) * 1.15 + margin }
        let byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let sorted = list.sorted { key($0) > key($1) }
        var order = prev.compactMap { byID[$0.id] }
        // 榜外的挑战者只有明显超过榜尾才能进来
        for p in sorted.prefix(8) where !order.contains(where: { $0.id == p.id }) {
            if order.count < 4 { order.append(p) } else if let last = order.last, beats(p, last) { order.append(p) }
        }
        for _ in 0..<order.count {
            for i in stride(from: order.count - 1, to: 0, by: -1) where beats(order[i], order[i - 1]) {
                order.swapAt(i, i - 1)
            }
        }
        // 掉出前 8 的旧进程(已退出或明显变低)不再占位
        let top8 = Set(sorted.prefix(8).map(\.id))
        return Array(order.filter { top8.contains($0.id) }.prefix(4))
    }

    /// 阈值参考 Stats 与 Apple 芯片的温控表现:持续高负载才算异常，瞬时尖峰不报
    private func checkSystem() {
        let perMinute = Int(60 / interval), perHalfMinute = Int(30 / interval)
        if let c = rawCPU {
            alerts.check("cpu", over: c >= 90, times: perMinute,
                         title: "CPU 持续高负载", body: String(format: "已连续 1 分钟超过 90%%,当前 %.0f%%", c))
        }
        if let t = rawTemp {
            // M2 约 100°C 起降频;无风扇机型持续 95°C 以上说明散热已到极限
            alerts.check("temp", over: t >= 95, times: perHalfMinute,
                         title: "CPU 温度过高", body: String(format: "已连续 30 秒超过 95°C,当前 %.0f°C", t))
        }
        if let m = rawMem {
            // 只看系统给的压力等级，不按已用比例报警(Mac 上用满是常态)。
            // 偏高要持续 1 分钟才报;紧张时系统已在大量换出、开始变卡，两次读数就报
            let detail = String(format: "已用 %.1f / %.0f GB,Swap %.1f GB,可用余量 %d%%",
                                m.usedGB, m.totalGB, m.swapGB, m.freePercent)
            alerts.check("mem-warn", over: m.pressure >= 2, times: perMinute,
                         title: "内存压力偏高", body: "已持续 1 分钟。" + detail)
            alerts.check("mem-crit", over: m.pressure >= 4, times: 2,
                         title: "内存压力紧张", body: "系统正在大量换出内存，可能变卡。" + detail)
        }
    }

    /// 单进程失控:两次扫描(约 2 分钟)平均 CPU ≥ 90%,或内存 ≥ 物理内存 25%
    private func checkProcesses() {
        procQueue.async { [alertProcs] in
            let list = alertProcs.sampler.sample()
            DispatchQueue.main.async { [weak self] in self?.checkProcesses(list) }
        }
    }

    private func checkProcesses(_ list: [ProcInfo]) {
        let memLimit = UInt64(Double(ProcessInfo.processInfo.physicalMemory) * 0.25)
        let gb = 1024.0 * 1024 * 1024
        for p in list {
            // 预警按单个进程判断(抓失控/泄漏的那一个),标题用所属 App 的名字
            let which = p.name == p.ownerName ? "" : "(\(p.name))"
            alerts.check("pcpu-\(p.id)", over: p.cpu >= 90, times: 2,
                         title: "\(p.ownerName) 持续占用 CPU",
                         body: String(format: "近 2 分钟平均 %.0f%%,可能卡死或失控", p.cpu) + which)
            alerts.check("pmem-\(p.id)", over: p.memBytes >= memLimit, times: 2,
                         title: "\(p.ownerName) 占用内存过多",
                         body: String(format: "已占用 %.1f GB", Double(p.memBytes) / gb) + which)
        }
        alerts.forget(prefixes: ["pcpu-", "pmem-"], keeping: Set(list.flatMap { ["pcpu-\($0.id)", "pmem-\($0.id)"] }))
    }

    private func schedule(interval: TimeInterval) {
        self.interval = interval
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 菜单栏标签不支持多行布局,先画成图片;设为模板图,自动适配深浅色菜单栏
    private func render(_ label: MenuBarLabel) -> NSImage {
        let r = ImageRenderer(content: label)
        r.scale = NSScreen.main?.backingScaleFactor ?? 2
        let img = r.nsImage ?? NSImage()
        img.isTemplate = true
        return img
    }
}

/// 右键菜单栏图标弹出菜单(开机自启 / 退出)。MenuBarExtra 不支持右键，用本地事件监听截获
@MainActor
final class StatusMenu: NSObject {
    static let shared = StatusMenu()
    private var eventMonitor: Any?

    func install() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, let win = event.window, win.className.contains("StatusBarWindow"),
                  let view = win.contentView else { return event }
            self.menu().popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4), in: view)
            return nil
        }
    }

    private func menu() -> NSMenu {
        let menu = NSMenu()
        let login = NSMenuItem(title: "开机自启", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            NSSound.beep()
        }
        // 被系统设置里关掉过时需要用户手动批准
        if svc.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - 界面

struct PanelView: View {
    @ObservedObject var m: Monitor
    @AppStorage("procSortByMem") private var byMem = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                tile(icon: "cpu", label: "CPU", value: m.cpu.map { String(format: "%.0f", $0) }, unit: "%",
                     fraction: m.cpu.map { $0 / 100 },
                     footnote: ("\(ProcessInfo.processInfo.activeProcessorCount) 核", nil))
                tile(icon: "thermometer.medium", label: "温度", value: m.temp.map { String(format: "%.0f", $0) }, unit: "°",
                     fraction: m.temp.map { $0 / 100 },
                     footnote: m.temp.map { tempStatus($0) } ?? ("—", nil))
                // 内存的进度条表示压力而非已用比例:Mac 会尽量用满内存，已用比例常年 70–90% 并不代表不够用。
                // 压力等级用进度条颜色表示(绿/橙/红)
                tile(icon: "memorychip", label: "内存",
                     value: m.mem.map { String(format: "%.1f", $0.usedGB) }, unit: "G",
                     fraction: m.mem.map { $0.pressurePercent / 100 },
                     barColor: m.mem.map { pressureColor($0.pressure) },
                     footnote: (m.mem.map { String(format: "Swap %.1fG", $0.swapGB) } ?? "—", nil))
            }
            Divider()
            FullWidthSegments(labels: ["CPU", "内存"], selection: Binding(get: { byMem ? 1 : 0 }, set: { byMem = $0 == 1 }))
            VStack(alignment: .leading, spacing: 7) {
                ForEach(byMem ? m.topMem : m.topCPU) { p in
                    HStack(spacing: 8) {
                        AppIcon(path: p.appPath)
                        Text(p.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(byMem ? memText(p.memBytes) : String(format: "%.0f%%", p.cpu))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                // 进程 CPU 要两次采样才算得出，刚打开的头 2 秒先占位
                ForEach(0..<max(0, 4 - (byMem ? m.topMem : m.topCPU).count), id: \.self) { _ in Text("—").foregroundStyle(.secondary) }
            }
            .font(.system(size: 13))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(width: 300)
        .onAppear { m.panelOpened() }
        .onDisappear { m.panelClosed() }
    }

    /// 一格读数：大号数字 + 图标标签 + 细进度条
    /// 三格统一规格：数字、标签、进度条、脚注各一行，保证横向对齐
    private func tile(icon: String, label: String, value: String?, unit: String, fraction: Double?,
                      barColor: Color? = nil, footnote: (text: String, color: Color?)) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                // 24pt 保证 "11.7G" 也放得下，不触发缩放
                Text(value ?? "—").font(.system(size: 24, weight: .medium, design: .rounded))
                if value != nil { Text(unit).font(.system(size: 13, weight: .medium, design: .rounded)) }
            }
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(label).lineLimit(1)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(barColor.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
                        .frame(width: g.size.width * min(max(fraction ?? 0, 0), 1))
                }
            }
            .frame(height: 3)
            Text(footnote.text)
                .font(.system(size: 11))
                .foregroundStyle(footnote.color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tertiary))
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func memText(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1024 / 1024
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }

    private func pressureColor(_ level: Int) -> Color {
        switch level {
        case 4: return .red
        case 2: return .orange
        default: return .green
        }
    }

    /// M2 约 100°C 起降频，和预警的 95°C 对齐
    private func tempStatus(_ t: Double) -> (text: String, color: Color?) {
        if t >= 95 { return ("过热", .red) }
        if t >= 80 { return ("偏高", .orange) }
        return ("正常", nil)
    }
}

/// 撑满整行的系统分段控件(SwiftUI 的 segmented Picker 在 macOS 上只按内容宽度显示)
struct FullWidthSegments: NSViewRepresentable {
    var labels: [String]
    @Binding var selection: Int

    func makeNSView(context: Context) -> NSSegmentedControl {
        let c = NSSegmentedControl(labels: labels, trackingMode: .selectOne,
                                   target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        c.segmentDistribution = .fillEqually
        c.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return c
    }

    func updateNSView(_ c: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        c.selectedSegment = selection
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject {
        var parent: FullWidthSegments
        init(parent: FullWidthSegments) { self.parent = parent }
        @objc func changed(_ c: NSSegmentedControl) { parent.selection = c.selectedSegment }
    }
}

/// 进程列表里的 App 图标;系统服务没有 .app,用齿轮代替
struct AppIcon: View {
    var path: String?
    @MainActor private static var cache: [String: NSImage] = [:]

    var body: some View {
        if let path {
            Image(nsImage: Self.icon(path)).resizable().frame(width: 16, height: 16)
        } else {
            Image(systemName: "gearshape").font(.system(size: 12)).foregroundStyle(.tertiary).frame(width: 16, height: 16)
        }
    }

    @MainActor private static func icon(_ path: String) -> NSImage {
        if let i = cache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        cache[path] = i
        return i
    }
}

/// 菜单栏里的两行小字
struct MenuBarLabel: View {
    var cpu: Double?
    var temp: Double?
    var mem: MemoryReading?

    var lines: [String] {
        ["CPU \(cpu.map { String(format: "%.0f%%", $0) } ?? "—")  \(temp.map { String(format: "%.0f°", $0) } ?? "—")",
         "MEM \(mem.map { String(format: "%.1fG", $0.usedGB) } ?? "—")"]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: -1) {
            ForEach(lines, id: \.self) { Text($0) }
        }
        .font(.system(size: 9, weight: .medium).monospacedDigit())
        .foregroundStyle(.black)
        // 72pt 放得下 "CPU 100%  52°"
        .frame(width: 72, height: 22, alignment: .leading)
    }
}

struct MiniMonitorApp: App {
    @StateObject private var monitor = Monitor()

    init() { StatusMenu.shared.install() }

    var body: some Scene {
        MenuBarExtra {
            PanelView(m: monitor)
        } label: {
            Image(nsImage: monitor.labelImage)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - 入口(--dump 在终端打印一次读数,用于自检)

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--dump") {
            var cpu = CPUSampler()
            var procs = ProcessSampler()
            _ = cpu.sample()
            _ = procs.sample()
            usleep(1_000_000)
            let top = AppUsage.group(procs.sample()).sorted { $0.cpu > $1.cpu }.prefix(6)
            let mem = MemoryReading.read()
            print(String(format: "CPU   %.1f%%", cpu.sample() ?? -1))
            print("温度  " + (TempReader().read().map { String(format: "%.1f°C", $0) } ?? "取不到"))
            if let mem {
                print(String(format: "内存  %.2f / %.0f GB  压力等级 %d  可用余量 %d%%  Swap %.2f GB",
                             mem.usedGB, mem.totalGB, mem.pressure, mem.freePercent, mem.swapGB))
            }
            for p in top { print(String(format: "  %-28@ %5.1f%%  %6.0f MB", p.name as NSString, p.cpu, Double(p.memBytes) / 1048576)) }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--label"), i + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated {
                let r = ImageRenderer(content: MenuBarLabel(cpu: 100, temp: 52, mem: MemoryReading.read())
                    .background(Color.white))
                r.scale = 4
                if let cg = r.cgImage {
                    let rep = NSBitmapImageRep(cgImage: cg)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
                }
            }
            return
        }
        // --panel out.png:把面板渲染成 PNG 检查排版(分段控件在离屏渲染里画不出来)
        if let i = CommandLine.arguments.firstIndex(of: "--panel"), i + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated {
                let m = Monitor()
                var ps = ProcessSampler()
                _ = ps.sample()
                usleep(1_000_000)
                m.apply(ps.sample())
                m.cpu = 23; m.temp = 52; m.mem = MemoryReading.read()
                let r = ImageRenderer(content: PanelView(m: m).background(Color.white).environment(\.colorScheme, .light))
                r.scale = 2
                if let cg = r.cgImage {
                    try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
                }
            }
            return
        }
        MiniMonitorApp.main()
    }
}
