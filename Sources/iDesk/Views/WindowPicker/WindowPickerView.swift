import SwiftUI

struct WindowPickerView: View {
    @ObservedObject var viewModel: WindowPickerViewModel
    let submit: () -> Void
    let cancel: () -> Void
    let refresh: () -> Void
    let openAccessibility: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Move a Window").font(.title2.bold())
                    Text("Choose a window, then its destination desktop.")
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
                    .onSubmit { if viewModel.moveRequest != nil { submit() } }
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
                                ? String(localized: "No movable windows on the current desktops. Open a regular application window, then refresh.")
                                : String(localized: "No matching windows."))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            List(selection: $viewModel.selectedWindowID) {
                                ForEach(viewModel.filteredWindows) { window in
                                    HStack(spacing: 10) {
                                        if let icon = window.icon {
                                            Image(nsImage: icon).resizable().frame(width: 32, height: 32)
                                        } else {
                                            Image(systemName: "macwindow").font(.title2).frame(width: 32, height: 32)
                                        }
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(window.title).lineLimit(2)
                                            Text(window.appName).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.vertical, 5)
                                    .tag(window.id)
                                    .help(window.title)
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
            Divider()
            HStack {
                Text("Return to move · Esc to close").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Move and Follow", action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(viewModel.moveRequest == nil)
            }
        }
        .padding(20)
        .frame(width: 720, height: 480)
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
