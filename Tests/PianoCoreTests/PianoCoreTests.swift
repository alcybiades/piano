import XCTest
@testable import PianoCore

final class PianoCoreTests: XCTestCase {
    func testTempoMapRoundTrip() throws {
        let score = Score(title: "Tempo", bpm: 120, notes: [Note(pitch: 60, start: 0, duration: 2), Note(pitch: 64, start: 2, duration: 4)], cues: [Cue(beat: 2, label: "C major")], tempos: [Tempo(beat: 2, bpm: 60)])
        XCTAssertEqual(score.seconds(at: 6), 5, accuracy: 0.001)
        for beat in stride(from: 0.0, through: 12, by: 0.1) { XCTAssertEqual(score.beat(at: score.seconds(at: beat)), beat, accuracy: 0.0001) }
        let parsed = try MIDI.read(MIDI.write(score), title: "Roundtrip")
        XCTAssertEqual(parsed.notes.map(\.pitch), [60, 64]); XCTAssertEqual(parsed.duration, 5, accuracy: 0.001)
        XCTAssertEqual(parsed.cues.first?.label, "C major")
        let timeline = Timeline(score)
        for beat in stride(from: 0.0, through: 20, by: 0.25) {
            XCTAssertEqual(timeline.seconds(at: beat), score.seconds(at: beat), accuracy: 0.000001)
            XCTAssertEqual(timeline.beat(at: timeline.seconds(at: beat)), beat, accuracy: 0.000001)
        }
    }
    func midi(_ track: [UInt8], format: UInt8 = 0, division: [UInt8] = [0x01, 0xe0]) -> Data {
        var bytes = Array("MThd".utf8)
        bytes += [0,0,0,6,0,format,0,1]; bytes += division
        bytes += Array("MTrk".utf8); bytes += MIDI.big(track.count, 4); bytes += track
        return Data(bytes)
    }
    func testRunningStatusAndVelocityZero() throws {
        let track: [UInt8] = [0,0x90,60,100,0,64,90,0x83,0x60,60,0,0,64,0,0,0xff,0x2f,0]
        let score = try MIDI.read(midi(track), title: "Running")
        XCTAssertEqual(score.notes.count, 2)
        XCTAssertEqual(score.notes[0].duration, 1)
        XCTAssertEqual(score.notes[1].velocity, 90)
    }
    func testSustainAndChannels() throws {
        let track: [UInt8] = [0,0x90,60,100,0,0xb0,64,127,0x83,0x60,0x80,60,0,0x83,0x60,0xb0,64,0,0,0xff,0x2f,0]
        let score = try MIDI.read(midi(track), title: "Pedal")
        XCTAssertEqual(score.notes[0].duration, 2)
    }
    func testMalformedMIDI() {
        XCTAssertThrowsError(try MIDI.read(Data(), title: "Empty"))
        XCTAssertThrowsError(try MIDI.read(midi([0, 0x90, 60]), title: "Truncated"))
        XCTAssertThrowsError(try MIDI.read(midi([0,0xff,0x2f,0], format: 2), title: "Format 2"))
        XCTAssertThrowsError(try MIDI.read(midi([0,0xff,0x2f,0], division: [0xe7,40]), title: "SMPTE"))
        XCTAssertThrowsError(try MIDI.read(midi([0x80,0x80,0x80,0x80,0,0xff,0x2f,0]), title: "Bad VLQ"))
    }
    func testBoundsValidation() throws {
        XCTAssertThrowsError(try Score(title: "Bad", notes: [Note(pitch: 128, start: 0, duration: 1)]).validated())
        XCTAssertThrowsError(try Score(title: "Bad", notes: [Note(pitch: 60, start: .nan, duration: 1)]).validated())
        XCTAssertThrowsError(try Score(title: "Bad", notes: [Note(pitch: 60, start: 0, duration: -1)]).validated())
        XCTAssertEqual(Score.welcome.transposed(12).notes.first!.pitch, Score.welcome.notes.first!.pitch + 12)
    }
    func testWorkspacePersistenceAndTraversal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CadenzaTest-\(UUID())")
        let store = try Workspace(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let score = Score.welcome; try store.save(score)
        XCTAssertEqual(try store.scores().first?.id, score.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.scoresURL.appendingPathComponent("\(score.id).mid").path))
        let name = try store.remember(title: "Preference", body: "Slow examples help.")
        XCTAssertTrue(try store.readMemory(name).contains("Slow examples"))
        XCTAssertThrowsError(try store.readMemory("../README.md"))
        var conversation = Conversation(); conversation.messages.append(ChatMessage(role: "user", text: "Hello")); try store.save(conversation)
        XCTAssertEqual(try store.conversations().first?.messages.first?.text, "Hello")
    }
    func testAllPitchesRoundTrip() throws {
        let score = Score(title: "All notes", notes: (0...127).map { Note(pitch: $0, start: Double($0), duration: 0.5, channel: $0 % 16) })
        let parsed = try MIDI.read(MIDI.write(score), title: "Roundtrip")
        XCTAssertEqual(parsed.notes.map(\.pitch), Array(0...127))
        XCTAssertEqual(parsed.notes.map(\.channel), score.notes.map(\.channel))
    }
}
