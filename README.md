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

## La séance du jour

Une séance quotidienne, c'est **une nouvelle leçon et ses activités**, validée une
fois. L'accueil la présente en étapes, et chaque étape se retrouve telle quelle si
l'app est fermée en route :

1. **Découverte** — le dialogue d'un trait, sans pause.
2. **Compréhension** — le texte, la traduction, la prononciation et les notes, tout
   visible, chaque phrase réécoutable.
3. **Répétition** — chaque phrase rejouée **3 fois** par défaut, chaque passage suivi
   de sa pause. Un repère pratique, réglable (1 à 6), pas une règle Assimil. ⏭ saute
   les répétitions restantes, ⏮ repart de la première.
4. **Exercice 1** — traduire.
5. **Exercice 2** — compléter.

**La validation est le bouton de la dernière activité.** Quand toutes les autres
étapes sont faites, il devient « Valider la séance » : il termine l'étape, valide la
séance et ramène à l'accueil, qui dit « terminée » et propose de retravailler la leçon
demain. S'il reste une étape en arrière (on peut y revenir par la bande d'étapes), il
mène à la liste de ce qui manque. L'ancien écran « Fin de séance » ne faisait que
redire cette liste avant un bouton.

**Une étape ne se termine que par un geste.** Ni la fin d'une piste, ni un saut à la
dernière phrase, ni la sortie du lecteur : la fin de l'audio met le bouton « Passer
aux exercices » en avant, elle ne l'actionne pas. C'est ce qui empêche une écoute de
valider une leçon — l'ancienne version posait `completedAt` en fin de lecture.

Les pauses restent du silence diffusé par `SessionPlayer` ; la répétition n'ajoute
que des étapes, pas de minuteur.

### Ce que le livre demande dans les exercices

Relu dans l'OCR des leçons 1 à 5, identique sur les cinq, et encore le même en
leçon 51 — la deuxième vague n'ajoute aucun type d'exercice :

- **« Ejercicio 1 – Traduzca / Exercice 1 – Traduisez »** : l'énoncé est en
  **espagnol**, le corrigé en **français**. L'audio `T01…` dit l'énoncé. On lit ou
  écoute, puis on traduit : au micro, ou de tête avant d'afficher le corrigé (voir
  « Répondre à voix haute »).
- **« Ejercicio 2 – Complete / Exercice 2 – Complétez »**, *« chaque point représente
  une lettre ou un caractère »* : la phrase française, l'espagnol amputé de mots, et un
  corrigé qui ne donne **que les mots manquants**.

**Importé pour les leçons 1 à 5**, lu sur les scans et non sur l'OCR : les pointillés
y sont illisibles. Chaque gabarit est recoupé avec le corrigé du livre — les mots entre
crochets sont exactement ceux du corrigé, dans l'ordre — et avec le nombre de points.
Aucune variante n'est ajoutée, le livre n'en donne pas. Là où le corrigé écrit un seul
morceau (`– Sí, claro –`) mais que la page imprime la virgule entre deux pointillés,
le gabarit suit la page : deux trous. Les leçons suivantes attendent leurs scans.

L'exercice 2 se saisit dans le JSON de la leçon, phrase espagnole entière, trous
entre crochets, variantes admises séparées par `|` (la première est celle du livre
et règle le nombre de points) :

```json
"exercise2": {
  "items": [
    { "n": 2, "fr": "Je vais bien, merci.", "es": "[Estoy] bien, [gracias]." }
  ]
}
```

**La correction suit une politique écrite, pas une tolérance floue** (`FillInGrader`) :

| | Règle | Pourquoi |
|---|---|---|
| Espaces | ignorés aux bords, suites réduites | ce n'est pas du contenu |
| Ponctuation | non notée | elle est imprimée autour du trou |
| Majuscules | acceptées, la forme du livre est montrée | elle tient à la place du mot |
| Accents, ñ | **exigés** — « presque : vérifie les accents » | tú/tu, él/el, sí/si, año/ano |
| Variantes | seulement celles saisies | rien n'est deviné |

Chaque trou est jugé seul ; une phrase est faite quand tous sont acceptés, ou quand
la correction a été affichée. Un trou refusé reste modifiable pour réessayer.

