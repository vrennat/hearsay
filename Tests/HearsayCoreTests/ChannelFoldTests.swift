import AVFoundation
import XCTest
@testable import HearsayCore

/// A 4-input interface with the mic on channel 0 and digital silence on the rest must read and fold
/// like a mono mic, not 12 dB quieter.
final class ChannelFoldTests: XCTestCase {
    private func buffer(channels: Int, frames: Int, fill: (Int, Int) -> Float) -> AVAudioPCMBuffer {
        // Above two channels AVAudioFormat needs a layout; discrete-in-order is what an interface reports.
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!
        let f = channels <= 2
            ? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: AVAudioChannelCount(channels), interleaved: false)!
            : AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false, channelLayout: layout)
        let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(frames))!
        b.frameLength = AVAudioFrameCount(frames)
        for c in 0..<channels { for i in 0..<frames { b.floatChannelData![c][i] = fill(c, i) } }
        return b
    }
    private func tone(_ i: Int) -> Float { 0.1 * sin(Float(i) * 0.05) }   // about -23 dBFS RMS

    func testOneLiveChannelFoldsAtFullLevel() {
        let b = buffer(channels: 4, frames: 4800) { c, i in c == 0 ? tone(i) : 1e-6 * Float((i % 3) - 1) }
        let mono = ChannelFold.mono(b)!
        XCTAssertEqual(mono.format.channelCount, 1)
        XCTAssertEqual(Int(mono.frameLength), 4800)
        for i in stride(from: 0, to: 4800, by: 97) { XCTAssertEqual(mono.floatChannelData![0][i], tone(i), accuracy: 1e-6) }
        let chans = (0..<4).map { UnsafePointer(b.floatChannelData![$0]) }
        XCTAssertEqual(ChannelFold.activeChannels(chans, frames: 4800), [0])
        let monoOnly = buffer(channels: 1, frames: 4800) { _, i in tone(i) }
        let expected = AudioLevel.dBFS(channels: [UnsafePointer(monoOnly.floatChannelData![0])], frames: 4800)
        XCTAssertEqual(AudioLevel.dBFS(channels: chans, frames: 4800), expected, accuracy: 0.01)
        XCTAssertEqual(expected, -23, accuracy: 1)
    }

    func testAllSilentChannelsStaySilent() {
        let b = buffer(channels: 4, frames: 1000) { _, _ in 0 }
        let chans = (0..<4).map { UnsafePointer(b.floatChannelData![$0]) }
        XCTAssertEqual(ChannelFold.activeChannels(chans, frames: 1000), [])
        XCTAssertEqual(AudioLevel.dBFS(channels: chans, frames: 1000), AudioLevel.floor)
        let mono = ChannelFold.mono(b)!   // kept alive: the pointer below must not outlive the buffer
        XCTAssertEqual(mono.floatChannelData![0][500], 0)
    }

    func testTwoLiveChannelsAverage() {
        let b = buffer(channels: 3, frames: 1000) { c, i in c == 2 ? 0 : (c == 0 ? 0.2 : 0.4) }
        let mono = ChannelFold.mono(b)!
        XCTAssertEqual(mono.floatChannelData![0][10], 0.3, accuracy: 1e-6)
    }

    func testMonoPassesThrough() {
        let b = buffer(channels: 1, frames: 100) { _, i in Float(i) }
        XCTAssertTrue(ChannelFold.mono(b) === b)
    }
}
