import SwiftUI

/// Plays a recording through a replay-mode `PowerMonitor`, so the regular UI (hero, peak,
/// events, thermals) renders exactly what it would have shown live.
@MainActor
final class ReplayController: ObservableObject {
    let recording: Recording
    @Published private(set) var monitor = PowerMonitor.forReplay()
    /// Number of frames ingested so far.
    @Published private(set) var position = 0
    @Published private(set) var isPlaying = false
    @Published var speed: Double = 10
    static let speeds: [Double] = [1, 10, 60, 600]
    private var task: Task<Void, Never>?
    private static let step: Duration = .milliseconds(100)

    init(recording: Recording) {
        self.recording = recording
        advance(to: 1)
    }

    var count: Int { recording.frames.count }
    var currentDate: Date? { position > 0 ? recording.frames[position - 1].date : nil }

    func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        if position >= count { seek(to: 1) }
        isPlaying = true
        task?.cancel()
        task = Task { [weak self] in
            var cursor = self?.currentDate ?? .distantPast
            while !Task.isCancelled, let self, self.isPlaying {
                try? await Task.sleep(for: Self.step)
                cursor += 0.1 * self.speed
                var target = self.position
                while target < self.count, self.recording.frames[target].date <= cursor { target += 1 }
                self.advance(to: target)
                if self.position >= self.count { self.pause() }
            }
        }
    }

    func pause() {
        isPlaying = false
        task?.cancel()
        task = nil
    }

    /// Jumps to a frame. Going backwards rebuilds the monitor from the start, because peak,
    /// hold and event detection depend on everything before.
    func seek(to frame: Int) {
        let target = min(max(frame, 1), count)
        if target < position {
            monitor = .forReplay()
            position = 0
        }
        advance(to: target)
    }

    private func advance(to target: Int) {
        guard target > position else { return }
        for i in position..<min(target, count) {
            let frame = recording.frames[i]
            monitor.ingest(recording.snapshot(at: i), frame.ambient)
        }
        position = min(target, count)
    }
}

struct ReplayTransport: View {
    @ObservedObject var controller: ReplayController
    @State private var scrub: Double?

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                Button {
                    controller.togglePlay()
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 28, height: 28)
                }
                Slider(value: Binding(get: { scrub ?? Double(controller.position) },
                                      set: { scrub = $0 }),
                       in: 1...Double(max(controller.count, 2))) { editing in
                    if !editing, let value = scrub {
                        controller.seek(to: Int(value))
                        scrub = nil
                    }
                }
                Menu {
                    Picker("Speed", selection: $controller.speed) {
                        ForEach(ReplayController.speeds, id: \.self) { Text("\(Int($0))×").tag($0) }
                    }
                } label: {
                    Text("\(Int(controller.speed))×")
                        .font(.callout.monospacedDigit())
                        .frame(minWidth: 44)
                }
            }
            if let date = scrubDate ?? controller.currentDate {
                Text(date.formatted(date: .abbreviated, time: .standard))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var scrubDate: Date? {
        guard let scrub, controller.count > 0 else { return nil }
        return controller.recording.frames[min(max(Int(scrub), 1), controller.count) - 1].date
    }
}

/// Loads a recording off the main thread, then shows it in the regular UI with a transport bar.
struct ReplayView: View {
    let url: URL
    @State private var controller: ReplayController?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let controller {
                ReplayContent(controller: controller)
            } else {
                NavigationStack {
                    VStack(spacing: 12) {
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        } else {
                            ProgressView("Loading \(url.lastPathComponent)")
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                    }
                }
            }
        }
        .task {
            let url = url
            do {
                let recording = try await Task.detached(priority: .userInitiated) { try Recording(url: url) }.value
                if recording.frames.isEmpty {
                    error = "No samples in this recording."
                } else {
                    controller = ReplayController(recording: recording)
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct ReplayContent: View {
    @ObservedObject var controller: ReplayController

    var body: some View {
        ContentView(monitor: controller.monitor, replay: controller)
    }
}

struct RecordingsView: View {
    /// The file the live monitor is writing to.
    let currentURL: URL?
    @State private var urls: [URL] = []
    @State private var replaying: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if urls.isEmpty {
                    Text("No recordings yet.").foregroundStyle(.secondary)
                }
                ForEach(urls, id: \.self) { url in
                    Button {
                        replaying = url
                    } label: {
                        row(url)
                    }
                    .foregroundStyle(.primary)
                    .swipeActions {
                        if url != currentURL {
                            Button("Delete", role: .destructive) {
                                try? FileManager.default.removeItem(at: url)
                                reload()
                            }
                        }
                        ShareLink(item: url)
                    }
                }
            }
            .navigationTitle("Recordings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .onAppear(perform: reload)
            .fullScreenCover(item: $replaying) { url in
                ReplayView(url: url)
            }
        }
    }

    private func row(_ url: URL) -> some View {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let start = RecordingFormat.fileNameFormatter.date(from: url.deletingPathExtension().lastPathComponent)
        let end = values?.contentModificationDate
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(start?.formatted(date: .abbreviated, time: .shortened) ?? url.lastPathComponent)
                if url == currentURL {
                    Text("Recording").font(.caption2.bold()).foregroundStyle(.red)
                }
            }
            Text([
                zip(start, end).map { Duration.seconds($1.timeIntervalSince($0)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)) },
                values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) },
            ].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func reload() { urls = RecordingFormat.list() }
}

extension URL: @retroactive Identifiable {
    public var id: URL { self }
}

private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
