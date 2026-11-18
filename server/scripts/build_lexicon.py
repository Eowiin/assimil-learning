# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = [
#   "spacy>=3.8,<3.9",
#   "es_core_news_lg @ https://github.com/explosion/spacy-models/releases/download/es_core_news_lg-3.8.0/es_core_news_lg-3.8.0-py3-none-any.whl",
#   "spylls>=0.1.7",
# ]
# ///
"""Le lexique fréquentiel du paquet `curriculum/es` : les 5 000 lemmes les plus
fréquents de l'espagnol parlé, avec leur transcription castillane.

    uv run server/scripts/build_lexicon.py
    uv run server/scripts/build_lexicon.py --pseudomots   # renouvelle aussi les non-mots

Trois sources, téléchargées une fois dans `server/scripts/.cache/` :

- **les fréquences** : les formes des sous-titres d'OpenSubtitles (FrequencyWords,
  2018), proches de la langue parlée ;
- **le contexte** : les phrases espagnoles de Tatoeba. Une forme isolée ne dit pas
  son lemme (« vino » : le vin, ou venir ?) ; dans ses phrases, si. Le compte d'une
  forme est partagé entre ses lemmes selon ce que `es_core_news_lg` y trouve ;
- **le filtre** : le dictionnaire Hunspell es_ES de LibreOffice. Un lemme n'est
  gardé que si Hunspell le reconnaît écrit en minuscules : les prénoms (john,
  harry), l'anglais (the) et les lemmes déformés par spaCy (sigu, podriar) tombent,
  les noms communs que spaCy prend pour des noms propres (madre, oficina) restent.
  Un lemme de pronom collé (« hacer él », pour « hacerlo ») est ramené au verbe.

La transcription vient des règles castillanes du serveur (`coach/g2p.py` :
distinción, /x/, /ʎ/, /r/ et /ɾ/), la même que juge la prononciation.

Produit `Resources/curriculum/es/lexicon.json` et, sur demande, `pseudowords.json` (des
non-mots plausibles pour le test de vocabulaire du placement, façon LexTALE). Affiche ce
qui a été écarté, et les verbes à relire (`LEMMES_FAUX`).
"""

from __future__ import annotations

import bz2
import json
import random
import re
import sys
import urllib.request
from collections import Counter, defaultdict
from pathlib import Path

ICI = Path(__file__).resolve().parent
SERVEUR = ICI.parent
DEPOT = SERVEUR.parent
sys.path.insert(0, str(SERVEUR))

from app.prononciation.coach.g2p import transcribe_word  # noqa: E402

CACHE = ICI / ".cache"
SORTIE = DEPOT / "Resources" / "curriculum" / "es"

SOURCES = {
    "es_50k.txt": "https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/es/es_50k.txt",
    "spa_sentences.tsv.bz2": "https://downloads.tatoeba.org/exports/per_language/spa/spa_sentences.tsv.bz2",
    "es_ES.dic": "https://raw.githubusercontent.com/LibreOffice/dictionaries/master/es/es_ES.dic",
    "es_ES.aff": "https://raw.githubusercontent.com/LibreOffice/dictionaries/master/es/es_ES.aff",
}

TAILLE = 5000
FORMES = 30000          # les formes les plus fréquentes examinées
PHRASES = 400_000       # phrases de Tatoeba lues, au plus
CONTEXTE_MIN = 3        # en dessous, la forme est analysée seule
LETTRES = set("abcdefghijklmnopqrstuvwxyzáéíóúüñ")
# Les mots d'une lettre sont des mots espagnols ; les autres lettres seules, non.
UNE_LETTRE = {"a", "e", "o", "u", "y"}
# Pas des mots du lexique : interjections de sous-titres, onomatopées.
EXCLUS = {"ah", "oh", "eh", "uh", "mm", "hm", "ay", "ja", "je", "jo", "ey", "uy", "bah", "puaj",
          "hey", "ok", "okay", "okey", "wow", "yeah", "bye", "hello", "mmm", "aja", "ajá"}
