import Foundation
import Darwin

enum EngineError: LocalizedError {
    case notRunning
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: return "The Meetily engine isn't running."
        case .failed(let message): return message
        }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// Talks to the embedded Rust engine (headless Tauri runtime) over a Unix socket
/// using newline-delimited JSON.
final class EngineClient: @unchecked Sendable {
    static let shared = EngineClient()

    let dataDir: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.meetily.ai").path
    var socketPath: String { dataDir + "/engine.sock" }
    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Meetily/engine.log")

    private var process: Process?
    private var stdinPipe: Pipe?
    private var handle: FileHandle?
    private let queue = DispatchQueue(label: "meetily.engine.client")
    private var buffer = Data()
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<Any, Error>] = [:]

    /// Called on the main queue for every engine event.
    var onEvent: ((String, Any) -> Void)?
    /// Called on the main queue when the engine goes away unexpectedly.
    var onDisconnect: ((String) -> Void)?
    private var stopping = false

    private func engineExecutable() -> URL? {
        if let override = ProcessInfo.processInfo.environment["MEETILY_ENGINE_PATH"] {
            return URL(fileURLWithPath: override)
        }
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/Engine/Meetily Engine.app/Contents/MacOS/meetily")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    func start() async throws {
        if handle != nil { return }
        // Reuse an engine that is already listening (e.g. after a UI restart).
        if (try? connect()) != nil { return }

        guard let exe = engineExecutable() else {
            throw EngineError.failed("The engine is missing from the app bundle.")
        }
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.createDirectory(at: Self.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: Self.logURL)

        let p = Process()
        p.executableURL = exe
        var env = ProcessInfo.processInfo.environment
        env["MEETILY_HEADLESS"] = "1"
        env["MEETILY_ENGINE_SOCKET"] = socketPath
        p.environment = env
        let input = Pipe()
        let output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = log

        let ready = Flag()
        output.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            log.write(data)
            if !ready.isSet, String(decoding: data, as: UTF8.self).contains("engine_ready") { ready.set() }
        }
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.queue.async {
                self.handle = nil
                self.failAll(EngineError.failed("The engine stopped."))
            }
            if !self.stopping {
                DispatchQueue.main.async { self.onDisconnect?("The engine stopped unexpectedly (code \(proc.terminationStatus)).") }
            }
        }
        try p.run()
        process = p
        stdinPipe = input

        let deadline = Date().addingTimeInterval(90)
        while !ready.isSet {
            if !p.isRunning {
                throw EngineError.failed("The engine quit while starting. Another Meetily may already be open.")
            }
            if Date() > deadline { throw EngineError.failed("The engine took too long to start.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        var lastError: Error?
        for _ in 0..<20 {
            do { try connect(); return } catch { lastError = error }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw lastError ?? EngineError.notRunning
    }

    private func connect() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw EngineError.failed("Couldn't create a socket.") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd); throw EngineError.failed("Socket path is too long.")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        guard result == 0 else { close(fd); throw EngineError.failed("Couldn't reach the engine.") }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        h.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self else { return }
            if data.isEmpty {
                h.readabilityHandler = nil
                self.queue.async {
                    self.handle = nil
                    self.failAll(EngineError.failed("Lost the connection to the engine."))
                }
                return
            }
            self.queue.async { self.consume(data) }
        }
        queue.sync { self.handle = h }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed]) as? [String: Any]
            else { continue }
            if let id = obj["id"] as? Int, let cont = pending.removeValue(forKey: id) {
                if (obj["ok"] as? Bool) == true {
                    cont.resume(returning: obj["result"] ?? NSNull())
                } else {
                    cont.resume(throwing: EngineError.failed(Self.describe(obj["error"])))
                }
            } else if let event = obj["event"] as? String {
                let payload = obj["payload"] ?? NSNull()
                DispatchQueue.main.async { self.onEvent?(event, payload) }
            }
        }
    }

    static func describe(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let d = value as? [String: Any] {
            for key in ["userMessage", "message", "error"] {
                if let s = d[key] as? String { return s }
            }
        }
        if let value, let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) {
            return String(decoding: data, as: UTF8.self)
        }
        return "Unknown engine error."
    }

    private func failAll(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        waiting.values.forEach { $0.resume(throwing: error) }
    }

    @discardableResult
    func call(_ cmd: String, _ args: [String: Any] = [:]) async throws -> Any {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                guard let handle = self.handle else { cont.resume(throwing: EngineError.notRunning); return }
                let id = self.nextId
                self.nextId += 1
                guard var data = try? JSONSerialization.data(withJSONObject: ["id": id, "cmd": cmd, "args": args]) else {
                    cont.resume(throwing: EngineError.failed("Couldn't encode arguments for \(cmd).")); return
                }
                data.append(0x0A)
                self.pending[id] = cont
                do { try handle.write(contentsOf: data) } catch {
                    self.pending.removeValue(forKey: id)
                    cont.resume(throwing: EngineError.failed("Couldn't send \(cmd) to the engine."))
                }
            }
        }
    }

    func call<T: Decodable>(_ cmd: String, _ args: [String: Any] = [:], as type: T.Type) async throws -> T {
        let value = try await call(cmd, args)
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Closing stdin tells the engine to exit cleanly; force-kill as a fallback.
    func stop() {
        stopping = true
        try? stdinPipe?.fileHandleForWriting.close()
        guard let p = process else { return }
        let deadline = Date().addingTimeInterval(4)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate() }
    }
}
