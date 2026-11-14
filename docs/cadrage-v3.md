# Cadrage v3 : un parcours d'unités, tiré du Plan curricular

**Proposé le 2026-11-14.** Ce cadrage prend la suite de `cadrage-v2.md` (validé le
2026-11-12 : le serveur, la conversation, la prononciation, puis le profil, tous faits).
Il part du document Claude « Système de progression — app d'espagnol » (14 novembre),
et l'adapte au code réel. Comme avant, chaque module aura son propre plan.

## Le but

L'app devient **un tuteur qui suit un parcours**, et non plus le lecteur d'une méthode.
Chaque jour, une séance de 30, 45 ou 60 minutes, assemblée selon le profil. Le parcours
est une suite d'**unités**, chacune bâtie autour d'une situation réelle (« Au
restaurant ») et terminée par une **mission** de conversation.

Ce qui distingue l'app de Duolingo, d'après le document : on parle dès le premier jour,
dans des situations qui ont du sens, et le chemin s'adapte au profil au lieu d'être le
même pour tous. On garde l'habitude quotidienne, la progression visible et le retour
immédiat. On laisse les séances de 5 minutes, les phrases isolées et les points qui
récompensent le clic.

**Assimil passe en bonus**, dans « Mes sources », pour le shadowing. Le cœur de l'app
ne dépend plus d'aucune méthode.

## Ce qui existe déjà, et où ça va

Rien n'est jeté. Chaque bloc de la séance du jour reprend un module qui existe.

| Bloc de la séance | Ce qui existe (dans `dev`) | Ce qui manque |
|---|---|---|
| 1. Échauffement et révisions | Les cartes FSRS du vocabulaire | Des cartes tirées des unités, pas seulement d'Assimil |
| 2. Nouveau contenu | Le lecteur, le shadowing, la courbe d'intonation (Assimil) | Le dialogue modèle de l'unité, avec sa voix |
| 3. Prononciation | La séance de prononciation, qui vise les sons faibles (profil, étape 1) | Des phrases tirées de l'unité, et non d'Assimil |
| 4. Mission de conversation | La conversation, qui reçoit le profil (profil, étape 3) | Un rôle à jouer, un objectif, et un bilan qui dit s'il est atteint |
| 5. Bilan | Le récapitulatif, les fautes qui reviennent (profil, étape 2) | Ce qui est réussi, pas seulement ce qui est faux |

## Le Plan curricular : ce qu'il est, et ce qu'il n'est pas

Le Plan curricular de l'Instituto Cervantes décrit, niveau par niveau de A1 à C2, ce
qu'un apprenant doit savoir, en espagnol d'Espagne. Il est organisé en inventaires :
grammaire, prononciation, fonctions (« demander une information »), notions par thème
(alimentation, logement, travail…), et d'autres.

**Ce n'est pas un programme.** Il ne propose ni unités, ni ordre de leçons, ni missions.
Les universités qui le suivent bâtissent leurs propres unités à partir de ses
inventaires. On fera de même : le Plan curricular dit **quoi** apprendre à chaque
niveau, et les unités disent **dans quel ordre et dans quelle situation**.

On ne l'extrait pas en entier d'un coup. Chaque unité apporte les points dont elle a
besoin, sous leur identifiant (`gram.…`, `func.…`), et le catalogue grandit avec les
unités. Le site du Centro Virtual Cervantes était en maintenance le 14 novembre :
l'extraction complète attendra.

## Principes

Les principes 1, 2, 3 et 5 de `cadrage-v2.md` restent. Le principe 4 change, et deux
s'ajoutent.

1. **L'accueil est la porte d'entrée unique.**
2. **Un module s'essaie, puis se garde ou se retire.**
3. **Le contenu vient d'un paquet, l'état de l'apprenant vit dans les tables communes.**
4. **Sans le PC, une séance réduite.** *(remplace « le serveur est un plus »)* La séance
   du jour garde les révisions et le nouveau contenu. La prononciation et la mission
   attendent le PC. L'app reste utilisable, mais le cœur de la séance a besoin du PC.
5. **Mesurer avant de construire.**
6. **Les unités sont écrites une fois, relues, puis livrées dans un paquet.** Claude les
   rédige dans le dépôt, Ethan les relit. Ni l'IA du PC ni une génération à la volée :
   un modèle de 8B se trompe sur les points fins, et un texte relu vaut ce que valait
   celui d'Assimil.
