//
//  DeviceChip.swift
//  VoxNotch
//
//  Header chip for one audio source: device name, live level and a menu to
//  switch devices or turn the source on/off for this session.
//

import CoreAudio
import SwiftUI

struct DeviceChip: View {

  let source: AudioSource
  let style: AlwaysOnStyle

  @Environment(AlwaysOnState.self) private var state
  private let devices = AudioDeviceMonitor.shared

  private var isOn: Bool { state.activeSources.contains(source) }
  private var canChange: Bool { state.status == .running }

  var body: some View {
    Menu {
      switch source {
      case .microphone: microphoneMenu
      case .systemAudio: outputMenu
      }
    } label: {
      HStack(spacing: 5) {
        Image(systemName: icon)
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(isOn ? style.color(for: source) : Color.white.opacity(0.35))
        Text(deviceName)
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(.white.opacity(isOn ? 0.85 : 0.4))
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(minWidth: 24, maxWidth: 92, alignment: .leading)
        if isOn {
          SourceLevelMeter(level: state.levels[source] ?? 0, color: style.color(for: source))
        }
      }
      .padding(.horizontal, 7)
      .frame(height: 20)
      .background(Capsule().fill(Color.white.opacity(0.08)))
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize(horizontal: false, vertical: true)
    .help(helpText)
  }

  // MARK: - Menus

  @ViewBuilder
  private var microphoneMenu: some View {
    Section("Microphone (Me)") {
      deviceButton(
        title: "System Default" + (defaultInputName.map { " — \($0)" } ?? ""),
        isSelected: devices.selectedInputID == nil
      ) { AlwaysOnController.shared.selectMicrophone(nil) }
      ForEach(devices.inputs) { device in
        deviceButton(title: device.name, isSelected: devices.selectedInputID == device.id) {
          AlwaysOnController.shared.selectMicrophone(device.id)
        }
      }
    }
    Divider()
    Button(isOn ? "Turn Off Microphone" : "Turn On Microphone") {
      AlwaysOnController.shared.setSource(.microphone, enabled: !isOn)
    }
    .disabled(!canChange)
  }

  @ViewBuilder
  private var outputMenu: some View {
    Section("Output Device (Them)") {
      ForEach(devices.outputs) { device in
        deviceButton(title: device.name, isSelected: devices.defaultOutputID == device.id) {
          devices.setDefaultOutput(device.id)
        }
      }
    }
    Divider()
    Button(isOn ? "Stop Capturing System Audio" : "Capture System Audio") {
      AlwaysOnController.shared.setSource(.systemAudio, enabled: !isOn)
    }
    .disabled(!canChange)
  }

  private func deviceButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      if isSelected {
        Label(title, systemImage: "checkmark")
      } else {
        Text(title)
      }
    }
    .disabled(!canChange)
  }

  // MARK: - Display

  private var defaultInputName: String? {
    devices.inputs.first { $0.id == devices.defaultInputID }?.name
  }

  private var deviceName: String {
    switch source {
    case .microphone: devices.activeInput?.name ?? "Microphone"
    case .systemAudio: devices.activeOutput?.name ?? "System Audio"
    }
  }

  private var icon: String {
    switch source {
    case .microphone:
      return isOn ? "mic.fill" : "mic.slash.fill"
    case .systemAudio:
      guard isOn else { return "speaker.slash.fill" }
      return devices.activeOutput?.isBluetooth == true ? "headphones" : "speaker.wave.2.fill"
    }
  }

  private var helpText: String {
    switch source {
    case .microphone: "Your microphone (Me) — click to switch or turn off"
    case .systemAudio: "System audio (Them) is captured from the output — click to switch output device or turn off"
    }
  }
}
