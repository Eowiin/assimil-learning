"""Acoustic analysis of rhotics: tap /ɾ/ vs trill /r/ (and a French uvular [ʁ]).

Phone recognizers cannot tell a learner's tap from a trill, so each rhotic is measured in
the signal instead, inside the window given by CTC forced alignment:
- an energy envelope (400-4000 Hz band, smoothed over 20 ms to remove the voice pitch
  ripple while keeping the 25-35 Hz trill modulation);
- the constriction: the region around the deepest point where energy stays well below the
  neighboring vowels;
- tongue contacts: dips inside the constriction (a tap has one, a trill two or more);
- a uvular/approximant r shows as a long, shallow plateau without distinct dips; a model
  that knows [ʁ] (ZIPA) confirms it from its posteriors (`uvular_evidence`).

Thresholds are calibrated on native Assimil rhotics (scripts/calibrate_rhotics.py).
Pure numpy, portable to Swift.
"""

import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from .ctc import BLANK, PhonePosteriors
from .gop import score_utterance
from .g2p import Utterance
from .phones import CONSONANTS, GLIDES, VOWELS

SR = 16_000
HOP = 0.001  # envelope hop (s)
SMOOTH = 0.020  # envelope smoothing window (s)
BAND = (400.0, 4000.0)
MIN_CONTACT_PROMINENCE = 5.0  # dB: energy rises at least this much on both sides
MIN_CONTACT_DEPTH = 8.0  # dB below the neighboring vowels
MIN_CONTACT_SPACING = 0.018  # s; trill contacts are ~30-40 ms apart
MAX_CONTACT_GAP = 0.060  # s between chained contacts
ANCHOR_TOLERANCE = 0.060  # s around the CTC spike (spikes may be early or late)
CALIBRATION = Path(__file__).resolve().parent / "thresholds" / "rhotics.json"


