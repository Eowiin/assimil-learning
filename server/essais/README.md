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
uv sync --group essais                           # PyTorch (CUDA 12.8), Whisper, XTTS : plusieurs Go
```

Au premier lancement, Whisper large-v3-turbo et XTTS v2 se téléchargent. **XTTS
demande d'accepter sa licence** (CPML, usage non commercial) : réponds `y`.

### Lancer

Si `ollama serve` ne tourne pas déjà, lance-le dans un autre terminal. Ensuite :

```bash
# 1. Au clavier : la qualité de l'IA, sans micro. Tu réponds à ses questions.
uv run --group essais python essais/conversation.py --interactif

# 2. Avec ta voix : des enregistrements (wav, m4a, mp3), un par tour.
uv run --group essais python essais/conversation.py tour1.m4a tour2.m4a --interactif

# 3. La même chose avec l'autre IA, pour comparer.
uv run --group essais python essais/conversation.py --ia gemma3:12b --interactif
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
  export LD_LIBRARY_PATH=$(uv run --group essais python -c \
    'import nvidia.cublas.lib as b, nvidia.cudnn.lib as d; print(b.__path__[0] + ":" + d.__path__[0])')
  ```
- **La mémoire affiche `?`** : `nvidia-smi` ne répond pas dans WSL2, et les modèles
  tournent sans la carte graphique. Vérifie le pilote NVIDIA de Windows.
