"""Les voix de l'étape 5c, côte à côte : Voxtral (Mistral), Pocket TTS (standard et
24 couches) et XTTS v2, sur les mêmes phrases.

Chaque voix dit :
- **des mots seuls**, comme sur une carte du lexique : Pocket est connu pour couper
  les phrases très courtes (issue #174 du projet) ;
- **des phrases du bloc 2** et des exemples de micro-leçon ;
- **des phrases chargées en θ, jota, r et v**, les sons d'un francophone.

Pour chacune : le temps de la synthèse, la durée de l'audio, le facteur temps réel
(temps de synthèse / durée : sous 1, plus vite que le temps réel), et la taille du
.m4a que recevrait l'app. Les fichiers vont dans `essais/sortie/voix/<voix>/`, à
écouter. Ce qu'il faut regarder à l'oreille : un mot seul entier ? le θ de « cerveza »,
la jota de « jamón » ? une phrase naturelle ou récitée ?

    uv run python essais/voix.py                           # les quatre voix
    uv run python essais/voix.py --voix voxtral pocket     # quelques-unes
    uv run python essais/voix.py --sans-fichiers           # les chiffres seulement

Voxtral demande `MISTRAL_API_KEY` (la clé de l'IA). XTTS prend la carte graphique,
avec `ASSIMIL_VOIX` s'il y a une voix clonée. Une voix qui ne se charge pas est
signalée et sautée.
"""

from __future__ import annotations

import argparse
import io
import os
import statistics
import sys
import time
import wave
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.voix import PocketTTS, VoxtralTTS, XTTSLocal, en_m4a

SORTIE = Path(__file__).resolve().parent / "sortie" / "voix"

PHRASES = {
    "mot seul": ["perro", "cerveza", "jamón", "ahora", "¿Qué?", "Sí."],
    "bloc 2": [
        "Cada mañana, Lucía toma el autobús para ir al trabajo.",
        "El mercado está cerca de la plaza, al lado de la farmacia.",
        "Me gustaría reservar una mesa para dos personas esta noche.",
        "Si tuviera más tiempo, aprendería a tocar la guitarra.",
    ],
    "sons": [
        "Cinco zapatos azules en la cocina.",             # θ
        "El joven Jorge juega en el jardín.",             # jota
        "El perro de Roberto corre por la carretera.",    # r roulé et battu
        "Vamos a ver la vaca en el valle.",               # b/v
    ],
}


def construire(nom: str):
    env = os.environ
    if nom == "voxtral":
        return VoxtralTTS(cle=env.get("MISTRAL_API_KEY", ""),
                          voix=env.get("ASSIMIL_VOXTRAL_VOIX", "voice_483"))
    if nom == "pocket":
        return PocketTTS(langue="spanish")
    if nom == "pocket-24":
        return PocketTTS(langue="spanish_24l")
    if nom == "xtts":
        voix = env.get("ASSIMIL_VOIX")
        return XTTSLocal(appareil=env.get("ASSIMIL_APPAREIL", "cuda"),
                         voix=Path(voix).expanduser() if voix else None)
    raise ValueError(nom)


def duree_wav(donnees: bytes) -> float | None:
    try:
        with wave.open(io.BytesIO(donnees)) as wav:
            return wav.getnframes() / wav.getframerate()
    except (wave.Error, EOFError):
        return None


def essayer(nom: str, fichiers: bool) -> dict | None:
    print(f"\n== {nom}")
    debut = time.perf_counter()
    try:
        tts = construire(nom)
    except Exception as erreur:  # noqa: BLE001 — on passe à la voix suivante
        print(f"   pas chargée : {erreur}")
        return None
    print(f"   {tts.nom}, chargée en {time.perf_counter() - debut:.1f} s")
    # Un premier passage à vide : XTTS et Pocket préparent leur code au premier appel.
    tts.dire("Hola.")
    dossier = SORTIE / nom
    if fichiers:
        dossier.mkdir(parents=True, exist_ok=True)
    rtf, synthese = [], []
    for groupe, phrases in PHRASES.items():
        print(f"   -- {groupe}")
        for i, phrase in enumerate(phrases):
            debut = time.perf_counter()
            try:
                audio = tts.dire(phrase)
            except Exception as erreur:  # noqa: BLE001
                print(f"   {phrase:<62} ÉCHEC : {erreur}")
                continue
            temps = time.perf_counter() - debut
            m4a = en_m4a(audio)
            duree = duree_wav(audio.donnees) if audio.format == "wav" else None
            synthese.append(temps)
            facteur = ""
            if duree:
                rtf.append(temps / duree)
                facteur = f"audio {duree:4.1f} s · ×{temps / duree:.2f}"
            print(f"   {phrase:<62} {temps:5.2f} s · {facteur} · {len(m4a) // 1024} Ko")
            if fichiers:
                (dossier / f"{groupe.replace(' ', '-')}-{i + 1}.m4a").write_bytes(m4a)
    if not synthese:
        return None
    return {"voix": nom, "moyenne": statistics.mean(synthese), "pire": max(synthese),
            "rtf": statistics.mean(rtf) if rtf else None}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--voix", nargs="+", default=["voxtral", "pocket", "pocket-24", "xtts"],
                        choices=["voxtral", "pocket", "pocket-24", "xtts"])
    parser.add_argument("--sans-fichiers", action="store_true")
    args = parser.parse_args()
    bilans = [b for nom in args.voix if (b := essayer(nom, not args.sans_fichiers))]
    print("\n== Bilan")
    for b in bilans:
        rtf = f"×{b['rtf']:.2f}" if b["rtf"] is not None else "—"
        print(f"   {b['voix']:<10} moyenne {b['moyenne']:.2f} s · pire {b['pire']:.2f} s · temps réel {rtf}")
    if not args.sans_fichiers:
        print(f"\nÀ écouter : {SORTIE}")


if __name__ == "__main__":
    main()
