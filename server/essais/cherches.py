"""Les mots cherchés et leur phrase (étape 6c), avec Mistral.

Ni Whisper ni la voix : seulement le récapitulatif, comme le serveur le demande
(`messages_correction`, puis `mots_cherches_propres`). Quatre conversations de débutant,
écrites d'avance, avec des demandes (« Je ne sais pas le dire ») et du français glissé
dans une réponse. Pour chaque mot cherché, l'IA doit rendre la phrase du partenaire qui
le donne, mot pour mot, et sa traduction : c'est le recto et le verso de la carte.

À regarder :
- chaque mot cherché est-il là, une fois, avec le bon lemme ?
- la phrase est-elle bien celle du partenaire qui donne le mot (pas une autre) ?
- la traduction est-elle juste ?
- « phrase écartée » : l'IA a rendu une phrase qui n'est pas dans les répliques
  (reformulée, ou inventée) ; le serveur l'enlève, et la carte n'aura que le mot.

    uv run python essais/cherches.py
    uv run python essais/cherches.py --fois 3   # chaque conversation 3 fois (stabilité)
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.conversation import (CorrectionsCherches, Message, messages_correction,  # noqa: E402
                              mots_cherches_propres)
from app.llm import LLMIndisponible, choisir_llm  # noqa: E402


def m(role: str, texte: str, ask: bool = False) -> Message:
    return Message(role=role, content=texte, ask=ask)


# Chaque conversation : son nom, son niveau, l'historique, et les lemmes attendus.
CONVERSATIONS = [
    ("restaurant, deux demandes", "A0", [
        m("assistant", "¡Hola! Bienvenido. ¿Qué quiere comer?"),
        m("user", "Quiero pollo, por favor."),
        m("assistant", "Muy bien, pollo. ¿Y para beber?"),
        m("user", "Comment on dit une carafe d'eau ?", ask=True),
        m("assistant", "Se dice «una jarra de agua». ¿Quiere una jarra de agua?"),
        m("user", "Sí, una jarra de agua."),
        m("assistant", "Perfecto. ¿Algo más?"),
        m("user", "couteau", ask=True),
        m("assistant", "¡Ah, un cuchillo! Aquí tiene el cuchillo."),
        m("user", "Gracias."),
    ], ["jarra", "cuchillo"]),
    ("français glissé dans les réponses", "A1", [
        m("assistant", "¿Qué hiciste el fin de semana?"),
        m("user", "Fui a la plage con mis amigos."),
        m("assistant", "¡Qué bien, a la playa! ¿Hacía calor?"),
        m("user", "Sí, mucho calor. Comimos des glaces."),
        m("assistant", "¿Helados? ¡Qué rico! ¿De qué sabor?"),
        m("user", "De chocolate."),
    ], ["playa", "helado"]),
    ("mélange : demande et français dans la même conversation", "A0", [
        m("assistant", "Hola, ¿cómo te llamas?"),
        m("user", "Me llamo Tom. Je suis fatigué."),
        m("assistant", "Encantado, Tom. ¿Estás cansado? ¿Por qué?"),
        m("user", "Comment on dit j'ai mal dormi ?", ask=True),
        m("assistant", "Se dice «he dormido mal». Dilo tú: «He dormido mal»."),
        m("user", "He dormido mal."),
        m("assistant", "Vaya, lo siento. ¿Quieres un café?"),
    ], ["cansado", "dormir"]),
    ("aucun mot cherché (doit rendre une liste vide)", "A1", [
        m("assistant", "¿Dónde vives?"),
        m("user", "Vivo en Lyon, en Francia."),
        m("assistant", "¡Qué bonito! ¿Te gusta tu ciudad?"),
        m("user", "Sí, me gusta mucho."),
    ], []),
]


def essayer(llm, nom: str, niveau: str, historique: list[Message], attendus: list[str]) -> tuple[int, int]:
    print(f"\n== {nom} ({niveau})")
    debut = time.perf_counter()
    recap = llm.structured(messages_correction(historique, None, niveau), CorrectionsCherches)
    duree = time.perf_counter() - debut
    propres = mots_cherches_propres(recap.searched, historique)
    print(f"   {duree:.1f} s · {len(recap.searched)} rendus, {len(propres)} gardés")
    brutes = {b.lemma.strip().casefold(): b for b in recap.searched}
    avec_phrase = 0
    for mot in propres:
        print(f"   · {mot.fr!r} → {mot.es!r} (lemme {mot.lemma})")
        if mot.sentence:
            avec_phrase += 1
            print(f"       recto : {mot.sentence}\n       verso : {mot.sentence_fr}")
        else:
            brute = brutes.get(mot.lemma)
            raison = f"phrase écartée : {brute.sentence!r}" if brute and brute.sentence.strip() else "pas de phrase"
            print(f"       ⚠ {raison}")
    trouves = {mot.lemma for mot in propres}
    manquants = [lemme for lemme in attendus if lemme not in trouves]
    if manquants:
        print(f"   ⚠ lemmes attendus absents : {', '.join(manquants)}")
    en_trop = sorted(trouves - set(attendus))
    if en_trop:
        print(f"   (en plus de l'attendu : {', '.join(en_trop)})")
    for correction in recap.corrections:
        print(f"   correction : {correction.said!r} → {correction.corrected!r}")
    return avec_phrase, len(propres)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--fois", type=int, default=1, help="nombre de passages par conversation")
    args = parser.parse_args()
    llm = choisir_llm()
    total_phrase = total = 0
    try:
        for _ in range(args.fois):
            for nom, niveau, historique, attendus in CONVERSATIONS:
                phrase, mots = essayer(llm, nom, niveau, historique, attendus)
                total_phrase += phrase
                total += mots
    except LLMIndisponible as erreur:
        sys.exit(f"L'IA ne répond pas : {erreur}")
    print(f"\nBilan : {total_phrase} mots sur {total} ont une phrase gardée (recto et verso).")


if __name__ == "__main__":
    main()
