"""Whisper avec ou sans amorce : la dernière réplique de l'IA aide-t-elle à comprendre ?

Le serveur peut donner à Whisper, comme amorce (`initial_prompt`), ce que l'IA
vient de dire (`ASSIMIL_WHISPER_CONTEXTE=1`, désactivé par défaut). L'idée : si
l'IA parle de « Jaén », Whisper reconnaît mieux « Jaén » dans la réponse. Le
risque : une amorce peut aussi faire « entendre » des mots de l'IA qui n'ont pas
été dits. Ce script tranche, sur tes enregistrements.

Le corpus est un fichier JSON, une entrée par enregistrement :

    [{"audio": "tour1.m4a",
      "contexte": "¡Hola! ¿Qué has comido hoy?",
      "attendu": "He comido jamón de Jaén."}, …]

- `audio` : relatif au fichier du corpus, ou absolu ;
- `contexte` : la réplique de l'IA à laquelle tu répondais ;
- `attendu` : ce que tu as vraiment dit, écrit à la main. C'est la référence.

`essais/appel.py` écrit ce fichier pour toi (`essais/sortie/corpus-whisper.json`),
avec le contexte et ce que Whisper a compris ; il ne reste qu'à remplir `attendu`.
Une entrée sans `attendu` est ignorée.

    uv run python essais/whisper_contexte.py essais/sortie/corpus-whisper.json

Les mots se comparent sans casse, sans ponctuation et sans accents écrits, comme
dans le récapitulatif de l'app (`WordDiff`).
"""

from __future__ import annotations

import argparse
import json
import sys
import unicodedata
from difflib import SequenceMatcher
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from app.moteurs import decoder_16k, transcrire  # noqa: E402


def mots(phrase: str) -> list[str]:
    """La même normalisation que `WordDiff.key` dans l'app."""
    sortie = []
    for mot in phrase.split():
        plie = unicodedata.normalize("NFD", mot.casefold())
        cle = "".join(c for c in plie if c.isalnum() and not unicodedata.combining(c))
        if cle:
            sortie.append(cle)
    return sortie


def justes(attendu: list[str], entendu: list[str]) -> int:
    """Les mots attendus retrouvés, dans l'ordre (plus longue sous-suite commune)."""
    return sum(b.size for b in SequenceMatcher(None, attendu, entendu, autojunk=False).get_matching_blocks())


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("corpus", type=Path, help="le fichier JSON des enregistrements")
    p.add_argument("--whisper", default="large-v3-turbo")
    p.add_argument("--appareil", default="cuda", choices=["cuda", "cpu"])
    args = p.parse_args()

    entrees = json.loads(args.corpus.read_text())
    pretes = [e for e in entrees if e.get("attendu", "").strip()]
    if len(pretes) < len(entrees):
        print(f"{len(entrees) - len(pretes)} entrée(s) sans « attendu », ignorée(s).")
    if not pretes:
        p.error("aucune entrée avec « attendu » : écris ce que tu as vraiment dit")

    from faster_whisper import WhisperModel
    calcul = "float16" if args.appareil == "cuda" else "int8"
    print(f"Chargement de Whisper {args.whisper}…", flush=True)
    whisper = WhisperModel(args.whisper, device=args.appareil, compute_type=calcul)

    total = {"sans": 0, "avec": 0}
    attendus = 0
    en_trop = {"sans": 0, "avec": 0}
    mieux = pire = 0
    detail = []
    for entree in pretes:
        chemin = Path(entree["audio"]).expanduser()
        if not chemin.is_absolute():
            chemin = args.corpus.parent / chemin
        audio = decoder_16k(chemin.read_bytes())
        ref = mots(entree["attendu"])
        rendu = {"sans": transcrire(whisper, audio),
                 "avec": transcrire(whisper, audio, entree.get("contexte") or None)}
        score = {}
        for facon, texte in rendu.items():
            entendu = mots(texte)
            score[facon] = justes(ref, entendu)
            total[facon] += score[facon]
            en_trop[facon] += len(entendu) - score[facon]
        attendus += len(ref)
        mieux += score["avec"] > score["sans"]
        pire += score["avec"] < score["sans"]
        detail.append({"audio": str(chemin), "attendu": entree["attendu"], **rendu,
                       "justes": score, "mots": len(ref)})
        if rendu["sans"] != rendu["avec"]:
            print(f"\n{chemin.name}\n  attendu : {entree['attendu']}\n"
                  f"  sans    : {rendu['sans']}  ({score['sans']}/{len(ref)})\n"
                  f"  avec    : {rendu['avec']}  ({score['avec']}/{len(ref)})")

    print("\n— Bilan " + "—" * 55)
    print(f"{len(pretes)} enregistrements, {attendus} mots attendus")
    for facon in ("sans", "avec"):
        print(f"  {facon} amorce : {total[facon] / attendus:.1%} de mots justes "
              f"({total[facon]}/{attendus}), {en_trop[facon]} mot(s) entendu(s) à tort")
    print(f"  L'amorce fait mieux sur {mieux} enregistrement(s), moins bien sur {pire}.")
    sortie = args.corpus.with_name(args.corpus.stem + "-bilan.json")
    sortie.write_text(json.dumps({"justes": total, "attendus": attendus, "en_trop": en_trop,
                                  "detail": detail}, ensure_ascii=False, indent=2))
    print(f"Détail : {sortie}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
