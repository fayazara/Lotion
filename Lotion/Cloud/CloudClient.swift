//
//  CloudClient.swift
//  Lotion
//
//  Talks to Lotion Share: a Cloudflare Worker the user deploys on their own
//  account (github.com/fayazara/lotion-share). The worker's address is a
//  preference; the shared token it checks is kept in the Keychain.
//

import Foundation
import Security

// MARK: - Settings

enum CloudSettings {
    /// The template the setup prompt points agents at.
    static let templateRepository = URL(string: "https://github.com/fayazara/lotion-share")!
    /// The template's package.json, to tell whether a deployed worker is behind.
    static let latestManifest = URL(string: "https://raw.githubusercontent.com/fayazara/lotion-share/main/package.json")!
    /// The oldest worker API this version of Lotion can talk to.
    static let requiredAPIVersion = 1

    static var workerURL: URL? {
        let raw = (UserDefaults.standard.string(forKey: Prefs.cloudURL) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedURL(raw)
    }

    static var token: String? {
        #if DEBUG
        // Self-tests pass a token in, and leave the Keychain alone.
        if let token = UserDefaults.standard.string(forKey: "LotionCloudToken") { return token }
        #endif
        return Keychain.read()
    }

    static var isConfigured: Bool { workerURL != nil && !(token ?? "").isEmpty }

    /// `lotion-share.me.workers.dev` reads as `https://lotion-share.me.workers.dev`.
    static func normalizedURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = (text.hasPrefix("localhost") || text.hasPrefix("127.") ? "http://" : "https://") + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }

    /// The prompt the user pastes into their coding agent. It stays short and
    /// points at DEPLOY.md, so the steps can change without a new Lotion.
    static let setupPrompt = """
    Set up Lotion Share on my Cloudflare account, so the Lotion notes app can publish my notes to the web. If I already have it set up, update it instead.

    The code is at \(templateRepository.absoluteString). If you're not already in a clone of it, look for one on this computer first. If there isn't one:
    - Ask me whether to fork it on my GitHub account (recommended) or just clone it.
    - Keep \(templateRepository.absoluteString) as the `upstream` remote, so it can be updated later.

    Then follow DEPLOY.md in the repository, step by step. It covers installing, signing in to Cloudflare, deploying, and updating a copy that's already deployed.

    When you're done, give me the Worker URL and the token, so I can paste them into Lotion → Settings → Cloud. Don't save the token in any file.
    """
}

// MARK: - Keychain

/// The token, as a generic password only this app reads.
enum Keychain {
    private static let service = "com.fayazahmed.Lotion.cloud"
    private static let account = "token"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// An empty token deletes the item.
    @discardableResult
    static func save(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return true
        }
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Lotion Share token"
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }
}

// MARK: - API

struct WorkerInfo: Decodable, Equatable {
    struct Migrations: Decodable, Equatable {
        let applied: Int
        let bundled: Int
        let pending: Int
    }

    let app: String
    let apiVersion: Int
    let version: String
    let migrations: Migrations
    let notes: Int
}

struct RemoteNote: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let updatedAt: Date
    let url: URL
}

/// What the worker answers to a publish: where the note is, and which of
/// its files it doesn't have yet.
struct PublishReply: Decodable {
    let id: String
    let url: URL
    let missing: [String]
}

enum CloudError: LocalizedError {
    case notConfigured
    case unauthorized
    case notLotionShare
    case outdated(WorkerInfo)
    case migrationsPending(Int)
    case server(status: Int, message: String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Add your worker’s URL and token in Settings → Cloud."
        case .unauthorized:
            "The worker didn’t accept the token. Check it in Settings → Cloud."
        case .notLotionShare:
            "That address answered, but it isn’t a Lotion Share worker. Check the URL."
        case .outdated(let info):
            "Your worker runs Lotion Share \(info.version), which is too old for this version of Lotion. Run the setup prompt again to update it."
        case .migrationsPending(let count):
            "Your worker’s database is \(count == 1 ? "one update" : "\(count) updates") behind. Run the setup prompt again to finish updating it."
        case .server(let status, let message):
            message.isEmpty ? "The worker answered with an error (\(status))." : message
        case .network(let message):
            message
        }
    }
}

