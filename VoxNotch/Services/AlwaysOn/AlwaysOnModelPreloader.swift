import FluidAudio
import Foundation

@MainActor
enum AlwaysOnModelPreloader {
  static let cache = PreparedModelCache<LiveTranscriber.PreparedModels> {
    let asr: AsrManager
    let existing = await MainActor.run { FluidAudioModelManager.shared.getLoadedModel(for: .v2English) }
    if case .tdt(let loaded)? = existing {
      asr = loaded
    } else {
      let models = try await AsrModels.downloadAndLoad(version: .v2)
      let manager = AsrManager()
      try await manager.loadModels(models)
      asr = manager
    }
    return try await LiveTranscriber.prepareModels(asr: asr)
  }

  private static var pressureSource: DispatchSourceMemoryPressure?

  static func models() async throws -> LiveTranscriber.PreparedModels {
    installPressureHandler()
    return try await cache.models()
  }

  static func preloadAtLaunch() {
    // Tests and synthetic UI demos must never start model downloads/inference.
    guard NSClassFromString("XCTestCase") == nil,
          ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
          !UserDefaults.standard.bool(forKey: "alwaysOnDemo"),
          AssistantSettings.shared.preloadTranscriptionOnLaunch else { return }
    installPressureHandler()
    // Onboarding downloads Parakeet v2 by default. Don't silently download a
    // second ~500 MB ASR model if the user chose a different dictation engine.
    guard FluidAudioModelManager.shared.isVersionDownloaded(.v2English) else { return }
    cache.preload()
  }

  static func prepareNow() {
    installPressureHandler()
    cache.preload()
  }

  private static func installPressureHandler() {
    guard pressureSource == nil else { return }
    let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
    source.setEventHandler {
      MainActor.assumeIsolated { cache.release() }
    }
    source.resume()
    pressureSource = source
  }
}
