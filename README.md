# Assimil Espagnol — app iOS personnelle

Le livre et l'audio Assimil réunis dans une app iPhone, pour faire sa séance
quotidienne sans être assis au bureau.

**Usage strictement personnel.** Le contenu Assimil (audio et texte) n'est jamais
versionné ni distribué — voir `.gitignore`.

## Organisation

```
audio-source/          copie intacte des mp3 d'origine (jamais modifiée)
Resources/audio/       audio converti, embarqué dans l'app
Resources/manifest.json  index des leçons, généré
Resources/text/        texte des leçons relu et validé (L001.json…)
scans/                 PDF des doubles pages, hors dépôt
content/               sorties OCR, transcriptions audio, brouillons — hors dépôt
AssimilES/             sources SwiftUI
tools/                 scripts de préparation des données
```

Les originaux vivent dans `~/Documents/assimil-3135414906918-methode-espagnol`
et ne doivent **jamais** être modifiés : `audio-source/` en est une copie.

## Préparer les données

```bash
./tools/build-audio.sh          # mp3 320k stéréo -> AAC 64k mono normalisé
python3 tools/build-manifest.py # -> Resources/manifest.json, avec contrôles
swift tools/transcribe.swift    # -> content/asr/, texte espagnol des 100 leçons
python3 tools/asr-to-text.py    # -> Resources/text/, pour les leçons sans livre
python3 tools/verify-clips.py   # relit les clips signalés au ralenti
swift tools/audio-smoke-test.swift  # vérifie l'enchaînement fichier/silence
```

`build-audio.sh` accepte un motif pour retraiter une seule leçon : `./tools/build-audio.sh L006`.
La conversion est incrémentale (un fichier déjà converti est ignoré).

Résultat : 100 leçons, 1899 fichiers, 2 h 59 d'audio, **641 Mo → 69 Mo**.

### Particularités de la source, déjà traitées

- Les leçons **6, 48 et 58** nomment leur exercice `ST` au lieu de `T`.
  `build-audio.sh` normalise en `T`, et `build-manifest.py` échoue si ces trois
  leçons perdent leur exercice.
- Les 14 leçons de **révision** (7, 14, … 98) n'ont pas d'exercice : c'est normal.
- Le dossier `ASSIMIL Spanish/` de la source contient les leçons entières,
  redondantes avec les segments : il n'est pas copié.
- Chaque mp3 embarquait une pochette JPEG pesant plus que l'audio lui-même.

## Le texte espagnol vient de l'audio, le reste vient du livre

Deux sources alimentent `Resources/text/`, et elles ne donnent pas la même chose.

| | Espagnol | Français | Prononciation | Notes |
|---|---|---|---|---|
| Transcription de l'audio | oui, 100 leçons | — | — | — |
| Saisie du livre | oui | oui | oui | oui |

**La transcription rend l'espagnol des 100 leçons sans scanner une seule page.**
La source étant découpée phrase par phrase, chaque fichier contient une réplique et
une seule : le numéro du fichier *est* le numéro de la phrase, il n'y a aucun
alignement à faire. C'est ce qui rend l'écran de lecture utilisable partout dès
maintenant, alors que la saisie du livre avance leçon par leçon.

```bash
swift tools/transcribe.swift        # 100 leçons, ~3 min, incrémental
python3 tools/asr-to-text.py        # écrit Resources/text/ pour les leçons sans livre
```

`transcribe.swift` utilise `SpeechTranscriber` (macOS 26) : modèle espagnol
téléchargé une fois, reconnaissance **entièrement locale**. L'ancienne API
`SFSpeechRecognizer` n'était pas utilisable ici — faute de modèle `es-ES` installé,
elle basculait sur les serveurs d'Apple, ce qui aurait envoyé l'audio Assimil au
réseau.

`asr-to-text.py` **n'écrase jamais** un fichier saisi depuis le livre : la relecture
fait foi, la transcription ne comble que les trous. Les fichiers issus de l'audio
portent `"source": "audio"`.

### Ce que vaut la transcription

Mesuré contre les 5 leçons relues depuis le livre, sur 50 phrases :

