# Cadrage : vers une app d'apprentissage complète

> **Suite : `cadrage-v2.md`** (2026-11-12) — l'app d'espagnol complète, avec le PC de la maison comme serveur.

**Validé le 2026-11-07** (décisions plus bas). Rien n'est codé. Ce document décide
quels modules on ajoute, dans quel ordre, et comment ils se branchent sur l'app.
Chaque module aura son propre plan, comme `refonte-modele-donnees.md`.

## Ce que dit l'usage

- **Seul l'accueil sert** : la séance du jour. L'onglet Réviser n'était jamais
  ouvert, le drapeau jamais utilisé, l'écoute libre rarement (#19, PR #50 et #51).
- L'app s'utilise **à la maison, en bougeant, écran consultable**. Le fonctionnement
  écran verrouillé reste requis, mais il est secondaire.
- Ce qui plaît : **l'oral** (répondre au micro) et **l'intonation** (la courbe).

## Principes proposés

1. **L'accueil est la porte d'entrée unique.** Un module apparaît sur l'accueil quand
   il a quelque chose à faire aujourd'hui, pas dans un onglet de plus. Un onglet
   qu'on n'ouvre pas, c'est une fonction qui n'existe pas.
2. **Un module s'essaie, puis se garde ou se retire.** Pas de fonction gardée en
   veille.
3. **Le contenu vient d'un paquet, l'état de l'apprenant vit dans les tables
   communes** (`Card`, `ReviewLog`, `StudyEvent`). La refonte du modèle de données
   a été faite pour ça : un mot peut être une carte au même titre qu'une phrase.
4. **Hors ligne, rien ne sort du téléphone.**
5. **Mesurer avant de construire.** Un prototype chiffré sur quelques leçons
   précède chaque module dont la faisabilité n'est pas acquise.

## Modules candidats

| Module | Ce que c'est | Contenu | Faisabilité | Avis |
|---|---|---|---|---|
| **Vocabulaire** | Les mots des leçons déjà faites, en cartes à la Anki | Tiré du texte espagnol des leçons | À vérifier (voir plus bas) | **En premier** |
| **Prononciation** (#44) | Dire quel son corriger, et comment | Phonèmes calculés localement | En local sur l'iPhone, écarté : le test sur ta voix ne repère que 24 % des fautes (README) | Pas de Core ML ; à reprendre avec un PC de la maison comme serveur |
| **Rappel** (angle « recall ») | Le français d'une phrase → la redire en espagnol | Traduction du livre | Bloqué : le français n'existe que pour les leçons 1 à 5 | Plus tard |
| **Conjugaison** | Exercices de conjugaison | Un paquet à construire | Contenu à créer de zéro | Plus tard |
| **Lecteur** | Lire des textes hors Assimil | Textes à importer | Import de paquets à faire | Plus tard |

Le **shadowing** n'a pas de ligne à part : la séance du jour le fait déjà (étape
Répétition), et la deuxième vague aussi.

## Le vocabulaire, de plus près

**Ce que ça donnerait.** Chaque jour, l'accueil propose « 12 mots à revoir » à côté de la
séance. Les mots viennent des leçons déjà validées : ceux de la leçon du jour arrivent
le lendemain. Le recto montre le mot espagnol. Le verso montre son sens et la phrase
de la leçon où il apparaît, avec son audio : l'audio Assimil est découpé par phrase,
pas par mot. Tu notes ensuite : À revoir, Difficile, Bien, Facile.

**Pourquoi une note, alors que la révision des phrases n'en a pas.** La révision des
phrases se voulait mains libres. Le vocabulaire, lui, se fait écran en main, ce qui
correspond à ton usage réel. Avec une note, **FSRS** a enfin un sens : il espace les
cartes selon tes réponses, et la place est déjà prévue dans `Card`.

**Les trois inconnues, à mesurer sur 5 leçons avant de construire :**

1. **Trouver les mots.** On découpe le texte espagnol (fiable pour les 100 leçons) et
   on ramène chaque mot à sa forme de base (`hablo` → `hablar`) avec le framework
   NaturalLanguage d'Apple. Il faut vérifier que la forme de base existe pour
   l'espagnol et ce qu'elle vaut.
