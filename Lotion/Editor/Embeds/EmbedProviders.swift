//
//  EmbedProviders.swift
//  Lotion
//
//  What a link alone on its line becomes, and the facts a card needs about
//  it. Videos, players and posts are recognized from their address; any
//  other page becomes a bookmark card made from its Open Graph tags. What is
//  fetched is kept in the library's `.lotion/embeds`, so a card draws from
//  disk after the first time.
//

import AppKit
import CryptoKit

enum VideoSite: String {
    case youtube, vimeo, loom

    var name: String {
        switch self {
        case .youtube: "YouTube"
        case .vimeo: "Vimeo"
        case .loom: "Loom"
        }
    }
}

struct GitHubRef: Equatable {
    let owner: String
    let repo: String
    /// An issue or pull request number.
    var number: Int?
    var isPull = false

    var slug: String { "\(owner)/\(repo)" }
}

struct MapPlace: Equatable {
    var latitude: Double?
    var longitude: Double?
    /// Meters across the snapshot.
    var span: Double = 1500
    var query: String?
    var name: String?
    let service: String
}

enum EmbedTarget: Equatable {
    case bookmark(URL)
    case video(VideoSite, id: String, page: URL, player: URL)
    /// A live web player of a fixed height: Spotify, Apple Music, Figma, CodePen, an iframe.
    case frame(URL, height: CGFloat, name: String)
    case github(GitHubRef, page: URL)
    case post(URL)
    case map(MapPlace, page: URL)

    var page: URL? {
        switch self {
        case .bookmark(let url), .video(_, _, let url, _), .github(_, let url), .post(let url), .map(_, let url): url
        case .frame(let url, _, _): url
        }
    }

    // MARK: Recognizing links

    static func classify(_ source: String) -> EmbedTarget? {
        guard let url = URL(string: source.trimmingCharacters(in: .whitespaces)), let rawHost = url.host?.lowercased() else { return nil }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        let parts = url.pathComponents.filter { $0 != "/" }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ name: String) -> String? { query.first { $0.name == name }?.value }

