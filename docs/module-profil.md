# Module du profil d'apprenant

**Validé le 2026-11-14.** Le pourquoi est dans `docs/cadrage-v2.md` (« Plus tard :
le profil d'apprenant »). La conception d'ensemble est dans le document Claude
« Profil d'apprenant — conception » (12 novembre). Ce plan en reprend ce qui se
construit maintenant, adapté au code réel. Il signale aussi ce qui, dans la
conception, ne colle pas avec l'existant. Comme pour les autres modules, ce fichier
dit ce qu'il reste à faire et comment, et le README garde les décisions une fois
faites.

## Ce qu'on construit

Le profil n'est pas un écran. C'est ce que l'app sait de l'apprenant, lu par les
modules pour choisir quoi proposer. Ce plan en fait trois usages concrets, du plus
simple au plus lourd :

1. **La prononciation travaille les sons les plus ratés.** La séance tire ses cinq
   phrases selon les fautes passées, et plus au hasard.
2. **Les fautes de conversation se reconnaissent d'une fois sur l'autre.** Le
   récapitulatif dit qu'une faute revient (« ser/estar : 3e conversation »).
3. **Le partenaire de conversation s'adapte.** Il reçoit la faute à surveiller et
   quelques mots à faire reprendre.

Le niveau par compétence, le catalogue d'étiquettes, le test de placement et le
tableau de bord restent pour plus tard. Ils demandent des données que l'app ne
recueille pas encore (voir « Ce qui ne colle pas »).

## Principes

1. **Les données restent sur l'iPhone ; le serveur ne garde rien** (décision 2 du
   cadrage v2). Quand le serveur a besoin du profil, l'iPhone joint à sa requête une
   vue courte, calculée pour l'occasion.
2. **Les records gardés sont le journal.** `PronunciationRecord`, `ConversationRecord`
   et `ReviewLog` sont ajoutés et jamais modifiés. Le profil en est une **projection** :
   on le recalcule en les relisant. On n'ajoute pas de table d'événements tant que
   ces records suffisent.
3. **Calculer à la demande, sans table de projection au départ.** Cinq prises par
   séance de prononciation, une conversation par jour : relire les records à
   l'ouverture d'un écran coûte quelques millisecondes. On ne crée `PhonemeState` ou
   `ErrorPattern` en SwiftData que si une mesure montre que c'est lent.
4. **Le profil choisit, il ne décide pas seul.** Une partie de chaque séance reste
   tirée comme aujourd'hui : un son jamais travaillé ne doit pas disparaître parce
   qu'on n'a aucune donnée dessus.
5. **Sans historique, rien ne change.** Au premier jour, ou après une sauvegarde
   restaurée vide, chaque module se comporte comme aujourd'hui.
6. **Mêmes conventions que pour les autres modules** : une branche et une PR par
   étape, partie de `dev`. On s'arrête après chaque étape pour un test. Les tests
   unitaires et d'interface tournent à chaque fois, et ceux du serveur quand il
   change.

## Ce qui ne colle pas avec la conception

La conception a été écrite avant de relire le code. Voici les écarts, et ce que ce
plan en fait.