def band_energy_db(audio: np.ndarray, sr: int = SR) -> np.ndarray:
    """Band-limited energy envelope in dB, one value per HOP."""
    spectrum = np.fft.rfft(audio)
    freqs = np.fft.rfftfreq(len(audio), 1 / sr)
    spectrum[(freqs < BAND[0]) | (freqs > BAND[1])] = 0
    band = np.fft.irfft(spectrum, n=len(audio))
    hop = int(HOP * sr)
    power = band[: len(band) // hop * hop].reshape(-1, hop).astype(np.float64)
    power = (power ** 2).mean(axis=1)
    win = np.hanning(int(SMOOTH / HOP) + 1)
    smooth = np.convolve(power, win / win.sum(), mode="same")
    return 10 * np.log10(smooth + 1e-12)


def _dips(env: np.ndarray, prominence: float, spacing: int) -> list[int]:
    """Indices of local minima whose prominence (rise to the lower of the two highest
    points on each side, up to a deeper minimum) is at least `prominence` dB."""
    found = []
    for i in range(1, len(env) - 1):
        if not (env[i] <= env[i - 1] and env[i] < env[i + 1]):
            continue
        left = env[: i + 1][::-1]
        right = env[i:]
        rises = []
        for side in (left, right):
            deeper = np.nonzero(side < env[i])[0]
            stop = deeper[0] if len(deeper) else len(side)
            rises.append(side[:stop].max() - env[i])
        if min(rises) >= prominence:
            found.append(i)
    kept: list[int] = []
    for i in sorted(found, key=lambda i: env[i]):  # deepest first
        if all(abs(i - j) >= spacing for j in kept):
            kept.append(i)
    return sorted(kept)


@dataclass
class RhoticFeatures:
    duration: float  # constriction duration (s)
    contacts: int  # tongue contacts (energy dips)
    depth: float  # dB between the neighboring vowels and the deepest point
    center: float  # time of the deepest point (s)


def measure(env: np.ndarray, start: float, end: float, anchor: float,
            ref_side: str = "both") -> RhoticFeatures | None:
    """Features of the rhotic expected near `anchor` (s), in the window `start`..`end` (s)
    around it. `env` is band_energy_db of the whole audio. The reference level is taken on
    the vocalic side(s) of the window: "left", "right" or "both" (the lower one).

    Between trill contacts the energy rises back almost to the vowel level, so contacts
    are found as separate dips, then chained when less than MAX_CONTACT_GAP apart."""
    a, b = max(0, int(start / HOP)), min(len(env), int(end / HOP) + 1)
    if b - a < 20:
        return None
    seg = env[a:b]
    edge = max(5, (b - a) // 4)
    sides = {"left": [seg[:edge].max()], "right": [seg[-edge:].max()]}
    ref = min(sides["left"] + sides["right"]) if ref_side == "both" else sides[ref_side][0]
    center = int(anchor / HOP) - a
    dips = [i for i in _dips(seg, MIN_CONTACT_PROMINENCE, int(MIN_CONTACT_SPACING / HOP))
            if ref - seg[i] >= MIN_CONTACT_DEPTH]
    near = [i for i in dips if abs(i - center) <= int(ANCHOR_TOLERANCE / HOP)]
    if not near:
        lo, hi = max(0, center - 30), min(len(seg), center + 31)
        m = lo + int(np.argmin(seg[lo:hi])) if hi > lo else center
        return RhoticFeatures(0.0, 0, float(ref - seg[min(m, len(seg) - 1)]), (a + m) * HOP)
    m = min(near, key=lambda i: seg[i])  # deepest contact near the anchor
    chain = [m]
    gap = int(MAX_CONTACT_GAP / HOP)
    for i in sorted(d for d in dips if d < m)[::-1]:
        if chain[0] - i <= gap:
            chain.insert(0, i)
    for i in sorted(d for d in dips if d > m):
        if i - chain[-1] <= gap:
            chain.append(i)
    depth = float(ref - seg[chain].min())
    level = ref - depth / 2  # constriction: below half depth, first to last contact
    left, right = chain[0], chain[-1]
    while left > 0 and seg[left - 1] < level:
        left -= 1
    while right < len(seg) - 1 and seg[right + 1] < level:
        right += 1
    return RhoticFeatures((right - left + 1) * HOP, len(chain), depth, (a + m) * HOP)


# ---------------------------------------------------------------- utterance-level analysis

@dataclass
class RhoticResult:
    word: int
    k: int
    phoneme: str  # expected: "ɾ" tap or "r" trill
    context: str  # V_V, C_V, #_V, V_C, V_#: what precedes / follows
    features: RhoticFeatures | None
    uvular: float | None = None  # posterior mass of uvular phones (ʁ χ ʀ), if available
    verdict: str = ""  # tap, trill, long, uvular, weak, uncertain
    ok: bool | None = None  # None: cannot tell
    reliable: bool = False  # context where natives are consistent: the verdict counts


def _kind(sym: str | None) -> str:
    if sym is None:
        return "#"
    if sym in VOWELS or sym in GLIDES:
        return "V"
    return "C" if sym in CONSONANTS else "#"


def rhotic_contexts(utterance: Utterance) -> list[tuple[int, int, str, str, int]]:
    """(word, k, phoneme, context, flat index) for every rhotic of scored words."""
    flat = []  # (word, k, phoneme, pause_before)
    pause = True
    for wi, w in enumerate(utterance.words):
        for k, ph in enumerate(w.phonemes()):
            flat.append((wi, k, ph, pause))
            pause = False
        pause = w.pause_after
    out = []
    for i, (wi, k, ph, pause_before) in enumerate(flat):
        if ph not in ("r", "ɾ") or not utterance.words[wi].scored:
            continue
        prev = None if pause_before or i == 0 else flat[i - 1][2]
        nxt = None if i + 1 >= len(flat) or flat[i + 1][3] else flat[i + 1][2]
        out.append((wi, k, ph, f"{_kind(prev)}_{_kind(nxt)}", i))
    return out


@dataclass
class Calibration:
    """Native ranges (seconds, counts) used to judge a rhotic."""

    tap_max_duration: float  # longer than (almost) any native tap
    trill_min_contacts: int
    long_duration: float  # plateau longer than this without contacts: uvular/approximant
    contexts: tuple[str, ...]  # contexts where the measure is reliable
    uvular_min: float = 1.0  # uvular posterior mass above (almost) all native rhotics

    @classmethod
    def load(cls, path: Path = CALIBRATION) -> "Calibration":
        data = json.loads(path.read_text(encoding="utf-8"))
        return cls(**{k: tuple(v) if isinstance(v, list) else v
                      for k, v in data.items() if k in cls.__dataclass_fields__})


def classify(f: RhoticFeatures | None, cal: Calibration, uvular: float | None = None) -> str:
    if uvular is not None and uvular >= cal.uvular_min:
        return "uvular"  # French r, recognized by a model that knows [ʁ] (ZIPA)
    if f is None or f.contacts == 0:
        return "weak"  # no clear constriction (approximant or very reduced)
    if f.contacts >= cal.trill_min_contacts:
        return "trill"
    if f.duration >= cal.long_duration:
        return "long"  # one long constriction: French/uvular r or a held approximant
    if f.duration <= cal.tap_max_duration:
        return "tap"
    return "uncertain"


def judge(phoneme: str, verdict: str, word_final: bool = False) -> bool | None:
    if verdict == "uncertain" or (phoneme == "r" and verdict == "weak"):
        return None  # a French r is caught by the uvular evidence, not by "weak"
    if phoneme == "ɾ":
        # Natives often weaken taps; a word-final r may be trilled for emphasis (visitar a).
        return verdict in ("tap", "weak") or (word_final and verdict == "trill")
    return verdict == "trill"


REF_SIDE = {"V_V": "both", "C_V": "right", "#_V": "right", "V_C": "left", "V_#": "left"}


def analyze(audio: np.ndarray, utterance: Utterance, spans: dict[tuple[int, int], tuple],
            cal: Calibration | None = None,
            uvular: dict[tuple[int, int], float] | None = None) -> list[RhoticResult]:
    """`spans[(word, k)] = (start_s, end_s)` of every aligned phone (from GOP alignment);
    `uvular[(word, k)]`: optional uvular evidence per rhotic (see `uvular_evidence`)."""
    cal = cal or Calibration.load()
    env = band_energy_db(audio)
    order = sorted(spans)
    results = []
    for wi, k, ph, context, _ in rhotic_contexts(utterance):
        if (wi, k) not in spans:
            continue
        pos = order.index((wi, k))
        s0, s1 = spans[wi, k]
        prev = spans[order[pos - 1]] if pos > 0 else (s0 - 0.08, s0 - 0.04)
        nxt = spans[order[pos + 1]] if pos + 1 < len(order) else (s1 + 0.04, s1 + 0.08)
        # CTC spikes often come early: extend the window past the next phone's spike.
        start = (prev[0] + prev[1]) / 2 - 0.02
        end = (nxt[0] + nxt[1]) / 2 + 0.04
        f = measure(env, start, end, (s0 + s1) / 2, REF_SIDE.get(context, "both"))
        uv = uvular.get((wi, k)) if uvular else None
        verdict = classify(f, cal, uv)
        reliable = context in cal.contexts or verdict == "uvular"
        word_final = k == len(utterance.words[wi].phonemes()) - 1
        ok = judge(ph, verdict, word_final)
        results.append(RhoticResult(wi, k, ph, context, f, uv, verdict, ok, reliable))
    return results


UVULAR = ("ʁ", "χ", "ʀ")


def uvular_evidence(utterance: Utterance, pp: PhonePosteriors) -> dict[tuple[int, int], float]:
    """Max share of uvular phones among non-blank posteriors around each aligned rhotic.
    Empty if the model has no uvular class."""
    idx = [i for s in UVULAR if (i := pp.index(s)) is not None]
    if not idx:
        return {}
    probs = np.exp(pp.log_probs.astype(np.float64))
    non_blank = np.maximum(1e-6, 1 - probs[:, pp.index(BLANK)])
    share = probs[:, idx].sum(axis=1) / non_blank
    out = {}
    for s in score_utterance(utterance, pp):
        if s.phoneme in ("r", "ɾ"):
            out[s.word, s.k] = float(share[max(0, s.start - 2): s.end + 3].max())
    return out
