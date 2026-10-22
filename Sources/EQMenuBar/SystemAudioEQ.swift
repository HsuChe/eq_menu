import AudioToolbox
import CoreAudio
import Foundation
import os

enum EQError: LocalizedError {
    case coreAudio(String, OSStatus)
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case let .coreAudio(step, status):
            return "\(step) failed (\(status)). Check System Audio Recording permission in System Settings → Privacy & Security."
        case .unsupportedFormat:
            return "The system audio tap is not 32-bit float PCM; this build can't process it."
        }
    }
}

/// Captures all system output through a Core Audio process tap, runs it through
/// a 10-band peaking EQ, and plays the result on the current default output device.
///
/// Signal chain per channel: EQ → headroom (cut by the curve's highest boost) → peak limiter.
/// Gain changes glide over a few callbacks instead of jumping, so dragging doesn't crackle.
final class SystemAudioEQ {
    static let centers: [Double] = [31, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    private static let bandCount = 10
    private static let maxChannels = 8
    static let q = 1.41

    /// The tap delivers the mix before the output's volume is applied, and Bluetooth headphones
    /// such as AirPods Max take full-level audio and apply volume themselves, so normal music
    /// routinely peaks at 2–3 here without clipping. A 1.0 ceiling limited ordinary music by up
    /// to 11 dB; at 4.0 (+12 dB) the limiter only catches runaway boosts.
    private static let limiterCeiling = 4.0

    /// Fraction of the remaining distance a smoothed value moves per IO callback
    /// (~10 ms at 512 frames / 48 kHz, so about 40 ms to settle).
    private static let smoothing = 0.25
    // Shared between the main thread (setGains) and the audio thread (render).
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let sharedGains: UnsafeMutablePointer<Double>
    private var sharedHeadroom = 1.0
    private var sharedGeneration = 0

    // Audio-thread state. Only touched by `render` once `start` has finished.
    private let targetGains: UnsafeMutablePointer<Double>
    private let currentGains: UnsafeMutablePointer<Double>
    private let filters: UnsafeMutablePointer<Biquad>
    private var limiter = LookaheadLimiter(maxChannels: SystemAudioEQ.maxChannels, sampleRate: 48_000)
    private let frame: UnsafeMutablePointer<Double>                  // one frame, all channels
    private let channelSamples: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let channelStrides: UnsafeMutablePointer<Int>
    private var targetHeadroom = 1.0
    private var currentHeadroom = 1.0
    private var seenGeneration = -1
    private var sampleRate = 48_000.0

    // Diagnostic mode: EQ_DEBUG=<file path> logs one line per IO callback (clock gaps, levels).
    // Off unless the variable is set; it formats strings on the audio thread, so debugging only.
    private static let debugLog: UnsafeMutablePointer<FILE>? =
        ProcessInfo.processInfo.environment["EQ_DEBUG"].flatMap { fopen($0, "w") }
    private var lastInputSampleTime = -1.0
    private var lastOutputSampleTime = -1.0
    private var lastFrames = 0

    // Main-thread state.
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        sharedGains = .allocate(capacity: Self.bandCount)
        sharedGains.initialize(repeating: 0, count: Self.bandCount)
        targetGains = .allocate(capacity: Self.bandCount)
        targetGains.initialize(repeating: 0, count: Self.bandCount)
        currentGains = .allocate(capacity: Self.bandCount)
        currentGains.initialize(repeating: 0, count: Self.bandCount)
        filters = .allocate(capacity: Self.maxChannels * Self.bandCount)
        filters.initialize(repeating: Biquad(), count: Self.maxChannels * Self.bandCount)
        frame = .allocate(capacity: Self.maxChannels)
        frame.initialize(repeating: 0, count: Self.maxChannels)
        channelSamples = .allocate(capacity: Self.maxChannels)
        channelStrides = .allocate(capacity: Self.maxChannels)
        channelStrides.initialize(repeating: 1, count: Self.maxChannels)
    }

    deinit {
        stop()
        lock.deallocate()
        sharedGains.deallocate()
        targetGains.deallocate()
        currentGains.deallocate()
        filters.deallocate()
        frame.deallocate()
        channelSamples.deallocate()
        channelStrides.deallocate()
    }

    /// Band gains in dB, clamped by the UI to ±12. With `autoHeadroom`, the whole signal is
    /// also turned down by the curve's highest boost; without it, only the limiter guards peaks.
    func setGains(_ gains: [Double], autoHeadroom: Bool) {
        let headroom = autoHeadroom ? pow(10, -Self.headroomDB(for: gains) / 20) : 1
        os_unfair_lock_lock(lock)
        for band in 0..<Self.bandCount {
            sharedGains[band] = gains[band]
        }
        sharedHeadroom = headroom
        sharedGeneration += 1
        os_unfair_lock_unlock(lock)
    }

