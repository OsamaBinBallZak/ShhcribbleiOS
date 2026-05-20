# Shhhcribble backlog

Features and refinements we've consciously deferred. Tracked here so they don't get lost in commit history. Newest at the top; cross out when shipped.

---

## Live-preview text stability strategy revisit

**Context.** During recording, `TypingViewModel` (`ShhhcribbleiOS/Features/Recording/RecordingView.swift`) currently uses a four-case hybrid (Tier 6 Step E.2, 2026-05-20): strict prefix → append; normalised prefix → snap in place; small content revision (≤15 char rewind) → honour the rewind; large content revision → reject, with a `rejectionLimit=4` safety valve that force-accepts the next update after 4 consecutive rejections (~2.8 s of staleness max).

We tried pure Option B (never rewind) first and it deadlocked — TDT was producing too many small word revisions that none extended the displayed text, freezing the live preview. The hybrid lets the small ones through fluidly and rejects only the catastrophic flips.

**Things to look into later, in rough priority order:**

1. **Word-level confidence freeze.** Track each word in the displayed text and how many consecutive live transcribes it survived unchanged. Words that have been stable for N=3 iterations get "frozen"; only the unstable tail gets revised. This would let small genuine corrections ("their" → "there") through while preventing wholesale flickers. Adds a tokenisation pass per update — cheap enough.

2. **Threshold rewind hybrid.** Allow a rewind if the resulting displayed text would still be ≥ 75% of the current displayed (i.e. the revision is "small"). Catches word corrections while blocking catastrophic flips. Simpler than (1).

3. **Forced unstick.** If the displayed text hasn't grown for >3 seconds AND the TDT live transcribes have been producing non-prefix output that whole time, accept the next update unconditionally. Prevents the rare "live preview frozen even though recording continues" edge case that (1) and (2) might also hit.

4. **VAD on its own actor.** Currently TranscriptionService is one big actor. Tier 6 Step D moved VAD work to fewer Task spawns but they still reenter the same actor, competing with TDT live transcribes. A dedicated `VADTracker` actor would fully decouple them. Might further smooth out live updates and let us re-enable Option A (legacy rewind for genuine revisions) without flicker.

**When to revisit:** if/when Tiuri starts noticing the live preview being noticeably stale during dictation. Right now we're prioritising stability.

---
