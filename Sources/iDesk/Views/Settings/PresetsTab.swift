import SwiftUI

struct PresetsTab: View {
    @ObservedObject var viewModel: PresetsViewModel
    @ObservedObject var displays: DisplaysViewModel
    @State private var name = ""
    @State private var screens: PresetScreens = .unchanged
    @State private var externalID: CGDirectDisplayID?

    var body: some View {
        Form {
            Section("Ready to Use") {
                ForEach(viewModel.suggestions) { preset in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(preset.name).font(.headline)
                            Text(preset.visibility.title + " · " + preset.screens.title).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Apply") { viewModel.apply(preset) }
                    }
                }
            }
            Section("Save Current Setup") {
                Text("Save the current Look and Desktop Line settings with a screen arrangement.")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("Preset name", text: $name)
                Picker("Screens", selection: $screens) {
                    ForEach(PresetScreens.allCases) { Text($0.title).tag($0) }
                }
                if screens == .externalOnly {
                    Picker("External screen", selection: $externalID) {
                        Text("Choose a screen").tag(nil as CGDirectDisplayID?)
                        ForEach(displays.externals) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                Button("Save Preset") {
                    viewModel.save(name: name, screens: screens, externalID: externalID)
                    if viewModel.errorMessage == nil { name = "" }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          (screens == .externalOnly && externalID == nil))
            }
            if !viewModel.presets.isEmpty {
                Section("Your Presets") {
                    ForEach(viewModel.presets) { preset in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(preset.name)
                                Text(preset.visibility.title + " · " + preset.screens.title)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Apply") { viewModel.apply(preset) }
                            Button(role: .destructive) { viewModel.remove(preset) } label: {
                                Image(systemName: "trash")
                            }.accessibilityLabel("Delete preset")
                        }
                    }
                }
            }
            if let error = viewModel.errorMessage { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .onAppear { displays.refresh() }
    }
}
