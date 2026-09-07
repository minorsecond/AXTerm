#if os(macOS)
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import Synchronization

/// The modem's audio on a Mac: two HAL output units (one capturing, one
/// playing) bound to the devices the profile names.
///
/// AVAudioEngine is deliberately not used: selecting a specific input device
/// needs the HAL unit underneath it anyway, and the engine has had start
/// failures on recent systems. The HAL units are simple and predictable, and
/// the audio thread callbacks here touch only preallocated buffers.
nonisolated final class CoreAudioModemIO: ModemAudioIO, @unchecked Sendable {

    let inputUID: String
    let outputUID: String
    let inputChannel: ModemInputChannel
    /// Preferred rate; used only if the device supports it.
    let preferredSampleRate: Double
    /// Frames per callback requested from the HAL (10 ms at 48 kHz).
    let preferredBufferFrames: UInt32

    private(set) var format: ModemAudioFormat?
    private(set) var latency = ModemAudioLatency()
    weak var sink: ModemAudioSink?

    private var inputUnit: AudioUnit?
    private var outputUnit: AudioUnit?
    private var inputDevice = AudioObjectID(kAudioObjectUnknown)
    private var outputDevice = AudioObjectID(kAudioObjectUnknown)
    private var inputChannels = 0
    private var outputChannels = 0
    private var maxFrames = 4096
    private var inputList: UnsafeMutableAudioBufferListPointer?
    private var inputStorage: [UnsafeMutablePointer<Float>] = []
    private var mono: UnsafeMutablePointer<Float>?
    private let running = Atomic<Bool>(false)
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private let listenerQueue = DispatchQueue(label: "com.axterm.modem.coreaudio")

    init(inputUID: String, outputUID: String, inputChannel: ModemInputChannel = .left,
         preferredSampleRate: Double = 48_000, preferredBufferFrames: UInt32 = 480) {
        self.inputUID = inputUID
        self.outputUID = outputUID
        self.inputChannel = inputChannel
        self.preferredSampleRate = preferredSampleRate
        self.preferredBufferFrames = preferredBufferFrames
    }

    deinit { stop() }

    // MARK: - ModemAudioIO

    func start() throws {
        guard !running.load(ordering: .acquiring) else { return }
        try Self.ensureMicrophonePermission()

        guard let inID = CoreAudioDeviceCatalog.deviceID(forUID: inputUID) else {
            throw ModemAudioError.deviceNotFound(uid: inputUID)
        }
        guard let outID = CoreAudioDeviceCatalog.deviceID(forUID: outputUID) else {
            throw ModemAudioError.deviceNotFound(uid: outputUID)
        }
        inputDevice = inID
        outputDevice = outID

        // Ask for the preferred rate where the device offers it; otherwise
        // run at whatever it runs at and let the DSP adapt.
        for id in Set([inID, outID]) where CoreAudioDeviceCatalog.supportsSampleRate(id, preferredSampleRate) {
            CoreAudioDeviceCatalog.setNominalSampleRate(id, preferredSampleRate)
        }
        guard let inRate = CoreAudioDeviceCatalog.nominalSampleRate(inID),
              let outRate = CoreAudioDeviceCatalog.nominalSampleRate(outID) else {
            throw ModemAudioError.unsupportedFormat("device reports no sample rate")
        }
        guard abs(inRate - outRate) < 1 else {
            throw ModemAudioError.unsupportedFormat("input runs at \(Int(inRate)) Hz but output at \(Int(outRate)) Hz")
        }
        inputChannels = max(1, CoreAudioDeviceCatalog.channelCount(inID, scope: kAudioObjectPropertyScopeInput))
        outputChannels = max(1, CoreAudioDeviceCatalog.channelCount(outID, scope: kAudioObjectPropertyScopeOutput))

        do {
            inputUnit = try makeUnit(device: inID, isInput: true, sampleRate: inRate, channels: inputChannels)
            outputUnit = try makeUnit(device: outID, isInput: false, sampleRate: outRate, channels: outputChannels)
            allocateInputBuffers()
            try check(AudioUnitInitialize(inputUnit!), "initialising input")
            try check(AudioUnitInitialize(outputUnit!), "initialising output")
        } catch {
            tearDownUnits()
            throw error
        }

        format = ModemAudioFormat(sampleRate: inRate, inputChannels: inputChannels, outputChannels: outputChannels)
        latency = ModemAudioLatency(
            inputSeconds: Self.latencySeconds(inID, scope: kAudioObjectPropertyScopeInput, rate: inRate),
            outputSeconds: Self.latencySeconds(outID, scope: kAudioObjectPropertyScopeOutput, rate: outRate))
        installListeners()
        running.store(true, ordering: .releasing)

        do {
            try check(AudioOutputUnitStart(inputUnit!), "starting input")
            try check(AudioOutputUnitStart(outputUnit!), "starting output")
        } catch {
            stop()
            throw error
        }
        sink?.audioIO(didReceive: .started(format!))
    }

    func stop() {
        guard running.exchange(false, ordering: .acquiringAndReleasing) else { return }
        if let inputUnit { AudioOutputUnitStop(inputUnit) }
        if let outputUnit { AudioOutputUnitStop(outputUnit) }
        removeListeners()
        tearDownUnits()
    }

    // MARK: - Permission

    static func ensureMicrophonePermission() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                granted = ok
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + .seconds(120))
            if !granted { throw ModemAudioError.permissionDenied }
        default:
            throw ModemAudioError.permissionDenied
        }
    }

    // MARK: - Units

    private func makeUnit(device: AudioObjectID, isInput: Bool, sampleRate: Double, channels: Int) throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw ModemAudioError.system(code: -1, stage: "finding the HAL output unit")
        }
        var unitOptional: AudioUnit?
        try check(AudioComponentInstanceNew(component, &unitOptional), "creating an audio unit")
        guard let unit = unitOptional else { throw ModemAudioError.system(code: -1, stage: "creating an audio unit") }

        // Element 1 is the input side of a HAL unit, element 0 the output side.
        var enable: UInt32 = isInput ? 1 : 0
        var disable: UInt32 = isInput ? 0 : 1
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                                       &enable, UInt32(MemoryLayout<UInt32>.size)), "enabling input")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                                       &disable, UInt32(MemoryLayout<UInt32>.size)), "enabling output")

        var deviceID = device
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &deviceID, UInt32(MemoryLayout<AudioObjectID>.size)), "selecting the device")

        var frames = preferredBufferFrames
        AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
                             &frames, UInt32(MemoryLayout<UInt32>.size))   // best effort
        var maximum = UInt32(maxFrames)
        AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                             &maximum, UInt32(MemoryLayout<UInt32>.size))

        // Our client format: Float32, non-interleaved, the device's rate.
        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if isInput {
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                           &clientFormat, size), "setting the capture format")
            var callback = AURenderCallbackStruct(inputProc: coreAudioInputProc,
                                                  inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                           &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                      "installing the capture callback")
        } else {
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                           &clientFormat, size), "setting the playback format")
            var callback = AURenderCallbackStruct(inputProc: coreAudioRenderProc,
                                                  inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                           &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                      "installing the render callback")
        }
        return unit
    }

    private func allocateInputBuffers() {
        freeInputBuffers()
        let list = AudioBufferList.allocate(maximumBuffers: inputChannels)
        var storage: [UnsafeMutablePointer<Float>] = []
        for i in 0..<inputChannels {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
            pointer.initialize(repeating: 0, count: maxFrames)
            storage.append(pointer)
            list[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(maxFrames * 4), mData: pointer)
        }
        inputList = list
        inputStorage = storage
        mono = .allocate(capacity: maxFrames)
        mono?.initialize(repeating: 0, count: maxFrames)
    }

    private func freeInputBuffers() {
        inputList?.unsafeMutablePointer.deallocate()
        inputList = nil
        for pointer in inputStorage { pointer.deallocate() }
        inputStorage = []
        mono?.deallocate()
        mono = nil
    }

    private func tearDownUnits() {
        for unit in [inputUnit, outputUnit].compactMap({ $0 }) {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        inputUnit = nil
        outputUnit = nil
        freeInputBuffers()
    }

    private func check(_ status: OSStatus, _ stage: String) throws {
        guard status == noErr else { throw ModemAudioError.system(code: status, stage: stage) }
    }

    private static func latencySeconds(_ id: AudioObjectID, scope: AudioObjectPropertyScope, rate: Double) -> Double {
        let latency = CoreAudioDeviceCatalog.uint32(id, kAudioDevicePropertyLatency, scope: scope) ?? 0
        let safety = CoreAudioDeviceCatalog.uint32(id, kAudioDevicePropertySafetyOffset, scope: scope) ?? 0
        let buffer = CoreAudioDeviceCatalog.uint32(id, kAudioDevicePropertyBufferFrameSize, scope: kAudioObjectPropertyScopeGlobal) ?? 0
        return Double(latency + safety + buffer) / rate
    }

    // MARK: - Listeners

    private func installListeners() {
        for device in Set([inputDevice, outputDevice]) {
            add(listener: kAudioDevicePropertyDeviceIsAlive, on: device) { [weak self] in
                guard let self else { return }
                var alive: UInt32 = 1
                var size = UInt32(MemoryLayout<UInt32>.size)
                var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
                                                         mScope: kAudioObjectPropertyScopeGlobal,
                                                         mElement: kAudioObjectPropertyElementMain)
                let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &alive)
                if status != noErr || alive == 0 {
                    self.running.store(false, ordering: .releasing)
                    self.sink?.audioIO(didReceive: .deviceLost)
                }
            }
            add(listener: kAudioDeviceProcessorOverload, on: device) { [weak self] in
                self?.sink?.audioIO(didReceive: .overload)
            }
            add(listener: kAudioDevicePropertyNominalSampleRate, on: device) { [weak self] in
                guard let self, let rate = CoreAudioDeviceCatalog.nominalSampleRate(device),
                      let format = self.format, abs(rate - format.sampleRate) > 1 else { return }
                self.format = ModemAudioFormat(sampleRate: rate, inputChannels: format.inputChannels,
                                               outputChannels: format.outputChannels)
                self.sink?.audioIO(didReceive: .formatChanged(self.format!))
            }
        }
    }

    private func add(listener selector: AudioObjectPropertySelector, on device: AudioObjectID,
                     _ handler: @escaping @Sendable () -> Void) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        if AudioObjectAddPropertyListenerBlock(device, &address, listenerQueue, block) == noErr {
            listeners.append((device, address, block))
        }
    }

    private func removeListeners() {
        for (device, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(device, &address, listenerQueue, block)
        }
        listeners.removeAll()
    }

    // MARK: - Real-time callbacks

    /// Pull the captured frames and hand them to the sink as mono.
    fileprivate func captured(_ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                              _ timeStamp: UnsafePointer<AudioTimeStamp>,
                              _ frames: UInt32) -> OSStatus {
        guard running.load(ordering: .relaxed), let unit = inputUnit, let list = inputList, let mono else { return noErr }
        let count = Int(min(frames, UInt32(maxFrames)))
        for i in 0..<inputChannels {
            list[i].mDataByteSize = UInt32(count * 4)
            list[i].mData = UnsafeMutableRawPointer(inputStorage[i])
        }
        let status = AudioUnitRender(unit, ioActionFlags, timeStamp, 1, UInt32(count), list.unsafeMutablePointer)
        guard status == noErr else { return status }

        let left = inputStorage[0]
        let right = inputChannels > 1 ? inputStorage[1] : inputStorage[0]
        switch inputChannel {
        case .left:
            mono.update(from: left, count: count)
        case .right:
            mono.update(from: right, count: count)
        case .mono:
            if inputChannels > 1 {
                for i in 0..<count { mono[i] = (left[i] + right[i]) * 0.5 }
            } else {
                mono.update(from: left, count: count)
            }
        }
        sink?.audioIO(didCapture: UnsafeBufferPointer(start: mono, count: count), hostTime: timeStamp.pointee.mHostTime)
        return noErr
    }

    /// Ask the sink for mono output and copy it to every channel.
    fileprivate func render(_ frames: UInt32, into data: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(data)
        let count = Int(frames)
        guard let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
        var written = 0
        if running.load(ordering: .relaxed), let sink {
            written = sink.audioIO(render: UnsafeMutableBufferPointer(start: first, count: count))
        }
        if written < count {
            (first + written).initialize(repeating: 0, count: count - written)
        }
        for buffer in buffers.dropFirst() {
            guard let other = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            other.update(from: first, count: count)
        }
        return noErr
    }
}

// C-callable trampolines: the refCon is the IO object, unretained.
nonisolated private func coreAudioInputProc(_ refCon: UnsafeMutableRawPointer,
                                _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                _ timeStamp: UnsafePointer<AudioTimeStamp>,
                                _ busNumber: UInt32,
                                _ frames: UInt32,
                                _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let io = Unmanaged<CoreAudioModemIO>.fromOpaque(refCon).takeUnretainedValue()
    return io.captured(ioActionFlags, timeStamp, frames)
}

nonisolated private func coreAudioRenderProc(_ refCon: UnsafeMutableRawPointer,
                                 _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                 _ timeStamp: UnsafePointer<AudioTimeStamp>,
                                 _ busNumber: UInt32,
                                 _ frames: UInt32,
                                 _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    guard let ioData else { return noErr }
    let io = Unmanaged<CoreAudioModemIO>.fromOpaque(refCon).takeUnretainedValue()
    return io.render(frames, into: ioData)
}
#endif