2. **Le sens en français.** Le livre ne le donne que pour les leçons 1 à 5. La piste
   est le framework Translation d'Apple : il traduit sur l'appareil, gratuitement,
   de l'espagnol vers le français. Il faut voir ce que vaut la traduction d'un mot
   isolé. Sinon, la phrase de la leçon (texte et audio) sert de contexte au lieu
   d'une traduction, ce qui est d'ailleurs l'esprit d'Assimil.
3. **Le tri.** Les mots-outils (`el`, `de`, `que`) n'ont rien à faire en cartes. Il
   faut fixer le seuil : une liste d'exclusion, ou la fréquence dans les leçons.

**Ce que ça remplacerait.** Le drapeau et la révision des phrases marquées. Au lieu
de marquer une phrase, on pourrait marquer un mot (« celui-là, je ne le connais
pas »), qui deviendrait une carte prioritaire.

## Décisions (2026-11-07)

1. **Le vocabulaire d'abord.** La prononciation (#44) suit.
2. **Le sens d'un mot : les deux**, une traduction et la phrase de la leçon où il
   apparaît (texte et audio).
3. **Les deux sens de carte** : espagnol → français et français → espagnol, soit deux
   cartes par mot (deux angles sur le même `ItemID`).
4. **20 nouvelles cartes par jour au plus.** La carte français → espagnol d'un mot
   n'arrive qu'une fois la carte espagnol → français connue.
5. **Le drapeau est retiré**, et avec lui la révision des phrases marquées, à
   l'arrivée du vocabulaire.

## Mesures (faites avec ce qui est devenu tools/vocabulaire/build-vocab.swift)

Le script lit le texte espagnol, découpe les mots, retrouve leur forme de base et
écarte les mots-outils et les noms propres. Le texte Assimil reste hors dépôt, la
sortie aussi : seuls les chiffres figurent ici.

| | Leçons 1 à 5 | Leçons 1 à 100 |
|---|---|---|
| Mots lus | 216 | 16 361 |
| Mots-outils écartés | 37 % | 41 % |
| **Mots à apprendre** (formes de base) | 43 | **1 938** |
| Nouveaux mots par leçon (médiane) | 9 | **21** (de 1 à 40) |

- **Le rythme colle aux 20 par jour** : une leçon par jour apporte une vingtaine de
  mots. Le parcours complet représente environ 1 900 mots.
- **La forme de base est juste à 93 % environ** (vérifiée à la main sur 60 mots tirés au
  hasard : `estoy / está / estás` → `estar`, `tomé / tomando` → `tomar`). Les erreurs
  sont du genre `barran` → `barrar` au lieu de `barrer`, ou un point resté collé à un
  mot. Il faudra une **liste de corrections** dans le paquet, et un geste pour
  écarter une carte absurde.
- **La classe de mot est peu fiable** (`hablar` étiqueté comme un nom) : elle sert
  à écarter les mots-outils, pas à l'affichage.
- **La traduction d'un mot isolé est juste à 85-90 % environ** (Translation d'Apple,
  sur l'appareil, 70 mots vérifiés à la main). Les erreurs se rangent en trois
  familles : un mot mal orthographié (`pesadilla` → « Causemar », `bombilla` →
  « Ampeule »), un sens hors contexte (`hostia` → « Hôte »), une erreur héritée de
  la forme de base. 102 mots reviennent identiques, presque toujours à raison
  (`café`, `dormir`, `triste`). **La phrase de la leçon est donc indispensable**
  à côté de la traduction : c'est elle qui donne le sens, la traduction aide.
- **Conséquence : le vocabulaire se calcule sur le Mac, pas sur l'iPhone.** On le
  calcule une fois et on le range dans le paquet, comme le texte. Les corrections
  à la main s'y appliquent avant l'installation, et l'iPhone n'a ni modèle à
  télécharger ni calcul à faire.

## Questions posées (réponses ci-dessus)

1. Le vocabulaire en premier, ça te va ? Ou la prononciation (#44) d'abord ?
2. Le sens d'un mot : une traduction (Translation d'Apple), la phrase de la leçon
   en contexte, ou les deux ?
3. Le sens des cartes : espagnol → français, l'inverse, ou les deux ? En
   français → espagnol, c'est plus dur et plus utile pour parler.
4. Combien de mots par jour, au plus ? Anki propose 20 nouveaux par défaut, ce qui
   fait beaucoup en plus de la séance.
5. Le drapeau : le retirer quand le vocabulaire arrive, ou le transformer en
   « marquer ce mot » ?

## Ensuite

Le plan du module : `docs/module-vocabulaire.md`.
