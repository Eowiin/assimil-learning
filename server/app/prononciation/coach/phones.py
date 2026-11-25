"""Phone inventory: articulatory features, tolerated variants, French labels, and
normalization of recognizer output symbols.

Pure data + small functions, meant to be ported as-is (Swift).
"""

import unicodedata

# Consonants: (place, manner, voiced). Places are ordered front -> back so that their
# distance is meaningful.
PLACES = ["bilabial", "labiodental", "dental", "alveolar", "postalveolar", "palatal",
          "velar", "uvular", "glottal"]
CONSONANTS: dict[str, tuple[str, str, bool]] = {
    "p": ("bilabial", "stop", False), "b": ("bilabial", "stop", True),
    "β": ("bilabial", "approximant", True), "m": ("bilabial", "nasal", True),
    "f": ("labiodental", "fricative", False), "v": ("labiodental", "fricative", True),
    "ʋ": ("labiodental", "approximant", True), "ɱ": ("labiodental", "nasal", True),
    "θ": ("dental", "fricative", False), "ð": ("dental", "fricative", True),
    "t": ("dental", "stop", False), "d": ("dental", "stop", True),
    "s": ("alveolar", "fricative", False), "z": ("alveolar", "fricative", True),
    "n": ("alveolar", "nasal", True), "l": ("alveolar", "lateral", True),
    "ɾ": ("alveolar", "tap", True), "r": ("alveolar", "trill", True),
    "ɹ": ("alveolar", "approximant", True), "ts": ("alveolar", "affricate", False),
    "tʃ": ("postalveolar", "affricate", False), "dʒ": ("postalveolar", "affricate", True),
    "ʃ": ("postalveolar", "fricative", False), "ʒ": ("postalveolar", "fricative", True),
    "ʝ": ("palatal", "fricative", True), "ɲ": ("palatal", "nasal", True),
    "ʎ": ("palatal", "lateral", True), "ç": ("palatal", "fricative", False),
    "k": ("velar", "stop", False), "g": ("velar", "stop", True),
    "x": ("velar", "fricative", False), "ɣ": ("velar", "fricative", True),
    "ŋ": ("velar", "nasal", True),
    "χ": ("uvular", "fricative", False), "ʁ": ("uvular", "fricative", True),
    "ʀ": ("uvular", "trill", True), "h": ("glottal", "fricative", False),
    "ʔ": ("glottal", "stop", False),
}
GLIDES = {"j": "i", "w": "u"}  # glide -> matching vowel
# Vowels: (height 1=close..4=open, backness 0=front..2=back, rounded, nasal)
VOWELS: dict[str, tuple[int, int, bool, bool]] = {
    "i": (1, 0, False, False), "y": (1, 0, True, False), "ɪ": (1.5, 0, False, False),
    "u": (1, 2, True, False), "ʊ": (1.5, 2, True, False), "ɨ": (1, 1, False, False),
    "e": (2, 0, False, False), "ø": (2, 0, True, False), "ɛ": (3, 0, False, False),
    "œ": (3, 0, True, False), "ə": (2.5, 1, False, False),
    "o": (2, 2, True, False), "ɔ": (3, 2, True, False),
    "a": (4, 1, False, False), "æ": (3.5, 0, False, False), "ɐ": (3.5, 1, False, False),
    "ɑ": (4, 2, False, False), "ʌ": (3, 2, False, False),
    "ɑ̃": (4, 2, False, True), "ɔ̃": (3, 2, True, True), "ɛ̃": (3, 0, False, True),
    "œ̃": (3, 0, True, True),
}

SPANISH_PHONEMES = ["a", "e", "i", "o", "u", "j", "w", "p", "b", "t", "d", "k", "g", "f",
                    "θ", "s", "x", "ʝ", "tʃ", "m", "n", "ɲ", "l", "ʎ", "ɾ", "r"]

# Variants accepted without comment for each expected phoneme: allophones and
# realizations that the recognizer cannot reliably tell apart (tuned on native Assimil
# audio in phase 3; context-dependent variants are in align.compare).
# θ -> f/ts, tʃ -> ts: recognizer confusions on native speech, not French-speaker errors
# (the typical one is θ -> s, which stays an error).
TOLERATED: dict[str, set[str]] = {
    "b": {"β", "v", "ʋ"}, "d": {"ð"}, "g": {"ɣ"},
    "n": {"m", "ŋ", "ɱ", "ɲ"}, "s": {"z"}, "θ": {"ð", "f", "ts"}, "tʃ": {"ts"},
    "ʝ": {"j", "ʎ", "dʒ", "i"}, "ʎ": {"ʝ", "j", "dʒ"},  # yeísmo: ll = y, often [ɟʝ] ~ [dʒ]
    "j": {"i", "ʝ", "ɪ"}, "w": {"u", "ʊ"}, "i": {"j", "ɪ"}, "u": {"w", "ʊ"},
    "e": {"ɛ"}, "o": {"ɔ"}, "a": {"ɐ", "ɑ"}, "x": {"χ"},
}

