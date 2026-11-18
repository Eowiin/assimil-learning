"""Le placement, Qwen3 et Mistral côte à côte : douze défis du paquet, trois réponses
chacun (en général : une qui montre l'objectif, une juste qui le contourne, une
fausse), jugés comme le fait le serveur (`app.placement.evaluer`).

Les réponses sont écrites pour ne jamais être identiques au paquet : elles vont toutes
au juge, aucune n'est triée d'avance. Ni Whisper, ni XTTS, ni spaCy ne sont chargés :
seulement l'IA (`app.llm.choisir_llm`, comme le serveur). Pour chaque IA : chaque verdict
à côté de celui qu'on attend, l'analyse des désaccords, le score et le temps.

    uv run python essais/placement.py                 # ollama, puis mistral si MISTRAL_API_KEY est là
    uv run python essais/placement.py mistral
    uv run python essais/placement.py mistral -v      # toutes les analyses, pas seulement les désaccords
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.llm import LLMIndisponible, choisir_llm  # noqa: E402
from app.placement import Defi, evaluer, trier  # noqa: E402

PAQUET = Path(__file__).resolve().parents[2] / "Resources/curriculum/es"
NIVEAU = "B1"

S, C, W = "shown", "correct_not_shown", "wrong"

# Par défi : (réponse, verdicts acceptés). Deux verdicts quand le cas se discute.
REPONSES: dict[str, list[tuple[str, tuple[str, ...]]]] = {
    "pc_015": [("No me gusta el café. A mi tampoco", (S,)),
               ("No me gusta nada el café. Yo tampoco.", (C,)),
               ("No me gusta el café. A mí también.", (W,))],
    "pc_018": [("Siga recto y después gire a la derecha, está al lado del bar.", (S,)),
               ("Sigue recto y después gira a la derecha, está al lado del bar.", (C,)),
               ("Siga todo recto y luego gire a la izquierda: está al lado del bar.", (W,))],
    "pc_020": [("Esta semana tengo que trabajar mucho, pero también hay que descansar un poco.", (S,)),
               ("Esta semana debo trabajar, pero también es necesario descansar.", (C,)),
               ("Esta semana tengo trabajar, pero también hay de descansar.", (W,))],
    "pc_025": [("Hoy por la mañana he ido al mercado y he comprado pan.", (S,)),
               ("Esta mañana fui al mercado y compré un poco de pan.", (C,)),
               ("Esta mañana soy ido al mercado y tengo comprado pan.", (W,))],
    "pc_031": [("Llovía cuando nosotros salimos del restaurante.", (S,)),
               ("Al salir del restaurante, llovía.", (C,)),
               ("Llovió cuando salíamos del restaurante.", (W,))],
    "pc_041": [("No vi a nadie y tampoco compré nada.", (S,)),
               ("No he visto nadie y he comprado nada.", (W,))],
    "pc_049": [("Como no tengo coche, voy en bus, así que llego más tarde.", (S,)),
               ("Puesto que no tengo coche, cojo el autobús, así que llego más tarde.", (C,)),
               # « Porque » en tête de phrase : un calque, ou une tournure qui contourne ?
               ("Porque no tengo coche, cojo el autobús, entonces llego más tarde.", (W, C))],
    "pc_064": [("No sé, estará en el gimnasio.", (S,)),
               ("No sé, debe estar en el gimnasio.", (C,)),
               ("No sé, está en el gimnasio.", (W,))],
    "pc_078": [("Espero que hayas disfrutado del fin de semana.", (S,)),
               ("Espero que lo pasaras bien este finde.", (C,)),
               ("Espero que has pasado un buen fin de semana.", (W,))],
    "pc_090": [("No puedo venir, es que mañana tengo examen.", (S,)),
               ("No puedo venir porque mañana tengo un examen.", (C,)),
               ("No puedo venir, es porque tengo un examen mañana.", (W,))],
    "pc_092": [("Aún no ha llegado; habrá perdido el bus.", (S,)),
               ("Todavía no ha llegado, seguramente ha perdido el autobús.", (C,)),
               ("Todavía no ha llegado; habría perdido el autobús.", (W,))],
    "pc_093": [("Por más que insistas, no cambiaré de idea.", (S,)),
               ("Aunque insistas mucho, no voy a cambiar de opinión.", (C,)),
               ("Por mucho que insistes, no voy a cambiar de opinión.", (W,))],
}


def chrono(fonction, *args, **kwargs):
    debut = time.perf_counter()
    resultat = fonction(*args, **kwargs)
    return resultat, time.perf_counter() - debut


def defis() -> tuple[list[Defi], list[tuple[str, ...]], list[str]]:
    """Les défis à juger, les verdicts acceptés, et l'identifiant du défi de chacun."""
    paquet = {c["id"]: c for c in json.loads(
        (PAQUET / "placement_challenges.json").read_text(encoding="utf-8"))["challenges"]}
    liste, attendus, ids = [], [], []
    for identifiant, reponses in REPONSES.items():
        c = paquet[identifiant]
        for reponse, acceptes in reponses:
            d = Defi(objective_id=c["objective"], instruction=c["instruction"], prompt=c["prompt"],
                     expected=c["expected"], also_correct=c["also_correct"], check=c["check"],
                     answer=reponse)
            assert trier(d) is None or not reponse.strip(), f"{identifiant} : « {reponse} » est trié d'avance"
            liste.append(d)
            attendus.append(acceptes)
            ids.append(identifiant)
    return liste, attendus, ids


def essayer(choix: str, bavard: bool) -> None:
    env = {**os.environ, "ASSIMIL_LLM": choix}
    try:
        llm = choisir_llm(env)
    except ValueError as erreur:
        print(f"\n== {choix} : {erreur}")
        return
    print(f"\n== {llm.nom}")
    liste, attendus, ids = defis()
    appels = []

    def juger(messages, modele):
        resultat, duree = chrono(llm.structured, messages, modele, temperature=0)
        appels.append(duree)
        return resultat

    try:
        _, duree = chrono(llm.prechauffer)
        print(f"   préchauffage : {duree:.1f} s")
        verdicts, duree = chrono(evaluer, liste, juger, NIVEAU)
    except LLMIndisponible as erreur:
        print(f"   indisponible : {erreur}")
        return
    justes = 0
    precedent = None
    for d, v, acceptes, identifiant in zip(liste, verdicts, attendus, ids):
        if identifiant != precedent:
            print(f"\n   {identifiant} ({d.objective_id}) : {d.prompt}")
            precedent = identifiant
        bon = v.verdict in acceptes
        justes += bon
        attendu = " ou ".join(acceptes)
        print(f"     {'✓' if bon else '✗'} {v.verdict:<17} (attendu {attendu:<24}) « {d.answer} »")
        if bavard or not bon:
            print(f"       {v.analyse_courte}")
    print(f"\n   score : {justes}/{len(liste)} en {duree:.1f} s "
          f"({len(appels)} appels : {', '.join(f'{a:.1f}' for a in appels)} s)")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("ia", nargs="*", help="ollama, mistral (par défaut : les deux si la clé est là)")
    p.add_argument("-v", action="store_true", help="toutes les analyses")
    args = p.parse_args()
    choix = args.ia or (["ollama", "mistral"] if os.environ.get("MISTRAL_API_KEY") else ["ollama"])
    for c in choix:
        essayer(c, args.v)


if __name__ == "__main__":
    main()
