import Foundation

/// One peaking-EQ section (RBJ Audio EQ Cookbook), Direct Form I.
struct Biquad {
    private var b0 = 1.0, b1 = 0.0, b2 = 0.0
    private var a1 = 0.0, a2 = 0.0
    private var x1 = 0.0, x2 = 0.0
    private var y1 = 0.0, y2 = 0.0

    /// Sets the coefficients for a bell boost/cut of `gainDB` at `frequency`.
    mutating func setPeaking(frequency: Double, gainDB: Double, q: Double, sampleRate: Double) {
        let amplitude = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosW0 = cos(w0)
        let a0 = 1 + alpha / amplitude

        b0 = (1 + alpha * amplitude) / a0
        b1 = -2 * cosW0 / a0
        b2 = (1 - alpha * amplitude) / a0
        a1 = -2 * cosW0 / a0
        a2 = (1 - alpha / amplitude) / a0
    }

    /// Gain of this section at `frequency`, in dB. Used to draw the response curve.
    func magnitudeDB(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let numRe = b0 + b1 * cos(w) + b2 * cos(2 * w)
        let numIm = -(b1 * sin(w) + b2 * sin(2 * w))
        let denRe = 1 + a1 * cos(w) + a2 * cos(2 * w)
        let denIm = -(a1 * sin(w) + a2 * sin(2 * w))
        let power = (numRe * numRe + numIm * numIm) / (denRe * denRe + denIm * denIm)
        return 10 * log10(power)
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = x
        y2 = y1
        y1 = y
        return y
    }
}
