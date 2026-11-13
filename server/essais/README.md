# Essais de modèles, sur le PC

Des scripts pour mesurer un modèle avant de le brancher sur l'app (principe 5 du
cadrage v2). Ils tournent sur le PC, dans WSL2, à côté du serveur.

## `conversation.py` : la conversation, sans l'app

```
ta voix ─▶ Whisper large-v3-turbo ─▶ IA (Ollama) ─▶ XTTS v2 ─▶ réponse .wav
```

Chaque tour affiche ce que Whisper a compris et la réponse de l'IA. Il donne aussi le
temps de chaque étape, et le **délai** : de la fin de ta phrase au début de la réponse
parlée, ce que tu attendras en talkie-walkie. Le bilan final donne la mémoire
graphique, une fois les trois modèles chargés ensemble. Les réponses parlées et
`bilan.json` vont dans `essais/sortie/`, hors dépôt.

L'IA a pour consigne de parler comme un ami, en espagnol d'Espagne simple (A2-B1),
en 1 à 3 phrases, en finissant par une question, et sans corriger les fautes. La
consigne est en tête du script (`CONSIGNE`).

### Installation (une fois, dans WSL2)

```bash
sudo apt install ffmpeg                          # lecture de l'audio, et XTTS
curl -fsSL https://ollama.com/install.sh | sh    # le moteur de l'IA
ollama pull qwen3:8b                             # l'IA par défaut, environ 5 Go
ollama pull gemma3:12b                           # celle à comparer, environ 8 Go
cd assimil-learning/server
uv sync                           # PyTorch (CUDA 12.8), Whisper, XTTS : plusieurs Go
```

Au premier lancement, Whisper large-v3-turbo et XTTS v2 se téléchargent. **XTTS
demande d'accepter sa licence** (CPML, usage non commercial) : réponds `y`.

### Lancer

Si `ollama serve` ne tourne pas déjà, lance-le dans un autre terminal. Ensuite :

```bash
# 1. Au clavier : la qualité de l'IA, sans micro. Tu réponds à ses questions.
uv run python essais/conversation.py --interactif

# 2. Avec ta voix : des enregistrements (wav, m4a, mp3), un par tour.
uv run python essais/conversation.py tour1.m4a tour2.m4a --interactif

# 3. La même chose avec l'autre IA, pour comparer.
uv run python essais/conversation.py --ia gemma3:12b --interactif
```

En mode `--interactif`, chaque tour se tape : une phrase, ou le chemin d'un audio.
Une ligne vide termine et affiche le bilan.

**La voix** : sans réglage, XTTS prend une de ses voix fournies (`Ana Florence`).
`--voix extrait.wav` lui fait imiter un extrait de 6 à 15 secondes. Avec une phrase
d'un natif d'Assimil, la réponse prend un accent castillan.

### Ce qu'il faut me renvoyer

- **Le bloc « Bilan »** du terminal, pour chaque IA essayée.
- **Ton avis** sur trois points :
  - l'espagnol de l'IA : naturel, à ton niveau, est-ce qu'elle relance bien ?
  - la voix de XTTS ;
  - ce que Whisper comprend de ta voix.

Repère pour le délai : en talkie-walkie, **3 secondes** restent supportables. On
saura alors si la conversation se fait avec ces modèles, et laquelle des deux IA
garder.

### Si ça coince

- **`Ollama ne répond pas`** : lance `ollama serve`, et vérifie que `ollama list`
  montre bien le modèle.
- **Une bibliothèque CUDA introuvable** (`libcublas`, `libcudnn`) au chargement de
  Whisper : faster-whisper cherche les bibliothèques de NVIDIA installées avec
  PyTorch. Indique-lui le chemin :
  ```bash
  export LD_LIBRARY_PATH=$(uv run python -c \
    'import nvidia.cublas.lib as b, nvidia.cudnn.lib as d; print(b.__path__[0] + ":" + d.__path__[0])')
  ```
- **La mémoire affiche `?`** : `nvidia-smi` ne répond pas dans WSL2, et les modèles
  tournent sans la carte graphique. Vérifie le pilote NVIDIA de Windows.

## `prononciation/` : le jugement des sons, sur les prises du 10 novembre

Le prototype du 10 novembre (README principal, « L'accent au phonème »), repris
pour tourner sur le PC, puis remplacé le 13 novembre par la méthode de
spanish-pronunciation-coach, le projet de recherche du PC (modules repris dans
`prononciation/coach/`) :

- **GOP aligné** : la phrase attendue est alignée de force sur les sorties du wav2vec2
  phonétique, et chaque phonème reçoit la probabilité de ses réalisations acceptées.
  Seuils par phonème tirés de 1899 phrases natives d'Assimil (quantile 0,002 ; 0,01
  pour /θ/), là où le prototype n'avait que quelques voix natives.
- **Les r jugés dans le signal** : battu ou roulé se compte aux contacts de la langue
  dans l'énergie. Aucun modèle ne sépare les deux de façon fiable.
- **ZIPA** (un second modèle phonétique, petit, en ONNX sur le CPU) entend ce que le
  wav2vec2 n'entend pas : le r français ([ʁ]) à la place d'un r ou d'une jota, et le
  [v] à la place d'un /b/ écrit v. Ses seuils (`seuils_zipa.json`) sont tirés des
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
| Méthode du coach (13 novembre) | 6/7 | 3/4 | 17/18 | 3/5 | **29/34** | **13/218** |

Les signalés de la prise soignée ne sont pas tous à tort : sur 13, il y a 4 θ dits
[s] et 3 r battus ou roulés à contretemps, deux habitudes déjà relevées sur les
autres prises de la même voix (dans le coach).

`extraits.py` découpe chaque mot signalé en un court wav, pour juger la faute à
l'oreille.

**Sur des voix inconnues** : `common_voice.py` tire des phrases de Common Voice
espagnol (lu en flux dans l'archive de 52 Go, hors dépôt), et `evaluer.py` mesure
l'analyse sur ce manifeste.

```bash
uv run --with datacollective python essais/prononciation/common_voice.py ~/common-voice-es --archive ARCHIVE
uv run python essais/prononciation/evaluer.py ~/common-voice-es/manifeste.tsv
```

Sur 400 phrases de 270 natifs d'Espagne, 1,4 % des sons sont signalés (281/19 713),
et 250 phrases sur 400 n'ont aucune alerte. Fausses alertes par faute visée : θ 4/335,
jota 0/129 par ZIPA, r français 5/1312, v 4/204. Une partie vient des mots anglais des
phrases (*price*, *Jennifer*…). Seul point faible : le jugement « r roulé dit battu »
classe battus 34 des 64 /r/ natifs jugés, contre 13,6 % sur Assimil. Les lecteurs
d'Assimil roulent plus que la moyenne. Common Voice n'a pas de francophones
utilisables (un seul, d'accent mexicain) : la détection chez d'autres francophones
reste à mesurer.
