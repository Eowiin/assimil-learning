# Essais de modèles, sur le PC

Des scripts pour mesurer un modèle avant de le brancher sur l'app (principe 5 du
cadrage v2). Ils tournent sur le PC, dans WSL2, à côté du serveur.

L'IA est Mistral, par son API : la clé dans `MISTRAL_API_KEY`, comme pour le serveur
(`server/README.md`). Le premier essai, `conversation.py` (Whisper, Qwen3 par Ollama et
XTTS, sans serveur), et `llm.py` (Qwen3 et Mistral côte à côte) ont été retirés le
2026-11-18, avec Ollama : le serveur et `appel.py` font la conversation, `objectif.py`,
`placement.py` et `texte.py` mesurent l'IA.

## Si ça coince

- **Une bibliothèque CUDA introuvable** (`libcublas`, `libcudnn`) au chargement de
  Whisper : faster-whisper cherche les bibliothèques de NVIDIA installées avec
  PyTorch. Indique-lui le chemin :
  ```bash
  export LD_LIBRARY_PATH=$(uv run python -c \
    'import nvidia.cublas.lib as b, nvidia.cudnn.lib as d; print(b.__path__[0] + ":" + d.__path__[0])')
  ```
- **`nvidia-smi` ne répond pas** dans WSL2 : les modèles tournent sans la carte
  graphique. Vérifie le pilote NVIDIA de Windows.
- **`L'IA (Mistral) demande la clé`** : `export MISTRAL_API_KEY=…` avant de lancer.

## `whisper_contexte.py` : la dernière réplique de l'IA, comme amorce de Whisper

Whisper peut recevoir un texte qu'il prend pour ce qui précède (`initial_prompt`),
et dont il reprend plus volontiers les mots. Si l'IA vient de parler de « Jaén »,
il reconnaîtra peut-être mieux « Jaén » dans ta réponse. Le risque : qu'il
« entende » des mots de l'IA que tu n'as pas dits. Le serveur sait le faire
(`ASSIMIL_WHISPER_CONTEXTE=1`), mais c'est **désactivé** tant que ce n'est pas mesuré.

1. Converse par `appel.py` avec des enregistrements. Chaque tour enregistré est noté
   dans `essais/sortie/corpus-whisper.json`, avec la réplique de l'IA qui le
   précédait et ce que Whisper a compris.
2. Dans ce fichier, écris pour chaque tour ce que tu as **vraiment** dit (`attendu`).
   Une entrée laissée vide est ignorée.
3. Compare :

```bash
uv run python essais/whisper_contexte.py essais/sortie/corpus-whisper.json
```

Le script transcrit chaque enregistrement sans amorce, puis avec, et compte les
mots justes. Les mots se comparent sans casse, ponctuation ni accents écrits, comme
dans le récapitulatif de l'app. Il affiche les tours où les deux transcriptions
diffèrent, puis le bilan : le taux de mots justes, les mots entendus à tort, et le
nombre de tours où l'amorce fait mieux ou moins bien.

## `langue.py` : les lemmes et la couverture d'un texte

Charge spaCy seul, comme le serveur, et prend pour « connus » les N premiers lemmes du
lexique de l'app (1500 par défaut). Chaque mot est affiché avec son lemme, les inconnus
avec un astérisque, puis la couverture. À lancer sur des répliques réelles de l'IA,
pour voir si les lemmes tombent sur les clés du lexique.

```bash
uv run python essais/langue.py
uv run python essais/langue.py -n 800 "Siéntate y cuéntame qué pasó."
uv run python essais/langue.py -f replique.txt
```

## `objectif.py` : l'objectif du jour

Charge l'IA et spaCy, sans Whisper ni la voix. Sur obj_031 (imparfait et indefinido),
niveau A2 :

1. le **récapitulatif** d'une conversation aux fautes connues : corrections (celles
   que le serveur écarte, identiques à la phrase de départ, sont marquées ✗), et
   chaque tentative de l'objectif jugée ;
