import AppKit
import Foundation

/// One visible Sonos room. Playback fields are only meaningful while the room coordinates its group.
@MainActor @Observable
final class Room: Identifiable {
    let id: String
    var name: String
    var model: String
    var ip: String

    var volume: Double = 0
    var muted = false
    var online = true
    var message: String?

    var state: TransportState = .unknown
    var title: String?
    var artist: String?
    var album: String?
    var source = ""
    var artURL: URL?
    var art: NSImage?
    var position = 0
    var duration = 0
    var playMode: PlayMode = .normal
    var sleepRemaining: Int?

    @ObservationIgnored private var holdVolumeUntil = Date.distantPast
    @ObservationIgnored private var holdStateUntil = Date.distantPast
    @ObservationIgnored private var pendingVolume: Int?
    @ObservationIgnored private var sendingVolume = false

    init(_ saved: SavedRoom) {
        id = saved.id
        name = saved.name
        model = saved.model
        ip = saved.ip
    }

    var saved: SavedRoom { SavedRoom(id: id, name: name, model: model, ip: ip) }
    var client: SonosClient { SonosClient(ip: ip) }
    var symbol: String { Sonos.symbol(forModel: model) }
    var isPlaying: Bool { state == .playing || state == .transitioning }
    var canSeek: Bool { duration > 0 && !["Radio", "TV", "Line-In"].contains(source) }
    var shortName: String { name.count <= 12 ? name : String(name.prefix(11)) + "…" }

