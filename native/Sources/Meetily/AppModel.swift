import Foundation
import SwiftUI
import AppKit

let liveSelectionID = "__live_recording__"

@MainActor
@Observable
final class AppModel {
    enum EngineState: Equatable { case starting, ready, failed(String) }
    enum RecordingPhase: Equatable { case idle, starting, recording, paused, finishing(String) }

    static var isRecordingNow = false

    let engine = EngineClient.shared
    var engineState: EngineState = .starting
    var meetings: [Meeting] = []
    var selection: String?
    var searchText = "" { didSet { scheduleSearch() } }
    var searchHits: [SearchHit] = []
    var isSearching = false

    var phase: RecordingPhase = .idle { didSet { Self.isRecordingNow = isRecording } }
    var liveSegments: [LiveSegment] = []
    var recordingStartedAt: Date?
    var pausedAccumulated: TimeInterval = 0
    var pausedAt: Date?
    var currentMeetingName = ""

    var devices: [AudioDevice] = []
    var micDevice: String = UserDefaults.standard.string(forKey: "micDevice") ?? "" {
        didSet { UserDefaults.standard.set(micDevice, forKey: "micDevice") }
    }
    var systemDevice: String = UserDefaults.standard.string(forKey: "systemDevice") ?? "" {
        didSet { UserDefaults.standard.set(systemDevice, forKey: "systemDevice") }
    }
    var summaryTemplate: String = UserDefaults.standard.string(forKey: "summaryTemplate") ?? "standard_meeting" {
        didSet { UserDefaults.standard.set(summaryTemplate, forKey: "summaryTemplate") }
    }
    var templates: [Template] = []

    var banner: String?
    private var bannerTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var stoppedFolder: String?
    private var stoppedName: String?
    private var transcriptionCompleted = false
    /// Bumped whenever a meeting's data changes so open detail views reload.
    var detailRevision = 0

    var isRecording: Bool {
        switch phase { case .recording, .paused, .starting, .finishing: return true; case .idle: return false }
    }

    var inputDevices: [String] { devices.filter { $0.device_type == "Input" }.map(\.name) }
    var outputDevices: [String] { devices.filter { $0.device_type == "Output" }.map(\.name) }

    // MARK: Boot

    func boot() async {
        guard engineState != .ready else { return }
        engineState = .starting
        engine.onEvent = { [weak self] name, payload in self?.handle(event: name, payload: payload) }
        engine.onDisconnect = { [weak self] reason in
            self?.engineState = .failed(reason)
            self?.phase = .idle
        }
        do {
            try await engine.start()
            engineState = .ready
            await reloadMeetings()
            await loadDevices()
            templates = (try? await engine.call("api_list_templates", as: [Template].self)) ?? []
        } catch {
            engineState = .failed(error.localizedDescription)
        }
    }

    func reloadMeetings() async {
        guard let list = try? await engine.call("api_get_meetings") as? [[String: Any]] else { return }
        var result: [Meeting] = list.compactMap { d in
            guard let id = d["id"] as? String else { return nil }
            return Meeting(id: id, title: (d["title"] as? String) ?? "Untitled", createdAt: DateParsing.parse(d["created_at"] as? String))
        }
        // The list endpoint only returns id/title; fetch dates for grouping.
        await withTaskGroup(of: (String, MeetingMetadata?).self) { group in
            for m in result {
                group.addTask {
                    let meta = try? await EngineClient.shared.call("api_get_meeting_metadata", ["meetingId": m.id], as: MeetingMetadata.self)
                    return (m.id, meta)
                }
            }
            for await (id, meta) in group {
                guard let meta, let i = result.firstIndex(where: { $0.id == id }) else { continue }
                result[i].createdAt = DateParsing.parse(meta.created_at)
                result[i].folderPath = meta.folder_path
            }
        }
        result.sort { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        meetings = result
    }

    func loadDevices() async {
        devices = (try? await engine.call("get_audio_devices", as: [AudioDevice].self)) ?? []
    }

    // MARK: Search

    private func scheduleSearch() {
        searchTask?.cancel()
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { searchHits = []; isSearching = false; return }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let hits = (try? await engine.call("api_search_transcripts", ["query": q], as: [SearchHit].self)) ?? []
            guard !Task.isCancelled else { return }
            searchHits = hits
            isSearching = false
        }
    }

    // MARK: Meetings

    func rename(_ id: String, to title: String) async {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        do {
            try await engine.call("api_save_meeting_title", ["meetingId": id, "title": t])
            if let i = meetings.firstIndex(where: { $0.id == id }) { meetings[i].title = t }
        } catch { show(error) }
    }

    func delete(_ id: String) async {
        do {
            try await engine.call("api_delete_meeting", ["meetingId": id])
            meetings.removeAll { $0.id == id }
            if selection == id { selection = nil }
        } catch { show(error) }
    }

