import ShhhcribbleShared
import SwiftUI
import UIKit
import os

private let diagLog = Logger(subsystem: "com.shhhcribble.diag", category: "keyboard")

/// Custom Shhhcribble keyboard. Push-to-talk:
///
/// - Touch-down on the mic: post `kDarwinStartRecording` so the main
///   app (alive in background) begins recording.
/// - Release: post `kDarwinStopRecording`. Main app stops, transcribes,
///   posts `kDarwinTranscriptReady`. We pick that up and inject via
///   `textDocumentProxy.insertText(_:)`.
///
/// If the engine isn't warm (cold start), the SwiftUI view switches to
/// a "Open Shhhcribble" banner whose button calls `extensionContext.open`
/// — the only path Apple allows for keyboard → app foregrounding.
///
/// Memory budget: ~70 MB. Parakeet (~66 MB) stays in the main app; this
/// extension only handles UI + IPC + proxy insertion.
final class KeyboardViewController: UIInputViewController {

    private let state = KeyboardState()
    private var hostingController: UIHostingController<KeyboardRootView>?
    private var pollTimer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()

        let root = KeyboardRootView(
            state: state,
            onPushToTalkBegin: { [weak self] in self?.handlePushToTalkBegin() },
            onPushToTalkEnd: { [weak self] in self?.handlePushToTalkEnd() },
            onColdStart: { [weak self] in self?.handleColdStart() },
            onNextKeyboard: { [weak self] in self?.advanceToNextInputMode() }
        )

        let host = UIHostingController(rootView: root)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: self)

        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        self.hostingController = host
        registerDarwinObservers()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Belt-and-braces: in case the transcript landed while the keyboard
        // was suspended and our Darwin observer wasn't running, consume now.
        consumeAndInsertTranscriptIfReady()
        // Re-poll engine state so the warm/cold UI flips correctly when the
        // keyboard reappears.
        state.refresh()
        startPollingEngineState()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pollTimer?.invalidate()
        pollTimer = nil
    }

    deinit {
        let token = Unmanaged.passUnretained(self).toOpaque()
        KeyboardBridge.removeDarwinObserver(UnsafeRawPointer(token))
        pollTimer?.invalidate()
    }

    // MARK: - Push-to-talk

    private func handlePushToTalkBegin() {
        guard KeyboardBridge.isEngineWarm else {
            diagLog.notice("ptt begin while engine cold — refreshing UI")
            state.refresh()
            return
        }
        // Post Darwin first (fastest path when both processes are alive),
        // then write App Group signal as a polling fallback in case the
        // Darwin observer fires before the recipient registered or got
        // dropped. Main app's start handler is idempotent.
        KeyboardBridge.postDarwin(KeyboardBridge.darwinStart)
        KeyboardBridge.writePTTSignal(.start)
        diagLog.notice("posted darwinStart + wrote PTT start signal")
    }

    private func handlePushToTalkEnd() {
        KeyboardBridge.postDarwin(KeyboardBridge.darwinStop)
        KeyboardBridge.writePTTSignal(.stop)
        diagLog.notice("posted darwinStop + wrote PTT stop signal")
        state.isTranscribing = true
    }

    // MARK: - Cold start

    private func handleColdStart() {
        extensionContext?.open(KeyboardBridge.recordURL) { success in
            if !success {
                diagLog.error("cold-start extensionContext.open refused")
            }
        }
    }

    // MARK: - Darwin observers (no-op fallback)
    //
    // Darwin notifications don't cross the extension/app sandbox boundary
    // on iOS 26 — confirmed by in-process self-test. We poll the App
    // Group instead. The transcript-ready check happens in the regular
    // poll tick (every 1 s in this VC) plus on viewDidAppear/textDidChange.

    private func registerDarwinObservers() {
        // Intentionally empty.
    }

    private func consumeAndInsertTranscriptIfReady() {
        state.isTranscribing = false
        guard let transcript = KeyboardBridge.consumeTranscript() else { return }
        textDocumentProxy.insertText(transcript)
        diagLog.notice("inserted transcript of \(transcript.count, privacy: .public) chars")
    }

    // MARK: - Engine state polling

    private func startPollingEngineState() {
        pollTimer?.invalidate()
        // 1 s tick: refresh engine-warm state AND check for a transcript
        // that landed while the keyboard was suspended/visible. App Group
        // polling replaces the Darwin-notification path.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.state.refresh()
            self.consumeAndInsertTranscriptIfReady()
        }
    }
}
