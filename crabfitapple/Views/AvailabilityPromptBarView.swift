import SwiftUI

struct AvailabilityPromptBarView: View {
    let isInputDisabled: Bool
    let isGenerating: Bool
    let clearTrigger: Int
    let submitAction: (String) -> Void

    @State private var prompt = ""

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !isInputDisabled && !isGenerating && !trimmedPrompt.isEmpty
    }

    var body: some View {
        liquidGlassPromptBar
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .onChange(of: clearTrigger) {
                prompt = ""
            }
    }

    private var liquidGlassPromptBar: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                promptFieldContent
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(minHeight: 48)
                    .frame(maxWidth: .infinity)
                    .glassEffect(.regular.interactive(), in: .capsule)

                sendControl
            }
        }
    }

    private var promptFieldContent: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(
                "10 to 12 noon on weekdays except Friday",
                text: $prompt,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...3)
            .submitLabel(.done)
            .textInputAutocapitalization(.sentences)
            .disabled(isInputDisabled)
            .onSubmit(submitPrompt)
        }
    }

    @ViewBuilder
    private var sendControl: some View {
        if isGenerating {
            ProgressView()
                .frame(width: 48, height: 48)
                .glassEffect(.regular)
                .accessibilityLabel("Updating Availability")
        } else {
            Button(action: submitPrompt) {
                Image(systemName: "arrow.up")
                    .font(.headline.weight(.semibold))
                    .frame(width: 24, height: 34)
            }
            .buttonStyle(.glassProminent)
            .tint(canSubmit ? Color.accentColor : Color.secondary)
            .disabled(!canSubmit)
        }
    }

    private func submitPrompt() {
        guard canSubmit else { return }
        submitAction(trimmedPrompt)
    }
}
