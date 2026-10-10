"""Texte espagnol → phonèmes castillans attendus, dans l'alphabet du modèle.

Le modèle a appris sur des transcriptions espeak : on produit les mêmes symboles
(θ, x, β/ð/ɣ, ɾ/r, j pour y et ʎ pour ll, tʃ). Règles écrites à la main plutôt
qu'espeak : l'orthographe espagnole est régulière, et on garde la main sur les
variantes du castillan.

Là où la prononciation hésite (diphtongue notée en un ou deux symboles, n assimilé
devant une bilabiale), `phonemiser` renvoie aussi des variantes ; l'analyse garde
celle que l'enregistrement rend la plus probable.

Les nombres ne sont pas gérés : `phonemiser` lève ValueError sur un chiffre.
"""
import re
import unicodedata

VOYELLES = set("aeiou")
NASALES = {"m", "n", "ɲ"}
# Une pause (ponctuation) remet b, d, g en occlusive.
PONCTUATION_PAUSE = set(",.;:?!¿¡…")
# Voyelle + glissante → diphtongue décroissante, qu'espeak note parfois d'un seul symbole.
DIPHTONGUES = {("a", "j"): "aɪ", ("e", "j"): "eɪ", ("o", "j"): "oɪ",
               ("a", "w"): "aʊ", ("e", "w"): "eʊ"}
# Archiphonèmes résolus selon le contexte : occlusive ou spirante.
OCCLUSIVE = {"B": "b", "D": "d", "G": "ɡ"}
SPIRANTE = {"B": "β", "D": "ð", "G": "ɣ"}


def _decouper(texte):
    """[(mot, pause_avant)] : pause_avant vaut True en début de phrase ou après une ponctuation."""
    mots, pause = [], True
    for jeton in re.findall(r"[a-záéíóúüñç]+|[^\sa-záéíóúüñç]", texte.lower()):
        if jeton[0].isalpha():
            mots.append((jeton, pause))
            pause = False
        elif jeton in PONCTUATION_PAUSE:
            pause = True
        elif jeton.isdigit():
            raise ValueError(f"nombre non géré : {texte!r}")
    return mots


def _lettres(mot):
    """Graphèmes → phonèmes d'un mot. Les voyelles portent (voyelle, accentuée)."""
    sortie, i = [], 0
    suivante = lambda k=1: mot[i + k] if i + k < len(mot) else ""
    while i < len(mot):
        c = mot[i]
        if c in "aeiouáéíóú":
            base = unicodedata.normalize("NFD", c)[0]
            sortie.append((base, c != base))
        elif c == "ü":
            sortie.append("w")
        elif c == "c":
            if suivante() == "h":
                sortie.append("tʃ"); i += 1
            elif suivante() in ("e", "é", "i", "í"):
                sortie.append("θ")
            else:
                sortie.append("k")
        elif c == "q":
            sortie.append("k")
            if suivante() == "u":
                i += 1
        elif c == "g":
            if suivante() == "u" and suivante(2) in ("e", "é", "i", "í"):
                sortie.append("G"); i += 1
            elif suivante() in ("e", "é", "i", "í"):
                sortie.append("x")
            else:
                sortie.append("G")
        elif c == "l" and suivante() == "l":
            sortie.append("ʎ"); i += 1
        elif c == "r":
            if suivante() == "r":
                sortie.append("r"); i += 1
            elif i == 0 or mot[i - 1] in "nls":
                sortie.append("r")
            else:
                sortie.append("ɾ")
        elif c == "y":
            if mot == "y":
                sortie.append(("i", False))
            elif i == len(mot) - 1:
                sortie.append("j")  # hoy, muy, rey : glissante
            else:
                sortie.append("ʝ")
        elif c == "x":
            sortie.extend(["s"] if i == 0 else ["k", "s"])
        elif c in "bv":
            sortie.append("B")
        elif c == "d":
            sortie.append("D")
        elif c == "h":
            pass
        else:
            sortie.append({"j": "x", "z": "θ", "ñ": "ɲ", "ç": "s"}.get(c, c))
        i += 1
    return sortie


def _glisser(sons):
    """i et u non accentués au contact d'une autre voyelle deviennent j et w."""
    est_voyelle = lambda s: isinstance(s, tuple)
    for k, s in enumerate(sons):
        if not est_voyelle(s) or s[1] or s[0] not in "iu":
            continue
        avant = k > 0 and est_voyelle(sons[k - 1])
        apres = k + 1 < len(sons) and est_voyelle(sons[k + 1])
        if apres or avant:
            sons[k] = "j" if s[0] == "i" else "w"
    return [s[0] if est_voyelle(s) else s for s in sons]


def phonemiser(texte):
    """Retourne (mots, phonèmes, variantes).

    Chaque phonème est (symbole, indice du mot). Chaque variante est (début, longueur,
    remplacement) : une autre réalisation acceptable des phonèmes[début:début+longueur].
    """
    mots = _decouper(texte)
    suite, pauses = [], set()
    for indice, (mot, pause) in enumerate(mots):
        sons = _glisser(_lettres(mot))
        if pause:
            pauses.add(len(suite))
        # Synalèphe : même voyelle de part et d'autre de la frontière de mot.
        if suite and sons and not pause and sons[0] in VOYELLES and suite[-1][0] == sons[0]:
            sons = sons[1:]
        suite.extend((s, indice) for s in sons)

    resultat, variantes = [], []
    for k, (s, indice) in enumerate(suite):
        precedent = resultat[-1][0] if resultat and k not in pauses else None
        if s in OCCLUSIVE:
            occlusive = precedent is None or precedent in NASALES or (s == "D" and precedent == "l")
            s = (OCCLUSIVE if occlusive else SPIRANTE)[s]
        # n peut s'assimiler devant une bilabiale : un poco → [um poko].
        if s in ("p", "b", "m") and precedent == "n":
            variantes.append((len(resultat) - 1, 1, ["m"]))
        if precedent and (precedent, s) in DIPHTONGUES and k not in pauses:
            variantes.append((len(resultat) - 1, 2, [DIPHTONGUES[(precedent, s)]]))
        resultat.append((s, indice))
    # La glissante devenue consonne (ya, mayo) s'écrit j, comme le fait le modèle.
    resultat = [("j" if s == "ʝ" else s, i) for s, i in resultat]
    return [m for m, _ in mots], resultat, variantes


if __name__ == "__main__":
    import sys
    for phrase in sys.argv[1:]:
        mots, sons, _ = phonemiser(phrase)
        print(phrase)
        for indice, mot in enumerate(mots):
            print(f"  {mot:15} {' '.join(s for s, i in sons if i == indice)}")
