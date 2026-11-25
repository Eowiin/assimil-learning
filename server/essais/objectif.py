"""L'objectif du jour, avec Mistral : le récapitulatif d'une
conversation, la correction d'un écrit, et la mesure des répliques.

Ni Whisper ni XTTS ne sont chargés : seulement l'IA (`app.llm.choisir_llm`, comme le
serveur) et spaCy. L'objectif est obj_031 (imparfait et indefinido), lu dans le paquet
de l'app :

1. **Récapitulatif** d'une conversation aux fautes connues : les corrections, celles que
   le serveur écarte parce qu'identiques à la phrase de départ, et l'objectif jugé.
2. **Écrit** fautif (accents et temps du passé) : les corrections et le texte corrigé.
3. **Répliques mesurées** : l'ouverture de chaque mode (libre, jeu de rôle, rapide) au
   niveau A2, puis un tour, avec les 800 premiers lemmes du lexique comme connus.
   Chaque version écrite est affichée avec sa couverture ; sous 85 %, l'IA réécrit.

    uv run python essais/objectif.py
    uv run python essais/objectif.py -n 1500  # un apprenant qui connaît 1 500 lemmes
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.conversation import (SEUIL_REPLIQUE, CorrectionsEcritObjectif,  # noqa: E402
                              CorrectionsObjectif, Message, Objectif, Profil, connus_du_tour,
                              messages_correction, messages_ecrit, messages_ouverture,
                              messages_tour, mesurer, vraies_corrections)
from app.langue.analyse import MODELE, Spacy, installe  # noqa: E402
from app.llm import LLMIndisponible, choisir_llm  # noqa: E402

PAQUET = Path(__file__).resolve().parents[2] / "Resources/curriculum/es"
NIVEAU = "A2"

HISTORIQUE = [
    Message(role="assistant", content="¿Te ha pasado algo curioso en un viaje?"),
    Message(role="user", content="Sí, el año pasado cuando iba a Madrid en tren, el tren se paraba de repente"),
    Message(role="assistant", content="¡Vaya! ¿Y cómo te sentiste?"),
    Message(role="user", content="Estuve muy nervioso porque tenía una reunión importante"),
    Message(role="assistant", content="Te entiendo. ¿Y qué hiciste mientras esperabas?"),
    Message(role="user", content="Mientras esperaba, leí un libro y hablé con una señora muy simpática"),
    Message(role="assistant", content="¿Y llegaste a tiempo a la reunión?"),
    Message(role="user", content="Llegué con una hora de retraso. Gracias para preguntar"),
]
ATTENDU_RECAP = """\
   à trouver : « se paraba » → « se paró » (l'événement), « Estuve » → « Estaba » (le décor),
               « gracias para » → « gracias por ». « Mientras esperaba, leí… » est juste.
   objectif : phrases 1 et 2 non valides, phrase 3 valide (« Llegué… » ne le tente pas)."""

ECRIT = ("El sábado pasado fui al cine con mi hermana. Cuando llegabamos, la película ya empezó. "
         "Hacía mucho frio y la sala estuvo llena. Despues, cenamos en un restaurante muy bueno "
         "y hablabamos mucho de la película.")
ATTENDU_ECRIT = """\
   à trouver : « llegabamos » → « llegamos » (événement), « ya empezó » → « ya había empezado »,
               « frio » → « frío », « estuvo llena » → « estaba llena » (décor), « Despues » →
               « Después », « hablabamos » → « hablamos » (ou « hablábamos », accent)."""

# Le tour mesuré : l'apprenant répond à l'ouverture.
PHRASE_DU_TOUR = "El domingo pasado iba en bici por el parque cuando empezó a llover"


def chrono(fonction, *args, **kwargs):
    debut = time.perf_counter()
    resultat = fonction(*args, **kwargs)
    return resultat, time.perf_counter() - debut


def objectif(identifiant: str) -> Objectif:
    tous = json.loads((PAQUET / "objectives.json").read_text(encoding="utf-8"))["objectives"]
    return Objectif.model_validate(next(o for o in tous if o["id"] == identifiant))


def lemmes_connus(n: int) -> list[str]:
    lexique = json.loads((PAQUET / "lexicon.json").read_text(encoding="utf-8"))["lemmas"]
    return [x["lemma"] for x in lexique if x["rank"] <= n]


def recapitulatif(llm, obj: Objectif) -> None:
    recap, duree = chrono(llm.structured, messages_correction(HISTORIQUE, obj, NIVEAU),
                          CorrectionsObjectif)
    gardees = vraies_corrections(recap.corrections)
    print(f"\n   1. récapitulatif ({duree:.1f} s) :")
    for c in recap.corrections:
        ecartee = "" if c in gardees else "   ✗ écartée (identique)"
        print(f"     - [{c.category} / {c.tag}] « {c.said} » → « {c.corrected} »{ecartee}")
        print(f"       {c.explanation}")
    if not recap.corrections:
        print("     (aucune faute relevée)")
    print("     objectif :")
    for u in recap.objective_uses:
        print(f"     - {'✓' if u.valide else '✗'} « {u.said} »\n       {u.analyse_courte}")
    if not recap.objective_uses:
        print("     (aucune tentative relevée)")
    print(ATTENDU_RECAP)


def ecrit(llm, obj: Objectif) -> None:
    recap, duree = chrono(llm.structured, messages_ecrit(ECRIT, obj, NIVEAU), CorrectionsEcritObjectif)
    gardees = vraies_corrections(recap.corrections, ecrit=True)
    print(f"\n   2. écrit ({duree:.1f} s) :")
    for c in recap.corrections:
        ecartee = "" if c in gardees else "   ✗ écartée (identique)"
        print(f"     - [{c.category} / {c.tag}] « {c.said} » → « {c.corrected} »{ecartee}")
        print(f"       {c.explanation}")
    print(f"     texte corrigé : {recap.corrected_text}")
    print("     objectif :")
    for u in recap.objective_uses:
        print(f"     - {'✓' if u.valide else '✗'} « {u.said} »\n       {u.analyse_courte}")
    if not recap.objective_uses:
        print("     (aucune tentative relevée)")
    print(ATTENDU_ECRIT)


def replique_mesuree(llm, langue: Spacy, messages: list[dict], profil: Profil,
                     phrase: str | None) -> str:
    """Une réplique, puis ses réécritures, chaque version affichée avec sa couverture."""
    connus = connus_du_tour(profil, phrase, langue)
    versions = []

    def repondre(msgs):
        texte = llm.chat(msgs, temperature=0.7)
        versions.append(texte)
        return texte

    debut = time.perf_counter()
    premiere = repondre(messages)
    mesure = mesurer(premiere, repondre, langue, connus, profil.level)
    duree = time.perf_counter() - debut
    for i, texte in enumerate(versions):
        c = langue.couverture(texte, connus)
        inconnus = f"  inconnus : {', '.join(c.inconnus)}" if c.inconnus else ""
        garde = "  ← gardée" if texte.strip().strip("«»\"“”'").strip() == mesure.texte else ""
        print(f"       v{i + 1} {c.taux:.0%} : {texte}{garde}")
        if inconnus:
            print(f"          {inconnus}")
    print(f"       → {mesure.couverture:.0%} en {mesure.essais} version(s), {duree:.1f} s")
    return mesure.texte


def repliques(llm, langue: Spacy, obj: Objectif, n: int) -> None:
    print(f"\n   3. répliques mesurées ({n} lemmes connus, seuil {SEUIL_REPLIQUE:.0%}) :")
    for mode in (None, "roleplay", "speed"):
        profil = Profil(level=NIVEAU, objective=obj, mode=mode, allowed_lemmas=lemmes_connus(n))
        print(f"     {mode or 'libre'} — ouverture :")
        ouverture = replique_mesuree(llm, langue, messages_ouverture(None, profil), profil, None)
        print(f"     {mode or 'libre'} — tour (« {PHRASE_DU_TOUR} ») :")
        historique = [Message(role="assistant", content=ouverture)]
        replique_mesuree(llm, langue, messages_tour(historique, PHRASE_DU_TOUR, profil), profil,
                         PHRASE_DU_TOUR)


def essayer(langue: Spacy | None, n: int) -> None:
    try:
        llm = choisir_llm()
    except ValueError as erreur:
        sys.exit(str(erreur))
    print(f"\n== {llm.nom}")
    obj = objectif("obj_031")
    try:
        _, duree = chrono(llm.prechauffer)
        print(f"   préchauffage : {duree:.1f} s")
        recapitulatif(llm, obj)
        ecrit(llm, obj)
        if langue is not None:
            repliques(llm, langue, obj, n)
    except LLMIndisponible as erreur:
        print(f"   indisponible : {erreur}")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("-n", type=int, default=800, help="combien de lemmes du lexique sont connus")
    args = p.parse_args()

    langue = None
    if installe():
        langue, duree = chrono(Spacy)
        print(f"{MODELE} chargé en {duree:.1f} s.")
    else:
        print(f"{MODELE} n'est pas installé (`uv sync`) : pas de mesure des répliques.")
    essayer(langue, args.n)


if __name__ == "__main__":
    main()
