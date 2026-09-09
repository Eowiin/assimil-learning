"""
Tranche entre les deux causes possibles d'un clip signalé par asr-to-text.py :
des mots avalés par la reconnaissance, ou une diction lente légitime — une plaque
épelée, un numéro de téléphone, un compte à rebours.

Le signalement d'asr-to-text.py compare une durée à une longueur de texte : il voit
qu'il reste du temps inexpliqué, mais pas pourquoi. Les deux causes donnent le même
symptôme, et seule une oreille pouvait les séparer. Ce script fait faire l'écoute à
la machine : il ralentit le clip et le repasse en reconnaissance.

    normal   L087 S04 : « A ver, »
    ralenti  L087 S04 : « A ver. Uno, dos. »   -> deux mots avaient été perdus

Là où la lecture ralentie rend les mêmes mots, rien n'a été avalé et il n'y a rien à
réécouter. Là où elle en rend davantage, le script montre lesquels : la vérification
porte alors sur une phrase précise, déjà reconstituée.

La comparaison ignore l'accentuation, la ponctuation et les espaces — comme le
recoupement scan/audio de structure.py, opposer la ponctuation de deux transcriptions
ne dirait rien. Les espaces comptent tout autant : une plaque rendue `XH553` puis
`XH 553` est le même contenu réécrit autrement, et un découpage en mots la ferait
passer pour deux mots perdus. On compare donc les suites de caractères.

Le script ne réécrit jamais Resources/text/ : il signale, la relecture promeut.

    python3 tools/verify-clips.py               # tous les clips signalés
    python3 tools/verify-clips.py L087/S04      # seulement celui-là
    python3 tools/verify-clips.py --tempo 0.5   # ralentir davantage
"""

import argparse
import importlib.util
import json
import re
import subprocess
import sys
import tempfile
import unicodedata
from difflib import SequenceMatcher
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ASR = ROOT / "content" / "asr"
AUDIO = ROOT / "Resources" / "audio"

TEMPO = 0.6      # atempo ffmpeg : préserve la hauteur de la voix
MIN_ADDED = 3    # caractères ajoutés d'un bloc en dessous desquels c'est du bruit

def flagged_clips() -> list[tuple[str, str, str]]:
    """Les clips que asr-to-text.py signale, avec sa règle et son seuil à lui.

    On importe `suspicious` plutôt que d'en recopier le calcul : le seuil doit rester
    à un seul endroit, sinon les deux scripts finissent par ne plus signaler la même
    chose. Le nom du fichier contient un tiret, d'où l'import par chemin.
    """
    spec = importlib.util.spec_from_file_location("asr_to_text",
                                                  ROOT / "tools" / "asr-to-text.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    out = []
    for path in sorted(ASR.glob("L*.json")):
        asr = json.loads(path.read_text())
        for clip in asr["dialogue"] + asr["exercise"]:
            reason = module.suspicious(clip)
            if reason:
                out.append((path.stem, clip["file"], reason))
    return out

def fold(text: str) -> tuple[str, list[int]]:
    """Le texte réduit à ses lettres et chiffres, sans accents ni espaces.

    On garde en regard la position d'origine de chaque caractère, pour pouvoir
    remonter du diff au passage lisible qu'il désigne.
    """
    chars, origin = [], []
    for i, char in enumerate(text):
        decomposed = unicodedata.normalize("NFD", char.lower())
        for c in decomposed:
            if unicodedata.category(c) != "Mn" and c.isalnum():
                chars.append(c)
                origin.append(i)
    return "".join(chars), origin

def additions(before: str, after: str) -> list[str]:
    """Ce que la lecture ralentie apporte et que la normale n'avait pas.

    Un ou deux caractères isolés ne prouvent rien : la reconnaissance hésite sur un
    chiffre ou une voyelle (`Yujú` une fois, `youjú` l'autre) sans qu'un mot ait été
    perdu. Au-delà, c'est du texte que la première lecture n'avait pas entendu, et on
    le rend tel qu'il se lit plutôt qu'en caractères nus.
    """
    a, _ = fold(before)
    b, origin = fold(after)
    added = []
    for tag, _i1, _i2, j1, j2 in SequenceMatcher(None, a, b).get_opcodes():
        if tag in ("insert", "replace") and j2 - j1 >= MIN_ADDED:
            added.append(after[origin[j1]:origin[j2 - 1] + 1].strip())
    return added

def slow_down(src: Path, dest: Path, tempo: float) -> None:
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(src),
                    "-filter:a", f"atempo={tempo}", "-c:a", "aac", "-b:a", "64k",
                    str(dest)], check=True)