    // MARK: - Response math (shared with the UI)

    /// One peaking section per band at the given gains.
    static func filters(for gains: [Double], sampleRate: Double) -> [Biquad] {
        centers.indices.map { band in
            var filter = Biquad()
            filter.setPeaking(frequency: centers[band], gainDB: gains[band], q: q, sampleRate: sampleRate)
            return filter
        }
    }

    /// How much the whole signal is turned down so the curve's highest point lands at 0 dB.
    /// Overlapping boosts add up, so this is the peak of the summed curve, not the largest fader.
    static func headroomDB(for gains: [Double], sampleRate: Double = 48_000) -> Double {
        let bands = filters(for: gains, sampleRate: sampleRate)
        let probes = (0...200).map { 20 * pow(1_000, Double($0) / 200) } + centers
        let peak = probes.map { frequency in
            bands.reduce(0) { $0 + $1.magnitudeDB(at: frequency, sampleRate: sampleRate) }
        }.max() ?? 0
        return max(0, peak)
    }

    func start() throws {
        stop()
        do {
            let outputID = try Self.defaultOutputDevice()
            let outputUID = try Self.uid(of: outputID)

            // Exclude ourselves: otherwise the tap captures (and mutes) our own processed
            // output, which feeds back into the input and silences what you hear.
            let ownProcess = try Self.processObject(for: getpid())
            let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcess])
            tapDescription.uuid = UUID()
            tapDescription.isPrivate = true
            tapDescription.muteBehavior = .mutedWhenTapped

            var tap = AudioObjectID(kAudioObjectUnknown)
            try Self.check(AudioHardwareCreateProcessTap(tapDescription, &tap), "Creating the system audio tap")
            tapID = tap

