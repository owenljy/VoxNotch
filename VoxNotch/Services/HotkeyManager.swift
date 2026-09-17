//
//  HotkeyManager.swift
//  VoxNotch
//
//  Global hotkey registration using CGEvent tap
//

import Foundation
import AppKit
import Carbon.HIToolbox
import os.log

/// Manages global hotkey registration and detection using CGEvent tap
final class HotkeyManager {

    // MARK: - Types

    /// Hotkey event types
    enum HotkeyEvent {
        case keyDown
        case keyUp
    }

    /// Callback type for hotkey events
    typealias HotkeyCallback = (HotkeyEvent) -> Void

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.voxnotch", category: "HotkeyManager")

    static let shared = HotkeyManager()

    /// Current hotkey configuration (modifier flags)
    /// Default: Control + Option
    private(set) var modifierFlags: CGEventFlags = [.maskControl, .maskAlternate]

    /// Modifier flags for the secondary (system-audio) hotkey. Default: Option.
    /// The secondary hotkey is a modifier+key combo (unlike the primary, which
    /// is modifier-only). Pairs with `secondaryKeyCode`.
    private(set) var secondaryModifierFlags: CGEventFlags = [.maskAlternate]

    /// Virtual keycode for the secondary hotkey trigger key. Default: 50 (` / ~).
    private(set) var secondaryKeyCode: Int64 = 50

    /// Callback for hotkey events
    var onHotkeyEvent: HotkeyCallback?

    /// Callback for the secondary (system-audio) hotkey events.
    var onSecondaryHotkeyEvent: HotkeyCallback?

    /// Callback for model switch arrow keys (-1 = left, +1 = right) while hotkey is held
    var onModelSwitchKey: ((Int) -> Void)?

    /// Callback for tone switch arrow keys (-1 = up, +1 = down) while hotkey is held
    var onToneSwitchKey: ((Int) -> Void)?

    /// Callback fired when ESC is pressed and useEscToCancel is enabled
    var onEscapeKey: (() -> Void)?

    /// Whether the hotkey is currently pressed
    private(set) var isHotkeyPressed: Bool = false

    /// Whether the secondary hotkey (modifier+key) is currently pressed.
    /// Used as an auto-repeat guard: macOS auto-repeats keyDown while held,
    /// but we only want to fire `.keyDown` once per press.
    private(set) var isSecondaryHotkeyPressed: Bool = false

    /// Whether global hotkey detection is temporarily paused (e.g., during hotkey recording)
    var isPaused: Bool = false {
        didSet {
            if isPaused && isHotkeyPressed {
                isHotkeyPressed = false
                DispatchQueue.main.async { [weak self] in
                    self?.onHotkeyEvent?(.keyUp)
                }
            }
            if isPaused && isSecondaryHotkeyPressed {
                isSecondaryHotkeyPressed = false
                DispatchQueue.main.async { [weak self] in
                    self?.onSecondaryHotkeyEvent?(.keyUp)
                }
            }
        }
    }

    /// Whether the event tap is currently active
    var isListening: Bool {
        guard let eventTap else { return false }
        return CFMachPortIsValid(eventTap) && CGEvent.tapIsEnabled(tap: eventTap)
    }

    /// The event tap for capturing global key events
    private var eventTap: CFMachPort?

    /// Run loop source for the event tap
    private var runLoopSource: CFRunLoopSource?

    /// Observer for settings changes
    private var settingsObserver: NSObjectProtocol?

    /// Whether accessibility permission has been granted
    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    // MARK: - Initialization

    private init() {
        loadFromSettings()
        setupSettingsObserver()
    }

    // MARK: - Settings Integration

    /// Load hotkey configuration from SettingsManager
    private func loadFromSettings() {
        let settings = SettingsManager.shared
        modifierFlags = CGEventFlags(rawValue: settings.hotkeyModifierFlags)
        secondaryModifierFlags = CGEventFlags(rawValue: settings.systemAudioHotkeyModifierFlags)
        secondaryKeyCode = Int64(settings.systemAudioHotkeyKeyCode)
        logger.debug("Loaded modifiers: primary=\(self.modifierFlags.modifierDescription), secondary=\(self.secondaryModifierFlags.modifierDescription)+keyCode=\(self.secondaryKeyCode)")
    }

