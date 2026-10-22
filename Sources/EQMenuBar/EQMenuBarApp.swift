import AppKit
import AudioToolbox
import Observation
import SwiftUI

@Observable
final class EQController {
    static let bandLabels = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    var gains: [Double] = Array(repeating: 0, count: 10) {
        didSet { engine.setGains(gains, autoHeadroom: autoHeadroom) }
    }
    /// Off by default: turning the whole signal down by the biggest boost made music too quiet.
    var autoHeadroom = false {
        didSet { engine.setGains(gains, autoHeadroom: autoHeadroom) }
    }
    private(set) var isOn = false
    var errorMessage: String?

    private let engine = SystemAudioEQ()

    init() {
        // Restart on the new device when the default output changes (e.g. AirPods connect).
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
        ) { [weak self] _, _ in
            guard let self, self.isOn else { return }
            self.setOn(true)
        }
    }

    func setOn(_ on: Bool) {
        guard on else {
            engine.stop()
            isOn = false
            return
        }
        do {
            try engine.start()
            isOn = true
            errorMessage = nil
        } catch {
            isOn = false
            errorMessage = error.localizedDescription
        }
    }

    func reset() {
        gains = Array(repeating: 0, count: 10)
    }
}

struct EQView: View {
    @Bindable var eq: EQController

    var body: some View {
        VStack(spacing: 12) {
            Toggle("EQ On", isOn: Binding(get: { eq.isOn }, set: { eq.setOn($0) }))
                .toggleStyle(.switch)

            ResponseCurve(gains: $eq.gains)

            HStack {
                // When on, boosts are offset by turning everything down; quieter, but the
                // limiter rarely has to act.
                Toggle("Auto headroom", isOn: $eq.autoHeadroom)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Spacer()
                let headroom = eq.autoHeadroom ? SystemAudioEQ.headroomDB(for: eq.gains) : 0
                Text(headroom > 0.05 ? String(format: "−%.1f dB · limiter on", headroom) : "Limiter on")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .bottom, spacing: 6) {
                ForEach(0..<10, id: \.self) { band in
                    VStack(spacing: 4) {
                        Text(String(format: "%+.0f", eq.gains[band]))
                            .font(.caption2)
                            .monospacedDigit()
                        VerticalSlider(value: $eq.gains[band], range: -12...12)
                            .frame(width: 24, height: 140)
                        Text(EQController.bandLabels[band])
                            .font(.caption2)
                    }
                }
            }

            if let message = eq.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Reset") { eq.reset() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding()
    }
}

/// Native vertical NSSlider. A rotated SwiftUI Slider doesn't draw inside a MenuBarExtra window.
struct VerticalSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(
            value: value,
            minValue: range.lowerBound,
            maxValue: range.upperBound,
            target: context.coordinator,
            action: #selector(Coordinator.changed(_:))
        )
        slider.isVertical = true
        slider.isContinuous = true
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        if slider.doubleValue != value {
            slider.doubleValue = value
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    final class Coordinator: NSObject {
        var value: Binding<Double>

        init(value: Binding<Double>) {
            self.value = value
        }

        @objc func changed(_ sender: NSSlider) {
            value.wrappedValue = sender.doubleValue
        }
    }
}

/// Combined response of all ten bands, 20 Hz–20 kHz on a log axis, ±18 dB.
/// Each band has a handle on the curve; dragging it up or down sets that band's gain.
struct ResponseCurve: View {
    @Binding var gains: [Double]

    private static let displayRange = 18.0
    private static let maxGain = 12.0
    private static let sampleRate = 48_000.0
    private static let handleRadius = 5.0

    private static func x(_ frequency: Double, in size: CGSize) -> CGFloat {
        size.width * log10(frequency / 20) / 3   // 20 Hz → 20 kHz is three decades
    }

    private static func y(_ db: Double, in size: CGSize) -> CGFloat {
        let clamped = min(max(db, -displayRange), displayRange)
        return size.height * (0.5 - clamped / (2 * displayRange))
    }

    /// Inverse of `y`, clamped to the fader range and snapped to 0.5 dB.
    private static func gain(atY y: CGFloat, in size: CGSize) -> Double {
        let db = (0.5 - Double(y / size.height)) * 2 * displayRange
        return (min(max(db, -maxGain), maxGain) * 2).rounded() / 2
    }

    private static func nearestBand(toX x: CGFloat, in size: CGSize) -> Int {
        SystemAudioEQ.centers.indices.min {
            abs(Self.x(SystemAudioEQ.centers[$0], in: size) - x) < abs(Self.x(SystemAudioEQ.centers[$1], in: size) - x)
        } ?? 0
    }

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                for db in [-12.0, -6, 0, 6, 12] {
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: Self.y(db, in: size)))
                    line.addLine(to: CGPoint(x: size.width, y: Self.y(db, in: size)))
                    context.stroke(line, with: .color(.secondary.opacity(db == 0 ? 0.6 : 0.2)), lineWidth: 1)
                }

                let filters = SystemAudioEQ.filters(for: gains, sampleRate: Self.sampleRate)

                var curve = Path()
                let points = 200
                for step in 0...points {
                    let frequency = 20 * pow(1_000, Double(step) / Double(points))
                    let db = filters.reduce(0) { $0 + $1.magnitudeDB(at: frequency, sampleRate: Self.sampleRate) }
                    let point = CGPoint(x: Self.x(frequency, in: size), y: Self.y(db, in: size))
                    if step == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
                }
                context.stroke(curve, with: .color(.accentColor), lineWidth: 2)

                // Handles sit at each band's own gain, not on the summed curve, so they
                // line up with the faders below.
                for band in SystemAudioEQ.centers.indices {
                    let center = CGPoint(
                        x: Self.x(SystemAudioEQ.centers[band], in: size),
                        y: Self.y(gains[band], in: size)
                    )
                    let r = Self.handleRadius
                    let dot = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
                    context.fill(dot, with: .color(.accentColor))
                    context.stroke(dot, with: .color(.white.opacity(0.8)), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                // The band is chosen from where the drag started, so it stays fixed while dragging.
                DragGesture(minimumDistance: 0).onChanged { value in
                    let band = Self.nearestBand(toX: value.startLocation.x, in: proxy.size)
                    gains[band] = Self.gain(atY: value.location.y, in: proxy.size)
                }
            )
        }
        .frame(height: 120)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
    }
}

@main
struct EQMenuBarApp: App {
    // Plain property: @State's macro plugin isn't shipped with the Command Line Tools.
    private let eq = EQController()

    var body: some Scene {
        MenuBarExtra("EQ", systemImage: "slider.vertical.3") {
            EQView(eq: eq)
        }
        .menuBarExtraStyle(.window)
    }
}
