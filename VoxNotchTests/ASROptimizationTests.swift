import XCTest
import AppKit
import MLX
import Metal
import MLXAudioSTT
@testable import VoxNotch

final class ASROptimizationTests: XCTestCase {
    @MainActor
    func testCustomModelIgnoresStalePersistedDownloadFlag() {
        var model = CustomSpeechModel(displayName: "Missing cache", hfRepoID: "voxnotch-tests/\(UUID().uuidString)")
        model.isDownloaded = true
        XCTAssertFalse(MLXAudioModelManager.shared.isCustomModelOnDisk(model))
        XCTAssertFalse(AnyModel.custom(model).isDownloaded)
    }

    func testLanguagePromptAndAutoOutput() {
        XCTAssertEqual(ASRLanguage.assistantPrefix(language: "zh-CN"), "language Chinese<asr_text>")
        XCTAssertEqual(ASRLanguage.assistantPrefix(language: "ja"), "language Japanese<asr_text>")
        XCTAssertEqual(ASRLanguage.assistantPrefix(language: "auto"), "")
        XCTAssertEqual(ASRLanguage.assistantPrefix(language: nil), "")
        let parsed = ASRLanguage.parse("language Chinese<asr_text>你好，Swift。", forcedLanguage: nil)
        XCTAssertEqual(parsed.text, "你好，Swift。")
        XCTAssertEqual(parsed.language, "zh")
    }

    func testCancelledInferenceDoesNotStart() {
        let cancellation = ASRCancellation()
        XCTAssertNoThrow(try cancellation.check())
        cancellation.cancel()
        XCTAssertThrowsError(try cancellation.check()) { XCTAssertTrue($0 is CancellationError) }
    }

    func testSegmenterPreservesEverySampleAndFlushesTail() {
        let input = (0..<420123).map { Float($0 % 100) / 100 }
        var segmenter = RecordingSegmenter()
        var segments: [[Float]] = []
        for start in stride(from: 0, to: input.count, by: 1024) {
            segments += segmenter.append(Array(input[start..<min(start + 1024, input.count)]))
        }
        XCTAssertGreaterThan(segments.count, 0, "Inference can begin before recording ends")
        segments.append(segmenter.finish())
        XCTAssertEqual(segments.flatMap { $0 }, input)
        XCTAssertTrue(segmenter.finish().isEmpty)
        XCTAssertTrue(segments.allSatisfy { $0.count <= 192000 })
    }

    func testSegmenterUsesPauseBoundary() {
        var segmenter = RecordingSegmenter()
        XCTAssertTrue(segmenter.append(Array(repeating: 0.1, count: 48000)).isEmpty)
        let segments = segmenter.append(Array(repeating: 0, count: 6400))
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.count, 54400)
    }

    func testRecordingSessionDecodesBeforeStopAndFlushesTail() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Segment inference requires a Metal device; run on an Apple Silicon Mac.")
        }
        let decoded = expectation(description: "decoded while recording")
        let model = FakeRecordingModel(onFirstDecode: { decoded.fulfill() })
        let handle = ASRModelHandle(model: model)
        let session = RecordingTranscriptionSession(language: "zh") { handle }
        session.append(Array(repeating: 0.1, count: 48000))
        session.append(Array(repeating: 0, count: 6400))
        await fulfillment(of: [decoded], timeout: 3)
        session.append(Array(repeating: 0.1, count: 8000))
        let result = try await session.finish()
        XCTAssertEqual(result.text, "segment1 segment2")
        XCTAssertEqual(result.audioDuration, 3.9, accuracy: 0.001)
    }

    func testRecordingSessionCancellationRejectsResult() async throws {
        let handle = ASRModelHandle(model: FakeRecordingModel(onFirstDecode: {}))
        let session = RecordingTranscriptionSession(language: nil) { handle }
        session.append(Array(repeating: 0.1, count: 8000))
        session.cancel()
        do {
            _ = try await session.finish()
            XCTFail("Cancelled recording must not produce output")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor
    func testClipboardRestoresRichDataAndDoesNotClobberNewCopy() {
        let pasteboard = NSPasteboard(name: .init("voxnotch-test-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("original", forType: .string)
        item.setData(Data([1, 2, 3]), forType: .png)
        pasteboard.writeObjects([item])
        let snapshot = ClipboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("transcript", forType: .string)
        snapshot.restore(to: pasteboard, ifUnchangedSince: pasteboard.changeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
        XCTAssertEqual(pasteboard.data(forType: .png), Data([1, 2, 3]))
        let count = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString("new user copy", forType: .string)
        snapshot.restore(to: pasteboard, ifUnchangedSince: count)
        XCTAssertEqual(pasteboard.string(forType: .string), "new user copy")
    }

    func testRepairsLegacyNestedDownloadWithoutLosingConfig() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = root.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = Data(#"{"model_type":"qwen3_asr"}"#.utf8)
        try config.write(to: destination.appendingPathComponent("config.json"))
        try HFModelDownload.repairNestedFile(at: destination)
        XCTAssertEqual(try Data(contentsOf: destination), config)
        // Already-flat downloads remain untouched on later launches.
        try HFModelDownload.repairNestedFile(at: destination)
        XCTAssertEqual(try Data(contentsOf: destination), config)
    }

    func testCacheRejectsConfigOnlyAndTruncatedWeights() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
        XCTAssertFalse(ModelCacheValidation.isComplete(folder))
        let header = Data(#"{"tensor":{"dtype":"F32","shape":[1],"data_offsets":[0,4]}}"#.utf8)
        var length = UInt64(header.count).littleEndian
        var weight = withUnsafeBytes(of: &length) { Data($0) }
        weight.append(header)
        weight.append(Data([0, 0]))
        let url = folder.appendingPathComponent("model.safetensors")
        try weight.write(to: url)
        XCTAssertFalse(ModelCacheValidation.isComplete(folder))
        weight.append(Data([0, 0]))
        try weight.write(to: url)
        XCTAssertTrue(ModelCacheValidation.isComplete(folder))
        let configURL = folder.appendingPathComponent("config.json")
        try Data(#"{"model_type":"qwen3_asr"}"#.utf8).write(to: configURL)
        XCTAssertFalse(ModelCacheValidation.isComplete(folder), "Weights alone do not make a Qwen cache ready")
        for name in ["tokenizer_config.json", "vocab.json", "merges.txt"] {
            try Data("{}".utf8).write(to: folder.appendingPathComponent(name))
        }
        XCTAssertTrue(ModelCacheValidation.isComplete(folder))
        let index = Data(#"{"weight_map":{"tensor":"missing.safetensors"}}"#.utf8)
        try index.write(to: folder.appendingPathComponent("model.safetensors.index.json"))
        XCTAssertFalse(ModelCacheValidation.isComplete(folder))
    }
}


nonisolated private final class FakeRecordingModel: STTGenerationModel, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let onFirstDecode: @Sendable () -> Void
    init(onFirstDecode: @escaping @Sendable () -> Void) { self.onFirstDecode = onFirstDecode }
    var defaultGenerationParameters: STTGenerateParameters { .init() }
    func generate(audio: MLXArray, generationParameters: STTGenerateParameters) -> STTOutput {
        let index = lock.withLock { count += 1; return count }
        if index == 1 { onFirstDecode() }
        return STTOutput(text: "segment\(index)")
    }
    func generateStream(audio: MLXArray, generationParameters: STTGenerateParameters) -> AsyncThrowingStream<STTGeneration, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
