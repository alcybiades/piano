import Foundation

/// Standard MIDI Files 0/1, PPQ timing, tempo maps, running status, and sustain.
/// Format 2 and SMPTE are rejected explicitly because they have different timelines.
public enum MIDI {
    struct Reader {
        var bytes: [UInt8]; var i = 0
        var remaining: Int { bytes.count - i }
        mutating func byte() throws -> UInt8 {
            guard remaining > 0 else { throw PianoError("Truncated MIDI file.") }
            defer { i += 1 }; return bytes[i]
        }
        mutating func take(_ count: Int) throws -> [UInt8] {
            guard count >= 0, count <= remaining else { throw PianoError("Truncated MIDI chunk.") }
            defer { i += count }; return Array(bytes[i..<i+count])
        }
        mutating func number(_ count: Int) throws -> Int { try take(count).reduce(0) { ($0 << 8) | Int($1) } }
        mutating func vlq() throws -> Int {
            var result = 0
            for _ in 0..<4 { let b = try byte(); result = (result << 7) | Int(b & 127); if b < 128 { return result } }
            throw PianoError("Invalid MIDI variable-length value.")
        }
    }
    struct Event { var tick: Int; var order: Int; var status: Int; var a: Int; var b: Int }
    public static func read(_ data: Data, title: String) throws -> Score {
        guard data.count <= 20_000_000 else { throw PianoError("MIDI files must be smaller than 20 MB.") }
        var r = Reader(bytes: Array(data))
        guard try r.take(4) == Array("MThd".utf8) else { throw PianoError("This is not a Standard MIDI File.") }
        let length = try r.number(4)
        guard length >= 6 else { throw PianoError("Invalid MIDI header.") }
        let format = try r.number(2), tracks = try r.number(2), division = try r.number(2)
        guard format <= 1 else { throw PianoError("Format 2 MIDI uses separate timelines. Please export as format 0 or 1.") }
        guard division > 0, division & 0x8000 == 0 else { throw PianoError("SMPTE MIDI timing is not supported. Export with musical (PPQ) timing.") }
        guard tracks > 0, tracks <= 1024 else { throw PianoError("Invalid MIDI track count.") }
        _ = try r.take(length - 6)
        var events: [Event] = [], tempos: [Tempo] = [], cues: [Cue] = []
        var lastTick = 0
        for _ in 0..<tracks {
            guard try r.take(4) == Array("MTrk".utf8) else { throw PianoError("Missing MIDI track chunk.") }
            let size = try r.number(4)
            var t = Reader(bytes: try r.take(size)), tick = 0, running: UInt8 = 0
            while t.remaining > 0 {
                tick += try t.vlq(); lastTick = max(lastTick, tick)
                var status = try t.byte()
                if status < 128 { guard running >= 0x80 else { throw PianoError("Invalid MIDI running status.") }; t.i -= 1; status = running }
                if status == 0xff {
                    running = 0
                    let kind = try t.byte(), count = try t.vlq(), payload = try t.take(count)
                    if kind == 0x51, count == 3 {
                        let micros = payload.reduce(0) { ($0 << 8) | Int($1) }
                        guard micros > 0 else { throw PianoError("Invalid zero MIDI tempo.") }
                        tempos.append(Tempo(beat: Double(tick) / Double(division), bpm: 60_000_000 / Double(micros)))
                    }
                    if kind == 0x06, let label = String(bytes: payload, encoding: .utf8) { cues.append(Cue(beat: Double(tick) / Double(division), label: String(label.prefix(240)))) }
                    if kind == 0x2f { break }
                } else if status == 0xf0 || status == 0xf7 {
                    running = 0; let count = try t.vlq(); _ = try t.take(count)
                } else if status < 0xf0 {
                    running = status
                    let kind = status & 0xf0, a = try t.byte()
                    let b: UInt8 = (kind == 0xc0 || kind == 0xd0) ? 0 : try t.byte()
                    guard a < 128, b < 128 else { throw PianoError("Invalid MIDI channel data.") }
                    events.append(Event(tick: tick, order: events.count, status: Int(status), a: Int(a), b: Int(b)))
                    guard events.count <= 1_000_000 else { throw PianoError("MIDI contains too many events.") }
                } else { throw PianoError("Unsupported MIDI system event.") }
            }
        }
        events.sort { $0.tick == $1.tick ? $0.order < $1.order : $0.tick < $1.tick }
        var held: [Int: [Event]] = [:], sustained: [Int: [Event]] = [:], pedal = Set<Int>(), notes: [Note] = []
        func finish(_ e: Event, at tick: Int) {
            guard tick > e.tick else { return }
            notes.append(Note(pitch: e.a, start: Double(e.tick) / Double(division), duration: Double(tick - e.tick) / Double(division), velocity: e.b, channel: e.status & 15, hand: e.a < 60 ? "left" : "right"))
        }
        for e in events {
            let channel = e.status & 15, kind = e.status & 0xf0, key = channel * 128 + e.a
            if kind == 0x90 && e.b > 0 { held[key, default: []].append(e) }
            else if kind == 0x80 || (kind == 0x90 && e.b == 0) {
                if var queue = held[key], !queue.isEmpty {
                    let on = queue.removeFirst(); held[key] = queue
                    if pedal.contains(channel) { sustained[channel, default: []].append(on) } else { finish(on, at: e.tick) }
                }
            } else if kind == 0xb0 && e.a == 64 {
                if e.b >= 64 { pedal.insert(channel) }
                else { pedal.remove(channel); for on in sustained.removeValue(forKey: channel) ?? [] { finish(on, at: e.tick) } }
            } else if kind == 0xb0 && [120, 123].contains(e.a) {
                for key in Array(held.keys) where key / 128 == channel { for on in held.removeValue(forKey: key) ?? [] { finish(on, at: e.tick) } }
                for on in sustained.removeValue(forKey: channel) ?? [] { finish(on, at: e.tick) }
            }
        }
        for on in held.values.flatMap({ $0 }) + sustained.values.flatMap({ $0 }) { finish(on, at: max(lastTick, on.tick + division)) }
        guard !notes.isEmpty else { throw PianoError("No playable notes were found in this MIDI file.") }
        let score = Score(title: title, detail: "Imported MIDI · \(tracks) track\(tracks == 1 ? "" : "s") · \(notes.count) notes. Sustain is included in note lengths; all parts use piano sound. Hand colors are estimated from pitch.", bpm: 120, notes: notes, cues: cues, tempos: tempos, source: "Imported MIDI")
        return try score.validated()
    }