        // YouTube
        var youtubeID: String?
        if host == "youtu.be", let first = parts.first { youtubeID = first }
        if host.hasSuffix("youtube.com") || host == "youtube-nocookie.com" {
            if parts.first == "watch" { youtubeID = item("v") }
            if ["shorts", "embed", "live", "v"].contains(parts.first ?? ""), parts.count > 1 { youtubeID = parts[1] }
        }
        if let id = youtubeID, id.count >= 6, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
            var player = "https://www.youtube-nocookie.com/embed/\(id)?autoplay=1&rel=0&playsinline=1&modestbranding=1"
            if let time = item("t") ?? item("start"), let seconds = Self.seconds(time) { player += "&start=\(seconds)" }
            return .video(.youtube, id: id, page: url, player: URL(string: player)!)
        }
        // Vimeo
        if host == "vimeo.com", let id = parts.first(where: { $0.allSatisfy(\.isNumber) }) {
            return .video(.vimeo, id: id, page: url, player: URL(string: "https://player.vimeo.com/video/\(id)?autoplay=1&dnt=1")!)
        }
        if host == "player.vimeo.com", parts.first == "video", parts.count > 1 {
            return .video(.vimeo, id: parts[1], page: url, player: URL(string: "https://player.vimeo.com/video/\(parts[1])?autoplay=1&dnt=1")!)
        }
        // Loom
        if host.hasSuffix("loom.com"), ["share", "embed"].contains(parts.first ?? ""), parts.count > 1 {
            return .video(.loom, id: parts[1], page: url, player: URL(string: "https://www.loom.com/embed/\(parts[1])?autoplay=1&hide_owner=true")!)
        }
        // Spotify
        if host == "open.spotify.com" {
            let rest = parts.first?.hasPrefix("intl-") == true ? Array(parts.dropFirst()) : parts
            if rest.count >= 2, ["track", "album", "playlist", "episode", "show", "artist"].contains(rest[0]) {
                let compact = rest[0] == "track" || rest[0] == "episode"
                return .frame(URL(string: "https://open.spotify.com/embed/\(rest[0])/\(rest[1])?utm_source=lotion")!,
                              height: compact ? 152 : 352, name: "Spotify")
            }
        }
        // Apple Music and Podcasts
        if host == "music.apple.com" || host == "podcasts.apple.com", var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.host = "embed." + host
            let single = item("i") != nil || parts.contains("song")
            if let embed = components.url {
                return .frame(embed, height: single ? 175 : 450, name: host.hasPrefix("music") ? "Apple Music" : "Apple Podcasts")
            }
        }
        // Figma
        if host.hasSuffix("figma.com"), ["file", "design", "proto", "board", "slides"].contains(parts.first ?? "") {
            let encoded = source.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? source
            return .frame(URL(string: "https://www.figma.com/embed?embed_host=lotion&url=\(encoded)")!, height: 450, name: "Figma")
        }
        // CodePen
        if host == "codepen.io" {
            // `/user/pen/id`, or `/team/name/pen/id` for teams.
            let rest = parts.first == "team" ? Array(parts.dropFirst()) : parts
            if rest.count >= 3, ["pen", "full", "details"].contains(rest[1]) {
                let owner = parts.first == "team" ? "team/\(rest[0])" : rest[0]
                return .frame(URL(string: "https://codepen.io/\(owner)/embed/\(rest[2])?default-tab=result")!, height: 400, name: "CodePen")
            }
        }
        // GitHub
        if host == "github.com", parts.count >= 2, !Self.githubReserved.contains(parts[0].lowercased()) {
            var ref = GitHubRef(owner: parts[0], repo: parts[1].replacingOccurrences(of: ".git", with: ""))
            if parts.count >= 4, parts[2] == "issues" || parts[2] == "pull", let number = Int(parts[3]) {
                ref.number = number
                ref.isPull = parts[2] == "pull"
                return .github(ref, page: url)
            }
            if parts.count == 2 { return .github(ref, page: url) }
        }
        // X / Twitter
        if ["twitter.com", "x.com", "mobile.twitter.com"].contains(host), parts.count >= 3, parts[1] == "status" {
            return .post(url)
        }
        // Maps
        if host == "maps.apple.com" || (host == "maps.apple" ) {
            var place = MapPlace(service: "Apple Maps")
            if let ll = item("ll") ?? item("sll") ?? item("coordinate"), let (lat, lng) = Self.pair(ll) {
                place.latitude = lat
                place.longitude = lng
            }
            place.query = item("q") ?? item("address") ?? item("daddr")
            place.name = item("q") ?? item("name")
            if let z = item("z").flatMap(Double.init) { place.span = Self.span(forZoom: z) }
            if place.latitude != nil || place.query != nil { return .map(place, page: url) }
        }
        if (host.hasPrefix("google.") || host.hasSuffix(".google.com") || host == "google.com") && parts.first == "maps" || host == "maps.google.com" {
            var place = MapPlace(service: "Google Maps")
            let path = url.path
            if let match = path.range(of: #"@(-?\d+\.\d+),(-?\d+\.\d+)(?:,(\d+(?:\.\d+)?)z)?"#, options: .regularExpression) {
                let text = String(path[match]).dropFirst()
                let numbers = text.split(separator: ",")
                place.latitude = Double(numbers[0])
                place.longitude = Double(numbers[1])
                if numbers.count > 2, let z = Double(numbers[2].dropLast()) { place.span = Self.span(forZoom: z) }
            }
            if let index = parts.firstIndex(of: "place"), index + 1 < parts.count {
                place.name = parts[index + 1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            }
            if let q = item("q") ?? item("query") {
                if let (lat, lng) = Self.pair(q) { place.latitude = lat; place.longitude = lng } else { place.query = q; place.name = q }
            }
            if place.query == nil, place.latitude == nil, let name = place.name { place.query = name }
            if place.latitude != nil || place.query != nil { return .map(place, page: url) }
        }
        return .bookmark(url)
    }

    /// Paths on github.com that aren't someone's repositories.
    private static let githubReserved: Set<String> = [
        "settings", "orgs", "topics", "marketplace", "features", "explore", "notifications", "pulls", "issues", "sponsors",
        "login", "join", "about", "pricing", "enterprise", "collections", "trending", "search", "new", "apps", "customer-stories",
    ]

    private static func seconds(_ time: String) -> Int? {
        if let value = Int(time) { return value }
        var total = 0, number = 0
        for character in time {
            if let digit = character.wholeNumberValue { number = number * 10 + digit; continue }
            switch character {
            case "h": total += number * 3600
            case "m": total += number * 60
            case "s": total += number
            default: return nil
            }
            number = 0
        }
        return total > 0 ? total : nil
    }

    private static func pair(_ text: String) -> (Double, Double)? {
        let numbers = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 2, abs(numbers[0]) <= 90, abs(numbers[1]) <= 180 else { return nil }
        return (numbers[0], numbers[1])
    }

    private static func span(forZoom zoom: Double) -> Double {
        // A web map's zoom level, as meters across a card.
        40_000_000 / pow(2, zoom) * 1.2
    }
}

