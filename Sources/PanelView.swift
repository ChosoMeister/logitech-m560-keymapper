import SwiftUI

/// Liquid Glass surface, with a material fallback for systems that predate it.
private struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 16))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(.white.opacity(0.12))
                )
        }
    }
}

private struct ToggleRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    @Binding var isOn: Bool
    var isEnabled: Bool = true

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12.5, weight: .medium))
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

struct PanelView: View {
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if settings.permissionDenied {
                permissionNotice
            }

            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    ToggleRow(
                        title: "Middle click",
                        subtitle: "Wheel button acts as a real middle button",
                        symbol: "computermouse",
                        isOn: $settings.middleClick,
                        isEnabled: settings.enabled
                    )
                    Divider().opacity(0.5)
                    ToggleRow(
                        title: "Space switching",
                        subtitle: "Side buttons move between desktops",
                        symbol: "rectangle.on.rectangle",
                        isOn: $settings.spaceSwitching,
                        isEnabled: settings.enabled
                    )
                    Divider().opacity(0.5)
                    ToggleRow(
                        title: "Wheel tilt navigation",
                        subtitle: "Tilt left or right for Back and Forward",
                        symbol: "arrow.left.arrow.right",
                        isOn: $settings.tiltNavigation,
                        isEnabled: settings.enabled
                    )
                }
                .padding(14)
            }

            GlassCard {
                ToggleRow(
                    title: "Launch at login",
                    subtitle: "Start automatically when macOS signs in",
                    symbol: "power",
                    isOn: $settings.launchAtLogin
                )
                .padding(14)
            }

            HStack {
                Text(settings.enabled ? "Mapping active" : "Mapping paused")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(settings.enabled ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.15))
                    .frame(width: 30, height: 30)
                Image(systemName: "computermouse.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(settings.enabled ? Color.accentColor : .secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("M560 Mapper").font(.system(size: 13.5, weight: .semibold))
                Text(statusLine)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $settings.enabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }

    private var statusLine: String {
        if settings.permissionDenied { return "Needs Accessibility access" }
        return settings.enabled ? "Logitech M560 · 046d:c52b" : "Buttons pass through untouched"
    }

    private var permissionNotice: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Accessibility access required", systemImage: "lock.shield")
                    .font(.system(size: 12, weight: .medium))
                Text("Add M560 Mapper under Privacy & Security → Accessibility, then toggle the mapper back on.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Button("Open Settings") { settings.requestAccessibilityPermission() }
                    .controlSize(.small)
            }
            .padding(14)
        }
    }
}