    static func vlq(_ value: Int) -> [UInt8] {
        var v = value, bytes = [UInt8(v & 127)]; v >>= 7
        while v > 0 { bytes.insert(UInt8(v & 127) | 128, at: 0); v >>= 7 }
        return bytes
    }
    static func big(_ value: Int, _ count: Int) -> [UInt8] { (0..<count).reversed().map { UInt8((value >> ($0 * 8)) & 255) } }
    public static func write(_ score: Score) throws -> Data {
        let score = try score.validated(), ppq = 480
        var events: [(Int, Int, [UInt8])] = []
        for tempo in score.tempoMap {
            let micros = Int(60_000_000 / tempo.bpm)
            guard micros <= 0xffffff else { throw PianoError("Tempo is too slow for Standard MIDI export.") }
            events.append((Int((tempo.beat * Double(ppq)).rounded()), -2, [0xff, 0x51, 3] + big(micros, 3)))
        }
        for cue in score.cues {
            let text = Array(cue.label.utf8)
            events.append((Int((cue.beat * Double(ppq)).rounded()), -1, [0xff, 0x06] + vlq(text.count) + text))
        }
        for n in score.notes {
            let start = Int((n.start * Double(ppq)).rounded()), end = Int((n.end * Double(ppq)).rounded())
            events.append((start, 1, [UInt8(0x90 | n.channel), UInt8(n.pitch), UInt8(n.velocity)]))
            events.append((max(start + 1, end), 0, [UInt8(0x80 | n.channel), UInt8(n.pitch), 0]))
        }
        events = events.enumerated().sorted { a, b in
            if a.element.0 != b.element.0 { return a.element.0 < b.element.0 }
            if a.element.1 != b.element.1 { return a.element.1 < b.element.1 }
            return a.offset < b.offset
        }.map(\.element)
        var track: [UInt8] = [], last = 0
        for (tick, _, event) in events {
            guard tick - last <= 0x0fffffff else { throw PianoError("A time gap is too long for Standard MIDI export.") }
            track += vlq(tick - last) + event; last = tick
        }
        track += [0, 0xff, 0x2f, 0]
        return Data(Array("MThd".utf8) + big(6, 4) + big(0, 2) + big(1, 2) + big(ppq, 2) + Array("MTrk".utf8) + big(track.count, 4) + track)
    }
}