| La conception dit | Le code aujourd'hui | Ce que ce plan en fait |
|---|---|---|
| Un événement au format commun (`id`, `type`, `tags`, `correct`, `confidence`) | Pas de tel format. Chaque record a sa forme : une prise jugée, une conversation entière, une revue | On lit les records tels quels (principe 2). La conception le dit déjà en note : il fallait surtout étiqueter les corrections, ce qui est fait (PR #74) |
| Les étiquettes viennent d'un catalogue, calqué sur le Plan curricular (`gram.subjuntivo.presente.deseo`) | `tag` est du **texte libre**, écrit par Qwen (« ser/estar »). Il n'y a ni catalogue ni table `Tag` | On regroupe les `tag` en les repliant (casse, accents, espaces). On regarde ce que l'IA écrit pendant quelques semaines avant de figer un catalogue |
| Grammaire : un score de maîtrise, avec les emplois **corrects** et fautifs | Le récapitulatif ne rend **que les fautes**. Aucun emploi correct n'est relevé | Pas de score de maîtrise dans ce plan. On compte les fautes qui reviennent, rien de plus |
| Phonèmes : le score moyen du wav2vec2 par son | Chaque son a un `score` et un `threshold` **propres à ce son** (GOP). Une faute peut aussi venir de ZIPA ou du juge des r. Un score moyen n'a pas de sens d'un son à l'autre | On compte un **taux de fautes** par son : fautes sur fois où le son est attendu. Le jugement complet est gardé dans `PronunciationRecord.judgement`, les sons justes compris |
| Les sons d'un francophone : θ, jota, r/rr, b/d/g adoucis, voyelles, accent tonique | Le serveur juge θ, jota, r et v. `PronunciationDrill` ne sait viser que ces quatre-là (`SpanishTarget`). Les autres sons fautifs sont repérés, mais rien ne choisit une phrase pour eux | La première étape vise les quatre sons de `SpanishTarget`. Les autres fautes sont gardées et comptées, sans choisir de phrase pour elles |
| Les symboles du serveur et les sons visés sont la même chose | Le serveur rend `θ`, `x`, `r`, `ɾ`, `b`, `β`. `SpanishTarget` a `theta`, `jota`, `r`, `v`. `faultSymbols` ne garde que les symboles fautifs | Une petite table relie les deux : θ → theta, x → jota, r et ɾ → r, b et β → v (comme les familles de `SpanishSpelling`) |
| Vocabulaire : un rang de fréquence par lemme, et un état réceptif ou productif | Les mots viennent des leçons d'Assimil, sans rang de fréquence. Une carte `recognize` (espagnol → sens) et une carte `recall` (français → espagnol) existent pour chaque mot | On prend `recognize` pour le réceptif et `recall` pour le productif : c'est déjà la séparation voulue. Le vrai productif, un mot employé juste en parlant, attendra |
| Compréhension écrite et orale : mots consultés, questions réussies | Ces modules n'existent pas. `StudyEvent` ne garde que le temps passé, par activité | Hors de ce plan |
| Conversation : les sons jugés en arrière-plan pendant l'échange | Les tours de conversation ne passent pas par le juge de prononciation | Hors de ce plan (déjà dans « Plus tard » de la prononciation) |
| Le bilan de séance passe dans le LLM **avec réflexion** | `Reels._chat` coupe toujours la réflexion de Qwen3, récapitulatif compris | À essayer à part, s'il manque des fautes ou si les `tag` sont flous (question 6) |
| Annuler un événement (« correction fausse ») | Les corrections sont un tableau JSON dans `ConversationRecord`, sans identifiant propre | La place dans le tableau suffit à en désigner une. Hors de ce plan |
| Le tuteur reçoit son contexte à `start` et à `turn` | `start` ne prend qu'un sujet. La consigne fixe le niveau à A2-B1 | Étape 3 : un champ optionnel en plus, l'API reste en version 1 |

## L'échange avec le serveur

**Étapes 1 et 2 : rien.** Tout se calcule sur l'iPhone, à partir de ce qu'il garde
déjà. `POST /pronunciation` et `POST /conversation/review` ne changent pas (la
catégorie et le `tag` des corrections viennent de la PR #74).

**Étape 3 : un champ optionnel `profile`**, dans `POST /conversation/start` (JSON)
et `POST /conversation/turn` (un champ de formulaire en JSON, comme `history`) :

```json
{"watch": "ser/estar",
 "words": ["aprovechar", "quedar con", "de momento"]}
```

- `watch` : la faute qui revient le plus, prise à l'étape 2.
- `words` : quelques mots dont la carte `recognize` est connue et la carte `recall`
  pas encore. Ce sont des mots compris mais pas encore dits.
- Sans `profile`, la consigne reste celle d'aujourd'hui. Ajouter un champ optionnel
  ne change pas la forme des anciens appels : l'API reste en **version 1**.
- La vue reste courte (une faute, cinq mots au plus) : une consigne courte garde
  Qwen3 8B rapide et concentré.
- Le niveau reste fixé à A2-B1 dans la consigne : l'app ne sait pas encore
  l'estimer.

## Étapes

### 1 · La prononciation choisit selon les sons ratés (app) — fait (PR #76)

- **`PhonemeStats`**, un type sans stockage, calculé depuis les `PronunciationRecord` :
  - pour chaque son de `SpanishTarget`, le nombre de fois où il était attendu et le
    nombre de fautes ;
  - lu dans le jugement complet (`judgement`), pas dans `faultSymbols`, qui ne
    garde pas les sons justes ;
  - un indice (`hint`, le r roulé dit battu) n'est pas une faute ;
  - **seulement la première prise de chaque phrase** (`attempt == 1`). La deuxième
    vient juste après le conseil, et compterait une réussite qui ne dure pas ;
  - sur les **30 derniers jours**, pour qu'un son corrigé cesse d'être visé ;
  - un son attendu moins de **6 fois** reste « pas assez vu », et n'est pas classé.
- **`PronunciationDrill.pick`** reçoit ces chiffres :
  - **3 phrases sur 5** contiennent l'un des deux sons au plus fort taux de fautes,
    s'il est au-dessus de zéro ;
  - les 2 autres sont tirées par la règle actuelle (chaque son couvert, les plus
    rares d'abord). C'est ainsi qu'un son « pas assez vu » se mesure ;
  - sans historique, ou sans son classé, la règle actuelle seule.
- `PronunciationEntry` lit les records à l'ouverture de la séance, une fois, comme
  il lit déjà les textes des leçons.
- **L'écran le dit** (décision 3) : une ligne discrète sous le titre, au début de la
  séance, « Aujourd'hui : surtout le th anglais ». Rien quand la séance n'est pas
  ciblée.
- **Tests** : le taux d'un son (fautes, sons justes, indices, deuxième prise
  ignorée, prises de plus de 30 jours ignorées) ; la table des symboles (`ɾ` et `r`
  font le même son, `β` va vers `v`) ; le tirage avec un générateur fixé, qui donne
  trois phrases du son le plus raté ; sans historique, le même tirage qu'aujourd'hui.
- **Test sur l'iPhone** : quelques séances en ratant exprès un son (le θ dit [s]),
  puis la séance suivante doit en proposer davantage, et le dire.

### 2 · Les fautes de conversation qui reviennent (app) — fait (PR #78)

- **`ErrorPatterns`**, sans stockage, calculé depuis les `ConversationRecord` :
  - les corrections regroupées par `tag` replié (casse, accents, espaces), avec leur
    catégorie, le nombre de conversations où le point revient, et les trois derniers
    exemples ;
  - une correction gardée avant la PR #74, sans `tag`, n'est comptée nulle part.
- **Le récapitulatif** l'affiche sous l'explication d'une faute qui revient
  (« ser/estar — déjà relevé dans 2 conversations »). Une première faute ne montre
  rien de plus.
- **Tests** : le regroupement (« Ser/Estar » et « ser / estar »), le compte par
  conversation et non par phrase, les anciennes corrections sans `tag`.
- **Test sur l'iPhone** : deux conversations avec la même faute.

### 3 · Le partenaire reçoit le profil (serveur et app) — en test (branche feat/profil-partenaire)

- **Serveur** : le champ `profile`, et une ligne de consigne quand il est là (« Usa
  de forma natural algunas de estas palabras… », « Si el estudiante falla en… »). La
  consigne interdit toujours de corriger pendant l'échange. Tests avec le faux
  moteur : la consigne reçue avec et sans profil.
- **App** : `ConversationClient` envoie la vue. Elle est calculée à l'ouverture de
  la conversation, depuis l'étape 2 et les `Card`.
- **Tests** : la vue (la faute la plus fréquente, les mots `recognize` connus sans
  `recall` connu, cinq au plus), et le formulaire envoyé.
- **Test sur le PC puis sur l'iPhone** : `essais/appel.py` avec un profil, pour juger
  si l'IA reprend les mots sans forcer ; puis une vraie conversation.

- **Premier essai (2026-11-14) : sans effet.** Une règle en tête de consigne (« si ça
  vient naturellement, emploie un de ces mots ») était ignorée par Qwen3 8B. D'où :
  - une **note précise à chaque réplique**, collée au message auquel l'IA répond :
    un seul mot, qui tourne d'un tour à l'autre, et une question qui oblige à
    employer le point. Elle n'entre pas dans l'historique que l'app garde ;
  - **Deuxième essai : le point trop appuyé.** L'IA recopiait le choix (« ¿eres o
    estás…? ») à chaque tour. Le point n'est plus demandé qu'à l'ouverture, puis une
    réplique sur trois, par une question ordinaire, sans options ni nom du point ;
  - l'**écran de conversation affiche le profil** en une ligne (« Aujourd'hui :
    ser/estar · aprovechar, quedar con »), et le serveur l'écrit dans son terminal.

