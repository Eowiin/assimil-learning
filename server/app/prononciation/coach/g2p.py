"""Rule-based Castilian Spanish G2P with syllabification and lexical stress.

Two levels are produced for every phone:
- phoneme  (/b d g/, /n/, /s/ ...): used to decide what is an error,
- allophone ([β ð ɣ], [m ŋ], [z] ...): context realization, used for display and as
  "also acceptable" variants.

Castilian choices: distinción (/θ/ for z, c+e/i), /x/ for j and g+e/i, /ʎ/ for ll
(yeísmo realizations [ʝ] are accepted downstream), /r/ vs /ɾ/.

Written to be ported to Swift: plain data, no dependencies, explicit rules.
"""

import itertools
from dataclasses import dataclass, field

from .normalize import normalize

STRONG_VOWELS = set("aeo")
# Grave accents only occur in Catalan names (Benicàssim); treated like acute ones.
ACCENTED = {"á": "a", "é": "e", "í": "i", "ó": "o", "ú": "u", "à": "a", "è": "e", "ò": "o"}
VOWEL_LETTERS = set("aeiouáéíóúüàèòï")
NASALS = {"m", "n", "ɲ"}
VOICED_CONSONANTS = {"b", "d", "g", "m", "n", "ɲ", "l", "ʎ", "r", "ɾ", "ʝ"}
APPROXIMANT = {"b": "β", "d": "ð", "g": "ɣ"}
# Obstruent + liquid onsets. Castilian splits "tl" (at.lán.ti.co) and "dl".
LIQUID_ONSETS = {(c, liq) for c in "pbtkgfd" for liq in ("ɾ", "l")} - {("t", "l"), ("d", "l")}

# Unstressed (clitic) words: never checked for stress. Some are ambiguous with a stressed
# homograph ("como" = I eat, "para" = it stops, "sobre" = envelope); skipping them is safe.
UNSTRESSED_WORDS = frozenset(["el", "la", "los", "las", "lo", "me", "te", "se", "nos", "os", "le", "les", "mi", "mis", "tu", "tus", "su", "sus", "a", "ante", "bajo", "con", "contra", "de", "desde", "en", "entre", "hacia", "hasta", "para", "por", "sin", "so", "sobre", "tras", "y", "e", "ni", "o", "u", "que", "pero", "sino", "mas", "si", "aunque", "porque", "como", "cuando", "donde", "cuanto", "cual", "cuales", "quien", "quienes", "cuyo", "cuya", "cuyos", "cuyas", "don"])

# Orthographic respellings for words the letter rules get wrong (loanwords, x = /x/, ...).
RESPELLINGS = {
    "méxico": "méjico", "mexicano": "mejicano", "mexicana": "mejicana",
    "mexicanos": "mejicanos", "mexicanas": "mejicanas", "texas": "tejas", "oaxaca": "oajaca",
    "sándwich": "sángüich", "sándwiches": "sángüiches", "mail": "meil", "sport": "espor",
    "york": "yorc", "whisky": "güisqui", "subrayar": "subrrayar", "subrayado": "subrrayado",
    "camping": "cámpin", "facebook": "féisbuc", "airbag": "érbag", "windsurf": "güinsurf",
}

# Loanwords and foreign names whose pronunciation varies between speakers: shown, not scored.
UNSCORED_WORDS = frozenset(["airbag", "camping", "chat", "facebook", "mail", "sport", "sándwich", "sándwiches", "windsurf", "york", "whisky", "benicàssim"])

# -mente adverbs carry two stresses; these words merely end in -mente.
NOT_MENTE_ADVERBS = frozenset(["mente", "demente", "clemente", "lamente", "comente", "aumente", "fomente", "cemente", "alimente", "atormente", "experimente", "documente", "implemente", "incremente", "complemente", "cumplimente", "orimente"])


@dataclass
class Syllable:
    phonemes: list[str]
    stress: int = 0  # 0 unstressed, 1 primary, 2 secondary
    allophones: list[str] = field(default_factory=list)


@dataclass
class Word:
    text: str
    syllables: list[Syllable]
    tonic: bool = True  # lexically stressed (False for clitics)
    scored: bool = True
    pause_after: bool = False

    @property
    def stress_index(self) -> int | None:
        return next((i for i, s in enumerate(self.syllables) if s.stress == 1), None)

    def phonemes(self) -> list[str]:
        return [p for s in self.syllables for p in s.phonemes]

    def allophones(self) -> list[str]:
        return [p for s in self.syllables for p in s.allophones]

    def format(self, allophonic: bool = False) -> str:
        marks = {0: "", 1: "ˈ", 2: "ˌ"}
        return ".".join(
            marks[s.stress] + "".join(s.allophones if allophonic else s.phonemes)
            for s in self.syllables
        )


