import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Recordings", systemImage: "mic") { RecordingSettings() }
            Tab("Transcription", systemImage: "waveform") { TranscriptionSettings() }
            Tab("Summary", systemImage: "sparkles") { SummarySettings() }
            Tab("Beta", systemImage: "flask") { BetaSettings() }
            Tab("About", systemImage: "info.circle") { AboutSettings() }
        }
        .frame(width: 640, height: 560)
        .toolbarBackground(Color.white.opacity(0.06), for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
    }
}

// MARK: - Helpers

private func dicts(_ v: Any?) -> [[String: Any]] { (v as? [[String: Any]]) ?? [] }

/// A model row parsed from the engine's loosely typed model lists.
struct ModelRow: Identifiable {
    var id: String { name }
    let name: String
    let title: String
    let detail: String
    /// available, missing, downloading, corrupted, error
    let state: String
    let progress: Double

    /// Parses whisper/parakeet `status` ("Available" | "Missing" | {Downloading:{progress}} | {Error:..} | {Corrupted:..})
    /// and built-in AI `status` ({type: "..."}).
    init(_ d: [String: Any], title: String? = nil) {
        name = (d["name"] as? String) ?? "?"
        self.title = title ?? (d["display_name"] as? String) ?? name
        var parts: [String] = []
        if let mb = d["size_mb"] as? Int, mb > 0 { parts.append(mb >= 1024 ? String(format: "%.1f GB", Double(mb) / 1024) : "\(mb) MB") }
        for k in ["accuracy", "speed"] { if let s = d[k] as? String, !s.isEmpty { parts.append(s) } }
        detail = parts.joined(separator: " · ")
        var state = "missing", progress = 0.0
        let st = d["status"]
        if let s = st as? String {
            state = s == "Available" ? "available" : s == "Missing" ? "missing" : s.lowercased()
        } else if let o = st as? [String: Any] {
            if let t = o["type"] as? String {
                state = t == "not_downloaded" ? "missing" : t
                progress = AppModel.num(o["progress"])
            } else if let k = o.keys.first {
                state = k.lowercased()
                progress = AppModel.num((o[k] as? [String: Any])?["progress"])
            }
        }
        self.state = state
        self.progress = progress
    }
}

