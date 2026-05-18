import ShhhcribbleShared
import SwiftUI

/// Shared state between `KeyboardViewController` and the toolbar.
final class KeyboardState: ObservableObject {
    @Published var engineWarm: Bool = KeyboardBridge.isEngineWarm
    @Published var isTranscribing: Bool = false
    @Published var isRecordingActive: Bool = KeyboardBridge.isRecordingActive

    func refresh() {
        engineWarm = KeyboardBridge.isEngineWarm
        isRecordingActive = KeyboardBridge.isRecordingActive
    }
}

/// Layout state for the QWERTY surface — what mode we're in (letters,
/// numbers, symbols) and shift state.
final class KeyboardLayoutState: ObservableObject {
    enum Mode { case letters, numbers, symbols }
    enum ShiftState { case off, once, locked }

    @Published var mode: Mode = .letters
    @Published var shift: ShiftState = .off
}

// MARK: - Root layout

struct ShhhcribbleKeyboardView: View {
    @ObservedObject var state: KeyboardState
    @ObservedObject var layoutState: KeyboardLayoutState

    let onKey: (String) -> Void
    let onShift: () -> Void
    let onBackspace: () -> Void
    let onSpace: () -> Void
    let onReturn: () -> Void
    let onNextKeyboard: () -> Void
    let onVoice: () -> Void
    let onStopActive: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ShhhcribbleToolbar(
                state: state,
                onVoice: onVoice,
                onStopActive: onStopActive
            )
            .padding(.horizontal, 4)
            .padding(.top, 4)

            VStack(spacing: 8) {
                ForEach(currentRows.indices, id: \.self) { rowIdx in
                    KeyRow(
                        keys: currentRows[rowIdx],
                        isShifted: layoutState.shift != .off,
                        onKey: onKey
                    )
                }
                bottomRow
            }
            .padding(.horizontal, 4)
            .padding(.top, 6)
            .padding(.bottom, 6)
        }
        .frame(height: 260)
        .background(Color(.systemGray5))
    }

    // MARK: Letter rows

    private var currentRows: [[String]] {
        switch layoutState.mode {
        case .letters:
            return KeyboardLayout.letterRows(shifted: layoutState.shift != .off)
        case .numbers:
            return KeyboardLayout.numberRows
        case .symbols:
            return KeyboardLayout.symbolRows
        }
    }

    // MARK: Bottom utility row

    private var bottomRow: some View {
        HStack(spacing: 6) {
            if layoutState.mode == .letters {
                SpecialKey(
                    label: layoutState.shift == .off ? "⇧" : (layoutState.shift == .locked ? "⇧" : "⇧"),
                    width: 40,
                    isActive: layoutState.shift != .off,
                    action: onShift
                )
            } else {
                Color.clear.frame(width: 40)
            }

            modeToggleKey

            SpecialKey(label: "🌐", width: 36, action: onNextKeyboard)

            Button(action: onSpace) {
                Text("space")
                    .font(.system(size: 16, weight: .regular))
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .foregroundStyle(Color.primary)
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 6))
            }

            SpecialKey(label: "⏎", width: 64, action: onReturn)

            SpecialKey(label: "⌫", width: 40, action: onBackspace)
        }
    }

    private var modeToggleKey: some View {
        let (label, nextMode): (String, KeyboardLayoutState.Mode) = {
            switch layoutState.mode {
            case .letters: return ("123", .numbers)
            case .numbers: return ("ABC", .letters)
            case .symbols: return ("123", .numbers)
            }
        }()
        return SpecialKey(label: label, width: 44) {
            layoutState.mode = nextMode
            layoutState.shift = .off
        }
    }
}

// MARK: - Toolbar (status + Voice button)

struct ShhhcribbleToolbar: View {
    @ObservedObject var state: KeyboardState
    let onVoice: () -> Void
    let onStopActive: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            statusLabel
            Spacer()
            voiceButton
        }
        .padding(.horizontal, 8)
        .frame(height: 48)
    }

    private var statusLabel: some View {
        Group {
            if state.isTranscribing {
                Label("Transcribing…", systemImage: "waveform")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.secondary)
            } else if state.isRecordingActive {
                Label("Recording", systemImage: "record.circle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.red)
            } else if state.engineWarm {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.accentColor)
            } else {
                Text("Shhhcribble")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.secondary)
            }
        }
    }

    private var voiceButton: some View {
        ZStack {
            Circle()
                .fill(buttonColor)
                .frame(width: 40, height: 40)
            if state.isTranscribing && !state.isRecordingActive {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(0.7)
            } else {
                Image(systemName: buttonSymbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            KeyboardBridge.debug("voiceButton.onTapGesture fired")
            onTap()
        }
    }

    private func onTap() {
        if state.isRecordingActive { onStopActive() } else { onVoice() }
    }

    private var buttonColor: Color {
        if state.isRecordingActive { return .red }
        if state.engineWarm { return .accentColor }
        return Color(.systemGray2)
    }

    private var buttonSymbol: String {
        if state.isRecordingActive { return "stop.fill" }
        if state.engineWarm { return "mic.fill" }
        return "mic.fill"
    }
}

// MARK: - Key row

private struct KeyRow: View {
    let keys: [String]
    let isShifted: Bool
    let onKey: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(keys, id: \.self) { key in
                Button(action: { onKey(displayKey(key)) }) {
                    Text(displayKey(key))
                        .font(.system(size: 20))
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .foregroundStyle(Color.primary)
                        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private func displayKey(_ key: String) -> String {
        // Letters shift to uppercase; numbers/symbols pass through.
        if key.count == 1, let first = key.first, first.isLetter, isShifted {
            return key.uppercased()
        }
        return key
    }
}

private struct SpecialKey: View {
    let label: String
    let width: CGFloat
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 18, weight: .regular))
                .frame(width: width, height: 42)
                .foregroundStyle(isActive ? Color.white : Color.primary)
                .background(
                    isActive ? Color.accentColor : Color(.systemGray3),
                    in: RoundedRectangle(cornerRadius: 6)
                )
        }
    }
}

// MARK: - Layout tables

enum KeyboardLayout {
    static func letterRows(shifted: Bool) -> [[String]] {
        let lower: [[String]] = [
            ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
            ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
            ["z", "x", "c", "v", "b", "n", "m"],
        ]
        return lower // KeyRow.displayKey upper-cases when shifted
    }

    static let numberRows: [[String]] = [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
        ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""],
        [".", ",", "?", "!", "'"],
    ]

    static let symbolRows: [[String]] = [
        ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
        ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"],
        [".", ",", "?", "!", "'"],
    ]
}
