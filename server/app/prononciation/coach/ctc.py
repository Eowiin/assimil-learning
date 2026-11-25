"""CTC decoding helpers (numpy only)."""

from dataclasses import dataclass

import numpy as np

from .acoustic import Posteriors
from .phones import AFFRICATES, WORD_SEPARATORS, normalize_symbol


@dataclass
class Segment:
    symbol: str
    start: int  # first frame
    end: int  # last frame (inclusive)


def greedy_decode(log_probs: np.ndarray, vocab: list[str], blank: int) -> list[Segment]:
    """Best-path decoding: argmax per frame, merge repeats, drop blanks, then map each
    token to inventory symbols (a diphthong token yields two segments with the same span).
    Affricates emitted in two halves (t + ʃ) are merged back."""
    best = log_probs.argmax(axis=1)
    segments: list[Segment] = []
    t = 0
    while t < len(best):
        token = best[t]
        start = t
        while t + 1 < len(best) and best[t + 1] == token:
            t += 1
        if token != blank:
            for s in normalize_symbol(vocab[token]):
                prev = segments[-1] if segments else None
                if prev and (prev.symbol, s) in AFFRICATES and start - prev.end <= 2:
                    segments[-1] = Segment(AFFRICATES[prev.symbol, s], prev.start, t)
                else:
                    segments.append(Segment(s, start, t))
        t += 1
    return segments


BLANK = "<b>"
OTHER = "<other>"  # tokens outside the inventory (tones, clicks, multi-phone tokens)


@dataclass
class PhonePosteriors:
    """Model posteriors summed onto inventory symbols: the model-independent input of
    forced alignment and GOP. Column 0 is the blank, the last column is OTHER."""

    log_probs: np.ndarray  # (frames, len(symbols))
    symbols: list[str]
    frame_seconds: float

    def index(self, symbol: str) -> int | None:
        return self._index.get(symbol)

    def __post_init__(self) -> None:
        self._index = {s: i for i, s in enumerate(self.symbols)}


def collapse(post: Posteriors) -> PhonePosteriors:
    token_symbols = []
    for k, token in enumerate(post.vocab):
        mapped = normalize_symbol(token)
        if k == post.blank or token in WORD_SEPARATORS:
            token_symbols.append(BLANK)  # word separators carry no phone: same as blank
        else:
            token_symbols.append(mapped[0] if len(mapped) == 1 else OTHER)
    inventory = sorted(set(token_symbols) - {BLANK, OTHER})
    symbols = [BLANK, *inventory, OTHER]
    index = {s: i for i, s in enumerate(symbols)}
    column = np.array([index[s] for s in token_symbols])
    probs = np.exp(post.log_probs.astype(np.float64))
    summed = np.zeros((probs.shape[0], len(symbols)))
    np.add.at(summed.T, column, probs.T)
    log_probs = np.log(np.maximum(summed, 1e-30)).astype(np.float32)
    return PhonePosteriors(log_probs, symbols, post.frame_seconds)
