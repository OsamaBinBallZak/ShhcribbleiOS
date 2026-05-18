import AVFoundation
import SwiftUI
import UIKit

struct SettingsView: View {
    @AppStorage("filterFillerWords") private var filterFillerWords = true
    @AppStorage("useANE") private var useANE = true
    @AppStorage("asrMode") private var asrModeRaw = AsrMode.streaming.rawValue
    @AppStorage("warmModeAlways") private var warmModeAlways = false
    @AppStorage("warmModeDurationSec") private var warmModeDurationSec = 60
    // TODO: remove after onboarding QA — see plan silly-karp
    @AppStorage("onboardingComplete") private var onboardingComplete: Bool = false
    @ObservedObject private var status = TranscriptionStatus.shared

    @State private var micPermission: AVAudioApplication.recordPermission = .undetermined

    // Counts for inline detail labels — refreshed on appear.
    @State private var hotwordCount: Int = 0
    @State private var substitutionCount: Int = 0
    @State private var customFillerCount: Int = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Settings")
                        .font(.system(size: 32, weight: .bold))
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)

                Form {
                    transcriptionStyleSection
                    keyboardSection
                    vocabularySection
                    performanceSection
                    permissionsSection
                    aboutSection
                    debugSection // TODO: remove after onboarding QA — see plan silly-karp
                }
                .scrollContentBackground(.hidden)
            }
            .background(Color(.systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                refreshPermissions()
                refreshCounts()
            }
        }
    }

    // MARK: - Sections

    private var transcriptionStyleSection: some View {
        Section {
            Picker("Style", selection: $asrModeRaw) {
                ForEach(AsrMode.allCases, id: \.rawValue) { mode in
                    Text(modeLabel(mode)).tag(mode.rawValue)
                }
            }
            .onChange(of: asrModeRaw) { _, _ in reload() }

            HStack {
                Text("Status")
                Spacer()
                statusLabel
            }
            if case .error(let msg) = status.model {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Transcription style")
        } footer: {
            Text("Streaming shows transcribed text live with the lowest latency, but without punctuation. Parakeet TDT v3 produces punctuated, capitalised text and is more CPU-intensive. Both run fully on-device.")
        }
    }

    private var vocabularySection: some View {
        Section {
            NavigationLink {
                CustomWordsView()
                    .onDisappear { refreshCounts() }
            } label: {
                detailRow(
                    title: "Custom Words",
                    detail: hotwordCount == 0 ? "None" : "\(hotwordCount)"
                )
            }

            NavigationLink {
                SubstitutionsView()
                    .onDisappear { refreshCounts() }
            } label: {
                detailRow(
                    title: "Substitutions",
                    detail: substitutionCount == 0 ? "None" : "\(substitutionCount)"
                )
            }

            NavigationLink {
                FillerWordsView()
                    .onDisappear { refreshCounts() }
            } label: {
                detailRow(
                    title: "Filler Words",
                    detail: filterFillerWords
                        ? (customFillerCount == 0 ? "On" : "On · +\(customFillerCount)")
                        : "Off"
                )
            }
        } header: {
            Text("Vocabulary")
        } footer: {
            Text("Auto-correct casing for proper nouns, replace recurring phrases, and remove filler words from your transcripts.")
        }
    }

    private func detailRow(title: String, detail: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(detail)
                .foregroundStyle(.secondary)
        }
    }

    private var performanceSection: some View {
        Section {
            Toggle("Use Neural Engine", isOn: $useANE)
                .onChange(of: useANE) { _, _ in reload() }
        } header: {
            Text("Performance")
        } footer: {
            Text("Runs the transcription model on Apple's Neural Engine for faster performance and lower battery use. Disable only if you experience issues.")
        }
    }

    private var keyboardSection: some View {
        Section {
            Picker("Keep keyboard ready for", selection: warmModeDurationBinding) {
                Text("30 seconds").tag(30)
                Text("1 minute").tag(60)
                Text("5 minutes").tag(300)
                Text("Always (mic indicator stays on)").tag(-1)
            }
            .onChange(of: warmModeAlways) { _, _ in applyWarmModeSetting() }
            .onChange(of: warmModeDurationSec) { _, _ in applyWarmModeSetting() }
        } header: {
            Text("Keyboard")
        } footer: {
            Text("After a recording, the Shhhcribble keyboard stays ready for push-to-talk for this long. While ready, iOS shows a small orange dot in the status bar (Apple's privacy indicator). The dot disappears once the timer runs out, and the next dictation starts a new session (one quick app open).")
        }
    }

    /// Bind the picker to a single `Int` while the underlying state is
    /// split across `warmModeAlways` (Bool) + `warmModeDurationSec` (Int).
    /// Tag `-1` represents the "Always" case.
    private var warmModeDurationBinding: Binding<Int> {
        Binding(
            get: { warmModeAlways ? -1 : warmModeDurationSec },
            set: { newValue in
                if newValue == -1 {
                    warmModeAlways = true
                } else {
                    warmModeAlways = false
                    warmModeDurationSec = newValue
                }
            }
        )
    }

    /// Apply the new setting immediately so the user doesn't need to
    /// re-launch the app for the change to take effect.
    private func applyWarmModeSetting() {
        if warmModeAlways {
            AudioSessionManager.shared.enterWarmMode()
            AudioSessionManager.shared.cancelIdleExpiry()
        } else {
            // If warm mode is currently active because of a session, just
            // re-schedule the expiry with the new duration. If it's not
            // active, do nothing — next keyboard tap will start a session.
            if AudioSessionManager.shared.warmModeActive {
                AudioSessionManager.shared.scheduleIdleExpiry()
            }
        }
    }

    private var permissionsSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Microphone")
                        .font(.body)
                    Text("Required to record your voice")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                permissionLabel(for: micPermission)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if micPermission == .denied,
                   let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        } header: {
            Text("Permissions")
        }
    }

    private var aboutSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Shhhcribble")
                        .font(.headline)
                    Spacer()
                    Text("v\(appVersion)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Divider()

                HStack(alignment: .top) {
                    Text("this app was crafted by a human named Hendri with chief vibes officer Tiuri whispering ideas in his ear. both humans. probably.")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("(◡‿◡)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("About")
        }
    }

    // TODO: remove after onboarding QA — see plan silly-karp
    private var debugSection: some View {
        Section {
            Button {
                onboardingComplete = false
            } label: {
                HStack {
                    Text("Replay onboarding")
                    Spacer()
                    Image(systemName: "arrow.counterclockwise")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Debug")
        } footer: {
            Text("Temporary — re-shows the onboarding flow on next return to this view's parent. Remove before TestFlight.")
        }
    }

    // MARK: - Helpers

    private func reload() {
        Task { await TranscriptionService.shared.reloadModel() }
    }

    private func refreshPermissions() {
        micPermission = AVAudioApplication.shared.recordPermission
    }

    private func refreshCounts() {
        hotwordCount = (UserDefaults.standard.array(forKey: "customHotwords") as? [String])?.count ?? 0
        customFillerCount = (UserDefaults.standard.array(forKey: "customFillerWords") as? [String])?.count ?? 0
        if let data = UserDefaults.standard.data(forKey: "substitutionRules"),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            substitutionCount = dict.count
        } else {
            substitutionCount = 0
        }
    }

    private func modeLabel(_ mode: AsrMode) -> String {
        switch mode {
        case .streaming: return "Streaming (live, no punctuation)"
        case .tdt:       return "Parakeet TDT v3 (punctuated)"
        }
    }

    @ViewBuilder
    private func permissionLabel(for permission: AVAudioApplication.recordPermission) -> some View {
        switch permission {
        case .granted:
            Label("Granted", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.green)
                .font(.subheadline)
        case .denied:
            Label("Denied", systemImage: "xmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.red)
                .font(.subheadline)
        case .undetermined:
            Text("Not asked")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        @unknown default:
            Text("Unknown")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var statusLabel: some View {
        switch status.model {
        case .notLoaded:
            Text("Not loaded").foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("Loading…").foregroundStyle(.secondary)
            }
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .error:
            Label("Error", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        return short
    }
}
