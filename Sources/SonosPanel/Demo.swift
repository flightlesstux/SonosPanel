import SwiftUI

/// Renders a scripted walkthrough with fixture rooms (no network) to numbered PNG frames.
/// Turn them into the README GIF with `scripts/make-demo-gif.sh`.
@MainActor
final class DemoRecorder {
    static let fps = 12.0

    let dir: URL
    let model = AppModel(demo: true)
    private var frame = 0

    init(dir: URL) {
        self.dir = dir
    }

    func run() {
        let living = room("demo-living", "Living Room", "Arc", "10.0.0.21")
        let kitchen = room("demo-kitchen", "Kitchen", "Era 100", "10.0.0.22")
        let office = room("demo-office", "Office", "SYMFONISK Picture frame", "10.0.0.23")
        let bedroom = room("demo-bedroom", "Bedroom", "SYMFONISK Bookshelf", "10.0.0.24")
        model.rooms = [bedroom, kitchen, living, office]
        model.groups = [living.id: [living.id], kitchen.id: [kitchen.id], office.id: [office.id], bedroom.id: [bedroom.id]]
        model.favorites = [
            Favorite(id: "f1", title: "Morning Jazz", uri: "x-rincon-cpcontainer:demo", meta: ""),
            Favorite(id: "f2", title: "Lo-fi Radio", uri: "x-sonosapi-stream:demo", meta: ""),
            Favorite(id: "f3", title: "Deep Focus", uri: "x-rincon-cpcontainer:demo2", meta: ""),
        ]

        living.volume = 18
        set(living, "Spotify", "Golden Hour", "The Night Owls", "Slow Lights", 0.08, 214, art: [.systemOrange, .systemPink])
        kitchen.volume = 24
        set(kitchen, "Idle", nil, nil, nil, 0, 0, art: nil)
        kitchen.state = .stopped
        office.volume = 12
        bedroom.volume = 9

        // Living room: volume up, mute, next track.
        model.selection = living.id
        hold(1.2)
        animate(1.2) { living.volume = (18 + 17 * $0).rounded(); living.tick() }
        hold(0.5)
        living.muted = true
        hold(0.7)
        living.muted = false
        living.position += 2
        hold(0.5)
        set(living, "Spotify", "Paper Planes", "Marlowe & Vine", "Cartography", 0.62, 187, art: [.systemTeal, .systemIndigo])
        hold(1.0)

        // Group the kitchen in, then show the group volume card.
        living.playMode = .shuffleNoRepeat
        hold(0.6)
        model.groups = [living.id: [living.id, kitchen.id], office.id: [office.id], bedroom.id: [bedroom.id]]
        hold(1.2)
        // The big slider moves the whole group, keeping each room's offset.
        animate(1.2) { t in
            living.volume = (35 - 12 * t).rounded()
            kitchen.volume = (24 - 12 * t).rounded()
        }
        hold(1.0)

        // Office: play a radio favorite and set a sleep timer.
        model.selection = office.id
        set(office, "Idle", nil, nil, nil, 0, 0, art: nil)
        office.state = .stopped
        hold(1.0)
        set(office, "Radio", "Rain on Glass", "Lo-fi Radio", "Lo-fi Radio", 0, 0, art: [.systemPurple, .systemBlue])
        hold(0.8)
        office.sleepRemaining = 30 * 60
        hold(0.6)
        animate(0.8) { office.volume = (12 + 10 * $0).rounded() }
        hold(1.2)

        // Back to the group.
        model.selection = kitchen.id
        hold(1.6)
    }

    private func room(_ id: String, _ name: String, _ model: String, _ ip: String) -> Room {
        Room(SavedRoom(id: id, name: name, model: model, ip: ip))
    }

    private func set(_ r: Room, _ source: String, _ title: String?, _ artist: String?, _ album: String?,
                     _ progress: Double, _ duration: Int, art colors: [NSColor]?) {
        r.source = source
        r.title = title
        r.artist = artist
        r.album = album
        r.duration = duration
        r.position = Int(Double(duration) * progress)
        r.state = title == nil ? .stopped : .playing
        r.art = colors.map { Self.cover($0[0], $0[1]) }
    }

    /// Abstract gradient cover so the GIF carries no real album art.
    private static func cover(_ a: NSColor, _ b: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 300, height: 300), flipped: false) { rect in
            NSGradient(starting: a, ending: b)?.draw(in: rect, angle: -60)
            NSColor.white.withAlphaComponent(0.18).setFill()
            NSBezierPath(ovalIn: NSRect(x: 150, y: 40, width: 190, height: 190)).fill()
            NSColor.black.withAlphaComponent(0.15).setFill()
            NSBezierPath(ovalIn: NSRect(x: -40, y: 170, width: 150, height: 150)).fill()
            return true
        }
    }
}

extension DemoRecorder {
    // MARK: Frames

    private func hold(_ seconds: Double) {
        guard let png = render() else { return }
        for _ in 0..<max(1, Int(seconds * Self.fps)) { write(png) }
    }

    private func animate(_ seconds: Double, _ step: (Double) -> Void) {
        let count = max(2, Int(seconds * Self.fps))
        for i in 0..<count {
            let t = Double(i) / Double(count - 1)
            step(t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2) // ease in-out
            if let png = render() { write(png) }
        }
    }

    private func render() -> Data? {
        let renderer = ImageRenderer(content: DemoStage(model: model))
        renderer.scale = 1.5
        guard let tiff = renderer.nsImage?.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    private func write(_ png: Data) {
        try? png.write(to: dir.appendingPathComponent(String(format: "frame_%04d.png", frame)))
        frame += 1
    }
}

/// Desktop backdrop with a menu bar and the panel hanging below it, like the real menu bar popover.
struct DemoStage: View {
    let model: AppModel

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.16, green: 0.24, blue: 0.36), Color(red: 0.47, green: 0.40, blue: 0.36)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: "applelogo")
                    Text("Finder").fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "wifi")
                    HStack(spacing: 4) { MenuBarLabel(model: model) }
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 5))
                    Text("Fri 20:15")
                }
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(.black.opacity(0.35))

                PanelView(model: model)
                    .fixedSize(horizontal: false, vertical: true)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.12)))
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
                    .padding(.top, 10)
                Spacer(minLength: 0)
            }
        }
        .frame(width: 520, height: 900)
    }
}
