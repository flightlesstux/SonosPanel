import SwiftUI

struct PanelView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            RoomSwitcher(model: model)
            if model.showSettings {
                SettingsView(model: model)
            } else if let room = model.selectedRoom {
                RoomPanel(room: room, model: model)
            } else {
                EmptyPanel(model: model)
            }
        }
        .padding(16)
        .frame(width: 440)
        .background(Theme.bg)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .animation(.snappy(duration: 0.2), value: model.selection)
        .animation(.snappy(duration: 0.2), value: model.showSettings)
        .onAppear { model.panelVisible = true }
        .onDisappear { model.panelVisible = false }
    }
}

struct RoomSwitcher: View {
    let model: AppModel

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(model.rooms) { room in
                let selected = room.id == model.selection && !model.showSettings
                let grouped = model.members(of: room).count > 1
                Button { model.select(room.id) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: room.symbol).font(.system(size: 12))
                        Text(room.shortName).font(.system(size: 12, weight: .medium))
                        if grouped { Image(systemName: "link").font(.system(size: 9)).foregroundStyle(Theme.tertiary) }
                        if model.coordinator(of: room).isPlaying { Circle().fill(.green).frame(width: 5, height: 5) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(selected ? Color.white.opacity(0.16) : Theme.tile, in: Capsule())
                    .overlay(Capsule().stroke(Theme.stroke))
                    .foregroundStyle(selected ? .white : Theme.secondary)
                    .opacity(room.online ? 1 : 0.5)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Room

struct RoomPanel: View {
    let room: Room
    let model: AppModel

    private var player: Room { model.coordinator(of: room) }
    private var members: [Room] { model.members(of: room) }
    private var groupVolume: Double { model.groupVolume(of: room) }
    private var groupMuted: Bool { members.allSatisfy(\.muted) }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Image(systemName: room.symbol).foregroundStyle(Theme.secondary)
                Text(room.name).font(.system(size: 15, weight: .medium))
                Text(room.model).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                Spacer()
                CircleButton(symbol: player.isPlaying ? "pause.fill" : "play.fill", size: 42,
                             tint: player.isPlaying ? .white : Theme.secondary,
                             highlighted: player.isPlaying) { Task { await player.togglePlay() } }
            }

            ArtHero(image: player.art, symbol: room.symbol, active: player.isPlaying,
                    caption: player.source == "Idle" ? "Nothing playing" : player.source)

            NowPlaying(player: player)

            HStack(alignment: .center) {
                BigReadout(value: room.online ? "\(Int(groupVolume))" : "--", unit: members.count > 1 ? "group" : "vol")
                Spacer()
                Card(padding: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: groupMuted ? "speaker.slash.fill" : "speaker.wave.2")
                            .frame(width: 22)
                        Text(members.count > 1 ? "Mute all" : "Mute").font(.system(size: 14, weight: .medium))
                        PillSwitch(isOn: groupMuted) { Task { await model.setMuted(!groupMuted, group: room) } }
                    }
                }
            }
            .disabled(!room.online)

            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    CircleButton(symbol: "minus") { model.stepVolume(-2, group: room) }
                    GlassSlider(value: Binding(get: { groupVolume }, set: { _ in }), enabled: room.online) {
                        model.setVolume($0, group: room)
                    }
                    CircleButton(symbol: "plus") { model.stepVolume(2, group: room) }
                }
                HStack {
                    Text("0"); Spacer(); Text("100")
                }
                .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                .padding(.horizontal, 54)
            }
            .disabled(!room.online)

            HStack(spacing: 8) {
                ChoiceTile(symbol: "star", title: "Favorites",
                           value: model.favorites.first { $0.title == player.album || $0.title == player.title }?.title
                               ?? (model.favorites.isEmpty ? "None" : "\(model.favorites.count) saved"),
                           choices: model.favorites.map { ($0.id, $0.title, $0.symbol) }) { id in
                    if let fav = model.favorites.first(where: { $0.id == id }) { Task { await player.play(fav) } }
                }
                ChoiceTile(symbol: "square.stack.3d.up", title: "Group",
                           value: members.count > 1 ? "\(members.count) rooms" : "Solo",
                           choices: groupChoices, isSelected: { id in members.contains { $0.id == id } },
                           keepOpen: true) { pickGroup($0) }
                ChoiceTile(symbol: player.playMode.symbol, title: "Mode", value: player.playMode.label,
                           choices: PlayMode.allCases.map { ($0.rawValue, $0.label, $0.symbol) },
                           isSelected: { $0 == player.playMode.rawValue }) { raw in
                    if let mode = PlayMode(rawValue: raw) { Task { await player.setPlayMode(mode) } }
                }
                ChoiceTile(symbol: "moon.zzz", title: "Sleep",
                           value: player.sleepRemaining.map { "\(($0 + 59) / 60) min" } ?? "Off",
                           choices: [("off", "Off", nil)] + [15, 30, 45, 60, 90].map { ("\($0)", "\($0) minutes", nil) }) { id in
                    Task { await player.setSleep(minutes: Int(id)) }
                }
            }

            if members.count > 1 { GroupCard(members: members, current: room) }

            Footer(symbol: room.online ? "checkmark.shield" : "wifi.slash", text: footerText,
                   tint: (room.message ?? player.message) == nil ? Theme.secondary : .orange) { model.showSettings = true }
        }
    }

    private var groupChoices: [(id: String, label: String, symbol: String?)] {
        var list = model.rooms.map { ($0.id, $0.name + ($0.id == room.id ? " (this room)" : ""), Optional($0.symbol)) }
        if members.count < model.rooms.count { list.insert(("all", "Group all rooms", "square.stack.3d.up.fill"), at: 0) }
        return list
    }

    private func pickGroup(_ id: String) {
        Task {
            if id == "all" {
                await model.groupAll(with: room)
            } else if id == room.id {
                if members.count > 1 { await model.playAlone(room) }
            } else if let other = model.room(id) {
                await model.toggleMember(other, in: room)
            }
        }
    }

    private var footerText: String {
        if let msg = room.message ?? player.message { return msg }
        guard room.online else { return "Offline · \(room.ip)" }
        return members.count > 1 && player.id != room.id
            ? "Connected · \(room.ip) · following \(player.name)"
            : "Connected · \(room.ip)"
    }
}

