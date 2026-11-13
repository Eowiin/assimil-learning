"""Text normalization: raw sentence -> spoken lowercase words with pause marks.

Handles the cases found in Assimil: numbers with their reading in parentheses
("1519 (mil quinientos diecinueve)"), bare numbers, ordinals ("1.ª", "1.a", "2°"),
percent, spelled letters ("2° C"), acronyms ("DNI"), codes ("XH553WB"), e-mails and URLs.
Words whose actual pronunciation is uncertain (spelled codes, acronyms, e-mails, URLs,
isolated letters) are kept but marked `scored=False` so they never produce errors.
"""

import re
import unicodedata
from dataclasses import dataclass

from .numbers import cardinal, ordinal


@dataclass
class Token:
    text: str  # one lowercase orthographic word
    scored: bool = True
    pause_after: bool = False


_NUM = r"\d{1,3}(?:[  .]\d{3})+(?!\d)|\d+"
_LETTER_NAMES = {
    "B": "be", "C": "ce", "D": "de", "F": "efe", "G": "ge", "H": "hache", "J": "jota",
    "K": "ka", "L": "ele", "M": "eme", "N": "ene", "P": "pe", "Q": "cu", "R": "erre",
    "S": "ese", "T": "te", "V": "uve", "W": "uve doble", "X": "equis", "Z": "zeta",
    "A": "a", "E": "e", "I": "i", "O": "o", "U": "u", "Y": "i griega", "Ñ": "eñe",
}
_SYMBOL_NAMES = {"_": "guion bajo", "@": "arroba", ".": "punto", "-": "guion", "/": "barra"}

# Order matters: the first alternative that matches at a position wins.
_SPECIAL = re.compile(
    rf"(?P<read>(?:{_NUM})\s*%?)\s*\((?P<reading>[^()\d]+)\)"
    r"|(?P<email>[\w.+-]+@[\w-]+(?:\.[\w-]+)+|\b[\w-]+\.(?:com|es|org|net)\b)(?:\s*\([^()]*\))?"
    r"|(?P<code>\b(?=[A-Z0-9]*\d)(?=[A-Z0-9]*[A-Z])[A-Z0-9]{3,}\b)"
    r"|(?P<acronym>\b[A-ZÑ]{2,}\b)"
    rf"|(?P<ord>\b\d+)\s?(?:\.\s?(?P<ordsuf>ª|º|a(?=\b|parte))|(?P<ordsym>[ªº°]))"
    r"|(?<!\w)(?P<letter>[BCDFGHJKLMNPQRSTVWXZ])(?!\w)"
    r"|(?P<percent>%)"
    rf"|(?P<num>{_NUM})"
)
_WORD = re.compile(r"[a-záéíóúüñàèòïç]+")
_PAUSE = re.compile(r"[,.;:!?¡¿()\"“”«»–—]")


def _spell(code: str) -> str:
    return " ".join(cardinal(int(c)) if c.isdigit() else _LETTER_NAMES.get(c.upper(), "")
                    for c in code)


def _expand_email(text: str) -> str:
    out = []
    for part in re.split(r"([_@.\-/])", text):
        if part in _SYMBOL_NAMES:
            out.append(_SYMBOL_NAMES[part])
        else:
            out += [cardinal(int(p)) if p.isdigit() else p for p in re.split(r"(\d+)", part) if p]
    return " ".join(out)


def _number(text: str) -> int:
    return int(re.sub(r"\D", "", text))


def _pieces(text: str) -> list[tuple[str, bool]]:
    """Split text into (spoken text, scored) pieces with special forms expanded."""
    pieces, pos = [], 0
    for m in _SPECIAL.finditer(text):
        pieces.append((text[pos:m.start()], True))
        if m["reading"]:
            pieces.append((f" {m['reading']} ", True))
        elif m["email"]:
            pieces.append((f" {_expand_email(m['email'])} ", False))
        elif m["code"] or m["acronym"]:
            pieces.append((f" {_spell(m['code'] or m['acronym'])} ", False))
        elif m["ord"]:
            feminine = (m["ordsuf"] or m["ordsym"]) in ("ª", "a")
            pieces.append((f" {ordinal(int(m['ord']), feminine)} ", True))
        elif m["letter"]:
            pieces.append((f" {_LETTER_NAMES[m['letter']]} ", False))
        elif m["percent"]:
            pieces.append((" por ciento ", True))
        else:
            pieces.append((f" {cardinal(_number(m['num']))} ", True))
        pos = m.end()
    pieces.append((text[pos:], True))
    return pieces


def normalize(text: str) -> list[Token]:
    text = unicodedata.normalize("NFC", text).replace("…", "...")
    tokens: list[Token] = []
    for piece, scored in _pieces(text):
        lower = piece.lower()
        pos = 0
        for m in _WORD.finditer(lower):
            if tokens and _PAUSE.search(lower[pos:m.start()]):
                tokens[-1].pause_after = True
            tokens.append(Token(m.group(), scored))
            pos = m.end()
        if tokens and _PAUSE.search(lower[pos:]):
            tokens[-1].pause_after = True
    if tokens:
        tokens[-1].pause_after = True
    return tokens
