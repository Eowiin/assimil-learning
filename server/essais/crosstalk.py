"""Le crosstalk : garder le français d'une prise mélangée, sans perdre l'espagnol.

Un débutant (A0, A1) répond parfois en français : « Quiero un… comment on dit… un
couteau ». Le serveur impose l'espagnol à Whisper : un passage en français est
traduit ou écorché sans prévenir, puis jugé comme une production. Ce script mesure,
sur tes prises, ce que font quatre façons de transcrire :

- `es` : Whisper, l'espagnol imposé (le serveur aujourd'hui, la référence) ;
- `multi` : Whisper, la langue détectée morceau par morceau (`multilingual=True`) ;
- `amorce` : Whisper, la langue détectée, avec une amorce bilingue (`initial_prompt`)
  qui annonce un apprenant français parlant espagnol ;
- `voxtral` : la transcription de Mistral, par son API, sans langue imposée. Ta voix
  part chez Mistral ; il faut `MISTRAL_API_KEY`, sinon ce candidat est sauté ;
- `double` : Whisper deux fois, l'espagnol imposé puis le français imposé, et l'IA
  (Mistral, en texte seulement) reconstitue la prise à partir des deux, le français
  entre crochets. Il faut aussi `MISTRAL_API_KEY`.

Les prises sont dans `essais/sortie/crosstalk/`, nommées `01.m4a` à `20.m4a` (toute
extension lisible par ffmpeg). Les phrases attendues sont dans `PHRASES`, plus bas :
entre crochets, la part en français. Si tu n'as pas dit exactement la phrase, corrige-la
dans `attendu.json`, à côté des prises : `{"10": "Quiero un… [comment on dit…] …"}`.

    uv run python essais/crosstalk.py
    uv run python essais/crosstalk.py --candidats es,multi      # sans Voxtral

Pour chaque candidat, le bilan dit :
- **espagnol** : la part des mots espagnols attendus retrouvés, sur toutes les prises ;
- **bascules** : les prises en espagnol pur dont moins de la moitié des mots est
  retrouvée (l'accent pris pour du français, ou une traduction). Il en faut zéro ;
- **français gardé** : les prises avec du français où au moins la moitié des mots
  français sont rendus tels quels (pas traduits, pas perdus) ;
- le temps moyen d'une prise.

La règle, fixée avant de mesurer : un candidat est retenu s'il n'a aucune bascule,
perd au plus 2 points d'espagnol par rapport à `es`, et garde le français dans au
moins 80 % des prises qui en ont. Sinon, ce sera un bouton « Je ne sais pas le dire ».

Les mots se comparent sans casse, ponctuation ni accents écrits, comme dans l'app.
Les « euh » ne comptent pas : Whisper les laisse tomber.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from app.moteurs import decoder_16k, transcrire  # noqa: E402
from whisper_contexte import justes, mots  # noqa: E402  (le dossier du script est dans le chemin)

# Entre crochets, la part en français.
PHRASES = {
    1: "Hola, quiero un café con leche, por favor.",
    2: "Vivo en Francia y aprendo español.",
    3: "¿Cuánto cuesta la habitación por una noche?",
    4: "Mañana voy a la playa con mis amigos.",
    5: "No entiendo, ¿puede repetir más despacio?",
    6: "Tengo hambre, ¿dónde está el restaurante?",
    7: "[Je ne sais pas comment on dit ça.]",
    8: "[Attends, je cherche le mot.]",
    9: "[Euh… je n'ai pas compris la question.]",
    10: "Quiero un… [comment on dit… un couteau], por favor.",
    11: "Necesito una [fourchette] para comer.",
    12: "¿Dónde está la [gare]? Tengo que ir a Madrid.",
    13: "Mi hermano es… [euh… plombier].",
    14: "Voy a comprar [pain] y queso.",
    15: "La habitación es muy… [bruyante], no puedo dormir.",
    16: "Quiero pagar con… [la carte bleue].",
    17: "Me gusta mucho… [comment dire… le printemps].",
    18: "[Je sais pas trop], pero creo que sí.",
    19: "[Attends…] sí, sí, quiero la sopa.",
    20: "[Comment on dit « réserver »…] quiero reservar una mesa.",
}

# Sans mot des prises, pour ne pas souffler la réponse.
AMORCE = ("Un apprenant français parle espagnol et dit parfois quelques mots en français. "
          "Necesito una… comment dire… une serviette, gracias.")

CONSIGNE_DOUBLE = """Un apprenant français débutant parle espagnol et glisse parfois des \
mots ou des phrases en français. Voici deux transcriptions automatiques de la même prise : \
l'une forcée en espagnol, l'autre forcée en français. Chaque transcription traduit ou \
déforme ce qui n'est pas dans sa langue.