# Les étiquettes gardées. PROPN n'en fait pas partie : un lemme qui n'a été vu
# que comme nom propre et que le dictionnaire connaît prend NOUN.
POS_GARDES = {"NOUN", "VERB", "ADJ", "ADV", "PRON", "DET", "ADP", "CCONJ", "SCONJ", "NUM", "INTJ", "AUX"}
# Les lemmes que spaCy invente pour un verbe irrégulier : un infinitif bien formé, connu
# de Hunspell, mais d'un homographe rare (« eres » → erar, « dime » → dimir). Relus à la
# main sur la liste « infinitif absent des sous-titres » que le script affiche.
LEMMES_FAUX = {"erar": "ser", "seriar": "ser", "dimir": "decir", "dir": "decir", "distar": "dar",
               "rugir": "rogar", "salgar": "salir", "empecer": "empezar", "vendar": "vender",
               "morar": "morir"}
# Ce qu'un infinitif doit avoir été rendu comme lemme par spaCy, ailleurs, pour qu'une
# forme conjuguée lui soit rattachée (voir `reparer`) : le compte de « asistir », rang
# 2 500, est de 8 000.
VU_COMME_LEMME = 200
# Niveau estimé d'après le rang : une indication pour le placement, pas une vérité.
NIVEAUX = [(600, "A1"), (1500, "A2"), (2800, "B1"), (4200, "B2"), (TAILLE, "C1")]


def telecharger() -> None:
    CACHE.mkdir(exist_ok=True)
    for nom, url in SOURCES.items():
        cible = CACHE / nom
        if not cible.exists():
            print(f"Téléchargement de {nom}…")
            requete = urllib.request.Request(url, headers={"User-Agent": "lexicon-builder"})
            with urllib.request.urlopen(requete) as reponse:
                cible.write_bytes(reponse.read())


def formes_frequentes() -> dict[str, int]:
    formes: dict[str, int] = {}
    for ligne in (CACHE / "es_50k.txt").read_text(encoding="utf-8").splitlines():
        parts = ligne.split()
        if len(parts) != 2:
            continue
        mot = parts[0].lower()
        if not set(mot) <= LETTRES or (len(mot) == 1 and mot not in UNE_LETTRE) or mot in EXCLUS:
            continue
        formes[mot] = formes.get(mot, 0) + int(parts[1])
        if len(formes) >= FORMES:
            break
    return formes


class Dictionnaire:
    """Hunspell es_ES. Les noms propres y ont une majuscule : écrits en minuscules,
    il ne les reconnaît pas. Les réponses sont gardées : spylls est lent."""

    def __init__(self):
        from spylls.hunspell import Dictionary
        self.hunspell = Dictionary.from_files(str(CACHE / "es_ES"))
        self.vus: dict[str, bool] = {}

    def radicaux(self, mot: str) -> set[str]:
        """Les entrées du dictionnaire d'où la forme peut venir : « hiciste » → hacer,
        « años » → año. Juste pour les verbes et les pluriels ; pour le reste, le
        dictionnaire range les mots autrement (« vida » vient de « vid »)."""
        return {f.stem for f in self.hunspell.lookuper.good_forms(mot)}

    def __contains__(self, mot: str) -> bool:
        if mot not in self.vus:
            self.vus[mot] = mot.isalpha() and bool(self.hunspell.lookup(mot))
        return self.vus[mot]


