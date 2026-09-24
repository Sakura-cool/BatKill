//  FanCurvePanel.swift
//  BatKill
//
//  Temperature-curve editor for the fan control "调速" (curve) sub-mode,
//  shown as a chart (验收反馈 v2):
//    - X axis: temperature 0 ... user threshold, one grid line per 10 °C
//    - Y axis: fan speed minSpeed ... maxSpeed, one grid line per 100 RPM
//    - Tapping a temperature node opens a small prompt to set that step's
//      speed; confirming applies monotonic smoothing before persisting.

import SwiftUI

/// SwiftUI view rendering a fan's temperature-speed curve as a chart.
struct FanCurvePanel: View {
    let fan: FanInfo
    let curveStore: FanCurveStore
    let lm: LocalizationManager

    /// Edited step index while the speed prompt is open.
    @State private var editingStep: Int?
    /// Speed prompt text field buffer.
    @State private var speedText: String = ""

    var body: some View {
        let curve = currentCurve

        return VStack(alignment: .leading, spacing: 4) {
            header(for: curve)
            curveChart(for: curve)
            if let step = editingStep {
                editPrompt(for: curve, step: step)
            }
        }
        .id(curve.threshold)   // re-render when threshold/step count changes
    }

    private var currentCurve: FanCurve {
        curveStore.curve(for: fan.index, minSpeed: fan.minSpeed, maxSpeed: fan.maxSpeed)
    }

