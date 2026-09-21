import Foundation
import AVFoundation

/// Audio-thread-safe conversion between the device format and GPT-Live wire audio.
enum LiveAudioCodec {
  nonisolated static func encode(_ input: AVAudioPCMBuffer, using converter: AVAudioConverter, to format: AVAudioFormat) -> Data? {
    let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate)) + 32
    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
    var supplied = false
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, state in
      if supplied { state.pointee = .noDataNow; return nil }
      supplied = true
      state.pointee = .haveData
      return input
    }
    guard status != .error, error == nil, let samples = output.int16ChannelData?[0] else { return nil }
    return Data(bytes: samples, count: Int(output.frameLength) * 2)
  }

  /// Speech envelope in 0...1, with a noise floor so quiet PCM stays still.
  nonisolated static func level(_ bytes: Data) -> Double {
    guard !bytes.isEmpty, bytes.count % 2 == 0 else { return 0 }
    let count = bytes.count / 2
    let energy = bytes.withUnsafeBytes { raw in
      var sum = 0.0
      for index in 0..<count {
        let sample = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32768
        sum += sample * sample
      }
      return sum / Double(count)
    }
    guard energy > 0 else { return 0 }
    let decibels = 10 * log10(energy)
    return min(1, max(0, (decibels + 48) / 36))
  }

  nonisolated static func decode(_ bytes: Data) -> AVAudioPCMBuffer? {
    guard !bytes.isEmpty, bytes.count % 2 == 0,
          let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(bytes.count / 2)),
          let samples = buffer.floatChannelData?[0] else { return nil }
    let count = bytes.count / 2
    bytes.withUnsafeBytes { raw in
      for index in 0..<count {
        samples[index] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32768
      }
    }
    buffer.frameLength = AVAudioFrameCount(count)
    return buffer
  }
}
