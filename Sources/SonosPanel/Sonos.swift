import AppKit
import Foundation

// MARK: - XML

/// Minimal DOM over XMLParser. Element names drop their namespace prefix (`dc:title` -> `title`).
final class XMLNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [XMLNode] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    func child(_ name: String) -> XMLNode? { children.first { $0.name == name } }

    /// First descendant with this name, depth first.
    func first(_ name: String) -> XMLNode? {
        for c in children {
            if c.name == name { return c }
            if let found = c.first(name) { return found }
        }
        return nil
    }

    /// Every descendant with this name.
    func all(_ name: String) -> [XMLNode] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.all(name) }
    }

    /// Trimmed text of the first descendant with this name; nil when missing or empty.
    func value(_ name: String) -> String? {
        guard let t = first(name)?.text.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    static func parse(_ string: String) -> XMLNode? {
        guard string.hasPrefix("<") else { return nil }  // e.g. "NOT_IMPLEMENTED"
        return parse(Data(string.utf8))
    }

    static func parse(_ data: Data) -> XMLNode? {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.parse()
        return builder.root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLNode?
        var stack: [XMLNode] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            let node = XMLNode(name: local, attributes: attributeDict)
            if let parent = stack.last { parent.children.append(node) } else { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            stack.removeLast()
        }
    }
}

extension String {
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - SOAP

enum SonosError: LocalizedError {
    case upnp(code: String, action: String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .upnp("701", _), .upnp("711", _): "Not available for this source"
        case .upnp("714", _), .upnp("712", _): "Not supported by this source"
        case .upnp("800", _): "Speaker is busy, try again"
        case let .upnp(code, action): "\(action) failed (UPnP \(code))"
        case let .badResponse(action): "\(action): unexpected reply"
        }
    }
}

/// UPnP control for one player on port 1400.
struct SonosClient {
    let ip: String

    enum Service: String {
        case avTransport = "AVTransport"
        case rendering = "RenderingControl"
        case topology = "ZoneGroupTopology"
        case content = "ContentDirectory"

        var path: String {
            switch self {
            case .avTransport, .rendering: "/MediaRenderer/\(rawValue)/Control"
            case .content: "/MediaServer/ContentDirectory/Control"
            case .topology: "/ZoneGroupTopology/Control"
            }
        }

        var urn: String { "urn:schemas-upnp-org:service:\(rawValue):1" }
        var takesInstance: Bool { self == .avTransport || self == .rendering }
    }

    /// Runs one action and returns its `<ActionResponse>` element. Argument order matters to Sonos.
    @discardableResult
    func call(_ service: Service, _ action: String, _ args: [(String, String)] = []) async throws -> XMLNode {
        let all = (service.takesInstance ? [("InstanceID", "0")] : []) + args
        let body = all.map { "<\($0.0)>\($0.1.xmlEscaped)</\($0.0)>" }.joined()
        let envelope = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
            + "<s:Body><u:\(action) xmlns:u=\"\(service.urn)\">\(body)</u:\(action)></s:Body></s:Envelope>"
        var req = URLRequest(url: URL(string: "http://\(ip):1400\(service.path)")!, timeoutInterval: 4)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(service.urn)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        req.httpBody = Data(envelope.utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        let xml = XMLNode.parse(data)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SonosError.upnp(code: xml?.value("errorCode") ?? "?", action: action)
        }
        guard let node = xml?.first("\(action)Response") else { throw SonosError.badResponse(action) }
        return node
    }
}

// MARK: - Models

struct SavedRoom: Codable, Hashable {
    let id: String  // RINCON_… UUID
    var name: String
    var model: String
    var ip: String
}

struct ZoneGroup {
    let coordinator: String
    let members: [SavedRoom]
}

struct Favorite: Identifiable, Hashable {
    let id: String
    let title: String
    let uri: String
    let meta: String

    var isRadio: Bool {
        ["x-sonosapi-stream:", "x-sonosapi-radio:", "x-rincon-mp3radio:", "hls-radio:", "x-sonosapi-hls:", "aac:"]
            .contains { uri.hasPrefix($0) }
    }

    /// Albums and playlists go through the queue; tracks and stations play directly.
    var isContainer: Bool {
        ["x-rincon-cpcontainer:", "x-rincon-playlist:", "file:///jffs/settings/savedqueues.rsq"].contains { uri.hasPrefix($0) }
    }

    var symbol: String { isRadio ? "dot.radiowaves.left.and.right" : (isContainer ? "music.note.list" : "music.note") }
}

enum TransportState: String {
    case playing = "PLAYING"
    case paused = "PAUSED_PLAYBACK"
    case stopped = "STOPPED"
    case transitioning = "TRANSITIONING"
    case unknown
}

enum PlayMode: String, CaseIterable {
    case normal = "NORMAL"
    case repeatAll = "REPEAT_ALL"
    case repeatOne = "REPEAT_ONE"
    case shuffleNoRepeat = "SHUFFLE_NOREPEAT"
    case shuffle = "SHUFFLE"
    case shuffleRepeatOne = "SHUFFLE_REPEAT_ONE"

    var label: String {
        switch self {
        case .normal: "Normal"
        case .repeatAll: "Repeat"
        case .repeatOne: "Repeat one"
        case .shuffleNoRepeat: "Shuffle"
        case .shuffle: "Shuffle + repeat"
        case .shuffleRepeatOne: "Shuffle + repeat one"
        }
    }

