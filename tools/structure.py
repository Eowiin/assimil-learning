"""
Pré-structure une leçon : content/ocr/L0NN.json → content/draft/L0NN.json.

La reconnaissance de texte est instantanée, la structuration coûtait ~10 min par
leçon. Ce script prend en charge la part mécanique de ces 10 minutes — celle où
l'erreur est invisible :

  - remise en ordre de lecture (voir `rows` : trier sur y seul mélange le texte) ;
  - séparation des deux colonnes, espagnol/notes à gauche, français/corrigés à droite ;
  - recollage des phrases numérotées, y compris quand l'OCR détache le numéro sur
    sa propre ligne — c'est le cas de la phrase 3 de la leçon 2 ;
  - retrait des appels de notes collés au texte (¡Hola ', Laura! → ¡Hola, Laura!),
    que l'OCR rend en ' " ^ ° ou en chiffre, parfois même en « ? » ;
  - découpage du bloc de prononciation, donné d'un seul tenant pour toute la
    leçon, en une transcription par phrase ;
  - découpage des exercices, dont les numéros cerclés ①..⑤ ressortent en glyphes
    imprévisibles (• ® © @ O) : on découpe sur la ponctuation, qui est fiable, et
    on les ignore ;
  - **contrôle du nombre de phrases contre le manifest**, seul garde-fou contre une
    perte silencieuse (voir README : l'exercice avalé de la leçon 2).

Ce qu'il ne fait PAS : les notes. Les rattacher demande de retrouver quel appel
portait sur quel mot, de recoller les fragments qui débordent d'une colonne sur
l'autre et de les réécrire. C'est de l'édition, pas de l'extraction : les notes
sont donc livrées brutes dans `_notesRaw`, à répartir à la main.

Le brouillon est écrit dans content/draft/, jamais dans Resources/text/ : c'est la
relecture qui promeut un fichier.

    python3 tools/structure.py L006 [L007 ...]   # produit les brouillons
    python3 tools/structure.py --check           # compare les brouillons : aux
                                                 # leçons relues à la main, et pour
                                                 # les autres à la transcription de
                                                 # l'audio (deux lectures
                                                 # indépendantes de la même leçon —
                                                 # ce sur quoi elles s'accordent est
                                                 # sûr, le reste est à relire)
"""

import json
import re
import statistics
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OCR = ROOT / "content" / "ocr"
DRAFT = ROOT / "content" / "draft"
TEXT = ROOT / "Resources" / "text"
MANIFEST = ROOT / "Resources" / "manifest.json"

SPLIT = 0.50  # frontière des colonnes, comme columns.py

# --- Ordre de lecture -----------------------------------------------------
def rows(lines: list[dict]) -> list[dict]:
    """
    Remet des lignes OCR dans l'ordre de lecture.

    Trier sur y ne suffit pas : Vision renvoie des cadres qui se chevauchent, et
    y est le haut du cadre. Un titre en gras suivi de son paragraphe peut donc
    sortir *après* lui (« Corrigé de l'exercice 1 » en leçon 1), et un fragment
    de fin de ligne sortir avant son début (le bloc de prononciation de la
    leçon 1, coupé en deux morceaux placés côte à côte). On regroupe donc les
    lignes en rangées par leur centre vertical, puis on ordonne sur x dans la
    rangée.
    """
    if not lines:
        return []
    ordered = sorted(lines, key=lambda l: l["y"] + l["height"] / 2)
    tol = 0.35 * statistics.median(l["height"] for l in lines)
    out: list[dict] = []
    row = [ordered[0]]
    center = ordered[0]["y"] + ordered[0]["height"] / 2
    for line in ordered[1:]:
        c = line["y"] + line["height"] / 2
        if abs(c - center) <= tol:
            row.append(line)
        else:
            out.extend(sorted(row, key=lambda l: l["x"]))
            row = [line]
            center = c
    out.extend(sorted(row, key=lambda l: l["x"]))
    return out

