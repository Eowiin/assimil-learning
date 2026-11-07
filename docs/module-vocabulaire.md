# Module de vocabulaire

**Plan proposé, à valider.** Le pourquoi et les mesures sont dans
`docs/cadrage-app.md`. Comme pour la refonte du modèle de données, ce fichier dit
ce qu'il reste à faire et comment, et le README garde les décisions une fois faites.

## Ce qu'on construit

Les mots des leçons déjà validées deviennent des cartes, révisées à la Anki depuis
l'accueil. Chaque mot a deux cartes :

- **reconnaître** (espagnol → français) : on voit `estar`, on donne le sens ;
- **retrouver** (français → espagnol) : on voit « être », on retrouve `estar`. Cette
  carte n'arrive qu'une fois la première connue.

Le verso montre la traduction, la phrase de la leçon où le mot apparaît (texte, son
français s'il existe) et un bouton pour l'entendre. On note ensuite : **À revoir,
Difficile, Bien, Facile**. FSRS espace les cartes selon ces notes. On peut retirer
une carte absurde d'un geste.

Au plus **20 nouvelles cartes par jour**. Le drapeau et la révision des phrases
marquées disparaissent.

## Principes

1. **Le vocabulaire se calcule sur le Mac et voyage dans le paquet**, comme le texte.
   L'iPhone ne fait ni découpage, ni forme de base, ni traduction.
2. **Un mot se désigne par sa forme de base** : `assimil-es:V:estar`. Les cartes sont
   `assimil-es:V:estar#recognize` et `assimil-es:V:estar#recall`.
3. **Corriger une forme de base ne doit pas orpheliner une carte.** Le fichier de
   corrections dit `barrar → barrer`, et le paquet garde la trace des renommages pour
   que l'app déplace les cartes concernées.
4. **Le paquet reste hors dépôt** (texte Assimil, traductions qui en dérivent). Seuls
   les scripts sont versionnés, comme pour le texte.
5. **Mêmes conventions que la refonte** : une branche et une PR par étape, partie de
   `dev` ; arrêt après chaque étape pour un test sur l'iPhone ; tests unitaires et
   d'interface à chaque fois.

## Étapes

### 1 · Le vocabulaire dans le paquet (Mac)

`tools/vocabulaire/` passe de la mesure à la production :

- `build-vocab.swift` lit `text/L001.json`… et écrit `vocab.json` dans le paquet. Pour
  chaque mot, il garde : la forme de base, les formes rencontrées, la traduction, la
  première leçon, et les occurrences (leçon, phrase) qui donnent le contexte et l'audio.
- `corrections.json` (hors dépôt, à sauvegarder avec le texte) : les formes de base à
  corriger, les traductions à remplacer, les mots à écarter. Il s'applique à chaque
  génération.
- Les points restés collés aux mots (`fatal.`) sont nettoyés.
- Un résumé chiffré à chaque génération : nombre de mots, corrections appliquées,
  mots sans traduction.

Côté app : `ContentPack` lit `vocab.json` s'il existe, et `VocabItem` lit et écrit le
chemin `V:<forme>`, comme `AssimilItem` le fait pour `L012:S04`. Sans `vocab.json`,
rien ne change. Tests : lecture du fichier, forme canonique de l'identifiant.

### 2 · FSRS

L'ordonnanceur, sans interface :

- FSRS-6 avec ses paramètres par défaut, rétention visée 90 %, sans optimisation
  (il faudrait des mois de journal pour en tirer quelque chose).
- `Card.scheduler = "fsrs"` ; `stability`, `difficulty` (déjà prévus dans `Card`) ;
  un état « nouvelle / en apprentissage / en révision / réapprentissage ».
- Chaque revue écrit un `ReviewLog` avec `rating` (1 à 4) et `context = "graded"`.
- Tests sur des valeurs de référence calculées une fois avec l'implémentation
  officielle (py-fsrs), consignées dans les tests.

Le champ d'état est la seule nouveauté de schéma : une propriété ajoutée avec une
valeur par défaut, donc une migration légère.

### 3 · L'écran de révision et l'accueil

- **Accueil** : une carte « Vocabulaire · 14 à revoir · 20 nouvelles » sous la séance
  du jour, qui ouvre la révision. Rien quand il n'y a rien à faire.
- **Nouvelles cartes** : celles des leçons validées, dans l'ordre du livre puis par
  fréquence, au plus 20 par jour. Une carte « retrouver » n'entre qu'une fois sa
  carte « reconnaître » passée en révision.
- **Révision** : le recto, « Voir la réponse », le verso (traduction, phrase de la
  leçon et son audio), les quatre notes, avec le délai suivant affiché sous chacune
  comme dans Anki. « Retirer ce mot » désactive ses deux cartes.
- **Temps d'étude** : `StudyEvent` avec une nouvelle activité, `vocab`.
- Tests unitaires (choix des nouvelles cartes, plafond de 20, déblocage de
  « retrouver ») et un test d'interface du parcours.

### 4 · Retrait du drapeau

- Le drapeau du lecteur, la révision des phrases (`SessionRequest.review`,
  `SessionReviews`, `CardReview.toggleFlag`) et la ligne « phrases à revoir » de
  l'accueil sont retirés.
- Les cartes `#listen` existantes restent en base, désactivées (on désactive, on ne
  supprime pas : l'historique reste).
- README : la section « La révision des phrases marquées » devient historique.

Cette étape peut se faire en même temps que la 3, pour que l'accueil ne montre
jamais deux révisions.

## Hors champ

Audio mot par mot (Assimil découpe par phrase), synthèse vocale, optimisation des
paramètres FSRS, conjugaison, import de paquets depuis Fichiers, synchro CloudKit.

## Points à valider

1. **Les noms d'angle** `recognize` et `recall`. « recall » était prévu pour les
   phrases (français → espagnol) ; ici il sert aux mots.
2. **« Connue »**, pour débloquer la carte « retrouver » : passée en révision dans
   FSRS, c'est-à-dire réussie au moins une fois un autre jour que celui de sa
   découverte.
3. **L'ordre des étapes** : 1 et 2 sont indépendantes (Mac et logique pure) ; 3 et 4
   vont ensemble.

## Vérifier, à chaque étape

Mêmes commandes que `docs/refonte-modele-donnees.md` (tests unitaires et d'interface
sur le simulateur, puis installation sur l'iPhone). L'iPhone joignable apparaît en
« connected » dans `xcrun devicectl list devices`.
