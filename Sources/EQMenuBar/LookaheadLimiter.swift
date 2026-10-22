import Foundation

/// Stereo-linked lookahead limiter. Audio is delayed by `lookahead` samples so the gain can
/// ease down before a peak arrives instead of jumping on it, which is what made the old
/// zero-lookahead limiter crackle on transients and track changes. All channels share one
/// gain, so the stereo image doesn't shift. Allocates only in `init`, so `process` is safe
/// on the audio thread.
final class LookaheadLimiter {
    let lookahead: Int
    private let maxChannels: Int
    private let ceiling: Double
    private let release: Double

    private let delay: UnsafeMutablePointer<Double>       // [position * maxChannels + channel]
    private var position = 0
    // Gain each frame needs, for the frame leaving the delay through the one entering it,
    // hence one slot longer than the delay.
    private let neededGain: UnsafeMutablePointer<Double>
    private var neededPosition = 0
    // The last `lookahead` window minimums, averaged so the gain ramps down over the
    // lookahead and reaches each peak's required gain exactly when that peak leaves the delay.
    private let windowMinimums: UnsafeMutablePointer<Double>
    private var minimumPosition = 0
    private(set) var gain = 1.0

    init(maxChannels: Int, sampleRate: Double, ceiling: Double = 1.0,
         lookaheadSeconds: Double = 0.002, releaseSeconds: Double = 0.1) {
        self.maxChannels = maxChannels
        self.ceiling = ceiling
        lookahead = max(1, Int(lookaheadSeconds * sampleRate))
        release = 1 - exp(-1 / (releaseSeconds * sampleRate))
        delay = .allocate(capacity: lookahead * maxChannels)
        delay.initialize(repeating: 0, count: lookahead * maxChannels)
        neededGain = .allocate(capacity: lookahead + 1)
        neededGain.initialize(repeating: 1, count: lookahead + 1)
        windowMinimums = .allocate(capacity: lookahead)
        windowMinimums.initialize(repeating: 1, count: lookahead)
    }

    deinit {
        delay.deallocate()
        neededGain.deallocate()
        windowMinimums.deallocate()
    }

    /// Replaces `frame[0..<channels]` with the limited sample from `lookahead` frames ago.
    func process(_ frame: UnsafeMutablePointer<Double>, channels: Int) {
        var peak = 0.0
        for channel in 0..<channels {
            peak = max(peak, abs(frame[channel]))
        }
        neededGain[neededPosition] = peak > ceiling ? ceiling / peak : 1
        neededPosition = (neededPosition + 1) % (lookahead + 1)

        var windowMinimum = 1.0
        for index in 0...lookahead {
            windowMinimum = min(windowMinimum, neededGain[index])
        }
        windowMinimums[minimumPosition] = windowMinimum
        minimumPosition = (minimumPosition + 1) % lookahead

        var sum = 0.0
        for index in 0..<lookahead {
            sum += windowMinimums[index]
        }
        let ramped = sum / Double(lookahead)

        // Follow the ramp straight down; come back up slowly so it doesn't pump.
        gain = ramped < gain ? ramped : gain + (ramped - gain) * release

        let slot = delay + position * maxChannels
        for channel in 0..<channels {
            let delayed = slot[channel]
            slot[channel] = frame[channel]
            // The ramp already lands each peak at the ceiling; this only guards rounding.
            frame[channel] = min(max(delayed * gain, -ceiling), ceiling)
        }
        position = (position + 1) % lookahead
    }
}