# --- Sections -------------------------------------------------------------
# Les ancres de section n'apparaissent pas toujours dans la même colonne :
# « Remarques de prononciation » est à droite en leçon 2, à gauche en leçon 5.
# On les cherche donc dans chaque colonne indépendamment.
SECTIONS = [
    ("pron_es", r"^\W*Prononciation\W*$"),
    ("notes",   r"^\W*Notes?\W*$"),
    ("pron_fr", r"^\W*Remarques de prononciation"),
    ("exo1_es", r"^\W*\d*\s*/?\s*Ejercicio\s*1"),
    ("exo1_fr", r"^\W*Corrig[ée]\s+de\s+l'exercice\s*1"),
    ("exo2_es", r"^\W*Ejercicio\s*2"),
    ("exo2_fr", r"^\W*Corrig[ée]\s+de\s+l'exercice\s*2"),
    ("break",   r"^\W*(\*\s*){3}\W*$"),
]

# Mobilier de page : en-têtes, pieds, et les intitulés français qui doublent les
# intitulés espagnols. Ces lignes n'ouvrent pas de section — les traiter comme des
# ancres envoyait tout le dialogue dans « l'en-tête ».
FURNITURE = [
    r"^\s*\d*\s*[•/]?\s*Lecci[óo]n\s+\w+",
    r"le[çc]on\s*/?\s*\d*\s*$",
    r"^\s*(Premi[èe]re|Deuxi[èe]me|Troisi[èe]me|Quatri[èe]me|Cinqui[èe]me"
    r"|\w+i[èe]me)\s+le[çc]on",
    r"^\s*Exercice\s*\d",
    r"^\s*\(chaque point repr[ée]sente",
    r"^\s*[•\d\s]*(uno|una|dos|tres|cuatro|cinco|seis|siete|ocho|nueve|diez"
    r"|once|doce|trece|catorce|quince|diecis[ée]is|diecisiete)\b",
    r"^\s*(uno|una|dos|tres|cuatro|cinco|seis|siete|ocho|nueve|diez|once|doce"
    r"|trece|catorce|quince|diecis[ée]is|diecisiete)\s*[\[(].*[\])]\s*[•\d\s]*$",
]

def is_caption(text: str) -> bool:
    """
    La phrase-vedette qui légende l'illustration est reprise en capitales
    (MI FAMILIA ES DE ANDALUCÍA). Elle tombe au milieu du bloc de prononciation
    ou des corrigés selon la page ; sans ce filtre elle s'y agrège.
    """
    letters = [c for c in text if c.isalpha()]
    return len(letters) > 6 and sum(c.isupper() for c in letters) / len(letters) > 0.8

def is_furniture(text: str) -> bool:
    return is_caption(text) or any(re.search(p, text, re.IGNORECASE) for p in FURNITURE)

def section_of(text: str) -> str | None:
    for name, pattern in SECTIONS:
        if re.search(pattern, text, re.IGNORECASE):
            return name
    return None

# Mots-outils français : leur absence signe une ligne de prononciation figurée.
FRENCH_WORDS = re.compile(
    r"(?<!\w)(est|les|des|de|du|la|le|il|elle|vous|nous|que|qui|pas|une|un|dans"
    r"|pour|par|sur|se|ne|on|au|aux|ce|cette|son|sa|ses|mais|avec|comme)(?!\w)",
    re.IGNORECASE)

def looks_phonetic(text: str) -> bool:
    return not FRENCH_WORDS.search(text)

def reunite_pron(col: dict[str, list[str]]) -> None:
    """
    En leçon 3, l'intertitre « Notes » est imprimé dans la marge à hauteur du bloc
    de prononciation : il le coupe en deux et la seconde moitié atterrit dans les
    notes. On rapatrie donc les lignes de tête qui sont manifestement de la
    prononciation figurée et non de la prose française.
    """
    if "pron_es" not in col or "notes" not in col:
        return
    while col["notes"] and looks_phonetic(col["notes"][0]):
        col["pron_es"].append(col["notes"].pop(0))

def split_sections(lines: list[str]) -> dict[str, list[str]]:
    """Découpe une colonne en sections ; « body » est ce qui précède la 1re ancre."""
    out: dict[str, list[str]] = {"body": []}
    current = "body"
    for line in lines:
        if not line.strip() or is_furniture(line):
            continue
        name = section_of(line)
        if name:
            current = name
            out.setdefault(name, [])
            continue
        out[current].append(line)
    reunite_pron(out)
    return out

