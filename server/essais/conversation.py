"""Essai de la conversation, sur le PC, sans l'app.

Chaque enregistrement donné est un tour de parole d'une même conversation :

    ta voix ─▶ Whisper large-v3-turbo ─▶ IA (Ollama) ─▶ XTTS v2 ─▶ réponse .wav

Pour chaque tour, le script affiche ce que Whisper a compris, la réponse de l'IA,
le temps de chaque étape, et enregistre la réponse parlée. Le bilan final donne
la mémoire graphique, modèles chargés ensemble. Rien n'est gardé ailleurs que
dans le dossier de sortie.

    uv run --group essais python essais/conversation.py tour1.m4a tour2.m4a
    uv run --group essais python essais/conversation.py --ia gemma3:12b tour1.m4a
    uv run --group essais python essais/conversation.py --texte "Hola, ¿qué tal?"
    uv run --group essais python essais/conversation.py --interactif

Voir `essais/README.md` pour l'installation (Ollama, modèles, voix).
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path

import httpx

CONSIGNE = """Eres un compañero de conversación para un estudiante francés de español \
(nivel A2-B1, español de España). Habláis de forma natural, como dos amigos.

Reglas:
- Responde siempre en español de España, en 1 a 3 frases cortas.
- Usa un vocabulario sencillo y frases claras.
- Termina siempre con una pregunta para que la conversación siga.
- No corrijas los errores del estudiante durante la conversación: responde a lo que quiso decir.
- Nada de listas, emojis, asteriscos ni formato: tu respuesta se leerá en voz alta."""

OLLAMA = "http://localhost:11434"


# --- Mémoire graphique ------------------------------------------------------------

def vram_utilisee() -> int | None:
    """Mémoire graphique occupée sur toute la carte, en Mo (tous processus,
    Ollama compris). `None` si `nvidia-smi` ne répond pas."""
    try:
        sortie = subprocess.run(
            ["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=5, check=True,
        ).stdout
        return int(sortie.strip().splitlines()[0])
    except (OSError, subprocess.SubprocessError, ValueError, IndexError):
        return None


def mo(valeur: int | None) -> str:
    return "?" if valeur is None else f"{valeur / 1024:.1f} Go"


def decoder(fichier: Path):
    """L'audio en 16 kHz mono, par ffmpeg. faster-whisper sait lire un fichier seul,
    mais par PyAV, dont les versions récentes ne lui conviennent plus."""
    import numpy
    brut = subprocess.run(
        ["ffmpeg", "-nostdin", "-loglevel", "error", "-i", str(fichier),
         "-f", "s16le", "-ac", "1", "-ar", "16000", "-"],
        capture_output=True, check=True,
    ).stdout
    return numpy.frombuffer(brut, numpy.int16).astype(numpy.float32) / 32768.0


# --- Les trois étapes -------------------------------------------------------------

class Oreille:
    """Whisper large-v3-turbo, par faster-whisper. L'espagnol est imposé : sans ça,
    un accent français peut faire détecter du français."""

    def __init__(self, modele: str, appareil: str):
        from faster_whisper import WhisperModel
        calcul = "float16" if appareil == "cuda" else "int8"
        self.modele = WhisperModel(modele, device=appareil, compute_type=calcul)

    def ecouter(self, fichier: Path) -> str:
        segments, _ = self.modele.transcribe(decoder(fichier), language="es", beam_size=5,
                                             vad_filter=True)
        return " ".join(s.text.strip() for s in segments).strip()


class Voix:
    """XTTS v2, par coqui-tts. Une voix de référence (un extrait de 6 à 15 s) donne
    le timbre et l'accent ; sinon, une voix fournie avec le modèle."""

    def __init__(self, appareil: str, reference: Path | None, locuteur: str):
        from TTS.api import TTS
        self.tts = TTS("tts_models/multilingual/multi-dataset/xtts_v2").to(appareil)
        self.reference = reference
        self.locuteur = locuteur

    def dire(self, texte: str, sortie: Path) -> float:
        if self.reference:
            self.tts.tts_to_file(text=texte, speaker_wav=str(self.reference), language="es",
                                 file_path=str(sortie))
        else:
            self.tts.tts_to_file(text=texte, speaker=self.locuteur, language="es",
                                 file_path=str(sortie))
        import soundfile
        return soundfile.info(str(sortie)).duration


