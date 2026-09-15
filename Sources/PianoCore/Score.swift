import Foundation

public struct PianoError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct Note: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var pitch: Int
    public var start: Double
    public var duration: Double
    public var velocity: Int
    public var channel: Int
    public var hand: String
    public init(pitch: Int, start: Double, duration: Double, velocity: Int = 80, channel: Int = 0, hand: String = "right") {
        self.pitch = pitch; self.start = start; self.duration = duration
        self.velocity = velocity; self.channel = channel; self.hand = hand
    }
    public var end: Double { start + duration }
    public var name: String { Self.name(pitch) }
    public static func name(_ pitch: Int) -> String {
        ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"][((pitch % 12) + 12) % 12] + "\(pitch / 12 - 1)"
    }
    public static func isBlack(_ pitch: Int) -> Bool { [1, 3, 6, 8, 10].contains(pitch % 12) }
}

public struct Cue: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var beat: Double
    public var label: String
    public init(beat: Double, label: String) { self.beat = beat; self.label = label }
}

public struct Tempo: Codable, Equatable, Sendable {
    public var beat: Double
    public var bpm: Double
    public init(beat: Double, bpm: Double) { self.beat = beat; self.bpm = bpm }
}

public struct ResourceOrigin: Codable, Equatable, Sendable {
    public var url: String
    public var pageURL: String
    public var credit: String
    public var retrieved: Date
    public init(url: String, pageURL: String, credit: String, retrieved: Date = Date()) {
        self.url = url; self.pageURL = pageURL; self.credit = credit; self.retrieved = retrieved
    }
}

public struct Score: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var title: String
    public var detail: String
    public var bpm: Double
    public var notes: [Note]
    public var cues: [Cue]
    public var tempos: [Tempo]
    public var source: String
    public var origin: ResourceOrigin?
    public var created: Date = Date()
    public init(title: String, detail: String = "", bpm: Double = 80, notes: [Note], cues: [Cue] = [], tempos: [Tempo] = [], source: String = "Tutor example") {
        self.title = title; self.detail = detail; self.bpm = bpm; self.notes = notes
        self.cues = cues; self.tempos = tempos; self.source = source
    }
    public var endBeat: Double { max(notes.map(\.end).max() ?? 4, 1) }
    public var duration: Double { seconds(at: endBeat) }
    public var tempoMap: [Tempo] {
        ([Tempo(beat: 0, bpm: bpm)] + tempos).enumerated().sorted {
            $0.element.beat == $1.element.beat ? $0.offset < $1.offset : $0.element.beat < $1.element.beat
        }.map(\.element)
    }
    public func seconds(at beat: Double) -> Double {
        var seconds = 0.0, last = 0.0, rate = bpm
        for tempo in tempoMap where tempo.beat <= beat {
            seconds += (tempo.beat - last) * 60 / rate
            last = tempo.beat; rate = tempo.bpm
        }
        return seconds + (beat - last) * 60 / rate
    }
    public func beat(at seconds: Double) -> Double {
        var elapsed = 0.0, last = 0.0, rate = bpm
        for tempo in tempoMap {
            let interval = (tempo.beat - last) * 60 / rate
            if elapsed + interval > seconds { return last + (seconds - elapsed) * rate / 60 }
            elapsed += interval; last = tempo.beat; rate = tempo.bpm
        }
        return last + (seconds - elapsed) * rate / 60
    }
    public func validated() throws -> Score {
        guard !title.isEmpty, title.count <= 240, detail.count <= 20000,
              bpm.isFinite, (20...300).contains(bpm), !notes.isEmpty, notes.count <= 100_000,
              cues.count <= 10000, tempos.count <= 10000 else { throw PianoError("Invalid score size, title, or tempo (20–300 BPM).") }
        for n in notes {
            guard (0...127).contains(n.pitch), (1...127).contains(n.velocity), (0...15).contains(n.channel),
                  n.start.isFinite, n.duration.isFinite, n.start >= 0, n.duration > 0, n.end <= 1_000_000 else {
                throw PianoError("A note has an invalid pitch, velocity, channel, or timing.")
            }
        }
        guard tempos.allSatisfy({ $0.beat.isFinite && $0.beat >= 0 && $0.bpm.isFinite && (1...1000).contains($0.bpm) }),
              cues.allSatisfy({ $0.beat.isFinite && $0.beat >= 0 && $0.label.count <= 240 }) else { throw PianoError("Invalid tempo or chord marker.") }
        var copy = self; copy.notes.sort { $0.start < $1.start }; copy.tempos.sort { $0.beat < $1.beat }
        return copy
    }
    public func transposed(_ semitones: Int) -> Score {
        var copy = self
        copy.notes = notes.compactMap { note in
            var n = note; n.pitch += semitones
            return (0...127).contains(n.pitch) ? n : nil
        }
        return copy
    }
    public static var welcome: Score {
        let voicings = [[48, 55, 59, 64], [45, 55, 60, 64], [50, 57, 60, 65], [43, 53, 59, 62], [48, 55, 59, 64]]
        let labels = ["Cmaj7", "Am7", "Dm7", "G7", "Cmaj7"]
        return Score(title: "A little tension. A beautiful return.", detail: "Hear how seventh chords lead the ear home. Follow the upper notes as the bass moves.", bpm: 84,
                     notes: voicings.enumerated().flatMap { i, chord in chord.enumerated().map { j, pitch in Note(pitch: pitch, start: Double(i * 4), duration: 3.5, velocity: j == 0 ? 72 : 83, hand: j == 0 ? "left" : "right") } },
                     cues: labels.enumerated().map { Cue(beat: Double($0.offset * 4), label: $0.element) }, source: "Welcome lesson")
    }
}

public struct ChatMessage: Codable, Identifiable, Sendable {
    public var id: String
    public var role: String
    public var text: String
    public var scoreID: UUID?
    public init(id: String = UUID().uuidString, role: String, text: String, scoreID: UUID? = nil) {
        self.id = id; self.role = role; self.text = text; self.scoreID = scoreID
    }
}

public struct Conversation: Codable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var title: String = "New conversation"
    public var threadID: String?
    public var toolsetVersion: Int?
    public var previousThreadIDs: [String]?
    public var messages: [ChatMessage] = []
    public var updated: Date = Date()
    public init() {}
}
