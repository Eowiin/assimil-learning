"""Prépare des voix inconnues de l'analyse, tirées de Common Voice (espagnol), pour la
mesurer hors de la voix du test du 10 novembre :

- des natifs d'Espagne (nord et centre) : tout son signalé est une fausse alerte ;
- les locuteurs dont l'accent déclaré est français, s'il y en a : d'autres francophones.

L'archive complète fait environ 50 Go. Elle est lue en flux, sans être décompressée :
un premier passage lit validated.tsv, un second n'extrait que les clips choisis,
convertis en wav 16 kHz mono. Repris de test-pronunciation-detection/prepare_validation.py.

    export MDC_API_KEY=...   # la clé de Mozilla Data Collective
    uv run --with datacollective python essais/prononciation/common_voice.py ~/common-voice-es --echantillon
    uv run --with datacollective python essais/prononciation/common_voice.py ~/common-voice-es

`--echantillon` essaie l'extrait que publie Mozilla, bien plus petit ; il ne contient
peut-être pas assez de voix d'Espagne, ni d'accent français. Sans lui, c'est l'archive
complète. Le manifeste écrit (manifeste.tsv) se mesure avec evaluer.py.
"""
import argparse
import csv
import io
import os
import random
import re
import subprocess
import sys
import tarfile
import time
from collections import Counter, defaultdict

DATASET = "cmu5kitx700pemi073feoiqqu"  # Common Voice, espagnol
ESPAGNE = re.compile(r"norte ?peninsular|centro-? ?sur ?peninsular", re.I)
FRANCAIS = re.compile(r"franc[eéi]s|francia|french|fran[cç]ais", re.I)
MOTS_MIN, MOTS_MAX = 5, 15
GRAINE = 13  # tirage reproductible (le jeu de 30 du 11 novembre utilisait 42)


def lire_validated(archive):
    print("1er passage : validated.tsv…")
    debut = time.perf_counter()
    with tarfile.open(archive, "r|*") as tar:
        for membre in tar:
            if membre.isfile() and membre.name.endswith("/validated.tsv"):
                # Lu d'un bloc : un membre d'archive lue en flux ne se laisse pas envelopper.
                texte = io.StringIO(tar.extractfile(membre).read().decode("utf-8"))
                csv.field_size_limit(sys.maxsize)
                lignes = list(csv.DictReader(texte, delimiter="\t", quoting=csv.QUOTE_NONE))
                print(f"  {len(lignes)} clips validés, en {time.perf_counter() - debut:.0f} s")
                return lignes
    raise SystemExit("validated.tsv introuvable dans l'archive")


def choisir(lignes, natifs, par_natif, francophones, par_francophone):
    accent = next((c for c in ("accents", "accent") if c in lignes[0]), None)
    if accent is None:
        raise SystemExit(f"Pas de colonne d'accent : {list(lignes[0])}")
    utiles = [l for l in lignes
              if (l.get("down_votes") or "0") == "0"
              and MOTS_MIN <= len((l.get("sentence") or "").split()) <= MOTS_MAX
              and not re.search(r"\d", l.get("sentence") or "")]
    accents_fr = Counter(l[accent] for l in lignes if FRANCAIS.search(l[accent] or ""))
    print("  accents déclarés français :", dict(accents_fr) or "aucun")

    def tirer(groupe, motif, n, par_locuteur):
        candidats = [l for l in utiles if motif.search(l[accent] or "")]
        random.Random(GRAINE).shuffle(candidats)
        vus, choix = defaultdict(int), []
        for l in candidats:
            if vus[l["client_id"]] < par_locuteur and len(choix) < n:
                vus[l["client_id"]] += 1
                choix.append({**l, "groupe": groupe, "accent": l[accent]})
        print(f"  {groupe} : {len(choix)} clips, {len({c['client_id'] for c in choix})} locuteurs (sur {len(candidats)} utilisables)")
        return choix

    return (tirer("natif", ESPAGNE, natifs, par_natif)
            + tirer("francophone", FRANCAIS, francophones, par_francophone))


def extraire(archive, choix, dossier):
    voulus = {c["path"]: c for c in choix}
    print(f"2e passage : extraction de {len(voulus)} clips…")
    faits = set()
    with tarfile.open(archive, "r|*") as tar:
        for membre in tar:
            nom = os.path.basename(membre.name)
            if not membre.isfile() or nom not in voulus or nom in faits:
                continue
            wav = os.path.join(dossier, os.path.splitext(nom)[0] + ".wav")
            subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", "-", "-ac", "1", "-ar", "16000", wav],
                           input=tar.extractfile(membre).read(), check=True)
            faits.add(nom)
            if len(faits) % 50 == 0:
                print(f"  {len(faits)}/{len(voulus)}")
            if len(faits) == len(voulus):
                break
    return faits


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("dossier", help="où écrire les wav et manifeste.tsv (hors dépôt)")
    p.add_argument("--echantillon", action="store_true", help="l'extrait publié, pas l'archive complète")
    p.add_argument("--natifs", type=int, default=400)
    p.add_argument("--par-natif", type=int, default=2, help="clips au plus par locuteur natif")
    p.add_argument("--francophones", type=int, default=300)
    p.add_argument("--par-francophone", type=int, default=10)
    p.add_argument("--archive", help="une archive déjà téléchargée")
    args = p.parse_args()
    if not args.archive and not os.environ.get("MDC_API_KEY"):
        sys.exit("MDC_API_KEY n'est pas définie")

    from datacollective import download_dataset, download_sample

    archive = args.archive or str((download_sample if args.echantillon else download_dataset)(DATASET))
    print(f"Archive : {archive} ({os.path.getsize(archive) / 1e9:.1f} Go)")
    dossier = os.path.expanduser(args.dossier)
    os.makedirs(dossier, exist_ok=True)

    choix = choisir(lire_validated(archive), args.natifs, args.par_natif,
                    args.francophones, args.par_francophone)
    faits = extraire(archive, choix, dossier)
    with open(os.path.join(dossier, "manifeste.tsv"), "w", newline="") as f:
        sortie = csv.writer(f, delimiter="\t")
        sortie.writerow(["fichier", "texte", "groupe", "accent", "locuteur"])
        for c in choix:
            if c["path"] in faits:
                sortie.writerow([os.path.splitext(c["path"])[0] + ".wav", c["sentence"], c["groupe"],
                                 c["accent"], c["client_id"][:8]])
    print(f"{len(faits)} clips et manifeste.tsv dans {dossier}")
    if not args.echantillon and not args.archive:
        print(f"L'archive reste dans {archive} : à supprimer à la main une fois le manifeste vérifié.")


if __name__ == "__main__":
    main()
