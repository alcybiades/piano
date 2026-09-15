import SwiftUI
import PianoCore

enum Studio {
    static let background = Color(red: 0.055, green: 0.067, blue: 0.076)
    static let panel = Color(red: 0.079, green: 0.094, blue: 0.102)
    static let raised = Color(red: 0.11, green: 0.128, blue: 0.136)
    static let muted = Color(red: 0.49, green: 0.55, blue: 0.56)
    static let mint = Color(red: 0.65, green: 0.86, blue: 0.70)
    static let blue = Color(red: 0.47, green: 0.66, blue: 0.82)
    static let line = Color.white.opacity(0.075)
}

struct KeyboardLayout {
    var lower: Int; var upper: Int; var width: CGFloat
    var whites: [Int] { (lower...upper).filter { !Note.isBlack($0) } }
    var whiteWidth: CGFloat { width / CGFloat(whites.count) }
    func rect(_ pitch: Int, height: CGFloat) -> CGRect {
        let before = (lower..<max(lower, pitch)).filter { !Note.isBlack($0) }.count
        if Note.isBlack(pitch) { return CGRect(x: CGFloat(before) * whiteWidth - whiteWidth * 0.31, y: 0, width: whiteWidth * 0.62, height: height * 0.63) }
        return CGRect(x: CGFloat(before) * whiteWidth, y: 0, width: whiteWidth, height: height)
    }
}

struct PianoView: View {
    @ObservedObject var transport: Transport
    @State private var held: Int?
    @State private var fullRange = false
    var bounds: (Int, Int) {
        if fullRange { return (21, 108) }
        let low = max(0, min(48, transport.pitchBounds.0 + transport.transpose)), high = min(127, max(83, transport.pitchBounds.1 + transport.transpose))
        return (max(0, (low / 12) * 12), min(127, (high / 12) * 12 + 11))
    }
    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let keyboardHeight: CGFloat = 100
                let rollHeight = max(100, proxy.size.height - keyboardHeight)
                let layout = KeyboardLayout(lower: bounds.0, upper: bounds.1, width: proxy.size.width)
                VStack(spacing: 0) {
                    Canvas { context, size in
                        let horizon = 5.0, scale = size.height / horizon
                        for pitch in layout.whites {
                            let rect = layout.rect(pitch, height: size.height)
                            if pitch % 12 == 0 {
                                context.fill(Path(CGRect(x: rect.minX, y: 0, width: layout.whiteWidth * 7, height: size.height)), with: .color(.white.opacity((pitch / 12) % 2 == 0 ? 0.013 : 0)))
                            }
                            var line = Path(); line.move(to: CGPoint(x: rect.minX, y: 0)); line.addLine(to: CGPoint(x: rect.minX, y: size.height))
                            context.stroke(line, with: .color(.white.opacity(pitch % 12 == 0 ? 0.09 : 0.025)), lineWidth: 1)
                        }
                        let first = max(0, Int(transport.beat)), last = Int(transport.timeline.beat(at: transport.position + horizon)) + 1
                        if first <= last, last - first < 100 {
                            for beat in first...last {
                                let y = size.height - (transport.timeline.seconds(at: Double(beat)) - transport.position) * scale
                                var line = Path(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
                                context.stroke(line, with: .color(.white.opacity(beat % 4 == 0 ? 0.085 : 0.025)), lineWidth: 1)
                            }
                        }
                        for item in transport.visibleNotes() {
                            let note = item.note, start = item.start, end = item.end
                            let pitch = note.pitch + transport.transpose
                            guard pitch >= bounds.0, pitch <= bounds.1 else { continue }
                            let key = layout.rect(pitch, height: 100)
                            let bottom = size.height - (start - transport.position) * scale
                            let top = size.height - (end - transport.position) * scale
                            let rect = CGRect(x: key.minX + 2, y: top, width: max(3, key.width - 4), height: max(5, bottom - top - 2))
                            let color = note.hand == "left" ? Studio.blue : Studio.mint
                            let enabled = note.hand == "left" ? transport.leftHand : transport.rightHand
                            context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .linearGradient(Gradient(colors: [color.opacity(enabled ? 0.52 : 0.12), color.opacity(enabled ? 0.95 : 0.2)]), startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY)))
                            context.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(color.opacity(0.7)), lineWidth: 0.6)
                            if key.width > 22, bottom > 20, rect.height > 26 {
                                context.draw(Text(Note.name(pitch)).font(.system(size: 9, weight: .semibold)).foregroundColor(Studio.background), at: CGPoint(x: rect.midX, y: min(bottom - 12, size.height - 12)))
                            }
                        }
                    }
                    .frame(height: rollHeight).clipped()
                    .overlay(alignment: .topLeading) {
                        if !transport.score.cues.isEmpty {
                            Text(transport.currentCue).font(.system(size: 19, weight: .light)).foregroundStyle(.white.opacity(0.75))
                                .padding(.horizontal, 22).padding(.top, 66).allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .bottom) { Rectangle().fill(Studio.mint.opacity(0.7)).frame(height: 2).shadow(color: Studio.mint.opacity(0.3), radius: 8) }
                    Canvas { context, size in
                        for pitch in layout.whites {
                            let rect = layout.rect(pitch, height: size.height).insetBy(dx: 0.75, dy: 0)
                            let active = transport.active.contains(pitch)
                            context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .linearGradient(Gradient(colors: active ? [Studio.mint, Studio.mint.opacity(0.75)] : [Color(red: 0.78, green: 0.80, blue: 0.78), Color(red: 0.94, green: 0.94, blue: 0.89)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                            if pitch % 12 == 0 {
                                context.draw(Text(Note.name(pitch)).font(.system(size: 9, weight: .medium)).foregroundColor(.black.opacity(0.4)), at: CGPoint(x: rect.midX, y: rect.maxY - 14))
                            }
                            if active { context.fill(Path(ellipseIn: CGRect(x: rect.midX - 3, y: rect.maxY - 31, width: 6, height: 6)), with: .color(Studio.background.opacity(0.5))) }
                        }
                        for pitch in bounds.0...bounds.1 where Note.isBlack(pitch) {
                            let rect = layout.rect(pitch, height: size.height), active = transport.active.contains(pitch)
                            context.fill(Path(roundedRect: rect.offsetBy(dx: 1, dy: 3), cornerRadius: 3), with: .color(.black.opacity(0.35)))
                            context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .linearGradient(Gradient(colors: active ? [Studio.mint.opacity(0.9), Studio.mint.opacity(0.6)] : [Color(white: 0.15), Color(white: 0.07)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: rect.height)))
                            context.stroke(Path(roundedRect: rect.insetBy(dx: 2, dy: 1), cornerRadius: 2), with: .color(.white.opacity(0.08)), lineWidth: 1)
                        }
                    }.frame(height: keyboardHeight)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            let black = (bounds.0...bounds.1).filter { Note.isBlack($0) }.first { layout.rect($0, height: keyboardHeight).contains(value.location) }
                            let white = layout.whites.first { layout.rect($0, height: keyboardHeight).contains(value.location) }
                            let next = black ?? white
                            if next != held { if let held { transport.preview(held, down: false) }; held = next; if let next { transport.preview(next, down: true) } }
                        }.onEnded { _ in if let held { transport.preview(held, down: false) }; held = nil })
                        .accessibilityLabel("Piano keyboard. Click or drag to play notes.")
                }
            }
        }.background(Studio.panel)
            .contextMenu { Toggle("Show all 88 keys", isOn: $fullRange) }
    }
}

