import SwiftUI
import AppKit
import PianoCore

struct ContentView: View {
    @ObservedObject var model: AppModel
    @StateObject private var speech = SpeechInput()
    @State private var sidebar = true
    @State private var tab = "Conversations"
    @State private var search = ""
    @AppStorage("chatOverlayFraction") private var chatFraction = 0.46
    @State private var resizeStartHeight: CGFloat?
    @State private var hoveringDivider = false
    var body: some View {
        HStack(spacing: 0) {
            if sidebar { sidebarView.padding(.top, 28).frame(width: 224); Rectangle().fill(Studio.line).frame(width: 1) }
            GeometryReader { geometry in
                let topInset = max(28, geometry.safeAreaInsets.top)
                let chatHeight = boundedChatHeight(geometry.size.height * chatFraction, available: geometry.size.height)
                ZStack(alignment: .top) {
                    // The piano's geometry never changes when the chat overlay is resized.
                    VStack(spacing: 0) {
                        PianoView(transport: model.transport)
                            .frame(maxHeight: .infinity)
                        TransportView(transport: model.transport)
                    }

                    VStack(spacing: 0) {
                        conversationView.frame(maxHeight: .infinity)
                        composer
                        chatDivider(height: chatHeight, available: geometry.size.height)
                    }
                    .padding(.top, topInset + 48)
                    .frame(height: chatHeight)
                    .background {
                        ChatBackdrop()
                            .overlay(Studio.background.opacity(0.12))
                            .allowsHitTesting(false)
                    }
                    .clipped()
                    .shadow(color: .black.opacity(0.15), radius: 16, y: 8)

                    HStack(alignment: .top) {
                        if !sidebar { sidebarToggle }
                        Spacer()
                        pianoControls
                    }.padding(.horizontal, 18).padding(.top, topInset + 10)
                }
            }
        }.ignoresSafeArea(.container, edges: .top)
            .coordinateSpace(name: "studioWindow")
            .background(Studio.background).preferredColorScheme(.dark)
            .frame(minWidth: 1050, minHeight: 760)
            .sheet(isPresented: $model.settingsShown) { SettingsView(model: model) }
            .alert("Cadenza", isPresented: Binding(get: { model.error != nil || speech.error != nil }, set: { if !$0 { model.error = nil; speech.error = nil } })) {
                Button("OK") { model.error = nil; speech.error = nil }
            } message: { Text(model.error ?? speech.error ?? "") }
            .onReceive(model.transport.$audioError) { if let error = $0 { model.error = error } }
            .onDisappear { speech.stop() }
    }
    private func boundedChatHeight(_ height: CGFloat, available: CGFloat) -> CGFloat {
        min(max(240, height), max(240, available - 220))
    }
    private func chatDivider(height: CGFloat, available: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(hoveringDivider || resizeStartHeight != nil ? 0.22 : 0.09)).frame(height: 1)
            Capsule().fill(Color.white.opacity(hoveringDivider || resizeStartHeight != nil ? 0.65 : 0.28)).frame(width: 38, height: 3)
        }
        .frame(maxWidth: .infinity).frame(height: 14)
        .contentShape(Rectangle())
        .onHover { inside in
            hoveringDivider = inside
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("studioWindow"))
            .onChanged { value in
                if resizeStartHeight == nil { resizeStartHeight = height }
                chatFraction = boundedChatHeight((resizeStartHeight ?? height) + value.translation.height, available: available) / max(1, available)
            }
            .onEnded { _ in resizeStartHeight = nil })
        .accessibilityElement()
        .accessibilityLabel("Chat height")
        .accessibilityValue("\(Int(chatFraction * 100)) percent")
        .accessibilityHint("Drag up or down to resize the chat overlay")
        .accessibilityAdjustableAction { direction in
            let delta: CGFloat = direction == .increment ? 40 : -40
            chatFraction = boundedChatHeight(height + delta, available: available) / max(1, available)
        }
        .help("Drag to resize chat")
    }
    private var sidebarToggle: some View {
        Button { withAnimation(.easeInOut(duration: 0.18)) { sidebar.toggle() } } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13))
                .foregroundStyle(Studio.muted)
                .frame(width: 30, height: 30)
                .background(Studio.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).help(sidebar ? "Collapse sidebar" : "Expand sidebar")
            .accessibilityLabel(sidebar ? "Collapse sidebar" : "Expand sidebar")
    }
    private var pianoControls: some View {
        HStack(spacing: 14) {
            Button { model.settingsShown = true } label: {
                HStack(spacing: 6) { Circle().fill(model.connected ? Studio.mint : Studio.muted).frame(width: 5, height: 5); Text(model.connected ? "Codex connected" : "Connect Codex").font(.system(size: 10)); Image(systemName: "chevron.down").font(.system(size: 7)) }
                .foregroundStyle(model.connected ? Studio.mint : Color.white).padding(.horizontal, 12).padding(.vertical, 8).background(Studio.background.opacity(0.85), in: Capsule())
            }.buttonStyle(.plain)
            Button { model.exportMIDI() } label: {
                Image(systemName: "square.and.arrow.up").foregroundStyle(Studio.muted)
                    .frame(width: 30, height: 30)
                    .background(Studio.background.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain).help("Export MIDI")
        }
    }
    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Spacer(); sidebarToggle }.padding(.top, 18).padding(.bottom, 18)
            Button { model.newConversation() } label: {
                HStack { Image(systemName: "plus"); Text("New conversation"); Spacer(); Text("⌘N").foregroundStyle(Studio.muted) }.font(.system(size: 11)).padding(12).background(Studio.raised, in: RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain).disabled(model.busy).padding(.bottom, 25)
            ForEach([("Conversations", "bubble.left.and.bubble.right"), ("My library", "music.note.list")], id: \.0) { name, icon in
                Button { tab = name } label: { HStack(spacing: 10) { Image(systemName: icon).frame(width: 16); Text(name); Spacer(); if tab == name { Circle().fill(Studio.mint).frame(width: 4, height: 4) } }.font(.system(size: 11)).foregroundStyle(tab == name ? .white : Studio.muted).padding(.vertical, 10) }.buttonStyle(.plain)
            }
            Rectangle().fill(Studio.line).frame(height: 1).padding(.vertical, 18)
            if tab == "My library" {
                TextField("Find an example…", text: $search).textFieldStyle(.plain).font(.system(size: 10)).padding(8).background(Studio.raised, in: RoundedRectangle(cornerRadius: 5)).padding(.bottom, 10)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    if tab == "Conversations" {
                        ForEach(model.conversations) { item in
                            Button { model.openConversation(item) } label: {
                                VStack(alignment: .leading, spacing: 5) { Text(item.title).font(.system(size: 11)).lineLimit(2).multilineTextAlignment(.leading); Text(item.updated, style: .date).font(.system(size: 9)).foregroundStyle(Studio.muted) }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(item.id == model.conversation.id ? Studio.raised : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain).disabled(model.busy)
                        }
                    } else {
                        ForEach(model.library.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { score in
                            Button { model.select(score) } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: score.source == "Imported MIDI" ? "doc.audio" : "waveform").foregroundStyle(Studio.mint).font(.system(size: 12)).padding(.top, 2)
                                    VStack(alignment: .leading, spacing: 5) { Text(score.title).font(.system(size: 11)).lineLimit(2).multilineTextAlignment(.leading); Text("\(score.source) · \(Int(score.duration))s").font(.system(size: 9)).foregroundStyle(Studio.muted) }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(model.transport.score.id == score.id ? Studio.raised : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            Spacer(minLength: 16)
            Button { model.chooseMIDI(); tab = "My library" } label: {
                Label("Import MIDI", systemImage: "arrow.down.doc")
                    .font(.system(size: 11)).foregroundStyle(Studio.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
            }.buttonStyle(.plain).padding(.bottom, 18)
            HStack {
                Button { model.openWorkspace() } label: { Label("Local memory", systemImage: "folder").font(.system(size: 10)).foregroundStyle(Studio.muted) }.buttonStyle(.plain)
                Spacer()
                Button { model.settingsShown = true } label: { Image(systemName: "gearshape").font(.system(size: 12)).foregroundStyle(Studio.muted) }.buttonStyle(.plain).help("Settings")
            }.padding(.bottom, 22)
        }.padding(.horizontal, 18).background(Color.black.opacity(0.13))
    }
    private var conversationView: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if model.conversation.messages.isEmpty {
                        welcome.padding(.top, 24)
                    } else {
                        ForEach(model.conversation.messages) { message in messageView(message).id(message.id) }
                    }
                    if model.busy { HStack(spacing: 8) { ProgressView().controlSize(.mini); Text(model.status).font(.system(size: 11)).foregroundStyle(Studio.muted) } }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(.horizontal, 34).padding(.vertical, 22).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
            }.onChange(of: model.conversation.messages.count) { _, _ in withAnimation { reader.scrollTo("bottom", anchor: .bottom) } }
        }
    }
    private var welcome: some View {
        HStack(spacing: 8) {
            suggestion("7th chords", prompt: "Explain seventh chords and play a short example showing how they resolve.")
            suggestion("Find the next chord", prompt: "I have Cmaj7, Am7, Dm7. What could come next? Play two different directions and explain how they feel.")
            suggestion("Explore Chopin", prompt: "What are the essential harmonies in Chopin’s Nocturne Op. 9 No. 2? Play a clearly labeled illustrative example; distinguish it from an exact score transcription.")
        }
    }
    private func suggestion(_ title: String, prompt: String) -> some View {
        Button { model.draft = prompt } label: { HStack(spacing: 7) { Text(title); Image(systemName: "arrow.up.right").font(.system(size: 8)) }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.75)).padding(.horizontal, 11).padding(.vertical, 9).background(RoundedRectangle(cornerRadius: 6).stroke(Studio.line)) }.buttonStyle(.plain)
    }
    @ViewBuilder private func messageView(_ message: ChatMessage) -> some View {
        if message.role == "example" {
            Button {
                if let score = model.library.first(where: { $0.id == message.scoreID }) { model.transport.load(score, autoplay: true) }
            } label: {
                HStack(spacing: 12) { Image(systemName: "play.circle.fill").font(.system(size: 25)).foregroundStyle(Studio.mint); VStack(alignment: .leading, spacing: 4) { Text(message.text).font(.system(size: 12, weight: .medium)); Text("PIANO EXAMPLE · SAVED TO LIBRARY").font(.system(size: 8)).tracking(1.2).foregroundStyle(Studio.muted) }; Spacer(); Image(systemName: "waveform").foregroundStyle(Studio.mint.opacity(0.5)) }.padding(14).background(Studio.mint.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).padding(.leading, 38)
        } else if message.role == "memory" {
            Label(message.text, systemImage: "bookmark").font(.system(size: 10)).foregroundStyle(Studio.muted).padding(.leading, 38)
        } else {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: message.role == "user" ? "person.crop.circle" : "sparkle").font(.system(size: 16)).foregroundStyle(message.role == "user" ? Studio.muted : Studio.mint).frame(width: 24).padding(.top, 2)
                VStack(alignment: .leading, spacing: 8) {
                    Text(message.role == "user" ? "YOU" : "CADENZA").font(.system(size: 8, weight: .semibold)).tracking(1.6).foregroundStyle(Studio.muted)
                    MessageText(text: message.text)
                }
            }
        }
    }
    private var composer: some View {
        VStack(spacing: 10) {
            HStack(alignment: .bottom, spacing: 12) {
                Button { model.chooseMIDI() } label: { Image(systemName: "plus").font(.system(size: 16)).foregroundStyle(Studio.muted).frame(width: 25, height: 28) }.buttonStyle(.plain).help("Import MIDI")
                TextField("Ask anything about piano…", text: $model.draft, axis: .vertical).textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...4).padding(.vertical, 5).onSubmit { if !speech.listening { model.send() } }
                Button {
                    if speech.listening { speech.stop() }
                    else { let prefix = model.draft; Task { await speech.start { model.draft = prefix + (prefix.isEmpty ? "" : " ") + $0 } } }
                } label: { Image(systemName: speech.listening ? "stop.circle.fill" : "mic").font(.system(size: 16)).foregroundStyle(speech.listening ? Studio.mint : Studio.muted).frame(width: 28, height: 28) }.buttonStyle(.plain).help(speech.listening ? "Stop dictation" : "Dictate a question").disabled(model.busy || speech.preparing)
                Button { if model.busy { model.cancel() } else { speech.stop(); model.send() } } label: {
                    Image(systemName: model.busy ? "stop.fill" : "arrow.up").font(.system(size: 13, weight: .semibold)).foregroundStyle(Studio.background).frame(width: 31, height: 31).background(Studio.mint, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).help(model.busy ? "Stop tutor" : "Send question").disabled(!model.busy && model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(13).background(Studio.raised.opacity(0.65), in: RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(Studio.line))
            HStack(spacing: 5) {
                Circle().fill(speech.listening ? Studio.mint : Studio.muted.opacity(0.7)).frame(width: 4, height: 4)
                Text(speech.listening ? "Listening…" : model.status).font(.system(size: 9)).foregroundStyle(Studio.muted)
                Spacer()
                Text("↵ to send").font(.system(size: 9)).foregroundStyle(Studio.muted)
            }
        }.padding(.horizontal, 28).padding(.bottom, 18).padding(.top, 10)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { Text("Settings").font(.system(size: 20, weight: .medium)); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            VStack(alignment: .leading, spacing: 10) {
                Text("CODEX CONNECTION").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(Studio.muted)
                Text("Uses the Codex CLI on your Mac and your ChatGPT subscription. Cadenza owns a persistent tutor conversation; your model still runs in the cloud.").font(.system(size: 12)).foregroundStyle(Studio.muted).lineSpacing(4)
                TextField("Absolute path to codex", text: $model.executable).textFieldStyle(.roundedBorder).disabled(model.busy || model.connecting)
                HStack {
                    Button("Find Codex") { model.executable = CodexClient.discover() }.disabled(model.busy || model.connecting)
                    Button(model.connecting ? "Connecting…" : "Reconnect") { Task { await model.connect() } }.disabled(model.connecting || model.busy)
                    Spacer(); Text(model.accountLabel).font(.system(size: 11)).foregroundStyle(model.connected ? Studio.mint : Studio.muted)
                }
                Text("First-time setup: install Codex CLI, then run codex login in Terminal and sign in with ChatGPT.").font(.system(size: 11)).foregroundStyle(Studio.muted).textSelection(.enabled)
            }
            if !model.models.isEmpty {
                Picker("Tutor model", selection: $model.selectedModel) { ForEach(model.models, id: \.id) { item in Text(item.name).tag(item.id) } }.disabled(model.busy)
            }
            Toggle("Automatically play the tutor’s examples", isOn: $model.autoplay).tint(Studio.mint)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("LOCAL MEMORY").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(Studio.muted)
                Text("\(model.library.count) piano examples · \(model.memoryCount) Markdown memories").font(.system(size: 12))
                Text(model.workspace.root.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(Studio.muted).textSelection(.enabled)
                Button("Open workspace in Finder") { model.openWorkspace() }
            }
            Text("MIDI and memory context are sent to Codex when you ask questions. Dictation uses on-device speech recognition when available. Subscription limits apply. Claude and hardware MIDI input are planned for a future version.").font(.system(size: 11)).foregroundStyle(Studio.muted).lineSpacing(4)
        }.padding(30).frame(width: 570).background(Studio.background).preferredColorScheme(.dark)
    }
}
