import AVFoundation
import Foundation

/// App-wide "read aloud" for assistant messages, built on the system speech
/// synthesizer (AVSpeechSynthesizer) — no network, no key, uses the voices
/// already installed on the Mac. One utterance plays at a time: starting a
/// new one stops whatever was playing, and the row that started the current
/// one shows a stop state while every other row shows "read aloud."
@MainActor
@Observable
final class SpeechNarrator: NSObject {
    static let shared = SpeechNarrator()

    /// The message currently being spoken, or nil when silent. Views read
    /// this (via `isSpeaking(_:)`) to flip their button between play/stop.
    private(set) var speakingMessageId: UUID?

    private let synthesizer = AVSpeechSynthesizer()
    /// Kept so `didFinish` can confirm it's clearing state for the utterance
    /// that actually completed, not a stale one from a superseded play.
    private var currentUtterance: AVSpeechUtterance?

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    func isSpeaking(_ id: UUID) -> Bool { speakingMessageId == id }

    /// Read this message, or stop if it's already the one playing.
    func toggle(id: UUID, text: String) {
        if speakingMessageId == id {
            stop()
        } else {
            speak(id: id, text: text)
        }
    }

    func speak(id: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Immediate, not queued — a new play should replace the old one now.
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: trimmed)
        currentUtterance = utterance
        speakingMessageId = id
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        currentUtterance = nil
        speakingMessageId = nil
    }
}

extension SpeechNarrator: AVSpeechSynthesizerDelegate {
    // didFinish fires only for an utterance that completed on its own — a
    // cancelled one gets didCancel instead (which we ignore, since both
    // `stop()` and a superseding `speak()` already manage the state
    // themselves). The identity check guards the rare reorder where a stale
    // finish could otherwise clear a freshly-started play.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if self.currentUtterance === utterance {
                self.currentUtterance = nil
                self.speakingMessageId = nil
            }
        }
    }
}
