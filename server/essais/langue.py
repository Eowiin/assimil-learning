"""La langue (spaCy), sans le serveur : les lemmes d'un texte et sa couverture.

Les « mots connus » sont les N premiers lemmes du lexique de l'app
(`Resources/curriculum/es/lexicon.json`), comme le serait le vocabulaire d'un
apprenant qui en connaîtrait N. Chaque mot est affiché avec son lemme quand il
diffère ; les inconnus sont marqués d'un astérisque. C'est ce qui dira si les
lemmes de spaCy en direct tombent bien sur les clés du lexique.

    uv run python essais/langue.py                       # les phrases d'exemple, N = 1500
    uv run python essais/langue.py -n 800
    uv run python essais/langue.py "Dímelo mañana, por favor."
    uv run python essais/langue.py -f texte.txt          # un texte entier (une réplique de l'IA…)
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.langue.analyse import MODELE, Spacy, installe  # noqa: E402

LEXIQUE = Path(__file__).resolve().parents[2] / "Resources/curriculum/es/lexicon.json"

EXEMPLES = [
    "¡Hola! ¿Qué tal el fin de semana? Yo fui a la playa con mis amigos.",
    "Cómpralo mañana y dímelo, que no quiero olvidarlo.",
    "Siéntate aquí y cuéntame qué pasó con María en Sevilla.",
    "Vino tarde y bebió vino: tenía 25 años y mucha sed.",
    "Si tuviera más tiempo, aprendería a tocar la guitarra.",
    "El ayuntamiento ha aprobado una normativa que restringe el tráfico rodado.",
]


def afficher(langue: Spacy, texte: str, connus: set[str]) -> None:
    debut = time.perf_counter()
    mots = langue.mots(texte)
    couverture = langue.couverture(texte, connus)
    duree = time.perf_counter() - debut
    rendu = []
    for m in mots:
        mot = m.forme if m.lemme == m.forme else f"{m.forme}→{m.lemme}"
        rendu.append(mot if m.lemme in connus or m.forme in connus else f"{mot}*")
    print(texte)
    print("  " + " ".join(rendu))
    print(f"  couverture {couverture.taux:.0%} sur {couverture.mots} mots"
          f"{', inconnus : ' + ', '.join(couverture.inconnus) if couverture.inconnus else ''}"
          f"  ({duree * 1000:.0f} ms)\n")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("texte", nargs="*", help="des phrases à analyser (sinon, les exemples)")
    p.add_argument("-n", type=int, default=1500, help="combien de lemmes du lexique sont connus")
    p.add_argument("-f", "--fichier", type=Path, help="un fichier texte à analyser en entier")
    args = p.parse_args()

    if not installe():
        sys.exit(f"{MODELE} n'est pas installé : lancer `uv sync` dans server/.")
    lexique = json.loads(LEXIQUE.read_text(encoding="utf-8"))["lemmas"]
    connus = {x["lemma"] for x in lexique if x["rank"] <= args.n}

    debut = time.perf_counter()
    langue = Spacy()
    print(f"{MODELE} chargé en {time.perf_counter() - debut:.1f} s ; {len(connus)} lemmes connus.\n")

    textes = ([args.fichier.read_text(encoding="utf-8")] if args.fichier
              else [" ".join(args.texte)] if args.texte else EXEMPLES)
    for texte in textes:
        afficher(langue, texte, connus)


if __name__ == "__main__":
    main()