# --- Nettoyage ------------------------------------------------------------
# Les appels de notes sont des exposants ; Vision les rend en ' " ^ ° ou en
# chiffre, tantôt détachés, tantôt collés au mot suivant. Aucun mot espagnol ne
# commence par une apostrophe et le caret n'existe ni en espagnol ni en français :
# ces formes sont des appels, pas de la ponctuation.
CALLS = [
    (r"\s+[\^°]+", ""),                    # exposant rendu en ^ ou °
    (r"\s+['\"]+(?=[\s?!,.:;]|$)", ""),    # appel détaché, avant ponctuation ou fin
    (r"\s+['\"]+(?=\w)", " "),             # appel collé au mot suivant
    (r"\s+\d{1,2}(?=[\s?!,.:;]|$)", ""),   # appel rendu en chiffre
    (r"\s+[?!](?=\s*[,;])", ""),           # appel rendu en « ? » : estás ?, guapa?
    (r"([?!])\1+", r"\1"),                 # ?? laissé par un appel avalé
]

TIDY = [
    (r"(?<!\.)\.\.(?!\.)", "..."),  # points de suspension amputés par l'OCR
    (r"\s+([,.;:!?])", r"\1"),   # espace parasite avant ponctuation
    (r"([¿¡«])\s+", r"\1"),      # ¿ Cómo → ¿Cómo
    (r"\s+", " "),
]

def clean(text: str) -> str:
    text = unicodedata.normalize("NFC", text)
    for pattern, repl in CALLS + TIDY:
        text = re.sub(pattern, repl, text)
    return text.strip()

def unpaired(text: str) -> str:
    """
    En espagnol, un « ? » est toujours ouvert par un « ¿ » : sans lui, ce n'est pas
    de la ponctuation mais un appel de note qu'a rendu l'OCR. C'est le cas de
    « Mucho gusto ? ¿Cómo está usted? » (leçon 4), où le point d'origine a été lu
    comme un point d'interrogation. L'orthographe permet donc de trancher au lieu
    de deviner : là où l'appel finit une phrase, on rétablit le point.
    """
    out, depth = [], {"?": 0, "!": 0}
    pairs = {"?": "¿", "!": "¡"}
    for i, c in enumerate(text):
        if c in "¿¡":
            depth["?" if c == "¿" else "!"] += 1
            out.append(c)
        elif c in "?!" :
            if depth[c] > 0:
                depth[c] -= 1
                out.append(c)
            else:
                rest = text[i + 1:]
                out.append("." if not rest.strip() or
                           re.match(r"\s+[¿¡«A-ZÁÉÍÓÚÑÜ]", rest) else "")
        else:
            out.append(c)
    return "".join(out)

def spanish(text: str) -> str:
    """
    L'espagnol n'emploie pas l'apostrophe : entre deux lettres, c'est un appel de
    note collé au mot (Él'es Rafa → Él es Rafa). La prononciation figurée, elle, en
    use pour marquer l'accent tonique — d'où ce nettoyage réservé au texte.
    """
    text = re.sub(r"(?<=[^\W\d_])['\u2019](?=[^\W\d_])", " ", text)
    return clean(unpaired(clean(text)))

def french(text: str) -> str:
    """Rétablit l'espace avant la ponctuation double, qu'Assimil respecte."""
    text = re.sub(r"(?<=[^\s])([?!;:»])", r" \1", text)
    return re.sub(r"\s+", " ", text).strip()

def capitalize(text: str) -> str:
    m = re.search(r"[^\W\d_]", text)
    return text[: m.start()] + text[m.start()].upper() + text[m.start() + 1:] if m else text

# --- Phrases numérotées ---------------------------------------------------
NUMBERED = re.compile(r"^\s*(\d{1,2})\s*[-–—]?\s+(.*\S.*)$")
LONE = re.compile(r"^\s*(\d{1,2})\s*$")

FINISHED = re.compile(r"""[.?!…]['"»\u2019]?$""")

