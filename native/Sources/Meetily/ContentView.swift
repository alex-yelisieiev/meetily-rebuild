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
        ContentUnavailableView {
            Label("Meetily", systemImage: "waveform.badge.mic")
        } description: {
            Text(app.meetings.isEmpty ? "Record your first meeting. Everything is transcribed on this Mac."
                                      : "Pick a meeting on the left, or start a new recording.")
        } actions: {
            Button {
                Task { await app.startRecording() }
            } label: {
                Label("Start Recording", systemImage: "record.circle")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(app.isRecording)
        }
    }
}
