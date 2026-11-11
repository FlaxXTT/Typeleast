import Foundation

/// A range of canonical 16 kHz mono PCM16 audio, relative to the start of a meeting.
struct MeetingLiveRange: Equatable {
    let startByte: Int
    let endByte: Int

    var startSeconds: Double { Double(startByte) / 32_000 }
    var durationSeconds: Double { Double(endByte - startByte) / 32_000 }
}

/// Schedules a single local transcription at a time while recording continues.
///
/// The recorder owns the samples. This queue retains only byte offsets, so slow inference cannot
/// create an unbounded collection of copied audio. Access it on one serial queue or the main thread.
struct MeetingLiveQueue {
    private let chunkBytes: Int
    private let maxChunkBytes: Int
    private var availableBytes = 0
    private var nextByte = 0
    private var inFlight: MeetingLiveRange?
    private var finalized = false
    private var cancelled = false

    /// Defaults to ten seconds of speech, growing to at most thirty seconds when behind.
    init(chunkBytes: Int = 320_000, maxChunkBytes: Int = 960_000) {
        let chunk = max(2, chunkBytes - max(0, chunkBytes) % 2)
        self.chunkBytes = chunk
        self.maxChunkBytes = max(chunk, maxChunkBytes - max(0, maxChunkBytes) % 2)
    }

    /// Reports the total number of recorded bytes, not an incremental byte count.
    /// Once final, every remaining complete sample is scheduled, including a short tail.
    mutating func offer(availableBytes: Int, isFinal: Bool = false) -> MeetingLiveRange? {
        guard !cancelled, availableBytes >= 0 else { return nil }
        if !finalized {
            let completeSamples = availableBytes - availableBytes % 2
            self.availableBytes = max(self.availableBytes, completeSamples)
            if isFinal { finalized = true }
        }
        return next()
    }

    /// Call after the current range has been handled, then offer the latest recording size.
    mutating func complete() {
        guard !cancelled, inFlight != nil else { return }
        inFlight = nil
    }

    mutating func cancel() {
        cancelled = true
        inFlight = nil
    }

    var isProcessing: Bool { !cancelled && inFlight != nil }
    var isFinished: Bool { !cancelled && finalized && inFlight == nil && nextByte == availableBytes }

    private mutating func next() -> MeetingLiveRange? {
        guard !cancelled, inFlight == nil else { return nil }
        let pending = availableBytes - nextByte
        guard pending > 0, finalized || pending >= chunkBytes else { return nil }
        let end = nextByte + min(pending, maxChunkBytes)
        let range = MeetingLiveRange(startByte: nextByte, endByte: end)
        nextByte = end
        inFlight = range
        return range
    }
}
