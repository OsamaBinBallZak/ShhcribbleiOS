import KeyboardKit
import ShhhcribbleShared
import SwiftUI
import UIKit
import os

private let diagLog = Logger(subsystem: "com.shhhcribble.diag", category: "keyboard")

/// Shhhcribble's iOS custom keyboard.
///
/// Phase I (2026-05-18): switched the alphabet/number/symbol surface from
/// a hand-rolled SwiftUI QWERTY to KeyboardKit (free tier), which renders
/// the native iOS look (rounded keys, shift/123/space/return geometry,
/// pop-up preview on long press, light/dark parity). Our own mic toolbar
/// sits ABOVE the KeyboardView via `setupKeyboardView { ... VStack { ... } ... }`.
///
/// Previous "doesn't load on device" experience was during the Personal
/// Team era when App Group was stripped; with paid team + App Group
/// restored, the keyboard extension should load. iOS may require a single
/// device reboot after first install before the extension activates.
final class KeyboardViewController: KeyboardInputViewController {

    private let toolbarState = KeyboardState()
    private var pollTimer: Timer?
    /// Captured from `@Environment(\.openURL)` in the SwiftUI keyboard
    /// root via `OpenURLCapture`. Phase J Tier 4b: this is the
    /// Apple-blessed openURL path from a keyboard extension. See
    /// `openContainingApp(url:)` for the rationale.
    private var capturedOpenURL: OpenURLAction?

    override func viewDidLoad() {
        super.viewDidLoad()
        KeyboardBridge.debug("KeyboardViewController.viewDidLoad — KeyboardKit build")
    }

    /// KeyboardKit calls this from `viewWillAppear`. Override here (NOT
    /// `viewDidLoad`) so our `setupKeyboardView` call wins — the default
    /// implementation would otherwise re-call `setupKeyboardView` with a
    /// plain KeyboardView and clobber our toolbar wrapper.
    override func viewWillSetupKeyboardView() {
        setupKeyboardView { [weak self] controller in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(
                OpenURLCapture(onCapture: { [weak self] action in
                    self?.capturedOpenURL = action
                }) {
                    VStack(spacing: 0) {
                        ShhhcribbleToolbar(
                            state: self.toolbarState,
                            onVoice: { [weak self] in self?.handleVoiceTap() },
                            onStopActive: { [weak self] in self?.handleStopActiveRecording() }
                        )
                        .padding(.horizontal, 4)
                        .padding(.top, 4)

                        KeyboardView(
                            state: controller.state,
                            services: controller.services,
                            buttonContent: { $0.view },
                            buttonView: { $0.view },
                            collapsedView: { $0.view },
                            emojiKeyboard: { $0.view },
                            toolbar: { _ in EmptyView() }   // we render our own
                        )
                    }
                }
            )
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        consumeAndInsertTranscriptIfReady()
        toolbarState.refresh()
        startPolling()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pollTimer?.invalidate()
        pollTimer = nil
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        consumeAndInsertTranscriptIfReady()
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.toolbarState.refresh()
            self.consumeAndInsertTranscriptIfReady()
        }
    }

    // MARK: - Voice / dictation

    private func handleVoiceTap() {
        KeyboardBridge.debug("voice tap: warm=\(KeyboardBridge.isEngineWarm) active=\(toolbarState.isRecordingActive)")
        // Phase J Tier 2 — always write the PTT signal regardless of
        // warm state. With the PushToTalk entitlement, iOS keeps the
        // main app's process alive in background long enough for the
        // polling task to pick up our App Group signal and call
        // PushToTalkService.beginTransmission. The `extensionContext.open`
        // cold-start path stays as a fallback but is empirically
        // denied on iOS 26 regardless of URL scheme.
        if toolbarState.isRecordingActive {
            KeyboardBridge.postDarwin(KeyboardBridge.darwinStop)
            KeyboardBridge.writePTTSignal(.stop)
        } else {
            KeyboardBridge.postDarwin(KeyboardBridge.darwinStart)
            KeyboardBridge.writePTTSignal(.start)
        }
        // If the engine isn't currently warm, also fire the URL as a
        // best-effort cold-start. Harmless if iOS denies it (we've
        // already written the signal). If iOS one day allows it, app
        // foregrounds in parallel with the PTT path.
        if !KeyboardBridge.isEngineWarm {
            // Use appOpenURL (custom scheme `shhhcribble://keyboard`)
            // — mirrors Superwhisper's verified pattern. recordURL
            // (Shortcuts URL) is kept around for the in-app intent
            // path but isn't useful for cold-start from the keyboard.
            openContainingApp(url: KeyboardBridge.appOpenURL)
        }
    }

    private func openContainingApp(url: URL) {
        // Phase J Tier 4b — Apple-blessed pattern: SwiftUI's openURL action
        // captured from `@Environment(\.openURL)` in the keyboard root view
        // via `OpenURLCapture`, stored on this controller, and invoked here.
        //
        // Why not `extensionContext.open(url)`: that API is documented
        // Today-widget-only and iOS refuses it inside the extension runtime
        // for `com.apple.keyboard-service` extensions (synchronous false
        // return in ~200µs, never reaches LaunchServices). See Apple DTS
        // thread 65621 + KeyboardKit 8.8.6+ release notes.
        //
        // Defensive fallback: if the capture hasn't fired yet (shouldn't
        // happen post-viewDidAppear, but theoretically possible during a
        // racy early tap), use the `EnvironmentValues()` direct
        // instantiation pattern. Same end behaviour; less idiomatic.
        if let openURL = capturedOpenURL {
            KeyboardBridge.debug("openContainingApp via captured @Environment(\\.openURL) url=\(url.absoluteString)")
            openURL(url)
        } else {
            KeyboardBridge.debug("openContainingApp fallback via EnvironmentValues().openURL url=\(url.absoluteString)")
            Task { @MainActor in
                EnvironmentValues().openURL(url)
            }
        }
    }

    private func handleStopActiveRecording() {
        KeyboardBridge.postDarwin(KeyboardBridge.darwinStop)
        KeyboardBridge.writePTTSignal(.stop)
        toolbarState.isTranscribing = true
    }

    private func consumeAndInsertTranscriptIfReady() {
        toolbarState.isTranscribing = false
        guard let transcript = KeyboardBridge.consumeTranscript() else { return }
        textDocumentProxy.insertText(transcript)
        diagLog.notice("inserted transcript of \(transcript.count, privacy: .public) chars")
    }
}
