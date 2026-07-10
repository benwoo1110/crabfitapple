import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = SettingsViewModel()
    @FocusState private var focusedField: Field?

    private enum Field {
        case name
        case password
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Name") {
                        TextField("Required", text: $viewModel.name)
                            .textContentType(.name)
                            .multilineTextAlignment(.trailing)
                            .submitLabel(.next)
                            .focused($focusedField, equals: .name)
                            .onSubmit(focusPasswordField)
                    }

                    LabeledContent("Password") {
                        SecureField("Optional", text: $viewModel.password)
                            .textContentType(.password)
                            .multilineTextAlignment(.trailing)
                            .submitLabel(.done)
                            .focused($focusedField, equals: .password)
                            .onSubmit(saveButtonTapped)
                    }
                } header: {
                    Text("Profile")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: saveButtonTapped)
                        .disabled(!viewModel.canSave)
                }
            }
            .alert("Could Not Save Settings", isPresented: $viewModel.isShowingError) {
            } message: {
                Text(viewModel.errorMessage)
            }
            .task(loadSettings)
        }
    }

    private func cancel() {
        dismiss()
    }

    private func focusPasswordField() {
        focusedField = .password
    }

    private func loadSettings() async {
        await viewModel.loadSettings()
        await Task.yield()

        if viewModel.name.isEmpty {
            focusedField = .name
        }
    }

    private func saveButtonTapped() {
        if viewModel.saveSettings() {
            dismiss()
        }
    }
}

#Preview {
    SettingsView()
}
