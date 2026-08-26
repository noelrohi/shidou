// PROTOTYPE — streaming transcript spike (wayfinder #9). Throwaway.
//
// On-device evidence instruments: a CADisplayLink frame meter (fps, worst
// frame, hitch count) and a physical-footprint memory readout.

import QuartzCore
import SwiftUI

@MainActor
@Observable
final class SpikeFrameMeter {
    private(set) var fps: Double = 0
    private(set) var worstFrameMs: Double = 0
    /// Frames that took longer than 1.5× the display's frame budget.
    private(set) var hitchCount = 0
    private(set) var memoryMB: Double = 0

    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var lastTimestamp: CFTimeInterval = 0
    @ObservationIgnored private var frameCount = 0
    @ObservationIgnored private var windowStart: CFTimeInterval = 0
    @ObservationIgnored private var windowWorst: Double = 0

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        lastTimestamp = 0
    }

    func reset() {
        hitchCount = 0
        worstFrameMs = 0
        windowWorst = 0
    }

    @objc private func step(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }
        guard lastTimestamp > 0 else {
            windowStart = link.timestamp
            return
        }
        let delta = link.timestamp - lastTimestamp
        let budget = link.targetTimestamp - link.timestamp
        frameCount += 1
        windowWorst = max(windowWorst, delta * 1000)
        if budget > 0, delta > budget * 1.5 {
            hitchCount += 1
        }
        // Publish at ~2 Hz so the HUD itself doesn't churn SwiftUI.
        if link.timestamp - windowStart >= 0.5 {
            fps = Double(frameCount) / (link.timestamp - windowStart)
            worstFrameMs = max(worstFrameMs, windowWorst)
            memoryMB = Self.physFootprintMB()
            frameCount = 0
            windowWorst = 0
            windowStart = link.timestamp
        }
    }

    private static func physFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }
}

struct SpikeHUDView: View {
    let meter: SpikeFrameMeter
    let rowCount: Int

    var body: some View {
        HStack(spacing: 12) {
            metric("\(Int(meter.fps.rounded()))", "fps")
            metric(String(format: "%.0f", meter.worstFrameMs), "worst ms")
            metric("\(meter.hitchCount)", "hitches")
            metric(String(format: "%.0f", meter.memoryMB), "MB")
            metric("\(rowCount)", "rows")
            Button("Reset") { meter.reset() }
                .font(.caption2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 0) {
            Text(value).font(.caption.monospacedDigit().bold())
            Text(label).font(.system(size: 8)).foregroundStyle(.secondary)
        }
    }
}