Reconstitue ce que l'apprenant a réellement dit, dans l'ordre, chaque passage dans la \
langue où il l'a dit. Mets les passages en français entre crochets. Ne corrige pas les \
fautes d'espagnol et n'ajoute rien. Réponds seulement par la transcription."""

HESITATIONS = {"euh", "heu", "eh", "em", "mmm"}


@dataclass
class Prise:
    numero: int
    phrase: str
    espagnol: list[str]
    francais: list[str]

    @property
    def attendu(self) -> str:
        return self.phrase.replace("[", "").replace("]", "")

    @property
    def categorie(self) -> str:
        if not self.francais:
            return "espagnol"
        return "français" if not self.espagnol else "mélangée"


def decouper(numero: int, phrase: str) -> Prise:
    """Les mots espagnols (hors crochets) et français (entre crochets)."""
    francais = " ".join(re.findall(r"\[([^\]]*)\]", phrase))
    espagnol = re.sub(r"\[[^\]]*\]", " ", phrase)
    garder = lambda texte: [m for m in mots(texte) if m not in HESITATIONS]  # noqa: E731
    return Prise(numero, phrase, garder(espagnol), garder(francais))


def trouver_audio(dossier: Path, numero: int) -> Path | None:
    for nom in (f"{numero:02d}", str(numero)):
        trouves = sorted(p for p in dossier.glob(f"{nom}.*") if p.suffix != ".json")
        if trouves:
            return trouves[0]
    return None


# --- Les candidats -----------------------------------------------------------------

WHISPER = ("es", "multi", "amorce", "double")  # ceux qui chargent Whisper

def whisper_detecte(whisper, audio, multilingue: bool, amorce: str | None) -> tuple[str, str]:
    segments, info = whisper.transcribe(audio, language=None, multilingual=multilingue,
                                        beam_size=5, vad_filter=True, initial_prompt=amorce)
    segments = list(segments)
    texte = " ".join(s.text.strip() for s in segments).strip()
    # La langue de chaque morceau, quand faster-whisper la donne ; sinon celle de la prise.
    langues = [getattr(s, "language", None) for s in segments]
    langues = [lang for lang in langues if lang] or [info.language]
    return texte, "/".join(dict.fromkeys(langues))


class Voxtral:
    """La transcription de Mistral (`/v1/audio/transcriptions`), sans langue imposée."""

    def __init__(self, cle: str, modele: str):
        import httpx
        self.modele = modele
        self.client = httpx.Client(base_url="https://api.mistral.ai", timeout=60,
                                   headers={"Authorization": f"Bearer {cle}"})

    def transcrire(self, audio) -> tuple[str, str]:
        from app.voix import wav_16_bits
        reponse = self.client.post("/v1/audio/transcriptions", data={"model": self.modele},
                                   files={"file": ("prise.wav", wav_16_bits(audio, 16000), "audio/wav")})
        if reponse.status_code != 200:
            raise RuntimeError(f"Voxtral répond {reponse.status_code} : {reponse.text[:200]}")
        corps = reponse.json()
        return corps.get("text", "").strip(), corps.get("language") or "?"


def montrer_cuda() -> None:
    """Whisper (ctranslate2) cherche libcublas et libcudnn dans `LD_LIBRARY_PATH`. Les
    paquets de NVIDIA installés avec torch les ont, mais ailleurs : on ajoute leurs
    dossiers, puis le script se relance, le chargeur ne relisant la variable qu'au
    démarrage. Rien à faire si elle les contient déjà."""
    dossiers = []
    for paquet in ("nvidia.cublas.lib", "nvidia.cudnn.lib"):
        try:
            module = __import__(paquet, fromlist=["_"])
        except ImportError:
            continue
        dossiers += [str(d) for d in getattr(module, "__path__", [])]
    actuel = [d for d in os.environ.get("LD_LIBRARY_PATH", "").split(":") if d]
    manquants = [d for d in dossiers if d not in actuel]
    if manquants:
        os.environ["LD_LIBRARY_PATH"] = ":".join(manquants + actuel)
        os.execv(sys.executable, [sys.executable, *sys.argv])


