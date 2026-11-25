"""Les fautes de francophone visées par le test du 10 novembre 2026, et comment
les retrouver parmi les phonèmes d'une phrase. Repris de `essayer.py` (branche
`recherche/prononciation-essai-voix`), sans l'enregistrement au micro du Mac."""

# Faute de francophone visée → (phonèmes attendus concernés, ce qu'on dit à la place).
FAUTES = {
    "θ": ({"θ"}, "s"),
    "jota": ({"x"}, "r français"),
    "r": ({"r", "ɾ"}, "r français"),
    "v": ({"b", "β"}, "v"),  # seulement là où la lettre est un v
}


def cibles(mots, phonemes):
    """Pour chaque phonème (dicts avec 'attendu' et 'mot'), la faute visée ou None.

    b et β ne sont visés que s'ils viennent d'un v : chaque b ou v écrit donne un
    seul b/β, dans l'ordre, ce qui permet de retrouver la lettre.
    """
    vus = {}
    sortie = []
    for p in phonemes:
        faute = next((nom for nom, (sons, _) in FAUTES.items() if p["attendu"] in sons), None)
        if faute == "v":
            lettres = [c for c in mots[p["mot"]] if c in "bv"]
            k = vus.get(p["mot"], 0)
            vus[p["mot"]] = k + 1
            faute = "v" if k < len(lettres) and lettres[k] == "v" else None
        sortie.append(faute)
    return sortie
