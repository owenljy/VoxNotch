//
//  GeneralTab.swift
//  VoxNotch
//
//  General settings: startup, privacy, about, storage
//

import SwiftUI
import ServiceManagement
import os.log

private let settingsLogger = Logger(subsystem: "com.voxnotch", category: "GeneralTab")

struct GeneralTab: View {

  @Bindable private var settings = SettingsManager.shared
  private var updateManager = UpdateManager.shared
  @State private var loginItemError: String?
  @State private var loginItemStatus = SMAppService.mainApp.status
  @State private var modelManager = FluidAudioModelManager.shared
  @State private var mlxModelManager = MLXAudioModelManager.shared
  @State private var showDeleteAllConfirmation = false

  private var isLoginItemEnabled: Bool {
    loginItemStatus == .enabled || loginItemStatus == .requiresApproval
  }

  var body: some View {
    Form {
      // MARK: Startup
      Section {
        Toggle(isOn: Binding(
          get: { isLoginItemEnabled },
          set: { newValue in
            updateLoginItem(enabled: newValue)
          }
        )) {
          InfoLabel(title: "Launch VoxNotch at login", tooltip: "Automatically start VoxNotch when you log into your Mac.")
        }
        if loginItemStatus == .requiresApproval {
          Text("Allow VoxNotch in System Settings → General → Login Items to finish enabling automatic startup.")
            .font(InterfaceScale.Typography.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Button("Open Login Items Settings") {
            SMAppService.openSystemSettingsLoginItems()
          }
        } else if loginItemStatus == .notFound {
          Text("macOS could not find the app's login item. Move VoxNotch to Applications and open it again.")
            .font(InterfaceScale.Typography.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        if let error = loginItemError {
          Text(error)
            .font(InterfaceScale.Typography.caption)
            .foregroundStyle(.red)
        }
      } header: {
        Text("Startup")
          .settingsSectionHeading()
      } footer: {
        Text("Start VoxNotch automatically in the menu bar when you log into your Mac, including after a restart.")
          .settingsSectionNote()
      }

      // MARK: Setup
      Section {
        Button("Run Setup Wizard Again\u{2026}") {
          let wizard = OnboardingWindowController.shared
          wizard.onComplete = nil
          wizard.show()
        }
      } header: {
        Text("Setup")
          .settingsSectionHeading()
      } footer: {
        Text("Re-run the first-time setup to configure permissions, download models, and review the tutorial.")
          .settingsSectionNote()
      }

      // MARK: Privacy
      Section {
        Toggle(isOn: $settings.hideFromScreenRecording) {
          InfoLabel(title: "Hide from screen recording", tooltip: "When enabled, VoxNotch windows won't appear in screen recordings, screenshots by other apps, or screen sharing.")
        }
      } header: {
        Text("Privacy")
          .settingsSectionHeading()
      } footer: {
        Text("Prevents VoxNotch from appearing in screen shares and recordings.")
          .settingsSectionNote()
      }

      // MARK: About
      Section {
        LabeledContent("Version") {
          Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
            .foregroundStyle(.secondary)
        }

        LabeledContent("Build") {
          Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
            .foregroundStyle(.secondary)
        }
      } header: {
        Text("About")
          .settingsSectionHeading()
      }

      // MARK: Storage
      Section {
        let totalBytes = modelManager.totalStorageUsedBytes() + mlxModelManager.totalStorageUsedBytes()
        LabeledContent {
          Text(formatBytes(totalBytes))
            .foregroundStyle(.secondary)
        } label: {
          InfoLabel(title: "Total Model Storage", tooltip: "Disk space used by downloaded speech models. Deleting models frees space but you'll need to re-download them.")
        }

        Button("Delete All Models", role: .destructive) {
          showDeleteAllConfirmation = true
        }
        .disabled(totalBytes == 0)
        .confirmationDialog("Delete all downloaded models?", isPresented: $showDeleteAllConfirmation) {
          Button("Delete All", role: .destructive) {
            do {
              try modelManager.deleteAllModels()
            } catch {
              settingsLogger.error("Failed to delete FluidAudio models: \(error.localizedDescription)")
            }
            do {
              try mlxModelManager.deleteAllModels()
            } catch {
              settingsLogger.error("Failed to delete MLX Audio models: \(error.localizedDescription)")
            }
            modelManager.refreshAllModelStates()
            mlxModelManager.refreshAllModelStates()
          }
        } message: {
          Text("This will remove all downloaded speech models. You can re-download them at any time.")
        }
      } header: {
        Text("Storage")
          .settingsSectionHeading()
      } footer: {
        Text("Includes all speech models for Quick Dictation.")
          .settingsSectionNote()
      }
    }
    .settingsFormLayout()
    .onAppear {
      refreshLoginItemStatus()
      modelManager.refreshAllModelStates()
      mlxModelManager.refreshAllModelStates()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      refreshLoginItemStatus()
    }
  }

  private func refreshLoginItemStatus() {
    loginItemStatus = SMAppService.mainApp.status
    settings.launchAtLogin = isLoginItemEnabled
  }

  private func updateLoginItem(enabled: Bool) {
    loginItemError = nil
    defer { refreshLoginItemStatus() }
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      loginItemError = "Failed to update login item: \(error.localizedDescription)"
    }
  }
}
