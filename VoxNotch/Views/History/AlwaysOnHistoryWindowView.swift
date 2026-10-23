//
//  AlwaysOnHistoryWindowView.swift
//  VoxNotch
//
//  Browse, search, rename, copy, and delete persisted Always-On sessions.
//

import SwiftUI
import os.log

@available(macOS 26.0, *)
struct AlwaysOnHistoryWindowView: View {

  @State private var sessions: [AlwaysOnSessionRecord] = []
  @State private var selectedSession: AlwaysOnSessionRecord?
  @State private var searchText = ""
  @State private var isLoading = false
  @State private var loadRequestID = UUID()
  @State private var showDeleteConfirmation = false
  @State private var sessionToDelete: AlwaysOnSessionRecord?

  var body: some View {
    NavigationSplitView {
      sidebarContent
    } detail: {
      detailContent
    }
    .navigationTitle("Always-On History")
    .searchable(text: $searchText, prompt: "Search transcripts and answers")
    .task(id: searchText) { await loadSessions() }
    .confirmationDialog(
      "Delete Always-On session?",
      isPresented: $showDeleteConfirmation,
      presenting: sessionToDelete
    ) { session in
      Button("Delete", role: .destructive) { Task { await delete(session) } }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("This permanently deletes the saved transcript and AI answers for this session.")
    }
    .toolbar {
      ToolbarItem {
        Button { Task { await loadSessions() } } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
      }
    }
  }

  @ViewBuilder
  private var sidebarContent: some View {
    if isLoading {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if sessions.isEmpty {
      ContentUnavailableView {
        Label(searchText.isEmpty ? "No Always-On Sessions" : "No Results", systemImage: "captions.bubble")
      } description: {
        Text(searchText.isEmpty ? "Saved Always-On sessions will appear here." : "Try a different search term.")
      }
      .frame(minWidth: 300)
    } else {
      List(selection: $selectedSession) {
        ForEach(groupedSessions, id: \.key) { group in
          Section(group.key) {
            ForEach(group.records) { session in
              AlwaysOnSessionRow(session: session)
                .tag(session)
                .privacyAwareContextMenu {
                  Button("Copy Session") { Task { await copy(session) } }
                  Divider()
                  Button("Delete", role: .destructive) {
                    sessionToDelete = session
                    showDeleteConfirmation = true
                  }
                }
            }
          }
        }
      }
      .listStyle(.sidebar)
      .frame(minWidth: 300)
    }
  }

  @ViewBuilder
  private var detailContent: some View {
    if let selectedSession {
      AlwaysOnSessionDetailView(session: selectedSession) { updated in
        replaceSession(updated)
      }
      .id(selectedSession.id)
    } else {
      ContentUnavailableView {
        Label("Select a Session", systemImage: "text.bubble")
      } description: {
        Text("Choose a saved Always-On session to view its transcript and AI answers.")
      }
    }
  }

  private var groupedSessions: [SessionDateGroup] {
    let calendar = Calendar.current
    let grouped = Dictionary(grouping: sessions) { calendar.startOfDay(for: $0.startedAt) }
    return grouped.sorted { $0.key > $1.key }.map { date, records in
      SessionDateGroup(key: Self.sectionDateFormatter.string(from: date), records: records)
    }
  }

  private static let sectionDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.doesRelativeDateFormatting = true
    f.dateStyle = .medium
    f.timeStyle = .none
    return f
  }()

  private func loadSessions() async {
    let requestID = UUID()
    loadRequestID = requestID
    isLoading = true
    defer { if loadRequestID == requestID { isLoading = false } }
    do {
      let loaded = try await AlwaysOnHistoryStore.shared.sessions(matching: searchText)
      guard !Task.isCancelled, loadRequestID == requestID else { return }
      sessions = loaded
      if let selectedSession, !sessions.contains(where: { $0.id == selectedSession.id }) {
        self.selectedSession = nil
      }
    } catch {
      guard !Task.isCancelled, loadRequestID == requestID else { return }
      sessions = []
      Logger(subsystem: "com.voxnotch", category: "AlwaysOnHistoryWindowView").error("Failed to load sessions: \(error.localizedDescription)")
    }
  }

  private func replaceSession(_ updated: AlwaysOnSessionRecord) {
    if let index = sessions.firstIndex(where: { $0.id == updated.id }) {
      sessions[index] = updated
    }
    if selectedSession?.id == updated.id {
      selectedSession = updated
    }
  }

  private func delete(_ session: AlwaysOnSessionRecord) async {
    do {
      try await AlwaysOnHistoryStore.shared.deleteSession(id: session.id)
      sessions.removeAll { $0.id == session.id }
      if selectedSession?.id == session.id { selectedSession = nil }
    } catch {
      Logger(subsystem: "com.voxnotch", category: "AlwaysOnHistoryWindowView").error("Failed to delete session: \(error.localizedDescription)")
    }
  }