    /// Setup observer for hotkey configuration changes
    private func setupSettingsObserver() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .hotkeyConfigurationChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.loadFromSettings()
        }
    }

    // MARK: - Public Methods

    /// Request accessibility permission from the user
    /// - Returns: True if permission is already granted
    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        // Trigger the system prompt which will:
        // 1. Show an alert if permission is not granted
        // 2. Register the app in the Accessibility list
        // 3. Give the user an "Open System Settings" button
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let isTrusted = AXIsProcessTrustedWithOptions(options)

        if isTrusted {
            logger.debug("Accessibility permission already granted")
        } else {
            logger.info("Accessibility permission requested - user needs to grant in System Settings")
        }

        return isTrusted
    }

    /// Start listening for global hotkey events
    /// - Returns: True if event tap was successfully created
    @discardableResult
    func startListening() -> Bool {
        guard hasAccessibilityPermission else {
            logger.info("Accessibility permission not granted")
            return false
        }

        if isListening { return true }
        if eventTap != nil { stopListening() }

        // Create event tap for modifier changes and key down/up events
        // (keyUp is needed to detect release of the secondary hotkey trigger key).
        let eventMask = (1 << CGEventType.flagsChanged.rawValue) |
                        (1 << CGEventType.keyDown.rawValue) |
                        (1 << CGEventType.keyUp.rawValue)

        // Create callback wrapper
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            return manager.handleEvent(type: type, event: event)
        }

        // Create the event tap
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.error("Failed to create event tap")
            return false
        }

        eventTap = tap

        // Create run loop source and add to MAIN run loop (critical for event processing)
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)

        // Enable the event tap
        CGEvent.tapEnable(tap: tap, enable: true)

        logger.info("Started listening (modifiers: \(self.modifierFlags.modifierDescription), raw: \(self.modifierFlags.rawValue))")
        return true
    }

    /// Stop listening for global hotkey events
    func stopListening() {
        guard eventTap != nil || runLoopSource != nil else { return }
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }

        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }

        if isHotkeyPressed { onHotkeyEvent?(.keyUp) }
        if isSecondaryHotkeyPressed { onSecondaryHotkeyEvent?(.keyUp) }
        isHotkeyPressed = false
        isSecondaryHotkeyPressed = false
        logger.info("Stopped listening")
    }

    /// Update the hotkey modifier configuration
    /// - Parameter modifiers: The new modifier flags to use
    func updateModifiers(_ modifiers: CGEventFlags) {
        modifierFlags = modifiers
        logger.debug("Updated modifiers to \(modifiers.modifierDescription)")
    }

    // MARK: - Private Methods

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard !isPaused else {
            return Unmanaged.passUnretained(event)
        }

        // Re-enable event tap if macOS disabled it (happens after system timeout)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                #if DEBUG
                print("HotkeyManager: Re-enabled event tap (disabled by system)")
                #endif
            }
            return Unmanaged.passUnretained(event)
        }

        // Handle keyDown events: arrow keys for model switching, Cmd+Shift+Space for cues
        if type == .keyDown {
            let flags = event.flags
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            // ESC key (53) — cancel active recording/session if enabled
            if keyCode == 53 && SettingsManager.shared.useEscToCancel {
                if let callback = onEscapeKey {
                    DispatchQueue.main.async { callback() }
                    return nil
                }
            }

            // Secondary hotkey (modifier + key) — fire .keyDown once per press.
            // Auto-repeat sends repeated keyDowns while held; the guard makes
            // sure the callback fires exactly once until the key is released.
            let relevantMask: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
            let filteredFlagsForSecondary = flags.intersection(relevantMask)
            let secondaryTargetMask = secondaryModifierFlags.intersection(relevantMask)
            if filteredFlagsForSecondary == secondaryTargetMask
                && filteredFlagsForSecondary.rawValue != 0
                && keyCode == secondaryKeyCode {
                if !isSecondaryHotkeyPressed {
                    isSecondaryHotkeyPressed = true
                    DispatchQueue.main.async { [weak self] in
                        self?.onSecondaryHotkeyEvent?(.keyDown)
                    }
                }
                return nil
            }

            // Arrow keys while hotkey is held — consume event and fire switch callbacks
            if isHotkeyPressed {
                if keyCode == 123 { // kVK_LeftArrow
                    DispatchQueue.main.async { [weak self] in self?.onModelSwitchKey?(-1) }
                    return nil
                } else if keyCode == 124 { // kVK_RightArrow
                    DispatchQueue.main.async { [weak self] in self?.onModelSwitchKey?(1) }
                    return nil
                } else if keyCode == 126 { // kVK_UpArrow
                    DispatchQueue.main.async { [weak self] in self?.onToneSwitchKey?(-1) }
                    return nil
                } else if keyCode == 125 { // kVK_DownArrow
                    DispatchQueue.main.async { [weak self] in self?.onToneSwitchKey?(1) }
                    return nil
                }
            }

            return Unmanaged.passUnretained(event)
        }

        // Handle keyUp: release the secondary hotkey if its trigger key was lifted.
        if type == .keyUp {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if isSecondaryHotkeyPressed && keyCode == secondaryKeyCode {
                isSecondaryHotkeyPressed = false
                DispatchQueue.main.async { [weak self] in
                    self?.onSecondaryHotkeyEvent?(.keyUp)
                }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        let currentFlags = event.flags
        
        // Define the mask for the modifiers we care about
        let relevantMask: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
        
        // Filter current flags to only include relevant ones
        let filteredFlags = currentFlags.intersection(relevantMask)
        
        // Compare with our configured modifier flags
        // We use rawValue comparison for exact match of the modifier set
        let targetMask = modifierFlags.intersection(relevantMask).rawValue
        let hotkeyActive = filteredFlags.rawValue == targetMask && filteredFlags.rawValue != 0

        #if DEBUG
        if hotkeyActive != isHotkeyPressed {
            print("HotkeyManager: State transition - Active: \(hotkeyActive), WasPressed: \(isHotkeyPressed), Flags: \(filteredFlags.rawValue), Target: \(targetMask)")
        }
        #endif

        // Secondary hotkey safety: if the user releases the modifier(s) while
        // the secondary trigger key is still held (or vice versa), force-release.
        if isSecondaryHotkeyPressed {
            let secondaryTargetMask = secondaryModifierFlags.intersection(relevantMask).rawValue
            if filteredFlags.rawValue != secondaryTargetMask {
                isSecondaryHotkeyPressed = false
                DispatchQueue.main.async { [weak self] in
                    self?.onSecondaryHotkeyEvent?(.keyUp)
                }
            }
        }

        if hotkeyActive && !isHotkeyPressed {
            // Hotkey just pressed
            isHotkeyPressed = true
            DispatchQueue.main.async { [weak self] in
                self?.onHotkeyEvent?(.keyDown)
            }
        } else if !hotkeyActive && isHotkeyPressed {
            // Hotkey just released
            isHotkeyPressed = false
            DispatchQueue.main.async { [weak self] in
                self?.onHotkeyEvent?(.keyUp)
            }
        } else if isHotkeyPressed {
            // SAFETY CHECK: If we think it's pressed but the flags don't match, force a release
            // This handles cases where we might have missed a flagsChanged event
            if filteredFlags.rawValue != targetMask {
                #if DEBUG
                print("HotkeyManager: Safety trigger - flags changed while pressed, forcing keyUp")
                #endif
                isHotkeyPressed = false
                DispatchQueue.main.async { [weak self] in
                    self?.onHotkeyEvent?(.keyUp)
                }
            }
        }

        // Pass the event through (don't consume it)
        return Unmanaged.passUnretained(event)
    }

    deinit {
        stopListening()
    }
}

// MARK: - CGEventFlags Extension

extension CGEventFlags {
    /// Human-readable description of modifier flags
    var modifierDescription: String {
        var parts: [String] = []
        if contains(.maskControl) { parts.append("Control") }
        if contains(.maskAlternate) { parts.append("Option") }
        if contains(.maskShift) { parts.append("Shift") }
        if contains(.maskCommand) { parts.append("Command") }
        return parts.isEmpty ? "None" : parts.joined(separator: " + ")
    }
}