INFINITIF = re.compile(r"(ar|er|ir|ír)$")
CLITIQUES = re.compile(r"(me|te|se|lo|la|le|nos|os|los|las|les)+$")
SANS_ACCENT = str.maketrans("áéíóú", "aeiou")
# Des mots qui s'écrivent avec un s final, et ne sont pas le pluriel d'un autre.
PAS_DES_PLURIELS = {"gracias", "lunes", "martes", "miércoles", "jueves", "viernes", "demás", "crisis",
                    "análisis", "virus", "paraguas", "cumpleaños", "tenis", "atlas", "dios", "mes", "país",
                    "inglés", "francés", "después", "además", "jamás", "quizás", "detrás", "atrás",
                    "través", "menos", "más", "tras", "lejos", "entonces", "pues", "apenas", "mientras"}


def reparer(lemme: str, pos: str, comptes: Counter, dictionnaire: "Dictionnaire") -> str | None:
    """Ce que spaCy rend parfois comme lemme est une forme : un verbe conjugué
    (« quieres », « dame ») ou un pluriel (« años »). Rend le vrai lemme, le même s'il
    est bon, ou None quand on ne sait pas le retrouver (la forme est alors écartée).

    Un infinitif n'est retenu que si spaCy l'a déjà rendu comme lemme ailleurs : pour un
    verbe irrégulier, Hunspell ne propose qu'un homographe rare (« era » → erar,
    « dime » → dimir, « salga » → salgar, « sería » → seriar), et le vrai verbe est
    déjà compté par ses autres formes."""
    if pos in ("VERB", "AUX"):
        if INFINITIF.search(lemme):
            return lemme
        for forme in (lemme, CLITIQUES.sub("", lemme).translate(SANS_ACCENT)):
            if not forme or forme not in dictionnaire:
                continue
            infinitifs = [r for r in dictionnaire.radicaux(forme)
                          if INFINITIF.search(r) and comptes[r] >= VU_COMME_LEMME]
            if infinitifs:
                return max(infinitifs, key=lambda r: comptes[r])
        return None
    if pos in ("NOUN", "ADJ") and lemme.endswith("s") and lemme not in PAS_DES_PLURIELS:
        for singulier in dictionnaire.radicaux(lemme):
            if singulier != lemme and lemme in (singulier + "s", singulier + "es") and comptes[singulier] > 0:
                return singulier
    return lemme


def etiquette_brute(vus: Counter) -> str:
    gardees = [(n, p) for p, n in vus.items() if p in POS_GARDES]
    return max(gardees)[1] if gardees else "NOUN"


def lemme_utile(lemme: str, pos: str) -> str:
    """spaCy rend « hacer él » pour « hacerlo » : le lemme est le verbe. Un lemme
    inventé (`LEMMES_FAUX`) devient le vrai verbe."""
    if pos in ("VERB", "AUX"):
        if " " in lemme:
            lemme = lemme.split(" ")[0]
        return LEMMES_FAUX.get(lemme, lemme)
    return lemme


def phrases():
    with bz2.open(CACHE / "spa_sentences.tsv.bz2", "rt", encoding="utf-8") as f:
        for i, ligne in enumerate(f):
            if i >= PHRASES:
                return
            parts = ligne.rstrip("\n").split("\t")
            if len(parts) == 3:
                yield parts[2]


def lemmes_en_contexte(nlp, formes: dict[str, int]) -> dict[str, Counter]:
    """Pour chaque forme : combien de fois spaCy y a vu tel (lemme, étiquette)."""
    vus: dict[str, Counter] = defaultdict(Counter)
    for n, doc in enumerate(nlp.pipe(phrases(), batch_size=2000), start=1):
        for t in doc:
            forme = t.text.lower()
            if forme in formes:
                vus[forme][(t.lemma_.lower(), t.pos_)] += 1
        if n % 50_000 == 0:
            print(f"  {n} phrases lues")
    return vus


def ipa(lemme: str) -> str:
    return transcribe_word(lemme).format()


