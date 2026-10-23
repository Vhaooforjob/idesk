import SwiftUI

struct WindowPickerView: View {
    @ObservedObject var viewModel: WindowPickerViewModel
    @ObservedObject var settingsStore: SettingsStore
    private var follow: Bool { settingsStore.value.followMovedWindow }
    let submit: () -> Void
    let cancel: () -> Void
    let refresh: () -> Void
    let openAccessibility: () -> Void
    var activate: () -> Void = {}
    var undo: () -> Void = {}
    var canUndo = false
    var arrange: (WindowArrangement) -> Void = { _ in }
    var undoArrangement: () -> Void = {}
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Find and Move Windows").font(.title2.bold())
                    Text("Find windows across desktops. Check several to move them together.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                    .help(Text("Refresh windows"))
                    .disabled(viewModel.isLoading)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search windows or apps", text: $viewModel.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onKeyPress(.upArrow) { viewModel.stepWindow(-1); return .handled }
                    .onKeyPress(.downArrow) { viewModel.stepWindow(1); return .handled }
                    .onKeyPress(.leftArrow, phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        viewModel.stepDestination(-1); return .handled
                    }
                    .onKeyPress(.rightArrow, phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        viewModel.stepDestination(1); return .handled
                    }
                    .onSubmit { if viewModel.batchRequest != nil { submit() } }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            if viewModel.isLoading {
                ProgressView("Finding windows…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "macwindow.badge.plus").font(.largeTitle).foregroundStyle(.secondary)
                    Text(error).multilineTextAlignment(.center)
                    if viewModel.needsPermission {
                        Button("Open Accessibility Settings", action: openAccessibility)
                    }
                    Button("Try Again", action: refresh)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Window").font(.headline)
                        if viewModel.filteredWindows.isEmpty {
                            Text(viewModel.windows.isEmpty
                                ? String(localized: "No regular windows found. Open or unminimize an application window, then refresh.")
                                : String(localized: "No matching windows."))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            List(selection: $viewModel.selectedWindowID) {
                                ForEach(viewModel.filteredWindows) { window in
                                    HStack(spacing: 10) {
                                        Toggle("Select window", isOn: Binding(
                                            get: { viewModel.checkedWindowIDs.contains(window.id) },
                                            set: { if $0 { viewModel.checkedWindowIDs.insert(window.id) } else { viewModel.checkedWindowIDs.remove(window.id) } }
                                        )).labelsHidden().toggleStyle(.checkbox)
                                        if let icon = window.icon {
                                            Image(nsImage: icon).resizable().frame(width: 32, height: 32)
                                        } else {
                                            Image(systemName: "macwindow").font(.title2).frame(width: 32, height: 32)
                                        }
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(window.title).lineLimit(2)
                                            if window.isMinimized { Text("Minimized · Go to Window to restore").font(.caption).foregroundStyle(.secondary) }
                                            Text(window.desktopName.isEmpty ? window.appName : window.appName + " · " + window.desktopName).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.vertical, 5)
                                    .tag(window.id)
                                    .help(window.title)
                                    .onDrag {
                                        if !viewModel.checkedWindowIDs.contains(window.id) { viewModel.checkedWindowIDs = []; viewModel.selectedWindowID = window.id }
                                        return WindowDragSession.shared.begin(windows: viewModel.selectedWindows, destinations: viewModel.destinations)
                                    }
                                }
                            }
                            .listStyle(.inset)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Destination Desktop").font(.headline)
                        if viewModel.destinations.isEmpty {
                            Text("Choose a window with another desktop on the same display.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ScrollView {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 125))], spacing: 10) {
                                    ForEach(viewModel.destinations) { destination in
                                        destinationCard(destination)
                                    }
                                }
                                .padding(3)
                            }
                        }
                    }
                    .frame(width: 290)
                }
                .frame(maxHeight: .infinity)
            }
            HStack {
                Button("Select App Windows") { viewModel.selectApplicationWindows() }.disabled(viewModel.selectedWindow == nil)
                Button("Clear Selection") { viewModel.checkedWindowIDs = [] }.disabled(viewModel.checkedWindowIDs.isEmpty)
                Spacer()
                Button("Undo Move", action: undo).disabled(!canUndo)
                Button("Go to Window", action: activate).disabled(viewModel.selectedWindow == nil || viewModel.isLoading)
            }
            HStack {
                Menu("Arrange Windows") {
                    ForEach(WindowArrangement.allCases) { layout in Button(layout.title) { arrange(layout) } }
                }.disabled(viewModel.selectedWindows.isEmpty || viewModel.selectedWindows.contains(where: \.isMinimized))
                Button("Undo Arrangement", action: undoArrangement).disabled(!viewModel.canUndoArrangement)
                Spacer()
                Text("Drag windows onto desktop cards").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("⌘←/→ destination · Return to move · Esc to close").font(.caption).foregroundStyle(.secondary)
            HStack {
                Toggle("Follow window", isOn: $settingsStore.value.followMovedWindow).toggleStyle(.checkbox)
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(follow ? String(localized: "Move and Follow") : String(localized: "Move"), action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(viewModel.batchRequest == nil)
            }
        }
        .padding(20)
        .frame(width: 780, height: 590)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { searchFocused = true }
        .onChange(of: viewModel.isLoading) { _, loading in
            if loading { searchFocused = true }
        }
        .onExitCommand(perform: cancel)
    }

    private func destinationCard(_ destination: WindowDestination) -> some View {
        let selected = viewModel.selectedDestinationID == destination.id
        return Button {
            viewModel.selectedDestinationID = destination.id
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.10))
                    if let preview = destination.preview {
                        Image(nsImage: preview).resizable().scaledToFill()
                    } else {
                        Image(systemName: "menubar.dock.rectangle").font(.largeTitle).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 68).clipped().clipShape(RoundedRectangle(cornerRadius: 7))
                HStack(alignment: .top) {
                    Text(destination.name).font(.callout.weight(.medium)).lineLimit(2)
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                }
            }
            .padding(9)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(destination.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
