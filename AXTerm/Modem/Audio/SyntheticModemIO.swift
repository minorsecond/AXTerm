import Foundation

/// Audio I/O that a test drives by hand.
///
/// `feed` delivers capture in fixed blocks, and after each block pulls one
/// block of output the way a real device would, appending it to
/// `renderedOutput`. Everything happens synchronously on the calling
/// thread, so a test is a sequence of plain function calls with no timing.
nonisolated final class SyntheticModemIO: ModemAudioIO, @unchecked Sendable {

    let sampleRate: Double
    let blockSize: Int
    private(set) var format: ModemAudioFormat?
    var latency = ModemAudioLatency(inputSeconds: 0.01, outputSeconds: 0.01)
    weak var sink: ModemAudioSink?

    /// Everything the engine rendered, block by block.
    private(set) var renderedOutput: [Float] = []
    /// Blocks the engine rendered short (silence filled the rest).
    private(set) var underfilledBlocks = 0
    private(set) var isRunning = false
    /// Set before `start()` to make it fail.
    var startError: Error?

    private var pendingInput: [Float] = []
    private var scratch: [Float]

    init(sampleRate: Double = 48_000, blockSize: Int = 480) {
        self.sampleRate = sampleRate
        self.blockSize = blockSize
        self.scratch = [Float](repeating: 0, count: blockSize)
    }

    func start() throws {
        if let startError { throw startError }
        format = ModemAudioFormat(sampleRate: sampleRate, inputChannels: 1, outputChannels: 1)
        isRunning = true
        sink?.audioIO(didReceive: .started(format!))
    }

    func stop() { isRunning = false }

    /// Deliver capture; whole blocks go through, a remainder waits for more.
    func feed(_ samples: [Float]) {
        pendingInput.append(contentsOf: samples)
        while pendingInput.count >= blockSize {
            let block = Array(pendingInput.prefix(blockSize))
            pendingInput.removeFirst(blockSize)
            deliver(block)
        }
    }

    /// Deliver `blocks` blocks of silence — time passing on a quiet channel.
    func pump(blocks: Int) {
        let silence = [Float](repeating: 0, count: blockSize)
        for _ in 0..<blocks { deliver(silence) }
    }

    func simulateDeviceLost() {
        isRunning = false
        sink?.audioIO(didReceive: .deviceLost)
    }

    private func deliver(_ block: [Float]) {
        guard isRunning, let sink else { return }
        block.withUnsafeBufferPointer { sink.audioIO(didCapture: $0, hostTime: 0) }
        let written = scratch.withUnsafeMutableBufferPointer { sink.audioIO(render: $0) }
        if written < blockSize {
            underfilledBlocks += 1
            for i in written..<blockSize { scratch[i] = 0 }
        }
        renderedOutput.append(contentsOf: scratch)
    }
}
