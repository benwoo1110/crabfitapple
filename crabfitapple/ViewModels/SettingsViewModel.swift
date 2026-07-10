import Foundation
import Observation
import SwiftUI

@Observable
final class SettingsViewModel {
    var name = ""
    var password = ""
    var isShowingError = false
    var errorMessage = ""

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canSave: Bool {
        !trimmedName.isEmpty
    }

    func loadSettings() async {
        do {
            let credentials = try AvailabilityCredentialsStore.load()
            name = credentials.name
            password = credentials.password
        } catch {
            show(error)
        }
    }

    func saveSettings() -> Bool {
        guard canSave else { return false }

        do {
            try AvailabilityCredentialsStore.save(name: trimmedName, password: password)
            return true
        } catch {
            show(error)
            return false
        }
    }

    private func show(_ error: Error) {
        errorMessage = error.localizedDescription
        isShowingError = true
    }
}
