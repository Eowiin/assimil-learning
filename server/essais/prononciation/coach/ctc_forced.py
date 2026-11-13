"""CTC forced alignment (Viterbi) in numpy.

Each target position accepts a *set* of classes (the expected allophone and its tolerated
variants); its emission score is the log of their summed posterior. Unlike textbook CTC,
two consecutive identical targets may share a spike without a blank in between: natives
merge them (las sillas, que es) and the alignment must not punish that.
"""

from dataclasses import dataclass

import numpy as np

NEG = -1e30


@dataclass
class Span:
    start: int  # first frame emitting the target
    end: int  # last frame (inclusive)


def emissions(log_probs: np.ndarray, targets: list[list[int]]) -> np.ndarray:
    """(frames, len(targets)) log posterior of each target's accepted class set."""
    out = np.empty((log_probs.shape[0], len(targets)), dtype=np.float64)
    for i, classes in enumerate(targets):
        out[:, i] = np.logaddexp.reduce(log_probs[:, classes].astype(np.float64), axis=1)
    return out


def forced_align(log_probs: np.ndarray, targets: list[list[int]], blank: int = 0
                 ) -> tuple[list[Span], float]:
    """Viterbi path over blank/target states. Returns one span per target and the path
    log-likelihood. Needs at least one frame per target; with fewer frames, targets are
    spread over the available frames (degenerate, scored very low anyway)."""
    n_frames, n = log_probs.shape[0], len(targets)
    if n == 0:
        return [], 0.0
    if n_frames < n:
        idx = np.minimum(np.arange(n) * n_frames // n, n_frames - 1)
        return [Span(int(t), int(t)) for t in idx], NEG

    emit = emissions(log_probs, targets)  # (T, n)
    blank_lp = log_probs[:, blank].astype(np.float64)
    n_states = 2 * n + 1  # even = blank, odd = target (s - 1) // 2
    score = np.full(n_states, NEG)
    score[0] = blank_lp[0]
    score[1] = emit[0, 0]
    back = np.zeros((n_frames, n_states), dtype=np.int8)  # 0 stay, 1 from s-1, 2 from s-2
    odd = np.arange(1, n_states, 2)
    even = np.arange(0, n_states, 2)
    for t in range(1, n_frames):
        stay = score
        step = np.concatenate([[NEG], score[:-1]])
        skip = np.full(n_states, NEG)
        skip[odd[1:]] = score[odd[:-1]]  # target i-1 -> target i, no blank in between
        cand = np.stack([stay, step, skip])
        move = cand.argmax(axis=0)
        best = cand[move, np.arange(n_states)]
        new = np.empty(n_states)
        new[even] = best[even] + blank_lp[t]
        new[odd] = best[odd] + emit[t]
        score, back[t] = new, move

    # End in the last target or the trailing blank.
    s = n_states - 1 if score[-1] >= score[-2] else n_states - 2
    total = float(score[s])
    starts = np.full(n, -1)
    ends = np.full(n, -1)
    for t in range(n_frames - 1, -1, -1):
        if s % 2:
            i = (s - 1) // 2
            starts[i] = t
            if ends[i] < 0:
                ends[i] = t
        s -= int(back[t, s])
    return [Span(int(a), int(b)) for a, b in zip(starts, ends, strict=True)], total
