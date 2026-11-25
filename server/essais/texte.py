"""Le texte du bloc 2, écrit par Mistral et mesuré comme le fait le
serveur (`app.seance.generer`).

L'objectif est obj_031 (imparfait et indefinido), lu dans le paquet de l'app ; le thème,
un voyage en train qui tourne mal ; 7 mots nouveaux du thème, pris au-delà des lemmes
connus. Les lemmes connus : les `-n` premiers du lexique. spaCy est chargé, ni Whisper
ni XTTS (sauf `--tts`). Chaque version écrite : sa couverture, ses mots
inconnus et les mots nouveaux employés ; puis le texte gardé, avec sa traduction et les
phrases de l'objectif repérées par le juge (la même IA, à température 0).

    uv run python essais/texte.py
    uv run python essais/texte.py -n 1500     # un apprenant qui connaît 1 500 lemmes
    uv run python essais/texte.py --mots 250  # un texte plus long
    uv run python essais/texte.py --tts essais/sortie/texte   # et les m4a, phrase par phrase
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


def essayer(langue: Spacy, demande: InputRequest, sortie: Path | None) -> None:
    try:
        llm = choisir_llm()
    except ValueError as erreur:
        sys.exit(str(erreur))
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
        texte, duree = chrono(generer, demande, rediger, langue,
                              lambda messages, modele: llm.structured(messages, modele, temperature=0))
    except LLMIndisponible as erreur:
        print(f"   indisponible : {erreur}")
        return
    for i, (r, d) in enumerate(versions, 1):
        brut = texte_de(r)
        c = langue.couverture(brut, connus)
        print(f"\n   v{i} ({d:.1f} s) : {c.taux:.1%}, {len(brut.split())} mots, {len(r.sentences)} phrases")
        print(f"      nouveaux : {', '.join(presents(demande.new_lemmas, langue, brut)) or '(aucun)'}")
        if c.inconnus:
            print(f"      inconnus : {', '.join(c.inconnus)}")
    print(f"\n   → gardé : {texte.coverage:.1%} en {texte.attempts} version(s), {duree:.1f} s ; "
          f"nouveaux absents : {', '.join(set(demande.new_lemmas) - set(texte.new_used)) or 'aucun'}")
    reperes = texte.objective_hits or []
    for i, p in enumerate(texte.sentences):
        repere = "◆" if i in reperes else " "
        print(f"     {repere} {p.es}\n         {p.fr}")
    print("     (◆ : la phrase emploie l'objectif, d'après le juge)" if texte.objective_hits is not None
          else "     (le juge n'a pas répondu : phrases de l'objectif inconnues)")
    # Les cartes de l'app (étape 4c) : le mot en gras dans sa première phrase.
    print("\n   cartes des mots nouveaux :")
    for o in texte.new_occurrences or []:
        print(f"     {o.lemma:<12} phrase {o.sentence + 1:>2}, « {o.form} » : {texte.sentences[o.sentence].es}")
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
    p.add_argument("-n", type=int, default=800, help="combien de lemmes du lexique sont connus")
    p.add_argument("--mots", type=int, default=150, help="la longueur visée (target_words)")
    p.add_argument("--tts", type=Path, help="un dossier où écrire les m4a, phrase par phrase")
    args = p.parse_args()
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
    essayer(langue, demande, args.tts)


if __name__ == "__main__":
    main()