def main() -> None:
    import spacy

    telecharger()
    formes = formes_frequentes()
    dictionnaire = Dictionnaire()
    print(f"{len(formes)} formes")

    nlp = spacy.load("es_core_news_lg", disable=["parser", "ner"])
    print("Analyse des phrases de Tatoeba…")
    contexte = lemmes_en_contexte(nlp, formes)

    seules = [f for f in formes if sum(contexte[f].values()) < CONTEXTE_MIN]
    for forme, doc in zip(seules, nlp.pipe(seules, batch_size=2000)):
        t = doc[0]
        contexte[forme] = Counter({(t.lemma_.lower(), t.pos_): 1})

    comptes: Counter = Counter()
    etiquettes: dict[str, Counter] = defaultdict(Counter)
    sources: dict[str, Counter] = defaultdict(Counter)
    ecartes: Counter = Counter()
    for forme, total in formes.items():
        vus = contexte[forme]
        somme = sum(vus.values())
        for (lemme, pos), n in vus.items():
            lemme = lemme_utile(lemme, pos)
            part = total * n / somme
            if lemme in EXCLUS or lemme not in dictionnaire:
                ecartes[f"{lemme} ({forme})"] += part
                continue
            comptes[lemme] += part
            etiquettes[lemme][pos] += part
            sources[lemme][forme] += part

    # Les formes prises pour des lemmes rejoignent leur lemme.
    for lemme in list(comptes):
        juste = reparer(lemme, etiquette_brute(etiquettes[lemme]), comptes, dictionnaire)
        if juste == lemme:
            continue
        masse = comptes.pop(lemme)
        if juste is None:
            ecartes[f"{lemme} (forme sans lemme)"] += masse
            etiquettes.pop(lemme)
            continue
        comptes[juste] += masse
        for pos, n in etiquettes.pop(lemme).items():
            etiquettes[juste][pos] += n

    def etiquette(lemme: str) -> str:
        return etiquette_brute(etiquettes[lemme])

    lexique = []
    for rang, (lemme, compte) in enumerate(comptes.most_common(TAILLE), start=1):
        niveau = next(n for borne, n in NIVEAUX if rang <= borne)
        lexique.append({"rank": rang, "lemma": lemme, "pos": etiquette(lemme), "ipa": ipa(lemme),
                        "level": niveau, "count": round(compte)})

    SORTIE.mkdir(parents=True, exist_ok=True)
    ecrire(SORTIE / "lexicon.json", {
        "version": 1, "language": "es",
        "source": "OpenSubtitles 2018 (FrequencyWords), lemmes en contexte Tatoeba (es_core_news_lg), "
                  "filtrés par Hunspell es_ES ; API castillane (server/app/prononciation/coach/g2p.py)",
        "lemmas": lexique,
    })
    # Les non-mots ont été relus : ils ne changent que sur demande. Leur tirage dépend
    # des rangs, et corriger un lemme les renouvellerait tous.
    cible = SORTIE / "pseudowords.json"
    if "--pseudomots" in sys.argv or not cible.exists():
        pseudo = pseudomots(lexique, set(formes), dictionnaire)
        ecrire(cible, {"version": 1, "language": "es", "pseudowords": pseudo})
        print(f"\n{len(pseudo)} non-mots écrits, à relire")
    print(f"\n{len(lexique)} lemmes écrits dans {SORTIE}")
    print("\nLes 40 masses écartées les plus lourdes (lemme proposé, forme) :")
    for cle, n in ecartes.most_common(40):
        print(f"  {round(n):>9}  {cle}")
    # Là se repèrent les lemmes inventés pour un verbe irrégulier (`LEMMES_FAUX`).
    print("\nLes verbes dont l'infinitif n'est pas une forme des sous-titres (verbe : formes) :")
    for e in lexique:
        if e["pos"] in ("VERB", "AUX") and e["lemma"] not in formes:
            haut = ", ".join(f for f, _ in sources[e["lemma"]].most_common(6))
            print(f"  {e['rank']:>5}  {e['lemma']} : {haut}")
    temoins = ["vino", "madre", "oficina", "universidad", "venir", "ciudad", "cerveza", "jamón"]
    rangs = {e["lemma"]: e["rank"] for e in lexique}
    print("\nTémoins :", {m: rangs.get(m) for m in temoins})


