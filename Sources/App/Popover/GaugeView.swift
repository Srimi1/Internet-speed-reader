import SwiftUI

/// The 270-degree arc behind the GO button.
struct GaugeArc: Shape {
    var progress: Double

    // Animating the arc means animating this value, not the whole view.
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let start = Angle.degrees(135)
        let end = Angle.degrees(135 + 270 * max(0, min(1, progress)))

        var path = Path()
        path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        return path
    }
}

struct GaugeView: View {
    let mbps: Double
    let isRunning: Bool
    let phaseLabel: String
    let canStart: Bool
    let onStart: () -> Void
    let onStop: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Speed spans four orders of magnitude, so a linear sweep would crush everything
    /// below 100 Mbps into the first few degrees.
    private var progress: Double {
        let clamped = max(mbps, 0.1)
        return min(1, max(0, log10(clamped / 0.1) / log10(1000 / 0.1)))
    }

    var body: some View {
        ZStack {
            GaugeArc(progress: 1)
                .stroke(Color.secondary.opacity(0.15), style: StrokeStyle(lineWidth: 12, lineCap: .round))

            GaugeArc(progress: progress)
                .stroke(
                    AngularGradient(
                        colors: [.blue, .cyan, .green],
                        center: .center,
                        startAngle: .degrees(135),
                        endAngle: .degrees(405)
                    ),
                    style: StrokeStyle(lineWidth: 12, lineCap: .round)
                )
                .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: progress)

            VStack(spacing: 2) {
                if isRunning {
                    Text(SpeedFormatterBridge.panel(mbps))
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(phaseLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("Stop", action: onStop)
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .padding(.top, 2)
                } else {
                    Button(action: onStart) {
                        Text("GO")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .frame(width: 62, height: 62)
                            .background(Circle().fill(canStart ? Color.accentColor : Color.gray.opacity(0.4)))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canStart)
                    .accessibilityLabel("Start speed test")
                }
            }
        }
        .frame(width: 168, height: 168)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

/// Small shim so SwiftUI views can format speeds without importing the whole core.
enum SpeedFormatterBridge {
    static func panel(_ mbps: Double) -> String {
        SpeedCoreFormatter.panel(mbps)
    }
}
