import SwiftUI

enum Settings {
    private static let roomsKey = "sonos.rooms"

    static var savedRooms: [SavedRoom] {
        get {
            guard let data = UserDefaults.standard.data(forKey: roomsKey) else { return [] }
            return (try? JSONDecoder().decode([SavedRoom].self, from: data)) ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: roomsKey) }
    }
}

@MainActor @Observable
final class AppModel {
    var rooms: [Room]
    /// Coordinator id -> member ids, coordinator first.
    var groups: [String: [String]] = [:]
    var selection: String
    var showSettings = false
    var scanning = false
    var scanMessage: String?
    var favorites: [Favorite] = []
    /// Poll fast only while the panel is open.
    var panelVisible = false

    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    /// `demo` skips saved rooms and networking (used to record the README GIF).
    init(demo: Bool = false) {
        let saved = demo ? [] : Settings.savedRooms
        rooms = saved.map(Room.init)
        selection = demo ? "" : UserDefaults.standard.string(forKey: "selection") ?? saved.first?.id ?? ""
        if !demo { startPolling() }
    }

    func room(_ id: String) -> Room? { rooms.first { $0.id == id } }

    var selectedRoom: Room? { room(selection) }

    func coordinator(of room: Room) -> Room {
        for (c, members) in groups where members.contains(room.id) { return self.room(c) ?? room }
        return room
    }

    /// Everyone in the room's group, coordinator first.
    func members(of room: Room) -> [Room] {
        let c = coordinator(of: room)
        return (groups[c.id] ?? [room.id]).compactMap(self.room)
    }

    var coordinators: [Room] { rooms.filter { groups[$0.id] != nil } }

    func select(_ id: String) {
        selection = id
        showSettings = false
        UserDefaults.standard.set(id, forKey: "selection")
    }

    private func fixSelection() {
        if room(selection) == nil, let first = rooms.first { select(first.id) }
    }

    // MARK: Discovery

    /// Concurrent callers share the scan in progress.
    func scan() async {
        if let scanTask { return await scanTask.value }
        let task = Task {
            scanning = true
            defer { scanning = false }
            let hosts = await SonosDiscovery.discover()
            // Known addresses still work when multicast is blocked.
            let candidates = hosts + rooms.map(\.ip).filter { !hosts.contains($0) }
            var ok = false
            for ip in candidates {
                if await refreshTopology(using: ip) {
                    ok = true
                    break
                }
            }
            scanMessage = ok
                ? "Found \(rooms.count) room\(rooms.count == 1 ? "" : "s")."
                : "No Sonos players answered. Check System Settings → Privacy & Security → Local Network."
            if ok {
                await refreshAll()
                if favorites.isEmpty { await refreshFavorites() }
            }
        }
        scanTask = task
        await task.value
        scanTask = nil
    }

    func addPlayer(ip: String) async {
        let ip = ip.trimmingCharacters(in: .whitespaces)
        if await refreshTopology(using: ip) {
            scanMessage = "Added the household of \(ip)."
            await refreshAll()
        } else {
            scanMessage = "No Sonos player at \(ip)."
        }
    }

    /// Reads groups from one player (any reachable one by default) and reconciles the room list.
    @discardableResult
    func refreshTopology(using ip: String? = nil) async -> Bool {
        let sources = ip.map { [$0] } ?? (rooms.filter(\.online).map(\.ip) + rooms.filter { !$0.online }.map(\.ip))
        for source in sources {
            guard let zones = try? await Sonos.topology(from: source) else { continue }
            await apply(zones)
            return true
        }
        return false
    }

    private func apply(_ zones: [ZoneGroup]) async {
        var next: [Room] = []
        for member in zones.flatMap(\.members) {
            if let existing = room(member.id) {
                existing.name = member.name
                existing.ip = member.ip
                if existing.model.isEmpty { existing.model = await Sonos.modelName(ip: member.ip) ?? "" }
                next.append(existing)
            } else {
                var saved = member
                saved.model = await Sonos.modelName(ip: member.ip) ?? "Sonos"
                next.append(Room(saved))
            }
        }
        rooms = next.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        groups = Dictionary(uniqueKeysWithValues: zones.map { z in
            (z.coordinator, [z.coordinator] + z.members.map(\.id).filter { $0 != z.coordinator })
        })
        Settings.savedRooms = rooms.map(\.saved)
        fixSelection()
    }

