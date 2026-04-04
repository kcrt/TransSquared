import SwiftUI

/// Popover content showing a real-time audio level chart with dB axis,
/// a silence-threshold line, and microphone input volume control.
struct AudioLevelPopoverView: View {
    var audioLevels: [Float]
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
        HStack(spacing: 0) {
            dbAxis
                .frame(width: 44)

            ZStack(alignment: .leading) {
                // Background grid lines
                Canvas { context, size in
                    for tick in Self.dbTicks {
                        let y = size.height * (1.0 - tick.normalized)
                        var path = Path()
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                        context.stroke(
                            path,
                            with: .color(.secondary.opacity(0.15)),
                            lineWidth: 0.5
                        )
                    }
                }

                // Level bars
                Canvas { context, size in
                    let barCount = audioLevels.count
                    guard barCount > 0 else { return }
                    let barSpacing: CGFloat = 2
                    let totalSpacing = CGFloat(barCount - 1) * barSpacing
                    let barWidth = max(1, (size.width - totalSpacing) / CGFloat(barCount))

                    for (index, level) in audioLevels.enumerated() {
                        let x = CGFloat(index) * (barWidth + barSpacing)
                        let barHeight = max(1, CGFloat(level) * size.height)
                        let y = size.height - barHeight
                        let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: 1),
                            with: .color(AudioWaveformView.levelColor(level, isActive: isActive))
                        )
                    }
                }
                .opacity(isActive ? 1.0 : 0.3)
                .animation(.easeOut(duration: 0.08), value: audioLevels)

                // Silence threshold dashed line
                Canvas { context, size in
                    let thresholdY = size.height * (1.0 - CGFloat(silenceThreshold))
                    var linePath = Path()
                    linePath.move(to: CGPoint(x: 0, y: thresholdY))
                    linePath.addLine(to: CGPoint(x: size.width, y: thresholdY))
                    context.stroke(
                        linePath,
                        with: .color(.orange.opacity(0.8)),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )

                    // Label
                    let label = Text("Silence Threshold")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                    context.draw(
                        context.resolve(label),
                        at: CGPoint(x: size.width - 2, y: thresholdY - 8),
                        anchor: .trailing
                    )
                }
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 4))
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
    AudioLevelPopoverView(
        audioLevels: (0..<20).map { _ in Float.random(in: 0...0.8) },
        isActive: true,
        silenceThreshold: 0.2,
        volumeService: nil
    )
}

