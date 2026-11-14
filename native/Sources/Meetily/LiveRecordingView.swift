import SwiftUI

struct LiveRecordingView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    header
                    if app.phase == .starting {
                        ProgressView().controlSize(.small).padding(.top, 8)
                    }
                    ForEach(app.liveSegments) { seg in
                        TranscriptRow(time: seg.start, text: seg.text, dimmed: seg.isPartial)
                            .id(seg.sequence)
                    }
                    Color.clear.frame(height: 110).id("bottom")
                }
                .padding(.horizontal, 32)
                .padding(.top, 24)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: app.liveSegments.count) {
                withAnimation(.smooth) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .overlay(alignment: .bottom) { controls.padding(.bottom, 22) }
        .navigationTitle(app.currentMeetingName)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(app.currentMeetingName)
                .font(.largeTitle.weight(.semibold))
            Spacer()
            MicLevelMeter()
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var controls: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(app.phase == .recording ? Color.red : Color.orange)
                        .symbolEffect(.pulse, isActive: app.phase == .recording)
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(formatClock(app.elapsed(at: ctx.date)))
                            .font(.title3.monospacedDigit().weight(.medium))
                    }
                    if case .finishing(let status) = app.phase {
                        Text(status).foregroundStyle(.secondary)
                    } else if app.phase == .paused {
                        Text("Paused").foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 18)
                .frame(height: 46)
                .glassEffect(.regular, in: .capsule)

                if app.phase == .recording || app.phase == .paused {
                    Button {
                        Task { await app.togglePause() }
                    } label: {
                        Image(systemName: app.phase == .paused ? "play.fill" : "pause.fill")
                            .font(.title3)
                            .frame(width: 46, height: 46)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .help(app.phase == .paused ? "Resume" : "Pause")

                    Button {
                        Task { await app.stopRecording() }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.title3.weight(.medium))
                            .padding(.horizontal, 20)
                            .frame(height: 46)
                            .foregroundStyle(.white)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(.red).interactive(), in: .capsule)
                    .help("Stop and save (⇧⌘R)")
                } else if case .finishing = app.phase {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 46, height: 46)
                        .glassEffect(.regular, in: .circle)
                }
            }
        }
    }
}

/// Its own view so frequent level updates only redraw the meter, not the whole screen.
private struct MicLevelMeter: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let level = app.audioLevels[app.micDevice] ?? 0
        ProgressView(value: min(level, 1)).frame(width: 80).opacity(level > 0 ? 1 : 0)
    }
}

struct TranscriptRow: View {
    let time: Double?
    let text: String
    var dimmed = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(time.map(formatClock) ?? "")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .trailing)
            Text(text)
                .font(.body)
                .lineSpacing(3)
                .foregroundStyle(dimmed ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
