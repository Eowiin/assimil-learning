"""Qwen3 par Ollama ou Mistral par son API : les mêmes demandes que le serveur, côte à côte.

Ni Whisper ni XTTS ne sont chargés : seulement l'IA, par `app.llm.choisir_llm`,
exactement comme au démarrage du serveur. Pour chaque IA demandée, trois appels :
l'ouverture de la conversation, un tour, et le récapitulatif d'une conversation
qui contient des fautes connues (sortie structurée). Le temps de chaque appel
est affiché.

    uv run python essais/llm.py                 # ollama, puis mistral si MISTRAL_API_KEY est là
    uv run python essais/llm.py ollama
    uv run python essais/llm.py mistral

Les autres réglages (`ASSIMIL_IA`, `ASSIMIL_MISTRAL_MODELE`…) se lisent dans
l'environnement, comme pour le serveur.
"""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.conversation import (Corrections, Message, messages_correction,  # noqa: E402
                              messages_ouverture, messages_tour)
from app.llm import LLMIndisponible, choisir_llm  # noqa: E402

HISTORIQUE = [
    Message(role="assistant", content="¡Hola! ¿Qué has hecho este fin de semana?"),
    Message(role="user", content="Yo soy muy cansado porque he ido a la playa con mis amigos"),
    Message(role="assistant", content="¡Qué bien! ¿Y qué tal el agua?"),
    Message(role="user", content="El agua era muy fría pero me gusta mucho nadar por la mañana"),
    Message(role="assistant", content="¿Vas a volver pronto?"),
    Message(role="user", content="Sí, voy a volver para el próximo sábado"),
]
# Ce qu'un bon récapitulatif doit trouver : ser/estar (« soy cansado ») et por/para
# (« para el próximo sábado »). « El agua era muy fría » est juste.
ATTENDU = ("ser/estar", "por/para")


def chrono(fonction, *args, **kwargs):
    debut = time.perf_counter()
    resultat = fonction(*args, **kwargs)
    return resultat, time.perf_counter() - debut


def essayer(choix: str) -> None:
    env = {**os.environ, "ASSIMIL_LLM": choix}
    try:
        llm = choisir_llm(env)
    except ValueError as erreur:
        print(f"\n== {choix} : {erreur}")
        return
    print(f"\n== {llm.nom}")
    try:
        _, duree = chrono(llm.prechauffer)
        print(f"   préchauffage : {duree:.1f} s")
        ouverture, duree = chrono(llm.chat, messages_ouverture("la comida"), temperature=0.7)
        print(f"   ouverture ({duree:.1f} s) : {ouverture}")
        tour, duree = chrono(llm.chat, messages_tour(HISTORIQUE[:2], HISTORIQUE[1].content),
                             temperature=0.7)
        print(f"   tour ({duree:.1f} s) : {tour}")
        recap, duree = chrono(llm.structured, messages_correction(HISTORIQUE), Corrections)
    except LLMIndisponible as erreur:
        print(f"   indisponible : {erreur}")
        return
    print(f"   récapitulatif ({duree:.1f} s) :")
    for c in recap.corrections:
        print(f"     - [{c.category} / {c.tag}] « {c.said} » → « {c.corrected} »")
        print(f"       {c.explanation}")
    if not recap.corrections:
        print("     (aucune faute relevée)")
    print(f"   à trouver : {', '.join(ATTENDU)}")


def main() -> None:
    choix = sys.argv[1:] or (["ollama", "mistral"] if os.environ.get("MISTRAL_API_KEY") else ["ollama"])
    for c in choix:
        essayer(c)


if __name__ == "__main__":
    main()