/// One worker, at one address, with one token.
struct CloudClient {
    let baseURL: URL
    let token: String

    /// The configured worker, or `notConfigured`.
    static func configured() throws -> CloudClient {
        guard let url = CloudSettings.workerURL, let token = CloudSettings.token, !token.isEmpty else { throw CloudError.notConfigured }
        return CloudClient(baseURL: url, token: token)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.httpAdditionalHeaders = ["User-Agent": "Lotion"]
        return URLSession(configuration: configuration)
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a date: \(text)"))
        }
        return decoder
    }()

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Sends a request and checks its status; a 401 is always `unauthorized`.
    private func send(_ request: URLRequest, body: Data? = nil, file: URL? = nil) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            if let file {
                (data, response) = try await Self.session.upload(for: request, fromFile: file)
            } else if let body {
                (data, response) = try await Self.session.upload(for: request, from: body)
            } else {
                (data, response) = try await Self.session.data(for: request)
            }
        } catch let error as URLError {
            throw CloudError.network(Self.describe(error))
        }
        guard let http = response as? HTTPURLResponse else { throw CloudError.network("The worker didn’t answer.") }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw CloudError.unauthorized
        default:
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            if http.statusCode == 404, message == nil { throw CloudError.notLotionShare }
            throw CloudError.server(status: http.statusCode, message: message ?? "")
        }
    }

    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost: "You’re offline."
        case .cannotFindHost, .dnsLookupFailed: "Couldn’t find that address. Check the worker URL."
        case .cannotConnectToHost: "Couldn’t connect to the worker. Check the URL, and that it’s deployed."
        case .timedOut: "The worker took too long to answer."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
            "Couldn’t make a secure connection to the worker."
        default: error.localizedDescription
        }
    }

    // MARK: Calls

    /// Checks the URL and the token together, and reads the deployed version.
    func info() async throws -> WorkerInfo {
        let data = try await send(request("api/v1/info"))
        guard let info = try? Self.decoder.decode(WorkerInfo.self, from: data), info.app == "lotion-share" else {
            throw CloudError.notLotionShare
        }
        return info
    }

    /// Fails unless this worker can take what this Lotion sends.
    func checkCompatible() async throws -> WorkerInfo {
        let info = try await info()
        if info.apiVersion < CloudSettings.requiredAPIVersion { throw CloudError.outdated(info) }
        if info.migrations.pending > 0 { throw CloudError.migrationsPending(info.migrations.pending) }
        return info
    }

    func notes() async throws -> [RemoteNote] {
        struct Listing: Decodable { let notes: [RemoteNote] }
        let data = try await send(request("api/v1/notes"))
        return try Self.decoder.decode(Listing.self, from: data).notes
    }

    func publish(id: String, payload: some Encodable) async throws -> PublishReply {
        var request = request("api/v1/notes/\(id)", method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data = try await send(request, body: try JSONEncoder().encode(payload))
        return try Self.decoder.decode(PublishReply.self, from: data)
    }

    func upload(noteID: String, name: String, file: URL, contentType: String) async throws {
        var request = request("api/v1/notes/\(noteID)/files/\(name)", method: "PUT")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        _ = try await send(request, file: file)
    }

    func upload(noteID: String, name: String, data: Data, contentType: String) async throws {
        var request = request("api/v1/notes/\(noteID)/files/\(name)", method: "PUT")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        _ = try await send(request, body: data)
    }

    func unpublish(id: String) async throws {
        _ = try await send(request("api/v1/notes/\(id)", method: "DELETE"))
    }

    /// The newest template version on GitHub, or nil when it can't be read.
    static func latestTemplateVersion() async -> String? {
        struct Manifest: Decodable { let version: String? }
        guard let (data, response) = try? await session.data(from: CloudSettings.latestManifest),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONDecoder().decode(Manifest.self, from: data))?.version
    }
}

extension String {
    /// Whether this dotted version is older than `other`: "0.1.0" < "0.2.0".
    func isOlderVersion(than other: String) -> Bool {
        let lhs = split(separator: ".").map { Int($0) ?? 0 }
        let rhs = other.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a < b }
        }
        return false
    }
}
