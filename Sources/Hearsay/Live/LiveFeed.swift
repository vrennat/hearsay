@preconcurrency import AVFoundation
import Foundation
import HearsayCore

/// Carries capture buffers to `LiveTranscriber.shared`: each stream is converted on its audio thread
/// to 16 kHz mono Float (one stateful `AVAudioConverter` per stream, rebuilt when a device rebuild
/// changes the format), stamped with meeting time (host seconds since the meeting's start host time),
/// gathered into chunks of about 0.5 s, and handed to one consumer task. The tap delivers ~10 ms
/// buffers; feeding the engines that often only adds per-call overhead.
final class LiveFeed: @unchecked Sendable {
    static let shared = LiveFeed()
    static let chunkSeconds = 0.5

    private let log = HSLog("livefeed")
    private let lock = NSLock()
    private var startHostSeconds: Double = 0
    private var streams: [StreamKind: StreamState] = [:]
    private var continuation: AsyncStream<Chunk>.Continuation?
    private var consumer: Task<Void, Never>?
    private var failures = 0

    struct Chunk: Sendable { let kind: StreamKind; let samples: [Float]; let offset: Double }

    final class StreamState {
        var converter: AVAudioConverter?
        var inputFormat: AVAudioFormat?
        var pending: [Float] = []
        var pendingOffset: Double?
        /// Meeting time just past the last converted sample, to place samples of the next buffer.
        var nextOffset: Double?
    }

    static let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    /// Starts a live transcript for the meeting. `onLines` runs on the main actor at each save.
    func begin(meetingID: String, store: MeetingStore, startHost: UInt64,
               onLines: @escaping @MainActor ([LiveLine]) -> Void) {
        let (stream, cont) = AsyncStream<Chunk>.makeStream(bufferingPolicy: .unbounded)
        lock.lock()
        startHostSeconds = HostClock.seconds(startHost)
        streams = [.mic: StreamState(), .system: StreamState()]
        continuation = cont
        failures = 0
        lock.unlock()
        let log = self.log
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            await LiveTranscriber.shared.begin(meetingID: meetingID, store: store, onLines: { lines in
                Task { @MainActor in onLines(lines) }
            })
            do { try await LiveTranscriber.shared.preload() } catch { log.error("Live engines did not load: \(error)") }
            for await c in stream {
                do { try await LiveTranscriber.shared.append(c.samples, at: c.offset, stream: c.kind) } catch {
                    self?.noteFailure(error)
                }
            }
        }
        lock.lock(); consumer = task; lock.unlock()
    }

    private func noteFailure(_ error: Error) {
        lock.lock(); failures += 1; let n = failures; lock.unlock()
        if n <= 3 || n % 100 == 0 { log.error("Live append failed (\(n)): \(error)") }
    }

    /// Audio thread. Converts and copies before returning (the tap's buffer does not own its memory).
    func push(_ kind: StreamKind, _ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard let cont = continuation, let st = streams[kind], buffer.frameLength > 0 else { return }
        // Active-channel fold first (`ChannelFold`): the converter's own downmix averages dead
        // interface inputs in and loses 12 dB on a 4-input device with one mic.
        guard let buffer = ChannelFold.mono(buffer) else { return }
        if st.inputFormat != buffer.format {
            st.converter = AVAudioConverter(from: buffer.format, to: Self.outputFormat)
            st.inputFormat = buffer.format
        }
        guard let converter = st.converter else { return }
        let ratio = Self.outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed { inputStatus.pointee = .noDataNow; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let ch = out.floatChannelData else { return }
        let n = Int(out.frameLength)
        // The resampler holds a few samples back, so place output by the buffer's own time unless that
        // would overlap what is already placed (then continue from the previous end).
        let bufferTime = HostClock.seconds(hostTime) - startHostSeconds
        let offset = max(bufferTime, st.nextOffset ?? bufferTime)
        if st.pendingOffset == nil { st.pendingOffset = offset }
        else if let next = st.nextOffset, offset - next > 0.05 {
            // A gap (the tap goes quiet when nothing plays): flush what we have; the transcriber pads.
            flush(kind, st, cont)
            st.pendingOffset = offset
        }
        st.pending.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: n))
        st.nextOffset = offset + Double(n) / Self.outputFormat.sampleRate
        if Double(st.pending.count) / Self.outputFormat.sampleRate >= Self.chunkSeconds { flush(kind, st, cont) }
    }

    private func flush(_ kind: StreamKind, _ st: StreamState, _ cont: AsyncStream<Chunk>.Continuation) {
        guard let o = st.pendingOffset, !st.pending.isEmpty else { return }
        cont.yield(Chunk(kind: kind, samples: st.pending, offset: o))
        st.pending.removeAll(keepingCapacity: true)
        st.pendingOffset = nil
    }

    /// Flushes the last chunks, waits for the transcriber to drain, then `finish()` (final save).
    func finish() async {
        await close()?.value
        do { try await LiveTranscriber.shared.finish() } catch { log.error("Live finish failed: \(error)") }
    }

    /// Stops taking buffers and ends the chunk stream; returns the consumer to wait for.
    private func close() -> Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        if let cont = continuation {
            for (k, st) in streams { flush(k, st, cont) }
            cont.finish()
        }
        continuation = nil
        streams = [:]
        let task = consumer
        consumer = nil
        return task
    }
}
