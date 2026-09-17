import Foundation

/// Check compiled CoreML bundles, not just the existence of their directories.
nonisolated enum FluidModelCache {
  static func isComplete(_ directory: URL, required: Set<String>) -> Bool {
    func hasData(_ path: URL) -> Bool {
      let values = try? path.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      return values?.isRegularFile == true && (values?.fileSize ?? 0) > 0
    }
    for name in required {
      let path = directory.appendingPathComponent(name)
      if path.pathExtension == "mlmodelc" {
        guard ["coremldata.bin", "model.mil", "weights/weight.bin"].allSatisfy({
          hasData(path.appendingPathComponent($0))
        }) else { return false }
      } else {
        guard hasData(path) else { return false }
        if path.pathExtension == "json" {
          guard let data = try? Data(contentsOf: path),
                (try? JSONSerialization.jsonObject(with: data)) != nil else { return false }
        }
      }
    }
    guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return false }
    for case let file as URL in files where file.pathExtension == "partial" { return false }
    return !required.isEmpty
  }
}
