import AVFoundation
import XCTest
@testable import VoxNotch

@MainActor
final class AudioCaptureManagerTests: XCTestCase {
  func testNoDefaultInputDoesNotOpenEngineOrAcceptPlaceholderFormat() {
    var queriedHardware = false
    XCTAssertThrowsError(try AudioCaptureManager.validateMicrophoneInput(deviceID: 0) {
      queriedHardware = true
      // AVAudioEngine's output bus can report this even without a microphone.
      return (44_100, 2)
    }) { error in
      guard case AudioCaptureManager.AudioCaptureError.noInputAvailable = error else {
        return XCTFail("Expected an actionable missing-input error, got \(error)")
      }
    }
    XCTAssertFalse(queriedHardware)
  }

  func testMissingHardwareFormatIsRejectedBeforeInstallingTap() {
    // Exact hardware format from the reported -10868 failure, plus partially
    // unavailable formats during device disconnect/reconnect.
    let formats: [(Double, AVAudioChannelCount)] = [
      (0, 0), (0, 1), (48_000, 0), (-1, 1), (.nan, 1), (.infinity, 1),
    ]
    for format in formats {
      XCTAssertThrowsError(try AudioCaptureManager.validateMicrophoneInput(deviceID: 123) { format }) { error in
        guard case AudioCaptureManager.AudioCaptureError.noInputAvailable = error else {
          return XCTFail("Expected missing-input error for \(format), got \(error)")
        }
      }
    }
  }

  func testNativeInputFormatsAreAcceptedWithoutForcingASRSampleRateOrChannels() {
    // Bluetooth, USB, and multichannel hardware are resampled after capture;
    // the hardware itself need not provide 16 kHz mono.
    let formats: [(Double, AVAudioChannelCount)] = [
      (8_000, 1), (16_000, 1), (24_000, 1), (44_100, 2), (48_000, 1), (96_000, 8),
    ]
    for format in formats {
      XCTAssertNoThrow(try AudioCaptureManager.validateMicrophoneInput(deviceID: 123) { format })
    }
  }
}
