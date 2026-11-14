"""Converser avec le serveur comme le fera l'app : ouverture, tours, récapitulatif.

    uv run python essais/appel.py                          # au clavier
    uv run python essais/appel.py tour1.m4a tour2.m4a      # des enregistrements, puis au clavier
    uv run python essais/appel.py --serveur https://nom-du-pc.reseau.ts.net

Les répliques parlées de l'IA vont dans essais/sortie/appel-NN.m4a. Le serveur ne
garde rien : c'est ce script qui tient l'historique, comme l'app.

Les tours enregistrés sont notés dans essais/sortie/corpus-whisper.json, avec la
réplique de l'IA qui les précédait : il suffit d'y écrire ce que tu as vraiment
dit (« attendu ») pour le donner à essais/whisper_contexte.py.
"""

from __future__ import annotations

import argparse
import base64
import json
import sys
import time
from pathlib import Path

import httpx


def enregistrer(reponse: dict, dossier: Path, numero: int) -> Path:
    fichier = dossier / f"appel-{numero:02d}.m4a"
    fichier.write_bytes(base64.b64decode(reponse["audio"]))
    return fichier


def temps(t: dict, aller_retour: float) -> str:
    etapes = [f"{nom} {t[cle]:.2f} s" for cle, nom in
              (("listen", "écoute"), ("think", "IA"), ("speak", "voix")) if t.get(cle) is not None]
    return " · ".join(etapes) + f" → aller-retour {aller_retour:.2f} s"


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("audio", nargs="*", type=Path, help="des tours enregistrés (wav, m4a, mp3)")
    p.add_argument("--serveur", default="http://localhost:8000")
    p.add_argument("--sujet", help="le sujet proposé à l'IA pour ouvrir")
    p.add_argument("--sortie", type=Path, default=Path("essais/sortie"))
    args = p.parse_args()
    args.sortie.mkdir(parents=True, exist_ok=True)

    client = httpx.Client(base_url=args.serveur, timeout=180)
    historique: list[dict] = []

    def appeler(route: str, **kwargs) -> dict | None:
        debut = time.perf_counter()
        reponse = client.post(route, **kwargs)
        duree = time.perf_counter() - debut
        if reponse.status_code != 200:
            print(f"!! {reponse.status_code} : {reponse.json().get('detail', reponse.text)}")
            return None
        corps = reponse.json()
        corps["_aller_retour"] = duree
        return corps

    ouverture = appeler("/conversation/start", json={"topic": args.sujet})
    if ouverture is None:
        return 1
    historique.append({"role": "assistant", "content": ouverture["reply"]})
    print(f"IA       : {ouverture['reply']}")
    print(f"Temps    : {temps(ouverture['timings'], ouverture['_aller_retour'])}")
    print(f"Écouter  : {enregistrer(ouverture, args.sortie, 0)}")

    def tours():
        yield from args.audio
        while True:
            try:
                ligne = input("\nTon tour (phrase, ou chemin d'un audio ; vide pour finir) : ").strip()
            except EOFError:
                return
            if not ligne:
                return
            chemin = Path(ligne.strip("'\""))
            yield chemin if chemin.suffix and chemin.exists() else ligne

    corpus_fichier = args.sortie / "corpus-whisper.json"
    corpus = json.loads(corpus_fichier.read_text()) if corpus_fichier.exists() else []

    for numero, tour in enumerate(tours(), start=1):
        contexte = historique[-1]["content"]
        donnees = {"history": json.dumps(historique, ensure_ascii=False)}
        if isinstance(tour, Path):
            corps = appeler("/conversation/turn", data=donnees,
                            files={"audio": (tour.name, tour.read_bytes())})
        else:
            corps = appeler("/conversation/turn", data={**donnees, "text": tour})
        if corps is None:
            continue
        historique += [{"role": "user", "content": corps["heard"]},
                       {"role": "assistant", "content": corps["reply"]}]
        if isinstance(tour, Path):
            corpus.append({"audio": str(tour.resolve()), "contexte": contexte,
                           "entendu": corps["heard"], "attendu": ""})
            corpus_fichier.write_text(json.dumps(corpus, ensure_ascii=False, indent=2))
        print(f"Toi      : {corps['heard']}")
        print(f"IA       : {corps['reply']}")
        print(f"Temps    : {temps(corps['timings'], corps['_aller_retour'])}")
        print(f"Écouter  : {enregistrer(corps, args.sortie, numero)}")

    print("\n— Récapitulatif " + "—" * 47)
    bilan = appeler("/conversation/review", json={"history": historique})
    if bilan is None:
        return 1
    if not bilan["corrections"]:
        print("Aucune faute relevée.")
    for c in bilan["corrections"]:
        print(f"\n  Tu as dit : {c['said']}\n  Correct   : {c['corrected']}\n  Pourquoi  : {c['explanation']}")
    print(f"\n({bilan['_aller_retour']:.1f} s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
