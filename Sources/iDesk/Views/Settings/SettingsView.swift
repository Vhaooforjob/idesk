import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        TabView {
            DesktopsTab(viewModel: viewModel)
                .tabItem { Label("Desktops", systemImage: "rectangle.on.rectangle") }
            LookTab(viewModel: viewModel)
                .tabItem { Label("Look", systemImage: "sparkles") }
            ScreensTab(viewModel: viewModel.screens)
                .tabItem { Label("Screens", systemImage: "display.2") }
            GeneralTab(viewModel: viewModel)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: 520)
        .onAppear { viewModel.refresh() }
    }
}

// MARK: - Desktops

private struct DesktopsTab: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Name every desktop. Names are kept by iDesk and follow each desktop even when you reorder them in Mission Control.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(viewModel.desktopGroups) { display in
                    Section {
                        ForEach(display.rows) { row in
                            DesktopRowView(row: row, viewModel: viewModel)
                        }
                    } header: {
                        HStack {
                            Text(display.title)
                            Spacer()
                            Button {
                                viewModel.addDesktop(to: display)
                            } label: {
                                Label("Add Desktop", systemImage: "plus")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            Text("Previews are taken while you are on a desktop. Visit each desktop once to see its picture.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DesktopRowView: View {
    let row: SettingsViewModel.DesktopRow
    @ObservedObject var viewModel: SettingsViewModel

    private var space: DesktopSpace { row.space }

    private var name: Binding<String> {
        Binding(
            get: { viewModel.customName(for: space) },
            set: { viewModel.setCustomName($0, for: space) }
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail = row.thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                }
            }
            .frame(width: 80, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(space.defaultName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if space.isCurrent {
                        Text("Current")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.2), in: Capsule())
                    }
                }
                TextField(space.defaultName, text: name)
                    .textFieldStyle(.roundedBorder)
            }

            Button {
                viewModel.go(to: space)
            } label: {
                Label("Go", systemImage: "arrow.right.circle")
            }
            .disabled(space.isCurrent)

            Button(role: .destructive) {
                viewModel.delete(space)
            } label: {
                Image(systemName: "trash")
            }
            .help(Text("Delete Desktop…"))
            .disabled(!viewModel.canDelete(space))
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Look

private struct LookTab: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.27, green: 0.35, blue: 0.62), Color(red: 0.62, green: 0.42, blue: 0.62), Color(red: 0.95, green: 0.62, blue: 0.48)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                DesktopLineView(viewModel: viewModel.preview)
                    .frame(height: LineLayout.panelHeight)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(height: LineLayout.panelHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 8) {
                    Button("Breeze", action: viewModel.blowPreview)
                    Button("Play Switch Effect", action: viewModel.playPreviewEffect)
                }
                .controlSize(.small)
                .padding(10)
            }

            Text("Hanging Style").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(HangStyle.allCases) { style in
                    StyleTile(style: style, isSelected: viewModel.settings.hangStyle == style) {
                        viewModel.settings.hangStyle = style
                    }
                }
            }

            Form {
                Picker("Sway", selection: $viewModel.settings.sway) {
                    ForEach(SwayStyle.allCases) { Text($0.title).tag($0) }
                }
                Picker("Switch effect", selection: $viewModel.settings.switchEffect) {
                    ForEach(SwitchEffect.allCases) { Text($0.title).tag($0) }
                }
                Picker("Particles", selection: $viewModel.settings.particles) {
                    ForEach(ParticleStyle.allCases) { Text($0.title).tag($0) }
                }
                Picker("Name banner after switching", selection: $viewModel.settings.banner) {
                    ForEach(NameBannerStyle.allCases) { Text($0.title).tag($0) }
                }
            }
            .formStyle(.columns)
            Spacer(minLength: 0)
        }
    }
}

