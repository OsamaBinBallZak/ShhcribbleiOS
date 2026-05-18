import ShhhcribbleShared
import SwiftUI
import UIKit
import os

private let diagLog = Logger(subsystem: "com.shhhcribble.diag", category: "keyboard")

/// Shhhcribble's iOS custom keyboard. Hand-built QWERTY because the
/// KeyboardKit binary framework wouldn't load on device (extension
/// crashed during init — likely LicenseKit + memory limit).
///
/// Layout:
///   - Toolbar row: status label + Voice/Stop button
///   - 3 letter rows: QWERTY layout with shift
///   - Bottom row: numbers toggle, globe (next keyboard), space, return
///   - Number/symbol modes via toggle key
final class KeyboardViewController: UIInputViewController {

    private let toolbarState = KeyboardState()
    private let layoutState = KeyboardLayoutState()
    private var hostingController: UIHostingController<ShhhcribbleKeyboardView>?
    private var pollTimer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        KeyboardBridge.debug("KeyboardViewController.viewDidLoad — build with debug logs is active")

        let root = ShhhcribbleKeyboardView(
            state: toolbarState,
            layoutState: layoutState,
            onKey: { [weak self] key in self?.handleKey(key) },
            onShift: { [weak self] in self?.handleShift() },
            onBackspace: { [weak self] in self?.handleBackspace() },
            onSpace: { [weak self] in self?.textDocumentProxy.insertText(" ") },
            onReturn: { [weak self] in self?.textDocumentProxy.insertText("\n") },
            onNextKeyboard: { [weak self] in self?.advanceToNextInputMode() },
            onVoice: { [weak self] in self?.handleVoiceTap() },
            onStopActive: { [weak self] in self?.handleStopActiveRecording() }
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

    // MARK: - Key handling

    private func handleKey(_ key: String) {
        textDocumentProxy.insertText(key)
        // Auto-disable temporary shift after one keystroke (like the
        // system keyboard does when you tap shift once, not twice).
        if layoutState.shift == .once {
            layoutState.shift = .off
        }
    }

    private func handleShift() {
        switch layoutState.shift {
        case .off: layoutState.shift = .once
        case .once: layoutState.shift = .locked
        case .locked: layoutState.shift = .off
        }
    }

    private func handleBackspace() {
        textDocumentProxy.deleteBackward()
    }

    // MARK: - Voice / dictation

    private func handleVoiceTap() {
        KeyboardBridge.debug("voice tap: warm=\(KeyboardBridge.isEngineWarm) active=\(toolbarState.isRecordingActive)")
        if KeyboardBridge.isEngineWarm {
            if toolbarState.isRecordingActive {
                KeyboardBridge.postDarwin(KeyboardBridge.darwinStop)
                KeyboardBridge.writePTTSignal(.stop)
            } else {
                KeyboardBridge.postDarwin(KeyboardBridge.darwinStart)
                KeyboardBridge.writePTTSignal(.start)
            }
        } else {
            openContainingApp(url: KeyboardBridge.recordURL)
        }
    }

    private func openContainingApp(url: URL) {
        KeyboardBridge.debug("openContainingApp: extensionContext=\(extensionContext == nil ? "nil" : "ok") url=\(url.absoluteString)")
        extensionContext?.open(url) { [weak self] success in
            KeyboardBridge.debug("extensionContext.open returned success=\(success)")
            if !success {
                DispatchQueue.main.async {
                    self?.openViaResponderChain(url: url)
                }
            }
        }
    }

    @MainActor
    private func openViaResponderChain(url: URL) {
        var responder: UIResponder? = self
        let legacy = sel_registerName("openURL:")
        let modern = sel_registerName("open:options:completionHandler:")
        var hops = 0
        while let r = responder {
            hops += 1
            if r.responds(to: modern) {
                KeyboardBridge.debug("responder fallback: \(type(of: r)) accepts open:options:completionHandler: at hop \(hops)")
                // open(_:options:completionHandler:) takes 3 args; use a
                // typed function pointer to call it correctly.
                typealias OpenFn = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                let impl = r.method(for: modern)
                let openFn = unsafeBitCast(impl, to: OpenFn.self)
                openFn(r, modern, url as NSURL, [:] as NSDictionary, nil)
                KeyboardBridge.debug("responder fallback: open:options: called")
                return
            }
            if r.responds(to: legacy) {
                KeyboardBridge.debug("responder fallback: \(type(of: r)) accepts openURL: at hop \(hops)")
                let result = r.perform(legacy, with: url)
                KeyboardBridge.debug("responder fallback: openURL: returned \(String(describing: result))")
                return
            }
            responder = r.next
        }
        KeyboardBridge.debug("responder fallback: no responder accepts open URL (\(hops) hops)")
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