  private func copy(_ session: AlwaysOnSessionRecord) async {
    do {
      let text = try await AlwaysOnHistoryTextExporter.text(for: session)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    } catch {
      Logger(subsystem: "com.voxnotch", category: "AlwaysOnHistoryWindowView").error("Failed to copy session: \(error.localizedDescription)")
    }
  }
}

private struct SessionDateGroup {
  let key: String
  let records: [AlwaysOnSessionRecord]
}

@available(macOS 26.0, *)
private struct AlwaysOnSessionRow: View {
  let session: AlwaysOnSessionRecord

  var body: some View {
    VStack(alignment: .leading, spacing: InterfaceScale.Space.small) {
      Text(title)
        .font(InterfaceScale.Typography.body)
        .lineLimit(1)
      HStack(spacing: InterfaceScale.Space.medium) {
        AlwaysOnMetadataPill(icon: "clock", text: relativeStart)
        AlwaysOnMetadataPill(icon: "waveform", text: sources)
        if !session.closedCleanly, session.endedAt != nil {
          AlwaysOnMetadataPill(icon: "exclamationmark.triangle", text: "Recovered", tint: .orange)
        }
        Spacer()
        Text(durationText)
          .font(InterfaceScale.Typography.caption)
          .foregroundStyle(.tertiary)
          .monospacedDigit()
      }
    }
    .padding(.vertical, InterfaceScale.Space.small)
  }

  private var title: String {
    if let title = session.title, !title.isEmpty { return title }
    return Self.titleFormatter.string(from: session.startedAt)
  }

  private var relativeStart: String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: session.startedAt, relativeTo: Date())
  }

  private var sources: String {
    let labels = session.sourceList.map { $0 == .microphone ? "Me" : "Them" }
    return labels.isEmpty ? "No audio" : labels.joined(separator: " + ")
  }

  private var durationText: String {
    guard let endedAt = session.endedAt else { return "running" }
    let seconds = max(0, Int(endedAt.timeIntervalSince(session.startedAt)))
    let m = seconds / 60
    let s = seconds % 60
    return m > 0 ? "\(m)m \(s)s" : "\(s)s"
  }

  private static let titleFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .none
    f.timeStyle = .short
    return f
  }()
}

@available(macOS 26.0, *)
private struct AlwaysOnSessionDetailView: View {
  let session: AlwaysOnSessionRecord
  let onRename: (AlwaysOnSessionRecord) -> Void

