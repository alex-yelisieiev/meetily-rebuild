import Foundation
import SwiftUI

@MainActor
@Observable
final class MeetingDetailModel {
    let meetingId: String
    private let engine = EngineClient.shared

    var meta: MeetingMetadata?
    var lines: [TranscriptLine] = []
    var loading = true
    var loadError: String?

    var summaryMarkdown: String?
    var summaryStatus = "idle"
    var summaryError: String?
    private var summaryData: [String: Any] = [:]
    private var pollTask: Task<Void, Never>?

    /// Extra context for the AI (people involved, objective, …).
    var customPrompt = ""
    /// Per-meeting summary language; nil = Auto.
    var summaryLanguage: String?
    var editing = false
    var draft = ""
    var saving = false

    init(meetingId: String) { self.meetingId = meetingId }

    var isSummarizing: Bool { ["processing", "summarizing", "regenerating", "pending", "started"].contains(summaryStatus) }

    var duration: Double {
        lines.compactMap { $0.audio_end_time }.max() ?? 0
    }

    var transcriptText: String {
        lines.map { line in
            if let t = line.audio_start_time { return "[\(formatClock(t))] \(line.text)" }
            return line.text
        }.joined(separator: "\n")
    }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            meta = try await engine.call("api_get_meeting_metadata", ["meetingId": meetingId], as: MeetingMetadata.self)
            var all: [TranscriptLine] = []
            var offset = 0
            while true {
                let page = try await engine.call("api_get_meeting_transcripts", ["meetingId": meetingId, "limit": 500, "offset": offset], as: TranscriptPage.self)
                all += page.transcripts
                offset += page.transcripts.count
                if !page.has_more || page.transcripts.isEmpty { break }
            }
            lines = all
        } catch {
            loadError = error.localizedDescription
        }
        await loadSummary()
        summaryLanguage = Self.language(from: try? await engine.call("api_get_meeting_summary_language", ["meetingId": meetingId]))
        if isSummarizing { startPolling() }
    }

    private static func language(from raw: Any?) -> String? {
        let v = (raw as? [String: Any])?["language"] ?? raw
        guard let s = v as? String, !s.isEmpty else { return nil }
        return s.lowercased()
    }

    func setSummaryLanguage(_ code: String?) async {
        summaryLanguage = code
        if let code { Prefs.addRecentSummaryLanguage(code) }
        _ = try? await engine.call("api_save_meeting_summary_language", ["meetingId": meetingId, "summaryLanguage": code ?? NSNull()])
    }

    /// Same order as the original: per-meeting choice, pinned default, cached detection, fresh detection.
    private func resolveSummaryLanguage() async -> String? {
        if let l = summaryLanguage { return l }
        if let pinned = Prefs.summaryLanguageDefault {
            await setSummaryLanguage(pinned)
            return pinned
        }
        if let cached = Self.language(from: try? await engine.call("api_get_meeting_detected_summary_language", ["meetingId": meetingId])) {
            return cached
        }
        let texts = lines.map(\.text)
        guard let r = try? await engine.call("api_detect_transcript_summary_language", ["transcriptTexts": texts]) as? [String: Any],
              let l = Self.language(from: r) else { return nil }
        _ = try? await engine.call("api_save_meeting_detected_summary_language", ["meetingId": meetingId, "detectedSummaryLanguage": l])
        return l
    }

    func beginEditing() {
        draft = summaryMarkdown ?? ""
        editing = true
    }

    func saveEdits() async {
        saving = true
        defer { saving = false }
        var data = summaryData
        data["markdown"] = draft
        data["summary_json"] = nil
        do {
            try await engine.call("api_save_meeting_summary", ["meetingId": meetingId, "summary": data])
            summaryData = data
            summaryMarkdown = draft
            editing = false
        } catch { summaryError = error.localizedDescription }
    }

    func loadSummary() async {
        guard let r = try? await engine.call("api_get_summary", ["meetingId": meetingId]) as? [String: Any] else { return }
        summaryStatus = ((r["status"] as? String) ?? "idle").lowercased()
        summaryData = (r["data"] as? [String: Any]) ?? [:]
        summaryMarkdown = SummaryContent.markdown(from: r["data"])
        summaryError = r["error"] as? String
        if summaryMarkdown != nil && !isSummarizing { summaryStatus = "completed" }
    }

    func generateSummary(template: String) async {
        let text = lines.map(\.text).joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            summaryError = "This meeting has no transcript to summarize."; return
        }
        summaryError = nil
        editing = false
        summaryStatus = "processing"
        do {
            let cfg = try await engine.call("api_get_model_config") as? [String: Any]
            guard let provider = cfg?["provider"] as? String, let model = cfg?["model"] as? String, !model.isEmpty else {
                summaryStatus = "failed"
                summaryError = "Pick a summary model in Settings first."
                return
            }
            let language = await resolveSummaryLanguage()
            try await engine.call("api_process_transcript", [
                "text": text, "model": provider, "modelName": model, "meetingId": meetingId,
                "chunkSize": 40000, "overlap": 1000, "customPrompt": customPrompt,
                "templateId": template, "summaryLanguage": language ?? NSNull(),
            ])
            startPolling()
        } catch {
            summaryStatus = "failed"
            summaryError = error.localizedDescription
        }
    }

    func cancelSummary() async {
        try? await engine.call("api_cancel_summary", ["meetingId": meetingId])
        pollTask?.cancel()
        await loadSummary()
        if isSummarizing { summaryStatus = "cancelled" }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                guard let r = try? await engine.call("api_get_summary", ["meetingId": meetingId]) as? [String: Any] else { continue }
                let status = ((r["status"] as? String) ?? "").lowercased()
                if ["completed", "failed", "error", "cancelled"].contains(status) {
                    summaryStatus = status
                    summaryMarkdown = SummaryContent.markdown(from: r["data"]) ?? summaryMarkdown
                    if let d = r["data"] as? [String: Any] { summaryData = d }
                    summaryError = status == "completed" ? nil : ((r["error"] as? String) ?? "Summary generation \(status).")
                    return
                }
            }
        }
    }

    func stop() { pollTask?.cancel() }
}
