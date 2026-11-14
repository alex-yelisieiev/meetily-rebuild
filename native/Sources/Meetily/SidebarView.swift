import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @State private var renaming: Meeting?
    @State private var renameText = ""
    @State private var deleting: Meeting?

    var body: some View {
        @Bindable var app = app
        List(selection: $app.selection) {
            if app.isRecording {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.phase == .paused ? "Paused" : "Recording")
                            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                Text(formatClock(app.elapsed(at: ctx.date)))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "record.circle.fill")
                            .foregroundStyle(.red)
                            .symbolEffect(.pulse, isActive: app.phase == .recording)
                    }
                    .tag(liveSelectionID)
                }
            }

            if !app.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                Section(app.isSearching ? "Searching…" : "Results") {
                    ForEach(app.searchHits) { hit in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hit.title).lineLimit(1)
                            Text(hit.matchContext)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .tag(hit.id)
                    }
                    if !app.isSearching && app.searchHits.isEmpty {
                        Text("No matches").foregroundStyle(.secondary)
                    }
                }
            } else {
                ForEach(groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.meetings) { meeting in
                            MeetingRow(meeting: meeting)
                                .tag(meeting.id)
                                .contextMenu {
                                    Button("Rename…") { renameText = meeting.title; renaming = meeting }
                                    Button("Show in Finder") { app.revealInFinder(meeting.id) }
                                    Divider()
                                    Button("Delete…", role: .destructive) { deleting = meeting }
                                }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if app.meetingsLoaded && app.meetings.isEmpty && app.searchText.isEmpty && !app.isRecording {
                Text("No meetings yet").foregroundStyle(.secondary)
            }
        }
        .alert("Rename Meeting", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                if let m = renaming { Task { await app.rename(m.id, to: renameText) } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(deleting?.title ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Meeting", role: .destructive) {
                if let m = deleting { Task { await app.delete(m.id) } }
            }
        } message: {
            Text("The transcript and summary are removed from Meetily.")
        }
    }

    private var groups: [(title: String, meetings: [Meeting])] {
        let cal = Calendar.current
        let now = Date()
        var buckets: [(String, [Meeting])] = []
        func add(_ title: String, _ m: Meeting) {
            if let i = buckets.firstIndex(where: { $0.0 == title }) { buckets[i].1.append(m) } else { buckets.append((title, [m])) }
        }
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "LLLL yyyy"
        for m in app.meetings {
            guard let d = m.createdAt else { add("Older", m); continue }
            if cal.isDateInToday(d) { add("Today", m) }
            else if cal.isDateInYesterday(d) { add("Yesterday", m) }
            else if let days = cal.dateComponents([.day], from: d, to: now).day, days < 7 { add("Previous 7 Days", m) }
            else { add(monthFormatter.string(from: d).capitalized, m) }
        }
        return buckets.map { (title: $0.0, meetings: $0.1) }
    }
}

struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meeting.title)
                .lineLimit(2)
            if let d = meeting.createdAt {
                Text(d.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