/// Album art with a soft glow of its own colours; falls back to the speaker glyph.
struct ArtHero: View {
    let image: NSImage?
    let symbol: String
    var active = true
    var caption: String?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 200, height: 90)
                    .blur(radius: 40)
                    .opacity(active ? 0.55 : 0.25)
                Image(nsImage: image)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 112, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.12)))
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
                    .saturation(active ? 1 : 0.4)
                if let caption { CaptionPill(text: caption).offset(y: 58) }
            } else {
                HeroGlyph(symbol: symbol, active: active, caption: caption)
            }
        }
        .frame(height: 132)
        .frame(maxWidth: .infinity)
    }
}

struct CaptionPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.black.opacity(0.65), in: Capsule())
            .overlay(Capsule().stroke(Theme.stroke))
    }
}

/// Title, artist and a seekable progress bar between previous / next.
struct NowPlaying: View {
    let player: Room

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 3) {
                Text(player.title ?? "Nothing playing")
                    .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text([player.artist, player.album].compactMap { $0 }.joined(separator: " · ").ifEmpty("—"))
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 10) {
                CircleButton(symbol: "backward.fill", size: 34) { Task { await player.previous() } }
                VStack(spacing: 4) {
                    ProgressBar(position: player.position, duration: player.duration, enabled: player.canSeek) { s in
                        Task { await player.seek(to: s) }
                    }
                    HStack {
                        Text(player.duration > 0 ? Sonos.timeString(player.position) : "")
                        Spacer()
                        Text(player.duration > 0 ? Sonos.timeString(player.duration) : (player.isPlaying ? "Live" : ""))
                    }
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(Theme.tertiary)
                }
                CircleButton(symbol: "forward.fill", size: 34) { Task { await player.next() } }
            }
        }
    }
}

