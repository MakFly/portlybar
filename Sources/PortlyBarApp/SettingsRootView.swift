import AppKit
import PortlyBarRuntime
import SwiftUI

struct SettingsRootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var supervisor: Supervisor
    @AppStorage("app.language") private var appLanguage = "en"

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 1020, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, Locale(identifier: appLanguage))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.gradient)
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 0) {
                    Text("PORTLYBAR")
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .tracking(0.5)
                    Text("LOCAL SUPERVISOR")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .tracking(0.7)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 20)

            Text("settings.workspace")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.tertiary)
                .tracking(0.8)
                .padding(.horizontal, 17)
                .padding(.bottom, 7)

            VStack(spacing: 4) {
                ForEach(SettingsTab.allCases) { tab in
                    SettingsSidebarButton(
                        tab: tab,
                        isSelected: model.selectedSettingsTab == tab,
                        badge: badge(for: tab)
                    ) {
                        withAnimation(.easeOut(duration: 0.12)) {
                            model.selectedSettingsTab = tab
                        }
                    }
                }
            }
            .padding(.horizontal, 9)

            Spacer()

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(Color.green.opacity(0.16))
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                    }
                    .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("settings.api.online")
                            .font(.system(size: 10, weight: .semibold))
                        Text(verbatim: "127.0.0.1:\(supervisor.configuration.apiPort)")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text("PORTLYBAR")
                    Spacer()
                    Text(verbatim: "v\(Supervisor.version)")
                }
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .overlay(alignment: .top) { Divider().opacity(0.55) }
        }
        .frame(width: 214)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selectedSettingsTab {
        case .projects: ProjectsSettingsView()
        case .ports: PortsSettingsView()
        case .docker: DockerSettingsView()
        case .logs: LogsSettingsView()
        case .resources: ResourcesSettingsView()
        case .general: GeneralSettingsView()
        }
    }

    private func badge(for tab: SettingsTab) -> Int? {
        switch tab {
        case .projects: return supervisor.projects.isEmpty ? nil : supervisor.projects.count
        case .ports: return supervisor.listeningPorts.count
        case .docker: return supervisor.dockerContainers.count
        case .logs, .resources, .general: return nil
        }
    }
}

private struct SettingsSidebarButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let badge: Int?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                Text(tab.titleKey)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                Spacer()
                if let badge {
                    Text(verbatim: String(badge))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(isSelected ? 0.16 : 0.07), in: Capsule())
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor : (hovering ? Color.primary.opacity(0.075) : Color.clear))
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