def transcribe(paths: list[Path]) -> dict[str, str]:
    """Une seule invocation pour tous les clips : le modèle ne se charge qu'une fois."""
    proc = subprocess.run(["swift", str(ROOT / "tools" / "transcribe-files.swift"),
                           *[str(p) for p in paths]],
                          capture_output=True, text=True)
    if proc.returncode != 0:
        print(proc.stderr, file=sys.stderr)
        raise SystemExit(1)
    return {r["path"]: r["text"] for r in json.loads(proc.stdout)}

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("clips", nargs="*", metavar="L087/S04",
                        help="par défaut, tous les clips signalés par asr-to-text.py")
    parser.add_argument("--tempo", type=float, default=TEMPO,
                        help=f"vitesse de la seconde lecture (défaut {TEMPO})")
    args = parser.parse_args()

    if not ASR.is_dir():
        print("content/asr absent — lancer tools/transcribe.swift d'abord", file=sys.stderr)
        return 1

    if args.clips:
        wanted = {(c.split("/")[0], Path(c.split("/")[1]).stem + ".m4a") for c in args.clips}
        clips = [(l, f, "demandé") for l, f in sorted(wanted)]
    else:
        clips = flagged_clips()
    if not clips:
        print("Aucun clip signalé.")
        return 0

    # Le texte de référence est celui qui est dans l'app, pas une nouvelle lecture.
    reference = {}
    for lesson in {c[0] for c in clips}:
        asr = json.loads((ASR / f"{lesson}.json").read_text())
        for clip in asr["dialogue"] + asr["exercise"]:
            reference[(lesson, clip["file"])] = clip["es"]

    with tempfile.TemporaryDirectory() as tmp:
        slowed = {}
        for lesson, file, _ in clips:
            src = AUDIO / lesson / file
            if not src.exists():
                print(f"{lesson}/{file} : introuvable", file=sys.stderr)
                continue
            dest = Path(tmp) / f"{lesson}_{file}"
            slow_down(src, dest, args.tempo)
            slowed[(lesson, file)] = dest

        texts = transcribe(list(slowed.values()))

    lost, confirm = [], []
    for lesson, file, reason in clips:
        key = (lesson, file)
        if key not in slowed:
            continue
        before = reference.get(key, "")
        after = texts.get(str(slowed[key]), "")
        added = additions(before, after)

        if not before:
            # Rien à comparer : la première lecture n'a rien rendu du tout. Ce que la
            # seconde entend peut aussi bien être un mot qu'un bruit de bouche.
            verdict, bucket = "? à confirmer", confirm
        elif added:
            verdict, bucket = "⚠ mots perdus", lost
        else:
            verdict, bucket = "✓ rien d'avalé", None

        print(f"{lesson} {file[:-4]:4s}  {verdict}   ({reason})")
        print(f"    normal   « {before} »")
        if bucket is not None:
            print(f"    ralenti  « {after} »")
            bucket.append(f"{lesson}/{file[:-4]}")
        if added:
            print(f"    apporté par la lecture ralentie : {', '.join(added)}")

    print()
    print(f"{len(clips)} clip(s) examiné(s) — "
          f"{len(clips) - len(lost) - len(confirm)} sans perte, "
          f"{len(lost)} avec des mots perdus, {len(confirm)} à confirmer.")
    if lost:
        print(f"À corriger dans Resources/text/ : {', '.join(lost)}")
    if confirm:
        print(f"À réécouter ({len(confirm)}) : {', '.join(confirm)}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