def verifier_whisper(whisper) -> None:
    """Une seconde de bruit, sans filtre de silence : si la carte graphique ne charge
    pas (`libcublas`, `libcudnn`), on le sait avant la première prise, au lieu de
    compter vingt erreurs comme des transcriptions vides."""
    import numpy
    bruit = numpy.random.default_rng(0).normal(0, 0.01, 16000).astype(numpy.float32)
    try:
        segments, _ = whisper.transcribe(bruit, language="es", vad_filter=False)
        list(segments)
    except Exception as erreur:
        sys.exit(f"Whisper ne tourne pas : {erreur}\n"
                 f"LD_LIBRARY_PATH = {os.environ.get('LD_LIBRARY_PATH', '(vide)')}\n"
                 "Pour comparer sans la carte graphique : --appareil cpu (bien plus lent).")


def decrire(chemin: Path) -> str:
    """Les pistes du fichier selon ffprobe, pour comprendre une prise qui ne décode rien."""
    import subprocess
    sortie = subprocess.run(["ffprobe", "-v", "error", "-show_entries",
                             "format=format_name,duration,size:stream=index,codec_type,codec_name,"
                             "sample_rate,channels,duration", "-of", "compact", str(chemin)],
                            capture_output=True, text=True)
    return (sortie.stdout + sortie.stderr).strip().replace("\n", "\n  ")


def niveau(audio) -> tuple[float, float]:
    """La durée de la prise (s) et son niveau de crête (dB, 0 au maximum)."""
    import numpy
    if len(audio) == 0:
        return 0.0, -120.0
    crete = float(numpy.max(numpy.abs(audio)))
    return len(audio) / 16000, 20 * numpy.log10(max(crete, 1e-6))


def double(whisper, llm, audio) -> tuple[str, str]:
    """L'espagnol imposé, le français imposé, puis l'IA reconstitue la prise."""
    espagnol = transcrire(whisper, audio)
    segments, _ = whisper.transcribe(audio, language="fr", beam_size=5, vad_filter=True)
    francais = " ".join(s.text.strip() for s in segments).strip()
    texte = llm.chat([{"role": "system", "content": CONSIGNE_DOUBLE},
                      {"role": "user", "content": f"Forcée en espagnol : {espagnol}\n"
                                                  f"Forcée en français : {francais}"}],
                     temperature=0)
    return texte, "es+fr"


def charger_candidats(noms: list[str], args) -> dict:
    candidats = {}
    cle = os.environ.get("MISTRAL_API_KEY", "")
    if any(n in noms for n in WHISPER):
        from faster_whisper import WhisperModel
        calcul = "float16" if args.appareil == "cuda" else "int8"
        print(f"Chargement de Whisper {args.whisper}…", flush=True)
        whisper = WhisperModel(args.whisper, device=args.appareil, compute_type=calcul)
        verifier_whisper(whisper)
        if "es" in noms:
            candidats["es"] = lambda audio: (transcrire(whisper, audio), "es")
        if "multi" in noms:
            candidats["multi"] = lambda audio: whisper_detecte(whisper, audio, True, None)
        if "amorce" in noms:
            candidats["amorce"] = lambda audio: whisper_detecte(whisper, audio, True, AMORCE)
        if "double" in noms:
            if cle:
                from app.llm import choisir_llm
                llm = choisir_llm()
                candidats["double"] = lambda audio: double(whisper, llm, audio)
            else:
                print("Double sauté : pas de MISTRAL_API_KEY.")
    if "voxtral" in noms:
        if cle:
            candidats["voxtral"] = Voxtral(cle, args.voxtral_modele).transcrire
        else:
            print("Voxtral sauté : pas de MISTRAL_API_KEY.")
    return candidats


# --- La mesure ---------------------------------------------------------------------

