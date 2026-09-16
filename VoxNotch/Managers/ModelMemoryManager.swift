import Foundation

/// Applies idle/pressure policy to the actual ASR service, which owns model leases.
@MainActor
final class ModelMemoryManager {
    static let shared = ModelMemoryManager()
    var idleTimeout: TimeInterval = 300
    var autoUnloadEnabled = true
    private var idleTimer: Timer?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var unload: ((TimeInterval) -> Void)?
    private init() {}

    func start(unload: @escaping (TimeInterval) -> Void) {
        self.unload = unload
        guard idleTimer == nil else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.autoUnloadEnabled else { return }
                self.unload?(self.idleTimeout)
            }
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.unload?(0) }
        }
        source.resume()
        memoryPressureSource = source
    }

    func stopIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        unload = nil
    }
}
