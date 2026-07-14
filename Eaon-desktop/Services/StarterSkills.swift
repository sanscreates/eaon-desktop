import Foundation

/// The Skill Library's default contents — a handful of small, original,
/// general-purpose skills (not copied from Anthropic's own) seeded once on
/// first launch so the library isn't empty before anyone has installed or
/// imported anything. Written in the same SKILL.md shape as everything
/// else, parsed by the same `SkillParser` real installs go through.
enum StarterSkills {
    static let all: [String] = [steelmanThenDecide, explainAtTwoLevels, tightenMyWriting]

    static let steelmanThenDecide = """
    ---
    name: steelman-then-decide
    description: Use when asked to weigh options, pick between approaches, or answer "which should I choose" — before giving a verdict.
    ---

    # Steelman, Then Decide

    The failure mode this guards against: a wishy-washy "it depends, here are some considerations" answer that never actually recommends anything, leaving the reader to do the deciding work they came to you for.

    ## How to answer a "which one" question

    1. **Steelman every real option first.** For each one, state the single strongest, most charitable case for it — not a strawman you'll knock down. If an option has no genuinely strong case, say so plainly instead of inventing one.
    2. **Name the actual tradeoff**, not a vague list of pros and cons. Most real decisions come down to one or two variables that matter (cost vs. speed, flexibility vs. simplicity, now vs. later) — identify which ones are actually in tension here.
    3. **Give a real recommendation.** Pick one, state it in the first sentence of your verdict, and say what would have to be true for a different option to be the better call instead. "X, unless Y matters more to you than Z" beats "it depends."
    4. **Scale the ceremony to the stakes.** A quick, low-stakes choice gets 2-3 sentences, not a structured breakdown. Save the fuller treatment for decisions that are actually hard or consequential.

    ## What NOT to do

    - Don't hedge the recommendation itself away with "but it really depends on your specific situation" as the last word — that undoes the whole point.
    - Don't present three options as equally valid when they clearly aren't; a fair steelman doesn't mean pretending everything is close.
    - Don't ask clarifying questions as a way to avoid committing to an answer when you already have enough information to give a reasonable default recommendation.
    """

    static let explainAtTwoLevels = """
    ---
    name: explain-at-two-levels
    description: Use when explaining a concept, how something works, or why something happened, especially anything technical.
    ---

    # Explain at Two Levels

    The failure mode this guards against: either a shallow one-liner that doesn't actually answer the question, or a dense technical answer that loses the reader before it gets to the point — both are common because "how deep should this go" is genuinely ambiguous without asking.

    ## The shape of a good explanation

    1. **First, the plain-language version** — one to three sentences, no jargon, as if explaining to someone who's smart but has zero background in this specific topic. This alone should be a real, correct, useful answer on its own, not a throat-clearing preamble to the "real" explanation below it.
    2. **Then, the deeper layer** — the mechanism, the "why," the edge cases, the technical vocabulary — for whoever wants to actually understand it, not just get the headline. Signal the shift clearly (a line break, "in more detail:", or similar) so a reader can stop after step 1 without feeling like they missed something.
    3. **Match depth to what's actually being asked.** A quick factual question doesn't need the full two-layer treatment — this is for "how does X work" / "why did this happen" / "explain Y" questions, not "what's the capital of France."

    ## Calibrating the deep layer

    - Prefer the concrete mechanism over abstract description — "it does X, which causes Y" beats "it handles X in a sophisticated way."
    - Use an analogy only when it clarifies the actual mechanism, not just as decoration; a wrong or strained analogy is worse than none.
    - If the topic has a genuinely important caveat or common misconception, that belongs in the deep layer even if it wasn't explicitly asked about.
    """

    static let tightenMyWriting = """
    ---
    name: tighten-my-writing
    description: Use when asked to edit, tighten, shorten, or improve a piece of the user's own writing.
    ---

    # Tighten My Writing

    The failure mode this guards against: an edit that's technically shorter but reads like a different person wrote it, or one that's polished but silently changes what the author actually meant.

    ## What to actually change

    - Cut filler and hedging that doesn't carry meaning: "I think that", "sort of", "in order to", "the fact that", needless "very"/"really", throat-clearing openers ("I wanted to reach out to say that...").
    - Replace a weak verb + noun pair with one strong verb where it reads more naturally that way ("make a decision about" → "decide"), but not so aggressively that it flattens the author's own rhythm.
    - Cut redundant restatement — saying the same thing twice in different words.
    - Fix genuine clarity problems (a sentence that has to be read twice to parse), not just stylistic preference.

    ## What NOT to change

    - The author's actual voice and register — don't turn a casual note formal, or a direct one flowery. Match the tone that's already there.
    - The actual claims or meaning. An edit that makes a sentence crisper but changes what it asserts is a bug, not an improvement — when in doubt, preserve meaning over brevity.
    - Don't rewrite something that's already tight just to have made a visible change.

    ## How to deliver it

    Give the edited version first. Then, briefly (1-3 bullets, not a paragraph per sentence), name the biggest changes made and why — enough that the author can tell what happened and push back on any of it, not a line-by-line diff.
    """
}
