# Cadrage v2 : une app d'espagnol complète, avec un serveur à la maison

**Brouillon du 2026-11-12.** Rien n'est codé. Ce cadrage prend la suite de
`cadrage-app.md` (validé le 2026-11-07, vocabulaire fait). Il fixe le but, l'architecture
et l'ordre des modules. Comme avant, chaque module aura son propre plan.

## Le but

Faire de l'app **l'app d'apprentissage de l'espagnol**, sur les quatre compétences :
compréhension écrite, expression écrite, compréhension orale et expression orale. Elle
travaille aussi la grammaire et la prononciation, avec pour cible une très bonne
prononciation, et si possible un accent proche de celui d'un natif.

**Assimil n'est plus le centre.** C'est une source de contenu parmi d'autres. On peut
réduire sa place, ou l'abandonner un jour, si un autre module fait mieux. L'app garde
son nom.

## Ce qui change : le PC de la maison

Jusqu'ici, l'iPhone 11 bornait ce que l'app pouvait faire : un modèle assez bon pour
juger un accent ou tenir une conversation ne tient pas dessus (#44). Le PC fixe d'Ethan
(RTX 5070 Ti, 16 Go de mémoire graphique) peut faire tourner ces modèles. Les premiers
essais d'Ethan sur la voix de synthèse et l'analyse de prononciation sont bons, en qualité
comme en vitesse.

Le PC devient donc un **serveur** que l'iPhone interroge. La voix quitte le téléphone,
mais pas la maison : aucun service tiers ne la reçoit.

## Ce qui existe déjà (dans `main`)

- **La séance du jour** (Assimil) : écoute, répétition, réponse au micro, deuxième vague.
- **Le vocabulaire** : des cartes à la Anki, révisées avec FSRS, présentes sur l'accueil.
- **Ma voix** : la courbe d'intonation, à côté de celle du natif.

Tout ça reste et marche sans le serveur.

## Principes

Les principes 1, 2, 3 et 5 de `cadrage-app.md` restent. Le principe 4 change.

1. **L'accueil est la porte d'entrée unique.** Un module se montre sur l'accueil
   quand il a quelque chose à faire aujourd'hui.
2. **Un module s'essaie, puis se garde ou se retire.**
3. **Le contenu vient d'un paquet, l'état de l'apprenant vit dans les tables communes**
   (`Card`, `ReviewLog`, `StudyEvent`).
4. **Le serveur est un plus, pas une dépendance.** *(remplace « hors ligne, rien ne
   sort du téléphone »)* Quand le PC ne répond pas, les modules qui en ont besoin
   disparaissent de l'accueil, et le reste de l'app marche comme avant. La voix ne
   va qu'au PC de la maison.
5. **Mesurer avant de construire.** Un modèle est mesuré sur de vrais
   enregistrements avant d'être branché sur l'app.

## Architecture

```
iPhone ──Tailscale──▶ PC fixe (Windows, WSL2, RTX 5070 Ti)
  │                     ├─ FastAPI (Python) ── prononciation, et tout ce qui
  │                     │                      se fait en une question-réponse
  │                     └─ LiveKit (serveur + Agents) ── conversation en temps réel
  │                          └─ modèles : reconnaissance, langue, synthèse, prononciation
  └─ sans serveur : séance, vocabulaire, Ma voix, comme aujourd'hui
```

### Le réseau : Tailscale

- Tailscale est installé sur l'iPhone et sur le PC. L'app ne s'occupe pas de la
  connexion. Une app iOS ne peut pas allumer le VPN d'une autre app.
- L'app connaît **une seule adresse**, le nom du PC dans Tailscale. Cette adresse marche
  à la maison, où Tailscale relie les deux appareils directement sur le Wi-Fi, et
  dehors, en passant par Internet chiffré.
- **WSL2 n'accepte pas les connexions de l'extérieur par défaut.** On active le mode
  réseau `mirrored` (`.wslconfig`), ou bien on installe Tailscale dans WSL2. Le choix
  se fera au moment de l'installation.
- **Dans l'app**, un réglage « Serveur » donne l'adresse, et un voyant dit si le PC
  répond. C'est ce voyant qui décide si les modules du serveur s'affichent sur
  l'accueil.

### Deux chemins pour l'audio

| | Prononciation | Conversation |
|---|---|---|
| Échange | Une phrase, puis un verdict | Un échange continu, avec des tours de parole |
| Transport | Envoi HTTP de l'enregistrement à FastAPI | WebRTC, avec le SDK LiveKit sur l'iPhone |
| Côté PC | Une route FastAPI | Le serveur LiveKit, et LiveKit Agents en Python |
| Compression, écho | iOS (session audio en mode voix) | LiveKit |

La prononciation n'a pas besoin du temps réel. Un simple envoi suffit, et ce chemin se
teste sans LiveKit. LiveKit n'arrive qu'avec la conversation : il gère le flux continu,
la détection de fin de phrase et le droit de couper la parole à l'IA.

### Les modèles

| Rôle | Modèle | État |
|---|---|---|
| Voix de synthèse | XTTS v2 (Coqui) | Testé par Ethan : bon. Sa licence interdit l'usage commercial, ce qui ne pose pas de problème ici |
| Analyse de prononciation | *à préciser* | Testé par Ethan : bon. À mesurer sur les 16 enregistrements (plus bas) |
| Reconnaissance (voix → texte) | Qwen ASR | En test (Whisper si Qwen ASR ne convient pas) |
| IA de conversation | Qwen (taille à fixer) | En test : qualité en espagnol, vitesse |

**La mémoire graphique est la contrainte.** Estimation, avant toute mesure : XTTS v2
prend 2 à 3 Go, la reconnaissance 2 à 5 Go, la prononciation 1 à 2 Go. Il resterait
6 à 10 Go pour le modèle de conversation. Ça laisse un modèle de 7 à 8 milliards de
paramètres, compressé. Si ça ne tient pas, plusieurs options : charger les modèles à
la demande, ou n'en garder chargé qu'un jeu par mode.

## Les modules

### Prononciation : « dis-moi ce que j'ai mal dit »

Ethan dit une phrase. L'app répond : « tout est bon », ou bien « là, ce son-là est
faux, dis-le comme ça ». Elle montre le mot fautif et fait réécouter le son juste. On
peut aussi lui faire écouter sa propre voix à côté du natif. Ce module complète Ma voix :
la courbe juge l'intonation, celui-ci juge les sons.

**La barre à franchir** est le test du 10 novembre (README, « L'accent au phonème »).
On y avait 8 phrases dites deux fois, une fois soignées et une fois avec les fautes
d'un francophone : θ dit s, jota et r dits en r français, v dit v. Le modèle d'alors
n'en repérait que 8 sur 34, et signalait 11 % de sons justes comme faux. Les 16
enregistrements sont gardés sur le Mac (`tools/prononciation/calibration/voix/`, hors
dépôt), et `bilan.py` sait faire le compte. Le nouveau modèle doit faire nettement
mieux **sur ces mêmes fichiers**.

**Une mise en garde sur la reconnaissance.** Un bon modèle de reconnaissance
*corrige* les fautes : il écrit `jamón` même si la jota est dite comme un r français.
C'est ce qu'on veut pour la conversation, et c'est le contraire de ce qu'on veut
pour la prononciation. Le juge de la prononciation doit être un modèle fait pour ça,
pas la transcription.

### Conversation : « parle avec moi »

Ethan parle, l'IA comprend, répond, relance et pose des questions. L'échange se fait
à la voix, avec le texte affiché à l'écran, conformément à l'usage écran en main.

Ce qu'elle pourrait faire, à trancher dans le plan du module :
- **parler à son niveau**, avec les mots qu'il connaît déjà (les cartes FSRS) et
  quelques mots nouveaux ;
- **noter les erreurs** pendant l'échange, de grammaire ou de vocabulaire, et les
  rendre à la fin plutôt que de couper la conversation ;
- **choisir un sujet** : libre, tiré d'une leçon faite, ou une mise en situation (au
  restaurant, à la gare).

**À mesurer avant de construire :**
- la qualité de l'espagnol de Qwen à la taille qui tient en mémoire ;
- le délai entre la fin de la phrase d'Ethan et le début de la réponse ;
- ce délai à la maison, et dehors en 4G ou 5G.

Une conversation devient pénible au-delà d'environ 1,5 seconde de silence.

### Plus tard : le profil d'apprenant

Chaque module y verse ce qu'il voit : les erreurs, les réussites, les sons ratés, les
mots oubliés, les points de grammaire. Le système s'adapte au niveau : on n'enseigne
pas la même chose à un A1 et à un C1. On ne le construit pas maintenant, mais on le
prépare : chaque module garde ses observations sous une forme exploitable (dans
`StudyEvent`, ou une table voisine) plutôt que de les jeter.

### Ce que le serveur débloque aussi

Les modules laissés « plus tard » dans `cadrage-app.md` changent de statut :

- **Rappel** (le français d'une phrase, à redire en espagnol) était bloqué, parce que
  le livre ne donne le français que des leçons 1 à 5. L'IA peut traduire, ou juger
  une réponse « même sens ».
- **Grammaire et conjugaison** : l'IA peut expliquer une phrase, ou créer des
  exercices. Il faudra les vérifier, car un modèle de cette taille se trompe sur les
  points fins.
- **Expression écrite** : écrire, puis être corrigé.

Ce ne sont que des pistes. Aucune n'entre dans l'ordre ci-dessous.

## Ordre proposé

0. **Les fondations du serveur.** FastAPI sous WSL2, Tailscale, le réglage
   « Serveur » et son voyant dans l'app. On vérifie l'aller-retour iPhone → PC →
   iPhone, à la maison et dehors.
1. **Mesurer la prononciation** sur les 16 enregistrements. C'est rapide, et ça
   décide si le module se fait.
2. **Le module de prononciation**, par le chemin HTTP, sans LiveKit.
3. **Mesurer la conversation** : Qwen, Qwen ASR, XTTS v2, la mémoire, le délai.
4. **Le module de conversation**, avec LiveKit.
5. **Le profil d'apprenant.**

La prononciation passe en premier parce que son chemin est le plus simple (pas de
LiveKit), et parce que la mesure existe déjà. La conversation est peut-être celle qui
apporte le plus. Si tu préfères commencer par elle, les étapes 3 et 4 passent devant,
et l'étape 0 ne change pas.

## Questions pour toi

1. **Le modèle de prononciation** que tu as testé : lequel, et que renvoie-t-il ?
   Une note par phonème, par mot, ou la transcription de ce que tu as réellement dit ?
2. **L'ordre** : la prononciation d'abord, ou la conversation ?
3. **La conversation** : sur quels sujets ? Libres, tirés des leçons, en mise en
   situation ? Et les corrections : pendant l'échange, ou à la fin ?
4. **Le code du serveur** : dans ce dépôt (un dossier `server/`), ou dans un dépôt à
   part ? Le dépôt commun garde ensemble l'app et le serveur qui évoluent ensemble.
5. **L'état de l'apprenant** reste sur l'iPhone, comme aujourd'hui, et le serveur
   ne garde rien ? Ça compte pour le profil, plus tard.