class Cerveau:
    """L'IA de conversation, servie par Ollama. Elle garde l'historique du dialogue."""

    def __init__(self, modele: str):
        self.modele = modele
        self.messages = [{"role": "system", "content": CONSIGNE}]
        self.client = httpx.Client(base_url=OLLAMA, timeout=120)

    def _requete(self, messages: list[dict]) -> dict:
        corps = {"model": self.modele, "messages": messages, "stream": True,
                 "options": {"temperature": 0.7}}
        # Qwen3 réfléchit avant de répondre : utile pour un problème, trop lent pour
        # une conversation.
        if self.modele.startswith("qwen3"):
            corps["think"] = False
        return corps

    def decharger(self) -> None:
        """Retire le modèle de la mémoire graphique, où Ollama le garde quelques
        minutes après usage : sinon, la mesure « avant » le compte déjà."""
        try:
            self.client.post("/api/generate", json={"model": self.modele, "keep_alive": 0})
        except httpx.HTTPError:
            pass  # Ollama éteint : rien à décharger, l'erreur viendra au préchauffage.

    def prechauffer(self) -> None:
        """Charge le modèle en mémoire avant le premier tour, pour que le premier
        délai mesuré ne compte pas le chargement."""
        reponse = self.client.post("/api/chat", json={**self._requete(
            [{"role": "user", "content": "Hola"}]), "stream": False})
        reponse.raise_for_status()

    def repondre(self, phrase: str) -> tuple[str, float, float]:
        """La réponse, le délai jusqu'au premier mot et la durée totale (s)."""
        self.messages.append({"role": "user", "content": phrase})
        debut = time.perf_counter()
        premier = None
        morceaux: list[str] = []
        with self.client.stream("POST", "/api/chat", json=self._requete(self.messages)) as flux:
            flux.raise_for_status()
            for ligne in flux.iter_lines():
                if not ligne:
                    continue
                paquet = json.loads(ligne)
                texte = paquet.get("message", {}).get("content", "")
                if texte and premier is None:
                    premier = time.perf_counter() - debut
                morceaux.append(texte)
                if paquet.get("done"):
                    break
        total = time.perf_counter() - debut
        reponse = "".join(morceaux).strip()
        self.messages.append({"role": "assistant", "content": reponse})
        return reponse, premier or total, total


# --- L'essai ----------------------------------------------------------------------

@dataclass
class Tour:
    numero: int
    entree: str
    compris: str
    reponse: str
    ecoute_s: float
    premier_mot_s: float
    reflexion_s: float
    voix_s: float
    duree_reponse_s: float

    @property
    def delai_s(self) -> float:
        """Talkie-walkie : de la fin de ta phrase au début de la réponse parlée."""
        return self.ecoute_s + self.reflexion_s + self.voix_s


@dataclass
class Bilan:
    ia: str
    whisper: str
    appareil: str
    vram_mo: dict[str, int | None] = field(default_factory=dict)
    chargement_s: dict[str, float] = field(default_factory=dict)
    tours: list[dict] = field(default_factory=list)


