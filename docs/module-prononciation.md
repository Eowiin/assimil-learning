# Module de prononciation

**Validé le 2026-11-13.** Le pourquoi et la barre à franchir sont dans
`docs/cadrage-v2.md`. La mesure est dans la PR #67, la route du serveur dans la
PR #68. Comme pour la conversation, ce fichier dit ce qu'il reste à faire et comment,
et le README garde les décisions une fois faites.

## Ce qu'on construit

Une séance courte, ouverte depuis l'accueil, pour corriger ses sons un par un :

1. **Une phrase s'affiche**, tirée des leçons déjà vues. On écoute le natif, puis on
   touche le micro, on lit, et on touche à nouveau.
2. **Le résultat** : la phrase, avec le son fautif marqué dans le mot (« ja**rr**a »).
   Une faute est marquée nettement. Un indice (le r roulé dit battu) l'est plus
   discrètement. Si rien n'est fautif : « Bien ! » et on passe à la phrase suivante.
3. **Une seule faute est détaillée**, la première de la phrase :
   - **en clair, sans alphabet phonétique** : « Tu as dit *s*. Il faut le *th*
     anglais. » ;
   - **le geste** : le conseil du serveur (« Pointe de la langue entre les dents. ») ;
   - **deux écoutes** : son mot, découpé dans sa prise, puis le natif.
4. **« Réessayer »** relance la même phrase. On passe à la suivante après une
   nouvelle tentative, même ratée. Toucher un autre mot marqué montre son détail.
5. Au bout de **5 phrases**, un bilan d'une ligne : les sons qui ont posé problème.

Le jugement prend 0,2 s sur le PC. Avec le réseau, compter moins d'une seconde.

## Principes

1. **L'analyse tourne sur le PC seulement**, jamais sur l'iPhone : elle y perdrait
   trop en qualité (#44).
2. **Une faute à la fois.** Une liste de cinq fautes décourage, et on n'en corrige
   aucune. Les autres restent visibles dans la phrase.
3. **Sans serveur, pas de prononciation, et rien d'autre ne change.** La ligne
   n'apparaît sur l'accueil que si `/health` annonce `pronunciation`. Si le serveur
   tombe en cours de séance, la phrase reste affichée et on peut renvoyer la prise.
4. **Le micro du lecteur ne change pas.** Il garde les mots en orange, la courbe
   d'intonation et la réécoute. Le module de prononciation juge les sons, le lecteur
   juge la mélodie.
5. **Mêmes conventions que pour la conversation** : une branche et une PR par étape,
   partie de `dev`. On s'arrête après chaque étape pour un test. Les tests unitaires
   et d'interface tournent à chaque fois.

## L'échange avec le serveur

Déjà fait (PR #68). `POST /pronunciation`, en multipart :

- `audio` : la prise, en AAC, comme pour la conversation ;
- `text` : la phrase attendue, telle qu'elle est écrite dans la leçon.

Réponse : `{words: [{text, fault, phonemes: [{expected, heard, fault, reason, hint,
tip, score, threshold, start, end}]}], heard, seconds}`.

- Les mots reviennent **en minuscules, sans ponctuation, et les nombres en lettres**.
  L'app rattache chaque mot jugé à son mot affiché en repliant les deux comme
  `SpanishMatch`. Si ça ne correspond pas, elle ne souligne rien plutôt que de se
  tromper de mot.
- `start` et `end` donnent la place de chaque son dans la prise. L'app en tire le
  début et la fin du mot pour le réécouter seul.
- Erreurs : 503 si la prononciation n'est pas chargée ; 422 si la prise est illisible,
  trop courte (moins de 0,3 s), ou si la phrase n'a pas de mot.

## D'où viennent les phrases

- **Des leçons déjà vues**, jusqu'à la leçon du jour : on connaît le sens, on peut se
  concentrer sur les sons. Le dialogue seulement, qui a la voix du natif.
- **Des phrases qui contiennent les sons à travailler** : θ (`z`, `ce`, `ci`), jota
  (`j`, `ge`, `gi`), r et rr, b et v. L'app les repère à l'orthographe, sans le
  serveur.
- **De 4 à 12 mots.** Plus court, il y a peu à juger. Plus long, la prise devient
  une lecture, et l'erreur se perd.
- Tirées au hasard parmi celles-là, sauf trois sur cinq qui visent les sons les
  plus ratés du dernier mois (`docs/module-profil.md`, étape 1).

## Les sons, dits en clair

Le serveur rend des symboles phonétiques (`θ`, `x`, `ɾ`, `r`, `β`…). L'app les
traduit en mots, dans une petite table :

| Symbole | Affiché |
|---|---|
| θ | le *th* anglais (*think*) |
| x | la jota, raclée au fond de la gorge |
| ɾ | le r battu, un seul coup de langue |
| r | le r roulé |
| β, b | le b, lèvres qui se touchent à peine |
| s | un *s* |
| ʁ | un r français |
| v | un *v*, dents sur la lèvre |

Un symbole absent de la table s'affiche tel quel, entre crochets.

## Étapes

### 1 · Le client (app) — fait (PR #70)

- `ServerHealth.pronunciation`, et un accès `ServerStatus.pronunciation` comme
  `conversation`.
- `PronunciationService`, un protocole, avec :
  - `PronunciationClient` : le multipart et le POST, sur le patron de
    `ConversationClient` ;
  - un faux service pour les tests et le mode DEBUG.
- Les modèles `Decodable` de la réponse, et le rattachement aux mots affichés.
- La table des sons.
- **Tests** : le décodage d'une vraie réponse du serveur, le rattachement (casse,
  ponctuation, « 3 » contre « tres »), le repli sans serveur ni module.

### 2 · Le choix des phrases (app) — fait (PR #71)

- `PronunciationDrill` : les phrases des leçons vues, filtrées par les sons et la
  longueur, puis tirées au hasard. Cinq par séance.
- **Tests** : le repérage des sons à l'orthographe (`cena`, `gente`, `perro`,
  `vaso`), les bornes de longueur, une leçon sans texte importé ignorée.

