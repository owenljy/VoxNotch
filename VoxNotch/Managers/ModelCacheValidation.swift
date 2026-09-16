import Foundation

nonisolated enum ModelCacheValidation {
    /// Safetensors embeds the expected tensor payload lengths in its JSON header.
    /// This detects interrupted downloads even when config.json and a weight file exist.
    static func isComplete(_ directory: URL) -> Bool {
        guard let config = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
              let json = try? JSONSerialization.jsonObject(with: config) as? [String: Any],
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return false }
        func hasAsset(_ name: String) -> Bool {
            let values = try? directory.appendingPathComponent(name).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            return values?.isRegularFile == true && (values?.fileSize ?? 0) > 0
        }
        switch json["model_type"] as? String {
        case "qwen3_asr":
            guard hasAsset("tokenizer_config.json"),
                  hasAsset("tokenizer.json") || (hasAsset("vocab.json") && hasAsset("merges.txt")) else { return false }
        case "glmasr", "glm_asr":
            guard hasAsset("tokenizer_config.json"), hasAsset("tokenizer.json") else { return false }
        case "voxtral_realtime":
            guard hasAsset("tekken.json") else { return false }
        default: break
        }
        let weights = files.filter { $0.pathExtension == "safetensors" }
        guard !weights.isEmpty else { return false }
        let indexURL = directory.appendingPathComponent("model.safetensors.index.json")
        if FileManager.default.fileExists(atPath: indexURL.path) {
            guard let data = try? Data(contentsOf: indexURL),
                  let index = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let map = index["weight_map"] as? [String: String], !map.isEmpty,
                  Set(map.values).isSubset(of: Set(weights.map(\.lastPathComponent))) else { return false }
        } else if weights.count > 1 || weights.contains(where: { $0.lastPathComponent.contains("-of-") }) {
            // Sharded downloads require an index; otherwise missing shards are ambiguous.
            return false
        }
        return weights.allSatisfy(validSafetensors)
    }

    static func validSafetensors(_ url: URL) -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        guard let prefix = try? file.read(upToCount: 8), prefix.count == 8 else { return false }
        let length = prefix.enumerated().reduce(UInt64.zero) { $0 | UInt64($1.element) << ($1.offset * 8) }
        guard length > 0, length < 100_000_000, length < UInt64(size),
              let header = try? file.read(upToCount: Int(length)), header.count == Int(length),
              let tensors = try? JSONSerialization.jsonObject(with: header) as? [String: Any] else { return false }
        var ranges: [(Int, Int)] = []
        for (name, value) in tensors where name != "__metadata__" {
            guard let tensor = value as? [String: Any],
                  let offsets = tensor["data_offsets"] as? [Int], offsets.count == 2,
                  offsets[0] >= 0, offsets[1] >= offsets[0] else { return false }
            ranges.append((offsets[0], offsets[1]))
        }
        guard !ranges.isEmpty else { return false }
        var end = 0
        for range in ranges.sorted(by: { $0.0 < $1.0 }) {
            guard range.0 == end else { return false }
            end = range.1
        }
        return UInt64(end) + length + 8 == UInt64(size)
    }
}