def numbered(lines: list[str], expected: int) -> tuple[dict[int, list[str]],
                                                       list[str], list[str]]:
    """
    Reconstitue { numéro: lignes } et rend à part ce qui précède la phrase 1.

    Un numéro seul sur sa ligne valant « courant + 1 » désigne les lignes non
    numérotées qui viennent de passer : c'est ainsi que la leçon 2 rend sa
    phrase 3, dont le « 3 » suit son propre texte.

    Rend aussi ce qui traîne après la dernière réplique : une réplique est une
    phrase complète, donc une ligne qui suit une ponctuation finale n'en fait pas
    partie. En leçon 3, c'est la fin d'une note imprimée sans intertitre, qui
    s'agrégeait à la phrase 5. Ces lignes ne sont pas jetées mais rendues à part —
    la perte silencieuse est justement ce qu'on cherche à éviter.
    """
    items: dict[int, list[str]] = {}
    preamble: list[str] = []
    trailing: list[str] = []
    current: int | None = None
    buffer: list[str] = []

    def flush(target: int | None) -> None:
        nonlocal buffer
        if not buffer:
            return
        if target is None:
            preamble.extend(buffer)
        else:
            for line in buffer:
                done = items.get(target) and FINISHED.search(items[target][-1].strip())
                (trailing if done else items.setdefault(target, [])).append(line)
        buffer = []

    for line in lines:
        m = NUMBERED.match(line)
        lone = LONE.match(line)
        if m and 1 <= int(m.group(1)) <= expected:
            flush(current)
            current = int(m.group(1))
            items.setdefault(current, []).append(m.group(2))
        elif lone and 1 <= int(lone.group(1)) <= expected and current is not None:
            n = int(lone.group(1))
            if buffer and n == (current or 0) + 1:
                # Le numéro suivait son texte. Il ne réclame que ce qui commence
                # après la dernière ligne achevée : en leçon 4, « sœur. » termine la
                # phrase 1 et seul « Et voici... » appartient à la phrase 2.
                start = 0
                for j, line in enumerate(buffer[:-1]):
                    if re.search(r"[.?!…]['\"»]?$", line.strip()):
                        start = j + 1
                items.setdefault(current, []).extend(buffer[:start])
                buffer = buffer[start:]
                flush(n)
            else:
                flush(current)
            current = n
            items.setdefault(n, [])
        else:
            buffer.append(line)
    flush(current)
    return items, preamble, trailing

# --- Prononciation --------------------------------------------------------
def split_pron(block: list[str], expected: int) -> dict[int, str]:
    """
    Le bloc de prononciation couvre la leçon d'un seul trait, les numéros de
    phrase servant de séparateurs :
        qué sorpréssa 1 ola laouRa 2 ola paco qué SORpRéssa 3 como éstass...
    La tête, avant « 1 », est la prononciation du titre.
    """
    text = re.sub(r"\s+", " ", " ".join(block)).strip()
    pieces = re.split(r"(?<!\S)(\d{1,2})(?!\S)", text)
    out: dict[int, str] = {}
    if pieces[0].strip():
        out[0] = pieces[0].strip()
    for i in range(1, len(pieces) - 1, 2):
        n = int(pieces[i])
        if 1 <= n <= expected:
            # L'exposant d'un appel de note ressort en « * » dans la transcription.
            out[n] = re.sub(r"\s+", " ", pieces[i + 1]).strip(" .,*")
    return out

# --- Exercices ------------------------------------------------------------
# Frontières possibles entre deux phrases d'exercice.
#   - la ponctuation forte, fiable mais parfois avalée par l'OCR ;
#   - les numéros cerclés ①..⑤, qui ressortent en glyphes imprévisibles
#     (• ® © @ ◦), en chiffre nu, ou en capitale isolée (A, E, O) — jamais deux
#     fois les mêmes au fil des leçons.
# Aucune des deux ne suffit seule : la leçon 1 perd le « ! » de « quelle surprise »
# (rendu « / »), la leçon 5 perd le point après « français ». On coupe donc sur
# l'union, et le compte attendu vient du manifest.
BOUNDARY = re.compile(r"(?<=[.?!…])(?=\s)")
GLYPH = re.compile(r"[•®©@◦*✳]+|(?<=\s)\d{1,2}(?=\s)")
# Une capitale isolée ne vaut frontière que suivie d'une majuscule : sinon on
# couperait « Madrid o Barcelona » ou « il a Vu ».
LETTER = re.compile(r"(?<=\s)[AEO](?=\s+[¿¡«A-ZÁÉÍÓÚÑÜ])")
LEADING = re.compile(r"^(?:[•®©@◦*✳]+|\d{1,2}|[AEOaeo])\s+(?=\S)")
OPENERS = {"¿": "?", "¡": "!"}