private struct ModelManagerRow: View {
    let row: ModelRow
    let selected: Bool
    let liveProgress: Double?
    var onUse: (() -> Void)?
    var onDownload: () -> Void
    var onCancel: () -> Void
    var onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title)
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                }
                if !row.detail.isEmpty { Text(row.detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if let p = liveProgress ?? (row.state == "downloading" ? row.progress : nil) {
                ProgressView(value: min(max(p, 0), 100), total: 100).frame(width: 110)
                Text("\(Int(p))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 34)
                Button("Cancel", action: onCancel)
            } else {
                switch row.state {
                case "available":
                    if let onUse, !selected { Button("Use", action: onUse) }
                    if let onDelete { Button("Delete", role: .destructive, action: onDelete) }
                case "corrupted", "error":
                    Text("Damaged").font(.caption).foregroundStyle(.orange)
                    if let onDelete { Button("Delete", role: .destructive, action: onDelete) }
                    Button("Download", action: onDownload)
                default:
                    Button("Download", action: onDownload)
                }
            }
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @State private var notif: [String: Any] = [:]
    @State private var dbDir = ""
    @State private var modelsDir = ""

    private func pref(_ key: String) -> Binding<Bool> {
        Binding(
            get: { ((notif["notification_preferences"] as? [String: Any])?[key] as? Bool) ?? true },
            set: { v in
                var p = (notif["notification_preferences"] as? [String: Any]) ?? [:]
                p[key] = v
                notif["notification_preferences"] = p
                Task { do { try await app.engine.call("set_notification_settings", ["settings": notif]) } catch { app.show(error) } }
            })
    }

    var body: some View {
        Form {
            Section("Notifications") {
                if notif.isEmpty {
                    Text("Notification settings aren't available.").foregroundStyle(.secondary)
                } else {
                    Toggle("When a recording starts", isOn: pref("show_recording_started"))
                    Toggle("When a recording stops", isOn: pref("show_recording_stopped"))
                }
            }
            Section("Storage") {
                folderRow("Database", dbDir, "open_database_folder")
                folderRow("Models", modelsDir, "open_models_folder")
                folderRow("Recordings", (app.recordingPrefs["save_folder"] as? String) ?? "", "open_recordings_folder")
            }
        }
        .formStyle(.grouped)
        .task {
            notif = ((try? await app.engine.call("get_notification_settings")) as? [String: Any]) ?? [:]
            dbDir = ((try? await app.engine.call("get_database_directory")) as? String) ?? ""
            modelsDir = ((try? await app.engine.call("whisper_get_models_directory")) as? String) ?? ""
            await app.loadRecordingPrefs()
        }
    }

    private func folderRow(_ label: String, _ path: String, _ cmd: String) -> some View {
        LabeledContent(label) {
            HStack {
                Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Button("Open") { Task { do { try await app.engine.call(cmd) } catch { app.show(error) } } }
            }
        }
    }
}

// MARK: - Recordings

private struct RecordingSettings: View {
    @Environment(AppModel.self) private var app
    @State private var backends: [[String: Any]] = []
    @State private var backend = ""
    @State private var remind = StorePrefs.showRecordingNotification
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                Toggle("Save audio recordings", isOn: Binding(
                    get: { (app.recordingPrefs["auto_save"] as? Bool) ?? true },
                    set: { v in Task { await app.setRecordingPref("auto_save", v) } }))
                LabeledContent("Save folder") {
                    HStack {
                        Text(((app.recordingPrefs["save_folder"] as? String) ?? "").replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Change…") { chooseFolder() }
                        Button("Open") { Task { try? await app.engine.call("open_recordings_folder") } }
                    }
                }
                LabeledContent("File format", value: ((app.recordingPrefs["file_format"] as? String) ?? "mp4").uppercased())
                Toggle("Remind me to tell participants they're being recorded", isOn: $remind)
                    .onChange(of: remind) { _, v in StorePrefs.showRecordingNotification = v }
            }
            Section("Devices") {
                Picker("Microphone", selection: Binding(get: { app.micDevice }, set: { v in Task { await app.setMic(v) } })) {
                    Text("System Default").tag("")
                    ForEach(app.inputDevices, id: \.self) { Text($0).tag($0) }
                    if !app.micDevice.isEmpty && !app.inputDevices.contains(app.micDevice) { Text(app.micDevice).tag(app.micDevice) }
                }
                Picker("System audio", selection: Binding(get: { app.systemDevice }, set: { v in Task { await app.setSystemAudio(v) } })) {
                    Text("System Default").tag("")
                    ForEach(app.outputDevices, id: \.self) { Text($0).tag($0) }
                    if !app.systemDevice.isEmpty && !app.outputDevices.contains(app.systemDevice) { Text(app.systemDevice).tag(app.systemDevice) }
                }
                if !backends.isEmpty {
                    Picker("System audio capture", selection: $backend) {
                        ForEach(backends.indices, id: \.self) { i in
                            Text((backends[i]["name"] as? String) ?? "").tag((backends[i]["id"] as? String) ?? "")
                        }
                    }
                    .onChange(of: backend) { old, new in
                        guard !old.isEmpty, old != new else { return }
                        Task {
                            do { try await app.engine.call("set_audio_backend", ["backend": new]); await app.loadRecordingPrefs() }
                            catch { app.show(error); backend = old }
                        }
                    }
                }
                HStack {
                    Button(testing ? "Stop Test" : "Test Microphones") { Task { await toggleTest() } }
                    Button("Refresh Devices") { Task { await app.loadDevices() } }
                }
                if testing {
                    ForEach(app.inputDevices, id: \.self) { name in
                        LabeledContent(name) {
                            ProgressView(value: min(app.audioLevels[name] ?? 0, 1)).frame(width: 200)
                        }
                    }
                }
            }
            .disabled(app.isRecording)
        }
        .formStyle(.grouped)
        .task {
            await app.loadRecordingPrefs()
            await app.loadDevices()
            backends = dicts(try? await app.engine.call("get_audio_backend_info"))
            backend = ((try? await app.engine.call("get_current_audio_backend")) as? String) ?? ""
        }
        .onDisappear { if testing { Task { try? await app.engine.call("stop_audio_level_monitoring") } } }
    }

    private func toggleTest() async {
        if testing {
            try? await app.engine.call("stop_audio_level_monitoring")
            testing = false
        } else {
            do {
                try await app.engine.call("start_audio_level_monitoring", ["deviceNames": app.inputDevices])
                testing = true
            } catch { app.show(error) }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            Task { await app.setRecordingPref("save_folder", url.path) }
        }
    }
}