- **99,5 % des mots corrects** (215 sur 216), **49 phrases sur 50 identiques mot
  pour mot**. Le seul mot manqué est l'interjection `Ejem...`.
- **72 % identiques au caractère près.** L'écart est presque entièrement de la
  ponctuation : Assimil écrit `¡Hola, Laura!` là où la reconnaissance rend
  `Hola Laura.` — les exclamations ressortent en points, quelques virgules
  manquent. Les `¿` et `¡` ouvrants sont rétablis mécaniquement quand la phrase se
  termine par `?` ou `!` sans marque ouvrante ; la règle place l'ouvrante après la
  dernière virgule, ce qui donne juste jusque dans `…a las ocho, ¿vale?`.

Autrement dit : **fiable pour lire en écoutant, approximatif à la virgule près.**
La saisie du livre reste ce qui apporte la traduction, la prononciation figurée, les
notes — et la ponctuation exacte.

### Les répliques signalées

`asr-to-text.py` compare la durée de chaque clip à ce que sa transcription explique,
au débit médian mesuré sur le corpus (11 car/s, plus ~1 s de silence de garde). Un
écart de plus de 2,5 s sort une liste de **11 clips sur 1613** : soit des mots
avalés — `A ver,` seul sur 5 secondes en leçon 87 —, soit une diction lente
légitime : une plaque épelée, un numéro de téléphone, un compte à rebours.

Le seuil vit dans `asr-to-text.py`, pas dans `transcribe.swift` : la transcription
stocke des faits (texte, confiance, durée), l'interprétation est gratuite et
recalibrable sans tout refaire.

### Séparer les deux causes sans réécouter

Le signalement ne distingue pas un mot avalé d'une diction lente : les deux laissent
du temps inexpliqué. `verify-clips.py` ralentit le clip à 0,6× et le repasse en
reconnaissance — la machine fait la réécoute.

```bash
python3 tools/verify-clips.py            # tous les clips signalés
python3 tools/verify-clips.py L087/S04   # seulement celui-là
```

    normal   L087 S04 : « A ver, »
    ralenti  L087 S04 : « A ver. Uno, dos. »

Là où la seconde lecture rend les mêmes mots, rien n'a été avalé. Là où elle en rend
davantage, le script montre lesquels : la vérification porte sur une phrase précise,
déjà reconstituée. **Sur les 11 clips signalés : 8 sans perte, 2 avec des mots
perdus, 1 sans texte du tout** — la leçon 76 commence par un éternuement, que la
lecture ralentie rend `Haches`. Il reste donc une phrase à écouter, pas onze.

Les deux pertes confirmées sont la troncature `A ver,` de la leçon 87, et
l'interjection `Ejem` de la leçon 26 — le même mot que le seul manqué sur les cinq
leçons de contrôle. Le script les signale sans les corriger : une lecture ralentie
reste une lecture machine, et c'est la relecture qui promeut un texte.

La comparaison ignore l'accentuation, la ponctuation **et les espaces**. Ce dernier
point n'est pas cosmétique : une plaque rendue `XH553` puis `XH 553` est le même
contenu réécrit autrement, et un découpage en mots la comptait pour deux mots perdus.
Trois des cinq premières alertes étaient de cette nature.

`transcribe-files.swift` transcrit des chemins quelconques et rend du JSON, là où
`transcribe.swift` parcourt le manifest : c'est ce qui permet de soumettre un clip
transformé sans rien changer aux données du projet.

## Ajouter le texte du livre pour une leçon

Fait pour les leçons **1 à 5**. Les suivantes n'ont que l'espagnol transcrit —
utilisable, mais sans traduction ni notes.

1. Scanner la double page, **un PDF par leçon** (`L006.pdf`), vers `scans/`.
   Le plus simple : dans le Finder, clic droit dans le dossier → *Importer depuis
   l'iPhone* → **Numériser des documents**. Le PDF atterrit directement au bon
   endroit, redressé et contrasté.
2. `swift tools/ocr.swift scans/L006.pdf` → `content/ocr/L006.json`, texte reconnu
   avec ses positions.
3. `python3 tools/columns.py L006` — sépare les deux colonnes de la page
   (espagnol et notes à gauche, français et corrigés à droite) pour rendre le
   texte relisible. Vision restitue les lignes dans un ordre qui entrelace les
   colonnes ; sans cette étape, la transcription est illisible.
