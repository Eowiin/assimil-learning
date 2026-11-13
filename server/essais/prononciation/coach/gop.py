"""Goodness of pronunciation (GOP) from CTC posteriors.

Each expected phone is force-aligned (ctc_forced) to the posteriors collapsed onto our
inventory (ctc.collapse); its score is the log posterior of its accepted classes at its
best frame. Thresholds per phoneme come from the distribution on native speech
(scripts/evaluate_assimil.py --scorer gop), so a phone is flagged only when it is less
likely than in (almost) all native productions.
"""

import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from . import phones
from .g2p import Utterance
from .ctc import BLANK, OTHER, PhonePosteriors
from .ctc_forced import forced_align

THRESHOLDS_DIR = Path(__file__).resolve().parent / "thresholds"
# From align/compare.py (the label diff, not reused here).
RHOTICS = {"r", "ɾ"}
RHOTIC_DELEGATED = {"r", "ɾ", "d", "ð"}  # tap vs trill is judged acoustically (rhotic.py)
RAISED = {"e": {"i", "j", "ɪ"}, "o": {"u", "w", "ʊ"}}  # unstressed mid vowels close up
_SPLIT_AFFRICATES = {v: list(k) for k, v in phones.AFFRICATES.items()}
# Thresholds: native quantile 0.002, 0.01 for /θ/ (calibrated in the coach project).


@dataclass
class PhoneScore:
    word: int
    k: int  # index in word
    phoneme: str
    allophone: str
    start: int  # aligned frames (inclusive)
    end: int
    score: float  # log P(accepted classes) at the best frame, normalized without blank
    competitor: str  # most likely non-accepted phone at that frame
    competitor_score: float


def accepted(phoneme: str, allophone: str, stressed: bool) -> set[str]:
    """Symbols accepted for a phone: same tolerances as the label comparison."""
    out = {phoneme, allophone} | phones.TOLERATED.get(phoneme, set())
    if phoneme in RHOTICS:
        out |= RHOTIC_DELEGATED  # tap vs trill is judged acoustically (prosody.rhotic)
    if not stressed:
        out |= RAISED.get(phoneme, set())
    return out


def _units(symbols: set[str], pp: PhonePosteriors, phoneme: str) -> list[list[int]]:
    """Class indices for one phone; an affricate the model only knows in halves
    (t + ʃ for ZIPA, Cnam) becomes two targets."""
    classes = sorted(i for s in symbols if (i := pp.index(s)) is not None)
    if pp.index(phoneme) is None and phoneme in _SPLIT_AFFRICATES:
        return [[pp.index(s)] for s in _SPLIT_AFFRICATES[phoneme] if pp.index(s) is not None]
    return [classes] if classes else []


def score_utterance(utterance: Utterance, pp: PhonePosteriors) -> list[PhoneScore]:
    """Scores for every phone of scored words (unscored words are aligned, not scored)."""
    blank = pp.index(BLANK)
    other = pp.index(OTHER)
    items = []  # (word, k, phoneme, allophone, accepted symbols, first unit, unit count)
    targets: list[list[int]] = []
    for wi, w in enumerate(utterance.words):
        k = 0
        for s in w.syllables:
            stressed = w.tonic and s.stress == 1
            for ph, al in zip(s.phonemes, s.allophones, strict=True):
                symbols = accepted(ph, al, stressed)
                units = _units(symbols, pp, ph)
                items.append((wi, k, ph, al, symbols, len(targets), len(units)))
                targets += units
                k += 1
    spans, _ = forced_align(pp.log_probs, targets, blank)

    lp = pp.log_probs.astype(np.float64)
    non_blank = np.log(np.maximum(1e-12, 1 - np.exp(lp[:, blank])))
    results = []
    for wi, k, ph, al, symbols, first, count in items:
        if not utterance.words[wi].scored:
            continue
        if count == 0:  # phone unknown to the model: cannot be judged
            continue
        unit_scores = []
        for u in range(first, first + count):
            span = spans[u]
            frames = np.arange(span.start, span.end + 1)
            acc = np.logaddexp.reduce(lp[np.ix_(frames, targets[u])], axis=1)
            norm = acc - non_blank[frames]
            best = int(np.argmax(norm))
            unit_scores.append((min(0.0, float(norm[best])), int(frames[best])))
        score, t = min(unit_scores)
        rival = lp[t].copy()
        rejected = [blank, other] + [i for s in symbols if (i := pp.index(s)) is not None]
        rival[rejected] = -np.inf
        c = int(np.argmax(rival))
        spans_ph = spans[first:first + count]
        results.append(PhoneScore(wi, k, ph, al, spans_ph[0].start, spans_ph[-1].end, score,
                                  pp.symbols[c], float(rival[c] - non_blank[t])))
    return results


@dataclass
class Thresholds:
    """Per-phoneme score thresholds calibrated on native speech."""

    model: str
    quantile: float
    by_phoneme: dict[str, float]
    default: float

    def __call__(self, phoneme: str) -> float:
        return self.by_phoneme.get(phoneme, self.default)

    @classmethod
    def load(cls, model: str) -> "Thresholds | None":
        path = THRESHOLDS_DIR / f"gop_{model}.json"
        if not path.is_file():
            return None
        return cls(**json.loads(path.read_text(encoding="utf-8")))

