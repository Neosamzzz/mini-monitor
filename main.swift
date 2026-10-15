import SwiftUI
import Darwin

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

        return MemoryReading(usedGB: used / gb,
                             totalGB: Double(ProcessInfo.processInfo.physicalMemory) / gb,
                             pressure: Int(level))
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

// MARK: - 状态

@MainActor
final class Monitor: ObservableObject {
    @Published var cpu: Double?
    @Published var temp: Double?
    @Published var mem: MemoryReading?
    @Published var labelImage = NSImage()

    private var cpuSampler = CPUSampler()
    private let tempReader = TempReader()
    private var timer: Timer?

    init() {
        _ = cpuSampler.sample()
        refresh()
        schedule(interval: 2)
    }

    func refresh() {
        cpu = cpuSampler.sample() ?? cpu
        temp = tempReader.read()
        mem = MemoryReading.read()
        labelImage = renderLabel()
    }

    /// 菜单栏常显:平时 2 秒刷新一次,面板打开时 1 秒
    func panelOpened() { refresh(); schedule(interval: 1) }
    func panelClosed() { schedule(interval: 2) }

    private func schedule(interval: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 菜单栏标签不支持多行布局,先画成图片;设为模板图,自动适配深浅色菜单栏
    private func renderLabel() -> NSImage {
        let r = ImageRenderer(content: MenuBarLabel(cpu: cpu, temp: temp, mem: mem))
        r.scale = NSScreen.main?.backingScaleFactor ?? 2
        let img = r.nsImage ?? NSImage()
        img.isTemplate = true
        return img
    }
}

// MARK: - 界面

struct PanelView: View {
    @ObservedObject var m: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("CPU", m.cpu.map { String(format: "%.0f%%", $0) })
            row("温度", m.temp.map { String(format: "%.0f°C", $0) })
            row("内存", m.mem.map { String(format: "%.1f / %.0f GB", $0.usedGB, $0.totalGB) },
                dot: m.mem.map { pressureColor($0.pressure) })
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 210)
        .onAppear { m.panelOpened() }
        .onDisappear { m.panelClosed() }
    }

    private func row(_ label: String, _ value: String?, dot: Color? = nil) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
            Text(value ?? "—").monospacedDigit()
        }
        .font(.system(size: 13))
    }

    private func pressureColor(_ level: Int) -> Color {
        switch level {
        case 4: return .red
        case 2: return .orange
        default: return .green
        }
    }
}

/// 菜单栏里的两行小字
struct MenuBarLabel: View {
    var cpu: Double?
    var temp: Double?
    var mem: MemoryReading?

    var body: some View {
        VStack(alignment: .leading, spacing: -1) {
            Text("CPU \(cpu.map { String(format: "%.0f%%", $0) } ?? "—")  \(temp.map { String(format: "%.0f°", $0) } ?? "—")")
            Text("MEM \(mem.map { String(format: "%.1fG", $0.usedGB) } ?? "—")")
        }
        .font(.system(size: 9, weight: .medium).monospacedDigit())
        .foregroundStyle(.black)
        .frame(width: 66, height: 22, alignment: .leading)
    }
}

struct MiniMonitorApp: App {
    @StateObject private var monitor = Monitor()

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
            _ = cpu.sample()
            usleep(1_000_000)
            let mem = MemoryReading.read()
            print(String(format: "CPU   %.1f%%", cpu.sample() ?? -1))
            print("温度  " + (TempReader().read().map { String(format: "%.1f°C", $0) } ?? "取不到"))
            if let mem {
                print(String(format: "内存  %.2f / %.0f GB  压力等级 %d", mem.usedGB, mem.totalGB, mem.pressure))
            }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--label"), i + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated {
                let r = ImageRenderer(content: MenuBarLabel(cpu: 23, temp: 52, mem: MemoryReading.read())
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
        MiniMonitorApp.main()
    }
}
