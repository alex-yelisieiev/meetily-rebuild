import Foundation

struct Meeting: Identifiable, Hashable {
    let id: String
    var title: String
    var createdAt: Date?
    var folderPath: String?
}

struct MeetingMetadata: Decodable {
    let id: String
    let title: String
    let created_at: String?
    let updated_at: String?
    let folder_path: String?
}

struct TranscriptLine: Decodable, Identifiable, Hashable {
    let id: String
    let text: String
    let timestamp: String?
    let audio_start_time: Double?
    let audio_end_time: Double?
    let duration: Double?
}

struct TranscriptPage: Decodable {
    let transcripts: [TranscriptLine]
    let total_count: Int
    let has_more: Bool
}

struct SearchHit: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let matchContext: String
    let timestamp: String
}

struct AudioDevice: Decodable, Hashable {
    let name: String
    let device_type: String
}

struct WhisperModel: Decodable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let size_mb: Int
    let accuracy: String
    let speed: String
    let description: String
    let statusLabel: String

    enum CodingKeys: String, CodingKey { case name, size_mb, accuracy, speed, description, status }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        size_mb = (try? c.decode(Int.self, forKey: .size_mb)) ?? 0
        accuracy = (try? c.decode(String.self, forKey: .accuracy)) ?? ""
        speed = (try? c.decode(String.self, forKey: .speed)) ?? ""
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        if let s = try? c.decode(String.self, forKey: .status) {
            statusLabel = s
        } else if let d = try? c.decode([String: JSONAny].self, forKey: .status), let key = d.keys.first {
            statusLabel = key
        } else {
            statusLabel = "Unknown"
        }
    }

    var isAvailable: Bool { statusLabel == "Available" }
}

struct Template: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let description: String?
}

/// Swallows any JSON value (used for loosely typed fields).
struct JSONAny: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { return }
        if (try? c.decode(Bool.self)) != nil { return }
        if (try? c.decode(Double.self)) != nil { return }
        if (try? c.decode(String.self)) != nil { return }
        if (try? c.decode([JSONAny].self)) != nil { return }
        _ = try? c.decode([String: JSONAny].self)
    }
}

struct LiveSegment: Identifiable, Hashable {
    var id: Int { sequence }
    let sequence: Int
    var text: String
    var timestamp: String
    var start: Double
    var end: Double
    var duration: Double
    var isPartial: Bool

    init?(payload: Any) {
        guard let d = payload as? [String: Any], let text = d["text"] as? String else { return nil }
        sequence = (d["sequence_id"] as? Int) ?? Int(Date().timeIntervalSince1970 * 1000)
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        timestamp = (d["timestamp"] as? String) ?? ""
        start = (d["audio_start_time"] as? Double) ?? 0
        end = (d["audio_end_time"] as? Double) ?? start
        duration = (d["duration"] as? Double) ?? max(0, end - start)
        isPartial = (d["is_partial"] as? Bool) ?? false
    }
}

enum DateParsing {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static let fallbacks: [DateFormatter] = ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss"].map {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = $0; return f
    }

    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if let d = iso.date(from: s) ?? isoPlain.date(from: s) { return d }
        for f in fallbacks { if let d = f.date(from: s) { return d } }
        return nil
    }
}

func formatClock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}

/// Pulls displayable Markdown out of the engine's summary payload.
enum SummaryContent {
    static func markdown(from raw: Any?) -> String? {
        var value = raw
        if let s = value as? String {
            if let data = s.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: data) {
                value = parsed
            } else {
                return s.isEmpty ? nil : s
            }
        }
        guard let obj = value as? [String: Any] else { return nil }
        if let md = obj["markdown"] as? String, !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stripReasoning(md)
        }
        if let blocks = obj["summary_json"] {
            let text = flatten(blocks)
            if !text.isEmpty { return text }
        }
        // Legacy section format: { Section: { title, blocks: [{content}] } }
        let order = (obj["_section_order"] as? [String]) ?? obj.keys.sorted()
        var out: [String] = []
        for key in order where key != "MeetingName" && key != "_section_order" {
            guard let section = obj[key] as? [String: Any], let blocks = section["blocks"] as? [[String: Any]] else { continue }
            let items = blocks.compactMap { $0["content"] as? String }.filter { !$0.isEmpty }
            guard !items.isEmpty else { continue }
            out.append("## \((section["title"] as? String) ?? key)")
            out.append(contentsOf: items.map { "- \($0)" })
            out.append("")
        }
        return out.isEmpty ? nil : out.joined(separator: "\n")
    }

    private static func flatten(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let a = value as? [Any] { return a.map(flatten).filter { !$0.isEmpty }.joined(separator: "\n") }
        if let d = value as? [String: Any] {
            return ["text", "content", "children"].compactMap { d[$0] }.map(flatten).filter { !$0.isEmpty }.joined(separator: "\n")
        }
        return ""
    }

    private static func stripReasoning(_ s: String) -> String {
        guard let r = s.range(of: "</think>") ?? s.range(of: "</thinking>") else { return s }
        return String(s[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