@dataclass
class Utterance:
    text: str
    words: list[Word]

    def format(self, allophonic: bool = False) -> str:
        return " ".join(w.format(allophonic) + (" |" if w.pause_after else "")
                        for w in self.words).removesuffix(" |")


# ---------------------------------------------------------------- graphemes -> segments

@dataclass
class _Seg:
    sym: str
    kind: str  # "V" vowel (nucleus or glide, resolved later), "C" consonant
    accented: bool = False
    weak: bool = False  # i/u (and y used as a vowel)
    force_glide: bool = False  # vowel-like y ("hoy", "muy")


def _segments(word: str) -> list[_Seg]:
    segs: list[_Seg] = []
    n = len(word)
    i = 0

    def at(k: int) -> str:
        return word[k] if 0 <= k < n else ""

    if word.startswith("ps"):
        i = 1  # psicología -> sicología
    elif word.startswith("gn"):
        i = 1
    while i < n:
        c, nxt = word[i], at(i + 1)
        if c in VOWEL_LETTERS:
            base = ACCENTED.get(c, {"ü": "u", "ï": "i"}.get(c, c))
            segs.append(_Seg(base, "V", accented=c in ACCENTED, weak=base in "iu"))
        elif c == "h":
            if i == 0 and nxt == "i" and at(i + 2) in VOWEL_LETTERS:
                segs.append(_Seg("ʝ", "C"))  # hielo, hierba
                i += 1
            # otherwise silent ("hue-" is handled by the u -> w glide rule)
        elif c == "c":
            if nxt == "h":
                segs.append(_Seg("tʃ", "C"))
                i += 1
            elif nxt in ("e", "i", "é", "í"):
                segs.append(_Seg("θ", "C"))
            else:
                segs.append(_Seg("k", "C"))
        elif c == "q":
            segs.append(_Seg("k", "C"))
            if nxt == "u":
                i += 1  # silent u
        elif c == "g":
            if nxt in ("e", "i", "é", "í"):
                segs.append(_Seg("x", "C"))
            else:
                segs.append(_Seg("g", "C"))
                if nxt == "u" and at(i + 2) in ("e", "i", "é", "í"):
                    i += 1  # silent u in gue/gui
        elif c == "l":
            if nxt == "l":
                segs.append(_Seg("ʎ", "C"))
                i += 1
            else:
                segs.append(_Seg("l", "C"))
        elif c == "r":
            if nxt == "r":
                segs.append(_Seg("r", "C"))
                i += 1
            elif i == 0 or at(i - 1) in ("n", "l", "s"):
                segs.append(_Seg("r", "C"))
            else:
                segs.append(_Seg("ɾ", "C"))
        elif c == "y":
            if nxt in VOWEL_LETTERS:
                segs.append(_Seg("ʝ", "C"))
            else:
                segs.append(_Seg("i", "V", weak=True, force_glide=bool(segs) or bool(nxt)))
        elif c == "x":
            segs += [_Seg("s", "C")] if i == 0 else [_Seg("k", "C"), _Seg("s", "C")]
        else:
            sym = {"j": "x", "z": "θ", "v": "b", "ñ": "ɲ", "w": "w", "ç": "s"}.get(c, c)
            if sym in "bdfkmnpstwxθɲ":
                segs.append(_Seg(sym, "C"))
            # anything else (apostrophes, stray symbols) is ignored
        i += 1
    return segs


def _resolve_glides(segs: list[_Seg]) -> list[tuple[str, str, bool]]:
    """Return (symbol, role, accented) with role N (nucleus), G (glide) or C."""
    out = []
    for k, s in enumerate(segs):
        if s.kind == "C":
            out.append((s.sym, "C", False))
            continue
        if not s.weak or s.accented:
            out.append((s.sym, "N", s.accented))
            continue
        prev = segs[k - 1] if k > 0 and segs[k - 1].kind == "V" else None
        nxt = segs[k + 1] if k + 1 < len(segs) and segs[k + 1].kind == "V" else None

        def strong(v: _Seg | None) -> bool:
            return v is not None and (not v.weak or v.accented)

        glide = (
            s.force_glide and (prev is not None or nxt is not None)
            or strong(prev) or strong(nxt)
            or (nxt is not None and nxt.weak and not nxt.force_glide)  # ui, iu: first glides
        )
        if glide:
            out.append(("j" if s.sym == "i" else "w", "G", False))
        else:
            out.append((s.sym, "N", False))
    return out


