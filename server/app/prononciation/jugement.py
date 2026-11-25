"""Le résultat de l'analyse, mis en forme pour l'app : mot par mot, avec un conseil
pour chaque faute de francophone connue. Sans modèle : testable seul."""

from __future__ import annotations

# Ce qu'un francophone fait de travers, et comment le corriger.
R_FRANCAIS = "Le r se fait du bout de la langue, derrière les dents du haut, pas au fond de la gorge comme en français."
CONSEILS = {
    "θ": "Le c (devant e, i) et le z se disent la langue entre les dents, comme le th anglais de « think ».",
    "x": "La jota se dit au fond de la gorge, comme un h fort et râpeux, sans vibrer comme le r français.",
    "r": "Le r roulé : plusieurs battements rapides du bout de la langue, derrière les dents du haut.",
    "ɾ": "Le r simple : un seul coup bref du bout de la langue, derrière les dents du haut.",
    "v": "Le v espagnol se dit comme un b : les deux lèvres, sans toucher les dents.",
}
UVULAIRES = {"ʁ", "χ", "ʀ"}


def conseil(attendu: str, entendu: str | None) -> str | None:
    if attendu in ("r", "ɾ") and entendu in UVULAIRES:
        return R_FRANCAIS
    if attendu == "b" and entendu == "v":
        return CONSEILS["v"]
    return CONSEILS.get(attendu)


def par_mots(resultat: dict) -> list[dict]:
    """`resultat` : la sortie d'`Analyseur.analyser`. Un mot est fautif si l'un de ses
    sons l'est ; un indice (le r roulé dit battu) ne le rend pas fautif."""
    mots = [{"text": texte, "fault": False, "phonemes": []} for texte in resultat["mots"]]
    for p in resultat["phonemes"]:
        faute, indice = p["faute"], p.get("indice")
        entendu = p["variante"] if faute else indice
        mot = mots[p["mot"]]
        mot["fault"] |= faute
        mot["phonemes"].append({
            "expected": p["attendu"],
            "heard": entendu,
            "fault": faute,
            "reason": p["raison"],
            "hint": indice is not None and not faute,
            "tip": conseil(p["attendu"], entendu) if faute or indice else None,
            "score": p["score"],
            "threshold": p.get("seuil"),
            "start": p.get("debut"),
            "end": p.get("fin"),
        })
    return mots
