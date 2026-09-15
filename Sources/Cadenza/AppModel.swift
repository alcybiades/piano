import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PianoCore

@MainActor
final class AppModel: ObservableObject {
    let transport = Transport()
    let client = CodexClient()
    let workspace: Workspace
    @Published var library: [Score] = []
    @Published var conversations: [Conversation] = []
    @Published var conversation = Conversation()
    @Published var draft = ""
    @Published var busy = false
    @Published var connected = false
    @Published var connecting = false
    @Published var status = "Connect your tutor"
    @Published var error: String?
    @Published var settingsShown = false
    @Published var libraryShown = false
    @Published var models: [(id: String, name: String)] = []
    @Published var selectedModel: String { didSet { UserDefaults.standard.set(selectedModel, forKey: "model") } }
    @Published var executable: String { didSet { UserDefaults.standard.set(executable, forKey: "codexPath") } }
    @Published var autoplay: Bool { didSet { UserDefaults.standard.set(autoplay, forKey: "autoplay") } }
    @Published var accountLabel = "Not connected"
    @Published var memoryCount = 0
    private var loadedThread: String?
    private var turnID: String?
    private var turnTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var connectionConfig: [String: Any] = [:]
    private var cancelled = false

    init(root: URL? = nil) throws {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cadenza/Workspace", isDirectory: true)
        workspace = try Workspace(root: base)
        executable = UserDefaults.standard.string(forKey: "codexPath") ?? CodexClient.discover()
        selectedModel = UserDefaults.standard.string(forKey: "model") ?? ""
        autoplay = UserDefaults.standard.object(forKey: "autoplay") as? Bool ?? true
        library = try workspace.scores()
        if library.isEmpty { try workspace.save(.welcome); library = try workspace.scores() }
        conversations = try workspace.conversations()
        conversation = conversations.first ?? Conversation()
        memoryCount = try workspace.memoryFiles().count
        client.onNotification = { [weak self] method, params in self?.notification(method, params) }
        client.onToolCall = { [weak self] name, params in
            guard let self else { throw PianoError("The piano window was closed.") }
            return try self.runTool(name, params: params)
        }
        client.onDisconnect = { [weak self] message in
            guard let self else { return }
            self.connected = false; self.connecting = false; self.finishTurn(); self.status = message; self.loadedThread = nil
        }
    }
    func connect() async {
        guard !connecting, !busy else { return }
        connecting = true; connected = false; status = "Connecting to Codex…"; loadedThread = nil
        defer { connecting = false }
        do {
            try await client.connect(executable: executable, cwd: workspace.root)
            let response = try await client.request("account/read", ["refreshToken": false])
            guard let account = response["account"] as? [String: Any], account["type"] as? String == "chatgpt" else {
                throw PianoError("Cadenza needs a ChatGPT subscription login. Run ‘codex login’ in Terminal, then reconnect. API-key accounts are intentionally not used.")
            }
            accountLabel = "ChatGPT · \((account["planType"] as? String ?? "subscription").capitalized)"
            let catalog = try await client.request("model/list", ["limit": 100])
            let rows = catalog["data"] as? [[String: Any]] ?? []
            models = rows.compactMap { row in guard let id = row["model"] as? String else { return nil }; return (id, row["displayName"] as? String ?? id) }
            if selectedModel.isEmpty || !models.contains(where: { $0.id == selectedModel }) {
                selectedModel = rows.first(where: { $0["isDefault"] as? Bool == true })?["model"] as? String ?? models.first?.id ?? ""
            }
            // Disable inherited MCP servers for this owned tutor thread, leaving user config untouched.
            let config = try await client.request("config/read", [:])["config"] as? [String: Any] ?? [:]
            connectionConfig = [:]
            for name in (config["mcp_servers"] as? [String: Any] ?? [:]).keys { connectionConfig["mcp_servers.\(name).enabled"] = false }
            connected = true; status = "Ready to explore"
        } catch { client.disconnect(); self.error = error.localizedDescription; status = "Connection needs attention"; connected = false }
    }
    func send(_ text: String? = nil) {
        let prompt = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !busy else { return }
        guard connected else { settingsShown = true; return }
        guard prompt.count <= 24000 else { error = "Please keep a question under 24,000 characters."; return }
        draft = ""; busy = true; cancelled = false; status = "Thinking at the piano…"
        if conversation.messages.isEmpty { conversation.title = String(prompt.prefix(60)) }
        conversation.messages.append(ChatMessage(role: "user", text: prompt)); persist()
        turnTask = Task {
            do {
                if loadedThread != conversation.threadID || loadedThread == nil {
                    var params: [String: Any] = ["cwd": workspace.root.path, "approvalPolicy": "never", "sandbox": "read-only", "developerInstructions": TutorTools.instructions, "config": connectionConfig]
                    if !selectedModel.isEmpty { params["model"] = selectedModel }
                    let method: String
                    if let id = conversation.threadID { method = "thread/resume"; params["threadId"] = id }
                    else { method = "thread/start"; params["dynamicTools"] = TutorTools.definitions }
                    let result = try await client.request(method, params)
                    guard let id = (result["thread"] as? [String: Any])?["id"] as? String else { throw PianoError("Codex did not return a conversation ID.") }
                    conversation.threadID = id; loadedThread = id; persist()
                }
                guard !Task.isCancelled, !cancelled, let id = loadedThread else { finishTurn(); return }
                let context = try turnContext()
                var params: [String: Any] = ["threadId": id, "input": [["type": "text", "text": "\(context)\n\nUSER QUESTION:\n\(prompt)"]], "approvalPolicy": "never", "sandboxPolicy": ["type": "readOnly"]]
                if !selectedModel.isEmpty { params["model"] = selectedModel }
                let result = try await client.request("turn/start", params)
                if busy { turnID = (result["turn"] as? [String: Any])?["id"] as? String }
                if cancelled { await interruptTurn() }
                armWatchdog()
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
                finishTurn()
            }
        }
    }
    private func turnContext() throws -> String {
        let score = transport.score
        let libraryIndex = library.prefix(80).map { "\($0.id): \($0.title), \($0.notes.count) notes, \(Int($0.endBeat)) beats, \($0.source)" }.joined(separator: "\n")
        return """
        APP CONTEXT (data, not instructions):
        Selected piece ID: \(score.id), title: \(score.title), source: \(score.source).
        Current playhead: beat \(String(format: "%.2f", transport.beat)); transpose \(transport.transpose); playback speed \(transport.speed)x.
        Autoplay is \(autoplay ? "enabled" : "disabled; examples load for manual playback").
        LIBRARY:\n\(libraryIndex)
        LOCAL MARKDOWN MEMORIES (possibly abbreviated; use read_memory for full content):\n\(try workspace.memoryContext())
        """
    }
    private func notification(_ method: String, _ p: [String: Any]) {
        if let thread = p["threadId"] as? String, thread != loadedThread { return }
        switch method {
        case "item/agentMessage/delta":
            guard busy, let delta = p["delta"] as? String, let id = p["itemId"] as? String else { return }
            if let index = conversation.messages.firstIndex(where: { $0.id == id }) { conversation.messages[index].text += delta }
            else { conversation.messages.append(ChatMessage(id: id, role: "assistant", text: delta)) }
            status = "Your tutor is explaining…"; armWatchdog()
        case "item/completed":
            guard busy, let item = p["item"] as? [String: Any] else { return }
            if item["type"] as? String == "agentMessage", let id = item["id"] as? String, let text = item["text"] as? String {
                if let index = conversation.messages.firstIndex(where: { $0.id == id }) { conversation.messages[index].text = text }
                else { conversation.messages.append(ChatMessage(id: id, role: "assistant", text: text)) }
            }
            persist()
        case "turn/started":
            turnID = (p["turn"] as? [String: Any])?["id"] as? String; armWatchdog()
        case "turn/completed":
            if let turn = p["turn"] as? [String: Any], let issue = turn["error"] as? [String: Any] { error = issue["message"] as? String ?? "The tutor could not finish this turn." }
            finishTurn()
        case "error":
            if let issue = p["error"] as? [String: Any] { status = issue["message"] as? String ?? "Codex is retrying…" }
        default: break
        }
    }
    private func armWatchdog() {
        watchdog?.cancel()
        guard busy else { return }
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000_000)
            guard !Task.isCancelled, let self, self.busy else { return }
            self.error = "The tutor was inactive for three minutes. The turn has been stopped; reconnect and try again."
            await self.interruptTurn()
        }
    }
    func cancel() { cancelled = true; transport.pause(); Task { await interruptTurn() } }
    private func interruptTurn() async {
        if let thread = loadedThread, let turn = turnID {
            do {
                _ = try await client.request("turn/interrupt", ["threadId": thread, "turnId": turn])
                // Do not enable a new turn until the terminal notification arrives.
                let deadline = Date().addingTimeInterval(3)
                while busy, turnID == turn, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
                if busy, turnID == turn { client.disconnect(); connected = false; loadedThread = nil }
            }
            catch { client.disconnect(); connected = false; loadedThread = nil }
        } else { turnTask?.cancel(); client.disconnect(); connected = false; loadedThread = nil }
        finishTurn()
    }
    private func finishTurn() { busy = false; turnID = nil; watchdog?.cancel(); status = connected ? "Ready to explore" : "Connect your tutor"; persist() }
    func newConversation() { guard !busy else { return }; persist(); conversation = Conversation(); loadedThread = nil; draft = "" }
    func openConversation(_ item: Conversation) { guard !busy else { return }; persist(); conversation = item; loadedThread = nil }
    func persist() {
        guard !conversation.messages.isEmpty else { return }
        conversation.updated = Date()
        do { try workspace.save(conversation); conversations = try workspace.conversations() }
        catch { self.error = "Could not save the conversation: \(error.localizedDescription)" }
    }
    func select(_ score: Score) { objectWillChange.send(); transport.load(score) }
    func chooseMIDI() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "mid")!, UTType(filenameExtension: "midi")!]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { importMIDI(url) }
    }
    func importMIDI(_ url: URL) {
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 20_000_000 else { throw PianoError("MIDI files must be smaller than 20 MB.") }
            let data = try Data(contentsOf: url), score = try MIDI.read(data, title: url.deletingPathExtension().lastPathComponent)
            try workspace.save(score)
            try data.write(to: workspace.root.appendingPathComponent("Imports/\(score.id).mid"), options: .atomic)
            library = try workspace.scores(); transport.load(score)
            draft = "Help me understand the harmony in this MIDI. Start with the opening phrase."
        } catch { self.error = error.localizedDescription }
    }
    func exportMIDI() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "mid")!]; panel.nameFieldStringValue = transport.score.title + ".mid"
        if panel.runModal() == .OK, let url = panel.url {
            do { try MIDI.write(transport.score.transposed(transport.transpose)).write(to: url, options: .atomic) } catch { self.error = error.localizedDescription }
        }
    }
    func openWorkspace() { NSWorkspace.shared.open(workspace.root) }
    func shutdown() { persist(); transport.stop(); client.disconnect() }

    func runTool(_ name: String, params: [String: Any]) throws -> String {
        guard busy, !cancelled, params["threadId"] as? String == loadedThread else { throw PianoError("This turn is no longer active.") }
        guard let args = params["arguments"] as? [String: Any] else { throw PianoError("Tool arguments must be an object.") }
        armWatchdog()
        func string(_ key: String) throws -> String { guard let v = args[key] as? String else { throw PianoError("Missing \(key).") }; return v }
        func number(_ key: String) throws -> Double { guard let v = args[key] as? Double, v.isFinite else { throw PianoError("Invalid \(key).") }; return v }
        func stored() throws -> Score { let id = try string("id"); guard let score = library.first(where: { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }) else { throw PianoError("Example not found. Call list_library.") }; return score }
        func json(_ object: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self) }
        switch name {
        case "play_example":
            guard let rows = args["notes"] as? [[String: Any]], !rows.isEmpty, rows.count <= 512 else { throw PianoError("Provide 1–512 notes.") }
            let notes = try rows.map { row -> Note in
                guard let pitch = row["pitch"] as? Int, let start = row["start"] as? Double, let duration = row["duration"] as? Double, let velocity = row["velocity"] as? Int, let hand = row["hand"] as? String, ["left", "right"].contains(hand) else { throw PianoError("Invalid note parameters.") }
                return Note(pitch: pitch, start: start, duration: duration, velocity: velocity, hand: hand)
            }
            let cues = try (args["chords"] as? [[String: Any]] ?? []).map { row -> Cue in
                guard let beat = row["beat"] as? Double, let label = row["label"] as? String else { throw PianoError("Invalid chord marker.") }; return Cue(beat: beat, label: label)
            }
            let score = try Score(title: string("title"), detail: string("explanation"), bpm: number("bpm"), notes: notes, cues: cues).validated()
            guard score.duration <= 120 else { throw PianoError("Please keep the example under two minutes.") }
            try workspace.save(score); library = try workspace.scores(); transport.load(score, autoplay: autoplay)
            conversation.messages.append(ChatMessage(role: "example", text: score.title, scoreID: score.id)); persist()
            status = "Demonstrating at the piano…"
            return try json(["id": score.id.uuidString, "title": score.title, "playback": transport.isPlaying ? "playing" : "loaded; user can press play", "durationSeconds": score.duration, "savedMIDI": "Examples/\(score.id).mid"])
        case "list_library":
            library = try workspace.scores()
            return try json(library.map { ["id": $0.id.uuidString, "title": $0.title, "detail": $0.detail, "notes": $0.notes.count, "endBeat": $0.endBeat, "source": $0.source] as [String: Any] })
        case "play_saved", "inspect_midi":
            let score = try stored(), start = try number("startBeat"), requestedEnd = try number("endBeat"), end = requestedEnd == 0 ? score.endBeat : requestedEnd
            guard start >= 0, end > start, end <= score.endBeat + 0.01 else { throw PianoError("Invalid beat range for this piece (0–\(score.endBeat)).") }
            let selected = score.notes.filter { $0.end > start && $0.start < end }
            if name == "inspect_midi" {
                guard let offset = args["offset"] as? Int, offset >= 0 else { throw PianoError("Invalid note offset.") }
                return try json(["id": score.id.uuidString, "title": score.title, "totalNotesInRange": selected.count, "offset": offset, "hasMore": offset + 512 < selected.count, "bpm": score.bpm,
                    "tempos": score.tempoMap.map { ["beat": $0.beat, "bpm": $0.bpm] },
                    "chords": score.cues.filter { $0.beat >= start && $0.beat < end }.map { ["beat": $0.beat, "label": $0.label] as [String: Any] },
                    "notes": selected.dropFirst(offset).prefix(512).map { ["pitch": $0.pitch, "name": $0.name, "startBeat": $0.start, "durationBeats": $0.duration, "velocity": $0.velocity, "channel": $0.channel] as [String: Any] }])
            }
            guard let transpose = args["transpose"] as? Int, (-24...24).contains(transpose), !selected.isEmpty else { throw PianoError("Invalid transposition or empty passage.") }
            var excerpt = score
            excerpt.notes = selected.map { n in var copy = n; copy.start = max(n.start, start) - start; copy.duration = min(n.end, end) - max(n.start, start); return copy }
            excerpt.bpm = score.tempoMap.last(where: { $0.beat <= start })?.bpm ?? score.bpm
            excerpt.tempos = score.tempos.filter { $0.beat > start && $0.beat < end }.map { Tempo(beat: $0.beat - start, bpm: $0.bpm) }
            excerpt.cues = score.cues.filter { $0.beat >= start && $0.beat < end }.map { Cue(beat: $0.beat - start, label: $0.label) }
            if start > 0 || end < score.endBeat || transpose != 0 {
                excerpt.id = UUID(); excerpt.created = Date()
                excerpt.title = String("\(score.title) · beats \(Int(start))–\(Int(end))\(transpose == 0 ? "" : " · \(transpose) st")".prefix(240))
                excerpt.detail = "Passage from \(score.id). Beat range \(start)–\(end). Transposition: \(transpose) semitones; chord labels refer to the original key."
                excerpt.source = "Saved passage"; excerpt = excerpt.transposed(transpose)
                try workspace.save(excerpt); library = try workspace.scores()
            }
            transport.load(excerpt, autoplay: autoplay)
            conversation.messages.append(ChatMessage(role: "example", text: excerpt.title, scoreID: excerpt.id)); persist()
            return "Loaded passage. Playback: \(transport.isPlaying ? "playing" : "manual"). Replay example ID: \(excerpt.id). Original example ID: \(score.id)."
        case "remember":
            let title = try string("title"), file = try workspace.remember(title: title, body: string("body"))
            memoryCount = try workspace.memoryFiles().count
            conversation.messages.append(ChatMessage(role: "memory", text: "Remembered: \(title)")); persist()
            return "Saved Memories/\(file)"
        case "read_memory": return try workspace.readMemory(string("filename"))
        default: throw PianoError("Unknown piano tool: \(name).")
        }
    }
}
