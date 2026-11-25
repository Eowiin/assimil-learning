"""Juge chaque phonème attendu d'une phrase prononcée.

La méthode vient de spanish-pronunciation-coach (le projet de recherche sur le PC), reprise
dans `coach/` :

1. GOP aligné : la phrase attendue (G2P castillan, `coach/g2p.py`) est alignée de force
   sur les sorties du wav2vec2 phonétique ; chaque phonème est noté par la probabilité
   de ses réalisations acceptées à sa meilleure trame. Il est fautif sous le seuil de son
   phonème (`coach/thresholds/gop_<modèle>.json`), le quantile 0,002 de 1899 phrases
   natives d'Assimil (0,01 pour /θ/).
2. Les r : battu ou roulé se juge dans le signal (`coach/rhotic.py` : les contacts de la
   langue dans l'énergie 400-4000 Hz), là où les natifs sont réguliers (entre voyelles,
   en début de mot). Un r français se reconnaît à ZIPA, qui connaît [ʁ]. Le r roulé
   jugé battu n'est qu'un indice (`indice`), pas une faute : les natifs le font souvent.
3. ZIPA juge aussi deux fautes que le wav2vec2 n'entend pas (essai du 13 novembre) :
   - la jota dite en r français : part de [ʁ χ ʀ] autour du /x/ aligné ;
   - le v dit [v] : part de [v] autour d'un /b/ écrit v. Le wav2vec2 entend du [v] chez
     les natifs ; ZIPA presque jamais.
   Seuils dans `seuils_zipa.json`, tirés des natifs par `essais/prononciation/calibrer_zipa.py`.

Le modèle phonétique se choisit par `ASSIMIL_PRONONCIATION_MODELE`, parmi ceux dont les
seuils GOP sont calibrés : xlsr53 (le défaut, le meilleur sur le test du 10 novembre),
lv60, cnam.
"""
import json
import os

import numpy as np

from .coach.acoustic import load_model
from .coach.ctc import BLANK, collapse, greedy_decode
from .coach.g2p import transcribe
from .coach.gop import Thresholds, score_utterance
from .coach.rhotic import Calibration, analyze, uvular_evidence

MODELE = os.environ.get("ASSIMIL_PRONONCIATION_MODELE", "xlsr53")

SEUILS_ZIPA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "seuils_zipa.json")
ZIPA = "zipa-s"
UVULAIRES = ("ʁ", "χ", "ʀ")
# Ce qu'un verdict sur le r fait entendre.
ENTENDU_R = {"tap": "ɾ", "trill": "r", "uvular": "ʁ", "long": "ʁ"}


def lettres_v(utt):
    """{(mot, k)} des /b/ écrits v : chaque b ou v écrit donne un /b/, dans l'ordre."""
    sortie = set()
    for wi, w in enumerate(utt.words):
        lettres = [c for c in w.text.lower() if c in "bvw"]
        b = [k for k, p in enumerate(w.phonemes()) if p == "b"]
        sortie |= {(wi, k) for k, l in zip(b, lettres) if l == "v"}
    return sortie


def parts_zipa(utt, pp):
    """Pour chaque /x/ : part uvulaire ; pour chaque /b/ écrit v : part de [v].

    Part = probabilité des symboles parmi les sorties non vides, au maximum sur la fenêtre
    alignée élargie (comme `uvular_evidence` pour les r). → {(mot, k): (faute, part)}"""
    probs = np.exp(pp.log_probs.astype(np.float64))
    non_vide = np.maximum(1e-6, 1 - probs[:, pp.index(BLANK)])

    def part(symboles):
        idx = [i for s in symboles if (i := pp.index(s)) is not None]
        return probs[:, idx].sum(axis=1) / non_vide

    uvulaire, v = part(UVULAIRES), part(("v",))
    ecrits_v = lettres_v(utt)
    sortie = {}
    for s in score_utterance(utt, pp):
        fenetre = slice(max(0, s.start - 2), s.end + 3)
        if s.phoneme == "x":
            sortie[s.word, s.k] = ("jota", float(uvulaire[fenetre].max()))
        elif (s.word, s.k) in ecrits_v:
            sortie[s.word, s.k] = ("v", float(v[fenetre].max()))
    return sortie


class Analyseur:
    def __init__(self):
        self.modele = load_model(MODELE)
        self.seuils = Thresholds.load(MODELE)
        if self.seuils is None:
            raise RuntimeError(f"Pas de seuils GOP pour {MODELE} (coach/thresholds/)")
        self.calibration = Calibration.load()
        self.zipa = load_model(ZIPA)
        self.seuils_zipa = json.load(open(SEUILS_ZIPA))

    def analyser(self, audio, phrase):
        utt = transcribe(phrase)
        if not utt.words:
            raise ValueError("aucun mot à prononcer")
        post = self.modele.posteriors(audio)
        notes = {(s.word, s.k): s for s in score_utterance(utt, collapse(post))}
        fs = post.frame_seconds
        spans = {cle: (s.start * fs, (s.end + 1) * fs) for cle, s in notes.items()}
        pp_zipa = collapse(self.zipa.posteriors(audio))
        r = {(x.word, x.k): x for x in analyze(audio, utt, spans, self.calibration,
                                               uvular_evidence(utt, pp_zipa))}
        zipa = parts_zipa(utt, pp_zipa)

        phonemes = []
        for wi, w in enumerate(utt.words):
            for k, p in enumerate(w.phonemes()):
                n = notes.get((wi, k))
                ph = {"attendu": p, "mot": wi, "score": None, "variante": None,
                      "faute": False, "raison": None}
                phonemes.append(ph)
                if n is None:  # mot non noté (sigle, emprunt) ou son inconnu du modèle
                    continue
                seuil = self.seuils(p)
                debut, fin = spans[wi, k]  # secondes, d'après l'alignement
                ph |= {"score": round(n.score, 2), "seuil": round(seuil, 2), "variante": n.competitor,
                       "debut": round(debut, 3), "fin": round(fin, 3)}
                if n.score < seuil:
                    ph |= {"faute": True, "raison": "gop",
                           "variante": n.competitor if n.competitor_score > n.score else "∅"}
                # Le r jugé dans le signal peut ajouter une faute, jamais en effacer une
                # du GOP : un [l] fait aussi un seul contact, et passerait pour battu.
                rh = r.get((wi, k))
                if rh and rh.ok is not None and rh.reliable:
                    ph["r"] = rh.verdict
                    if not rh.ok and p == "r" and rh.verdict == "tap":
                        # Roulé dit battu : simple indice. Les natifs de Common Voice
                        # réduisent souvent le r roulé à un contact (34 des 64 /r/ jugés).
                        ph["indice"] = "ɾ"
                    elif not rh.ok:
                        ph |= {"faute": True, "raison": "r",
                               "variante": ENTENDU_R.get(rh.verdict, rh.verdict)}
                if (wi, k) in zipa:
                    faute, part = zipa[wi, k]
                    ph["part_zipa"] = round(part, 3)
                    if part >= self.seuils_zipa[faute] and not ph["faute"]:
                        ph |= {"faute": True, "raison": "zipa",
                               "variante": "ʁ" if faute == "jota" else "v"}

        entendu = [s.symbol for s in greedy_decode(post.log_probs, post.vocab, post.blank)]
        return {"mots": [w.text.lower() for w in utt.words], "phonemes": phonemes,
                "entendu": entendu}