def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--dossier", type=Path, default=Path("essais/sortie/crosstalk"))
    p.add_argument("--candidats", default="es,multi,amorce,voxtral,double")
    p.add_argument("--whisper", default="large-v3-turbo")
    p.add_argument("--appareil", default="cuda", choices=["cuda", "cpu"])
    p.add_argument("--voxtral-modele", default="voxtral-mini-latest")
    args = p.parse_args()

    phrases = dict(PHRASES)
    corrections = args.dossier / "attendu.json"
    if corrections.exists():
        phrases.update({int(k): v for k, v in json.loads(corrections.read_text()).items()})
    prises = []
    for numero, phrase in sorted(phrases.items()):
        chemin = trouver_audio(args.dossier, numero)
        if chemin is None:
            print(f"Prise {numero:02d} introuvable dans {args.dossier}, ignorée.")
        else:
            prises.append((decouper(numero, phrase), chemin))
    if not prises:
        p.error(f"aucune prise dans {args.dossier} (01.m4a … 20.m4a)")

    noms = args.candidats.split(",")
    if args.appareil == "cuda" and any(n in noms for n in WHISPER):
        montrer_cuda()
    candidats = charger_candidats(noms, args)
    bilan = {nom: {"es_justes": 0, "es_attendus": 0, "bascules": [], "fr_gardes": [],
                   "avec_fr": 0, "secondes": 0.0, "erreurs": []} for nom in candidats}
    muettes = []
    detail = []
    for prise, chemin in prises:
        audio = decoder_16k(chemin.read_bytes())
        duree_prise, crete = niveau(audio)
        print(f"\n{prise.numero:02d} ({prise.categorie}, {chemin.name}, {duree_prise:.1f} s, "
              f"crête {crete:.0f} dB)  {prise.attendu}")
        if duree_prise == 0:
            print("  Aucun son décodé : ignorée. Ce que ffmpeg voit dans le fichier :")
            print("  " + decrire(chemin))
            muettes.append(prise.numero)
            continue
        if duree_prise < 0.5 or crete < -40:
            print("  Prise vide ou presque muette : ignorée. Réenregistre-la.")
            muettes.append(prise.numero)
            continue
        ligne = {"prise": prise.numero, "categorie": prise.categorie, "attendu": prise.phrase,
                 "duree": round(duree_prise, 1), "crete_db": round(crete)}
        for nom, transcrire_prise in candidats.items():
            debut = time.perf_counter()
            try:
                texte, langue = transcrire_prise(audio)
            except Exception as erreur:  # un candidat en échec ne doit pas arrêter les autres
                print(f"  {nom:8} en erreur : {erreur}")
                bilan[nom]["erreurs"].append(prise.numero)
                ligne[nom] = {"erreur": str(erreur)}
                continue
            duree = time.perf_counter() - debut
            entendu = mots(texte)
            es = justes(prise.espagnol, entendu)
            fr = justes(prise.francais, entendu)
            b = bilan[nom]
            b["es_justes"] += es
            b["es_attendus"] += len(prise.espagnol)
            b["secondes"] += duree
            if prise.categorie == "espagnol" and es < len(prise.espagnol) / 2:
                b["bascules"].append(prise.numero)
            if prise.francais:
                b["avec_fr"] += 1
                if fr >= len(prise.francais) / 2:
                    b["fr_gardes"].append(prise.numero)
            scores = f"es {es}/{len(prise.espagnol)}" + (f", fr {fr}/{len(prise.francais)}"
                                                       if prise.francais else "")
            print(f"  {nom:8} [{langue}] {texte}  ({scores})")
            ligne[nom] = {"texte": texte, "langue": langue, "es": es, "fr": fr,
                          "secondes": round(duree, 2)}
        detail.append(ligne)

    print("\n— Bilan " + "—" * 70)
    mesurees = len(prises) - len(muettes)
    print(f"{mesurees} prises mesurées"
          + (f", {len(muettes)} muettes ignorées ({', '.join(f'{n:02d}' for n in muettes)})"
             if muettes else ""))
    print(f"  {'':8} {'espagnol':>10} {'bascules':>9} {'français gardé':>15} {'temps':>7}")
    reference = None
    if "es" in bilan and bilan["es"]["es_attendus"] and not bilan["es"]["erreurs"]:
        reference = bilan["es"]["es_justes"] / bilan["es"]["es_attendus"]
    retenus = []
    for nom, b in bilan.items():
        taux_es = b["es_justes"] / b["es_attendus"] if b["es_attendus"] else 0
        taux_fr = len(b["fr_gardes"]) / b["avec_fr"] if b["avec_fr"] else 0
        print(f"  {nom:8} {taux_es:>10.1%} {len(b['bascules']):>9} "
              f"{len(b['fr_gardes']):>6}/{b['avec_fr']} ({taux_fr:.0%}) "
              f"{b['secondes'] / max(mesurees - len(b['erreurs']), 1):>6.2f}s"
              + (f"   en erreur sur {len(b['erreurs'])} prise(s)" if b["erreurs"] else "")
              + (f"   bascules : {', '.join(f'{n:02d}' for n in b['bascules'])}" if b["bascules"] else ""))
        if (nom != "es" and not b["erreurs"] and not b["bascules"] and taux_fr >= 0.8
                and reference is not None and taux_es >= reference - 0.02):
            retenus.append(nom)
    if reference is None:
        print("\nPas de verdict : il faut la référence `es`, mesurée sans erreur.")
    else:
        print("\nRetenu(s) : " + (", ".join(retenus) if retenus
                                  else "aucun. Ce sera le bouton « Je ne sais pas le dire »."))

    sortie = args.dossier / "bilan.json"
    sortie.write_text(json.dumps({"bilan": bilan, "retenus": retenus, "detail": detail},
                                 ensure_ascii=False, indent=2))
    print(f"Détail : {sortie}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