  @State private var segments: [AlwaysOnSegmentRecord] = []
  @State private var answers: [AlwaysOnAnswerRecord] = []
  @State private var titleText = ""

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: InterfaceScale.Space.large) {
        header
        Divider()
        if timeline.isEmpty {
          ContentUnavailableView("Empty Session", systemImage: "text.bubble", description: Text("No final transcript or AI answers were saved for this session."))
            .frame(maxWidth: .infinity)
        } else {
          ForEach(timeline) { item in
            switch item.kind {
            case .segment(let segment):
              historySegmentView(segment)
            case .answer(let answer):
              historyAnswerView(answer)
            }
          }
        }
      }
      .padding(InterfaceScale.Space.large)
      .textSelection(.enabled)
    }
    .task { await loadDetail() }
    .toolbar {
      ToolbarItem {
        Button { Task { await copyFullText() } } label: {
          Label("Copy", systemImage: "doc.on.doc")
        }
      }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: InterfaceScale.Space.medium) {
      TextField("Session title", text: $titleText)
        .font(InterfaceScale.Typography.title)
        .textFieldStyle(.roundedBorder)
        .onSubmit { Task { await saveTitle() } }
      Text(dateRange)
        .font(InterfaceScale.Typography.body)
        .foregroundStyle(.secondary)
      HStack(spacing: InterfaceScale.Space.medium) {
        AlwaysOnDetailBadge(icon: "waveform", text: sourceText)
        AlwaysOnDetailBadge(icon: "text.bubble", text: "\(segments.count) turns")
        AlwaysOnDetailBadge(icon: "sparkles", text: "\(answers.count) answers", tint: .purple)
        if !session.closedCleanly, session.endedAt != nil {
          AlwaysOnDetailBadge(icon: "exclamationmark.triangle", text: "Recovered after crash", tint: .orange)
        }
      }
    }
  }

  private var timeline: [TimelineItem] {
    let segmentItems = segments.map { TimelineItem(time: $0.startedAt, kind: .segment($0)) }
    let answerItems = answers.map { TimelineItem(time: $0.createdAt, kind: .answer($0)) }
    return (segmentItems + answerItems).sorted { $0.time < $1.time }
  }

  private var dateRange: String {
    let formatter = DateFormatter()
    formatter.dateStyle = .full
    formatter.timeStyle = .medium
    let start = formatter.string(from: session.startedAt)
    guard let endedAt = session.endedAt else { return "Started \(start) · still open" }
    return "\(start) – \(formatter.string(from: endedAt))"
  }

  private var sourceText: String {
    let labels = session.sourceList.map { $0 == .microphone ? "Microphone" : "System audio" }
    return labels.isEmpty ? "No sources" : labels.joined(separator: " + ")
  }

  private func historySegmentView(_ segment: AlwaysOnSegmentRecord) -> some View {
    VStack(alignment: .leading, spacing: InterfaceScale.Space.small) {
      Label(segment.audioSource == .microphone ? "Me" : "Them", systemImage: segment.audioSource == .microphone ? "mic.fill" : "speaker.wave.2.fill")
        .font(InterfaceScale.Typography.caption)
        .foregroundStyle(segment.audioSource == .microphone ? .green : .blue)
      Text(segment.text)
        .font(InterfaceScale.Typography.body)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(InterfaceScale.Space.medium)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.secondary.opacity(0.05))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private func historyAnswerView(_ answer: AlwaysOnAnswerRecord) -> some View {
    VStack(alignment: .leading, spacing: InterfaceScale.Space.small) {
      HStack {
        Label(answer.templateName.isEmpty ? "AI answer" : answer.templateName, systemImage: "sparkles")
          .font(InterfaceScale.Typography.caption)
          .foregroundStyle(.purple)
        Spacer()
        Text(answer.status)
          .font(InterfaceScale.Typography.caption)
          .foregroundStyle(.secondary)
      }
      Text(.init(answer.markdown))
        .font(InterfaceScale.Typography.body)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(InterfaceScale.Space.medium)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.purple.opacity(0.06))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private func loadDetail() async {
    titleText = session.title ?? ""
    do {
      async let loadedSegments = AlwaysOnHistoryStore.shared.segments(for: session.id)
      async let loadedAnswers = AlwaysOnHistoryStore.shared.answers(for: session.id)
      segments = try await loadedSegments
      answers = try await loadedAnswers
    } catch {
      segments = []
      answers = []
      Logger(subsystem: "com.voxnotch", category: "AlwaysOnSessionDetailView").error("Failed to load session detail: \(error.localizedDescription)")
    }
  }

  private func saveTitle() async {
    do {
      try await AlwaysOnHistoryStore.shared.renameSession(id: session.id, title: titleText)
      var updated = session
      let trimmed = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
      updated.title = trimmed.isEmpty ? nil : trimmed
      onRename(updated)
    } catch {
      Logger(subsystem: "com.voxnotch", category: "AlwaysOnSessionDetailView").error("Failed to rename session: \(error.localizedDescription)")
    }
  }

  private func copyFullText() async {
    do {
      let text = try await AlwaysOnHistoryTextExporter.text(for: session)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    } catch {
      Logger(subsystem: "com.voxnotch", category: "AlwaysOnSessionDetailView").error("Failed to copy session: \(error.localizedDescription)")
    }
  }
}

private struct TimelineItem: Identifiable {
  enum Kind {
    case segment(AlwaysOnSegmentRecord)
    case answer(AlwaysOnAnswerRecord)
  }

  var id: String {
    switch kind {
    case .segment(let segment): "segment-\(segment.id)"
    case .answer(let answer): "answer-\(answer.id)"
    }
  }
  let time: Date
  let kind: Kind
}

private struct AlwaysOnMetadataPill: View {
  let icon: String
  let text: String
  var tint: Color? = nil

  var body: some View {
    HStack(spacing: InterfaceScale.Space.small) {
      Image(systemName: icon)
        .font(.system(size: 9))
      Text(text)
        .font(InterfaceScale.Typography.caption)
        .lineLimit(1)
    }
    .foregroundStyle(tint ?? .secondary)
  }
}

private struct AlwaysOnDetailBadge: View {
  let icon: String
  let text: String
  var tint: Color? = nil

  var body: some View {
    HStack(spacing: InterfaceScale.Space.small) {
      Image(systemName: icon)
        .font(.system(size: 10))
      Text(text)
        .font(InterfaceScale.Typography.caption)
    }
    .foregroundStyle(tint ?? .secondary)
    .padding(.horizontal, InterfaceScale.Space.medium)
    .padding(.vertical, InterfaceScale.Space.small)
    .background((tint ?? .secondary).opacity(0.08))
    .clipShape(Capsule())
  }
}

enum AlwaysOnHistoryTextExporter {
  static func text(for session: AlwaysOnSessionRecord) async throws -> String {
    async let segments = AlwaysOnHistoryStore.shared.segments(for: session.id)
    async let answers = AlwaysOnHistoryStore.shared.answers(for: session.id)
    let timeline = try await segments.map { TimelineItem(time: $0.startedAt, kind: .segment($0)) }
      + answers.map { TimelineItem(time: $0.createdAt, kind: .answer($0)) }
    let sorted = timeline.sorted { $0.time < $1.time }
    let title = session.title?.isEmpty == false ? session.title! : "Always-On session \(session.startedAt)"
    var lines = [title]
    for item in sorted {
      switch item.kind {
      case .segment(let segment):
        let speaker = segment.audioSource == .microphone ? "Me" : "Them"
        lines.append("\n\(speaker): \(segment.text)")
      case .answer(let answer):
        lines.append("\nCopilot (\(answer.status)):\n\(answer.markdown)")
      }
    }
    return lines.joined(separator: "\n")
  }
}
