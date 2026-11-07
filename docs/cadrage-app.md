# Cadrage : vers une app d'apprentissage complète

**Brouillon, à valider.** Rien n'est codé. Ce document décide quels modules on
ajoute, dans quel ordre, et comment ils se branchent sur l'app. Une fois validé, chaque
module aura son propre plan, comme `refonte-modele-donnees.md`.

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
| **Prononciation** (#44) | Dire quel son corriger, et comment | Phonèmes calculés localement | Prototype prêt, test sur ta voix en attente | En parallèle, dès que tu peux t'enregistrer |
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

## Questions pour toi

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

Après tes réponses : un prototype de mesure du vocabulaire sur les leçons 1 à 5
(mots trouvés, formes de base, qualité des traductions), en chiffres. Puis un plan
par étapes, comme pour la refonte du modèle de données.