def split_exercise(block: list[str], expected: int) -> list[str]:
    """Découpe les phrases d'exercice, données d'un seul tenant sur plusieurs lignes."""
    text = re.sub(r"\s+", " ", " ".join(block)).strip()

    parts = [text]
    for pattern in (BOUNDARY, GLYPH, LETTER):
        parts = [f for part in parts for f in pattern.split(part)]

    out = []
    for part in (p.strip() for p in parts):
        part = LEADING.sub("", part)
        if part and not re.fullmatch(r"[•®©@◦*✳\d\sAEO]+", part):
            out.append(part)

    # Une coupe en trop laisse un fragment qui ne commence pas comme une phrase :
    # on le recolle au précédent. On ne fusionne jamais dans l'autre sens — mieux
    # vaut signaler un compte faux que fabriquer une phrase.
    merged: list[str] = []
    for part in out:
        if merged and not re.match(r"[¿¡«A-ZÁÉÍÓÚÑÜ]", part):
            merged[-1] += " " + part
        else:
            merged.append(part)

    # Les phrases d'exercice sont des phrases complètes : une finale absente a été
    # perdue par l'OCR, et « / » y est un « ! » mal lu.
    final = []
    for part in merged:
        part = re.sub(r"\s*/\s*$", "!", part)
        if not re.search(r"[.?!…]['\"»]?$", part):
            part += OPENERS.get(part[0], ".")
        final.append(part)
    return final

