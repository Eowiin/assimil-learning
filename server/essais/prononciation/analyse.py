"""Note chaque phonème attendu d'une phrase prononcée.

Pour chaque position, on compare la vraisemblance CTC de la phrase attendue à celle
de la même phrase où ce seul phonème est remplacé par un autre son, ou supprimé
(GOP sans alignement préalable). Score = écart de log-vraisemblance entre la
meilleure variante et l'attendu : positif, l'attendu l'emporte ; négatif, le modèle
a plutôt entendu la variante, qu'on rapporte.

Une faute n'est signalée que si le score passe sous le seuil du phonème (seuils.json),
tiré des voix natives : le modèle se trompe aussi sur elles, il ne faut pas
reprocher à l'élève ce que le modèle reproche déjà au natif.

Usage : analyse.py AUDIO "phrase attendue"
"""
import json
import os
import sys

import torch
import torch.nn.functional as F

from entendre import charger_audio, charger_modele, decoder
from phonemes import phonemiser

# Sons proposés en remplacement : l'inventaire espagnol, plus les sons qu'un
# francophone risque d'y substituer (r grasseyé, voyelles nasales, u français…).
ESPAGNOL = "a e i o u j w p b β t d ð k ɡ ɣ f θ s x tʃ m n ɲ l ʎ ɾ r aɪ eɪ oɪ aʊ eʊ".split()
FRANCAIS = "ʁ ʒ ʃ v z y ø œ ə ɛ ɔ ɑ̃ ɔ̃ ɛ̃ h ŋ ɹ dʒ".split()
SUPPRESSION = "∅"
# Réalisations tolérées pour un phonème attendu : pas une faute. Orientées : un r
# roulé à la place du battu passe, un r battu à la place du roulé (perro → pero) non.
# Le modèle distingue mal occlusives et spirantes (b/β, d/ð, g/ɣ) même chez les natifs.
TOLERANCES = {
    "ɾ": {"r"}, "s": {"z"}, "n": {"ŋ"}, "e": {"ɛ"}, "o": {"ɔ"},
    "b": {"β"}, "β": {"b"}, "d": {"ð"}, "ð": {"d"}, "ɡ": {"ɣ"}, "ɣ": {"ɡ"},
    "j": {"i", "ʎ", "dʒ"}, "ʎ": {"j", "dʒ"}, "w": {"u"}, "i": {"j"}, "u": {"w"},
}
SEUILS = os.path.join(os.path.dirname(__file__), "seuils.json")
LOT = 512


def _tolere(p):
    return {p} | TOLERANCES.get(p, set())


def _perte(log_probs, sequence, vocab_ids, vide):
    cible = torch.tensor([vocab_ids[p] for p in sequence])
    return F.ctc_loss(log_probs, cible, torch.tensor(log_probs.shape[0]),
                      torch.tensor(len(sequence)), blank=vide, reduction="sum").item()


def choisir_variantes(log_probs, attendus, variantes, vocab_ids, vide):
    """Applique chaque variante si elle rend l'enregistrement plus probable.

    De droite à gauche, pour que les indices des variantes restantes restent valides.
    """
    attendus = list(attendus)
    perte = _perte(log_probs, [p for p, _ in attendus], vocab_ids, vide)
    for debut, longueur, remplacement in sorted(variantes, reverse=True):
        mot = attendus[debut][1]
        essai = attendus[:debut] + [(p, mot) for p in remplacement] + attendus[debut + longueur:]
        perte_essai = _perte(log_probs, [p for p, _ in essai], vocab_ids, vide)
        if perte_essai < perte:
            attendus, perte = essai, perte_essai
    return attendus


def noter(log_probs, attendus, vocab_ids, vide):
    """log_probs : (T, C) log-softmax. Retourne [(score, variante la plus probable)]."""
    candidats = [p for p in ESPAGNOL + FRANCAIS if p in vocab_ids]
    colonnes = sorted({vide} | {vocab_ids[p] for p in candidats + attendus})
    local = {c: k for k, c in enumerate(colonnes)}
    lp = log_probs[:, colonnes]
    cible = [local[vocab_ids[p]] for p in attendus]

    variantes, etiquettes = [cible], [(None, None)]
    for i, p in enumerate(attendus):
        for q in candidats:
            if q not in _tolere(p):
                variantes.append(cible[:i] + [local[vocab_ids[q]]] + cible[i + 1:])
                etiquettes.append((i, q))
        variantes.append(cible[:i] + cible[i + 1:])
        etiquettes.append((i, SUPPRESSION))

    pertes = []
    for debut in range(0, len(variantes), LOT):
        lot = variantes[debut:debut + LOT]
        longueurs = torch.tensor([len(v) for v in lot])
        cibles = torch.tensor([x for v in lot for x in v])
        entree = lp.unsqueeze(1).expand(-1, len(lot), -1)
        pertes.append(F.ctc_loss(entree, cibles, torch.full((len(lot),), lp.shape[0]),
                                 longueurs, blank=local[vide], reduction="none"))
    pertes = torch.cat(pertes)

    reference = pertes[0].item()
    meilleures = [(float("inf"), None)] * len(attendus)
    for (i, q), perte in zip(etiquettes[1:], pertes[1:].tolist()):
        if perte < meilleures[i][0]:
            meilleures[i] = (perte, q)
    return [(perte - reference, q) for perte, q in meilleures]


class Analyseur:
    def __init__(self):
        self.extracteur, self.modele, self.vocabulaire = charger_modele()
        self.vocab_ids = {p: i for i, p in self.vocabulaire.items()}
        self.vide = self.modele.config.pad_token_id
        self.seuils = json.load(open(SEUILS)) if os.path.exists(SEUILS) else {}

    def log_probs(self, audio):
        entree = self.extracteur(audio, sampling_rate=16000, return_tensors="pt")
        dispositif = next(self.modele.parameters()).device
        with torch.no_grad():
            logits = self.modele(entree.input_values.to(dispositif)).logits[0]
        return F.log_softmax(logits.float(), dim=-1).cpu()

    def analyser(self, audio, phrase):
        mots, attendus, variantes = phonemiser(phrase)
        lp = self.log_probs(audio)
        attendus = choisir_variantes(lp, attendus, variantes, self.vocab_ids, self.vide)
        notes = noter(lp, [p for p, _ in attendus], self.vocab_ids, self.vide)
        entendu = decoder(lp.argmax(-1).tolist(), self.vocabulaire, self.vide)
        return {
            "mots": mots,
            "phonemes": [{"attendu": p, "mot": m, "score": round(s, 2), "variante": q,
                          "faute": s < self.seuils.get(p, 0.0)}
                         for (p, m), (s, q) in zip(attendus, notes)],
            "entendu": entendu,
        }


def afficher(resultat):
    print("entendu :", " ".join(resultat["entendu"]))
    for indice, mot in enumerate(resultat["mots"]):
        sons = [p for p in resultat["phonemes"] if p["mot"] == indice]
        rendu = " ".join(
            f"[{p['attendu']}→{p['variante']} {p['score']:+.1f}]" if p["faute"] else p["attendu"]
            for p in sons)
        print(f"  {mot:15} {rendu}")


if __name__ == "__main__":
    afficher(Analyseur().analyser(charger_audio(sys.argv[1]), sys.argv[2]))
