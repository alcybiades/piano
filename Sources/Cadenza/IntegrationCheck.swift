import Foundation
import AppKit
import PianoCore

/// Explicit opt-in smoke test. Uses two short real subscription turns in a fresh test workspace.
@MainActor
enum IntegrationCheck {
    static func playback(_ model: AppModel) async {
        let player = model.transport
        var report: [String: Any] = [:]
        do {
            player.load(.welcome, autoplay: true)
            try await Task.sleep(nanoseconds: 600_000_000)
            guard player.isPlaying, player.position > 0.3, !player.active.isEmpty else { throw PianoError("Transport failed to advance or activate keys.") }
            guard player.audioProbe.maximum > 0.0001 else { throw PianoError("Sampler output was silent.") }
            report["audioPeak"] = player.audioProbe.maximum
            player.pause(); guard player.active.isEmpty else { throw PianoError("Pause left active notes.") }
            player.seek(3); player.changeTranspose(2); player.play()
            guard player.active.contains(47) else { throw PianoError("Seek / transpose did not activate the expected A2 + 2 semitones.") }
            player.setHands(left: false, right: true)
            guard !player.active.contains(47) else { throw PianoError("Hand isolation did not release the bass.") }
            player.loop = true; player.seek(player.duration - 0.05)
            try await Task.sleep(nanoseconds: 400_000_000)
            guard player.isPlaying, player.position < 1 else { throw PianoError("Loop did not restart.") }
            player.stop(); guard player.position == 0, player.active.isEmpty, !player.isPlaying else { throw PianoError("Stop failed.") }
            let original = Score.welcome
            let file = model.workspace.root.appendingPathComponent("playback-import.mid")
            try MIDI.write(original).write(to: file)
            model.importMIDI(file)
            guard model.transport.score.source == "Imported MIDI", model.transport.score.notes.count == original.notes.count, model.error == nil else { throw PianoError("App MIDI import failed.") }
            report["importedNotes"] = model.transport.score.notes.count
            report["passed"] = true
        } catch { report["passed"] = false; report["error"] = error.localizedDescription }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: "/tmp/cadenza-playback-result.json"), options: .atomic) }
        model.shutdown(); NSApp.terminate(nil)
    }
    static func run(_ model: AppModel) async {
        let originalAutoplay = model.autoplay
        defer { model.autoplay = originalAutoplay }
        var report: [String: Any] = ["workspace": model.workspace.root.path, "connected": model.connected]
        do {
            guard model.connected else { throw PianoError(model.error ?? "Connection failed") }
            model.autoplay = true
            model.send("For an integration check of this piano tutor, call play_example to demonstrate Dm7 → G7 → Cmaj7 in three comfortable four-note chords at 100 BPM (two beats per chord). Then call remember with title ‘Integration practice preference’ and body ‘This test learner prefers short jazz cadence demonstrations.’ Finally explain the cadence in one sentence. Use the piano tools only.")
            try await wait(model)
            let examples = model.library.filter { $0.source == "Tutor example" }
            guard let score = examples.first else { throw PianoError("Tutor did not create a playable example. \(model.error ?? "")") }
            report["generatedNotes"] = score.notes.count; report["midiSaved"] = FileManager.default.fileExists(atPath: model.workspace.scoresURL.appendingPathComponent("\(score.id).mid").path)
            guard model.memoryCount > 0 else { throw PianoError("Tutor did not save a Markdown memory.") }
            report["memorySaved"] = true
            report["audioError"] = model.transport.audioError ?? "none"
            let oldThread = model.conversation.threadID
            model.transport.stop()
            await model.connect()
            guard model.connected else { throw PianoError("Reconnect failed") }
            model.send("Use inspect_midi to inspect the example you just played (beats 0 to 0 meaning the whole piece, offset 0). Tell me its pitches and recall the practice preference you remembered. Do not play another example.")
            try await wait(model)
            guard model.error == nil else { throw PianoError(model.error!) }
            report["resumedSameThread"] = model.conversation.threadID == oldThread
            report["assistantMessages"] = model.conversation.messages.filter { $0.role == "assistant" }.count
            report["passed"] = true
        } catch { report["passed"] = false; report["error"] = error.localizedDescription }
        let url = URL(fileURLWithPath: "/tmp/cadenza-integration-result.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url, options: .atomic) }
        model.shutdown(); NSApp.terminate(nil)
    }
    private static func wait(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(150)
        while model.busy, Date() < deadline { try await Task.sleep(nanoseconds: 250_000_000) }
        if model.busy { model.cancel(); throw PianoError("Integration turn timed out") }
        if let error = model.error { throw PianoError(error) }
    }
}
