# Cadenza

A native macOS piano tutor. Ask about harmony, hear the agent demonstrate it, and keep exploring. SwiftUI, AVAudioEngine, standard MIDI files, and a persistent local Codex app-server conversation. No third-party packages or API key required.

## Run

Requires macOS 14+, Swift 6 (Xcode or Command Line Tools), and a current Codex CLI. Tested against Codex CLI 0.154.0. Dynamic piano tools use the experimental app-server interface, so CLI upgrades may require adapter changes.

```sh
codex login                    # Sign in with ChatGPT
bash scripts/build-app.sh      # Builds dist/Cadenza.app
open dist/Cadenza.app
```

Use the `.app` bundle for microphone permissions. `swift run Cadenza` also works for typed questions and playback. Open `Package.swift` in Xcode for development. The app discovers common CLI installations (including nvm); set an absolute path in Settings if discovery fails.

```sh
bash scripts/test.sh           # Selects Xcode for XCTest if needed
```

## What works

- Falling notes aligned with an interactive piano keyboard; fit-to-notes or full 88-key range.
- Piano sound from the built-in macOS General MIDI sound bank.
- Play, pause, seek, loop, speed adjustment, transpose, hand isolation, volume, MIDI export.
- Real streamed Codex conversations with persistent thread resume and model discovery.
- Agent tools to compose/play examples, replay passages, inspect MIDI, save Markdown memories, and recall them.
- Example replay cards, searchable music library, session history, and Markdown conversation exports.
- MIDI format 0/1 import with PPQ timing, running status, per-channel notes, tempo changes, markers, and sustain pedal handling.
- Optional on-device speech-to-text with microphone permission prompts. Dictation goes into the editable prompt; it is not automatically sent.
- Cancel, timeouts, connection recovery, validation of tool input, and app-mediated local file storage.

## Using it

Press play for the welcome progression or click any key. Ask “How do seventh chords resolve?” and the tutor can create and play an example during its answer. Each example is saved automatically. Use **My library** to recall it, and ask for a change in voicing or a different continuation.

Use **Import MIDI** (⌘O) to load a piece. It becomes the selected context for the next question. The tutor can inspect the actual note events and demonstrate a beat range. Imported hands are estimated from pitch. Time coordinates in the tools use quarter-note beats, starting at zero—not measure numbers.

⌘N starts a new conversation; ⌘, opens settings; ⌘Space toggles playback; ⌘. stops; ⇧⌘E exports MIDI. The toolbar exposes all playback controls without shortcuts.

## Subscription integration

Cadenza launches its own `codex app-server --listen stdio://` process and reuses Codex-managed login credentials. It checks `account/read` and only enables the tutor for `type: chatgpt`. It does not read/copy tokens, ask for API keys, or silently fall back to API billing. Subscription limits and account policies still apply. The model runs in the cloud; only the app, audio rendering, MIDI, and workspace are local.

This is a dedicated tutor thread, **not** an attachment to whichever CLI or desktop conversation happens to be open. Threads resume through app-server IDs. The provider protocol and piano tool contract are separated from transport so a Claude adapter can be added later; Claude is not implemented in v1.

Official references: [App server](https://learn.chatgpt.com/docs/app-server), [Authentication](https://learn.chatgpt.com/docs/auth).

## Local workspace and privacy

Default location:

```text
~/Library/Application Support/Cadenza/Workspace/
  Examples/          <uuid>.json + <uuid>.mid
  Memories/          <uuid>.md
  Conversations/     <uuid>.json + <uuid>.md
  Imports/           original imported MIDI bytes
  README.md
```

Open the workspace from the sidebar or Settings. Memories can be edited with any text editor and are read again on the next question. The agent chooses which useful observations to remember. Examples are always saved; memory Markdown can reference their stable IDs. Conversations also persist in Codex's own session store.

Selected-piece metadata, library metadata, memory excerpts, and inspected note events are sent to Codex as conversation context. Importing by itself does not start a model turn. On-device speech recognition is required; if the language/device does not support it, use typed input or macOS Dictation.

The Codex subprocess has shell/app/plugin/multi-agent features disabled, inherited MCP servers disabled for its tutor threads, read-only sandboxing, and no approval escalation. Music and memory writes happen through validated app tools. The legacy read-only sandbox is not a restriction on all filesystem reads; the tutor's narrow tool set is the primary access boundary. Cadenza itself is a locally signed, unsandboxed Mac app because it launches a CLI; it is not a Mac App Store sandbox distribution.

## Scope and known limitations

- This is a working initial version, not a notarized distribution. The build script signs locally; distributing to other Macs requires a Developer ID and notarization. macOS may ask again for microphone permission after rebuilding an ad-hoc-signed app.
- A language model can produce incorrect harmony or uncomfortable voicings. The tutor is instructed to distinguish illustrative examples from exact score analysis. For Chopin or another named work, import a reliable MIDI or provide a score before expecting precise bar-by-bar claims. MIDI lacks enharmonic spelling and much notation context.
- MIDI formats 0/1 with PPQ timing are supported. Format 2 and SMPTE are explicitly rejected. Imports are limited to 20 MB and 100,000 notes. All channels use piano; instrument programs, pitch bend, time signatures, non-sustain controllers, and original track organization are not reproduced. Sustain becomes extended note lengths on export.
- Full 128 MIDI pitches are retained; the 88-key view can hide notes outside a physical piano's range. Fit view includes them. Transposition drops notes outside MIDI's 0–127 range on export. Displayed chord labels retain their original spelling when transposed.
- Playback uses a monotonic clock and a 120 Hz main-run-loop scheduler. It is suitable for listening and demonstrations, not sample-accurate performance recording. A long run-loop stall pauses playback to prevent bursts or stuck notes. Imported passages with dense sustained notes may be demanding.
- Speech input is optional; spoken tutor answers, notation rendering, hardware MIDI input, assessment of playing, and Claude are outside v1.
- A missing/deleted Codex thread does not silently lose or replace the conversation; the error is shown. Start a new conversation if its server-side thread can no longer be resumed.

## Structure

`PianoCore` contains validated score models, MIDI parsing/writing, and persistence. `Cadenza` contains the SwiftUI studio, AVAudioEngine player, speech input, app model, tool dispatch, and JSON-RPC Codex adapter. No web view or web service is involved in the UI.

## Integration checks

The following opt-in checks use temporary workspaces, then quit. Close the ordinary app first. Playback tests do not contact Codex; the tutor integration check uses two short real subscription turns.

```sh
open -n dist/Cadenza.app --args --playback-test
# Report: /tmp/cadenza-playback-result.json
open -n dist/Cadenza.app --args --integration-test
# Report: /tmp/cadenza-integration-result.json
```

The playback check measures nonzero PCM audio from the mixer, verifies advancing playback, highlighted notes, pause/stop, seek, transposition, hand isolation, looping, and app-level MIDI import. The tutor check verifies tool-generated MIDI, Markdown memory, reconnect, and resuming the same conversation. Neither test exercises microphone transcription; test that interactively on the target Mac and language.