# --- Assemblage -----------------------------------------------------------
def build(name: str, manifest: dict) -> dict:
    doc = json.loads((OCR / f"{name}.json").read_text())
    number = int(name[1:])
    lesson = manifest["lessons"][number - 1]
    n_dial = len(lesson["dialogue"])
    n_exo = len(lesson["exercise"])
    review: list[str] = []

    left: dict[str, list[str]] = {}
    right: dict[str, list[str]] = {}
    overflow: list[str] = []
    for index, page in enumerate(doc["pages"]):
        ordered = rows(page["lines"])
        for dest, col in (
            (left, [l["text"] for l in ordered if l["x"] < SPLIT]),
            (right, [l["text"] for l in ordered if l["x"] >= SPLIT]),
        ):
            for k, v in split_sections(col).items():
                # Le dialogue et le titre tiennent sur la première double page ;
                # au-delà, ce qui n'est sous aucun intertitre est la fin des notes,
                # qui déborde de page en page. L'y laisser entrer collait des
                # paragraphes de commentaire à la dernière phrase du dialogue.
                if k == "body" and index > 0:
                    overflow.extend(v)
                else:
                    dest.setdefault(k, []).extend(v)

    es_items, es_pre, es_tail = numbered(left.get("body", []), n_dial)
    fr_items, fr_pre, fr_tail = numbered(right.get("body", []), n_dial)
    if es_tail or fr_tail:
        review.append(f"{len(es_tail) + len(fr_tail)} ligne(s) après la dernière "
                      f"réplique versées aux notes — vérifier qu'aucune réplique "
                      f"n'y est passée")

    # Le titre est la dernière ligne avant la phrase 1 : ce qui précède est
    # l'avant-propos de la leçon 1 ou un reste d'en-tête.
    title_es = clean(es_pre[-1]) if es_pre else ""
    title_fr = french(clean(fr_pre[-1])) if fr_pre else ""
    if not title_es:
        review.append("titre espagnol introuvable")
    if not title_fr:
        review.append("titre français introuvable")

    pron = split_pron(left.get("pron_es", []), n_dial)

    sentences = []
    for n in range(1, n_dial + 1):
        es = spanish(" ".join(es_items.get(n, [])))
        fr = french(clean(" ".join(fr_items.get(n, []))))
        for label, value in (("espagnol", es), ("français", fr),
                             ("prononciation", pron.get(n, ""))):
            if not value:
                review.append(f"phrase {n} : {label} introuvable")
        sentences.append({"n": n, "es": es, "fr": fr,
                          "pron": pron.get(n, ""), "note": None})

    # Une réplique numérotée trouvée au-delà de la première double page et absente
    # de ce qu'on a recueilli signifie que le dialogue déborde : c'est le scénario
    # qui fait disparaître du texte sans rien dire.
    stray = sorted({n for l in overflow if (m := NUMBERED.match(l))
                    and (n := int(m.group(1))) <= n_dial
                    and not (es_items.get(n) or fr_items.get(n))})
    if stray:
        review.append(f"répliques {stray} trouvées au-delà de la première double "
                      f"page et nulle part ailleurs — dialogue à cheval sur deux pages")

    # Les 14 leçons de révision n'ont pas d'exercice : ne pas en chercher, comme
    # build-manifest.py ne s'attend pas à en trouver.
    if lesson["isReview"]:
        exo_es = exo_fr = []
    else:
        exo_es = split_exercise(left.get("exo1_es", []), n_exo)
        exo_fr = split_exercise(right.get("exo1_fr", []), n_exo)
        for label, got in (("phrases espagnoles", exo_es), ("corrigés français", exo_fr)):
            if len(got) != n_exo:
                review.append(f"exercice : {len(got)} {label} découpés pour "
                              f"{n_exo} fichiers audio")

    exercise = [{
        "n": i + 1,
        "es": capitalize(spanish(exo_es[i])) if i < len(exo_es) else "",
        "fr": capitalize(french(clean(exo_fr[i]))) if i < len(exo_fr) else "",
    } for i in range(n_exo)]

    exercise2 = None
    exercise2_raw = None
    if not lesson["isReview"]:
        exercise2, exo2_review = draft_exercise2(left.get("exo2_es", []), right.get("exo2_fr", []))
        exercise2_raw = {"es": left.get("exo2_es", []), "fr": right.get("exo2_fr", [])}
        review.extend(exo2_review)

    # Assimil éclate les notes : le bloc « Notes » de la page de gauche, mais aussi
    # la fin du bloc « Remarques de prononciation » de la page de droite, où les
    # remarques de langue suivent celles de prononciation sans intertitre. Les deux
    # sont livrés bruts : c'est le lecteur qui les répartit.
    notes_raw = [l for l in left.get("notes", []) + right.get("notes", [])
                 + es_tail + fr_tail + overflow if l.strip()]
    remarks_raw = [l for l in left.get("pron_fr", []) + right.get("pron_fr", [])
                   if l.strip()]
    if not notes_raw and not remarks_raw and n_dial:
        review.append("aucune note reconnue — vérifier l'ancre « Notes »")

    draft = {
        "number": number,
        "titleES": title_es,
        "titleFR": title_fr,
        "sentences": sentences,
        "exercise": exercise,
    }
    if exercise2 is not None:
        # Sous « _exercise2 » et non « exercise2 » : le gabarit espagnol reste à
        # composer, et un brouillon promu tel quel ne doit pas passer pour importé.
        draft["_exercise2"] = exercise2
        draft["_exercise2Raw"] = exercise2_raw
    draft.update({"_notesRaw": notes_raw, "_remarksRaw": remarks_raw, "_review": review})
    return draft

# --- Exercice 2 -------------------------------------------------------------
# « Ejercicio 2 – Complete » : la phrase française, puis l'espagnol amputé de mots
# en pointillés ; le corrigé ne donne que les mots manquants, les parties
# imprimées remplacées par des tirets :  ① – estás  ② Estoy – gracias  …
#
# L'OCR lit bien le français et le corrigé, mal les gabarits : les pointillés
# ressortent en « •• », « i...? », « (.. », et une ligne de gabarit passe parfois
# dans l'autre colonne. Le script rend donc les consignes et les réponses par
# phrase, et laisse le gabarit « es » vide : c'est lui qu'on compose à la main,
# trous entre crochets (voir LessonText.swift). Aucun trou n'est deviné.
FRENCH_PROMPT_WORDS = re.compile(
    r"(?<!\w)(je|tu|il|elle|nous|vous|ils|en|et|mon|ma|mes|ton|ta|très|oui|non)(?!\w)",
    re.IGNORECASE)
