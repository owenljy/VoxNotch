import Foundation
import CryptoKit

/// Populate a flat SDK cache without the pinned Hub client's nested-file/Xet path.
nonisolated enum HFModelDownload {
    private struct Repository: Decodable {
        let sha: String
        let siblings: [File]
    }
    private struct File: Decodable {
        let rfilename: String
        let size: Int64?
        let lfs: LFS?
    }
    private struct LFS: Decodable { let sha256: String }

    static func ensureCached(repoID: String, directory: URL) async throws {
        if ModelCacheValidation.isComplete(directory) { return }
        let parts = repoID.split(separator: "/")
        guard parts.count == 2, parts.allSatisfy({ $0.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil }),
              let metadataURL = URL(string: "https://huggingface.co/api/models/\(repoID)?blobs=true") else {
            throw MLXAudioError.modelDownloadFailed("Invalid model repository")
        }
        var request = URLRequest(url: metadataURL)
        request.timeoutInterval = 30
        authorize(&request)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw MLXAudioError.modelDownloadFailed("Could not fetch model file list")
        }
        let repository = try JSONDecoder().decode(Repository.self, from: data)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let extensions: Set<String> = ["safetensors", "json", "txt", "model"]
        for file in repository.siblings where extensions.contains((file.rfilename as NSString).pathExtension) {
            try Task.checkCancellation()
            // Model assets must stay inside this repository's cache.
            guard !file.rfilename.hasPrefix("/"),
                  !file.rfilename.split(separator: "/").contains("..") else {
                throw MLXAudioError.modelDownloadFailed("Invalid model file path")
            }
            let destination = directory.appendingPathComponent(file.rfilename)
            try repairNestedFile(at: destination)
            if matches(file, at: destination) { continue }
            let base = URL(string: "https://huggingface.co/\(repoID)/resolve/\(repository.sha)/")!
            var downloadRequest = URLRequest(url: base.appendingPathComponent(file.rfilename))
            downloadRequest.timeoutInterval = 600
            authorize(&downloadRequest)
            let (temporary, response) = try await URLSession.shared.download(for: downloadRequest)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard (response as? HTTPURLResponse)?.statusCode == 200, matches(file, at: temporary) else {
                throw MLXAudioError.modelDownloadFailed("Incomplete or invalid download: \(file.rfilename)")
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        }
        guard ModelCacheValidation.isComplete(directory) else {
            throw MLXAudioError.modelDownloadFailed("Model cache is incomplete")
        }
    }

    static func authorize(_ request: inout URLRequest) {
        if let token = ProcessInfo.processInfo.environment["HF_TOKEN"]
            ?? Bundle.main.object(forInfoDictionaryKey: "HF_TOKEN") as? String, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    static func repairNestedFile(at destination: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue {
            // Repair the old downloader's filename/filename layout.
            let nested = destination.appendingPathComponent(destination.lastPathComponent)
            if FileManager.default.fileExists(atPath: nested.path) {
                let staging = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
                try FileManager.default.moveItem(at: nested, to: staging)
                try FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: staging, to: destination)
            } else {
                try FileManager.default.removeItem(at: destination)
            }
        }
    }

    private static func matches(_ file: File, at url: URL) -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, file.size.map({ Int64(size) == $0 }) ?? true else { return false }
        guard let expected = file.lfs?.sha256 else { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var hash = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
                hash.update(data: chunk)
            }
        } catch { return false }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == expected
    }
}
