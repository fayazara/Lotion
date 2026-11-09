//
//  UpdaterManager.swift
//  Lotion
//
//  Sparkle auto-updates. The feed and public key live in Config/Info.plist;
//  releases are published by `go run ./cmd/lotion-release`. Lotion is
//  sandboxed, so Sparkle installs through its launcher XPC service
//  (SUEnableInstallerLauncherService plus the -spks/-spki mach-lookup
//  exceptions in Config/Lotion.entitlements).
//

import AppKit
import Combine
import Foundation
import Sparkle
import SwiftUI

@MainActor
final class UpdaterManager: NSObject, ObservableObject {
    static let shared = UpdaterManager()

    private let controller: SPUStandardUpdaterController

    @Published private(set) var canCheckForUpdates = false

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    private override init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// Starts the update schedule. Debug builds never check, so a build from
    /// Xcode is not replaced by the latest release.
    func start() {
        #if !DEBUG
        controller.startUpdater()
        #endif
    }

    func checkForUpdates() {
        #if !DEBUG
        NSApp.activate()
        controller.checkForUpdates(nil)
        #endif
    }
}

/// "Check for Updates…" in the app menu.
struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = UpdaterManager.shared

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
