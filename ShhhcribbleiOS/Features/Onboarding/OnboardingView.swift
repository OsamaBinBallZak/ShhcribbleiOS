import SwiftUI
import UIKit

struct OnboardingView: View {
    @AppStorage("onboardingComplete") private var onboardingComplete: Bool = false
    @State private var page: Int = 0

    private let accent = Color(red: 0.25, green: 0.55, blue: 1.0)

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(.systemGroupedBackground).ignoresSafeArea()

            TabView(selection: $page) {
                WelcomePage(accent: accent, onNext: { advance() })
                    .tag(0)
                ControlCenterPage(accent: accent, onNext: { advance() })
                    .tag(1)
                TriggersPage(accent: accent, onNext: { advance() })
                    .tag(2)
                KeyboardPage(accent: accent, onFinish: { finish() })
                    .tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button("Skip", action: finish)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
    }

    private func advance() {
        withAnimation(.easeInOut(duration: 0.25)) { page = min(page + 1, 3) }
    }

    private func finish() {
        onboardingComplete = true
    }
}

// MARK: - Pages

private struct WelcomePage: View {
    let accent: Color
    let onNext: () -> Void

    var body: some View {
        OnboardingPageScaffold(
            symbol: "waveform",
            symbolColor: accent,
            title: "Shhhcribble",
            primaryButton: ("Next", onNext),
            primaryTint: accent
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Tap once. Talk. It lands as a note and on your clipboard. That's the whole app.")
                    .font(.title3)
                    .foregroundStyle(.primary)

                Text("Everything runs on your iPhone. No cloud, no accounts, no API keys.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ControlCenterPage: View {
    let accent: Color
    let onNext: () -> Void

    var body: some View {
        OnboardingPageScaffold(
            symbol: "square.on.square",
            symbolColor: accent,
            title: "Add the control",
            primaryButton: ("Next", onNext),
            primaryTint: accent
        ) {
            VStack(alignment: .leading, spacing: 18) {
                Text("The fastest way in is the Control Center button. One swipe, one tap, you're recording.")
                    .font(.body)
                    .foregroundStyle(.primary)

                VStack(alignment: .leading, spacing: 10) {
                    NumberedStep(number: 1, text: "Swipe down from the top-right of the screen to open Control Center.")
                    NumberedStep(number: 2, text: "Tap the + in the top-left, then \"Add a Control\".")
                    NumberedStep(number: 3, text: "Search \"Shhhcribble\" and tap the Record control to add it.")
                }
            }
        }
    }
}

private struct TriggersPage: View {
    let accent: Color
    let onNext: () -> Void

    var body: some View {
        OnboardingPageScaffold(
            symbol: "hand.tap.fill",
            symbolColor: accent,
            title: "Other ways to start",
            primaryButton: ("Next", onNext),
            primaryTint: accent
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Shhhcribble registers a system Shortcut, so anything that runs a Shortcut can start a recording:")
                    .font(.body)
                    .foregroundStyle(.primary)

                VStack(alignment: .leading, spacing: 14) {
                    TriggerRow(
                        symbol: "mic.circle.fill",
                        title: "Siri",
                        detail: "Say \"Start Shhhcribble\" to any Siri surface — phone, AirPods, Watch, HomePod."
                    )
                    TriggerRow(
                        symbol: "button.programmable",
                        title: "Action Button",
                        detail: "iPhone 15 Pro and up. Settings → Action Button → swipe to Shortcut → pick \"Start Shhhcribble\"."
                    )
                    TriggerRow(
                        symbol: "iphone.gen3.radiowaves.left.and.right",
                        title: "Back Tap",
                        detail: "First add \"Start Shhhcribble\" to your library in the Shortcuts app. Then Settings → Accessibility → Touch → Back Tap → pick it under Shortcuts."
                    )
                }
            }
        }
    }
}

private struct KeyboardPage: View {
    let accent: Color
    let onFinish: () -> Void

    var body: some View {
        OnboardingPageScaffold(
            symbol: "keyboard.fill",
            symbolColor: accent,
            title: "Dictate from any app",
            primaryButton: ("Get Started", onFinish),
            primaryTint: accent
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Text("The Shhhcribble keyboard adds a push-to-talk mic next to your text. Hold it, speak, release — the transcript drops straight into the text field.")
                    .font(.body)
                    .foregroundStyle(.primary)

                VStack(alignment: .leading, spacing: 14) {
                    NumberedStep(
                        number: 1,
                        text: "Settings → General → Keyboard → Keyboards → Add New Keyboard → Shhhcribble."
                    )
                    NumberedStep(
                        number: 2,
                        text: "Tap Shhhcribble in the list, then enable Allow Full Access. Required to send the transcript back to your text field."
                    )
                    NumberedStep(
                        number: 3,
                        text: "In any text field, long-press the globe to switch to Shhhcribble. Hold the blue mic to dictate."
                    )
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(accent)
                    Text("iOS shows a small orange dot in the status bar while Shhhcribble keeps the mic ready for instant dictation. You can disable this in Settings → Keyboard, at the cost of slower keyboard recordings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        }
    }
}

// MARK: - Scaffold

private struct OnboardingPageScaffold<Content: View>: View {
    let symbol: String
    let symbolColor: Color
    let title: String
    let primaryButton: (String, () -> Void)
    let primaryTint: Color
    var secondaryButton: (String, () -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 24)

            Image(systemName: symbol)
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(symbolColor)
                .padding(.horizontal, 28)
                .padding(.bottom, 24)

            Text(title)
                .font(.system(size: 32, weight: .bold))
                .padding(.horizontal, 28)
                .padding(.bottom, 20)

            content()
                .padding(.horizontal, 28)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 24)

            VStack(spacing: 12) {
                if let secondary = secondaryButton {
                    Button(secondary.0, action: secondary.1)
                        .font(.body.weight(.medium))
                        .foregroundStyle(primaryTint)
                }

                Button(action: primaryButton.1) {
                    Text(primaryButton.0)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(primaryTint)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 56) // leave space for page indicator dots
        }
    }
}

private struct NumberedStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number).")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            Text(text)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TriggerRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

#Preview {
    OnboardingView()
}
