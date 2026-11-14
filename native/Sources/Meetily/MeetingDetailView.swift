import SwiftUI
import AppKit

struct MeetingDetailView: View {
    @Environment(AppModel.self) private var app
    @State private var model: MeetingDetailModel
    @State private var tab: Tab = .summary
    @State private var title = ""
    @State private var confirmDelete = false
    @State private var showRetranscribe = false
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
                if !model.editing { contextField }
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
                if model.isSummarizing {
                    Button { Task { await model.cancelSummary() } } label: {
                        Label("Stop Summary", systemImage: "stop.fill")
                    }
                    .help("Stop generating the summary")
                } else {
                    Button {
                        tab = .summary
                        Task { await model.generateSummary(template: app.summaryTemplate) }
                    } label: {
                        Label(model.summaryMarkdown == nil ? "Generate Summary" : "Regenerate Summary", systemImage: "sparkles")
                    }
                    .disabled(model.lines.isEmpty)
                    .help(model.summaryMarkdown == nil ? "Generate summary" : "Regenerate summary")
                }

                Menu {
                    Picker("Template", selection: Binding(get: { app.summaryTemplate }, set: { app.summaryTemplate = $0 })) {
                        ForEach(app.templates) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Menu("Summary Language: \(Languages.summaryName(model.summaryLanguage))") {
                        Button { Task { await model.setSummaryLanguage(nil) } } label: {
                            if model.summaryLanguage == nil { Label("Auto", systemImage: "checkmark") } else { Text("Auto") }
                        }
                        let recents = Prefs.summaryLanguageRecents
                        if !recents.isEmpty {
                            Section("Recent") {
                                ForEach(recents, id: \.self) { code in languageButton(code) }
                            }
                        }
                        Section("All Languages") {
                            ForEach(Languages.summary) { languageButton($0.code) }
                        }
                    }
                    Divider()
                    SettingsLink { Text("Summary Model…") }
                } label: {
                    Label("Summary Options", systemImage: "slider.horizontal.3")
                }
                .help("Template, language and model")

                Button {
                    let text = tab == .summary ? (model.editing ? model.draft : (model.summaryMarkdown ?? "")) : model.transcriptText
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
                .help("Open the recording folder")

                if app.importAndRetranscribe, model.meta?.folder_path != nil {
                    Button { showRetranscribe = true } label: {
                        Label("Re-transcribe", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .help("Transcribe the saved audio again")
                }

                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Delete", systemImage: "trash")
                }
                .help("Delete this meeting")
            }
        }
        .sheet(isPresented: $showRetranscribe) {
            RetranscribeSheet(meetingId: model.meetingId, folder: model.meta?.folder_path ?? "")
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
            if app.autoSummaryPending.remove(model.meetingId) != nil,
               model.summaryMarkdown == nil, !model.isSummarizing, !model.lines.isEmpty {
                tab = .summary
                await model.generateSummary(template: app.summaryTemplate)
            } else if model.summaryMarkdown == nil && !model.isSummarizing { tab = .transcript }
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
        if let job = app.retranscribeJobs[model.meetingId], job.failed == nil {
            progressCard(job.message.isEmpty ? "Re-transcribing…" : job.message, job.percent) {
                Task { await app.cancelRetranscribe(meetingId: model.meetingId) }
            }
        }
        if model.isSummarizing {
            progressCard("Writing the summary…", nil) { Task { await model.cancelSummary() } }
        }
        if let error = model.summaryError, !model.isSummarizing {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
        if model.editing {
            TextEditor(text: $model.draft)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(minHeight: 360)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
            HStack {
                Spacer()
                Button("Cancel") { model.editing = false }
                    .buttonStyle(.glass)
                Button(model.saving ? "Saving…" : "Save") { Task { await model.saveEdits() } }
                    .buttonStyle(.glassProminent)
                    .disabled(model.saving)
                    .keyboardShortcut("s", modifiers: .command)
            }
        } else if let md = model.summaryMarkdown {
            MarkdownView(markdown: md)
                .opacity(model.isSummarizing ? 0.5 : 1)
            HStack {
                Spacer()
                Button { model.beginEditing() } label: { Label("Edit", systemImage: "pencil") }
                    .buttonStyle(.glass)
                    .disabled(model.isSummarizing)
            }
        } else if !model.isSummarizing && !model.loading {
            VStack(spacing: 16) {
                Text("No summary yet")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
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

    private var contextField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Summary Prompt", systemImage: "text.bubble")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("Add context for the AI summary: people involved, meeting overview, objective…", text: $model.customPrompt, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.plain)
                .padding(12)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
        }
    }

    private func progressCard(_ text: String, _ percent: Double?, cancel: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            if let percent {
                ProgressView(value: min(max(percent, 0), 100), total: 100).frame(width: 120)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text)
            Spacer()
            Button("Cancel", action: cancel).buttonStyle(.glass)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func languageButton(_ code: String) -> some View {
        Button { Task { await model.setSummaryLanguage(code) } } label: {
            if model.summaryLanguage == code { Label(Languages.summaryName(code), systemImage: "checkmark") }
            else { Text(Languages.summaryName(code)) }
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if model.loading {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
        } else if let error = model.loadError {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        } else if model.lines.isEmpty {
            Text("No transcript").foregroundStyle(.secondary)
        } else {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(model.lines) { line in
                    TranscriptRow(time: line.audio_start_time, text: line.text)
                }
            }
        }
    }
}

struct RetranscribeSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let meetingId: String
    let folder: String
    @State private var language = Prefs.primaryLanguage == "auto-translate" ? "auto" : Prefs.primaryLanguage

    var body: some View {
        let job = app.retranscribeJobs[meetingId]
        VStack(alignment: .leading, spacing: 16) {
            Text("Re-transcribe Meeting").font(.title2.weight(.semibold))
            Picker("Language", selection: $language) {
                ForEach(Languages.transcription.filter { $0.code != "auto-translate" }) { Text($0.name).tag($0.code) }
            }
            .disabled(job != nil && job?.failed == nil)
            if let job {
                if let failed = job.failed {
                    Label(failed, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else {
                    ProgressView(value: min(max(job.percent, 0), 100), total: 100) { Text(job.message) }
                }
            }
            HStack {
                Spacer()
                Button(job != nil && job?.failed == nil ? "Run in Background" : "Cancel") { dismiss() }
                if job != nil && job?.failed == nil {
                    Button("Stop", role: .destructive) { Task { await app.cancelRetranscribe(meetingId: meetingId) } }
                } else {
                    Button("Start") { Task { await app.startRetranscribe(meetingId: meetingId, folder: folder, language: language) } }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 440)
        .onChange(of: app.retranscribeJobs[meetingId] == nil) { _, gone in if gone { dismiss() } }
    }
}