2. la **correction d'un écrit** fautif (temps du passé, accents) et le texte corrigé ;
3. les **répliques mesurées** de chaque mode (libre, jeu de rôle, rapide), ouverture
   puis un tour, avec les 800 premiers lemmes comme connus : chaque version avec sa
   couverture et ses mots inconnus, la version gardée marquée.

Sous chaque partie, ce qu'un bon résultat doit trouver.

```bash
uv run python essais/objectif.py
uv run python essais/objectif.py -n 1500
```

## `placement.py` : les défis du placement

Charge l'IA seule. Douze défis du paquet (A1 à B2), trois réponses chacun en général :
une qui montre l'objectif, une juste qui le contourne, une fausse. Aucune n'est
identique au paquet : toutes vont au juge. Chaque verdict s'affiche à côté de celui
qu'on attend (deux sont acceptés quand le cas se discute), avec l'analyse des
désaccords, puis le score et le temps de chaque appel (paquets de 10).

```bash
uv run python essais/placement.py
uv run python essais/placement.py -v   # toutes les analyses
```

## `texte.py` : le texte du bloc 2

Charge l'IA et spaCy. obj_031, niveau A2, un voyage en train qui tourne mal, 7 mots
nouveaux du thème, 150 mots visés, les 800 premiers lemmes comme connus. Chaque version
écrite s'affiche avec sa couverture, ses inconnus et les mots nouveaux employés ; puis
le texte gardé, sa traduction, les phrases de l'objectif repérées par le juge, et la
phrase de chaque mot nouveau, avec sa forme écrite (`new_occurrences` : le recto de sa
carte dans l'app).

```bash
uv run python essais/texte.py
uv run python essais/texte.py -n 1500 --mots 250
uv run python essais/texte.py --tts essais/sortie/texte   # et les m4a (XTTS)
```

## `amorces.py` : les amorces des débutants et la fin de scène (étape 5b)

Charge l'IA seule. Pour le premier objectif A0 et le premier A1 du paquet, en jeu de
rôle : l'ouverture et ses trois amorces (début de réponse et traduction), un tour et ses
amorces, puis la dernière réponse (`closing`), où l'IA doit conclure sans question. À
regarder : les amorces répondent-elles à la réplique, et sont-elles assez simples ?

```bash
uv run python essais/amorces.py
uv run python essais/amorces.py --niveaux A1 A2
```

## `voix.py` : Voxtral, Pocket TTS et XTTS côte à côte (étape 5c)

Les mêmes phrases dites par chaque voix : des mots seuls (Pocket est connu pour couper
les phrases très courtes), des phrases du bloc 2, et des phrases chargées en θ, jota,
r et v. Pour chacune, le temps de synthèse, le facteur temps réel et la taille du .m4a.
Les fichiers vont dans `essais/sortie/voix/<voix>/`, à écouter. Sur le Mac, Pocket
(standard, processeur) dit une phrase du bloc 2 en 0,5 s, six fois plus vite que le
temps réel.

```bash
uv run python essais/voix.py
uv run python essais/voix.py --voix voxtral pocket
```

## `prononciation/` : le jugement des sons, sur les prises du 10 novembre

Le prototype du 10 novembre (README principal, « L'accent au phonème »), repris
pour tourner sur le PC, puis remplacé le 13 novembre par la méthode de
spanish-pronunciation-coach, le projet de recherche du PC. Depuis, l'analyse est
passée dans le serveur (`app/prononciation/`, modules du coach dans
`app/prononciation/coach/`) ; les scripts d'ici l'importent de là :

- **GOP aligné** : la phrase attendue est alignée de force sur les sorties du wav2vec2
  phonétique, et chaque phonème reçoit la probabilité de ses réalisations acceptées.
  Seuils par phonème tirés de 1899 phrases natives d'Assimil (quantile 0,002 ; 0,01
  pour /θ/), là où le prototype n'avait que quelques voix natives.
- **Les r jugés dans le signal** : battu ou roulé se compte aux contacts de la langue
  dans l'énergie. Aucun modèle ne sépare les deux de façon fiable.
- **ZIPA** (un second modèle phonétique, petit, en ONNX sur le CPU) entend ce que le
  wav2vec2 n'entend pas : le r français ([ʁ]) à la place d'un r ou d'une jota, et le
  [v] à la place d'un /b/ écrit v. Ses seuils (`app/prononciation/seuils_zipa.json`) sont tirés des
  mêmes natives par `calibrer_zipa.py`. Licence CC-BY-NC-SA : bon pour l'essai, pas
  pour une app publiée.

`rejouer.py` fait passer l'analyse sur les 16 prises du test (8 phrases, soignées
puis avec les fautes d'un francophone), puis donne le bilan.

```bash
# Sur le Mac, une fois : les prises et leur texte, hors dépôt, à copier sur le PC.
python3 server/essais/prononciation/empaqueter.py ~/Desktop/prises-10-novembre

# Sur le PC :
uv run python essais/prononciation/rejouer.py ~/prises-10-novembre
ASSIMIL_PRONONCIATION_MODELE=lv60 uv run python essais/prononciation/rejouer.py ~/prises-10-novembre
```

`ASSIMIL_PRONONCIATION_MODELE` choisit le wav2vec2 parmi ceux dont les seuils sont
calibrés : `xlsr53` (le défaut, `facebook/wav2vec2-xlsr-53-espeak-cv-ft`), `lv60`, `cnam`.

**Les résultats**, sur les mêmes 16 prises :

| | θ dit s | jota dite r français | r dit r français | v dit v | **Total** | Signalés en prise soignée |
|---|---|---|---|---|---|---|
| Prototype du 10 novembre | 4/7 | 0/4 | 1/18 | 3/5 | **8/34** | **24/218** |
| Méthode du coach (13 novembre) | 6/7 | 3/4 | 17/18 | 3/5 | **29/34** | **12/218** |

Les signalés de la prise soignée ne sont pas tous à tort : sur 12, il y a 4 θ dits
[s] et des r battus ou roulés à contretemps, deux habitudes déjà relevées sur les
autres prises de la même voix (dans le coach). Le r roulé dit battu n'est qu'un
indice, pas une faute (voir plus bas).

`extraits.py` découpe chaque mot signalé en un court wav, pour juger la faute à
l'oreille.

**Sur des voix inconnues** : `common_voice.py` tire des phrases de Common Voice
espagnol (lu en flux dans l'archive de 52 Go, hors dépôt), et `evaluer.py` mesure
l'analyse sur ce manifeste.

```bash
uv run --with datacollective python essais/prononciation/common_voice.py ~/common-voice-es --archive ARCHIVE
uv run python essais/prononciation/evaluer.py ~/common-voice-es/manifeste.tsv
```

Sur 400 phrases de 270 natifs d'Espagne, 1,3 % des sons sont signalés (247/19 713),
et 272 phrases sur 400 n'ont aucune alerte. Fausses alertes par faute visée : θ 4/335,
jota 0/129 par ZIPA, r français 5/1312, v 4/204. Une partie vient des mots anglais des
phrases (*price*, *Jennifer*…). Le r roulé dit battu n'est plus qu'un indice : 34 des 64 /r/ natifs jugés sont
battus, contre 18 sur 206 chez Assimil. Ce n'est pas le détecteur qui se trompe :
sur le signal (*carrera*, *herramientas*, *concurrentes*), on voit un seul contact
bref entre deux voyelles. En lecture courante, beaucoup de natifs ne roulent pas.

**Un accent français de synthèse** : XTTS v2 lit les 8 phrases du test en espagnol,
puis en mode français, ce qui donne un fort accent francophone (2 voix × 2 tirages).
En espagnol, 0,7 % des sons sont signalés (surtout le θ dit [s] d'une des voix, qui
fait vraiment le seseo). En mode français, les fautes visées sortent presque toutes :
θ 24/28, jota 16/16 (dite [ʒ]), r 70/72, v 19/20. L'accent est caricatural (19 % des
sons signalés), plus fort que celui d'un apprenant. Common Voice n'a pas de francophones
utilisables (un seul, d'accent mexicain) : la détection chez d'autres francophones
reste à mesurer.
