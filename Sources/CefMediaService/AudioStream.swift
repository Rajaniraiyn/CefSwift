import Foundation

/// One page's audio stream: its decoder, the FLAC it writes, and where
/// its timeline is.
///
/// A request is a run of compressed packets in decode order with their
/// times; the answer is what to append to the page's native FLAC
/// `SourceBuffer`, in order: an initialization segment when the format
/// changes, then a media segment per run of packets that follow each
/// other in time.
final class AudioStream {
    /// One packet's presentation time and duration, in seconds.
    struct Timing: Equatable {
        var start: Double
        var duration: Double
    }

    /// Two times closer than this are the same.
    static let tolerance = 0.002

    private let decoder: SystemAudioDecoder
    private var writer: FlacFragmentWriter?
    /// Where the next packet would start if the stream continues.
    private var expected: Double?

    init(decoder: SystemAudioDecoder) {
        self.decoder = decoder
    }

    var format: FlacFragmentWriter.Format { decoder.output }

    /// Decodes `sizes.count` packets and returns the segments to append.
    /// `discontinuity` says the page moved (a seek, `abort()`), so the
    /// packets do not continue the previous ones whatever their times.
    func append(packets: UnsafeRawBufferPointer, sizes: [Int], timing: [Timing], discontinuity: Bool) -> [Data] {
        guard !sizes.isEmpty, sizes.count == timing.count else { return [] }
        let reset = discontinuity || expected.map { abs(timing[0].start - $0) > Self.tolerance } ?? true
        if reset { decoder.reset() }
        let planes = decoder.decode(packets: packets, sizes: sizes)
        if let last = timing.last { expected = last.start + last.duration }
        // After a reset the first packet has no predecessor to overlap
        // with: its output is replaced by silence, which keeps the
        // timeline exact.
        if reset, let first = planes.frames.first { planes.silence(from: 0, count: first) }

        let rate = Double(decoder.output.sampleRate)
        var runs: [Run] = []
        var at = 0
        for index in timing.indices {
            let follows = index > 0 && abs(timing[index].start - (timing[index - 1].start + timing[index - 1].duration)) <= Self.tolerance
            if !follows { runs.append(Run(start: Int((timing[index].start * rate).rounded()), first: at)) }
            runs[runs.count - 1].blocks.append(planes.frames[index])
            at += planes.frames[index]
        }

        var segments: [Data] = []
        for var run in runs {
            run.skipPriming()
            let length = run.blocks.reduce(0, +)
            guard length > 0 else { continue }
            if writer?.format != decoder.output {
                writer = FlacFragmentWriter(format: decoder.output)
                if let writer { segments.append(writer.initializationSegment()) }
            }
            segments.append(writer!.mediaSegment(
                planes: planes.planes(from: run.first, count: length), blocks: run.blocks, startSample: run.start))
        }
        return segments
    }

    /// Packets that follow each other in time. Within a run the decoder's
    /// output is contiguous from the run's first time: the decoder may
    /// emit less for a packet (HE-AAC drops its SBR delay after it
    /// starts) without the timeline moving.
    struct Run {
        /// The first frame's time, in samples.
        var start: Int
        /// The first frame's index in the decoded planes.
        var first: Int
        var blocks: [Int] = []

        /// Leaves out what comes before time zero: the priming that an
        /// edit list or iTunes' gapless tag moves there.
        mutating func skipPriming() {
            var skip = max(0, -start)
            while skip > 0, !blocks.isEmpty {
                let take = min(skip, blocks[0])
                blocks[0] -= take
                first += take
                start += take
                skip -= take
                if blocks[0] == 0 { blocks.removeFirst() }
            }
        }
    }
}