FRENCH_LABELS: dict[str, str] = {
    "r": "r roulé", "ɾ": "r battu", "ʁ": "r français (de gorge)",
    "ʀ": "r grasseyé", "ɹ": "r anglais", "θ": "θ (z/ce/ci, comme « think »)",
    "x": "jota (j, ge/gi)", "h": "h expiré", "ʝ": "y espagnol", "ʎ": "ll",
    "tʃ": "ch (« tch »)", "ʃ": "ch français", "ʒ": "j français", "dʒ": "dj",
    "ɲ": "ñ (« gn »)", "β": "b/v doux", "ð": "d doux", "ɣ": "g doux",
    "b": "b", "v": "v français", "d": "d", "g": "g", "s": "s", "z": "z", "ə": "e muet",
    "u": "u (« ou »)", "y": "u français", "j": "i semi-voyelle", "w": "u semi-voyelle",
    "ɑ̃": "voyelle nasale « an »", "ɔ̃": "voyelle nasale « on »",
    "ɛ̃": "voyelle nasale « in »", "œ̃": "voyelle nasale « un »",
    "e": "e (« é »)", "ɛ": "è", "o": "o", "ɔ": "o ouvert",
}

# Multi-symbol recognizer tokens that stand for a sequence of our phones.
_SPLIT = {"aɪ": ["a", "j"], "eɪ": ["e", "j"], "ɔɪ": ["o", "j"], "oɪ": ["o", "j"],
          "aʊ": ["a", "w"], "oʊ": ["o", "w"], "əʊ": ["ə", "w"], "ja": ["j", "a"],
          "ju": ["j", "u"], "əl": ["ə", "l"], "iə": ["i", "ə"], "ai": ["a", "j"],
          "ei": ["e", "j"], "au": ["a", "w"], "ui": ["w", "i"], "ie": ["j", "e"],
          "ua": ["w", "a"], "uo": ["w", "o"], "eə": ["e", "ə"], "ʊə": ["u", "ə"]}
_RENAME = {"ɡ": "g", "e̞": "e", "o̞": "o", "ɫ": "l", "r̝": "r", "ɐ̃": "ɑ̃", "ã": "ɑ̃",
           "õ": "ɔ̃", "ẽ": "ɛ̃", "ɚ": "ə", "ᵻ": "ɪ", "ɜ": "ə", "ɒ": "ɔ", "ɟ": "ʝ"}
# Blank, special and word-boundary tokens of the supported recognizers.
_SPECIAL = {"<pad>", "<s>", "</s>", "<unk>", "[PAD]", "[UNK]", "|", "▁", "<blk>", "<sos/eos>"}
WORD_SEPARATORS = {"|", "▁"}
# Recognizers with single-character vocabularies (ZIPA) emit affricates in two halves.
AFFRICATES = {("t", "ʃ"): "tʃ", ("d", "ʒ"): "dʒ"}


def known(sym: str) -> bool:
    return sym in CONSONANTS or sym in VOWELS or sym in GLIDES


def normalize_symbol(token: str) -> list[str]:
    """Map one recognizer token (espeak-style IPA) to zero or more inventory symbols.

    Strips length marks, tone digits and secondary articulations; keeps foreign phones
    (ʁ, ʃ, ʒ, nasal vowels...) since they reveal typical learner errors.
    """
    if token in _SPECIAL:
        return []
    tok = unicodedata.normalize("NFC", token)
    tok = "".join(c for c in tok if c not in "ːˑ:ʲˤʰ^[.\"" and not c.isdigit())
    tok = _RENAME.get(tok, tok)
    if not tok:
        return []
    if known(tok):
        return [tok]
    if tok in _SPLIT:
        return list(_SPLIT[tok])
    # Fall back to greedy decomposition into known symbols (longest first).
    out, i = [], 0
    while i < len(tok):
        for size in (2, 1):
            piece = _RENAME.get(tok[i:i + size], tok[i:i + size])
            if known(piece):
                out.append(piece)
                i += size
                break
        else:
            i += 1  # unknown diacritic or symbol: drop
    return out


def substitution_cost(expected: str, heard: str) -> float:
    """0 for identical or tolerated, otherwise 0.25..1 from articulatory distance.

    Vowel <-> consonant costs more than a deletion + insertion pair (2.0), so such
    mismatches are reported as an omission plus an extra sound.
    """
    if expected == heard or heard in TOLERATED.get(expected, ()):
        return 0.0
    e = GLIDES.get(expected, expected)
    h = GLIDES.get(heard, heard)
    if e in VOWELS and h in VOWELS:
        eh, eb, er, en = VOWELS[e]
        hh, hb, hr, hn = VOWELS[h]
        d = abs(eh - hh) / 3 + abs(eb - hb) / 2 + 0.3 * (er != hr) + 0.4 * (en != hn)
        return max(0.25, min(1.0, 0.8 * d))
    if e in CONSONANTS and h in CONSONANTS:
        ep, em, ev = CONSONANTS[e]
        hp, hm, hv = CONSONANTS[h]
        dp = abs(PLACES.index(ep) - PLACES.index(hp)) / 3
        d = 0.4 * min(1.0, dp) + 0.4 * (em != hm) + 0.2 * (ev != hv)
        return max(0.25, d)
    return 2.5
