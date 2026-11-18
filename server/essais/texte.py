"""Le texte du bloc 2, Qwen3 et Mistral côte à côte, écrit et mesuré comme le fait le
serveur (`app.seance.generer`).

L'objectif est obj_031 (imparfait et indefinido), lu dans le paquet de l'app ; le thème,
un voyage en train qui tourne mal ; 7 mots nouveaux du thème, pris au-delà des lemmes
connus. Les lemmes connus : les `-n` premiers du lexique. spaCy est chargé, ni Whisper
ni XTTS (sauf `--tts`). Pour chaque IA, chaque version écrite : sa couverture, ses mots
inconnus, les mots nouveaux employés, et les phrases marquées pour l'objectif ; puis le
texte gardé, avec sa traduction.

    uv run python essais/texte.py                     # ollama, puis mistral si MISTRAL_API_KEY est là
    uv run python essais/texte.py mistral -n 1500     # un apprenant qui connaît 1 500 lemmes
    uv run python essais/texte.py mistral --mots 250  # un texte plus long
    uv run python essais/texte.py mistral --tts essais/sortie/texte   # et les m4a, phrase par phrase
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.conversation import Objectif  # noqa: E402
from app.langue.analyse import MODELE, Spacy, installe  # noqa: E402
from app.llm import LLMIndisponible, choisir_llm  # noqa: E402
from app.seance import (CIBLE_TEXTE, SEUIL_TEXTE, InputRequest, Redaction, generer,  # noqa: E402
                        presents, texte_de)

PAQUET = Path(__file__).resolve().parents[2] / "Resources/curriculum/es"
NIVEAU = "A2"
THEME = "un viaje en tren que no salió como estaba previsto"
NOUVEAUX = ["estación", "asiento", "maleta", "billete", "equipaje", "retraso", "paisaje"]


def chrono(fonction, *args, **kwargs):
    debut = time.perf_counter()
    resultat = fonction(*args, **kwargs)
    return resultat, time.perf_counter() - debut


def objectif(identifiant: str) -> Objectif:
    tous = json.loads((PAQUET / "objectives.json").read_text(encoding="utf-8"))["objectives"]
    return Objectif.model_validate(next(o for o in tous if o["id"] == identifiant))


def lexique() -> dict[str, int]:
    return {x["lemma"]: x["rank"] for x in json.loads(
        (PAQUET / "lexicon.json").read_text(encoding="utf-8"))["lemmas"]}


def essayer(choix: str, langue: Spacy, demande: InputRequest, sortie: Path | None) -> None:
    env = {**os.environ, "ASSIMIL_LLM": choix}
    try:
        llm = choisir_llm(env)
    except ValueError as erreur:
        print(f"\n== {choix} : {erreur}")
        return
    print(f"\n== {llm.nom}")
    connus = {*demande.known_lemmas, *demande.new_lemmas}
    versions: list[tuple[Redaction, float]] = []

    def rediger(messages, modele):
        # Comme `Reels.rediger` : la sortie structurée, avec de la variété.
        redaction, duree = chrono(llm.structured, messages, modele, temperature=0.7)
        versions.append((redaction, duree))
        return redaction

    try:
        _, duree = chrono(llm.prechauffer)
        print(f"   préchauffage : {duree:.1f} s")
        texte, duree = chrono(generer, demande, rediger, langue)
    except LLMIndisponible as erreur:
        print(f"   indisponible : {erreur}")
        return
    for i, (r, d) in enumerate(versions, 1):
        brut = texte_de(r)
        c = langue.couverture(brut, connus)
        marquees = sum(p.objective for p in r.sentences)
        print(f"\n   v{i} ({d:.1f} s) : {c.taux:.1%}, {len(brut.split())} mots, {len(r.sentences)} phrases, "
              f"{marquees} pour l'objectif")
        print(f"      nouveaux : {', '.join(presents(demande.new_lemmas, langue, brut)) or '(aucun)'}")
        if c.inconnus:
            print(f"      inconnus : {', '.join(c.inconnus)}")
    print(f"\n   → gardé : {texte.coverage:.1%} en {texte.attempts} version(s), {duree:.1f} s ; "
          f"nouveaux absents : {', '.join(set(demande.new_lemmas) - set(texte.new_used)) or 'aucun'}")
    for i, p in enumerate(texte.sentences):
        repere = "◆" if i in texte.objective_hits else " "
        print(f"     {repere} {p.es}\n         {p.fr}")
    print("     (◆ : la phrase emploie l'objectif, d'après l'IA)")
    if sortie is not None:
        dire(texte.sentences, sortie / llm.nom.replace(" ", "_").replace(":", "_"))


def dire(phrases, dossier: Path) -> None:
    """Les phrases en m4a, comme `/tts` : XTTS, réglé par les mêmes variables que le serveur."""
    from app.voix import choisir_tts, en_m4a

    dossier.mkdir(parents=True, exist_ok=True)
    tts, duree = chrono(choisir_tts, os.environ.get("ASSIMIL_APPAREIL", "cuda"))
    print(f"   voix ({tts.nom}) chargée en {duree:.1f} s")
    debut = time.perf_counter()
    for i, p in enumerate(phrases, 1):
        (dossier / f"{i:02}.m4a").write_bytes(en_m4a(tts.dire(p.es)))
    print(f"   {len(phrases)} phrases dites en {time.perf_counter() - debut:.1f} s → {dossier}/")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("ia", nargs="*", help="ollama, mistral (par défaut : les deux si la clé est là)")
    p.add_argument("-n", type=int, default=800, help="combien de lemmes du lexique sont connus")
    p.add_argument("--mots", type=int, default=150, help="la longueur visée (target_words)")
    p.add_argument("--tts", type=Path, help="un dossier où écrire les m4a, phrase par phrase")
    args = p.parse_args()
    choix = args.ia or (["ollama", "mistral"] if os.environ.get("MISTRAL_API_KEY") else ["ollama"])
    if not installe():
        sys.exit(f"{MODELE} n'est pas installé (`uv sync`) : il mesure le texte.")

    rangs = lexique()
    connus = [l for l, r in rangs.items() if r <= args.n]
    deja = [m for m in NOUVEAUX if rangs.get(m, 10**6) <= args.n]
    if deja:
        print(f"Attention : {', '.join(deja)} sont déjà dans les {args.n} lemmes connus.")
    demande = InputRequest(level=NIVEAU, theme=THEME, objective=objectif("obj_031"),
                           known_lemmas=connus, new_lemmas=NOUVEAUX, target_words=args.mots)
    langue, duree = chrono(Spacy)
    print(f"{MODELE} chargé en {duree:.1f} s. {len(connus)} lemmes connus, {args.mots} mots visés, "
          f"seuil {SEUIL_TEXTE:.0%}, cible {CIBLE_TEXTE:.0%}.")
    for c in choix:
        essayer(c, langue, demande, args.tts)


if __name__ == "__main__":
    main()
