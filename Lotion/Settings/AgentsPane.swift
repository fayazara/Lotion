//
//  AgentsPane.swift
//  Lotion
//
//  Settings → AI Agents: the switch for the local MCP server that lets
//  coding agents read and change notes, and the one-line setup for the
//  agents people use most.
//

import AppKit
import SwiftUI

struct AgentsPane: View {
    @AppStorage(AgentPreferences.enabledKey) private var isEnabled = true
    @State private var copied: Setup?

    private enum Setup: String, CaseIterable, Identifiable {
        case claudeCode = "Claude Code"
        case codex = "Codex"
        case json = "Other MCP clients"

        var id: Self { self }
    }

    /// The relay is this very binary run with `--mcp`, so the command is
    /// right for whichever copy of the app is showing it.
    private var executablePath: String {
        Bundle.main.executableURL?.path ?? "/Applications/Lotion.app/Contents/MacOS/Lotion"
    }

    private func command(for setup: Setup) -> String {
        let quoted = "'\(executablePath.replacingOccurrences(of: "'", with: "'\\''"))'"
        switch setup {
        case .claudeCode:
            return "claude mcp add --scope user lotion -- \(quoted) \(AgentSocket.relayArgument)"
        case .codex:
            return "codex mcp add lotion -- \(quoted) \(AgentSocket.relayArgument)"
        case .json:
            let config: JSONValue = [
                "mcpServers": [
                    "lotion": [
                        "command": .string(executablePath),
                        "args": [.string(AgentSocket.relayArgument)],
                    ],
                ],
            ]
            return config.compactString
        }
    }

    var body: some View {
        SettingsPage {
            Section {
                Toggle(isOn: $isEnabled) {
                    SettingsControlLabel(
                        "Allow AI agents",
                        detail: "Let Claude Code, Codex and other MCP clients read, write, organize and publish your notes. Agents connect over a private socket on this Mac."
                    )
                }
                .onChange(of: isEnabled) { _, _ in
                    AgentServer.shared.updateForPreference()
                }
            } header: {
                Text("MCP Server")
            }

            if isEnabled {
                Section {
                    ForEach(Setup.allCases) { setup in
                        LabeledContent {
                            Button {
                                copy(setup)
                            } label: {
                                Label(copied == setup ? "Copied" : "Copy",
                                      systemImage: copied == setup ? "checkmark" : "doc.on.doc")
                                    .contentTransition(.symbolEffect(.replace))
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(setup.rawValue)
                                Text(command(for: setup))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                } header: {
                    Text("Connect an Agent")
                } footer: {
                    Text("Run the command in a terminal once. The agent opens Lotion in the background when it needs it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func copy(_ setup: Setup) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command(for: setup), forType: .string)
        copied = setup
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copied == setup { copied = nil }
        }
    }
}