    func refreshFavorites() async {
        guard let ip = rooms.first(where: \.online)?.ip else { return }
        if let favs = try? await Sonos.favorites(ip: ip) { favorites = favs }
    }

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for r in rooms { group.addTask { await r.refreshVolume() } }
            for c in coordinators { group.addTask { await c.refreshPlayback(full: true) } }
        }
    }

    // MARK: Group volume

    /// Average of the group's rooms (the room's own volume when it plays alone).
    func groupVolume(of room: Room) -> Double {
        let m = members(of: room)
        return m.isEmpty ? room.volume : (m.map(\.volume).reduce(0, +) / Double(m.count)).rounded()
    }

    /// Moves every room in the group by the same amount, keeping their offsets (like the Sonos app).
    func setVolume(_ target: Double, group room: Room) {
        let delta = min(100, max(0, target.rounded())) - groupVolume(of: room)
        guard delta != 0 else { return }
        for m in members(of: room) { m.setVolume(m.volume + delta) }
    }

    func stepVolume(_ delta: Int, group room: Room) {
        for m in members(of: room) { m.stepVolume(delta) }
    }

    func setMuted(_ on: Bool, group room: Room) async {
        await withTaskGroup(of: Void.self) { group in
            for m in members(of: room) { group.addTask { await m.setMuted(on) } }
        }
    }

    // MARK: Grouping

    /// Adds `other` to `room`'s group, or takes it out when it's already in.
    func toggleMember(_ other: Room, in room: Room) async {
        if members(of: room).contains(where: { $0.id == other.id }) {
            await other.leaveGroup()
        } else {
            await other.join(coordinator(of: room).id)
        }
        await regroupSettled()
    }

    func groupAll(with room: Room) async {
        let c = coordinator(of: room)
        await withTaskGroup(of: Void.self) { group in
            for r in rooms where !members(of: room).contains(where: { $0.id == r.id }) {
                group.addTask { await r.join(c.id) }
            }
        }
        await regroupSettled()
    }

    func playAlone(_ room: Room) async {
        await room.leaveGroup()
        await regroupSettled()
    }

    private func regroupSettled() async {
        try? await Task.sleep(for: .milliseconds(600))
        await refreshTopology()
        await refreshAll()
    }

    // MARK: Polling

    private func startPolling() {
        poller = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                for c in self.coordinators { c.tick() }
                let fast = self.panelVisible
                // Rediscover on launch, every 5 minutes, and every 30 s while nothing is known.
                if tick % 300 == 0 || (self.rooms.isEmpty && tick % 30 == 0) {
                    await self.scan()
                } else if tick % 10 == 0 {
                    await self.refreshTopology()
                }
                if tick % 600 == 3 || (self.favorites.isEmpty && tick % 60 == 3) { await self.refreshFavorites() }

                let active = self.selectedRoom.map { self.coordinator(of: $0) }
                if fast, tick % 2 == 0 {
                    await withTaskGroup(of: Void.self) { group in
                        if let active { group.addTask { await active.refreshPlayback(full: tick % 6 == 0) } }
                        for r in self.rooms { group.addTask { await r.refreshVolume() } }
                        if tick % 6 == 0 {
                            for c in self.coordinators where c.id != active?.id {
                                group.addTask { await c.refreshPlayback(full: false) }
                            }
                        }
                    }
                } else if !fast, tick % 15 == 0 {
                    await self.refreshAll()
                }
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

@main
struct SonosPanelApp: App {
    @State private var model = AppModel(demo: CommandLine.arguments.contains("--demo-frames"))

    init() {
        let args = CommandLine.arguments
        let model = self.model

        // `SonosPanel --demo-frames <dir>` renders the scripted README walkthrough as PNG frames and exits.
        if let i = args.firstIndex(of: "--demo-frames"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            Task { @MainActor in
                DemoRecorder(dir: dir).run()
                exit(0)
            }
        }

        // `SonosPanel --snapshot <dir>` renders every room's panel and settings to PNG and exits.
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            Task { @MainActor in
                model.panelVisible = true
                try? await Task.sleep(for: .seconds(6))
                for id in model.rooms.map(\.id) + ["settings"] {
                    if id == "settings" { model.showSettings = true } else { model.select(id) }
                    let renderer = ImageRenderer(content: PanelView(model: model))
                    renderer.scale = 2
                    if let tiff = renderer.nsImage?.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: dir.appendingPathComponent("\(model.room(id)?.name ?? id).png"))
                    }
                }
                exit(0)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        if let room = model.selectedRoom, model.coordinator(of: room).isPlaying {
            Image(systemName: "hifispeaker.2.fill")
            Text("\(Int(model.groupVolume(of: room)))")
        } else {
            Image(systemName: "hifispeaker.2")
        }
    }
}
