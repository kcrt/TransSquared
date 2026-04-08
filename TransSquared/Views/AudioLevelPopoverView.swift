import SwiftUI

/// Popover content showing a real-time audio level chart with dB axis,
/// a silence-threshold line, and microphone input volume control.
struct AudioLevelPopoverView: View {
    /// Observe the monitor directly to isolate level-change updates to this view.
    var monitor: AudioLevelMonitor
    var isActive: Bool
    var silenceThreshold: Float
    var inputDeviceName: String?
    var volumeService: MicrophoneVolumeService?

    @State private var micVolume: Float = 1.0

    /// dB tick marks and their normalized Y positions.
    private static let dbTicks: [(db: Int, normalized: CGFloat)] = [
        (0,   1.0),
        (-10, 0.8),
        (-20, 0.6),
        (-30, 0.4),
        (-40, 0.2),
        (-50, 0.0),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Audio Level Monitor")
                    .font(.headline)
                if let inputDeviceName {
                    Text("— \(inputDeviceName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            audioChart
                .frame(height: 180)

            Divider()

            microphoneVolumeControl
        }
        .padding()
        .frame(width: 320)
        .onAppear {
            micVolume = volumeService?.getInputVolume() ?? 1.0
        }
    }

    // MARK: - Audio Level Chart

    private var audioChart: some View {
        let audioLevels = monitor.levels
        return HStack(spacing: 0) {
            dbAxis
                .frame(width: 44)

            Canvas { context, size in
                // Background grid lines
                for tick in Self.dbTicks {
                    let y = size.height * (1.0 - tick.normalized)
                    var gridPath = Path()
                    gridPath.move(to: CGPoint(x: 0, y: y))
                    gridPath.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(gridPath, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
                }

                // Level bars
                let barCount = audioLevels.count
                if barCount > 0 {
                    let barSpacing: CGFloat = 2
                    let totalSpacing = CGFloat(barCount - 1) * barSpacing
                    let barWidth = max(1, (size.width - totalSpacing) / CGFloat(barCount))
                    let barOpacity = isActive ? 1.0 : 0.3

                    for (index, level) in audioLevels.enumerated() {
                        let x = CGFloat(index) * (barWidth + barSpacing)
                        let barHeight = max(1, CGFloat(level) * size.height)
                        let y = size.height - barHeight
                        let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                        context.opacity = barOpacity
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: 1),
                            with: .color(AudioWaveformView.levelColor(level, isActive: isActive))
                        )
                    }
                    context.opacity = 1.0
                }

                // Silence threshold dashed line
                let thresholdY = size.height * (1.0 - CGFloat(silenceThreshold))
                var linePath = Path()
                linePath.move(to: CGPoint(x: 0, y: thresholdY))
                linePath.addLine(to: CGPoint(x: size.width, y: thresholdY))
                context.stroke(
                    linePath,
                    with: .color(.orange.opacity(0.8)),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )

                let label = Text("Silence Threshold")
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
                context.draw(
                    context.resolve(label),
                    at: CGPoint(x: size.width - 2, y: thresholdY - 8),
                    anchor: .trailing
                )
            }
            .animation(.easeOut(duration: 0.08), value: audioLevels)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .accessibilityElement()
            .accessibilityLabel(String(localized: "Audio level chart"))
        }
    }

    // MARK: - dB Axis

    private var dbAxis: some View {
        GeometryReader { geo in
            ForEach(Self.dbTicks, id: \.db) { tick in
                let y = geo.size.height * (1.0 - tick.normalized)
                Text("\(tick.db) dB")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .position(x: geo.size.width / 2, y: y)
            }
        }
    }

    // MARK: - Microphone Volume

    private var microphoneVolumeControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Input Volume")
                .font(.subheadline)

            if let volumeService, volumeService.isVolumeControlAvailable() {
                HStack {
                    Image(systemName: "speaker.wave.1.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Slider(value: $micVolume, in: 0...1, step: 0.05)
                        .accessibilityLabel(String(localized: "Input Volume"))
                        .accessibilityValue("\(Int(micVolume * 100))%")
                        .onChange(of: micVolume) { _, newValue in
                            volumeService.setInputVolume(newValue)
                        }
                    Image(systemName: "speaker.wave.3.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Text("\(Int(micVolume * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            } else {
                Text("Volume control is not available for this device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }


}
#Preview {
    let monitor = AudioLevelMonitor()
    AudioLevelPopoverView(
        monitor: monitor,
        isActive: true,
        silenceThreshold: 0.2,
        volumeService: nil
    )
}

