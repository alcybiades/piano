import Foundation
import PianoCore

@MainActor
protocol TutorProvider: AnyObject {
    var onNotification: ((String, [String: Any]) -> Void)? { get set }
    var onToolCall: ((String, [String: Any]) async throws -> String)? { get set }
    func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any]
    func disconnect()
}

/// One owned stdio app-server; credentials remain under Codex's management.
@MainActor
final class CodexClient: TutorProvider {
    var onNotification: ((String, [String: Any]) -> Void)?
    var onToolCall: ((String, [String: Any]) async throws -> String)?
    var onDisconnect: ((String) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var buffer = Data()
    private var sequence = 0
    private var generation = UUID()
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]

    static func discover() -> String {
        let fm = FileManager.default
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidates = path.split(separator: ":").map { String($0) + "/codex" } + [
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex", "/Applications/ChatGPT.app/Contents/Resources/codex"
        ]
        if let found = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return found }
        let versions = fm.homeDirectoryForCurrentUser.appendingPathComponent(".nvm/versions/node")
        if let dirs = try? fm.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil),
           let found = dirs.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }).map({ $0.appendingPathComponent("bin/codex").path }).first(where: { fm.isExecutableFile(atPath: $0) }) { return found }
        return ""
    }
    func connect(executable: String, cwd: URL) async throws {
        disconnect()
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw PianoError("Choose your Codex executable in Settings. Install Codex CLI and run ‘codex login’ first.") }
        let p = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["app-server", "--listen", "stdio://", "-c", "model_provider=\"openai\"", "-c", "features.shell_tool=false", "-c", "features.apps=false", "-c", "features.plugins=false", "-c", "features.multi_agent=false", "-c", "web_search=\"disabled\""]
        p.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = URL(fileURLWithPath: executable).deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        // Do not accidentally select billable API auth inherited from the parent app.
        env.removeValue(forKey: "OPENAI_API_KEY"); env.removeValue(forKey: "CODEX_API_KEY")
        p.environment = env; p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr
        process = p; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading; errors = stderr.fileHandleForReading
        let token = generation
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in guard let self, self.generation == token else { return }; self.receive(data) }
        }
        // Drain stderr without persisting potentially sensitive server diagnostics.
        errors?.readabilityHandler = { handle in _ = handle.availableData }
        p.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.failAll(PianoError("Codex exited (\(process.terminationStatus)). Reconnect in Settings."))
                self.onDisconnect?("Codex disconnected. Reconnect in Settings.")
            }
        }
        do { try p.run() } catch { disconnect(); throw error }
        _ = try await request("initialize", ["clientInfo": ["name": "cadenza_piano", "title": "Cadenza", "version": "0.1.0"], "capabilities": ["experimentalApi": true]])
        try send(["method": "initialized", "params": [:]])
    }
    func request(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        guard process?.isRunning == true else { throw PianoError("Codex is not connected.") }
        sequence += 1; let id = sequence
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            deadlines[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                guard !Task.isCancelled, let self, let pending = self.pending.removeValue(forKey: id) else { return }
                self.deadlines.removeValue(forKey: id); pending.resume(throwing: PianoError("Codex did not respond to \(method). Reconnect and try again."))
            }
            do { try send(["id": id, "method": method, "params": params]) }
            catch { pending.removeValue(forKey: id)?.resume(throwing: error); deadlines.removeValue(forKey: id)?.cancel() }
        }
    }
    private func send(_ object: [String: Any]) throws {
        guard let input else { throw PianoError("Codex input is closed.") }
        var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
        try input.write(contentsOf: data)
    }
    private func receive(_ data: Data) {
        guard !data.isEmpty else { output?.readabilityHandler = nil; return }
        buffer.append(data)
        guard buffer.count < 16_000_000 else { disconnect(); onDisconnect?("Codex sent an oversized message."); return }
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer.subdata(in: 0..<end); buffer.removeSubrange(0...end)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let method = object["method"] as? String {
                let params = object["params"] as? [String: Any] ?? [:]
                if let id = object["id"] { handleServerRequest(id, method: method, params: params) }
                else { onNotification?(method, params) }
            } else if let id = object["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
                deadlines.removeValue(forKey: id)?.cancel()
                if let error = object["error"] as? [String: Any] { continuation.resume(throwing: PianoError(error["message"] as? String ?? "Codex request failed.")) }
                else { continuation.resume(returning: object["result"] as? [String: Any] ?? [:]) }
            }
        }
    }
    private func handleServerRequest(_ id: Any, method: String, params: [String: Any]) {
        let token = generation
        Task {
            guard token == generation else { return }
            if method == "item/tool/call" {
                do {
                    guard let tool = params["tool"] as? String, let handler = onToolCall else { throw PianoError("Unknown piano tool.") }
                    let text = try await handler(tool, params)
                    guard token == generation else { return }
                    try send(["id": id, "result": ["success": true, "contentItems": [["type": "inputText", "text": text]]]])
                } catch {
                    try? send(["id": id, "result": ["success": false, "contentItems": [["type": "inputText", "text": error.localizedDescription]]]])
                }
            } else if method.contains("requestApproval") {
                try? send(["id": id, "result": ["decision": "decline"]])
            } else {
                try? send(["id": id, "error": ["code": -32601, "message": "Cadenza supports piano tools only; ask the user in conversation instead."]])
            }
        }
    }
    private func failAll(_ error: Error) {
        let requests = pending; pending.removeAll()
        for deadline in deadlines.values { deadline.cancel() }; deadlines.removeAll()
        for continuation in requests.values { continuation.resume(throwing: error) }
    }
    func disconnect() {
        generation = UUID()
        output?.readabilityHandler = nil; errors?.readabilityHandler = nil
        try? input?.close(); input = nil
        if let process, process.isRunning { process.terminate() }
        process = nil; output = nil; errors = nil; buffer.removeAll()
        failAll(PianoError("Codex connection closed."))
    }
}