    private func header(for curve: FanCurve) -> some View {
        HStack {
            Text(lm.translate("Curve up to %d °C", "调速曲线至 %d °C", Int(curve.threshold)))
                .font(.caption2)
                .foregroundColor(.secondary)
            Spacer()
            Text(lm.translate("Tap a point to adjust", "点击节点调节转速"))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Chart

    private func curveChart(for curve: FanCurve) -> some View {
        let maxStep = FanCurve.maxStepIndex(for: curve.threshold)
        let bounds = chartBounds

        return GeometryReader { geo in
            let plot = plotRect(geo: geo, bounds: bounds)
            ZStack {
                // Speed grid lines (horizontal), one per 100 RPM
                ForEach(Array(stride(from: bounds.minY, through: bounds.maxY, by: 100)), id: \.self) { speed in
                    gridLine(plot: plot, ySpeed: speed, curve: curve, horizontal: true)
                }
                // Temperature grid lines (vertical), one per 10 °C
                ForEach(0...maxStep, id: \.self) { k in
                    gridLine(plot: plot, ySpeed: 0, curve: curve, horizontal: false, step: k)
                }
                // Curve polyline
                curvePath(plot: plot, curve: curve)
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                // Current-temperature marker
                currentTempMarker(plot: plot, curve: curve)
                // Tappable nodes + axis labels
                nodes(plot: plot, curve: curve, maxStep: maxStep)
            }
        }
        .frame(height: 140)
    }

    private func gridLine(plot: PlotRect, ySpeed: Double, curve: FanCurve,
                          horizontal: Bool, step: Int = 0) -> some View {
        let x0 = plot.x0
        let y0 = plot.y0
        let x1 = plot.x1
        let y1 = plot.y1
        return Path { p in
            if horizontal {
                let y = yFor(speed: ySpeed, plot: plot, curve: curve)
                p.move(to: CGPoint(x: x0, y: y))
                p.addLine(to: CGPoint(x: x1, y: y))
            } else {
                let t = FanCurve.temperature(atStep: step, threshold: curve.threshold)
                let x = xFor(temp: t, plot: plot, curve: curve)
                p.move(to: CGPoint(x: x, y: y0))
                p.addLine(to: CGPoint(x: x, y: y1))
            }
        }
        .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
    }

    private func curvePath(plot: PlotRect, curve: FanCurve) -> Path {
        var path = Path()
        let maxStep = FanCurve.maxStepIndex(for: curve.threshold)
        for k in 0...maxStep {
            let t = FanCurve.temperature(atStep: k, threshold: curve.threshold)
            let speed = curve.stepSpeeds[k] ?? 0
            let point = CGPoint(x: xFor(temp: t, plot: plot, curve: curve),
                                y: yFor(speed: speed, plot: plot, curve: curve))
            if k == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    private func nodes(plot: PlotRect, curve: FanCurve, maxStep: Int) -> some View {
        ForEach(0...maxStep, id: \.self) { k in
            let t = FanCurve.temperature(atStep: k, threshold: curve.threshold)
            let speed = curve.stepSpeeds[k] ?? 0
            let x = xFor(temp: t, plot: plot, curve: curve)
            let y = yFor(speed: speed, plot: plot, curve: curve)

            // Tappable curve node
            Circle()
                .fill(editingStep == k ? Color.orange : Color.blue)
                .frame(width: 10, height: 10)
                .position(x: x, y: y)
                .onTapGesture { beginEdit(step: k) }

            // Speed label beside the node
            Text("\(Int(speed))")
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(.secondary)
                .position(x: x, y: y - 10)
        }
    }

    private func currentTempMarker(plot: PlotRect, curve: FanCurve) -> some View {
        let current = hardwareTemp()
        let x = xFor(temp: current, plot: plot, curve: curve)
        return Rectangle()
            .fill(Color.red.opacity(0.5))
            .frame(width: 1.5, height: plot.y1 - plot.y0)
            .position(x: x, y: (plot.y0 + plot.y1) / 2)
    }

    private func hardwareTemp() -> Double {
        curveStore.lastReadCPUTemp  // populated by the refresh driver
    }

    // MARK: - Prompt

    private func editPrompt(for curve: FanCurve, step: Int) -> some View {
        let temp = FanCurve.temperature(atStep: step, threshold: curve.threshold)
        return HStack(spacing: 6) {
            Text(lm.translate("%d °C speed", "%d °C 转速", Int(temp)))
                .font(.caption2)
                .foregroundColor(.secondary)
            TextField("", text: $speedText)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 60)
            Button(lm.translate("Set", "设定")) { confirmEdit(step: step, curve: curve) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button(lm.translate("Cancel", "取消")) { editingStep = nil }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private func beginEdit(step: Int) {
        editingStep = step
        speedText = String(format: "%d", Int(currentCurve.stepSpeeds[step] ?? fan.minSpeed))
    }

    private func confirmEdit(step: Int, curve: FanCurve) {
        guard let value = Double(speedText), value.isFinite else {
            editingStep = nil
            return
        }
        var updated = curve
        updated.stepSpeeds[step] = min(max(value, fan.minSpeed), fan.maxSpeed)
        // Monotonic smoothing prevents "high-temp low-speed" mistakes.
        curveStore.setCurve(updated.smoothed(), for: fan.index)
        editingStep = nil
    }

    // MARK: - Geometry

    private struct PlotRect {
        let x0: CGFloat, x1: CGFloat, y0: CGFloat, y1: CGFloat
    }

    private var chartBounds: (minY: Double, maxY: Double) {
        (fan.minSpeed, max(fan.maxSpeed, fan.minSpeed + 100))
    }

    private func plotRect(geo: GeometryProxy, bounds: (minY: Double, maxY: Double)) -> PlotRect {
        PlotRect(x0: 30, x1: geo.size.width - 8, y0: 8, y1: geo.size.height - 18)
    }

    private func xFor(temp: Double, plot: PlotRect, curve: FanCurve) -> CGFloat {
        let range = max(curve.threshold, 1)
        let ratio = CGFloat(min(max(temp, 0), curve.threshold) / range)
        return plot.x0 + ratio * (plot.x1 - plot.x0)
    }

    private func yFor(speed: Double, plot: PlotRect, curve: FanCurve) -> CGFloat {
        let bounds = chartBounds
        let range = bounds.maxY - bounds.minY
        let ratio = CGFloat(min(max(speed, bounds.minY), bounds.maxY) - bounds.minY) / CGFloat(range)
        return plot.y1 - ratio * (plot.y1 - plot.y0)
    }
}
