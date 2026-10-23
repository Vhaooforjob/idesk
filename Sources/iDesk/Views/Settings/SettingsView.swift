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
            ScreensTab(viewModel: viewModel.screens, tuning: viewModel.tuning)
                .tabItem { Label("Screens", systemImage: "display.2") }
            PresetsTab(viewModel: viewModel.presets, displays: viewModel.screens)
                .tabItem { Label("Presets", systemImage: "slider.horizontal.3") }
            AutomationTab(viewModel: viewModel)
                .tabItem { Label("Rules", systemImage: "arrow.triangle.branch") }
            WorkspaceToolsTab(model: viewModel, journal: viewModel.journal, updates: viewModel.updates)
                .tabItem { Label("Workspace", systemImage: "wrench.and.screwdriver") }
            GeneralTab(viewModel: viewModel)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .safeAreaInset(edge: .bottom) {
            if let error = viewModel.saveError {
                HStack {
                    Text(String(localized: "Settings could not be saved") + ": " + error).foregroundStyle(.red)
                    Button("Retry", action: viewModel.retrySave)
                }.padding(8)
            }
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
            HStack {
                Button("Refresh Current Previews") { viewModel.refreshPreviews() }
                    .disabled(!viewModel.settings.showsPreviews)
                Button("Clear Preview Cache", role: .destructive) { viewModel.clearPreviews() }
            }
            if let error = viewModel.previewError { Text(error).foregroundStyle(.red) }
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
                HStack {
                    Picker("Color", selection: Binding(
                        get: { viewModel.settings.appearances[space.id]?.color ?? .accent },
                        set: { viewModel.settings.appearances[space.id, default: DesktopAppearance()].color = $0 }
                    )) {
                        ForEach(DesktopColor.allCases) { Text($0.title).tag($0) }
                    }.frame(width: 150)
                    Picker("Icon", selection: Binding(
                        get: { viewModel.settings.appearances[space.id]?.symbol ?? "rectangle.on.rectangle" },
                        set: { viewModel.settings.appearances[space.id, default: DesktopAppearance()].symbol = $0 }
                    )) {
                        ForEach(DesktopAppearance.symbols, id: \.self) { Image(systemName: $0).tag($0) }
                    }.frame(width: 100)
                }
                HStack {
                    ShortcutRecorder(value: Binding(
                        get: { viewModel.settings.desktopHotkeys[space.id] ?? "" },
                        set: { viewModel.settings.desktopHotkeys[space.id] = $0.isEmpty ? nil : $0 }
                    )).frame(width: 145, height: 24).accessibilityLabel("Desktop shortcut")
                    Toggle("Private preview", isOn: Binding(
                        get: { viewModel.settings.privateDesktopIDs.contains(space.id) },
                        set: { if $0 { viewModel.settings.privateDesktopIDs.insert(space.id) } else { viewModel.settings.privateDesktopIDs.remove(space.id) } }
                    )).toggleStyle(.checkbox)
                }
                HStack {
                    TextField("Group", text: Binding(get: { viewModel.settings.workspace.organization[space.id]?.group ?? "" }, set: { viewModel.settings.workspace.organization[space.id, default: DesktopOrganization()].group = $0 }))
                    TextField("Tags", text: Binding(get: { viewModel.settings.workspace.organization[space.id]?.tags ?? "" }, set: { viewModel.settings.workspace.organization[space.id, default: DesktopOrganization()].tags = $0 }))
                    Toggle("Favorite", isOn: Binding(get: { viewModel.settings.workspace.organization[space.id]?.favorite ?? false }, set: { viewModel.settings.workspace.organization[space.id, default: DesktopOrganization()].favorite = $0 })).toggleStyle(.checkbox)
                }
                if let error = viewModel.shortcutErrors[.desktop(space.id)] { Text(error).font(.caption).foregroundStyle(.red) }
                if let date = viewModel.previewDate(for: space) {
                    Text("Captured \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("No captured preview").font(.caption2).foregroundStyle(.secondary)
                }
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
    let tuning: ScreenTuningViewModel?

    var body: some View {
        Form {
            if let tuning { ScreenTuningSections(tuning: tuning) }
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
        .onAppear {
            viewModel.refresh()
            if let tuning { Task { await tuning.reload() } }
        }
    }
}

/// Brightness and warmth for each external screen, and Night Shift.
private struct ScreenTuningSections: View {
    @ObservedObject var tuning: ScreenTuningViewModel

    private static func footer(hardware: Bool) -> LocalizedStringKey {
        if hardware {
            return "Brightness and Color mode change the screen itself. Warmth tints the picture and lasts while iDesk runs."
        }
        return "This screen does not accept brightness commands (some cables and docks do not pass them), so iDesk darkens the picture instead. Keep the screen's own brightness high. Warmth tints the picture and lasts while iDesk runs."
    }

    var body: some View {
        ForEach(tuning.screens) { screen in
            Section {
                LabeledContent("Brightness") {
                    Slider(
                        value: Binding(get: { screen.brightness }, set: { tuning.setBrightness($0, for: screen.id) }),
                        in: screen.brightnessRange
                    ) {
                        Text("Brightness")
                    } minimumValueLabel: {
                        Image(systemName: "sun.min")
                    } maximumValueLabel: {
                        Image(systemName: "sun.max")
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }
                LabeledContent("Warmth") {
                    Slider(value: Binding(get: { screen.warmth }, set: { tuning.setWarmth($0, for: screen.id) }), in: 0...1) {
                        Text("Warmth")
                    } minimumValueLabel: {
                        Image(systemName: "snowflake")
                    } maximumValueLabel: {
                        Image(systemName: "flame")
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }
                if !screen.colorPresets.isEmpty {
                    Picker("Color mode", selection: Binding(
                        get: { screen.colorPreset ?? screen.colorPresets[0].value },
                        set: { tuning.setColorPreset($0, for: screen.id) }
                    )) {
                        ForEach(screen.colorPresets) { Text($0.name).tag($0.value) }
                    }
                }
                if screen.warmth > 0 || (!screen.usesHardware && screen.brightness < 1) {
                    Button("Reset Colors") { tuning.resetColors(for: screen.id) }
                }
            } header: {
                Text(screen.name)
            } footer: {
                Text(Self.footer(hardware: screen.usesHardware))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if tuning.hasNightShift {
            Section {
                Toggle("Night Shift", isOn: Binding(
                    get: { tuning.nightShift?.isOn ?? false },
                    set: { tuning.setNightShift($0) }
                ))
            } footer: {
                Text("Night Shift is one macOS setting for every screen. Some external screens do not show it. Use Warmth above to tint a single screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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

    private func shortcut(_ title: LocalizedStringKey, action: HotkeyService.Action, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                ShortcutRecorder(value: value).frame(width: 170, height: 24)
            }
            if let error = viewModel.shortcutErrors[action] {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(get: { viewModel.launchAtLogin }, set: { viewModel.setLaunchAtLogin($0) })
    }

    var body: some View {
        Form {
            Section("Desktop Line") {
                Picker("Desktop layout", selection: $viewModel.settings.lineLayout) {
                    ForEach(DesktopLineLayout.allCases) { Text($0.title).tag($0) }
                }
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
                shortcut("Show or hide the line", action: .toggleLine, value: $viewModel.settings.toggleLineHotkey)
                shortcut("Rename current desktop", action: .renameCurrent, value: $viewModel.settings.renameHotkey)
                shortcut("Command Palette", action: .searchDesktops, value: $viewModel.settings.searchDesktopsHotkey)
                shortcut("Previous Desktop", action: .previousDesktop, value: $viewModel.settings.previousDesktopHotkey)
                shortcut("Undo Window Move", action: .undoMove, value: $viewModel.settings.undoMoveHotkey)
                shortcut("Open window picker", action: .moveWindow, value: $viewModel.settings.moveWindowHotkey)
                shortcut("Turn every screen back on", action: .restoreDisplays, value: $viewModel.settings.restoreDisplaysHotkey)
                shortcut("Brighten the screen under the pointer", action: .brightnessUp, value: $viewModel.settings.brightnessUpHotkey)
                shortcut("Dim the screen under the pointer", action: .brightnessDown, value: $viewModel.settings.brightnessDownHotkey)
                shortcut("Turn Night Shift on or off", action: .toggleNightShift, value: $viewModel.settings.nightShiftHotkey)
                Text("Click a shortcut and press keys. Esc cancels; Delete clears it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Preview Storage") {
                Toggle("Show app icons and window counts", isOn: $viewModel.settings.workspace.showsWindowBadges)
                Toggle("Save previews on disk", isOn: $viewModel.settings.storesPreviewsOnDisk)
                Text("Turn off to keep previews only in memory and remove saved preview files.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Clear Preview Cache", role: .destructive) { viewModel.clearPreviews() }
                if let error = viewModel.previewError { Text(error).foregroundStyle(.red) }
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
            Section("Backup and Restore") {
                SettingsTransferView(viewModel: viewModel)
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
