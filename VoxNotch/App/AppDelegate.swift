//
//  AppDelegate.swift
//  VoxNotch
//
//  NSApplicationDelegate for menu bar integration and app lifecycle
//

import SwiftUI
import AppKit
import CoreAudio
import os.log

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties
    private lazy var container = ServiceContainer.shared
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var deviceChangeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupNotch()
        initializeDatabase()
        setupSleepWakeHandling()
        configureAppBehavior()

        if container.settings.hasCompletedOnboarding {
            startNormalOperation()
        } else {
            showOnboardingWizard()
        }

        AlwaysOnShortcuts.install()

        #if DEBUG
        AlwaysOnDemo.startIfRequested()
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleanup()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep app running when windows are closed (menu bar app)
        return false
    }

    // MARK: - Notch

    private func setupNotch() {
        NotchManager.shared.setup()
    }

    // MARK: - Menu Bar Setup

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(named: "MenuBarIcon")
            button.image?.isTemplate = true
            button.action = #selector(statusBarButtonClicked)
            button.target = self
        }

        setupMenu()
    }

    private func setupMenu() {
        let menu = NSMenu()

        let alwaysOnItem = NSMenuItem(
            title: "Always-On Mode",
            action: #selector(toggleAlwaysOn),
            keyEquivalent: ""
        )
        alwaysOnItem.tag = Self.alwaysOnMenuTag
        menu.addItem(alwaysOnItem)

        menu.addItem(NSMenuItem.separator())

        // Settings
        menu.addItem(NSMenuItem(
            title: "Settings...",
            action: #selector(openSettings),
            keyEquivalent: ","
        ))

        // Microphone submenu (tag 103 — relied on by buildMicrophoneSubmenu refresh logic and device change observer)
        let micMenuItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        micMenuItem.tag = 103
        let micSubmenu = NSMenu(title: "Microphone")
        micMenuItem.submenu = micSubmenu
        menu.addItem(micMenuItem)
        buildMicrophoneSubmenu(micSubmenu)

        // History
        let historyItem = NSMenuItem(
            title: "History...",
            action: #selector(openHistory),
            keyEquivalent: ""
        )
        menu.addItem(historyItem)

        let alwaysOnHistoryItem = NSMenuItem(
            title: "Always-On History...",
            action: #selector(openAlwaysOnHistory),
            keyEquivalent: ""
        )
        menu.addItem(alwaysOnHistoryItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        menu.addItem(NSMenuItem(
            title: "Quit VoxNotch",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        self.statusItem?.menu = menu
    }

    // MARK: - Actions

    @objc private func statusBarButtonClicked() {
        // Toggle menu (handled by the menu property)
    }

    private static let alwaysOnMenuTag = 104

    @objc private func toggleAlwaysOn() {
        AlwaysOnController.shared.toggle()
    }

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.tag == Self.alwaysOnMenuTag {
            menuItem.state = AlwaysOnController.shared.isActive ? .on : .off
        }
        return true
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func openHistory() {
        if #available(macOS 26.0, *) {
            HistoryWindowController.shared.show()
        }
    }

    @objc private func openAlwaysOnHistory() {
        if #available(macOS 26.0, *) {
            AlwaysOnHistoryWindowController.shared.show()
        }
    }

    // MARK: - Microphone Submenu

    private func buildMicrophoneSubmenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let audioManager = AudioCaptureManager.shared
        let currentSelection = audioManager.selectedDeviceID

        /// System Default item
        let defaultItem = NSMenuItem(
            title: "System Default",
            action: #selector(selectMicrophone(_:)),
            keyEquivalent: ""
        )
        defaultItem.tag = 0
        defaultItem.target = self
        defaultItem.state = currentSelection == nil ? .on : .off
        menu.addItem(defaultItem)

        menu.addItem(NSMenuItem.separator())

        /// Available devices
        let devices = audioManager.availableInputDevices()

        if devices.isEmpty {
            let noDeviceItem = NSMenuItem(title: "No devices found", action: nil, keyEquivalent: "")
            noDeviceItem.isEnabled = false
            menu.addItem(noDeviceItem)
        } else {
            for device in devices {
                let item = NSMenuItem(
                    title: device.name,
                    action: #selector(selectMicrophone(_:)),
                    keyEquivalent: ""
                )
                item.tag = Int(device.id)
                item.target = self
                item.state = currentSelection == device.id ? .on : .off
                menu.addItem(item)
            }
        }
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        let deviceID = sender.tag
        let audioManager = AudioCaptureManager.shared

        if deviceID == 0 {
            audioManager.selectInputDevice(nil)
        } else {
            audioManager.selectInputDevice(AudioDeviceID(deviceID))
        }

        /// Rebuild the submenu to update checkmarks
        if let menu = statusItem?.menu,
           let micMenuItem = menu.item(withTag: 103),
           let micSubmenu = micMenuItem.submenu
        {
            buildMicrophoneSubmenu(micSubmenu)
        }
    }

    // MARK: - Audio Device Monitoring

    private func setupAudioDeviceMonitoring() {
        let audioManager = AudioCaptureManager.shared

        /// Restore persisted device selection
        audioManager.restoreDeviceSelection()
        audioManager.warmUp()

        /// Start listening for device connect/disconnect
        audioManager.startDeviceChangeListener()

        /// Rebuild mic submenu when devices change
        deviceChangeObserver = NotificationCenter.default.addObserver(
            forName: AudioCaptureManager.inputDevicesChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self,
                  let menu = self.statusItem?.menu,
                  let micMenuItem = menu.item(withTag: 103),
                  let micSubmenu = micMenuItem.submenu
            else {
                return
            }

            self.buildMicrophoneSubmenu(micSubmenu)
        }
    }

    // MARK: - Status Updates

    func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        button.image = NSImage(named: "MenuBarIcon")
        button.image?.isTemplate = true
    }

    func updateMenuStatus() {
        // No dynamic menu items to update currently
    }

    // MARK: - Database

    private func initializeDatabase() {
        Task { [container] in
            do {
                try await container.databaseManager.initialize()
                AlwaysOnHistoryStore.shared.recoverCrashedSessions()
                AlwaysOnHistoryStore.shared.pruneExpiredSessions()
            } catch {
                Logger(subsystem: "com.voxnotch", category: "AppDelegate").error("Failed to initialize database: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Quick Dictation

    private func setupQuickDictation() {
        let controller = container.dictationController

        // Listen for state changes to update UI
        controller.onStateChange = { [weak self] state in
            self?.updateStatusIcon()
            self?.updateMenuStatus()
        }

        // Start the controller
        controller.start()

        // Check model readiness (no auto-download)
        let appState = container.appState
        let settings = container.settings
        Task {
            let modelManager = FluidAudioModelManager.shared
            let isReady = modelManager.quickDictationModelsReady()
            await MainActor.run {
                appState.modelDownload.isModelReady = isReady
                appState.modelDownload.isDownloadingModel = false
                if !isReady {
                    appState.modelDownload.modelsNeeded = true
                    let speechModelID = settings.speechModel
                    let (builtin, custom) = SpeechModel.resolve(speechModelID)
                    let name = builtin?.displayName ?? custom?.displayName ?? speechModelID
                    appState.modelDownload.modelsNeededMessage = "Not downloaded: \(name)"
                }
            }
        }
    }

    // MARK: - First-Run Wizard

    private func showOnboardingWizard() {
        let wizard = OnboardingWindowController.shared
        wizard.onComplete = { [weak self] in
            self?.startNormalOperation()
        }
        wizard.show()
    }

    private func startNormalOperation() {
        setupQuickDictation()
        setupAudioDeviceMonitoring()

        // Refresh model states in case onboarding just downloaded a model
        FluidAudioModelManager.shared.refreshAllModelStates()
        MLXAudioModelManager.shared.refreshAllModelStates()
    }

    // MARK: - Configuration

    private func configureAppBehavior() {
        // Hide dock icon (menu bar only app)
        // Note: This should be set in Info.plist with LSUIElement = YES for production
        // For development, we keep the dock icon visible

        // Ensure app activates properly
        NSApp.setActivationPolicy(.accessory)

        // Check for updates on launch if enabled
        if container.settings.checkForUpdatesAutomatically {
            UpdateManager.shared.checkForUpdatesInBackground()
        }
    }

    // MARK: - Sleep/Wake

    private func setupSleepWakeHandling() {
        let ws = NSWorkspace.shared.notificationCenter

        sleepObserver = ws.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.container.dictationController.stop()
            ModelMemoryManager.shared.stopIdleTimer()
            MainActor.assumeIsolated {
                AlwaysOnController.shared.stop()
            }
        }

        wakeObserver = ws.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.container.dictationController.start()
        }
    }

    // MARK: - Cleanup

    private func cleanup() {
        container.dictationController.stop()

        // Clean up device monitoring
        AudioCaptureManager.shared.stopDeviceChangeListener()
        if let observer = deviceChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            deviceChangeObserver = nil
        }

        // Clean up sleep/wake observers
        let ws = NSWorkspace.shared.notificationCenter
        if let observer = sleepObserver {
            ws.removeObserver(observer)
            sleepObserver = nil
        }
        if let observer = wakeObserver {
            ws.removeObserver(observer)
            wakeObserver = nil
        }

        statusItem = nil
    }
}
