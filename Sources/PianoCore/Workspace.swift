import Foundation

public final class Workspace {
    public let root: URL
    public var scoresURL: URL { root.appendingPathComponent("Examples", isDirectory: true) }
    public var memoriesURL: URL { root.appendingPathComponent("Memories", isDirectory: true) }
    public var conversationsURL: URL { root.appendingPathComponent("Conversations", isDirectory: true) }
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }()
    public init(root: URL) throws {
        self.root = root
        for path in [root, scoresURL, memoriesURL, conversationsURL, root.appendingPathComponent("Imports")] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        let readme = root.appendingPathComponent("README.md")
        if !FileManager.default.fileExists(atPath: readme.path) {
            try "# Cadenza workspace\n\nYour piano tutor's local memory. Examples are JSON + standard MIDI pairs. Memories are Markdown. Conversations are saved locally as JSON and Markdown. Imported originals live in Imports. You can edit memory Markdown in any editor.\n".write(to: readme, atomically: true, encoding: .utf8)
        }
    }
    public func save(_ score: Score) throws {
        let score = try score.validated(), name = score.id.uuidString
        try MIDI.write(score).write(to: scoresURL.appendingPathComponent(name + ".mid"), options: .atomic)
        try encoder.encode(score).write(to: scoresURL.appendingPathComponent(name + ".json"), options: .atomic)
    }
    public func scores() throws -> [Score] {
        try FileManager.default.contentsOfDirectory(at: scoresURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { url in try? JSONDecoder().decode(Score.self, from: Data(contentsOf: url)).validated() }
            .sorted { $0.created > $1.created }
    }
    public func save(_ conversation: Conversation) throws {
        let name = conversation.id.uuidString
        try encoder.encode(conversation).write(to: conversationsURL.appendingPathComponent(name + ".json"), options: .atomic)
        let text = "# \(conversation.title)\n\n" + conversation.messages.map { "## \($0.role.capitalized)\n\n\($0.text)\n" }.joined(separator: "\n")
        try text.write(to: conversationsURL.appendingPathComponent(name + ".md"), atomically: true, encoding: .utf8)
    }
    public func conversations() throws -> [Conversation] {
        try FileManager.default.contentsOfDirectory(at: conversationsURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Conversation.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updated > $1.updated }
    }
    public func remember(title: String, body: String) throws -> String {
        guard !title.isEmpty, title.count <= 240, !body.isEmpty, body.utf8.count <= 32000 else { throw PianoError("Memory must have a title and at most 32 KB of text.") }
        let filename = UUID().uuidString + ".md"
        try "# \(title)\n\n\(body)\n".write(to: memoriesURL.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        return filename
    }
    public func memoryFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: memoriesURL, includingPropertiesForKeys: nil).filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    public func readMemory(_ name: String) throws -> String {
        guard !name.contains("/"), !name.contains("\\"), name.hasSuffix(".md"), !name.contains("..") else { throw PianoError("Invalid memory filename.") }
        let url = memoriesURL.appendingPathComponent(name).resolvingSymlinksInPath()
        guard url.deletingLastPathComponent() == memoriesURL.resolvingSymlinksInPath() else { throw PianoError("Memory must be inside the workspace.") }
        let data = try Data(contentsOf: url)
        guard data.count <= 64000 else { throw PianoError("Memory is too large to read (64 KB maximum).") }
        return String(decoding: data, as: UTF8.self)
    }
    public func memoryContext() throws -> String {
        var context = ""
        for url in try memoryFiles().prefix(100) {
            let text = (try? readMemory(url.lastPathComponent)) ?? "[unreadable]"
            context += "\n\(url.lastPathComponent): \(text.prefix(2000))\n"
            if context.count > 16000 { break }
        }
        return String(context.prefix(18000))
    }
}
