//
//  AlwaysOnDemo.swift
//  VoxNotch
//
//  DEBUG-only scripted session for working on the Always-On UI without audio.
//  Launch with `-alwaysOnDemo YES`.
//

#if DEBUG
import AppKit
import Foundation

@MainActor
enum AlwaysOnDemo {

  private static let script: [(AudioSource, String)] = [
    (.systemAudio, "Thanks for joining us today. Let's start with your background."),
    (.microphone, "Sure. I've spent the last four years building growth and retention features."),
    (.systemAudio, "Great. Our retention dropped about eight percent this quarter. What do you think is driving it?"),
    (.microphone, "My first guess would be the onboarding flow, it got a lot longer after the redesign."),
    (.systemAudio, "Interesting. So how would you actually validate that hypothesis?"),
  ]

  static func startIfRequested() {
    if let path = UserDefaults.standard.string(forKey: "settingsSnapshot") {
      let panel = UserDefaults.standard.string(forKey: "settingsSnapshotPanel").flatMap(SettingsPanel.init) ?? .alwaysOn
      SettingsWindowController.shared.show(panel: panel)
      Task {
        try? await Task.sleep(for: .seconds(1.5))
        guard let view = SettingsWindowController.shared.window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
      }
    }
    guard UserDefaults.standard.bool(forKey: "alwaysOnDemo") else { return }
    let state = AlwaysOnState.shared
    AlwaysOnPanelController.shared.show()
    state.begin(sources: [.microphone, .systemAudio])
    if UserDefaults.standard.bool(forKey: "alwaysOnDemoPreparing") {
      Task {
        try? await Task.sleep(for: .seconds(2))
        AlwaysOnPanelController.shared.debugSimulateDrag()
      }
      return
    }
    state.status = .running
    state.startedAt = Date().addingTimeInterval(-754)

    Task {
      var clock = Date()
      for (source, line) in script {
        let id = UUID()
        let words = line.split(separator: " ")
        let start = clock
        for count in 1...words.count {
          state.levels[source] = Float.random(in: 0.02...0.2)
          state.levels[source == .microphone ? .systemAudio : .microphone] = Float.random(in: 0...0.003)
          state.apply(update(id, source, words.prefix(count).joined(separator: " "), final: false, start: start, end: clock))
          try? await Task.sleep(for: .milliseconds(140))
          clock = clock.addingTimeInterval(0.3)
        }
        state.apply(update(id, source, line, final: true, start: start, end: clock))
        state.levels = [:]
        clock = clock.addingTimeInterval(2)
        try? await Task.sleep(for: .milliseconds(500))
      }
    }

    if UserDefaults.standard.bool(forKey: "alwaysOnDemoDrag") {
      Task {
        try? await Task.sleep(for: .seconds(3))
        AlwaysOnPanelController.shared.debugSimulateDrag()
        try? await Task.sleep(for: .seconds(4))
        AlwaysOnPanelController.shared.debugSimulateDrag()
      }
    }

    if let dir = UserDefaults.standard.string(forKey: "alwaysOnDemoSnapshots") {
      captureSnapshots(into: URL(fileURLWithPath: dir))
    }
  }

  private static let sampleAnswer = """
    **Say:** "I'd validate it with funnel data first, then run a focused A/B test on a shorter onboarding."

    ### Plan
    1. Compare activation rates **before vs. after** the redesign
    2. Find the step with the biggest drop-off
    3. A/B test a 3-step flow against the current one

    | Metric | Before | After |
    |---|---|---|
    | Day-7 retention | 41% | 33% |
    | Onboarding steps | 4 | 9 |

    > Tie it back to revenue impact if they push on priority.

    ```sql
    SELECT step, COUNT(*) FROM onboarding_events GROUP BY step;
    ```
    """

  private static func captureSnapshots(into dir: URL) {
    let panel = AlwaysOnPanelController.shared
    let state = AlwaysOnState.shared
    if UserDefaults.standard.bool(forKey: "alwaysOnDemoAnswers") {
      Task {
        try? await Task.sleep(for: .seconds(16))
        var sample = AssistantAnswer(id: UUID(), createdAt: Date(), trigger: .auto, model: "demo")
        sample.markdown = sampleAnswer
        sample.status = .done
        sample.firstTokenLatency = .milliseconds(412)
        state.appendAnswer(sample)
        try? await Task.sleep(for: .seconds(1))
        panel.debugSnapshot(to: dir.appendingPathComponent("5-markdown.png"))

        AssistantService.shared.ask(trigger: .auto)
        while state.answers.last?.status == .waiting { try? await Task.sleep(for: .milliseconds(50)) }
        try? await Task.sleep(for: .milliseconds(600))
        panel.debugSnapshot(to: dir.appendingPathComponent("6-streaming.png"))
        while state.answers.last?.isInProgress == true { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .milliseconds(300))
        panel.debugSnapshot(to: dir.appendingPathComponent("7-answer.png"))
        print("DEMO answer status=\(String(describing: state.answers.last?.status)) ttft=\(String(describing: state.answers.last?.firstTokenLatency))")
        print("DEMO answer markdown=\(state.answers.last?.markdown ?? "")")
      }
      return
    }
    Task {
      try? await Task.sleep(for: .seconds(4))
      panel.debugSnapshot(to: dir.appendingPathComponent("1-docked-streaming.png"))
      try? await Task.sleep(for: .seconds(12))
      panel.debugSnapshot(to: dir.appendingPathComponent("2-docked-full.png"))
      panel.toggleMinimized()
      try? await Task.sleep(for: .seconds(1))
      panel.debugSnapshot(to: dir.appendingPathComponent("3-minimized.png"))
      panel.toggleMinimized()
      try? await Task.sleep(for: .seconds(1))
      panel.debugFloat()
      try? await Task.sleep(for: .seconds(1))
      panel.debugSnapshot(to: dir.appendingPathComponent("4-floating.png"))
    }
  }

  private static func update(
    _ id: UUID, _ source: AudioSource, _ text: String, final: Bool, start: Date, end: Date
  ) -> TranscriptUpdate {
    TranscriptUpdate(
      utteranceID: id, source: source, text: text, isFinal: final,
      startedAt: start, endedAt: end, processingLatency: .zero, trailingSilence: .zero
    )
  }
}
#endif
