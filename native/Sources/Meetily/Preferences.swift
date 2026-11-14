import Foundation

/// UI-side preferences the original web interface kept in localStorage.
enum Prefs {
    static let d: UserDefaults = {
        let d = UserDefaults.standard
        register(d)
        return d
    }()

    private static func register(_ d: UserDefaults) {
        d.register(defaults: [
            "primaryLanguage": "auto",
            "isAutoSummary": true,
            "betaImportAndRetranscribe": true,
            "summaryTemplate": "standard_meeting",
            "providerModelMap": ["builtin-ai": "qwen3.5:4b", "openai": "gpt-4o"],
            "summaryLanguageRecents": [String](),
        ])
    }

    static var primaryLanguage: String {
        get { d.string(forKey: "primaryLanguage") ?? "auto" }
        set { d.set(newValue, forKey: "primaryLanguage") }
    }
    static var isAutoSummary: Bool {
        get { d.bool(forKey: "isAutoSummary") }
        set { d.set(newValue, forKey: "isAutoSummary") }
    }
    static var importAndRetranscribe: Bool {
        get { d.bool(forKey: "betaImportAndRetranscribe") }
        set { d.set(newValue, forKey: "betaImportAndRetranscribe") }
    }
    static var summaryTemplate: String {
        get { d.string(forKey: "summaryTemplate") ?? "standard_meeting" }
        set { d.set(newValue, forKey: "summaryTemplate") }
    }
    static var providerModelMap: [String: String] {
        get { (d.dictionary(forKey: "providerModelMap") as? [String: String]) ?? [:] }
        set { d.set(newValue, forKey: "providerModelMap") }
    }
    /// Pinned default summary language; nil means Auto (dominant transcript language).
    static var summaryLanguageDefault: String? {
        get { d.string(forKey: "summaryLanguageDefault") }
        set { d.set(newValue, forKey: "summaryLanguageDefault") }
    }
    static var summaryLanguageRecents: [String] {
        get { d.stringArray(forKey: "summaryLanguageRecents") ?? [] }
        set { d.set(Array(newValue.prefix(5)), forKey: "summaryLanguageRecents") }
    }
    static func addRecentSummaryLanguage(_ code: String) {
        var r = summaryLanguageRecents.filter { $0 != code }
        r.insert(code, at: 0)
        summaryLanguageRecents = r
    }
}

/// The engine's plugin-store file `preferences.json` (shared with the original app).
enum StorePrefs {
    static var url: URL { URL(fileURLWithPath: EngineClient.shared.dataDir + "/preferences.json") }

    static func read() -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    static var showRecordingNotification: Bool {
        get { (read()["show_recording_notification"] as? Bool) ?? true }
        set {
            var obj = read()
            obj["show_recording_notification"] = newValue
            if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}

/// Where the live transcript is mirrored during a recording, so a crash can be recovered.
enum PendingRecording {
    static var url: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.meetily.native", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pending-recording.json")
    }

    struct Snapshot: Codable {
        var name: String
        var folder: String?
        var startedAt: Date
        var segments: [Segment]
    }
    struct Segment: Codable {
        var sequence: Int; var text: String; var timestamp: String
        var start: Double; var end: Double; var duration: Double
    }

    static func save(_ s: Snapshot) {
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: url, options: .atomic) }
    }
    static func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
    static func clear() { try? FileManager.default.removeItem(at: url) }
}