// MARK: - Transcription

private struct TranscriptionSettings: View {
    @Environment(AppModel.self) private var app
    @State private var provider = "localWhisper"
    @State private var current = ""
    @State private var models: [ModelRow] = []
    @State private var loaded = false
    private let mlxModel = "large-v3-mlx"

    private var kind: String { provider == "parakeet" ? "parakeet" : "whisper" }

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                Picker("Engine", selection: $provider) {
                    Text("Whisper").tag("localWhisper")
                    Text("Parakeet").tag("parakeet")
                }
                .onChange(of: provider) { old, new in
                    guard loaded, old != new else { return }
                    Task { await reloadModels() }
                }
                Picker("Language", selection: $app.primaryLanguage) {
                    ForEach(provider == "parakeet" ? Languages.transcription.filter { $0.code.hasPrefix("auto") } : Languages.transcription) {
                        Text($0.name).tag($0.code)
                    }
                }
            }
            Section("Models") {
                if provider == "localWhisper" {
                    MLXModelRow(selected: current == mlxModel, onUse: { Task { await use(mlxModel) } })
                }
                ForEach(models) { m in
                    ModelManagerRow(
                        row: m, selected: current == m.name,
                        liveProgress: app.downloads["\(kind):\(m.name)"],
                        onUse: { Task { await use(m.name) } },
                        onDownload: { Task { await download(m.name) } },
                        onCancel: { Task { await cancel(m.name) } },
                        onDelete: m.state == "available" ? nil : { Task { await deleteCorrupted(m.name) } })
                }
                Button("Open Models Folder") {
                    Task { try? await app.engine.call(provider == "parakeet" ? "open_parakeet_models_folder" : "open_models_folder") }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            if let cfg = try? await app.engine.call("api_get_transcript_config") as? [String: Any] {
                provider = (cfg["provider"] as? String) == "parakeet" ? "parakeet" : "localWhisper"
                current = (cfg["model"] as? String) ?? mlxModel
            }
            await reloadModels()
            loaded = true
        }
        .onChange(of: app.downloadRevision) { Task { await reloadModels() } }
    }

    private func reloadModels() async {
        try? await app.engine.call(provider == "parakeet" ? "parakeet_init" : "whisper_init")
        let list = dicts(try? await app.engine.call(provider == "parakeet" ? "parakeet_get_available_models" : "whisper_get_available_models"))
        models = list.map { ModelRow($0) }.filter { $0.name != mlxModel }
    }

    private func use(_ model: String) async {
        do {
            let prov = model == mlxModel ? "localWhisper" : provider
            try await app.engine.call("api_save_transcript_config", ["provider": prov, "model": model, "apiKey": NSNull()])
            if model != mlxModel {
                try await app.engine.call(prov == "parakeet" ? "parakeet_load_model" : "whisper_load_model", ["modelName": model])
            }
            current = model
            if prov == "parakeet" && !app.primaryLanguage.hasPrefix("auto") { app.primaryLanguage = "auto" }
        } catch { app.show(error) }
    }

    private func download(_ model: String) async {
        app.downloads["\(kind):\(model)"] = 0
        do { try await app.engine.call(provider == "parakeet" ? "parakeet_download_model" : "whisper_download_model", ["modelName": model]) }
        catch { app.downloads["\(kind):\(model)"] = nil; app.show(error) }
        await reloadModels()
    }

    private func cancel(_ model: String) async {
        try? await app.engine.call(provider == "parakeet" ? "parakeet_cancel_download" : "whisper_cancel_download", ["modelName": model])
        app.downloads["\(kind):\(model)"] = nil
        await reloadModels()
    }

    private func deleteCorrupted(_ model: String) async {
        do { try await app.engine.call(provider == "parakeet" ? "parakeet_delete_corrupted_model" : "whisper_delete_corrupted_model", ["modelName": model]) }
        catch { app.show(error) }
        await reloadModels()
    }
}

// MARK: - Summary