7. **Une unité de bout en bout avant d'en écrire vingt.** Le format, la séance et la
   mission se valident sur une première unité. Le chemin, le test de départ et les
   examens viennent ensuite.

## L'unité

Une unité est un fichier du paquet de contenu, comme `vocab.json` aujourd'hui. Exemple
de la première, « Au restaurant », niveau A2 :

- **le dialogue modèle**, en espagnol, avec sa traduction et ses notes, comme une leçon
  d'Assimil saisie depuis le livre ;
- **le vocabulaire** (la carta, el primer plato, la cuenta…), qui devient des cartes
  FSRS ;
- **une ou deux structures** de grammaire, et les **fonctions** visées (commander,
  demander ce que contient un plat, se plaindre poliment), sous leur identifiant ;
- **des phrases pour la prononciation**, de 4 à 12 mots, qui contiennent les sons
  travaillés ;
- **la mission** : le rôle de l'IA (« le serveur d'un petit restaurant de Madrid »), ce
  qu'il faut obtenir (« commander un menu sans gluten et payer séparément »), et ce que
  le bilan vérifie.

**La voix du dialogue** est produite une fois par XTTS sur le PC, puis livrée dans le
paquet : elle se rejoue sans le PC. Pour viser un accent castillan, XTTS imite un
extrait de natif. Un extrait d'Assimil le fait déjà (`server/essais/README.md`).

## La séance du jour

Elle se choisit au lancement : 30, 45 ou 60 minutes. L'app assemble les cinq blocs de
l'unité en cours, à partir du profil. Les durées sont celles du document, à ajuster à
l'usage.

| Bloc | 30 min | 45 min | 60 min | Sans le PC |
|---|---|---|---|---|
| 1. Échauffement et révisions | 7 | 10 | 12 | oui |
| 2. Nouveau contenu | 10 | 15 | 20 | oui |
| 3. Prononciation | 5 | 7 | 10 | non |
| 4. Mission de conversation | 7 | 11 | 15 | non |
| 5. Bilan | 1 | 2 | 3 | en partie |

## Plus tard (hors des premières étapes)

- **Le chemin vertical** : une unité par groupe de nœuds, terminée par son bilan.
- **Le test de départ** (auto-évaluation, test de vocabulaire, conversation de
  placement). Le format et les conditions d'usage du LexTALE-Esp sont à vérifier.
- **Le niveau par compétence**, et **les examens de niveau** au format du DELE.
- **« Mes sources »** : importer ses propres audios avec leur texte (podcasts, RTVE).
- **La direction artistique**, à partir des maquettes de Claude Design.

## Ordre proposé

0. **Ce cadrage**, relu et validé.
1. **Le format d'une unité et la première unité**, « Au restaurant » (A2) : le fichier
   du paquet, et son contenu écrit par Claude et relu par Ethan. Les identifiants du
   Plan curricular de ses points de grammaire et de ses fonctions.
2. **La voix du dialogue**, produite par XTTS sur le PC, livrée dans le paquet.
3. **La mission** : la conversation joue un rôle, et le bilan dit si l'objectif est
   atteint et ce qui a été bien employé. Le `tag` libre des corrections devient un
   identifiant du catalogue.
4. **La séance du jour** : les cinq blocs assemblés depuis l'unité, avec les modules
   existants, et la séance réduite sans le PC. La séance Assimil reste sur l'accueil à
   côté, tant que le parcours n'a pas fait ses preuves.
5. **Le bilan d'une semaine d'usage**, avant d'écrire d'autres unités.

## Décisions (2026-11-14)

1. **Claude écrit les unités, Ethan les relit.**
2. **Sans le PC, une séance réduite** (révisions et nouveau contenu).
3. **La séance Assimil reste sur l'accueil** tant que le parcours n'est pas prêt.
4. **La première unité est « Au restaurant », niveau A2.** Le Plan curricular ne
   propose pas d'unités ; on les bâtit à partir de ses inventaires.

## Questions

1. **Ton niveau**, à l'oral et à l'écrit : A2 pour la première unité te semble-t-il
   juste ?
2. **La durée par défaut** de la séance du jour : 30, 45 ou 60 minutes ?
3. **La voix du dialogue** : la même voix que le partenaire de conversation, ou une autre
   pour distinguer le dialogue modèle de l'IA ?