private struct StyleTile: View {
    let style: HangStyle
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: style.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 22)
                Text(style.title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Screens

private struct ScreensTab: View {
    @ObservedObject var viewModel: DisplaysViewModel

    var body: some View {
        Form {
            if !viewModel.hasSeveralDisplays {
                Section {
                    Label("Connect a second screen to choose which ones are on.", systemImage: "display")
                        .foregroundStyle(.secondary)
                }
            } else if !viewModel.canTurnOff {
                Section {
                    Text("This version of macOS does not let iDesk turn screens off.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(viewModel.arrangements, id: \.self) { arrangement in
                        ArrangementRow(
                            title: viewModel.title(for: arrangement),
                            symbol: arrangement.symbol,
                            isSelected: arrangement == viewModel.arrangement
                        ) {
                            viewModel.choose(arrangement)
                        }
                    }
                } header: {
                    Text("Which screens are on")
                } footer: {
                    Text("Turning a screen off asks you to keep the change, and undoes it after \(DisplaysViewModel.confirmSeconds) seconds without an answer. Logging out or quitting iDesk turns every screen back on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Screens") {
                    ForEach(viewModel.displays) { display in
                        Toggle(isOn: Binding(get: { display.isEnabled }, set: { viewModel.setEnabled(display, $0) })) {
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(display.name)
                                    Text(display.id == viewModel.primaryID ? String(localized: "Main screen") : String(localized: "External screen"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if !viewModel.canToggle(display) {
                                        Text("The last screen on stays on.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } icon: {
                                Image(systemName: display.isBuiltin ? "laptopcomputer" : "display")
                            }
                        }
                        .disabled(!viewModel.canToggle(display))
                    }
                    if viewModel.hasScreensOff {
                        Button("Turn Every Screen Back On", action: viewModel.turnEverythingOn)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: viewModel.refresh)
    }
}

private struct ArrangementRow: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 24)
                Text(title)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var viewModel: SettingsViewModel

    private var launchAtLogin: Binding<Bool> {
        Binding(get: { viewModel.launchAtLogin }, set: { viewModel.setLaunchAtLogin($0) })
    }

    var body: some View {
        Form {
            Section("Desktop Line") {
                Picker("Show the line", selection: $viewModel.settings.visibility) {
                    ForEach(LineVisibility.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Hang full screen apps too", isOn: $viewModel.settings.showsFullScreenSpaces)
                Toggle("Show desktop previews", isOn: $viewModel.settings.showsPreviews)
                Toggle("Play a sound when switching", isOn: $viewModel.settings.playsSounds)
            }
            Section("Menu Bar") {
                Picker("Menu bar shows", selection: $viewModel.settings.menuBarTitle) {
                    ForEach(MenuBarTitle.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Shortcuts") {
                LabeledContent("Show or hide the line") {
                    TextField("⌃⌥D", text: $viewModel.settings.toggleLineHotkey).frame(width: 120)
                }
                LabeledContent("Rename current desktop") {
                    TextField("⌃⌥R", text: $viewModel.settings.renameHotkey).frame(width: 120)
                }
                LabeledContent("Turn every screen back on") {
                    TextField("⌃⌥⌘D", text: $viewModel.settings.restoreDisplaysHotkey).frame(width: 120)
                }
                Text("Write shortcuts with ⌃ ⌥ ⇧ ⌘ and a key, for example ⌃⌥D.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Permissions") {
                PermissionRow(
                    title: String(localized: "Accessibility"),
                    detail: String(localized: "Needed to switch desktops: iDesk presses the Mission Control shortcuts for you."),
                    isGranted: viewModel.canSwitch,
                    action: viewModel.allowSwitching
                )
                PermissionRow(
                    title: String(localized: "Screen Recording"),
                    detail: String(localized: "Optional. Lets iDesk keep a small picture of each desktop. Without it, the wallpaper is shown."),
                    isGranted: viewModel.canCapture,
                    action: viewModel.allowPreviews
                )
            }
            Section("Startup") {
                Toggle("Open iDesk at login", isOn: launchAtLogin)
                if let error = viewModel.launchError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let isGranted: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isGranted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isGranted ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !isGranted {
                Button("Allow…", action: action)
            }
        }
    }
}