            let format = try Self.tapFormat(tap)
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32
            else { throw EQError.unsupportedFormat }
            sampleRate = format.mSampleRate

            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "EQMenuBar",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: outputUID]
                ],
                kAudioAggregateDeviceTapListKey: [
                    [
                        // Needed: with it off, the tap and the output drifted apart and the
                        // input broke into ~150 ms dropouts every 0.16 s.
                        kAudioSubTapDriftCompensationKey: true,
                        kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                    ]
                ],
            ]
            var aggregate = AudioObjectID(kAudioObjectUnknown)
            try Self.check(
                AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate),
                "Creating the aggregate device"
            )
            aggregateID = aggregate

            // Reset filter and limiter state; the first callback picks up the current
            // settings and glides in from flat.
            filters.update(repeating: Biquad(), count: Self.maxChannels * Self.bandCount)
            currentGains.update(repeating: 0, count: Self.bandCount)
            limiter = LookaheadLimiter(maxChannels: Self.maxChannels, sampleRate: sampleRate, ceiling: Self.limiterCeiling)
            currentHeadroom = 1
            seenGeneration = -1

            try Self.check(
                AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, nil) { [self] now, input, inputTime, output, outputTime in
                    self.render(input: input, output: output)
                    if let log = Self.debugLog {
                        self.logCallback(log, now: now, input: input, inputTime: inputTime, output: output, outputTime: outputTime)
                    }
                },
                "Creating the audio IO proc"
            )
            try Self.check(AudioDeviceStart(aggregate, procID), "Starting the audio device")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Audio thread

    private func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outBuffers = UnsafeMutableAudioBufferListPointer(output)

        // Start from silence so any output buffer without a matching input never plays stale data.
        for buffer in outBuffers {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        for index in 0..<min(inBuffers.count, outBuffers.count) {
            let bytes = min(inBuffers[index].mDataByteSize, outBuffers[index].mDataByteSize)
            if let src = inBuffers[index].mData, let dst = outBuffers[index].mData {
                memcpy(dst, src, Int(bytes))
            }
        }

        let headroomAtStart = currentHeadroom
        advanceSmoothing()
        let headroomAtEnd = currentHeadroom

        // Map every channel to its samples, whether buffers are interleaved or one per channel.
        var channels = 0
        var frames = Int.max
        for buffer in outBuffers {
            let count = Int(buffer.mNumberChannels)
            guard count > 0, let raw = buffer.mData else { continue }
            let samples = raw.assumingMemoryBound(to: Float.self)
            frames = min(frames, Int(buffer.mDataByteSize) / (count * MemoryLayout<Float>.size))
            for offset in 0..<count where channels < Self.maxChannels {
                channelSamples[channels] = samples + offset
                channelStrides[channels] = count
                channels += 1
            }
        }
        guard channels > 0, frames != Int.max, frames > 0 else { return }

        // Frame by frame so the limiter sees every channel at once and applies one shared gain.
        for index in 0..<frames {
            // Headroom ramps linearly across the block so a change never steps.
            let progress = Double(index + 1) / Double(frames)
            let headroom = headroomAtStart + (headroomAtEnd - headroomAtStart) * progress

            for channel in 0..<channels {
                var x = Double(channelSamples[channel][index * channelStrides[channel]])
                let bands = filters + channel * Self.bandCount
                for band in 0..<Self.bandCount {
                    x = bands[band].process(x)
                }
                frame[channel] = x * headroom
            }

            limiter.process(frame, channels: channels)

            for channel in 0..<channels {
                channelSamples[channel][index * channelStrides[channel]] = Float(frame[channel])
            }
        }
    }

    /// Diagnostic log line. Columns: host seconds, input clock step, output clock step, frames,
    /// input peak, output peak, limiter gain. A clock step that isn't the previous block's
    /// frame count means samples were skipped or repeated, which is heard as a crackle.
    private func logCallback(
        _ log: UnsafeMutablePointer<FILE>,
        now: UnsafePointer<AudioTimeStamp>,
        input: UnsafePointer<AudioBufferList>,
        inputTime: UnsafePointer<AudioTimeStamp>,
        output: UnsafeMutablePointer<AudioBufferList>,
        outputTime: UnsafePointer<AudioTimeStamp>
    ) {
        func peak(_ list: UnsafeMutableAudioBufferListPointer) -> (Float, Int) {
            var peak: Float = 0
            var frames = 0
            for buffer in list {
                guard let raw = buffer.mData, buffer.mNumberChannels > 0 else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                frames = count / Int(buffer.mNumberChannels)
                let samples = raw.assumingMemoryBound(to: Float.self)
                for i in 0..<count { peak = max(peak, abs(samples[i])) }
            }
            return (peak, frames)
        }
        let (inPeak, frames) = peak(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)))
        let (outPeak, _) = peak(UnsafeMutableAudioBufferListPointer(output))

        let inStep = lastInputSampleTime < 0 ? 0 : inputTime.pointee.mSampleTime - lastInputSampleTime
        let outStep = lastOutputSampleTime < 0 ? 0 : outputTime.pointee.mSampleTime - lastOutputSampleTime
        lastInputSampleTime = inputTime.pointee.mSampleTime
        lastOutputSampleTime = outputTime.pointee.mSampleTime
        let seconds = Double(now.pointee.mHostTime) * hostTicksToSeconds

        fputs(String(format: "%.4f %.0f %.0f %d %d %.4f %.4f %.4f\n",
                     seconds, inStep, outStep, lastFrames, frames, inPeak, outPeak, limiter.gain), log)
        lastFrames = frames
        fflush(log)
    }

    private let hostTicksToSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    /// Picks up new settings from the main thread and moves the current band gains and
    /// headroom one step toward them, rebuilding coefficients only while something moves.
    private func advanceSmoothing() {
        os_unfair_lock_lock(lock)
        let generation = sharedGeneration
        if generation != seenGeneration {
            targetGains.update(from: sharedGains, count: Self.bandCount)
            targetHeadroom = sharedHeadroom
        }
        os_unfair_lock_unlock(lock)

        let isFirstUpdate = seenGeneration == -1
        seenGeneration = generation

        var moved = isFirstUpdate
        for band in 0..<Self.bandCount {
            let remaining = targetGains[band] - currentGains[band]
            guard remaining != 0 else { continue }
            currentGains[band] = abs(remaining) < 0.01 ? targetGains[band] : currentGains[band] + remaining * Self.smoothing
            moved = true
        }

        let headroomRemaining = targetHeadroom - currentHeadroom
        currentHeadroom = abs(headroomRemaining) < 0.0001 ? targetHeadroom : currentHeadroom + headroomRemaining * Self.smoothing

        guard moved else { return }
        for channel in 0..<Self.maxChannels {
            for band in 0..<Self.bandCount {
                filters[channel * Self.bandCount + band].setPeaking(
                    frequency: Self.centers[band],
                    gainDB: currentGains[band],
                    q: Self.q,
                    sampleRate: sampleRate
                )
            }
        }
    }

    // MARK: - Core Audio helpers

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw EQError.coreAudio(step, status) }
    }

    private static func defaultOutputDevice() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device),
            "Reading the default output device"
        )
        return device
    }

    private static func processObject(for pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
            ),
            "Looking up this app's audio process"
        )
        return object
    }

    private static func uid(of device: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid), "Reading the output device UID")
        return (uid?.takeRetainedValue() as String?) ?? ""
    }

    private static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format), "Reading the tap format")
        return format
    }
}
