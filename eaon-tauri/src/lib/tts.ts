// Read-aloud — the cross-platform port of SpeechNarrator.swift, on the web
// SpeechSynthesis API (the OS's own voices on Windows/Linux/macOS; no
// network, no key). One utterance at a time: starting a new one stops
// whatever was playing.

/** Strip the markdown/tool plumbing a voice shouldn't read out loud. */
export function speakableText(raw: string): string {
  return raw
    .replace(/```[\s\S]*?```/g, " (code) ")
    .replace(/`([^`]+)`/g, "$1")
    .replace(/!\[[^\]]*\]\([^)]*\)/g, "")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
    .replace(/^#{1,6}\s+/gm, "")
    .replace(/[*_~]{1,3}([^*_~]+)[*_~]{1,3}/g, "$1")
    .replace(/\s+/g, " ")
    .trim();
}

/** Speak `text`, calling `onEnd` when it finishes or is cut off. Returns
 *  false when this platform's webview has no speech synthesis. */
export function speak(text: string, onEnd: () => void): boolean {
  if (!("speechSynthesis" in window)) return false;
  window.speechSynthesis.cancel();
  const utterance = new SpeechSynthesisUtterance(text);
  utterance.onend = onEnd;
  utterance.onerror = onEnd;
  window.speechSynthesis.speak(utterance);
  return true;
}

export function stopSpeaking(): void {
  if ("speechSynthesis" in window) window.speechSynthesis.cancel();
}
