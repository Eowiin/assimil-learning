# Module de conversation

**Plan proposé le 2026-11-12, à valider.** Le pourquoi, l'architecture et les mesures
sont dans `docs/cadrage-v2.md`. Comme pour le vocabulaire, ce fichier dit ce qu'il
reste à faire et comment, et le README garde les décisions une fois faites.

## Ce qu'on construit

Une conversation en espagnol avec l'IA, à la voix, en **talkie-walkie** :

1. On ouvre la conversation depuis l'accueil. L'IA parle la première : elle salue et
   propose un sujet de la vie courante.
2. On touche le micro, on parle, on touche à nouveau. Ce que Whisper a compris
   s'affiche en bulle. On voit donc tout de suite si une phrase est passée.
3. L'IA répond, en texte et à voix haute, et relance par une question. On peut
   réécouter chacune de ses répliques.
4. **Terminer** affiche le récapitulatif : les phrases fautives, leur version corrigée
   et une courte explication en français. Rien ne coupe l'échange avant.

Le délai attendu entre la fin de sa phrase et la réponse parlée est d'environ 1,3 s,
mesuré à la maison. Il faut compter un peu plus en 4G ou en 5G.

## Principes

1. **Le serveur ne garde rien** (décision 2 du cadrage). L'iPhone envoie à chaque
   tour l'historique de la conversation, et le serveur répond sans rien retenir.
2. **Les modèles restent chargés tant que le serveur tourne.** Au démarrage, le
   serveur charge Whisper et XTTS, puis fait un tour à vide. Le premier passage sur
   la carte prend 20 s, et on ne doit jamais le subir en conversation. Ollama garde
   Qwen 30 minutes après le dernier usage.
3. **Une conversation à la fois.** Il n'y a qu'une carte graphique et qu'un
   utilisateur : les tours passent l'un après l'autre.
4. **Sans serveur, pas de conversation, et rien d'autre ne change.** La ligne
   Conversation n'apparaît sur l'accueil que si le voyant est vert. Si le serveur
   tombe en cours de route, l'échange reste affiché et on peut renvoyer le dernier
   tour.
5. **Mêmes conventions que pour le vocabulaire** : une branche et une PR par étape,
   partie de `dev`. On s'arrête après chaque étape pour un test, sur le PC ou sur
   l'iPhone. Les tests unitaires et d'interface tournent à chaque fois.

## L'échange entre l'app et le serveur

L'API passe en **version 2** : l'app refuse un serveur qui n'a pas les routes de
conversation, et le voyant dit pourquoi.

| Route | L'app envoie | Le serveur renvoie |
|---|---|---|
| `POST /conversation/start` | rien, ou un sujet | la première réplique de l'IA : texte et audio |
| `POST /conversation/turn` | l'audio du tour (AAC, 16 kHz, mono) et l'historique | ce qu'il a compris, la réponse en texte et en audio, et les temps de chaque étape |
| `POST /conversation/review` | l'historique complet | les corrections : phrase dite, phrase corrigée, explication |

- **L'audio de la réponse revient dans le JSON**, en AAC, encodé en base64. Une
  réponse de 4 s pèse environ 40 Ko. On a ainsi une seule requête par tour, et rien
  à aller rechercher ensuite.
- **`turn` accepte aussi du texte à la place de l'audio.** Ça sert aux tests, et plus
  tard peut-être à l'expression écrite.
- **Les corrections sont demandées à Qwen dans un format imposé** (sortie JSON
  structurée d'Ollama). L'app reçoit une liste propre, pas un texte à découper.

## Étapes

### 1 · Le serveur converse (PC)

- Les dépendances du groupe `essais` passent dans celles du serveur.
- `app/conversation.py` : l'enchaînement Whisper → Qwen → XTTS, repris de
  `essais/conversation.py`, derrière une interface que les tests remplacent par un
  faux. Les tests ne chargent donc aucun modèle, et tournent sur le Mac.
- Les trois routes, le chargement au démarrage et le tour à vide.
- La consigne de l'IA, reprise de l'essai. La consigne des corrections est nouvelle :
  ne relever que les vraies fautes (grammaire, vocabulaire, tournure non idiomatique),
  pas le style, et expliquer en français en une phrase.
- **Test sur le PC** : un petit script appelle les routes avec tes enregistrements,
  comme le fera l'app. On vérifie le délai et le récapitulatif.

### 2 · L'écran de conversation (app)

- `ConversationClient` : les trois appels, et la lecture des réponses. Il est testé
  avec un faux réseau, comme `ServerStatus`.
- `ConversationView` :
  - les bulles : à droite ce que Whisper a compris, à gauche l'IA, avec un bouton
    pour la réécouter ;
  - le bouton micro, et ses états : prêt, j'écoute, l'IA réfléchit, l'IA parle ;
  - en cas d'échec, un message et un bouton pour renvoyer le tour.
- L'audio reprend `VoiceRecorder` : session `.playAndRecord`, haut-parleur par
  défaut. On arrête la séance d'Assimil si elle jouait.
- **L'accueil** : une ligne « Conversation » sous le vocabulaire, visible seulement si
  le serveur est en ligne.
- Le temps passé est compté dans `StudyEvent`, activité `conversation`, sans cours :
  elle ne dépend pas d'Assimil.
- **Test sur l'iPhone** : une vraie conversation, à la maison puis dehors.

### 3 · Le récapitulatif (app et serveur)

- La route `review` et sa consigne, si elles n'ont pas été faites à l'étape 1.
- L'écran du récapitulatif, après « Terminer » : la phrase dite, la phrase
  corrigée avec les différences en couleur, et l'explication. S'il n'y a pas de faute,
  il le dit.
- Selon ta réponse à la question 2, la conversation et ses corrections sont gardées
  sur l'iPhone.
- **Test sur l'iPhone.**

## Plus tard (hors de ce plan)

- Les thèmes tirés des leçons. On donnerait alors à Whisper les mots attendus, pour
  qu'il reconnaisse mieux les noms propres comme « Jaén ».
- Adapter l'IA au niveau et aux mots connus (le profil d'apprenant).
- LiveKit, si l'attente du talkie-walkie gêne.
- Faire tourner le serveur comme un service, lancé avec Windows.

## Questions pour toi

1. **Le micro** : toucher pour commencer, puis toucher pour finir, ou bien garder le
   doigt appuyé pendant qu'on parle ? Je propose de toucher deux fois : rien à tenir
   en bougeant, et le doigt libre.
2. **Garder les conversations sur l'iPhone ?** Je propose de garder chaque
   conversation et ses corrections (un nouveau modèle SwiftData, ajouté par une
   migration légère). Elles nourriront le profil d'apprenant plus tard, même si rien
   ne les affiche après le récapitulatif.
3. **Le texte de l'IA** : affiché d'emblée, ou masqué derrière un bouton ? Masqué, on
   travaille la compréhension orale. Je propose de l'afficher, avec un réglage pour le
   masquer.
4. **La voix de l'IA** : une voix fournie avec XTTS, ou une imitation d'une voix
   native d'Assimil (un extrait de 10 s, gardé sur le PC, hors dépôt) ? Je propose
   d'essayer les deux à l'étape 1, et de garder celle qui te plaît.
