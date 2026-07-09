import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var password = ""
    @State private var isShowingError = false
    @State private var errorMessage = ""
    @FocusState private var focusedField: Field?

    private enum Field {
        case name
        case password
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedName.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Name") {
                        TextField("Required", text: $name)
                            .textContentType(.name)
                            .multilineTextAlignment(.trailing)
                            .submitLabel(.next)
                            .focused($focusedField, equals: .name)
                            .onSubmit(focusPasswordField)
                    }

                    LabeledContent("Password") {
                        SecureField("Optional", text: $password)
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
                        .disabled(!canSave)
                }
            }
            .alert("Could Not Save Settings", isPresented: $isShowingError) {
            } message: {
                Text(errorMessage)
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
        do {
            let credentials = try AvailabilityCredentialsStore.load()
            name = credentials.name
            password = credentials.password
        } catch {
            show(error)
        }

        await Task.yield()
        if name.isEmpty {
            focusedField = .name
        }
    }

    private func saveButtonTapped() {
        guard canSave else { return }

        do {
            try AvailabilityCredentialsStore.save(name: trimmedName, password: password)
            dismiss()
        } catch {
            show(error)
        }
    }

    private func show(_ error: Error) {
        errorMessage = error.localizedDescription
        isShowingError = true
    }
}

#Preview {
    SettingsView()
}
