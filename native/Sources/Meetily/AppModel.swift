import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
    var meetingsLoaded = false
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
    /// The engine's recording_preferences.json (devices carry " (input)" / " (output)" suffixes).
    var recordingPrefs: [String: Any] = [:]
    var micDevice: String { Self.bare(recordingPrefs["preferred_mic_device"]) }
    var systemDevice: String { Self.bare(recordingPrefs["preferred_system_device"]) }
    var summaryTemplate: String = Prefs.summaryTemplate { didSet { Prefs.summaryTemplate = summaryTemplate } }
    var primaryLanguage: String = Prefs.primaryLanguage {
        didSet {
            Prefs.primaryLanguage = primaryLanguage
            Task { try? await engine.call("set_language_preference", ["language": primaryLanguage]) }
        }
    }
    var isAutoSummary: Bool = Prefs.isAutoSummary { didSet { Prefs.isAutoSummary = isAutoSummary } }
    var importAndRetranscribe: Bool = Prefs.importAndRetranscribe { didSet { Prefs.importAndRetranscribe = importAndRetranscribe } }
    var templates: [Template] = []

    /// Meetings that should get a summary as soon as their detail view opens.
    var autoSummaryPending: Set<String> = []
    var importJob: ImportJob?
    var retranscribeJobs: [String: JobProgress] = [:]
    /// Download progress keyed by "<kind>:<model>", e.g. "whisper:large-v3".
    var downloads: [String: Double] = [:]
    var downloadRevision = 0
    var audioLevels: [String: Double] = [:]
    var recovery: PendingRecording.Snapshot?
    private var snapshotTask: Task<Void, Never>?
    private var currentFolder: String?

    struct JobProgress: Equatable { var percent: Double; var message: String; var failed: String? }
    struct ImportJob: Equatable {
        var path: String; var filename: String; var duration: Double
        var title: String; var running = false; var progress: JobProgress?
    }

    static func bare(_ v: Any?) -> String {
        guard let s = v as? String else { return "" }
        for suffix in [" (input)", " (output)"] where s.hasSuffix(suffix) { return String(s.dropLast(suffix.count)) }
        return s
    }

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
            try? await engine.call("set_language_preference", ["language": primaryLanguage])
            await loadRecordingPrefs()
            recovery = PendingRecording.load()
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
        meetingsLoaded = true
    }

    func loadRecordingPrefs() async {
        if let p = try? await engine.call("get_recording_preferences") as? [String: Any] { recordingPrefs = p }
    }

    func setRecordingPref(_ key: String, _ value: Any?) async {
        var p = recordingPrefs
        p[key] = value ?? NSNull()
        do {
            try await engine.call("set_recording_preferences", ["preferences": p])
            recordingPrefs = p
        } catch { show(error) }
    }

    func setMic(_ name: String) async { await setRecordingPref("preferred_mic_device", name.isEmpty ? nil : "\(name) (input)") }
    func setSystemAudio(_ name: String) async { await setRecordingPref("preferred_system_device", name.isEmpty ? nil : "\(name) (output)") }

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
                "micDeviceName": recordingPrefs["preferred_mic_device"] as? String ?? NSNull(),
                "systemDeviceName": recordingPrefs["preferred_system_device"] as? String ?? NSNull(),
                "meetingName": currentMeetingName,
            ])
            recordingStartedAt = Date()
            phase = .recording
            currentFolder = try? await engine.call("get_meeting_folder_path") as? String
            saveSnapshot()
            if StorePrefs.showRecordingNotification { showRecordingNotice() }
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
            .filter { !$0.text.isEmpty }
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
            PendingRecording.clear()
            phase = .idle
            liveSegments = []
            let newId = (result?["meeting_id"] as? String) ?? meetings.first?.id
            if isAutoSummary, let newId { autoSummaryPending.insert(newId) }
            selection = newId
        } catch {
            phase = .idle
            show(error)
        }
    }

    // MARK: Events

    private func handle(event: String, payload: Any) {
        switch event {
        case "transcript-update":
            // Same as the original UI: every chunk is its own line (the engine flags
            // low-confidence chunks as "partial", but they are never re-sent), so keep them all.
            guard let seg = LiveSegment(payload: payload), !seg.text.isEmpty else { return }
            if let i = liveSegments.firstIndex(where: { $0.sequence == seg.sequence }) {
                liveSegments[i] = seg
            } else {
                liveSegments.append(seg)
            }
            scheduleSnapshot()
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
        case "import-progress":
            if let d = payload as? [String: Any] {
                importJob?.progress = JobProgress(percent: Self.num(d["progress_percentage"]), message: (d["message"] as? String) ?? "", failed: nil)
            }
        case "import-complete":
            let d = payload as? [String: Any]
            importJob = nil
            Task {
                await reloadMeetings()
                if let id = d?["meeting_id"] as? String {
                    if isAutoSummary { autoSummaryPending.insert(id) }
                    selection = id
                }
            }
        case "import-error":
            let msg = ((payload as? [String: Any])?["error"] as? String) ?? EngineClient.describe(payload)
            importJob?.running = false
            importJob?.progress = JobProgress(percent: 0, message: "", failed: msg)
        case "retranscription-progress", "retranscription-complete", "retranscription-error":
            guard let d = payload as? [String: Any], let id = d["meeting_id"] as? String else { return }
            if event == "retranscription-progress" {
                retranscribeJobs[id] = JobProgress(percent: Self.num(d["progress_percentage"]), message: (d["message"] as? String) ?? "", failed: nil)
            } else if event == "retranscription-complete" {
                retranscribeJobs[id] = nil
                detailRevision += 1
                flash("Re-transcription finished.")
            } else {
                retranscribeJobs[id] = JobProgress(percent: 0, message: "", failed: (d["error"] as? String) ?? "Re-transcription failed.")
            }
        case "model-download-progress", "parakeet-model-download-progress", "builtin-ai-download-progress", "ollama-model-download-progress":
            guard let d = payload as? [String: Any],
                  let name = (d["modelName"] as? String) ?? (d["model"] as? String) ?? (d["model_name"] as? String) else { return }
            let key = Self.downloadKind(event) + ":" + name
            let status = d["status"] as? String
            if status == "cancelled" || status == "completed" || status == "error" {
                downloads[key] = nil; downloadRevision += 1
            } else {
                downloads[key] = Self.num(d["progress"])
            }
        case "model-download-complete", "parakeet-model-download-complete", "ollama-model-download-complete",
             "model-download-error", "parakeet-model-download-error", "ollama-model-download-error":
            let d = payload as? [String: Any]
            if let name = (d?["modelName"] as? String) ?? (d?["model"] as? String) ?? (d?["model_name"] as? String) {
                downloads[Self.downloadKind(event) + ":" + name] = nil
            } else {
                downloads = downloads.filter { !$0.key.hasPrefix(Self.downloadKind(event) + ":") }
            }
            if event.hasSuffix("error") { flash((d?["error"] as? String) ?? "The model download failed.") }
            downloadRevision += 1
        case "audio-levels":
            guard let d = payload as? [String: Any], let levels = d["levels"] as? [[String: Any]] else { return }
            for l in levels {
                if let n = l["device_name"] as? String { audioLevels[n] = Self.num(l["rms_level"]) }
            }
        default:
            break
        }
    }

    nonisolated static func num(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        return 0
    }

    static func downloadKind(_ event: String) -> String {
        if event.hasPrefix("parakeet") { return "parakeet" }
        if event.hasPrefix("builtin") { return "builtin" }
        if event.hasPrefix("ollama") { return "ollama" }
        return "whisper"
    }

    // MARK: Recording notice

    private func showRecordingNotice() {
        let alert = NSAlert()
        alert.messageText = "Recording started"
        alert.informativeText = "Let everyone in the meeting know it's being recorded."
        alert.addButton(withTitle: "I've Told Them")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't remind me again"
        let finish: (NSApplication.ModalResponse) -> Void = { _ in
            if alert.suppressionButton?.state == .on { StorePrefs.showRecordingNotification = false }
        }
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    // MARK: Crash recovery

    private func scheduleSnapshot() {
        snapshotTask?.cancel()
        snapshotTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            saveSnapshot()
        }
    }

    private func saveSnapshot() {
        guard isRecording else { return }
        let segs = liveSegments.filter { !$0.text.isEmpty }.map {
            PendingRecording.Segment(sequence: $0.sequence, text: $0.text, timestamp: $0.timestamp, start: $0.start, end: $0.end, duration: $0.duration)
        }
        PendingRecording.save(.init(name: currentMeetingName, folder: currentFolder, startedAt: recordingStartedAt ?? Date(), segments: segs))
    }

    func recoverPending() async {
        guard let snap = recovery else { return }
        var audioNote = ""
        if let folder = snap.folder, (try? await engine.call("has_audio_checkpoints", ["meetingFolder": folder]) as? Bool) == true {
            if let r = try? await engine.call("recover_audio_from_checkpoints", ["meetingFolder": folder, "sampleRate": 48000]) as? [String: Any] {
                if (r["status"] as? String) == "success" || (r["status"] as? String) == "partial" {
                    try? await engine.call("cleanup_checkpoints", ["meetingFolder": folder])
                } else { audioNote = " The audio couldn't be recovered." }
            }
        }
        let payload: [[String: Any]] = snap.segments.sorted { $0.start < $1.start }.map {
            ["id": "seg-\($0.sequence)", "text": $0.text, "timestamp": $0.timestamp,
             "audio_start_time": $0.start, "audio_end_time": $0.end, "duration": $0.duration]
        }
        do {
            let result = try await engine.call("api_save_transcript", [
                "meetingTitle": snap.name, "transcripts": payload,
                "folderPath": snap.folder.map { $0 as Any } ?? NSNull(),
            ]) as? [String: Any]
            PendingRecording.clear()
            recovery = nil
            await reloadMeetings()
            selection = (result?["meeting_id"] as? String) ?? meetings.first?.id
            flash("Recovered “\(snap.name)”." + audioNote)
        } catch { show(error) }
    }

    func discardPending() async {
        if let folder = recovery?.folder { try? await engine.call("cleanup_checkpoints", ["meetingFolder": folder]) }
        PendingRecording.clear()
        recovery = nil
    }

    // MARK: Import audio

    static let audioExtensions = ["mp4", "m4a", "wav", "mp3", "flac", "ogg", "aac", "webm", "mkv", "wma", "mov"]

    func chooseAudioToImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.audioExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.message = "Choose an audio or video file to transcribe"
        if panel.runModal() == .OK, let url = panel.url { Task { await prepareImport(url) } }
    }

    func prepareImport(_ url: URL) async {
        guard importAndRetranscribe else { flash("Turn on Import & Retranscribe in Settings › Beta first."); return }
        guard importJob?.running != true else { return }
        do {
            let info = try await engine.call("validate_audio_file_command", ["path": url.path]) as? [String: Any]
            let filename = (info?["filename"] as? String) ?? url.lastPathComponent
            importJob = ImportJob(path: (info?["path"] as? String) ?? url.path, filename: filename,
                                  duration: Self.num(info?["duration_seconds"]),
                                  title: (filename as NSString).deletingPathExtension)
        } catch { show(error) }
    }

    func startImport(title: String, language: String) async {
        guard var job = importJob else { return }
        job.title = title; job.running = true; job.progress = JobProgress(percent: 0, message: "Starting…", failed: nil)
        importJob = job
        let cfg = try? await engine.call("api_get_transcript_config") as? [String: Any]
        do {
            try await engine.call("start_import_audio_command", [
                "sourcePath": job.path, "title": title,
                "language": (language == "auto" || language == "auto-translate") ? NSNull() : language,
                "model": (cfg?["model"] as? String) ?? NSNull(), "provider": (cfg?["provider"] as? String) ?? NSNull(),
            ])
        } catch {
            importJob?.running = false
            importJob?.progress = JobProgress(percent: 0, message: "", failed: error.localizedDescription)
        }
    }

    func cancelImport() async {
        if importJob?.running == true { try? await engine.call("cancel_import_command") }
        importJob = nil
    }

    func startRetranscribe(meetingId: String, folder: String, language: String) async {
        retranscribeJobs[meetingId] = JobProgress(percent: 0, message: "Starting…", failed: nil)
        let cfg = try? await engine.call("api_get_transcript_config") as? [String: Any]
        let provider = cfg?["provider"] as? String
        do {
            try await engine.call("start_retranscription_command", [
                "meetingId": meetingId, "meetingFolderPath": folder,
                "language": (provider == "parakeet" || language == "auto") ? NSNull() : language,
                "model": (cfg?["model"] as? String) ?? NSNull(), "provider": provider ?? NSNull(),
            ])
        } catch {
            retranscribeJobs[meetingId] = JobProgress(percent: 0, message: "", failed: error.localizedDescription)
        }
    }

    func cancelRetranscribe(meetingId: String) async {
        try? await engine.call("cancel_retranscription_command")
        retranscribeJobs[meetingId] = nil
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
