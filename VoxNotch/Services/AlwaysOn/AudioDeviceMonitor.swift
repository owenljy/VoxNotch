//
//  AudioDeviceMonitor.swift
//  VoxNotch
//
//  Observable list of audio input/output devices and the system defaults,
//  kept current via CoreAudio property listeners. Backs the device chips in
//  the Always-On panel header.
//

import CoreAudio
import Foundation

@MainActor @Observable
final class AudioDeviceMonitor {

  struct Device: Identifiable, Equatable, Sendable {
    let id: AudioDeviceID
    let name: String
    let transportType: UInt32

    var isBluetooth: Bool {
      transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE
    }
  }

  static let shared = AudioDeviceMonitor()

  private(set) var inputs: [Device] = []
  private(set) var outputs: [Device] = []
  private(set) var defaultInputID: AudioDeviceID = 0
  private(set) var defaultOutputID: AudioDeviceID = 0
  /// The microphone chosen in VoxNotch; nil follows the system default.
  private(set) var selectedInputID: AudioDeviceID?

  @ObservationIgnored private var isListening = false

  private init() {}

  /// The microphone actually in use.
  var activeInput: Device? {
    let id = selectedInputID ?? defaultInputID
    return inputs.first { $0.id == id }
  }

  var activeOutput: Device? {
    outputs.first { $0.id == defaultOutputID }
  }

  func start() {
    refresh()
    guard !isListening else { return }
    isListening = true
    for selector in [
      kAudioHardwarePropertyDevices,
      kAudioHardwarePropertyDefaultInputDevice,
      kAudioHardwarePropertyDefaultOutputDevice,
    ] {
      var address = AudioObjectPropertyAddress(
        mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
      AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.refresh() }
      }
    }
  }

  func refresh() {
    let all = Self.allDeviceIDs()
    inputs = all.filter { Self.hasStreams($0, scope: kAudioDevicePropertyScopeInput) }.compactMap(Self.device)
    outputs = all.filter { Self.hasStreams($0, scope: kAudioDevicePropertyScopeOutput) }.compactMap(Self.device)
    defaultInputID = Self.systemDevice(kAudioHardwarePropertyDefaultInputDevice)
    defaultOutputID = Self.systemDevice(kAudioHardwarePropertyDefaultOutputDevice)
    selectedInputID = AudioCaptureManager.shared.selectedDeviceID
  }

  /// Switches the system-wide output device (what System Settings → Sound does).
  func setDefaultOutput(_ id: AudioDeviceID) {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var deviceID = id
    AudioObjectSetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
      UInt32(MemoryLayout<AudioDeviceID>.size), &deviceID)
    refresh()
  }

  // MARK: - CoreAudio

  private nonisolated static func allDeviceIDs() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
    else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
    else { return [] }
    return ids
  }

  private nonisolated static func hasStreams(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
  }

  private nonisolated static func device(_ id: AudioDeviceID) -> Device? {
    var nameAddress = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceNameCFString, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var name: Unmanaged<CFString>?
    var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr,
          let deviceName = name?.takeRetainedValue() as String?
    else { return nil }

    var transportAddress = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var transport: UInt32 = 0
    var transportSize = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &transportSize, &transport)

    return Device(id: id, name: deviceName, transportType: transport)
  }

  private nonisolated static func systemDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var id: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
    return id
  }
}
