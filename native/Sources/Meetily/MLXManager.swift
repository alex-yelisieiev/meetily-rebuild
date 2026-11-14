import Foundation
import Observation

/// Installs what the MLX Whisper backend needs on a fresh Mac:
/// the Python runtime (bundled sources + a uv-managed venv) and the large-v3 MLX weights.
/// Paths match what the engine expects (see mlx_sidecar.rs).
@MainActor
@Observable
final class MLXManager {
    static let shared = MLXManager()

    enum Phase: Equatable { case idle, runtime(String), model(Double), failed(String) }

    var phase: Phase = .idle
    var runtimeReady = false
    var modelReady = false
    var modelSizeMB = 0
    /// Approximate size shown before downloading.
    static let modelDownloadMB = 3_080

    /// Why this Mac can't run MLX, or nil when it can. MLX needs an Apple Silicon GPU (Metal) and macOS 13.5+.
    nonisolated static let unsupportedReason: String? = {
        var arm: Int32 = 0; var size = MemoryLayout<Int32>.size
        let isAppleSilicon = sysctlbyname("hw.optional.arm64", &arm, &size, nil, 0) == 0 && arm == 1
            && ProcessInfo.processInfo.environment["MEETILY_SIMULATE_NO_MLX"] == nil
        if !isAppleSilicon { return "MLX runs only on Apple Silicon (M-series) Macs. This Mac has an Intel processor, so use a regular Whisper or Parakeet model instead." }
        if !ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 13, minorVersion: 5, patchVersion: 0)) {
            return "MLX needs macOS 13.5 or later. Update macOS or use a regular Whisper or Parakeet model instead."
        }
        return nil
    }()
    nonisolated static var isSupported: Bool { unsupportedReason == nil }

    nonisolated static let repo = "https://huggingface.co/mlx-community/whisper-large-v3-mlx/resolve/main/"
    nonisolated static let modelFiles = ["config.json", "weights.npz"]

    let root: URL
    var runtimeDir: URL {
        if let p = ProcessInfo.processInfo.environment["MEETILY_MLX_PROJECT"] { return URL(fileURLWithPath: p) }
        return root.appending(path: "mlx-whisper-runtime")
    }
    var modelDir: URL { root.appending(path: "models/mlx-whisper-large-v3") }
    private var python: URL { runtimeDir.appending(path: ".venv/bin/python") }
    private var bundled: URL? { Bundle.main.resourceURL?.appending(path: "MLXRuntime") }
    private var work: Task<Void, Never>?
    private var downloader: FileDownloader?

    var isBusy: Bool { if case .runtime = phase { return true }; if case .model = phase { return true }; return false }

    init(root: URL? = nil) {
        if let root { self.root = root }
        else if let r = ProcessInfo.processInfo.environment["MEETILY_MLX_HOME"] { self.root = URL(fileURLWithPath: r) }
        else { self.root = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/com.meetily.ai") }
        refresh()
    }

    func refresh() {
        let fm = FileManager.default
        runtimeReady = fm.isExecutableFile(atPath: python.path) && !runtimeOutdated()
        modelReady = fm.fileExists(atPath: modelDir.appending(path: "config.json").path)
            && fm.fileExists(atPath: modelDir.appending(path: "weights.npz").path)
        modelSizeMB = modelReady ? Self.dirSizeMB(modelDir) : 0
    }

    /// Runtime setup happens on its own at launch (small); the 3 GB model only on request.
    func ensureRuntimeInBackground() {
        guard Self.isSupported, !runtimeReady, !isBusy else { return }
        work = Task { _ = await installRuntime() }
    }

    func install() {
        guard Self.isSupported, !isBusy else { return }
        work = Task {
            guard await installRuntime() else { return }
            _ = await downloadModel()
        }
    }

    func cancel() {
        work?.cancel()
        downloader?.cancel()
        phase = .idle
        refresh()
    }

    func deleteModel() {
        try? FileManager.default.removeItem(at: modelDir)
        refresh()
    }

    // MARK: Runtime

    private func runtimeOutdated() -> Bool {
        guard let bundled else { return false }
        for f in ["pyproject.toml", "uv.lock", "src/meetily_sidecar.py"] {
            let a = try? Data(contentsOf: bundled.appending(path: f))
            let b = try? Data(contentsOf: runtimeDir.appending(path: f))
            if a != nil && a != b { return true }
        }
        return false
    }

    @discardableResult
    func installRuntime() async -> Bool {
        guard Self.isSupported else { return false }
        refresh()
        if runtimeReady { return true }
        guard let bundled, FileManager.default.fileExists(atPath: bundled.path) else {
            phase = .failed("The MLX runtime files are missing from the app bundle.")
            return false
        }
        do {
            phase = .runtime("Preparing the MLX runtime…")
            let fm = FileManager.default
            try fm.createDirectory(at: runtimeDir.appending(path: "src"), withIntermediateDirectories: true)
            for f in ["pyproject.toml", "uv.lock", "src/__init__.py", "src/meetily_sidecar.py"] {
                let dst = runtimeDir.appending(path: f)
                try? fm.removeItem(at: dst)
                try fm.copyItem(at: bundled.appending(path: f), to: dst)
            }
            let uv = try await locateOrFetchUV()
            phase = .runtime("Installing Python and MLX (one time)…")
            try await Self.run(uv, ["sync", "--frozen", "--no-dev", "--python", "3.12"], in: runtimeDir)
            refresh()
            guard runtimeReady else { throw SetupError("The MLX runtime didn't finish installing.") }
            phase = .idle
            return true
        } catch is CancellationError {
            phase = .idle; return false
        } catch {
            phase = .failed(error.localizedDescription); return false
        }
    }

    private func locateOrFetchUV() async throws -> URL {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let ours = root.appending(path: "bin/uv")
        var candidates = [ours.path]
        if ProcessInfo.processInfo.environment["MEETILY_FORCE_UV_DOWNLOAD"] == nil {
            candidates += ["\(home)/.local/bin/uv", "/opt/homebrew/bin/uv", "/usr/local/bin/uv", "\(home)/.cargo/bin/uv"]
        }
        if let found = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return URL(fileURLWithPath: found) }

        phase = .runtime("Downloading the uv installer…")
        let tmp = fm.temporaryDirectory.appending(path: "meetily-uv-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let tgz = tmp.appending(path: "uv.tar.gz")
        let d = FileDownloader()
        downloader = d
        try await d.download(URL(string: "https://github.com/astral-sh/uv/releases/latest/download/uv-aarch64-apple-darwin.tar.gz")!, to: tgz) { _ in }
        try await Self.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", tgz.path, "-C", tmp.path], in: tmp)
        guard let extracted = fm.enumerator(at: tmp, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "uv" && fm.isExecutableFile(atPath: $0.path) })
        else { throw SetupError("Couldn't unpack uv.") }
        try fm.createDirectory(at: ours.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: ours)
        try fm.moveItem(at: extracted, to: ours)
        return ours
    }

    // MARK: Model

    @discardableResult
    func downloadModel() async -> Bool {
        refresh()
        if modelReady { phase = .idle; return true }
        let fm = FileManager.default
        let partial = modelDir.deletingLastPathComponent().appending(path: "mlx-whisper-large-v3.partial")
        do {
            try fm.createDirectory(at: partial, withIntermediateDirectories: true)
            phase = .model(0)
            // config.json is tiny; weights.npz is the whole download.
            let d = FileDownloader()
            downloader = d
            try await d.download(URL(string: Self.repo + "config.json")!, to: partial.appending(path: "config.json")) { _ in }
            try await d.download(URL(string: Self.repo + "weights.npz")!, to: partial.appending(path: "weights.npz")) { [weak self] f in
                Task { @MainActor in if case .model = self?.phase { self?.phase = .model(f) } }
            }
            try? fm.removeItem(at: modelDir)
            try fm.moveItem(at: partial, to: modelDir)
            refresh()
            phase = .idle
            return modelReady
        } catch {
            try? fm.removeItem(at: partial)
            if error is CancellationError || (error as? URLError)?.code == .cancelled { phase = .idle }
            else { phase = .failed("Model download failed: \(error.localizedDescription)") }
            refresh()
            return false
        }
    }

    // MARK: Helpers

    struct SetupError: LocalizedError { let message: String; init(_ m: String) { message = m }; var errorDescription: String? { message } }

    nonisolated static func dirSizeMB(_ dir: URL) -> Int {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = files.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.reduce(0, +)
        return bytes / (1024 * 1024)
    }

    nonisolated static func run(_ exe: URL, _ args: [String], in dir: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            p.currentDirectoryURL = dir
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            env.removeValue(forKey: "VIRTUAL_ENV")
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            p.terminationHandler = { proc in
                let log = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 { cont.resume() }
                else { cont.resume(throwing: SetupError("\(exe.lastPathComponent) failed: \(log.split(separator: "\n").suffix(3).joined(separator: " "))")) }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}

/// URLSession download with progress and cancellation; moves the result into place.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var session: URLSession?
    private var cont: CheckedContinuation<Void, Error>?
    private var dest: URL?
    private var onProgress: ((Double) -> Void)?
    private var cancelled = false
    private let lock = NSLock()

    func download(_ url: URL, to dest: URL, progress: @escaping (Double) -> Void) async throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    self.cont = c; self.dest = dest; self.onProgress = progress
                    let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
                    self.session = s
                    s.downloadTask(with: url).resume()
                }
            }
        } onCancel: { self.cancel() }
    }

    func cancel() {
        lock.withLock { cancelled = true; session?.invalidateAndCancel() }
    }

    private func finish(_ result: Result<Void, Error>) {
        let c: CheckedContinuation<Void, Error>? = lock.withLock { let c = cont; cont = nil; return c }
        c?.resume(with: result)
        session?.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(MLXManager.SetupError("HTTP \(http.statusCode)"))); return
        }
        do {
            guard let dest else { return }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            finish(.success(()))
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(lock.withLock({ cancelled }) ? CancellationError() : error)) }
    }
}

/// `Meetily --mlx-selftest` installs runtime + model into $MEETILY_MLX_HOME (fresh-install check), then exits.
enum MLXSelfTest {
    @MainActor static func runBlocking() {
        Task { @MainActor in
            if let reason = MLXManager.unsupportedReason { print("unsupported:", reason); fflush(stdout); exit(2) }
            let m = MLXManager.shared
            let start = Date()
            print("root:", m.root.path, "runtime:", m.runtimeDir.path)
            var last = -10.0
            let watcher = Task { @MainActor in
                while !Task.isCancelled {
                    switch m.phase {
                    case .runtime(let s): print("runtime:", s)
                    case .model(let p) where p - last >= 10: print(String(format: "model: %.0f%%", p)); last = p
                    default: break
                    }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            let rt = await m.installRuntime()
            print("runtimeReady:", rt, m.phase)
            let md = rt ? await m.downloadModel() : false
            watcher.cancel()
            print("modelReady:", md, "sizeMB:", m.modelSizeMB, m.phase, String(format: "%.0fs", Date().timeIntervalSince(start)))
            fflush(stdout)
            exit(rt && md ? 0 : 1)
        }
        while true { RunLoop.main.run(mode: .default, before: .distantFuture) }
    }
}