4. `python3 tools/structure.py L006` → brouillon `content/draft/L006.json`, au
   format ci-dessous. Le script rend les titres, les répliques, les traductions,
   la prononciation par phrase et les deux versions de l'exercice ; il **ne
   rattache pas les notes**, livrées brutes dans `_notesRaw` et `_remarksRaw`.
5. Relire le brouillon, répartir les notes, puis le déplacer en
   `Resources/text/L006.json` — c'est la relecture qui promeut un fichier, jamais
   le script.

Le format cible :

```json
{
  "number": 1,
  "titleES": "…",
  "titleFR": "…",
  "sentences": [{ "n": 1, "es": "…", "fr": "…", "pron": "…", "note": "…" }],
  "exercise":  [{ "n": 1, "es": "…", "fr": "…" }]
}
```

Le `n` est ce qui apparie le texte et l'audio : il doit correspondre au numéro du
fichier (`S01.m4a` → `n: 1`).

**Vérifier systématiquement que le nombre de phrases correspond au manifest.**
C'est le seul garde-fou contre une perte silencieuse (voir ci-dessous).
`structure.py` fait ce contrôle et signale l'écart au lieu de le combler : il sort
en erreur dès qu'une réplique, une prononciation ou un corrigé manque à l'appel.

### Ce que `structure.py` reprend à la main, et pourquoi

Le pilote avait mesuré ~10 min par leçon, presque entièrement passées à la
structuration. Ce qui coûtait ce temps est précisément ce qui se prête mal à
l'œil : chaque cas ci-dessous a été trouvé en rejouant le script sur les cinq
leçons déjà relues, puis en comparant champ par champ.

