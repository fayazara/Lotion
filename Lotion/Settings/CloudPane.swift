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
            Section {
                TextField(text: $workerURL, prompt: Text("https://lotion-share.you.workers.dev")) {
                    SettingsControlLabel("Worker URL", detail: "Where your Lotion Share worker runs.")
                }
                .textContentType(.URL)
                .autocorrectionDisabled()
                .onSubmit { verify() }
                SecureField(text: $token, prompt: Text("Paste your token")) {
                    SettingsControlLabel("Token", detail: "Kept in your Keychain.")
                }
                .onChange(of: token) { _, value in Keychain.save(value) }
                .onSubmit { verify() }
                LabeledContent {
                    Button("Verify Connection") { verify() }
                        .disabled(status == .checking || CloudSettings.normalizedURL(workerURL) == nil || token.isEmpty)
                } label: {
                    statusLabel
                }
            } header: {
                Text("Your Worker")
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Publishing runs on your own Cloudflare account, free. Lotion doesn’t run a server, so your notes stay yours.")
                    Text("Copy this prompt and paste it into a coding agent, like Claude Code, Codex or OpenCode. It forks or clones [Lotion Share](\(CloudSettings.templateRepository.absoluteString)), deploys it with D1 and R2, and gives you the URL and token to paste above. Run it again any time to update.")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(CloudSettings.setupPrompt, forType: .string)
                            didCopyPrompt = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                didCopyPrompt = false
                            }
                        } label: {
                            Label(didCopyPrompt ? "Copied" : "Copy Setup Prompt", systemImage: didCopyPrompt ? "checkmark" : "doc.on.doc")
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.glassProminent)
                        Button(showsPrompt ? "Hide Prompt" : "Show Prompt") { showsPrompt.toggle() }
                            .buttonStyle(.link)
                    }
                    if showsPrompt {
                        Text(CloudSettings.setupPrompt)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4)
            } header: {
                Text("Set Up or Update")
            }

            if case .connected = status {
                Section {
                    if notes.isEmpty {
                        Text("Nothing published yet. Use the Share button in a note’s toolbar.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(notes) { note in
                        LabeledContent {
                            HStack(spacing: 6) {
                                Button("Open") { NSWorkspace.shared.open(note.url) }
                                Button("Unpublish", role: .destructive) { unpublish(note) }
                                    .disabled(unpublishing.contains(note.id))
                            }
                        } label: {
                            SettingsControlLabel(note.title, detail: "Updated \(note.updatedAt.formatted(.relative(presentation: .named)))")
                        }
                    }
                } header: {
                    Text("Published Notes")
                }
            }
        }
        .task { if CloudSettings.isConfigured { verify() } }
    }

    @ViewBuilder private var statusLabel: some View {
        switch status {
        case .idle:
            SettingsControlLabel("Connection", detail: "Check the URL and token work.")
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
        case .connected(let info, let latest):
            VStack(alignment: .leading, spacing: 2) {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if let latest, info.version.isOlderVersion(than: latest) {
                    Text("Lotion Share \(info.version) · Version \(latest) is out. Run the setup prompt again to update.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Lotion Share \(info.version) · \(info.notes == 1 ? "1 published note" : "\(info.notes) published notes")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 2) {
                Label("Not connected", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