struct ProgressBar: View {
    let position: Int
    let duration: Int
    var enabled = true
    let onSeek: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            let f = duration > 0 ? min(1, CGFloat(position) / CGFloat(duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color(white: 0.16))
                Capsule()
                    .fill(LinearGradient(colors: [Color.white.opacity(0.35), .white], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(f > 0 ? 6 : 0, geo.size.width * f))
            }
            .frame(height: 5)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard enabled, duration > 0 else { return }
                onSeek(Int(CGFloat(duration) * min(1, max(0, location.x / geo.size.width))))
            }
        }
        .frame(height: 14)
        .animation(.linear(duration: 0.9), value: position)
    }
}

/// Per-room volume for every member of a group.
struct GroupCard: View {
    let members: [Room]
    let current: Room

    var body: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Group volume", systemImage: "square.stack.3d.up")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                ForEach(members) { m in
                    HStack(spacing: 10) {
                        Image(systemName: m.symbol).frame(width: 16).foregroundStyle(Theme.secondary)
                        Text(m.name).font(.system(size: 12, weight: m.id == current.id ? .semibold : .regular))
                            .lineLimit(1).frame(width: 92, alignment: .leading)
                        GlassSlider(value: Binding(get: { m.volume }, set: { _ in }), enabled: m.online && !m.muted,
                                    height: 26) { m.setVolume($0) }
                        Text("\(Int(m.volume))").font(.system(size: 12, weight: .medium)).monospacedDigit()
                            .frame(width: 24, alignment: .trailing)
                        Button { Task { await m.setMuted(!m.muted) } } label: {
                            Image(systemName: m.muted ? "speaker.slash.fill" : "speaker.wave.2")
                                .font(.system(size: 11)).frame(width: 18)
                                .foregroundStyle(m.muted ? .orange : Theme.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct EmptyPanel: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            HeroGlyph(symbol: "hifispeaker.2", active: false, animate: model.scanning)
            Text(model.scanning ? "Looking for Sonos speakers…" : "No Sonos speakers found")
                .font(.system(size: 15, weight: .medium))
            if let msg = model.scanMessage, !model.scanning {
                Text(msg).font(.system(size: 11)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            }
            HStack {
                Button("Scan again") { Task { await model.scan() } }.disabled(model.scanning)
                Button("Settings") { model.showSettings = true }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 20)
    }
}

// MARK: - Settings

struct SettingsView: View {
    let model: AppModel
    @State private var manualIP = ""

    private func addManual() {
        let ip = manualIP
        manualIP = ""
        Task { await model.addPlayer(ip: ip) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings").font(.system(size: 17, weight: .semibold))

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Rooms (local network)", systemImage: "hifispeaker.2").font(.system(size: 13, weight: .medium))
                        Spacer()
                        if model.scanning { ProgressView().controlSize(.mini) }
                        Button("Scan") { Task { await model.scan() } }
                            .controlSize(.small)
                            .disabled(model.scanning)
                    }
                    if model.rooms.isEmpty {
                        Text("No rooms yet. Scan finds Sonos players on this network automatically.")
                            .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                    ForEach(model.rooms) { room in
                        HStack {
                            Circle().fill(room.online ? Color.green : Theme.tertiary).frame(width: 6, height: 6)
                            Text(room.name).font(.system(size: 12))
                            Text(room.model).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                            Spacer()
                            Text(room.ip).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.tertiary)
                        }
                    }
                    HStack {
                        TextField("Add by IP address", text: $manualIP)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addManual)
                        Button("Add", action: addManual)
                            .controlSize(.small)
                            .disabled(manualIP.isEmpty)
                    }
                    if let msg = model.scanMessage {
                        Text(msg).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Favorites", systemImage: "star").font(.system(size: 13, weight: .medium))
                        Spacer()
                        Button("Reload") { Task { await model.refreshFavorites() } }.controlSize(.small)
                    }
                    Text(model.favorites.isEmpty
                         ? "No favorites. Add some in the Sonos app under My Sonos."
                         : "\(model.favorites.count) favorites from My Sonos.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
            }

            HStack {
                Button("Done") { model.showSettings = false }
                Spacer()
                Button("Quit SonosPanel") { NSApplication.shared.terminate(nil) }
            }
            .controlSize(.small)
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
