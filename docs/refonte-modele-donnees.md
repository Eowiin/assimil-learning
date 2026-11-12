# Refonte du modèle de données — terminée

**Terminée** : les quatre étapes sont faites et testées sur l'iPhone (PR #45 à
#48), le nettoyage final dans la PR `chore/fin-refonte`. Ce fichier reste pour
l'historique ; les décisions vivent dans le README (« Stockage et migration »,
« Le contenu vient d'un paquet », « Cartes, journal et temps d'étude »). Les
points hors champ, en bas, restent à décider un par un.

## Pourquoi

L'app doit devenir une app d'apprentissage plus large : plusieurs modules (séance
Assimil, révision, plus tard conjugaison, lecteur, shadowing), plusieurs langues à
terme, une répétition espacée unifiée. Cette refonte ne touche **que le modèle de
données**. L'app ne gère que l'espagnol, mais le modèle doit rester modulaire.
Aucun changement visible pour l'utilisateur, sauf le bouton d'export (étape 1).

## Principes

1. **Le contenu n'entre pas dans SwiftData.** Leçons, phrases, textes, audio
   viennent d'un paquet (`PackStore`). Un item se désigne par un identifiant global
   stable, sans version de paquet : `assimil-es:L012:S04` (dialogue),
   `assimil-es:L012:T03` (exercice). SwiftData ne garde que l'état de l'apprenant.
