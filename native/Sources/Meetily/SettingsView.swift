import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Transcription", systemImage: "waveform") { TranscriptionSettings() }
            Tab("Audio", systemImage: "mic") { AudioSettings() }
            Tab("Summary", systemImage: "sparkles") { SummarySettings() }
        }
        .frame(width: 560, height: 430)
    }
}

private struct TranscriptionSettings: View {
    @Environment(AppModel.self) private var app
    @State private var models: [WhisperModel] = []
    @State private var current = ""
    @State private var provider = "localWhisper"
    @State private var busy = false

    private let mlxModel = "large-v3-mlx"

    var body: some View {
        Form {
            Section {
                Picker("Model", selection: $current) {
                    Text("Whisper large-v3 (MLX, Apple GPU)").tag(mlxModel)
                    ForEach(models.filter(\.isAvailable)) { m in
                        Text("Whisper \(m.name) · \(m.size_mb) MB").tag(m.name)
                    }
                }
                .disabled(busy)
                .onChange(of: current) { old, new in
                    guard !old.isEmpty, old != new else { return }
                    Task { await apply(new) }
                }
            } footer: {
                Text("Transcription runs entirely on this Mac. The MLX large-v3 model is the most accurate one here.")
            }
            if !models.filter({ !$0.isAvailable }).isEmpty {
                Section("Not downloaded") {
                    ForEach(models.filter { !$0.isAvailable }) { m in
                        LabeledContent(m.name) {
                            Text("\(m.size_mb) MB · \(m.accuracy) · \(m.speed)").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await load() }
    }

    private func load() async {
        models = (try? await app.engine.call("whisper_get_available_models", as: [WhisperModel].self)) ?? []
        if let cfg = try? await app.engine.call("api_get_transcript_config") as? [String: Any] {
            provider = (cfg["provider"] as? String) ?? provider
            current = (cfg["model"] as? String) ?? mlxModel
        }
    }

    private func apply(_ model: String) async {
        busy = true
        defer { busy = false }
        do {
            try await app.engine.call("api_save_transcript_config", ["provider": provider, "model": model, "apiKey": NSNull()])
            if model != mlxModel { try await app.engine.call("whisper_load_model", ["modelName": model]) }
            app.flash("Transcription model set to \(model).")
        } catch { app.show(error) }
    }
}

private struct AudioSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                Picker("Microphone", selection: $app.micDevice) {
                    Text("System Default").tag("")
                    ForEach(app.inputDevices, id: \.self) { Text($0).tag($0) }
                }
                Picker("System audio", selection: $app.systemDevice) {
                    Text("System Default").tag("")
                    ForEach(app.outputDevices, id: \.self) { Text($0).tag($0) }
                }
            } footer: {
                Text("System audio captures what the other people in a call say. Changes apply to the next recording.")
            }
            Section {
                Button("Refresh Devices") { Task { await app.loadDevices() } }
            }
        }
        .formStyle(.grouped)
        .task { await app.loadDevices() }
    }
}

private struct SummarySettings: View {
    @Environment(AppModel.self) private var app
    @State private var provider = "builtin-ai"
    @State private var model = ""
    @State private var apiKey = ""
    @State private var endpoint = ""
    @State private var whisperModel = "large-v3"
    @State private var loaded = false

    private let providers: [(String, String)] = [
        ("builtin-ai", "Built-in (on this Mac)"), ("ollama", "Ollama"), ("openai", "OpenAI"),
        ("claude", "Anthropic Claude"), ("groq", "Groq"), ("openrouter", "OpenRouter"),
        ("custom-openai", "Custom OpenAI-compatible"),
    ]

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                Picker("Provider", selection: $provider) {
                    ForEach(providers, id: \.0) { Text($0.1).tag($0.0) }
                    if !providers.contains(where: { $0.0 == provider }) { Text(provider).tag(provider) }
                }
                TextField("Model", text: $model, prompt: Text("e.g. qwen3.5:4b"))
                if !["builtin-ai", "ollama"].contains(provider) {
                    SecureField("API key", text: $apiKey)
                }
                if provider == "ollama" || provider == "custom-openai" {
                    TextField("Endpoint", text: $endpoint, prompt: Text("http://localhost:11434"))
                }
            }
            Section {
                Picker("Default template", selection: $app.summaryTemplate) {
                    ForEach(app.templates) { Text($0.name).tag($0.id) }
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Save") { Task { await save() } }
                        .buttonStyle(.glassProminent)
                        .disabled(model.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .task { await load() }
    }

    private func load() async {
        guard !loaded, let cfg = try? await app.engine.call("api_get_model_config") as? [String: Any] else { return }
        provider = (cfg["provider"] as? String) ?? provider
        model = (cfg["model"] as? String) ?? ""
        apiKey = (cfg["apiKey"] as? String) ?? ""
        endpoint = (cfg["ollamaEndpoint"] as? String) ?? ""
        whisperModel = (cfg["whisperModel"] as? String) ?? whisperModel
        loaded = true
    }

    private func save() async {
        do {
            try await app.engine.call("api_save_model_config", [
                "provider": provider, "model": model.trimmingCharacters(in: .whitespaces),
                "whisperModel": whisperModel,
                "apiKey": apiKey.isEmpty ? NSNull() : apiKey,
                "ollamaEndpoint": endpoint.isEmpty ? NSNull() : endpoint,
            ])
            app.flash("Summary settings saved.")
        } catch { app.show(error) }
    }
}
