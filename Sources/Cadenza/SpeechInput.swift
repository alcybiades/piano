import AVFoundation
import Speech
import SwiftUI
import PianoCore

@MainActor
final class SpeechInput: ObservableObject {
    @Published var listening = false
    @Published var preparing = false
    @Published var error: String?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var timeout: Task<Void, Never>?
    private var generation = UUID()
    func start(onText: @escaping (String) -> Void) async {
        guard !preparing, !listening else { return }
        stop(); preparing = true
        let token = generation
        defer { if generation == token { preparing = false } }
        let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard generation == token else { return }
        guard speech == .authorized else { error = "Enable Speech Recognition for Cadenza in System Settings → Privacy & Security."; return }
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        guard generation == token else { return }
        guard mic else { error = "Enable Microphone access for Cadenza in System Settings → Privacy & Security."; return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            error = "On-device dictation is unavailable for this language. Enable macOS Dictation or type your question."; return
        }
        let req = SFSpeechAudioBufferRecognitionRequest(); req.shouldReportPartialResults = true; req.requiresOnDeviceRecognition = true
        request = req
        let input = engine.inputNode, format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { error = "No microphone input is available."; return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in req.append(buffer) }; tapInstalled = true
        recognition = recognizer.recognitionTask(with: req) { [weak self] result, issue in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                if let result { onText(result.bestTranscription.formattedString); if result.isFinal { self.stop() } }
                if let issue, self.listening { self.error = issue.localizedDescription; self.stop() }
            }
        }
        do { try engine.start(); listening = true } catch { self.error = error.localizedDescription; stop() }
        timeout = Task { [weak self] in try? await Task.sleep(nanoseconds: 60_000_000_000); if !Task.isCancelled { self?.stop() } }
    }
    func stop() {
        generation = UUID(); preparing = false; listening = false; timeout?.cancel(); timeout = nil
        engine.stop(); if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio(); recognition?.cancel(); recognition = nil; request = nil
    }
}