    func revealInFinder(_ id: String) {
        if let path = meetings.first(where: { $0.id == id })?.folderPath, FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            Task { do { try await engine.call("open_meeting_folder", ["meetingId": id]) } catch { show(error) } }
        }
    }

    // MARK: Recording

    func toggleRecording() async {
        switch phase {
        case .idle: await startRecording()
        case .recording, .paused: await stopRecording()
        default: break
        }
    }

    func startRecording() async {
        guard phase == .idle, engineState == .ready else { return }
        liveSegments = []
        stoppedFolder = nil
        stoppedName = nil
        transcriptionCompleted = false
        pausedAccumulated = 0
        pausedAt = nil
        let f = DateFormatter()
        f.dateFormat = "dd_MM_yy_HH_mm_ss"
        currentMeetingName = "Meeting " + f.string(from: Date())
        phase = .starting
        selection = liveSelectionID
        do {
            try await engine.call("start_recording_with_devices_and_meeting", [
                "micDeviceName": micDevice.isEmpty ? NSNull() : micDevice,
                "systemDeviceName": systemDevice.isEmpty ? NSNull() : systemDevice,
                "meetingName": currentMeetingName,
            ])
            recordingStartedAt = Date()
            phase = .recording
        } catch {
            phase = .idle
            selection = nil
            show(error)
        }
    }

    func togglePause() async {
        do {
            if phase == .recording {
                try await engine.call("pause_recording")
                pausedAt = Date()
                phase = .paused
            } else if phase == .paused {
                try await engine.call("resume_recording")
                if let p = pausedAt { pausedAccumulated += Date().timeIntervalSince(p) }
                pausedAt = nil
                phase = .recording
            }
        } catch { show(error) }
    }

    func elapsed(at now: Date) -> TimeInterval {
        guard let start = recordingStartedAt else { return 0 }
        let pausedNow = pausedAt.map { now.timeIntervalSince($0) } ?? 0
        return now.timeIntervalSince(start) - pausedAccumulated - pausedNow
    }

    func stopRecording() async {
        guard phase == .recording || phase == .paused else { return }
        phase = .finishing("Stopping…")
        do {
            let ts = Int(Date().timeIntervalSince1970 * 1000)
            try await engine.call("stop_recording", ["args": ["save_path": "\(engine.dataDir)/recording-\(ts).wav"]])
        } catch {
            show(error)
        }

        // Let the transcriber drain whatever is still queued.
        let deadline = Date().addingTimeInterval(90)
        var drained = false
        while Date() < deadline {
            if transcriptionCompleted { drained = true; break }
            if let s = try? await engine.call("get_transcription_status") as? [String: Any] {
                let queued = (s["chunks_in_queue"] as? Int) ?? 0
                let busy = (s["is_processing"] as? Bool) ?? false
                let idleMs = (s["last_activity_ms"] as? Int) ?? 0
                if queued == 0 && (!busy || idleMs > 8000) { drained = true; break }
                phase = .finishing(queued > 0 ? "Transcribing the last \(queued) chunk\(queued == 1 ? "" : "s")…" : "Finishing transcription…")
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        if drained { try? await Task.sleep(for: .seconds(3)) }
        for _ in 0..<12 where stoppedFolder == nil { try? await Task.sleep(for: .milliseconds(250)) }

        phase = .finishing("Saving meeting…")
        let segments = liveSegments
            .filter { !$0.isPartial && !$0.text.isEmpty }
            .sorted { $0.start == $1.start ? $0.sequence < $1.sequence : $0.start < $1.start }
        guard !segments.isEmpty else {
            phase = .idle
            selection = nil
            flash("Nothing was transcribed, so there's no meeting to save.")
            return
        }
        let payload: [[String: Any]] = segments.map {
            ["id": "seg-\($0.sequence)", "text": $0.text, "timestamp": $0.timestamp,
             "audio_start_time": $0.start, "audio_end_time": $0.end, "duration": $0.duration]
        }
        do {
            let result = try await engine.call("api_save_transcript", [
                "meetingTitle": stoppedName ?? currentMeetingName,
                "transcripts": payload,
                "folderPath": stoppedFolder.map { $0 as Any } ?? NSNull(),
            ]) as? [String: Any]
            await reloadMeetings()
            phase = .idle
            liveSegments = []
            selection = (result?["meeting_id"] as? String) ?? meetings.first?.id
        } catch {
            phase = .idle
            show(error)
        }
    }

    // MARK: Events

    private func handle(event: String, payload: Any) {
        switch event {
        case "transcript-update":
            guard var seg = LiveSegment(payload: payload), !seg.text.isEmpty else { return }
            if let i = liveSegments.firstIndex(where: { $0.sequence == seg.sequence }) {
                liveSegments[i] = seg
            } else {
                // A final segment replaces the trailing partial preview.
                if !seg.isPartial, let last = liveSegments.last, last.isPartial { liveSegments.removeLast() }
                if seg.isPartial, let last = liveSegments.last, last.isPartial {
                    seg = LiveSegment(copying: seg); liveSegments[liveSegments.count - 1] = seg
                } else {
                    liveSegments.append(seg)
                }
            }
        case "recording-stopped":
            if let d = payload as? [String: Any] {
                stoppedFolder = d["folder_path"] as? String
                stoppedName = d["meeting_name"] as? String
            }
        case "transcription-complete":
            transcriptionCompleted = true
        case "recording-paused":
            if phase == .recording { pausedAt = Date(); phase = .paused }
        case "recording-resumed":
            if phase == .paused { if let p = pausedAt { pausedAccumulated += Date().timeIntervalSince(p) }; pausedAt = nil; phase = .recording }
        case "recording-error", "transcription-error", "transcript-error", "mic-unavailable", "mic-swap-failed", "mic-recovery-exhausted":
            flash(EngineClient.describe(payload))
        case "mic-device-switched", "microphone-recovered":
            Task { await loadDevices() }
        case "request-recording-toggle":
            Task { await toggleRecording() }
        default:
            break
        }
    }

    // MARK: Banner

    func show(_ error: Error) { flash(error.localizedDescription) }

    func flash(_ message: String) {
        bannerTask?.cancel()
        withAnimation(.snappy) { banner = message }
        bannerTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { banner = nil }
        }
    }
}

extension LiveSegment {
    init(copying other: LiveSegment) { self = other }
}
