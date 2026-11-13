"""Spanish number words (cardinals up to 999 999 999, small ordinals)."""

_UNITS = [
    "cero", "uno", "dos", "tres", "cuatro", "cinco", "seis", "siete", "ocho", "nueve",
    "diez", "once", "doce", "trece", "catorce", "quince", "dieciséis", "diecisiete",
    "dieciocho", "diecinueve", "veinte", "veintiuno", "veintidós", "veintitrés",
    "veinticuatro", "veinticinco", "veintiséis", "veintisiete", "veintiocho", "veintinueve",
]
_TENS = {3: "treinta", 4: "cuarenta", 5: "cincuenta", 6: "sesenta", 7: "setenta",
         8: "ochenta", 9: "noventa"}
_HUNDREDS = {1: "ciento", 2: "doscientos", 3: "trescientos", 4: "cuatrocientos",
             5: "quinientos", 6: "seiscientos", 7: "setecientos", 8: "ochocientos",
             9: "novecientos"}

_ORDINALS = ["primer", "segund", "tercer", "cuart", "quint", "sext", "séptim", "octav",
             "noven", "décim"]


def _below_thousand(n: int, apocope: bool) -> str:
    if n == 100:
        return "cien"
    hundreds, rest = divmod(n, 100)
    parts = [_HUNDREDS[hundreds]] if hundreds else []
    if rest < 30 and rest:
        word = _UNITS[rest]
        if apocope and word.endswith("uno"):
            word = word[:-1] if rest == 1 else word[:-3] + "ún"  # un, veintiún
        parts.append(word)
    elif rest:
        tens, unit = divmod(rest, 10)
        parts.append(_TENS[tens])
        if unit:
            parts += ["y", "un" if apocope and unit == 1 else _UNITS[unit]]
    return " ".join(parts)


def cardinal(n: int, apocope: bool = False) -> str:
    """Cardinal in words. `apocope` gives the form used before a noun (un, veintiún)."""
    if not 0 <= n < 1_000_000_000:
        raise ValueError(f"unsupported number: {n}")
    if n == 0:
        return "cero"
    millions, rest = divmod(n, 1_000_000)
    thousands, units = divmod(rest, 1000)
    parts = []
    if millions:
        parts.append("un millón" if millions == 1
                     else _below_thousand(millions, apocope=True) + " millones")
    if thousands:
        parts.append("mil" if thousands == 1 else _below_thousand(thousands, apocope=True) + " mil")
    if units:
        parts.append(_below_thousand(units, apocope))
    return " ".join(parts)


def ordinal(n: int, feminine: bool) -> str:
    if not 1 <= n <= len(_ORDINALS):
        raise ValueError(f"unsupported ordinal: {n}")
    return _ORDINALS[n - 1] + ("a" if feminine else "o")