def chrono(fonction, *args):
    debut = time.perf_counter()
    resultat = fonction(*args)
    return resultat, time.perf_counter() - debut


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("audio", nargs="*", type=Path, help="tes tours de parole (wav, m4a, mp3)")
    p.add_argument("--texte", action="append", default=[],
                   help="un tour écrit au lieu d'un audio (répétable, après les audios)")
    p.add_argument("--interactif", action="store_true",
                   help="après les tours donnés, demander les suivants au clavier")
    p.add_argument("--ia", default="qwen3:8b", help="modèle Ollama (défaut : qwen3:8b)")
    p.add_argument("--whisper", default="large-v3-turbo")
    p.add_argument("--voix", type=Path, help="extrait de voix de référence pour XTTS (wav)")
    p.add_argument("--locuteur", default="Ana Florence",
                   help="voix fournie avec XTTS, sans --voix (défaut : Ana Florence)")
    p.add_argument("--sortie", type=Path, default=Path("essais/sortie"))
    p.add_argument("--appareil", default="cuda", choices=["cuda", "cpu"])
    args = p.parse_args()

    entrees = [("audio", a) for a in args.audio] + [("texte", t) for t in args.texte]
    if not entrees and not args.interactif:
        p.error("donne au moins un audio, un --texte, ou --interactif")
    for genre, valeur in entrees:
        if genre == "audio" and not valeur.exists():
            p.error(f"introuvable : {valeur}")

    args.sortie.mkdir(parents=True, exist_ok=True)
    bilan = Bilan(ia=args.ia, whisper=args.whisper, appareil=args.appareil)
    cerveau = Cerveau(args.ia)
    cerveau.decharger()
    time.sleep(1)  # le temps que la mémoire soit rendue
    bilan.vram_mo["avant"] = vram_utilisee()

    print(f"Chargement de Whisper {args.whisper}…", flush=True)
    oreille, bilan.chargement_s["whisper"] = chrono(Oreille, args.whisper, args.appareil)
    bilan.vram_mo["whisper chargé"] = vram_utilisee()

    print("Chargement de XTTS v2…", flush=True)
    voix, bilan.chargement_s["xtts"] = chrono(Voix, args.appareil, args.voix, args.locuteur)
    bilan.vram_mo["+ xtts chargé"] = vram_utilisee()

    print(f"Chargement de {args.ia} dans Ollama…", flush=True)
    try:
        _, bilan.chargement_s["ia"] = chrono(cerveau.prechauffer)
    except httpx.HTTPError as erreur:
        print(f"\nOllama ne répond pas ou ne connaît pas {args.ia} : {erreur}\n"
              f"Lance `ollama serve`, puis `ollama pull {args.ia}`.", file=sys.stderr)
        return 1
    bilan.vram_mo["+ ia chargée"] = vram_utilisee()

    # Le premier passage sur la carte graphique prépare son code : XTTS y met
    # plusieurs secondes de plus. Le serveur fera de même au démarrage.
    print("Tour à vide…", flush=True)
    _, bilan.chargement_s["tour à vide"] = chrono(voix.dire, "Hola.", args.sortie / "vide.wav")
    if args.audio:
        oreille.ecouter(args.audio[0])
    pic = bilan.vram_mo["+ ia chargée"]

    def tours():
        """Les tours donnés, puis ceux tapés au clavier en mode interactif : un
        chemin d'audio, ou une phrase écrite. Une ligne vide termine."""
        yield from entrees
        while args.interactif:
            try:
                ligne = input("\nTon tour (phrase, ou chemin d'un audio ; vide pour finir) : ").strip()
            except EOFError:
                return
            if not ligne:
                return
            chemin = Path(ligne.strip("'\""))
            yield ("audio", chemin) if chemin.suffix and chemin.exists() else ("texte", ligne)

    for numero, (genre, valeur) in enumerate(tours(), start=1):
        print(f"\n— Tour {numero} " + "—" * 50)
        if genre == "audio":
            compris, ecoute = chrono(oreille.ecouter, valeur)
            entree = str(valeur)
        else:
            compris, ecoute, entree = valeur, 0.0, "(texte)"
        print(f"Toi      : {compris}")

        reponse, premier_mot, reflexion = cerveau.repondre(compris)
        print(f"IA       : {reponse}")

        fichier = args.sortie / f"tour-{numero:02d}.wav"
        duree, parole = chrono(voix.dire, reponse, fichier)
        pic = max(filter(None, [pic, vram_utilisee()]), default=None)

        tour = Tour(numero, entree, compris, reponse, round(ecoute, 2), round(premier_mot, 2),
                    round(reflexion, 2), round(parole, 2), round(duree, 2))
        bilan.tours.append({**asdict(tour), "delai_s": round(tour.delai_s, 2)})
        print(f"Temps    : écoute {ecoute:.2f} s · IA {reflexion:.2f} s "
              f"(1er mot {premier_mot:.2f} s) · voix {parole:.2f} s "
              f"→ délai {tour.delai_s:.2f} s, pour {duree:.1f} s de réponse")
        print(f"Réponse  : {fichier}")

    bilan.vram_mo["pic pendant l'essai"] = pic
    (args.sortie / "bilan.json").write_text(json.dumps(asdict(bilan), ensure_ascii=False, indent=2))

    print("\n— Bilan " + "—" * 55)
    print(f"IA : {args.ia} · Whisper : {args.whisper} · {args.appareil}")
    print("Mémoire graphique (toute la carte) :")
    for etape, valeur in bilan.vram_mo.items():
        print(f"  {etape:<22} {mo(valeur)}")
    print("Chargement : " + " · ".join(f"{k} {v:.1f} s" for k, v in bilan.chargement_s.items()))
    delais = [t["delai_s"] for t in bilan.tours if t["entree"] != "(texte)"]
    if delais:
        print(f"Délai par tour (audio) : de {min(delais):.2f} à {max(delais):.2f} s")
    print(f"Détail : {args.sortie / 'bilan.json'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