FRENCH_ONLY = re.compile(r"[àâçèêëîïôûùœ]|\s[?!:;]$", re.IGNORECASE)
ITEM_MARK = re.compile(r"(?:(?<=\s)|^)(?:[•®©@◦*✳]+|\d{1,2}|[OE0])(?=\s|[-–])")
DASH = re.compile(r"\s*[-–—]\s*")

def is_french_prompt(line: str) -> bool:
    text = LEADING.sub("", line.strip())
    if ".." in text or "…" in text or re.search(r"[¿¡•]", text):
        return False  # un gabarit : pointillés ou ponctuation espagnole
    if not re.search(r"[^\W\d_]{2,}", text):
        return False
    return bool(FRENCH_WORDS.search(text) or FRENCH_PROMPT_WORDS.search(text)
                or FRENCH_ONLY.search(text))

def split_answers(block: list[str]) -> list[list[str]]:
    """
    Les mots manquants, par phrase : ce qui n'est pas un tiret dans le corrigé.

    Le corrigé s'écrit tout en tirets ; la prose qui le suit sur la page n'en a pas
    et n'est pas toujours séparée par « *** » (leçons 2 et 3). On s'arrête donc à la
    première ligne sans tiret, faute de quoi un paragraphe devenait une réponse.
    """
    lines = []
    for line in block:
        if lines and not DASH.search(line):
            break
        lines.append(line)
    text = re.sub(r"\s+", " ", " ".join(lines)).strip()
    items = [part for part in ITEM_MARK.split(text) if part.strip()]
    return [[a for a in (s.strip(" .,;") for s in DASH.split(item)) if a] for item in items]

def lost_marks(block: list[str]) -> bool:
    """
    Deux tirets de suite dans le corrigé : la fin d'une phrase et le début de la
    suivante, dont le numéro cerclé a disparu (leçon 2 : « es de - - dónde eres »).
    """
    return bool(re.search(r"[-–]\s+[-–]", " ".join(block)))

def draft_exercise2(es_lines: list[str], fr_lines: list[str]) -> tuple[dict, list[str]]:
    prompts = [french(clean(LEADING.sub("", l.strip()))) for l in es_lines if is_french_prompt(l)]
    answers = split_answers(fr_lines)
    review = []
    if not prompts and not answers:
        review.append("exercice 2 introuvable — vérifier l'ancre « Ejercicio 2 »")
    elif len(prompts) != len(answers):
        review.append(f"exercice 2 : {len(prompts)} consignes françaises pour "
                      f"{len(answers)} corrigés — l'OCR a fusionné ou perdu une phrase")
    # Deux pertes peuvent se compenser (leçon 2 : une consigne passée dans l'autre
    # colonne, un numéro cerclé avalé) : un corrigé vide ou chargé est suspect.
    suspicious = [i + 1 for i, a in enumerate(answers) if not a or len(a) > 3]
    if suspicious:
        review.append(f"exercice 2 : corrigé douteux pour les phrases {suspicious}")
    if lost_marks(fr_lines):
        review.append("exercice 2 : « - - » dans le corrigé, un numéro de phrase a été "
                      "avalé — les réponses sont décalées")
    if prompts or answers:
        review.append("exercice 2 : gabarits espagnols à composer à la main depuis "
                      "le livre (trous entre crochets), puis renommer « _exercise2 » "
                      "en « exercise2 »")
    items = [{
        "n": i + 1,
        "fr": prompts[i] if i < len(prompts) else "",
        "es": "",
        "_answers": answers[i] if i < len(answers) else [],
    } for i in range(max(len(prompts), len(answers)))]
    return {"items": items}, review

# --- Contrôle contre les leçons relues -----------------------------------
WORD = re.compile(r"[a-záéíóúüñ]+", re.IGNORECASE)