### 3 · L'écran et l'accueil (app) — fait (PR #72)

- `PronunciationView` : la phrase, l'écoute du natif, le micro, le résultat, la
  faute détaillée, les deux écoutes, « Réessayer », puis le bilan.
- L'audio reprend `VoiceRecorder`. Le mot seul se rejoue par sa place dans la prise.
- **L'accueil** : une ligne « Prononciation » sous la conversation, visible
  seulement si le serveur annonce le module.
- Le temps passé est compté dans `StudyEvent`, activité `pronunciation`.
- **Test sur l'iPhone**, serveur du PC lancé.

### 4 · Garder les fautes, et le README (app) — fait (branche feat/prononciation-suivi)

- Chaque phrase jugée (décision 2) est gardée sur l'iPhone
  (un nouveau modèle SwiftData), avec ses fautes. C'est ce que lira le profil
  d'apprenant.
- Le README : une section « Prononciation ». Les sections « L'accent au phonème » et
  « S'enregistrer et se comparer au natif » disent encore que l'analyse des sons est
  écartée : elle se fait désormais sur le PC.
- **Test sur l'iPhone.**

## Plus tard (hors de ce plan)

- Le natif mot par mot. Il faudrait la place de chaque mot dans l'audio d'Assimil :
  le serveur pourrait l'aligner une fois pour toutes.
- Des phrases hors d'Assimil, ou des mots seuls pour un son difficile.
- Juger aussi les prises de la conversation.

## Décisions (2026-11-13)

1. **Cinq phrases par séance.**
2. **Les phrases jugées et leurs fautes sont gardées sur l'iPhone**, pour le profil
   d'apprenant à venir.
3. **On passe à la phrase suivante après une nouvelle tentative, même ratée.**
   Bloquer sur un son qu'on n'arrive pas encore à faire décourage.