// MARK: - Cache

/// Facts about links, as small dictionaries, in memory and on disk.
enum EmbedCache {
    static var directory: URL?
    static let didLoad = Notification.Name("LotionEmbedDidLoad")

    private static var memory: [String: [String: String]] = [:]
    private static var pending: Set<String> = []
    private static var failed: Set<String> = []
    private static var images: [String: NSImage] = [:]
    private static var pendingImages: Set<String> = []
    private static var failedImages: Set<String> = []

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static func key(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func file(_ key: String, _ ext: String) -> URL? {
        directory?.appending(path: "\(key).\(ext)")
    }

    /// The cached facts for `id`, or nil while `load` fetches them (once).
    static func facts(_ id: String, maxAge: TimeInterval? = nil, load: @escaping () async -> [String: String]?) -> [String: String]? {
        let key = key(id)
        if let facts = memory[key] { return facts }
        if failed.contains(key) || pending.contains(key) { return nil }
        if let url = file(key, "json"), let data = try? Data(contentsOf: url),
           let facts = try? JSONDecoder().decode([String: String].self, from: data) {
            let age = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { -$0.timeIntervalSinceNow } ?? 0
            if maxAge == nil || age < maxAge! {
                memory[key] = facts
                return facts
            }
            memory[key] = facts
            refresh(key, load: load)
            return facts
        }
        refresh(key, load: load)
        return nil
    }

    private static func refresh(_ key: String, load: @escaping () async -> [String: String]?) {
        guard !pending.contains(key) else { return }
        pending.insert(key)
        Task {
            let facts = await load()
            pending.remove(key)
            guard let facts, !facts.isEmpty else {
                if memory[key] == nil { failed.insert(key) }
                NotificationCenter.default.post(name: didLoad, object: nil)
                return
            }
            memory[key] = facts
            if let url = file(key, "json"), let data = try? JSONEncoder().encode(facts) {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            }
            NotificationCenter.default.post(name: didLoad, object: nil)
        }
    }

    static func hasFailed(_ id: String) -> Bool { failed.contains(key(id)) }

    /// Forgets what is known about `id`, so it is fetched again.
    static func forget(_ id: String) {
        let key = key(id)
        memory[key] = nil
        failed.remove(key)
        if let url = file(key, "json") { try? FileManager.default.removeItem(at: url) }
    }

    /// An image from the web, or nil while it loads (once).
    static func image(_ address: String?) -> NSImage? {
        guard let address, let url = URL(string: address), url.scheme?.hasPrefix("http") == true else { return nil }
        let key = key(address)
        if let image = images[key] { return image }
        if pendingImages.contains(key) || failedImages.contains(key) { return nil }
        if let file = file(key, "img"), let image = NSImage(contentsOf: file) {
            images[key] = image
            return image
        }
        pendingImages.insert(key)
        Task {
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let data = try? await URLSession.shared.data(for: request).0
            pendingImages.remove(key)
            guard let data, let image = NSImage(data: data), image.size.width > 1 else {
                failedImages.insert(key)
                NotificationCenter.default.post(name: didLoad, object: nil)
                return
            }
            images[key] = image
            if let file = file(key, "img") {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            }
            NotificationCenter.default.post(name: didLoad, object: nil)
        }
        return nil
    }

    static func imageIsLoading(_ address: String?) -> Bool {
        guard let address else { return false }
        return pendingImages.contains(key(address))
    }

    // MARK: Fetching

    static func json(_ address: String, headers: [String: String] = [:]) async -> [String: Any]? {
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// oEmbed facts: title, author and thumbnail.
    static func oEmbed(_ endpoint: String, for page: URL) async -> [String: String]? {
        let encoded = page.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? page.absoluteString
        guard let json = await json(endpoint + (endpoint.contains("?") ? "&" : "?") + "url=" + encoded) else { return nil }
        var facts: [String: String] = [:]
        for key in ["title", "author_name", "thumbnail_url", "html", "provider_name"] {
            if let value = json[key] as? String { facts[key] = value }
        }
        return facts
    }

    /// A page's title, description, image and site name, from its head.
    static func pageFacts(_ page: URL) async -> [String: String]? {
        var request = URLRequest(url: page, timeoutInterval: 15)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        let final = response.url ?? page
        let head = data.prefix(600_000)
        guard let html = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else { return nil }
        return PageHead.facts(html, base: final)
    }
}

/// Reads a page's `<head>` for a card.
enum PageHead {
    private static let metaPattern = try! NSRegularExpression(pattern: #"<meta\s[^>]*>"#, options: [.caseInsensitive])
    private static let attributePattern = try! NSRegularExpression(pattern: #"([a-zA-Z:_-]+)\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))"#)
    private static let titlePattern = try! NSRegularExpression(pattern: #"<title[^>]*>([\s\S]*?)</title>"#, options: [.caseInsensitive])
    private static let linkPattern = try! NSRegularExpression(pattern: #"<link\s[^>]*>"#, options: [.caseInsensitive])

    static func attributes(_ tag: String) -> [String: String] {
        var result: [String: String] = [:]
        let range = NSRange(tag.startIndex..., in: tag)
        for match in attributePattern.matches(in: tag, range: range) {
            guard let name = Range(match.range(at: 1), in: tag) else { continue }
            var value = ""
            for group in 3...5 { if let r = Range(match.range(at: group), in: tag) { value = String(tag[r]); break } }
            result[tag[name].lowercased()] = value
        }
        return result
    }

    static func facts(_ html: String, base: URL) -> [String: String] {
        let headEnd = html.range(of: "</head>", options: .caseInsensitive)?.lowerBound ?? html.endIndex
        let head = String(html[..<headEnd])
        let range = NSRange(head.startIndex..., in: head)
        var meta: [String: String] = [:]
        for match in metaPattern.matches(in: head, range: range) {
            guard let r = Range(match.range, in: head) else { continue }
            let attrs = attributes(String(head[r]))
            guard let key = (attrs["property"] ?? attrs["name"] ?? attrs["itemprop"])?.lowercased(), let content = attrs["content"],
                  meta[key] == nil else { continue }
            meta[key] = decode(content)
        }
        var facts: [String: String] = [:]
        facts["title"] = meta["og:title"] ?? meta["twitter:title"]
        if facts["title"] == nil, let match = titlePattern.firstMatch(in: head, range: range), let r = Range(match.range(at: 1), in: head) {
            facts["title"] = decode(String(head[r])).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        facts["description"] = meta["og:description"] ?? meta["twitter:description"] ?? meta["description"]
        if let image = meta["og:image"] ?? meta["og:image:url"] ?? meta["og:image:secure_url"] ?? meta["twitter:image"] ?? meta["twitter:image:src"],
           let url = URL(string: image, relativeTo: base) {
            facts["image"] = url.absoluteString
        }
        facts["site"] = meta["og:site_name"] ?? meta["application-name"]
        // A larger icon than the favicon service's, when the page names one.
        for match in linkPattern.matches(in: head, range: range) {
            guard let r = Range(match.range, in: head) else { continue }
            let attrs = attributes(String(head[r]))
            guard let rel = attrs["rel"]?.lowercased(), rel.contains("apple-touch-icon"), let href = attrs["href"],
                  let url = URL(string: href, relativeTo: base) else { continue }
            facts["icon"] = url.absoluteString
            break
        }
        facts["url"] = base.absoluteString
        return facts.filter { !$0.value.isEmpty }
    }

    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " ",
                     "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&rsquo;": "’", "&lsquo;": "‘", "&rdquo;": "”", "&ldquo;": "“"]
        for (entity, character) in named { result = result.replacingOccurrences(of: entity, with: character) }
        // Numeric entities.
        let pattern = try! NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#)
        let ns = result as NSString
        var output = ""
        var last = 0
        for match in pattern.matches(in: result, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let hex = ns.substring(with: match.range(at: 1)) == "x"
            let digits = ns.substring(with: match.range(at: 2))
            if let value = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(value) {
                output.unicodeScalars.append(scalar)
            }
            last = match.range.location + match.range.length
        }
        output += ns.substring(from: last)
        return output
    }
}