private struct SummarySettings: View {
    @Environment(AppModel.self) private var app
    @State private var provider = "builtin-ai"
    @State private var model = ""
    @State private var apiKey = ""
    @State private var endpoint = ""
    @State private var whisperModel = "large-v3"
    @State private var modelList: [String] = []
    @State private var builtin: [ModelRow] = []
    @State private var loadingModels = false
    @State private var loaded = false
    @State private var pullName = ""
    @State private var defaultLanguage = Prefs.summaryLanguageDefault ?? ""
    // Custom OpenAI-compatible server
    @State private var maxTokens = ""
    @State private var temperature = ""
    @State private var topP = ""
    @State private var testResult: String?

    static let providers: [(String, String)] = [
        ("builtin-ai", "Built-in AI (offline, no API needed)"), ("claude", "Claude"),
        ("custom-openai", "Custom Server (OpenAI-compatible)"), ("groq", "Groq"),
        ("ollama", "Ollama"), ("openai", "OpenAI"), ("openrouter", "OpenRouter"),
    ]

    private var needsKey: Bool { ["openai", "claude", "groq", "openrouter", "custom-openai"].contains(provider) }

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                Toggle("Summarize automatically after each recording", isOn: $app.isAutoSummary)
                Picker("Default template", selection: $app.summaryTemplate) {
                    ForEach(app.templates) { Text($0.name).tag($0.id) }
                }
                Picker("Default summary language", selection: $defaultLanguage) {
                    Text("Auto (dominant transcript language)").tag("")
                    ForEach(Languages.summary) { Text($0.name).tag($0.code) }
                }
                .onChange(of: defaultLanguage) { _, v in Prefs.summaryLanguageDefault = v.isEmpty ? nil : v }
            }
            Section("Model") {
                Picker("Provider", selection: $provider) {
                    ForEach(Self.providers, id: \.0) { Text($0.1).tag($0.0) }
                }
                .onChange(of: provider) { old, new in
                    guard loaded, old != new else { return }
                    model = Prefs.providerModelMap[new] ?? ""
                    testResult = nil
                    Task { await providerChanged() }
                }
                if provider == "ollama" || provider == "custom-openai" {
                    TextField("Endpoint", text: $endpoint, prompt: Text(provider == "ollama" ? "http://localhost:11434" : "https://your-server/v1"))
                        .onSubmit { Task { await loadModelList() } }
                }
                if needsKey {
                    SecureField("API key", text: $apiKey)
                        .onSubmit { Task { await loadModelList() } }
                }
                if provider == "custom-openai" {
                    TextField("Model", text: $model)
                } else {
                    HStack {
                        Picker("Model", selection: $model) {
                            if model.isEmpty { Text("Choose…").tag("") }
                            ForEach(modelList.contains(model) || model.isEmpty ? modelList : [model] + modelList, id: \.self) { Text($0).tag($0) }
                        }
                        if loadingModels { ProgressView().controlSize(.small) }
                        Button { Task { await loadModelList() } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).help("Refresh the model list")
                    }
                }
                if provider == "custom-openai" {
                    TextField("Max tokens", text: $maxTokens, prompt: Text("Optional"))
                    TextField("Temperature", text: $temperature, prompt: Text("Optional"))
                    TextField("Top P", text: $topP, prompt: Text("Optional"))
                    HStack {
                        Button("Test Connection") { Task { await testConnection() } }
                        if let testResult { Text(testResult).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            if provider == "ollama" {
                Section("Ollama models") {
                    HStack {
                        TextField("Download a model", text: $pullName, prompt: Text("e.g. gemma3:4b"))
                        if let p = app.downloads["ollama:\(pullName)"] {
                            ProgressView(value: min(p, 100), total: 100).frame(width: 100)
                        } else {
                            Button("Download") { Task { await pull() } }.disabled(pullName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    if !model.isEmpty && modelList.contains(model) {
                        Button("Delete “\(model)” from Ollama", role: .destructive) { Task { await deleteOllama(model) } }
                    }
                }
            }
            if provider == "builtin-ai" {
                Section("Built-in models") {
                    ForEach(builtin) { m in
                        ModelManagerRow(
                            row: m, selected: model == m.name,
                            liveProgress: app.downloads["builtin:\(m.name)"],
                            onUse: { model = m.name },
                            onDownload: { Task { await builtinCall("builtin_ai_download_model", m.name) } },
                            onCancel: { Task { await builtinCall("builtin_ai_cancel_download", m.name) } },
                            onDelete: { Task { await builtinCall("builtin_ai_delete_model", m.name) } })
                    }
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Save") { Task { await save() } }
                        .buttonStyle(.glassProminent)
                        .disabled(model.trimmingCharacters(in: .whitespaces).isEmpty || (provider == "custom-openai" && endpoint.isEmpty))
                }
            }
        }
        .formStyle(.grouped)
        .task { await load() }
        .onChange(of: app.downloadRevision) { Task { if provider == "builtin-ai" || provider == "ollama" { await loadModelList() } } }
    }

    private func load() async {
        guard !loaded else { return }
        if let cfg = try? await app.engine.call("api_get_model_config") as? [String: Any] {
            provider = (cfg["provider"] as? String) ?? provider
            model = (cfg["model"] as? String) ?? ""
            endpoint = (cfg["ollamaEndpoint"] as? String) ?? ""
            whisperModel = (cfg["whisperModel"] as? String) ?? whisperModel
        }
        await providerChanged()
        loaded = true
    }

    private func providerChanged() async {
        apiKey = ""
        if provider == "custom-openai" {
            if let c = try? await app.engine.call("api_get_custom_openai_config") as? [String: Any] {
                endpoint = (c["endpoint"] as? String) ?? endpoint
                apiKey = (c["apiKey"] as? String) ?? ""
                if let m = c["model"] as? String, !m.isEmpty { model = m }
                maxTokens = (c["maxTokens"] as? Int).map(String.init) ?? ""
                temperature = (c["temperature"] as? Double).map { String($0) } ?? ""
                topP = (c["topP"] as? Double).map { String($0) } ?? ""
            }
        } else if needsKey {
            apiKey = ((try? await app.engine.call("api_get_api_key", ["provider": provider])) as? String) ?? ""
        }
        await loadModelList()
    }

    private func loadModelList() async {
        loadingModels = true
        defer { loadingModels = false }
        let key: Any = apiKey.isEmpty ? NSNull() : apiKey
        var names: [String] = []
        switch provider {
        case "builtin-ai":
            builtin = dicts(try? await app.engine.call("builtin_ai_list_models")).map { ModelRow($0) }
            names = builtin.filter { $0.state == "available" }.map(\.name)
        case "ollama":
            names = dicts(try? await app.engine.call("get_ollama_models", ["endpoint": endpoint.isEmpty ? NSNull() : endpoint])).compactMap { $0["name"] as? String }
        case "openai": names = dicts(try? await app.engine.call("get_openai_models", ["apiKey": key])).compactMap { $0["id"] as? String }
        case "claude": names = dicts(try? await app.engine.call("get_anthropic_models", ["apiKey": key])).compactMap { $0["id"] as? String }
        case "groq": names = dicts(try? await app.engine.call("get_groq_models", ["apiKey": key])).compactMap { $0["id"] as? String }
        case "openrouter": names = dicts(try? await app.engine.call("get_openrouter_models")).compactMap { $0["id"] as? String }
        default: break
        }
        modelList = names
        if model.isEmpty, let first = names.first { model = first }
    }

    private func builtinCall(_ cmd: String, _ name: String) async {
        if cmd == "builtin_ai_download_model" { app.downloads["builtin:\(name)"] = 0 }
        if cmd == "builtin_ai_cancel_download" { app.downloads["builtin:\(name)"] = nil }
        do { try await app.engine.call(cmd, ["modelName": name]) } catch { app.show(error) }
        await loadModelList()
    }

    private func pull() async {
        let name = pullName.trimmingCharacters(in: .whitespaces)
        app.downloads["ollama:\(name)"] = 0
        do {
            try await app.engine.call("pull_ollama_model", ["modelName": name, "endpoint": endpoint.isEmpty ? NSNull() : endpoint])
        } catch { app.downloads["ollama:\(name)"] = nil; app.show(error) }
        await loadModelList()
    }

    private func deleteOllama(_ name: String) async {
        do {
            try await app.engine.call("delete_ollama_model", ["modelName": name, "endpoint": endpoint.isEmpty ? NSNull() : endpoint])
            model = ""
        } catch { app.show(error) }
        await loadModelList()
    }

    private func testConnection() async {
        testResult = "Testing…"
        do {
            let r = try await app.engine.call("api_test_custom_openai_connection", [
                "endpoint": endpoint, "apiKey": apiKey.isEmpty ? NSNull() : apiKey, "model": model,
            ])
            testResult = ((r as? [String: Any])?["message"] as? String) ?? "Connected."
        } catch { testResult = error.localizedDescription }
    }

    private func save() async {
        let m = model.trimmingCharacters(in: .whitespaces)
        do {
            if provider == "custom-openai" {
                try await app.engine.call("api_save_custom_openai_config", [
                    "endpoint": endpoint, "apiKey": apiKey.isEmpty ? NSNull() : apiKey, "model": m,
                    "maxTokens": Int(maxTokens).map { $0 as Any } ?? NSNull(),
                    "temperature": Double(temperature).map { $0 as Any } ?? NSNull(),
                    "topP": Double(topP).map { $0 as Any } ?? NSNull(),
                ])
            }
            try await app.engine.call("api_save_model_config", [
                "provider": provider, "model": m, "whisperModel": whisperModel,
                "apiKey": apiKey.isEmpty ? NSNull() : apiKey,
                "ollamaEndpoint": endpoint.isEmpty ? NSNull() : endpoint,
            ])
            var map = Prefs.providerModelMap
            map[provider] = m
            Prefs.providerModelMap = map
            app.flash("Summary model saved.")
        } catch { app.show(error) }
    }
}

// MARK: - Beta

private struct BetaSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                Toggle("Import audio & re-transcribe", isOn: $app.importAndRetranscribe)
            } footer: {
                Text("Adds File › Import Audio, drag-and-drop of audio files, and re-transcribing a saved meeting.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

private struct AboutSettings: View {
    private var version: String {
        let engine = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/Engine/Meetily Engine.app")
        return (Bundle(url: engine)?.infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Meetily").font(.title.weight(.semibold))
            if !version.isEmpty { Text("Version \(version)").foregroundStyle(.secondary) }
            Text("Private meeting notes. Recording, transcription and summaries stay on this Mac unless you pick a cloud provider.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
            HStack {
                Link("Project on GitHub", destination: URL(string: "https://github.com/Zackriya-Solutions/meeting-minutes")!)
                Link("Privacy Policy", destination: URL(string: "https://github.com/Zackriya-Solutions/meeting-minutes/blob/main/PRIVACY_POLICY.md")!)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}


/// The MLX large-v3 row: runtime setup, 3 GB model download with progress, delete.
private struct MLXModelRow: View {
    let selected: Bool
    let onUse: () -> Void
    @State private var mlx = MLXManager.shared
    @State private var confirmDelete = false

    var body: some View {
        if let reason = MLXManager.unsupportedReason { unsupported(reason) } else { row }
    }

    private func unsupported(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "nosign").font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Whisper large-v3 (MLX)").strikethrough(color: .secondary)
                    Text("Not supported by your hardware").font(.caption.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.red.opacity(0.15), in: .capsule).foregroundStyle(.red)
                }
                Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
        .opacity(0.8)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private var row: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Whisper large-v3 (MLX)")
                    if selected && mlx.modelReady && mlx.runtimeReady { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                }
                Text(subtitle).font(.caption).foregroundStyle(isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
            }
            Spacer()
            switch mlx.phase {
            case .runtime:
                ProgressView().controlSize(.small)
                Button("Cancel") { mlx.cancel() }
            case .model(let p):
                ProgressView(value: min(p, 100), total: 100).frame(width: 110)
                Button("Cancel") { mlx.cancel() }
            default:
                if mlx.modelReady && mlx.runtimeReady {
                    if !selected { Button("Use", action: onUse) }
                    Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Delete the model")
                } else {
                    Button(isFailed ? "Retry" : "Download") { mlx.install() }
                }
            }
        }
        .onAppear { mlx.refresh() }
        .confirmationDialog("Delete the MLX model (\(mlx.modelSizeMB) MB)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { mlx.deleteModel() }
        }
    }

    private var isFailed: Bool { if case .failed = mlx.phase { return true }; return false }

    private var subtitle: String {
        switch mlx.phase {
        case .runtime(let s): return s
        case .model(let p): return String(format: "Downloading… %.0f%% of %.1f GB", p, Double(MLXManager.modelDownloadMB) / 1024)
        case .failed(let e): return e
        case .idle:
            if !mlx.modelReady { return String(format: "Runs on the Apple GPU · %.1f GB download", Double(MLXManager.modelDownloadMB) / 1024) }
            if !mlx.runtimeReady { return "Runs on the Apple GPU · needs a one-time setup" }
            return "Runs on the Apple GPU · \(mlx.modelSizeMB) MB"
        }
    }
}