### 4 · Essai : le récapitulatif avec réflexion (PC)

Indépendant des autres étapes (décision 6). Pendant l'échange, Qwen3 répond sans
réfléchir, pour aller vite. Au récapitulatif, le délai compte moins : avec la
réflexion, il repérerait peut-être mieux les fautes, et nommerait mieux leur point.

- `essais/appel.py` garde l'historique de chaque conversation dans `essais/sortie/`.
- Un essai repasse ces conversations au récapitulatif, sans puis avec réflexion,
  et montre les deux côte à côte : les fautes relevées, leur `tag`, et le temps.
- **On garde la réflexion si les corrections sont plus justes**, et si le délai
  reste supportable (quelques secondes, une fois par conversation).

## Plus tard (hors de ce plan)

- **Le niveau par compétence** (`SkillEstimate`) et le **test de placement**. Il
  faudrait des emplois corrects, et des questions de compréhension, que l'app ne
  recueille pas.
- **Le catalogue d'étiquettes** (`Tag`), calqué sur le Plan curricular, une fois
  qu'on aura vu les `tag` libres de quelques semaines de conversation.
- **Les emplois corrects** : un récapitulatif qui relève aussi les structures bien
  employées, pour un vrai score de maîtrise.
- **Le tableau de bord** : les sons, les fautes actives, le temps par activité.
- **Les préférences** (centres d'intérêt, mode de correction), dans les Réglages.
- **Juger les sons en conversation**, et verser ces fautes dans `PhonemeStats`.
- **Des tables de projection** (`PhonemeState`, `ErrorPattern`), si le calcul à la
  demande devient lent.

## Décisions (2026-11-14)

1. **Le taux de fautes d'un son** se calcule sur la première prise de chaque phrase,
   sur les 30 derniers jours, et seulement à partir de 6 fois le son.
2. **3 phrases sur 5 visent les sons les plus ratés**, 2 sont tirées comme
   aujourd'hui. La séance reste à 5 phrases, et pourra s'allonger si c'est court à
   l'usage.
3. **La séance dit quel son elle travaille**, en une ligne discrète.
4. **Le récapitulatif dit qu'une faute revient** (« déjà relevé dans 2
   conversations »). Retiré si c'est du bruit à l'usage.
5. **L'ordre des étapes reste 1, 2, 3.** La 3 a besoin de la 2 pour la faute à
   surveiller.
6. **On essaie le récapitulatif avec réflexion** (étape 4), sur des conversations
   gardées, avant de rien changer au serveur.