    var symbol: String {
        switch self {
        case .normal: "arrow.forward"
        case .repeatAll: "repeat"
        case .repeatOne, .shuffleRepeatOne: "repeat.1"
        case .shuffleNoRepeat, .shuffle: "shuffle"
        }
    }
}

// MARK: - Household-wide queries

enum Sonos {
    /// Groups and visible members as seen by any one player. Bonded surrounds and subs are hidden.
    static func topology(from ip: String) async throws -> [ZoneGroup] {
        let r = try await SonosClient(ip: ip).call(.topology, "GetZoneGroupState")
        guard let state = r.value("ZoneGroupState"), let xml = XMLNode.parse(state) else {
            throw SonosError.badResponse("GetZoneGroupState")
        }
        return xml.all("ZoneGroup").compactMap { group in
            guard let coordinator = group.attributes["Coordinator"] else { return nil }
            let members: [SavedRoom] = group.children.compactMap { m in
                guard m.name == "ZoneGroupMember", m.attributes["Invisible"] != "1",
                      let id = m.attributes["UUID"], let name = m.attributes["ZoneName"],
                      let host = m.attributes["Location"].flatMap(URL.init(string:))?.host
                else { return nil }
                return SavedRoom(id: id, name: name, model: "", ip: host)
            }
            return members.isEmpty ? nil : ZoneGroup(coordinator: coordinator, members: members)
        }
    }

    /// Marketing model name, e.g. "Era 100" or "SYMFONISK Picture frame".
    static func modelName(ip: String) async -> String? {
        let req = URLRequest(url: URL(string: "http://\(ip):1400/xml/device_description.xml")!, timeoutInterval: 3)
        guard let (data, _) = try? await URLSession.shared.data(for: req), let xml = XMLNode.parse(data),
              let name = xml.value("modelName") else { return nil }
        return name.hasPrefix("Sonos ") ? String(name.dropFirst(6)) : name
    }

    /// "My Sonos" favorites.
    static func favorites(ip: String) async throws -> [Favorite] {
        let r = try await SonosClient(ip: ip).call(.content, "Browse", [
            ("ObjectID", "FV:2"), ("BrowseFlag", "BrowseDirectChildren"),
            ("Filter", "dc:title,res,dc:creator,upnp:albumArtURI,r:resMD"),
            ("StartingIndex", "0"), ("RequestedCount", "200"), ("SortCriteria", ""),
        ])
        guard let result = r.value("Result"), let didl = XMLNode.parse(result) else { return [] }
        return didl.children.compactMap { item in
            guard item.name == "item", let title = item.value("title"),
                  let uri = item.child("res")?.text.trimmingCharacters(in: .whitespacesAndNewlines), !uri.isEmpty
            else { return nil }
            return Favorite(id: item.attributes["id"] ?? uri, title: title, uri: uri, meta: item.value("resMD") ?? "")
        }
    }

    static func symbol(forModel model: String) -> String {
        let m = model.lowercased()
        if m.contains("picture frame") { return "photo.artframe" }
        if m.contains("sub") { return "speaker.wave.3" }
        if ["arc", "beam", "ray", "playbar", "playbase", "soundbar"].contains(where: m.contains) { return "tv.and.hifispeaker.fill" }
        if m.contains("move") || m.contains("roam") { return "speaker" }
        if m.contains("amp") || m.contains("port") || m.contains("connect") { return "amplifier" }
        return "hifispeaker"
    }

    /// "0:03:21" -> 201.
    static func seconds(_ time: String?) -> Int {
        guard let parts = time?.split(separator: ":").compactMap({ Int($0) }), parts.count == 3 else { return 0 }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    static func timeString(_ seconds: Int) -> String {
        seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Human source name from the transport URI (or the current track's URI when playing the queue).
    static func source(media: String, track: String) -> String {
        let u = media.isEmpty ? track : media
        if u.isEmpty { return "Idle" }
        if u.hasPrefix("x-sonos-htastream") { return "TV" }
        if u.hasPrefix("x-rincon-stream") { return "Line-In" }
        if u.hasPrefix("x-sonos-vli") {
            if u.contains("spotify") { return "Spotify Connect" }
            if u.contains("airplay") { return "AirPlay" }
            return "Streaming"
        }
        if u.hasPrefix("x-rincon-mp3radio") || u.hasPrefix("x-sonosapi-stream") || u.hasPrefix("x-sonosapi-radio")
            || u.hasPrefix("hls-radio") || u.hasPrefix("aac:") { return "Radio" }
        let t = track.isEmpty ? u : track
        if t.contains("spotify") { return "Spotify" }
        if t.contains("sid=204") || t.contains("apple") { return "Apple Music" }
        if t.contains("sid=") && t.contains("tidal") { return "TIDAL" }
        if t.hasPrefix("x-file-cifs") || t.hasPrefix("x-smb") { return "Music Library" }
        if u.hasPrefix("x-rincon-queue") { return "Queue" }
        return "Streaming"
    }
}

/// Album art downloads, cached in memory by URL.
@MainActor
enum ArtCache {
    private static var images: [URL: NSImage] = [:]

    static func image(_ url: URL) async -> NSImage? {
        if let hit = images[url] { return hit }
        let req = URLRequest(url: url, timeoutInterval: 5)
        guard let (data, _) = try? await URLSession.shared.data(for: req), let img = NSImage(data: data) else { return nil }
        if images.count > 64 { images.removeAll() }
        images[url] = img
        return img
    }
}
