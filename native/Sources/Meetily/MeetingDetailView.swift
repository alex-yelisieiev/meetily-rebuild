import SwiftUI
import AppKit

struct MeetingDetailView: View {
    @Environment(AppModel.self) private var app
    @State private var model: MeetingDetailModel
    @State private var tab: Tab = .summary
    @State private var title = ""
    @State private var confirmDelete = false
    @FocusState private var titleFocused: Bool

    enum Tab: String, CaseIterable, Identifiable {
        case summary = "Summary", transcript = "Transcript"
        var id: String { rawValue }
    }

    init(meetingId: String) {
        _model = State(initialValue: MeetingDetailModel(meetingId: meetingId))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                switch tab {
                case .summary: summary
                case .transcript: transcript
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 26)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(title.isEmpty ? "Meeting" : title)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            ToolbarItemGroup {
                Button {
                    Task { await model.generateSummary(template: app.summaryTemplate) }
                    tab = .summary
                } label: {
                    Label(model.summaryMarkdown == nil ? "Generate Summary" : "Regenerate Summary", systemImage: "sparkles")
                }
                .disabled(model.isSummarizing || model.lines.isEmpty)
                .help("Generate a summary with the model chosen in Settings")

                Button {
                    let text = tab == .summary ? (model.summaryMarkdown ?? "") : model.transcriptText
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    app.flash("Copied the \(tab.rawValue.lowercased()).")
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .help("Copy the \(tab.rawValue.lowercased())")

                Button { app.revealInFinder(model.meetingId) } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .help("Show the recording folder")

                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Delete", systemImage: "trash")
                }
                .help("Delete this meeting")
            }
        }
        .confirmationDialog("Delete “\(title)”?", isPresented: $confirmDelete) {
            Button("Delete Meeting", role: .destructive) { Task { await app.delete(model.meetingId) } }
        } message: {
            Text("The transcript and summary are removed from Meetily.")
        }
        .task {
            title = app.meetings.first(where: { $0.id == model.meetingId })?.title ?? ""
            await model.load()
            if let t = model.meta?.title, !titleFocused { title = t }
            if model.summaryMarkdown == nil && !model.isSummarizing { tab = .transcript }
        }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: $title, axis: .vertical)
                .font(.largeTitle.weight(.semibold))
                .textFieldStyle(.plain)
                .focused($titleFocused)
                .onSubmit { Task { await app.rename(model.meetingId, to: title) } }
                .onChange(of: titleFocused) { _, focused in
                    if !focused { Task { await app.rename(model.meetingId, to: title) } }
                }
            HStack(spacing: 14) {
                if let d = DateParsing.parse(model.meta?.created_at) {
                    Label(d.formatted(date: .complete, time: .shortened), systemImage: "calendar")
                }
                if model.duration > 0 {
                    Label(formatClock(model.duration), systemImage: "clock")
                }
                if !model.lines.isEmpty {
                    Label("\(model.lines.count) segments", systemImage: "text.alignleft")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
    }

    @ViewBuilder
    private var summary: some View {
        if model.isSummarizing {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Writing the summary…")
                Spacer()
                Button("Cancel") { Task { await model.cancelSummary() } }
                    .buttonStyle(.glass)
            }
            .padding(16)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
        if let error = model.summaryError, !model.isSummarizing {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
        if let md = model.summaryMarkdown {
            MarkdownView(markdown: md)
                .opacity(model.isSummarizing ? 0.5 : 1)
        } else if !model.isSummarizing && !model.loading {
            VStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text("No summary yet")
                    .font(.title3.weight(.medium))
                Text("Meetily can write one from the transcript, locally or with the provider you picked in Settings.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Picker("Template", selection: Binding(get: { app.summaryTemplate }, set: { app.summaryTemplate = $0 })) {
                    ForEach(app.templates) { Text($0.name).tag($0.id) }
                }
                .frame(maxWidth: 320)
                Button {
                    Task { await model.generateSummary(template: app.summaryTemplate) }
                } label: {
                    Label("Generate Summary", systemImage: "sparkles").padding(.horizontal, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(model.lines.isEmpty)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if model.loading {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
        } else if let error = model.loadError {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        } else if model.lines.isEmpty {
            Text("This meeting has no transcript.").foregroundStyle(.secondary)
        } else {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(model.lines) { line in
                    TranscriptRow(time: line.audio_start_time, text: line.text)
                }
            }
        }
    }
}
