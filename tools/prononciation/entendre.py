"""Transcrit un enregistrement en phonèmes (API), sans le corriger vers un texte attendu.

Usage : entendre.py FICHIER_AUDIO [...]
"""
import subprocess
import sys

import json

import numpy as np
import torch
from huggingface_hub import hf_hub_download
from transformers import AutoFeatureExtractor, AutoModelForCTC

MODELE = "facebook/wav2vec2-xlsr-53-espeak-cv-ft"


def charger_audio(chemin):
    """Décode n'importe quel format via ffmpeg en mono 16 kHz flottant."""
    brut = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", chemin, "-ac", "1", "-ar", "16000", "-f", "f32le", "-"],
        check=True, capture_output=True,
    ).stdout
    return np.frombuffer(brut, dtype=np.float32)


def charger_vocabulaire():
    """Index → phonème. Le tokenizer du modèle exige espeak même pour décoder : on s'en passe."""
    with open(hf_hub_download(MODELE, "vocab.json")) as f:
        return {i: p for p, i in json.load(f).items()}


def decoder(ids, vocabulaire, vide):
    """Décodage CTC glouton : fusionne les répétitions, retire le symbole vide."""
    phonemes, precedent = [], None
    for i in ids:
        if i != precedent and i != vide:
            phonemes.append(vocabulaire[i])
        precedent = i
    return phonemes


def charger_modele():
    """(extracteur, modèle sur le GPU Apple si disponible, vocabulaire)."""
    dispositif = "mps" if torch.backends.mps.is_available() else "cpu"
    extracteur = AutoFeatureExtractor.from_pretrained(MODELE)
    modele = AutoModelForCTC.from_pretrained(MODELE).eval().to(dispositif)
    return extracteur, modele, charger_vocabulaire()


def main():
    extracteur, modele, vocabulaire = charger_modele()
    for chemin in sys.argv[1:]:
        entree = extracteur(charger_audio(chemin), sampling_rate=16000, return_tensors="pt")
        with torch.no_grad():
            logits = modele(entree.input_values.to(modele.device)).logits[0].cpu()
        ids = torch.argmax(logits, dim=-1).tolist()
        print(f"{chemin}\n  {' '.join(decoder(ids, vocabulaire, modele.config.pad_token_id))}")


if __name__ == "__main__":
    main()