struct TransportView: View {
    @ObservedObject var transport: Transport
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 18) {
                Button { transport.stop() } label: { Image(systemName: "backward.end.fill") }.help("Return to beginning")
                Button { transport.toggle() } label: {
                    Image(systemName: transport.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 12)).foregroundStyle(Studio.background).frame(width: 34, height: 34).background(Studio.mint, in: Circle())
                }.help("Play / pause")
                Button { transport.loop.toggle() } label: { Image(systemName: "repeat").foregroundStyle(transport.loop ? Studio.mint : Studio.muted) }.help("Loop piece")
                Text(time(transport.position)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Studio.muted)
                Slider(value: Binding(get: { min(transport.position, transport.duration) }, set: { transport.seek($0) }), in: 0...max(0.01, transport.duration)).tint(Studio.mint).help("Seek")
                Text(time(transport.duration)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Studio.muted)
                Rectangle().fill(Studio.line).frame(width: 1, height: 20)
                Menu {
                    ForEach([0.25, 0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { speed in Button("\(speed.formatted())×") { transport.speed = speed } }
                } label: { Text("\(transport.speed.formatted())×").font(.system(size: 11, weight: .medium)).frame(width: 36) }.menuStyle(.borderlessButton)
                Menu {
                    ForEach(-12...12, id: \.self) { step in Button(step == 0 ? "Original key" : "\(step > 0 ? "+" : "")\(step) semitones") { transport.changeTranspose(step) } }
                } label: { Label(transport.transpose == 0 ? "Original key" : "\(transport.transpose > 0 ? "+" : "")\(transport.transpose) st", systemImage: "music.note").font(.system(size: 10)).frame(width: 100) }.menuStyle(.borderlessButton)
                Menu {
                    Toggle("Left hand", isOn: Binding(get: { transport.leftHand }, set: { transport.setHands(left: $0, right: transport.rightHand) }))
                    Toggle("Right hand", isOn: Binding(get: { transport.rightHand }, set: { transport.setHands(left: transport.leftHand, right: $0) }))
                } label: { Image(systemName: "hand.raised.fingers.spread") }.menuStyle(.borderlessButton).frame(width: 26).help("Isolate a hand")
                Image(systemName: "speaker.wave.2").font(.system(size: 11)).foregroundStyle(Studio.muted)
                Slider(value: $transport.volume, in: 0...1).frame(width: 65).tint(Studio.mint).help("Volume")
            }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.8))
        }.padding(.horizontal, 24).padding(.vertical, 14).background(Studio.panel)
    }
    private func time(_ value: Double) -> String { String(format: "%d:%02d", Int(value) / 60, Int(value) % 60) }
}
