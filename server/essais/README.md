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
pour tourner sur le PC. Un wav2vec2 phonétique transcrit la prise, et chaque phonème
attendu reçoit une note : le modèle entend-il mieux ce son-là, ou un autre ?
`rejouer.py` le fait passer sur les 16 prises du test (8 phrases, soignées puis avec
les fautes d'un francophone), puis donne le bilan.

```bash
# Sur le Mac, une fois : les prises et leur texte, hors dépôt, à copier sur le PC.
python3 server/essais/prononciation/empaqueter.py ~/Desktop/prises-10-novembre

# Sur le PC :
uv run python essais/prononciation/rejouer.py ~/prises-10-novembre
ASSIMIL_PRONONCIATION_MODELE=autre/modele uv run python essais/prononciation/rejouer.py ~/prises-10-novembre
```

**Le chiffre à battre**, avec le modèle par défaut (`facebook/wav2vec2-xlsr-53-espeak-cv-ft`),
retrouvé à l'identique le 12 novembre :

| | θ dit s | jota dite r français | r dit r français | v dit v | **Total** |
|---|---|---|---|---|---|
| Fautes repérées | 4/7 | 0/4 | 1/18 | 3/5 | **8/34** |
| Signalés à tort (prise soignée) | | | | | **24/218** |

Un même modèle donne le même résultat sur le Mac et sur le PC : la carte graphique
change la vitesse, pas le jugement. Pour faire mieux, il faut un autre modèle (la
variable `ASSIMIL_PRONONCIATION_MODELE`), ou une autre méthode.