    /// Records the error for the footer, or clears it on success.
    @discardableResult
    private func run(_ op: () async throws -> Void) async -> Bool {
        do {
            try await op()
            message = nil
            online = true
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    // MARK: Volume

    func refreshVolume() async {
        guard Date() > holdVolumeUntil else { return }
        do {
            let v = try await client.call(.rendering, "GetVolume", [("Channel", "Master")])
            let m = try await client.call(.rendering, "GetMute", [("Channel", "Master")])
            online = true
            // A drag that started while the request was in flight wins.
            guard Date() > holdVolumeUntil else { return }
            volume = v.value("CurrentVolume").flatMap(Double.init) ?? volume
            muted = m.value("CurrentMute") == "1"
        } catch {
            online = false
        }
    }

    /// Updates the UI at once and streams the latest value to the speaker, one request at a time.
    func setVolume(_ value: Double) {
        let v = Int(min(100, max(0, value.rounded())))
        volume = Double(v)
        holdVolumeUntil = Date().addingTimeInterval(1.5)
        pendingVolume = v
        guard !sendingVolume else { return }
        sendingVolume = true
        Task {
            while let target = pendingVolume {
                pendingVolume = nil
                await run { try await client.call(.rendering, "SetVolume", [("Channel", "Master"), ("DesiredVolume", "\(target)")]) }
                holdVolumeUntil = Date().addingTimeInterval(1.5)
            }
            sendingVolume = false
        }
    }

    func stepVolume(_ delta: Int) { setVolume(volume + Double(delta)) }

    func setMuted(_ on: Bool) async {
        muted = on
        holdVolumeUntil = Date().addingTimeInterval(1.5)
        await run { try await client.call(.rendering, "SetMute", [("Channel", "Master"), ("DesiredMute", on ? "1" : "0")]) }
    }

    // MARK: Playback state (coordinator)

    func refreshPlayback(full: Bool) async {
        do {
            let t = try await client.call(.avTransport, "GetTransportInfo")
            if Date() > holdStateUntil {
                state = TransportState(rawValue: t.value("CurrentTransportState") ?? "") ?? .unknown
            }
            let p = try await client.call(.avTransport, "GetPositionInfo")
            let m = try await client.call(.avTransport, "GetMediaInfo")
            online = true
            apply(position: p, media: m)
            if full {
                let s = try await client.call(.avTransport, "GetTransportSettings")
                playMode = PlayMode(rawValue: s.value("PlayMode") ?? "") ?? .normal
                let sleep = try? await client.call(.avTransport, "GetRemainingSleepTimerDuration")
                let remaining = Sonos.seconds(sleep?.value("RemainingSleepTimerDuration"))
                sleepRemaining = remaining > 0 ? remaining : nil
            }
        } catch {
            online = false
        }
    }

    private func apply(position p: XMLNode, media m: XMLNode) {
        let trackURI = p.value("TrackURI") ?? ""
        let mediaURI = m.value("CurrentURI") ?? ""
        let meta = p.value("TrackMetaData").flatMap(XMLNode.parse)
        let station = m.value("CurrentURIMetaData").flatMap(XMLNode.parse)?.value("title")
        source = Sonos.source(media: mediaURI, track: trackURI)
        position = Sonos.seconds(p.value("RelTime"))
        duration = Sonos.seconds(p.value("TrackDuration"))

        var t = meta?.value("title"), a = meta?.value("creator"), al = meta?.value("album")
        if t.map({ $0.hasPrefix("x-sonos") || $0.hasPrefix("x-rincon") || $0.hasPrefix("http") }) == true { t = nil }
        switch source {
        case "Radio":
            // Stations put "Artist - Title" in streamContent; ZPSTR_ values are status codes.
            if let stream = meta?.value("streamContent"), !stream.hasPrefix("ZPSTR_") {
                let parts = stream.components(separatedBy: " - ")
                if parts.count >= 2 {
                    a = parts[0]
                    t = parts.dropFirst().joined(separator: " - ")
                } else {
                    t = stream
                    a = nil
                }
            } else {
                t = station ?? t
                a = nil
            }
            al = station
        case "TV":
            t = "TV audio"; a = name; al = nil
        case "Line-In":
            t = "Line-In"; a = name; al = nil
        case "Idle":
            t = nil; a = nil; al = nil
        default:
            break
        }
        title = t
        artist = a
        album = al

        let art = meta?.value("albumArtURI").flatMap { uri -> URL? in
            uri.hasPrefix("http") ? URL(string: uri) : URL(string: "http://\(ip):1400\(uri.hasPrefix("/") ? "" : "/")\(uri)")
        }
        if art != artURL {
            artURL = art
            self.art = nil
            if let art {
                Task {
                    let img = await ArtCache.image(art)
                    if artURL == art { self.art = img }
                }
            }
        }
    }

    /// Advances the progress bar between polls.
    func tick() {
        if state == .playing, duration > 0, position < duration { position += 1 }
        if let s = sleepRemaining { sleepRemaining = s > 1 ? s - 1 : nil }
    }

    // MARK: Transport (coordinator)

    func togglePlay() async {
        isPlaying ? await pause() : await play()
    }

    func play() async {
        hold(.playing)
        await run { try await client.call(.avTransport, "Play", [("Speed", "1")]) }
    }

    /// Live sources (radio, TV, line-in) can't pause; they stop instead.
    func pause() async {
        hold(.paused)
        do {
            try await client.call(.avTransport, "Pause")
            message = nil
        } catch {
            hold(.stopped)
            await run { try await client.call(.avTransport, "Stop") }
        }
    }

    func next() async {
        if await run({ try await client.call(.avTransport, "Next") }) { await settle() }
    }

    func previous() async {
        // Like the Sonos app: past 3 s, restart the track instead.
        if position > 3, canSeek {
            await seek(to: 0)
        } else if await run({ try await client.call(.avTransport, "Previous") }) {
            await settle()
        }
    }

    func seek(to seconds: Int) async {
        position = seconds
        await run { try await client.call(.avTransport, "Seek", [("Unit", "REL_TIME"), ("Target", Sonos.timeString(seconds).paddedHMS)]) }
    }

    func setPlayMode(_ mode: PlayMode) async {
        let old = playMode
        playMode = mode
        if !(await run({ try await client.call(.avTransport, "SetPlayMode", [("NewPlayMode", mode.rawValue)]) })) { playMode = old }
    }

    /// nil turns the timer off.
    func setSleep(minutes: Int?) async {
        let value = minutes.map { String(format: "%02d:%02d:00", $0 / 60, $0 % 60) } ?? ""
        if await run({ try await client.call(.avTransport, "ConfigureSleepTimer", [("NewSleepTimerDuration", value)]) }) {
            sleepRemaining = minutes.map { $0 * 60 }
        }
    }

    func play(_ favorite: Favorite) async {
        let ok = await run {
            if favorite.isContainer {
                try await client.call(.avTransport, "RemoveAllTracksFromQueue")
                try await client.call(.avTransport, "AddURIToQueue", [
                    ("EnqueuedURI", favorite.uri), ("EnqueuedURIMetaData", favorite.meta),
                    ("DesiredFirstTrackNumberEnqueued", "0"), ("EnqueueAsNext", "0"),
                ])
                try await client.call(.avTransport, "SetAVTransportURI", [("CurrentURI", "x-rincon-queue:\(id)#0"), ("CurrentURIMetaData", "")])
            } else {
                try await client.call(.avTransport, "SetAVTransportURI", [("CurrentURI", favorite.uri), ("CurrentURIMetaData", favorite.meta)])
            }
            try await client.call(.avTransport, "Play", [("Speed", "1")])
        }
        if ok {
            hold(.playing)
            await settle()
        }
    }

    // MARK: Grouping (this room)

    func join(_ coordinatorID: String) async {
        await run { try await client.call(.avTransport, "SetAVTransportURI", [("CurrentURI", "x-rincon:\(coordinatorID)"), ("CurrentURIMetaData", "")]) }
    }

    func leaveGroup() async {
        await run { try await client.call(.avTransport, "BecomeCoordinatorOfStandaloneGroup") }
    }

    private func hold(_ s: TransportState) {
        state = s
        holdStateUntil = Date().addingTimeInterval(2)
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(400))
        await refreshPlayback(full: false)
    }
}

private extension String {
    /// Seek wants H:MM:SS.
    var paddedHMS: String { split(separator: ":").count == 2 ? "0:" + self : self }
}
