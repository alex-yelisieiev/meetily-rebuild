import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Group {
            switch app.engineState {
            case .starting:
                ProgressView("Starting Meetily…")
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let reason):
                ContentUnavailableView {
                    Label("The engine isn't running", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(reason)
                } actions: {
                    Button("Try Again") { Task { await app.boot() } }
                        .buttonStyle(.glassProminent)
                    Button("Show Engine Log") {
                        NSWorkspace.shared.activateFileViewerSelecting([EngineClient.logURL])
                    }
                    .buttonStyle(.glass)
                }
            case .ready:
                NavigationSplitView {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 380)
                } detail: {
                    DetailRouter()
                }
                .searchable(text: $app.searchText, placement: .sidebar, prompt: "Search transcripts")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { RecordToolbarButton() }
                }
            }
        }
        .overlay(alignment: .top) { BannerView() }
        .sheet(isPresented: Binding(get: { app.importJob != nil }, set: { if !$0 && app.importJob?.running != true { app.importJob = nil } })) {
            ImportAudioSheet()
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard app.importAndRetranscribe, let url = urls.first(where: { AppModel.audioExtensions.contains($0.pathExtension.lowercased()) }) else { return false }
            Task { await app.prepareImport(url) }
            return true
        }
        .task { await app.boot() }
    }
}

struct RecordToolbarButton: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        switch app.phase {
        case .idle:
            Button {
                Task { await app.startRecording() }
            } label: {
                Label("New Recording", systemImage: "record.circle")
            }
            .help("Start recording (⇧⌘R)")
        case .recording, .paused:
            Button {
                app.selection = liveSelectionID
            } label: {
                Label("Recording", systemImage: "waveform")
                    .symbolEffect(.variableColor.iterative, isActive: app.phase == .recording)
            }
            .tint(.red)
            .help("Show the live recording")
        case .starting, .finishing:
            ProgressView().controlSize(.small)
        }
    }
}

struct BannerView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let message = app.banner {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { app.banner = nil }
        }
    }
}

struct DetailRouter: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.selection == liveSelectionID, app.isRecording {
            LiveRecordingView()
        } else if let id = app.selection, app.meetings.contains(where: { $0.id == id }) {
            MeetingDetailView(meetingId: id)
                .id("\(id)-\(app.detailRevision)")
        } else {
            WelcomeView()
        }
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 22) {
            if let snap = app.recovery {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Unsaved recording found", systemImage: "exclamationmark.arrow.circlepath")
                        .font(.headline)
                    Text("“\(snap.name)”, \(snap.startedAt.formatted(date: .abbreviated, time: .shortened)), \(snap.segments.count) segments")
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Discard", role: .destructive) { Task { await app.discardPending() } }
                            .buttonStyle(.glass)
                        Button("Recover") { Task { await app.recoverPending() } }
                            .buttonStyle(.glassProminent)
                    }
                }
                .padding(18)
                .frame(maxWidth: 440)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
            }
            if app.meetingsLoaded && app.recovery == nil {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 48))
                    .foregroundStyle(.quaternary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ImportAudioSheet: View {
    @Environment(AppModel.self) private var app
    @State private var title = ""
    @State private var language = Prefs.primaryLanguage == "auto-translate" ? "auto" : Prefs.primaryLanguage

    var body: some View {
        if let job = app.importJob {
            VStack(alignment: .leading, spacing: 16) {
                Text("Import Audio").font(.title2.weight(.semibold))
                LabeledContent("File", value: job.filename)
                if job.duration > 0 { LabeledContent("Length", value: formatClock(job.duration)) }
                TextField("Title", text: $title).disabled(job.running)
                Picker("Language", selection: $language) {
                    ForEach(Languages.transcription.filter { $0.code != "auto-translate" }) { Text($0.name).tag($0.code) }
                }
                .disabled(job.running)
                if let p = job.progress {
                    if let failed = p.failed {
                        Label(failed, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    } else {
                        ProgressView(value: min(max(p.percent, 0), 100), total: 100) { Text(p.message) }
                    }
                }
                HStack {
                    Spacer()
                    Button("Cancel") { Task { await app.cancelImport() } }
                    if !job.running {
                        Button("Import") { Task { await app.startImport(title: title.isEmpty ? job.title : title, language: language) } }
                            .buttonStyle(.glassProminent)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(24)
            .frame(width: 460)
            .onAppear { title = job.title }
        }
    }
}