def _legal_onset(cluster: list[tuple[str, str, bool]]) -> bool:
    syms = [s for s, _, _ in cluster]
    roles = [r for _, r, _ in cluster]
    # strip trailing glides: onset = [C [liquid]] glide*
    while roles and roles[-1] == "G":
        roles.pop()
        syms.pop()
    if not syms:
        return True
    if "G" in roles:
        return False
    if len(syms) == 1:
        return True
    return len(syms) == 2 and (syms[0], syms[1]) in LIQUID_ONSETS


def _syllabify(units: list[tuple[str, str, bool]]) -> list[tuple[list[str], bool]]:
    """Split into syllables; returns (phonemes, has_written_accent) per syllable."""
    nuclei = [k for k, (_, role, _) in enumerate(units) if role == "N"]
    if not nuclei:
        return []
    bounds = [0]
    for a, b in itertools.pairwise(nuclei):
        cluster = units[a + 1:b]
        split = len(cluster)
        for start in range(len(cluster) + 1):  # longest legal suffix = onset
            if _legal_onset(cluster[start:]):
                split = start
                break
        bounds.append(a + 1 + split)
    bounds.append(len(units))
    return [
        ([s for s, _, _ in units[lo:hi]], any(acc for _, _, acc in units[lo:hi]))
        for lo, hi in itertools.pairwise(bounds)
    ]


def _stress_position(word: str, syllables: list[tuple[list[str], bool]]) -> int:
    for k, (_, accented) in enumerate(syllables):
        if accented:
            return k
    if len(syllables) == 1:
        return 0
    letters = [c for c in word if c.isalpha()]
    # vowel-, n- or s-final words are paroxytone ("y"-final words count as consonant-final).
    return len(syllables) - 2 if letters and letters[-1] in "aeiouns" else len(syllables) - 1


def _is_mente_adverb(word: str) -> bool:
    if not word.endswith("mente") or word in NOT_MENTE_ADVERBS:
        return False
    base = word[:-5]
    return len(base) >= 3 and base[-1] in "aelnrzáéíóú"


def transcribe_word(word: str, tonic: bool | None = None) -> Word:
    """Phonemic transcription of one lowercase orthographic word (allophones left empty)."""
    spelled = RESPELLINGS.get(word, word)
    if tonic is None:
        tonic = word not in UNSTRESSED_WORDS
    if _is_mente_adverb(spelled):
        base, mente = transcribe_word(spelled[:-5]), transcribe_word("mente")
        for s in base.syllables:
            s.stress = 2 if s.stress else 0
        return Word(word, base.syllables + mente.syllables, tonic=True)

    raw = _syllabify(_resolve_glides(_segments(spelled)))
    syllables = [Syllable(list(phs)) for phs, _ in raw]
    if syllables and tonic:
        syllables[_stress_position(spelled, raw)].stress = 1
    return Word(word, syllables, tonic=tonic)


# ---------------------------------------------------------------- allophones in context

def apply_allophones(words: list[Word]) -> None:
    """Fill Syllable.allophones from phonemes using cross-word context (pauses block it)."""
    flat: list[tuple[Syllable, int]] = []  # (syllable, index) per phone
    pause_before: list[bool] = []
    after_pause = True
    for w in words:
        for s in w.syllables:
            s.allophones = list(s.phonemes)
            for k in range(len(s.phonemes)):
                flat.append((s, k))
                pause_before.append(after_pause)
                after_pause = False
        if w.pause_after:
            after_pause = True

    def phoneme(i: int) -> str | None:
        return flat[i][0].phonemes[flat[i][1]] if 0 <= i < len(flat) else None

    for i, (syl, k) in enumerate(flat):
        ph = syl.phonemes[k]
        prev = None if pause_before[i] else phoneme(i - 1)
        nxt = None if i + 1 >= len(flat) or pause_before[i + 1] else phoneme(i + 1)
        if ph in APPROXIMANT:
            stop = prev is None or prev in NASALS or (ph == "d" and prev == "l")
            syl.allophones[k] = ph if stop else APPROXIMANT[ph]
        elif ph == "n" and nxt in ("p", "b", "m"):
            syl.allophones[k] = "m"
        elif ph == "n" and nxt in ("k", "g", "x"):
            syl.allophones[k] = "ŋ"
        elif ph == "s" and nxt in VOICED_CONSONANTS:
            syl.allophones[k] = "z"


def transcribe(text: str) -> Utterance:
    words = []
    for token in normalize(text):
        w = transcribe_word(token.text)
        w.scored = token.scored and bool(w.syllables) and token.text not in UNSCORED_WORDS
        w.pause_after = token.pause_after
        words.append(w)
    apply_allophones(words)
    return Utterance(text, words)
