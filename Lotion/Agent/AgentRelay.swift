//
//  AgentRelay.swift
//  Lotion
//
//  `Lotion --mcp`: the process an agent (Claude Code, Codex, ...) launches as
//  its MCP server. It never starts the UI. It connects to the running app
//  over a Unix socket - opening Lotion in the background first if needed -
//  and copies newline-delimited JSON-RPC between the agent's stdio and that
//  socket. Everything else happens in the app, so changes land in the same
//  library the window shows.
//
//  Lotion is sandboxed. Run from a terminal, this binary gets the same
//  container as the app, so both find the socket at the same path.
//

import AppKit
import Darwin
import Foundation

nonisolated enum AgentSocket {
    static let relayArgument = "--mcp"
    /// Passed when the relay opens the app, so it doesn't come to the front
    /// over whatever the user is doing.
    static let launchedByAgentArgument = "--launched-by-agent"

    /// In the app's container when sandboxed, so only Lotion can reach it.
    static var url: URL {
        URL.applicationSupportDirectory
            .appending(path: "Lotion", directoryHint: .isDirectory)
            .appending(path: "agent.sock")
    }

    /// Runs `body` with an address for the socket. A sandbox container's path
    /// is often longer than a socket address holds (104 bytes), so then the
    /// address is the bare file name, relative to its folder for the call.
    static func withAddress<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T? {
        let path = url.path
        if let result = withAddress(path: path, body) { return result }
        let directory = url.deletingLastPathComponent().path
        let previous = open(".", O_RDONLY)
        guard previous >= 0, chdir(directory) == 0 else {
            if previous >= 0 { close(previous) }
            return nil
        }
        defer {
            fchdir(previous)
            close(previous)
        }
        return withAddress(path: url.lastPathComponent, body)
    }

    private static func withAddress<T>(path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// A connected socket, or nil when nothing is listening.
    static func connect() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let result = withAddress { Darwin.connect(fd, $0, $1) }
        guard result == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    @discardableResult
    static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return true }
            var remaining = buffer.count
            while remaining > 0 {
                let written = write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                remaining -= written
                pointer += written
            }
            return true
        }
    }
}

nonisolated enum AgentRelay {
    static var isRequested: Bool {
        CommandLine.arguments.contains(AgentSocket.relayArgument)
    }

    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        let relay = Connection()
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if !relay.forward(line) {
                replyUnavailable(to: line, reason: relay.unavailableReason)
            }
        }
        exit(0)
    }

    /// Answers a request the app never saw, so the agent gets a reason
    /// instead of waiting forever.
    private static func replyUnavailable(to line: String, reason: String) {
        guard let message = try? JSONValue.decoder.decode(JSONValue.self, from: Data(line.utf8)),
              let id = message["id"], message["method"] != nil else {
            return
        }
        let response: JSONValue = [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": -32000, "message": .string(reason)],
        ]
        if let data = try? response.encodedLine() {
            Stdout.write(data)
        }
    }

    private enum Stdout {
        private static let lock = NSLock()

        static func write(_ data: Data) {
            lock.withLock { _ = AgentSocket.writeAll(data, to: STDOUT_FILENO) }
        }
    }

    /// The socket to the app, reopened (relaunching Lotion if it quit) the
    /// next time the agent sends something after the app goes away.
    private final class Connection: @unchecked Sendable {
        private let lock = NSLock()
        private var fd: Int32 = -1
        private(set) var unavailableReason = "Lotion is not running."

        func forward(_ line: String) -> Bool {
            var data = Data(line.utf8)
            data.append(0x0A)
            for _ in 0..<2 {
                guard let fd = currentOrNewSocket() else { return false }
                if AgentSocket.writeAll(data, to: fd) { return true }
                drop(fd)
            }
            return false
        }

        private func currentOrNewSocket() -> Int32? {
            if let fd = lock.withLock({ fd >= 0 ? fd : nil }) { return fd }
            guard let fd = openSocket() else { return nil }
            lock.withLock { self.fd = fd }
            let reader = Thread { [weak self] in self?.pump(from: fd) }
            reader.name = "Lotion MCP relay"
            reader.start()
            return fd
        }

        private func drop(_ dead: Int32) {
            lock.withLock {
                guard fd == dead else { return }
                close(fd)
                fd = -1
            }
        }

        /// Copies whole lines from the app to stdout. A line cut off by the
        /// app quitting is thrown away rather than glued to the next one.
        private func pump(from fd: Int32) {
            var pending = Data()
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = read(fd, &chunk, chunk.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                pending.append(contentsOf: chunk[0..<count])
                if let lastNewline = pending.lastIndex(of: 0x0A) {
                    Stdout.write(Data(pending[...lastNewline]))
                    pending = Data(pending[pending.index(after: lastNewline)...])
                }
            }
            drop(fd)
        }

        private func openSocket() -> Int32? {
            if let fd = AgentSocket.connect() { return fd }

            let bundleID = Bundle.main.bundleIdentifier ?? "com.fayazahmed.Lotion"
            let alreadyRunning = !NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID).isEmpty
            if !alreadyRunning {
                launchApp()
            }
            // A running app with no socket has the agent server switched
            // off; give it a moment in case it is still starting up.
            let deadline = Date().addingTimeInterval(alreadyRunning ? 2 : 30)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.2)
                if let fd = AgentSocket.connect() { return fd }
            }
            unavailableReason = alreadyRunning
                ? "Lotion is running but its agent server is off. Turn on \"Allow AI agents\" in Lotion Settings → AI Agents."
                : "Lotion could not be opened."
            return nil
        }

        private func launchApp() {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            configuration.arguments = [AgentSocket.launchedByAgentArgument]
            let done = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
                done.signal()
            }
            _ = done.wait(timeout: .now() + 30)
        }
    }
}
