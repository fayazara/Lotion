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
            SettingsSection("MCP server", icon: "terminal") {
                SettingsToggle("Allow AI agents", icon: "sparkles",
                               detail: "Let coding agents read, write, organize and publish your notes.",
                               info: "Claude Code, Codex and other MCP clients connect over a private socket on this Mac.",
                               isOn: $isEnabled)
                    .onChange(of: isEnabled) { _, _ in
                        AgentServer.shared.updateForPreference()
                    }
            }

            if isEnabled {
                SettingsSection("Connect an agent", icon: "link",
                                footer: "Run the command in a terminal once. The agent opens Lotion in the background when it needs it.") {
                    ForEach(Setup.allCases) { setup in
                        SettingsRow(setup.rawValue, icon: setup == .json ? "chevron.left.forwardslash.chevron.right" : "terminal") {
                            Button {
                                copy(setup)
                            } label: {
                                Label(copied == setup ? "Copied" : "Copy",
                                      icon: copied == setup ? "checkmark" : "doc.on.doc")
                                    .contentTransition(.symbolEffect(.replace))
                            }
                        } below: {
                            Text(command(for: setup))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Palette.secondaryLabel)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
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