`tools/structure.py` extrait désormais du scan **les consignes françaises et les mots
du corrigé**, par phrase, sous `_exercise2` dans le brouillon. Il laisse le gabarit
`es` vide : l'OCR lit mal les pointillés, et un trou ne se devine pas. Sur les cinq
leçons, les leçons 1, 3 et 4 sortent justes. En leçon 5 un numéro cerclé avalé fusionne
deux corrigés ; en leçon 2, s'y ajoute une consigne passée dans l'autre colonne, et les
deux pertes se compensent au compte. Le script les signale toutes deux — la seconde
par le double tiret que laisse le numéro disparu. Le corrigé s'arrête aussi à la
première ligne sans tiret : sans séparateur `***`, la prose de la page devenait une
réponse.

### Répondre à voix haute

En traduction comme en deuxième vague, chaque phrase se répond **au micro** ou **de
tête**. Au micro, la reconnaissance locale — la même que pour la prononciation, en
français pour la traduction, en espagnol pour la vague — rend ce qui a été dit, et
`SpokenCheck` le compare à la réponse attendue avec la règle de `SpanishMatch` :
accents, ponctuation, majuscules et espaces ignorés. Rien ne sort du téléphone.

**L'app dit « identique » ou « pas identique », jamais « même sens ».**

| | Identique | Pas identique |
|---|---|---|
| Deuxième vague (→ espagnol) | réussie, sans geste | mots manquants en orange ; réessayer ou « Pas encore » |
| Traduction (→ français) | réussie, sans geste | ce qui a été entendu, mots du corrigé manquants ; « Même sens » ou « Pas encore » |

Juger le sens n'est pas à la portée de l'appareil. Le corrigé d'Assimil n'est qu'une
traduction possible — « Comment tu vas ? » vaut « Comment vas-tu ? ». Le modèle de
langue local d'Apple exige Apple Intelligence, absent de l'iPhone 11. La proximité
entre phrases de NaturalLanguage tourne sur l'iPhone 11, mais rapproche « je lis » de
« je ne lis pas » : un verdict tiré de là validerait des contresens. Un service en
ligne jugerait bien, au prix d'envoyer la voix et le texte hors du téléphone.

Deux règles viennent des données :

- **« né/née »** — seule notation spéciale des corrigés de l'exercice 1 : une barre
  entre deux mots vaut deux réponses admises.
- **Les chiffres** — 61 phrases de dialogue en contiennent (`7:00`, `XH553 WB`), que la
  reconnaissance écrit en lettres. Pour celles-là, la vague ne tranche pas et
  l'apprenant juge.

Répondre au micro reste facultatif : on ne s'enregistre qu'à l'arrêt, écran en main,
et la sortie audio est rendue à la séance dès la prise terminée.

### Trois absences à ne pas confondre

- **Absente par conception** : une révision hebdomadaire n'a pas d'exercices. Rien à
  signaler, les étapes n'existent pas.
