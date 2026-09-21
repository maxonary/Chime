import Foundation
import AVFoundation

@main
struct AudioCodecTests {
  static func main() {
    let pcm = Data([0, 128, 0, 192, 0, 0, 0, 64, 255, 127])
    let decoded = LiveAudioCodec.decode(pcm)!
    assert(decoded.format.sampleRate == 24000)
    assert(decoded.format.channelCount == 1)
    assert(decoded.frameLength == 5)
    let expected: [Float] = [-1, -0.5, 0, 0.5, 32767.0 / 32768.0]
    for index in expected.indices {
      assert(abs(decoded.floatChannelData![0][index] - expected[index]) < 0.00001)
    }
    assert(LiveAudioCodec.decode(Data([0])) == nil)
    assert(LiveAudioCodec.decode(Data()) == nil)

    // Meter silence/noise separately from speech and tolerate malformed frames.
    assert(LiveAudioCodec.level(Data(repeating: 0, count: 1920)) == 0)
    assert(LiveAudioCodec.level(Data([0])) == 0)
    assert(LiveAudioCodec.level(Data()) == 0)
    func constantPCM(_ sample: Int16) -> Data {
      let value = sample.littleEndian
      return withUnsafeBytes(of: value) { Data($0) }
    }
    assert(LiveAudioCodec.level(constantPCM(16)) == 0, "Noise below the floor should not pulse")
    let soft = LiveAudioCodec.level(constantPCM(600))
    let loud = LiveAudioCodec.level(constantPCM(6000))
    assert(soft > 0 && loud > soft && loud <= 1, "Speech energy must drive pulse strength")
    assert(LiveAudioCodec.level(constantPCM(-6000)) == loud, "Meter both PCM polarities equally")
    assert(LiveAudioCodec.level(constantPCM(Int16.min)) == 1, "Full-scale samples must remain bounded")

    // Simulate a 48 kHz microphone producing a continuous 1 kHz sine wave.
    // The same converter must retain its resampling state between tap callbacks.
    let source = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    let wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!
    let converter = AVAudioConverter(from: source, to: wire)!
    var audio = Data()
    for chunk in 0..<20 {
      let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 2048)!
      buffer.frameLength = 2048
      for index in 0..<2048 {
        buffer.floatChannelData![0][index] = Float(sin(2 * .pi * 1000 * Double(chunk * 2048 + index) / 48000)) * 0.5
      }
      let bytes = LiveAudioCodec.encode(buffer, using: converter, to: wire)!
      assert(bytes.count % 2 == 0)
      audio.append(bytes)
    }
    let result = LiveAudioCodec.decode(audio)!
    assert(abs(Int(result.frameLength) - 20480) < 100, "Capture must be resampled, not relabeled")
    let samples = UnsafeBufferPointer(start: result.floatChannelData![0], count: Int(result.frameLength))
    assert((samples.map { abs($0) }.max() ?? 0) > 0.45, "Audio must retain signal amplitude")
    assert((samples.map { abs($0) }.max() ?? 1) < 0.55, "Audio must not clip")
    var crossings = 0
    for index in 1..<samples.count {
      if samples[index - 1] < 0 && samples[index] >= 0 { crossings += 1 }
    }
    let frequency = Double(crossings) * 24000 / Double(samples.count)
    assert(abs(frequency - 1000) < 5, "Resampling must preserve pitch")
    print("PASS: PCM byte order, playback amplitude, invalid frames, continuous 48→24 kHz resampling, pitch, and speech level metering")
  }
}
