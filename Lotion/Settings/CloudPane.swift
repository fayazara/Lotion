//
//  CloudPane.swift
//  Lotion
//
//  Settings → Cloud: where Lotion publishes. Lotion runs no servers; each
//  user deploys Lotion Share to their own Cloudflare account, by pasting a
//  prompt into their coding agent, then pastes the worker's URL and token
//  here. The token goes in the Keychain.
//

import AppKit
import SwiftUI

struct CloudPane: View {
    @AppStorage(Prefs.cloudURL) private var workerURL = ""
    @State private var token = Keychain.read() ?? ""
    @State private var status: Status = .idle
    @State private var notes: [RemoteNote] = []
    @State private var didCopyPrompt = false
    @State private var showsPrompt = false
    @State private var unpublishing: Set<String> = []

    enum Status: Equatable {
        case idle
        case checking
        case connected(WorkerInfo, latest: String?)
        case failed(String)
    }

    var body: some View {
        SettingsPage {
            SettingsSection("Your worker", icon: "globe") {
                SettingsRow("Worker URL", icon: "link", detail: "Where your Lotion Share worker runs.") {
                    TextField("Worker URL", text: $workerURL, prompt: Text("https://lotion-share.you.workers.dev"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .frame(minWidth: 150, idealWidth: 250, maxWidth: 250)
                        .onSubmit { verify() }
                }
                SettingsRow("Token", icon: "key", detail: "Kept in your Keychain.") {
                    SecureField("Token", text: $token, prompt: Text("Paste your token"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 150, idealWidth: 250, maxWidth: 250)
                        .onChange(of: token) { _, value in Keychain.save(value) }
                        .onSubmit { verify() }
                }
                HStack(alignment: .top, spacing: SettingsStyle.chipGap) {
                    SettingsIcon(statusIcon)
                    statusLabel
                        .frame(minHeight: SettingsStyle.chip, alignment: .leading)
                    Spacer(minLength: 16)
                    Button("Verify") { verify() }
                        .disabled(status == .checking || CloudSettings.normalizedURL(workerURL) == nil || token.isEmpty)
                        .frame(minHeight: SettingsStyle.chip)
                }
                .padding(SettingsStyle.rowPadding)
            }

            SettingsSection("Set up or update", icon: "wrench.and.screwdriver") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Publishing runs on your own Cloudflare account, free. Lotion doesn’t run a server, so your notes stay yours.")
                        .foregroundStyle(Palette.label)
                    Text("Paste this prompt into a coding agent, like Claude Code, Codex or OpenCode. It forks or clones [Lotion Share](\(CloudSettings.templateRepository.absoluteString)), deploys it with D1 and R2, and gives you the URL and token to paste above. Run it again any time to update.")
                        .foregroundStyle(Palette.secondaryLabel)
                    HStack(spacing: 10) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(CloudSettings.setupPrompt, forType: .string)
                            didCopyPrompt = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                didCopyPrompt = false
                            }
                        } label: {
                            Label(didCopyPrompt ? "Copied" : "Copy Setup Prompt", icon: didCopyPrompt ? "checkmark" : "doc.on.doc")
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.glassProminent)
                        Button(showsPrompt ? "Hide Prompt" : "Show Prompt") { showsPrompt.toggle() }
                            .buttonStyle(.link)
                    }
                    .padding(.top, 2)
                    if showsPrompt {
                        Text(CloudSettings.setupPrompt)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .padding(SettingsStyle.rowPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if case .connected = status {
                SettingsSection("Published notes", icon: "square.and.arrow.up") {
                    if notes.isEmpty {
                        Text("Nothing published yet. Use the Share button in a note’s toolbar.")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.secondaryLabel)
                            .padding(SettingsStyle.rowPadding)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(notes) { note in
                        SettingsRow(note.title, icon: "doc.text",
                                    detail: "Updated \(note.updatedAt.formatted(.relative(presentation: .named)))") {
                            HStack(spacing: 6) {
                                Button("Open") { NSWorkspace.shared.open(note.url) }
                                Button("Unpublish", role: .destructive) { unpublish(note) }
                                    .disabled(unpublishing.contains(note.id))
                            }
                        }
                    }
                }
            }
        }
        .task { if CloudSettings.isConfigured { verify() } }
    }

    private var statusIcon: String {
        switch status {
        case .connected: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        default: "cloud"
        }
    }

    @ViewBuilder private var statusLabel: some View {
        switch status {
        case .idle:
            VStack(alignment: .leading, spacing: 2) {
                Text("Connection")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.label)
                Text("Check the URL and token work.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.secondaryLabel)
            }
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
        case .connected(let info, let latest):
            VStack(alignment: .leading, spacing: 2) {
                Text("Connected")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.green)
                if let latest, info.version.isOlderVersion(than: latest) {
                    Text("Lotion Share \(info.version) · Version \(latest) is out. Run the setup prompt again to update.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.orange)
                } else {
                    Text("Lotion Share \(info.version) · \(info.notes == 1 ? "1 published note" : "\(info.notes) published notes")")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.secondaryLabel)
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 2) {
                Text("Not connected")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func verify() {
        guard let url = CloudSettings.normalizedURL(workerURL), !token.isEmpty else { return }
        Keychain.save(token)
        status = .checking
        Task {
            let client = CloudClient(baseURL: url, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
            do {
                async let latest = CloudClient.latestTemplateVersion()
                let info = try await client.checkCompatible()
                notes = (try? await client.notes()) ?? []
                status = .connected(info, latest: await latest)
            } catch {
                notes = []
                status = .failed(error.localizedDescription)
            }
        }
    }

    private func unpublish(_ note: RemoteNote) {
        guard let url = CloudSettings.normalizedURL(workerURL) else { return }
        unpublishing.insert(note.id)
        Task {
            do {
                try await CloudClient(baseURL: url, token: token).unpublish(id: note.id)
                notes.removeAll { $0.id == note.id }
                NotificationCenter.default.post(name: .cloudDidUnpublish, object: note.id)
            } catch {
                status = .failed(error.localizedDescription)
            }
            unpublishing.remove(note.id)
        }
    }
}