# --- Non-mots -------------------------------------------------------------------

VOYELLES = "aeiou"
# Relus à la main : un mot d'Amérique (milpa), une grossièreté, deux voyelles doublées.
PSEUDO_ECARTES = {"milpa", "putar", "senee"}
CONSONNES = {"b": "dgp", "c": "gpt", "d": "bgt", "f": "jls", "g": "bdc", "j": "fs", "l": "rn",
             "m": "nb", "n": "ml", "p": "tcb", "r": "ln", "s": "fz", "t": "pcd", "v": "bf", "z": "s"}


def pseudomots(lexique: list[dict], formes: set[str], dictionnaire: Dictionnaire, nombre: int = 80) -> list[str]:
    """Des non-mots qui ressemblent à de l'espagnol : un vrai mot de fréquence moyenne
    dont on change deux lettres (une consonne et une voyelle, de même famille). Rejeté
    s'il est un mot connu du dictionnaire ou des sous-titres."""
    # Les suites de consonnes des vrais mots, au début et au milieu : un non-mot qui en
    # a une autre (« tn », « mt ») se repère sans connaître l'espagnol.
    def groupes(mot: str) -> list[tuple[bool, str]]:
        return [(m.start() == 0, m.group()) for m in re.finditer(r"[^aeiouáéíóúü]+", mot)]

    vus: Counter = Counter()
    for e in lexique:
        for debut, g in groupes(e["lemma"]):
            vus[debut, g] += 1

    def prononcable(mot: str) -> bool:
        return all(vus[debut, g] >= 5 for debut, g in groupes(mot) if not mot.endswith(g) or debut)

    hasard = random.Random(17)
    bases = [e["lemma"] for e in lexique[800:4000]
             if e["pos"] in {"NOUN", "ADJ", "VERB"} and 5 <= len(e["lemma"]) <= 9
             and set(e["lemma"]) <= set("abcdefghijlmnoprstuvz")]
    hasard.shuffle(bases)
    sortie: list[str] = []
    for base in bases:
        lettres = list(base)
        consonnes = [i for i, c in enumerate(lettres[:-1]) if c in CONSONNES and i > 0]
        voyelles = [i for i, c in enumerate(lettres[:-1]) if c in VOYELLES]
        if not consonnes or not voyelles:
            continue
        i = hasard.choice(consonnes)
        lettres[i] = hasard.choice(CONSONNES[lettres[i]])
        j = hasard.choice(voyelles)
        lettres[j] = hasard.choice([v for v in VOYELLES if v != lettres[j]])
        mot = "".join(lettres)
        # c devant e/i et g devant e/i changent de son : on les évite, ils trahiraient le mot.
        if any(a in mot for a in ("ce", "ci", "ge", "gi", "qa", "qo", "zi", "ze")):
            continue
        if (not prononcable(mot) or mot in formes or mot in dictionnaire or mot in sortie
                or mot in PSEUDO_ECARTES):
            continue
        sortie.append(mot)
        if len(sortie) >= nombre:
            break
    return sorted(sortie)


def ecrire(chemin: Path, donnees: dict) -> None:
    """Un lemme par ligne : lisible, et un diff qui montre ce qui change."""
    cle_liste = next(k for k, v in donnees.items() if isinstance(v, list))
    tete = {k: v for k, v in donnees.items() if k != cle_liste}
    lignes = [json.dumps(e, ensure_ascii=False) for e in donnees[cle_liste]]
    texte = json.dumps(tete, ensure_ascii=False, indent=2)[:-2]
    texte += f',\n  "{cle_liste}": [\n    ' + ",\n    ".join(lignes) + "\n  ]\n}\n"
    json.loads(texte)
    chemin.write_text(texte, encoding="utf-8")


if __name__ == "__main__":
    main()