- **Ordre de lecture.** Trier les lignes sur leur `y` ne suffit pas : Vision rend
  des cadres qui se chevauchent. Un intertitre en gras sort *après* son
  paragraphe (leçon 1, « Corrigé de l'exercice 1 ») et une fin de ligne sort
  avant son début (le bloc de prononciation de la leçon 1, coupé en deux
  morceaux côte à côte). On regroupe donc les lignes en rangées par leur centre
  vertical, puis on ordonne sur `x`.
- **Numéro de réplique détaché.** L'OCR le pose parfois sur sa propre ligne,
  *après* le texte qu'il désigne (leçon 2, phrase 3) — et il ne réclame alors que
  ce qui commence après la dernière ponctuation finale, sinon la phrase 1 de la
  leçon 4 perd son dernier mot.
- **Appels de notes.** Rendus en `'`, `"`, `^`, `°`, en chiffre, et jusqu'en `?` :
  `Mucho gusto ? ¿Cómo está usted?` (leçon 4) où le point d'origine est devenu un
  point d'interrogation. L'orthographe espagnole tranche : un `?` sans `¿` qui
  l'ouvre n'est pas de la ponctuation.
- **Numéros cerclés ①..⑤ des exercices.** Jamais deux fois le même glyphe
  (`• ® © @ O E`), et la ponctuation de fin de phrase disparaît elle aussi
  (leçon 1, `quelle surprise !` lu `quelle surprise /`). On coupe sur l'union des
  deux indices, et le manifest arbitre le compte.
- **Notes imprimées sans intertitre.** Elles débordent d'une colonne sur l'autre
  et d'une double page sur la suivante ; en leçon 3 la fin d'une note s'agrégeait
  à la phrase 5, en leçon 5 des paragraphes entiers de commentaire. Une réplique
  étant une phrase complète, ce qui suit sa ponctuation finale part aux notes —
  et le script le signale, pour le cas où une vraie réplique y serait passée.

Mesure sur les cinq leçons relues : **128 champs sur 135 identiques (95 %)**,
notes exclues. Les 7 écarts restants sont des caractères mal lus, hors de portée
d'un analyseur : `Rocío` → `Rocio`, `mouï` → `mouj`, un `d` rendu `®`. Cinq
tombent dans la prononciation figurée, deux dans un prénom.

    python3 tools/structure.py --check    # rejoue la comparaison

### Le recoupement scan / audio

Pour une leçon dont le livre n'est pas encore saisi, `--check` ne compare pas le
brouillon à une référence relue — il n'y en a pas. Il le compare à la transcription
de l'audio, et c'est plus utile : **deux lectures indépendantes de la même leçon**,
l'une qui lit la page, l'autre qui écoute l'enregistrement. Là où elles s'accordent,
la phrase est sûre et la relecture peut passer vite ; là où elles divergent, c'est
exactement ce qu'il faut regarder.

La comparaison porte sur les mots seuls : opposer la ponctuation d'une transcription
à celle du livre ne dirait rien, elle est approchée par construction.

Vérifié sur la leçon 1 : **10 phrases sur 10 concordantes** entre le scan et l'audio.
C'est le contrôle que le plan appelait « recoupement Whisper », obtenu sans Whisper
et sans quitter la machine.

### Ce que le pilote sur 5 leçons a appris

- **Qualité** : 484 lignes reconnues, une seule peu fiable (des pointillés
  d'exercice à trous). L'OCR local est excellent sur de l'imprimé.
- **Coût réel** : ~10 min par leçon. La reconnaissance est instantanée ; c'est la
  structuration qui prend le temps — détacher les appels de notes collés aux
  phrases (`¡Hola ', Laura!` → `¡Hola, Laura!`), répartir le bloc de prononciation
  par phrase, rattacher chaque note à sa phrase.
- **Orientation** : 3 pages sur 10 étaient photographiées à 90°. Vision lit
  pourtant le texte correctement, mais rend des coordonnées dans le repère tourné,
  ce qui mélange les colonnes. `ocr.swift` mesure donc l'angle médian des lignes,
  redresse l'image et relit.
- **Le redressement n'est pas cosmétique** : avant correction, l'OCR avait avalé
  les trois premières phrases de l'exercice de la leçon 2 — sans erreur, sans
  signal, juste une absence. Le redressement les a récupérées et a corrigé les
  accents au passage.

**L'app fonctionne sans ce texte.** Les trois modes n'utilisent que l'audio. La
saisie du livre peut donc suivre l'avancement des leçons sans jamais bloquer
l'usage : elle ajoute la traduction sous la phrase, la prononciation figurée et les
notes, elle ne conditionne rien.

La liste des leçons distingue toujours trois états — « audio seul », « espagnol
seul », complet — sur `hasText` et `hasTranslation`. Ce n'est plus une question de
mode disponible, mais de ce que l'écran de lecture peut montrer : sans `fr`, il n'y
a pas de traduction à révéler sous la phrase.

## Construire l'app

```bash
xcodebuild -project AssimilES.xcodeproj -scheme AssimilES \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Pour l'iPhone, sans passer par Xcode :

```bash
xcodebuild -project AssimilES.xcodeproj -scheme AssimilES -sdk iphoneos \
  -destination 'platform=iOS,id=<identifiant appareil>' \
  -allowProvisioningUpdates build
xcrun devicectl list devices          # pour retrouver l'identifiant
xcrun devicectl device install app --device <identifiant> <chemin>/AssimilES.app
```

L'équipe de signature (`DEVELOPMENT_TEAM`) est déjà renseignée dans le projet.
Pour des mises à jour sans fil sur la durée, passer par TestFlight.

Le projet utilise les *synchronized file groups* de Xcode 16+ : tout fichier
ajouté sous `AssimilES/` est pris en compte sans toucher au projet.

## Deux décisions non évidentes

**Les pauses sont du silence diffusé, pas un minuteur.** iOS suspend une app en
arrière-plan dès que sa session audio cesse de produire du son. Une pause de
répétition gérée par minuteur tuerait la séance dès que le téléphone est en poche.
`SessionPlayer` planifie donc un buffer de silence de la durée exacte : le flux
audio ne s'interrompt jamais. Mesuré par `audio-smoke-test.swift` : décalage
constant de ~0,12 s (latence de sortie), sans dérive cumulative.

**Le retour arrière relance la phrase en cours.** C'est le comportement standard
d'un lecteur, et au casque la triple pression tombe donc naturellement sur
« refais-la moi » — le geste le plus fréquent en répétition — sans détourner
l'icône ⏭ de l'écran verrouillé de son sens habituel.
