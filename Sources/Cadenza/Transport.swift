import AVFoundation
import SwiftUI
import PianoCore

final class AudioProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0
    func observe(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        var maximum: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) { maximum = max(maximum, abs(channels[channel][frame])) }
        }
        lock.lock(); peak = max(peak, maximum); lock.unlock()
    }
    var maximum: Float { lock.lock(); defer { lock.unlock() }; return peak }
}

@MainActor
final class Transport: ObservableObject {
    @Published var score: Score = .welcome
    @Published var position = 0.0
    @Published var isPlaying = false
    @Published var speed = 1.0
    @Published var transpose = 0
    @Published var loop = false
    @Published var volume: Double = 0.7 { didSet { engine.mainMixerNode.outputVolume = Float(volume) } }
    @Published var active: Set<Int> = []
    @Published var audioError: String?
    @Published var leftHand = true
    @Published var rightHand = true
    private let engine = AVAudioEngine()
    private let sampler = AVAudioUnitSampler()
    let audioProbe = AudioProbe()
    private var timer: Timer?
    private var lastClock = 0.0
    private var sounding: [UUID: Note] = [:]
    private var scheduled: [(note: Note, start: Double, end: Double)] = []
    private var nextNote = 0
    private var previewNotes = Set<Int>()
    private(set) var timeline = Timeline(.welcome)
    private var maximumNoteDuration = 0.0
    private(set) var pitchBounds = (48, 83)
    private(set) var duration = Score.welcome.duration
    private var sortedCues: [Cue] = []
    var beat: Double { timeline.beat(at: position) }
    func visibleNotes(horizon: Double = 5) -> [(note: Note, start: Double, end: Double)] {
        var low = 0, high = scheduled.count
        let earliest = position - maximumNoteDuration - 0.1
        while low < high { let mid = (low + high) / 2; if scheduled[mid].start < earliest { low = mid + 1 } else { high = mid } }
        var result: [(note: Note, start: Double, end: Double)] = []
        while low < scheduled.count, scheduled[low].start < position + horizon {
            if scheduled[low].end > position - 0.1 { result.append(scheduled[low]) }; low += 1
        }
        return result
    }
    var currentCue: String {
        let label = sortedCues.last { $0.beat <= beat + 0.02 }?.label ?? "Listen closely"
        return transpose == 0 ? label : "\(label)  (\(transpose > 0 ? "+" : "")\(transpose) st)"
    }

    init() {
        engine.attach(sampler); engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = Float(volume)
        if CommandLine.arguments.contains("--playback-test") {
            let probe = audioProbe
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in probe.observe(buffer) }
        }
        do {
            let bank = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
            try sampler.loadSoundBankInstrument(at: bank, program: 0, bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB), bankLSB: 0)
            try engine.start()
        } catch { audioError = "Piano audio could not start: \(error.localizedDescription)" }
        rebuild()
        timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pause()
                do { try self.engine.start(); self.audioError = nil } catch { self.audioError = error.localizedDescription }
            }
        }
    }
    func load(_ score: Score, autoplay: Bool = false) {
        pause(); self.score = score; position = 0; transpose = 0; rebuild()
        if autoplay { play() }
    }
    func play() {
        guard audioError == nil else { return }
        if position >= duration { position = 0 }
        if !engine.isRunning { do { try engine.start() } catch { audioError = error.localizedDescription; return } }
        lastClock = ProcessInfo.processInfo.systemUptime; isPlaying = true
        synchronize()
    }
    func pause() { isPlaying = false; silence() }
    func toggle() { isPlaying ? pause() : play() }
    func stop() { pause(); position = 0; nextNote = 0 }
    func seek(_ value: Double) { position = min(max(0, value), duration); synchronize(); lastClock = ProcessInfo.processInfo.systemUptime }
    func changeTranspose(_ value: Int) { transpose = min(24, max(-24, value)); silence(); if isPlaying { synchronize() } }
    func setHands(left: Bool, right: Bool) { leftHand = left; rightHand = right; synchronize() }
    private func rebuild() {
        timeline = Timeline(score)
        scheduled = score.notes.map { ($0, timeline.seconds(at: $0.start), timeline.seconds(at: $0.end)) }.sorted { $0.start < $1.start }; nextNote = 0
        maximumNoteDuration = scheduled.map { $0.end - $0.start }.max() ?? 0
        pitchBounds = (score.notes.map(\.pitch).min() ?? 48, score.notes.map(\.pitch).max() ?? 83)
        duration = timeline.seconds(at: score.endBeat); sortedCues = score.cues.sorted { $0.beat < $1.beat }
    }
    private func audible(_ n: Note) -> Bool { n.hand == "left" ? leftHand : rightHand }
    private func start(_ note: Note) {
        let pitch = note.pitch + transpose
        guard (0...127).contains(pitch), audible(note) else { return }
        sampler.startNote(UInt8(pitch), withVelocity: UInt8(note.velocity), onChannel: UInt8(note.channel))
        sounding[note.id] = note
    }
    private func release(_ note: Note) {
        sounding.removeValue(forKey: note.id)
        let pitch = note.pitch + transpose
        if (0...127).contains(pitch), !sounding.values.contains(where: { $0.pitch == note.pitch && $0.channel == note.channel }) {
            sampler.stopNote(UInt8(pitch), onChannel: UInt8(note.channel))
        }
    }
    private func synchronize() {
        silence(); nextNote = scheduled.firstIndex { $0.start > position } ?? scheduled.count
        if isPlaying { for item in scheduled.prefix(nextNote) where item.end > position { start(item.note) } }
        updateActive()
    }
    private func tick() {
        guard isPlaying else { return }
        let clock = ProcessInfo.processInfo.systemUptime
        let delta = clock - lastClock; lastClock = clock
        // Sleep, debugger pauses, or a blocked run loop must never produce a burst of old notes.
        if delta > 0.3 { pause(); return }
        position += delta * speed
        if position >= duration + 0.15 {
            if loop { seek(0) } else { position = duration; pause() }
            return
        }
        for note in Array(sounding.values) where timeline.seconds(at: note.end) <= position { release(note) }
        while nextNote < scheduled.count, scheduled[nextNote].start <= position {
            let item = scheduled[nextNote]; nextNote += 1
            if item.end > position { start(item.note) }
        }
        updateActive()
    }
    private func updateActive() { active = Set(sounding.values.map { $0.pitch + transpose }).union(previewNotes) }
    private func silence() {
        for channel in UInt8(0)...15 { sampler.sendController(123, withValue: 0, onChannel: channel); sampler.sendController(120, withValue: 0, onChannel: channel) }
        sounding.removeAll(); previewNotes.removeAll(); active = []
    }
    func preview(_ pitch: Int, down: Bool) {
        guard (0...127).contains(pitch), audioError == nil else { return }
        if down { previewNotes.insert(pitch); sampler.startNote(UInt8(pitch), withVelocity: 88, onChannel: 15) }
        else { previewNotes.remove(pitch); sampler.stopNote(UInt8(pitch), onChannel: 15) }
        updateActive()
    }
}