- **Pas encore importée** : pas d'exercice 2 dans le JSON, pas de traduction pour les
  95 leçons transcrites depuis l'audio. L'écran le dit, montre ce qui existe (l'énoncé
  espagnol, l'audio) et propose **« J'ai fait cet exercice dans le livre »** — une
  confirmation explicite, qui seule termine alors l'étape.
- **Mal saisie** : un gabarit illisible (crochet non fermé, trou vide). L'exercice est
  refusé en entier et renvoie au livre, plutôt que d'en proposer la moitié.

### La progression

- Le parcours est une suite de **séances numérotées** : 1 à 100 portent une nouvelle
  leçon, 101 à 149 ne sont plus que la deuxième vague (voir plus bas).
- La séance suivante se **déduit** de la dernière validée (`DailyCourse`) ; rien n'est
  incrémenté. Valider deux fois, rouvrir l'écran ou relancer l'app ne peut donc pas
  avancer deux fois.
- Une fois validée : « Séance terminée pour aujourd'hui », la leçon de demain, et plus
  aucun bouton de nouvelle leçon. Les leçons et l'écoute libre restent accessibles.
- Le lendemain est le **jour calendaire local**, pas 24 heures : validée à 23 h 30, la
  suivante est là à minuit. `DayClock` suit `NSCalendarDayChanged`, les changements
  d'heure et le retour au premier plan : l'accueil se met à jour app ouverte.
- **Jours manqués** : aucune leçon sautée. **Séance inachevée** : reprise, quel que soit
  le jour. **Difficulté** : « Retravailler cette leçon demain » rouvre la même leçon.
- L'**écoute libre** vit dans l'onglet Leçons : ses trois modes en tête de liste (le
  choix est gardé), « Reprendre » sur les leçons commencées, la reprise dans
  `LessonProgress`, sans effet sur la séance du jour. L'accueil ne parle plus que de
  la séance et des révisions.
- Le temps étudié n'est compté qu'une fois : le lecteur rend ses secondes une seule
  fois (`PlayTimeLedger`). Avant, quitter et rouvrir le lecteur les recomptait.

### Les révisions hebdomadaires

Leçons 7, 14… 98 : découverte, compréhension, répétition du dialogue de révision, puis
validation — sans les deux exercices. La synthèse grammaticale du livre peut se
saisir sous `"review": { "sections": [{ "title": …, "text": … }] }` ; faute de quoi
l'écran renvoie au livre. Elles comptent comme la séance du jour. Rien à voir avec
l'onglet **À revoir**, qui reste la file des phrases marquées.

### La deuxième vague

Le site d'Assimil place la **phase active à la leçon 50** : on restitue la langue à
partir du français, réponses cachées. Le décalage de 49 (leçon 50 → leçon 1) est celui
qu'avait déjà l'app, et **le livre le confirme** : le bas de la leçon 51 indique
« Deuxième vague : 2e leçon » (`Curriculum.waveStartLesson`). La vague n'apporte pas
d'exercice à elle : la leçon du jour garde sa traduction et ses phrases à compléter,
et l'ancienne leçon se restitue depuis son français.

À partir de la leçon 50, la séance gagne une étape : le français de l'ancienne leçon,
l'espagnol caché, « Voir l'espagnol » qui l'affiche et le fait entendre, puis
l'auto-évaluation. Sans traduction importée — le cas de toutes les leçons après la 5 —
l'écran renvoie à la restitution dans le livre et propose l'écoute de l'ancienne leçon.

Après la leçon 100, la vague continue seule (leçons 52 à 100), une par jour, pour ne
laisser aucune leçon sans deuxième vague. Le mode « La vague » de l'écoute libre ne
change pas.

### Stockage et migration

- `DailySession` : une séance, son avancement en JSON (étape, reprise audio par
  phrase, réponses), sa date de validation. `CourseAnchor` : le point de départ.
- Ajouter ces deux entités est une migration légère. Au premier lancement, le parcours
  part de l'ancien réglage manuel `currentLesson` ; une ancienne fin d'écoute ne vaut
  pas validation.
- **`LessonProgress` est unique par leçon, pas par mode.** Enregistrer la reprise d'un
  second mode ne créait pas de doublon : SwiftData *remplaçait* la ligne existante. Le
  lecteur met donc à jour la ligne de la leçon ; le test `lessonProgressIsUniquePerLesson`
  le vérifie. Changer la contrainte aurait demandé une migration de schéma pour rien.

### Vérifier

```bash
xcodebuild test -project AssimilES.xcodeproj -scheme AssimilES \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:AssimilESTests
xcodebuild test -project AssimilES.xcodeproj -scheme AssimilES \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:AssimilESUITests
```

Les tests n'utilisent que des données fictives. Les tests d'interface parcourent la
séance dans le simulateur grâce à trois variables lues **en Debug seulement** :
`ASSIMIL_STORE` (stockage isolé), `ASSIMIL_TEXT_DIR` (textes fictifs) et
`ASSIMIL_DAY_OFFSET` (décaler « aujourd'hui » pour vérifier le lendemain).

## La révision des phrases marquées

Pendant l'écoute, le drapeau met une phrase de côté. Ces phrases reviennent
d'elles-mêmes : l'onglet **À revoir** propose chaque jour celles qui sont dues, et
l'écran du jour les annonce à côté de la séance.

Une phrase revient à intervalle croissant — **1, 3, 7, 21 puis 60 jours**. Elle ne
sort jamais de la file toute seule : c'est le **drapeau**, le même qu'en écoute,
qui l'en retire quand elle est acquise, et qui enchaîne alors sur la suivante.

**Pas de notation.** Un « facile / difficile » après chaque phrase serait plus fin,
mais il demanderait l'œil sur l'écran et un appui à chaque pause — exactement ce
dont l'app affranchit. Un seul geste, déjà connu, qui ne sert qu'à dire « celle-là,
c'est bon ». La séance de révision se conduit sinon comme une leçon, y compris
depuis l'écran verrouillé.

Deux points de calcul, dans `ReviewSchedule` :

- L'échéance est calée sur le **début de journée**. Une phrase revue le soir revient
  le lendemain, pas le lendemain soir : la séance est quotidienne, l'heure n'a pas à
  décider de ce qui est dû.
- La suite **s'arrête à 60 jours**. Une phrase encore marquée après cinq reprises
  mérite de repasser de temps en temps, pas de disparaître.

Une phrase compte comme revue dès qu'elle est **jouée** : c'est de l'avoir
réentendue et redite qui la révise. La rejouer dans la même séance ne repousse pas
son échéance une seconde fois.

## S'enregistrer et se comparer au natif

Sur l'écran de lecture, le micro (à droite du transport) **arrête la séance et
enregistre d'un même geste** ; un second appui termine la prise. Le résultat s'affiche
au-dessus du transport : les mots de la phrase, ceux qui ne sont pas passés en orange,
la mélodie en un mot, la réécoute moi / natif. « Reprendre » relance la séance là où
elle était. La courbe, le tempo et ce que la machine a compris sont à un appui (ⓘ).
Trois gestes au lieu de six, quand c'était une feuille à part.

La logique de l'essai vit dans `VoiceTrial`, partagé par le panneau du lecteur et la
feuille de détail (`PronunciationView`).

**Ce que ça mesure, et ce que ça ne mesure pas.** La reconnaissance dit si les mots
*passent*, pas si l'accent est bon : aucune API d'Apple n'évalue une prononciation.
L'écran affiche donc trois choses vérifiables — les mots de la phrase, ceux qui ne
sont pas passés en orange ; ce que la machine a compris, mot pour mot ; et le tempo,
qui compare deux durées. Pour l'accent, c'est la réécoute côte à côte qui tranche,
pas une note.

C'est le même signal que sur le corpus : c'est ce contrôle qui avait fait ressortir
`Ejem` comme le seul mot manqué sur les cinq leçons de contrôle.

La comparaison applique **exactement la règle du pipeline** (`SpanishMatch`, portée
de `tools/verify-clips.py`) : le texte replié sur ses lettres et ses chiffres —
minuscules, sans accents, sans ponctuation **et sans espaces** — puis comparé
caractère par caractère, et remonté aux mots seulement pour l'affichage. Vérifié sur
les cas que le pipeline avait documentés : `¡Hola, Laura!` contre `Hola Laura.` ne
signale rien, `XH 553` contre `XH553` non plus, `Yujú` contre `Youjú` non plus — et
`Ejem...` comme la troncature `A ver.` ressortent bien.

**Deux moteurs, selon l'appareil.** `SpeechTranscriber` — celui qui a transcrit le
corpus — expose `isAvailable` : il demande un appareil capable d'Apple Intelligence,
ce que l'iPhone 11 (A13) n'est pas. `DictationTranscriber` n'a pas cette condition et
rend la même chose. L'app prend le premier quand il est là, le second sinon, et
affiche en petit lequel a parlé. Dans les deux cas, l'app doit **réserver** la locale
auprès d'`AssetInventory` avant d'en toucher les assets : sans cette souscription, le
système refuse jusqu'à dire où en est le téléchargement. Le portage direct de
`tools/transcribe.swift`, qui n'y est pas soumis en ligne de commande, échouait sur
les deux points.

Modèle es-ES installé une fois, **rien ne sort du téléphone**. Il s'agit ici de la voix
d'Ethan, ce qui est une raison de plus de rester hors ligne. Les prises vivent dans
`Documents/voice/`, une par phrase, nommées comme la clé de marquage (`L012-S04`).

Cet écran demande **iOS 26** (`SpeechTranscriber`), d'où la cible de déploiement.
L'iPhone de test est en 26.6 ; l'app est personnelle et n'a qu'un appareil.

### La mélodie, mesurée

Après l'enregistrement, l'écran superpose **deux courbes d'intonation** : celle du
natif et la tienne, alignées dans le temps et ramenées chacune au registre de son
locuteur. Un chiffre dit de combien ça s'écarte, la courbe dit où — une montée de
question qu'on a aplatie se voit d'un coup d'œil.

C'est la seule des deux questions posées (accent, intonation) à laquelle on puisse
répondre honnêtement en local et sans payer. L'évaluation d'accent au phonème
n'existe ni chez Apple, ni en auto-hébergé calibré pour l'espagnol.

**La hauteur est calculée ici, pas empruntée.** `SFVoiceAnalytics` d'Apple donne une
courbe de pitch, mais par le chemin de la reconnaissance vocale — or il faut la même
mesure sur les deux enregistrements, celui d'Ethan *et* le clip Assimil.
`PitchTrack` fait donc sa propre détection, comme le reste du pipeline fait ses
propres mesures.

**Trois choses ont dû être corrigées, chacune visible dans les données :**

- **L'autocorrélation normalisée attrapait les harmoniques.** Une voix réellement à
  ~95 Hz ressortait en 95, 180, 260 et 365 Hz selon les trames — des multiples. Une
  voix grave encodée en AAC 64 k a un fondamental faible devant ses harmoniques.
  Remplacée par **YIN**, dont la différence normalisée cumulée pénalise les
  décalages trop courts et retient le *premier* creux, pas le meilleur.
- **Le seuil de voisement est calibré, pas repris de l'article.** Sur 4 364 trames
  non silencieuses de quatre leçons, la valeur d'origine 0,15 ne retenait que 36 %
  des trames ; 0,25 en retient 51 %, l'ordre attendu pour de la parole.
- **Le DTW libre ne mesurait rien.** Sans contrainte, il apparie une trame contre
  vingt et rapproche n'importe quoi : deux phrases différentes ne sortaient qu'à
  1,7 demi-ton. Une bande de Sakoe-Chiba à 20 % de la diagonale interdit de
  s'écarter au-delà de ce qui reste la même phrase dite autrement.

**Les seuils du verdict sont mesurés.** Deux distributions sur 12 clips de 4 leçons :

| | médiane | p90 | max |
|---|---|---|---|
| Même phrase, débit ×0,8 ou +3 demi-tons | 0,11 | 0,22 | 0,46 |
| Phrases différentes | 0,55 | 1,19 | 2,18 |

Au p90 du premier groupe (0,22), **98 % des paires de phrases différentes sont
au-dessus** : la mesure sépare « la même mélodie autrement dite » de « une autre
mélodie ». Les bornes du verdict sont ces trois nombres. Mes premiers seuils,
inventés (1, 2, 4 demi-tons), classaient deux phrases sans rapport comme conformes —
l'échelle réelle est quatre fois plus resserrée.

Ce qu'aucun corpus ne donne : une phrase dite par Ethan tombe *entre* les deux
groupes, et savoir où demanderait ses propres enregistrements. Les seuils sont donc
posés sur ce qui est mesuré, pas sur ce qu'on voudrait qu'ils disent.

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

**La lecture en arrière-plan tient à `AssimilES-Info.plist`**, à la racine et non
sous `AssimilES/` (le groupe synchronisé le copierait dans l'app en plus). Il ne
contient que `UIBackgroundModes = audio` ; Xcode le fusionne avec l'Info.plist
qu'il génère. Le réglage `INFOPLIST_KEY_UIBackgroundModes` qui le déclarait avant
n'existe pas : Xcode l'ignorait sans rien dire, et l'iPhone suspendait l'app dès
le retour à l'accueil. Le simulateur, lui, continuait de jouer — c'est sur
l'appareil que ça se vérifie :

```bash
plutil -p <chemin>/AssimilES.app/Info.plist | grep -A2 UIBackgroundModes
```

Le journal audio (`AudioLog` : lecture, pauses, passages en arrière-plan,
interruptions, changements de sortie) se lit dans Console.app, sous-système
`com.ethansaux.AssimilES`. En Debug, il sort aussi sur la console de
`xcrun devicectl device process launch --console`.

## Quatre décisions non évidentes

**L'enregistrement est un moment à l'arrêt, pas une greffe sur la pause de
répétition.** Capter la voix pendant le silence de répétition serait élégant — zéro
geste, la prise se ferait toute seule. Mais enregistrer impose la catégorie de
session `.playAndRecord`, alors que toute la séance repose sur `.playback` et sur un
flux qui ne s'interrompt jamais : changer de catégorie au milieu d'une leçon, c'est
risquer exactement la suspension que le silence diffusé évite, et pour toutes les
séances, y compris celles où on ne s'enregistre pas. L'essai de prononciation prend
donc la sortie audio explicitement (`SessionPlayer.releaseAudio()`), au moment où l'on
touche le micro, et la rend avec « Reprendre ». Il suppose de toute façon d'être à
l'arrêt, téléphone en main.


**C'est l'étape qui porte sa leçon, jamais la séance.** Une séance n'est pas « une
leçon dans un mode » : la vague en enchaîne deux (la leçon du jour puis celle d'il y
a 49 jours), et la file de révision en traverse autant qu'il y a de phrases
marquées. Tant que l'écran de lecture tirait son texte d'une leçon supposée unique,
il affichait la mauvaise — pendant l'exercice il surlignait les phrases 1 à 5 du
*dialogue*, et le drapeau enregistrait leur clé. `SessionStep` porte donc son
`lessonNumber` et son `isExercise`, y compris sur les pauses, et l'écran comme
l'écran verrouillé se pilotent dessus. C'était le prérequis de la révision, qui
serait sinon restée enfermée dans une leçon.


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