2. **Ce qui est propre à Assimil reste propre à Assimil.** `DailySession`,
   `CourseAnchor`, `LessonProgress` ne sont pas généralisés, et ne reçoivent pas de
   `courseID` (inutile tant qu'il n'y a qu'un cours ; migration légère plus tard).
3. **Pas de FSRS.** Les phrases marquées gardent l'échelle actuelle
   (`ReviewSchedule` : 1, 3, 7, 21, 60 jours, sans notation). Le schéma laisse
   seulement la place à FSRS : `stability` et `difficulty` optionnels, `rating`
   nullable dans le journal.
4. **Pas de migration SwiftData personnalisée** (`MigrationStage.custom`). On ajoute
   des tables (migration légère automatique), on copie par une tâche applicative
   idempotente.

## Conventions

- Commentaires en français qui expliquent le pourquoi ; clés en chaîne lisibles ;
  pas de `@Relationship` ; une valeur par défaut sur chaque propriété des `@Model`.
- Une branche et une PR par étape, **partie de `dev`, PR vers `dev`**. Arrêt après
  chaque étape pour un test sur l'iPhone.
- Le contenu Assimil est hors dépôt : ne jamais le commiter (le dépôt est public).
- Pas de nouveau paquet Swift (pas de StudyKit : rien ne le justifie encore).
- Si le code contredit ce plan ou qu'une décision n'est pas claire : s'arrêter et
  demander.

## Schéma cible

```
Card            key (unique)      "assimil-es:L012:S04#listen"
                itemID            "assimil-es:L012:S04"
                angle             "listen" — seul angle pour l'instant
                language          "es"
                scheduler         "ladder" | "fsrs"
                isActive          désactiver au lieu de supprimer : l'historique reste
                createdAt         première création
                activatedAt       dernière activation — tri de la liste « À revoir »
                dueAt, reps, lastReviewedAt
                stability?, difficulty?
                index : dueAt, itemID

ReviewLog       ajout seul — la source de vérité ; les champs de Card en sont un cache
                cardKey, reviewedAt
                rating: Int?      nil pour une revue mains libres
                context           "handsFree" | "graded" | "spoken"
                spokenMatch: Bool?, durationMs: Int?
                index : cardKey, reviewedAt

StudyEvent      day (début de journée), startedAt, seconds
                language          "es"
                activity          "assimil.daily" | "review" | "assimil.listen" | "assimil.legacy"
                courseID?         "assimil-es" pour les activités Assimil
                index : day

DataMigration   key (unique), completedAt — voir étape 3
```

Écarts au schéma d'origine, validés :

- **`key` et non `id`** : sous `@Model`, `id` entre en conflit avec l'`id`
  d'`Identifiable` que fournit `PersistentModel`. Le reste du code dit déjà `key`.
- **`activatedAt`** en plus : la liste « À revoir » est triée par date de marquage,
  et une phrase remarquée doit remonter en tête.
- **`cardKey`** dans `ReviewLog` (et non `cardID`), par cohérence avec `key`.

## Décisions validées

- **Card réactivée = planification remise à zéro.** Remarquer une phrase
  démarquée la rend due tout de suite, `reps = 0`, `activatedAt = maintenant`, comme
  aujourd'hui où elle est recréée. Le journal garde ses revues passées.
- **La copie de l'étape 3 synchronise**, elle ne se contente pas d'insérer. Entre
  l'étape 3 et l'étape 4, l'app écrit encore `DifficultSentence` et `StudyDay` : une
  copie unique laisserait les cartes se périmer. À chaque lancement, la copie remet
  les cartes à l'identique de l'ancien modèle. À l'étape 4, une dernière
  synchronisation, puis plus jamais.
- **Réglages garde seulement « Temps total »**, calculé à l'étape 4 depuis
  `StudyEvent`. Il n'existe pas d'affichage du temps par jour, on n'en ajoute pas ;
  l'agrégation par jour est une fonction testée, prête pour plus tard.

## Étapes

### 1 · Export de sauvegarde — fait (PR #45)

Réglages › Sauvegarde › « Exporter une sauvegarde » : `StoreBackup` sauvegarde le
contexte et copie `.store`, `-wal`, `-shm` dans un dossier daté, rangé dans Fichiers.
Restauration manuelle décrite dans le README.

### 2 · PackStore et ItemID — fait (PR #46)

`PackStore` (`@Observable`, environnement) remplace `Manifest.shared` : paquet
installé dans `Application Support/Packs/assimil-es/`, sinon le bundle. Sans paquet,
« Aucun contenu ». Le manifest descend par `@Environment(\.manifest)`. `ItemID`
(paquet + chemin opaque) et `AssimilItem` (`L012:S04`, forme canonique,
conversion de l'ancienne clé `L012-S04`).

### 3 · Nouvelles tables et copie — fait (PR #47)

Tables dans `Model/LearnerState.swift`. La tâche s'appelle `LegacyCopy`
(`Model/LegacyCopy.swift`), lancée dans `AssimilESApp.init`, avant toute vue ; elle
renvoie un `Report` (comptes, clés ignorées) et journalise dans la catégorie
`data`. Précision apportée en route : `activatedAt` est recopié depuis `markedAt`
**à chaque passe**, pas seulement à la création — une phrase remarquée a un
nouveau `markedAt`, et sa carte réactivée doit remonter en tête.

Ce qui était prévu :

1. Ajouter `Card`, `ReviewLog`, `StudyEvent`, `DataMigration` à
   `AssimilESApp.models`, avec `#Unique` et `#Index`. Vérifier par un test (comme
   `MigrationTests.legacyStoreOpens`) qu'un stockage de l'étape 2 s'ouvre avec le
   nouveau schéma, données intactes.
2. Une tâche `LegacyCopy` (nom à confirmer), `@MainActor`, lancée au démarrage avant
   l'affichage des listes. Elle **synchronise** :
   - Chaque `DifficultSentence` → la `Card` de clé `<itemID>#listen` (via
     `AssimilItem(legacyKey:)`). Créée si absente : `scheduler = "ladder"`,
     `language = "es"`, `createdAt = activatedAt = markedAt`. Dans tous les cas :
     `dueAt`, `reps = reviewCount`, `lastReviewedAt` recopiés, `isActive = true`.
   - Une `Card` « ladder » active sans `DifficultSentence` correspondante →
     `isActive = false` (la phrase a été démarquée entre deux lancements).
   - Une clé ancienne illisible est ignorée et journalisée, jamais fatale.
   - Chaque `StudyDay` → un `StudyEvent` `activity = "assimil.legacy"`,
     `language = "es"`, `courseID = "assimil-es"`, `day = startedAt = StudyDay.day`,
     `seconds` recopiées. Retrouvé par (`activity`, `day`) : un par jour, mis à jour.
   - Aucun `ReviewLog` n'est créé : l'ancien modèle n'a pas d'historique. Les
     `reps` copiés ne sont donc pas adossés au journal — c'est attendu.
   - Les anciennes tables ne sont ni modifiées ni supprimées.
3. Rien d'autre ne lit encore les nouvelles tables : comportement inchangé.
4. Tests sur conteneur en mémoire : une passe ; deux passes sans doublon ; une
   phrase démarquée entre deux passes → carte inactive ; remarquée ensuite → carte
   réactivée ; une phrase revue entre deux passes → échéance et `reps` suivent ;
   un `StudyDay` qui grossit → l'événement suit ; une clé illisible.

`DataMigration` sert à l'étape 4 : la fin de la copie y est inscrite **dans le
stockage**, pas dans `UserDefaults`, pour voyager avec une sauvegarde. Restaurer
une sauvegarde d'avant la bascule relancerait ainsi la copie, comme il faut.

### 4 · Bascule — fait (PR #48)

`LegacyCopy.finishIfNeeded` au démarrage (copie et inscription d'un même `save` ;
inscription illisible → pas de copie). Règles dans `Model/CardReview.swift` :
`CardReview.review`, `CardReview.toggleFlag`, et `SessionReviews` pour la revue
unique par séance. Temps : `StudyActivity`, `StudyTime.record(_:as:in:)`,
`StudyTime.total`, `StudyTime.secondsByDay`. Tests dans `BasculeTests`.

Précisions apportées en route :

- **Prises de voix** : `markKey` les nommait (`L012-S04.m4a`). Elles gardent ce
  nom par `SessionStep.recordingKey` ; aucun fichier n'est renommé.
- **Réactivation** : `lastReviewedAt` n'est pas effacé — c'est un fait, pas une
  planification ; seuls `dueAt`, `reps`, `activatedAt` sont remis à zéro.
- **Extraits** (`SessionRequest.excerpt`) : leur temps compte pour
  `assimil.daily`, l'écran qui les lance surtout.

Ce qui était prévu :

1. Au démarrage : si `DataMigration["legacy-copy"]` est absent, une dernière
   synchronisation, puis l'inscrire. Ensuite la copie ne tourne plus.
2. La révision lit et écrit `Card` :
   - `SessionBuilder.review` prend des cartes actives dues, résolues en phrases par
     `ItemID` → `AssimilItem` ; ordre : échéance, puis clé.
   - `SessionStep.markKey` devient la clé de carte.
   - Revue (une fois par séance, comme aujourd'hui) : `dueAt =
     ReviewSchedule.next(after: reps)`, `reps += 1`, `lastReviewedAt`, et un
     `ReviewLog` (`rating = nil`, `context = "handsFree"`).
   - Le drapeau : carte active → désactivée (en révision, phrase suivante) ; carte
     inactive → réactivée et remise à zéro ; absente → créée.
   - `DifficultListView` : cartes actives triées par `activatedAt` décroissant ; le
     balayage désactive. `TodayView` compte les cartes dues.
3. Le temps d'étude écrit un `StudyEvent` par enregistrement (`StudyTime.record`) :
   `assimil.daily` (séance du jour), `review` (révision, `courseID` nil),
   `assimil.listen` (écoute libre) ; `startedAt = maintenant − secondes`. Réglages ›
   Temps total = somme des `StudyEvent` (les `assimil.legacy` y compris). Agrégation
   par jour en fonction testée.
4. La série reste calculée sur les séances validées (`DailySession`), sans changement.
5. `DifficultSentence` et `StudyDay` ne sont plus écrits, mais restent dans le schéma.
6. Tests : révision sur cartes, drapeau (trois cas), journal ajouté une seule fois
   par séance, temps total sans double compte, bascule lancée deux fois. Adapter
   `SessionTests` et les tests d'interface qui marquent une phrase.

### Nettoyage final — fait

Code mort retiré (`DifficultSentence.recordReview`, devenu une aide des tests, et
`isDue`) ; `ReviewSchedule` rangé avec `CardReview`, `StudyTime` avec `StudyEvent` ;
commentaires et README remis à jour (nom des prises de voix, décisions du plan).

## Hors champ

Import de paquets depuis Fichiers, suppression des anciennes tables, FSRS, angle
« recall », synchro CloudKit, nouveau paquet Swift.

## Vérifier, à chaque étape

```bash
xcodebuild test -project AssimilES.xcodeproj -scheme AssimilES \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:AssimilESTests
xcodebuild test -project AssimilES.xcodeproj -scheme AssimilES \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:AssimilESUITests
```

Puis installer sur l'iPhone (iPhone 11 « Tatane ») — l'utilisateur teste sur
l'appareil, pas sur le simulateur :

```bash
xcrun devicectl list devices      # doit être « available (paired) »
xcodebuild -project AssimilES.xcodeproj -scheme AssimilES -sdk iphoneos \
  -destination 'platform=iOS,id=<identifiant>' -derivedDataPath build/device \
  -allowProvisioningUpdates build
xcrun devicectl device install app --device <identifiant> \
  build/device/Build/Products/Debug-iphoneos/AssimilES.app
```

« unavailable » : l'iPhone est verrouillé ou hors du Wi‑Fi — demander de le
déverrouiller. Avant d'installer une étape qui touche aux données, rappeler
d'exporter une sauvegarde.