def cross_check(name: str, ref: dict, got: dict) -> tuple[int, int, list[str]]:
    """
    Recoupe le brouillon OCR avec la transcription de l'audio (asr-to-text.py).

    Les deux sources sont indépendantes : l'une lit la page, l'autre écoute
    l'enregistrement. Là où elles disent les mêmes mots, la phrase est sûre et la
    relecture peut passer vite ; là où elles divergent, c'est exactement ce qu'il
    faut regarder. On compare les mots seuls — la ponctuation d'une transcription
    est approchée par nature, l'opposer au livre ne dirait rien.
    """
    agree = total = 0
    disagreements = []
    for kind, r_items, g_items in (("phrase", ref["sentences"], got["sentences"]),
                                   ("exercice", ref["exercise"], got["exercise"])):
        by_n = {g["n"]: g for g in g_items}
        for r in r_items:
            g = by_n.get(r["n"])
            total += 1
            audio = WORD.findall((r.get("es") or "").lower())
            ocr = WORD.findall(((g or {}).get("es") or "").lower())
            if audio == ocr:
                agree += 1
            else:
                disagreements.append(f"  {kind} {r['n']}\n"
                                     f"     audio : {' '.join(audio)}\n"
                                     f"     scan  : {' '.join(ocr)}")
    return agree, total, disagreements

def check(names: list[str]) -> int:
    total = same = 0
    for name in names:
        ref_path, draft_path = TEXT / f"{name}.json", DRAFT / f"{name}.json"
        if not (ref_path.exists() and draft_path.exists()):
            continue
        ref = json.loads(ref_path.read_text())
        got = json.loads(draft_path.read_text())

        # Une référence issue de l'audio n'est pas une leçon relue : la comparer
        # champ par champ n'aurait aucun sens (elle n'a ni français, ni notes).
        # C'est un recoupement entre deux lectures indépendantes de la même leçon.
        if ref.get("source") == "audio":
            agree, count, disagreements = cross_check(name, ref, got)
            print(f"{name} : recoupement scan / audio — {agree}/{count} phrases "
                  f"concordantes")
            for d in disagreements:
                print(d)
            continue

        problems = []

        def cmp(label: str, a, b) -> None:
            nonlocal total, same
            total += 1
            if (a or "") == (b or ""):
                same += 1
            else:
                problems.append(f"  {label}\n      relu : {a!r}\n    obtenu : {b!r}")

        cmp("titleES", ref["titleES"], got["titleES"])
        cmp("titleFR", ref["titleFR"], got["titleFR"])
        for r, g in zip(ref["sentences"], got["sentences"]):
            for k in ("es", "fr", "pron"):
                cmp(f"phrase {r['n']} {k}", r.get(k), g.get(k))
        for r, g in zip(ref["exercise"], got["exercise"]):
            for k in ("es", "fr"):
                cmp(f"exercice {r['n']} {k}", r.get(k), g.get(k))

        print(f"{name} : {'identique' if not problems else f'{len(problems)} écart(s)'}")
        for p in problems:
            print(p)

    if total:
        print(f"\n{same}/{total} champs identiques ({100 * same / total:.0f} %) — "
              f"notes exclues, elles restent manuelles")
    return 0 if same == total else 1

def main() -> int:
    if not MANIFEST.exists():
        print("Resources/manifest.json absent — lancer build-manifest.py d'abord",
              file=sys.stderr)
        return 1
    manifest = json.loads(MANIFEST.read_text())

    args = sys.argv[1:]
    checking = "--check" in args
    names = [a for a in args if not a.startswith("--")] or \
            [p.stem for p in sorted(OCR.glob("L*.json"))]

    DRAFT.mkdir(parents=True, exist_ok=True)
    flagged = []
    for name in names:
        if not (OCR / f"{name}.json").exists():
            print(f"{name} : pas de sortie OCR", file=sys.stderr)
            flagged.append(name)
            continue
        draft = build(name, manifest)
        (DRAFT / f"{name}.json").write_text(
            json.dumps(draft, ensure_ascii=False, indent=2) + "\n")
        review = draft["_review"]
        print(f"{name} : {len(draft['sentences'])} phrases, "
              f"{len(draft['exercise'])} exercice, "
              f"{len(draft['_notesRaw']) + len(draft['_remarksRaw'])} "
              f"lignes de notes à répartir"
              + ("  ⚠ " + " ; ".join(review) if review else ""))
        if review:
            flagged.append(name)

    print(f"→ {DRAFT.relative_to(ROOT)}/")
    if checking:
        print()
        return check(names)
    return 1 if flagged else 0

if __name__ == "__main__":
    sys.exit(main())
