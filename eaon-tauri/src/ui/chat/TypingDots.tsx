// Waiting-for-first-token indicator, shown until any content or reasoning
// has arrived.

export default function TypingDots() {
  return (
    <div className="typing-dots" aria-label="Waiting for a reply">
      <span />
      <span />
      <span />
    </div>
  );
}
