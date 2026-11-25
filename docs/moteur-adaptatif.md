# Le moteur adaptatif

**Validé le 2026-11-17.** Remplace le cadrage v3 (PR #80, parcours d'unités) : la
progression ne suit plus des leçons ni des unités, mais 125 micro-objectifs du CECRL
(A0 à C2), un lexique de fréquence et les sons faibles de l'apprenant. La séance est
un cycle d'un quart d'heure en 4 blocs, qu'on enchaîne autant qu'on a de temps (étape
5 ; jusque-là, une séance de 60 minutes par jour). La séance Assimil reste sur
l'accueil à côté, tant que la nouvelle n'a pas fait ses preuves.

## Décisions

1. **Hybride.** Ce qui doit être juste au mot près est écrit une fois et relu :
   les 125 micro-leçons (5 lignes au plus) et les 125 défis du placement. Seul le
   texte du bloc 2 est généré à la volée, encadré par un vérificateur spaCy.
2. **Le référentiel est un paquet**, `Resources/curriculum/es/`, lu par l'app
   (`CurriculumPack`). Le serveur reçoit de l'app ce dont il a besoin (le texte de
   l'objectif, les lemmes connus) : il n'en garde pas de copie.
3. **Le lexique est régénéré par script** (`server/scripts/build_lexicon.py`) :
   `es_core_news_lg` en contexte, filtre Hunspell, API castillane du serveur.
4. **L'état vit dans six tables nouvelles**, sans toucher aux anciennes. Les mots
   déjà travaillés dans Assimil y entrent une fois (`LexiconMigration`).
5. **L'objectif se juge au récapitulatif** (`/conversation/review`), pas après chaque
   tour : le serveur n'a qu'une carte graphique, et un appel de plus par tour
   allongerait chaque réponse.
6. **Le test de vocabulaire du placement se fait sur l'iPhone**, avec des non-mots
   (façon LexTALE) pour corriger la surestimation.
7. **Trois verdicts pour un défi** (2026-11-17) : objectif montré, correct mais
   objectif non montré (« debe de estar » au lieu du futur de probabilité ; on repose
   un défi, sans compter de lacune), faux. Le type du défi (`complete`, `translate`,
   `rewrite`) ne change rien au correcteur, à tous les niveaux.
8. **Le LLM et la voix passent derrière des protocoles** (`LLM` : Mistral depuis la
   décision 10 ; `TTS` : Voxtral, avec Pocket TTS en secours, depuis l'étape 5c ;
   XTTS v2 reste possible).
9. **Les jugements vont à Mistral** (2026-11-18), par `ASSIMIL_LLM_JUGE=mistral` :
   récapitulatif, écrit, puis placement. La conversation reste sur Qwen3, en local. À
   l'essai sur obj_031, Qwen3 8B corrigeait des phrases justes et jugeait l'objectif
   au hasard (tout validé, puis tout refusé, à température 0) ; Mistral presque sans
   faute, en 2 à 4 s.
10. **Tout passe par Mistral** (2026-11-18), conversation comprise ; Ollama et Qwen3 sont
    retirés, avec `ASSIMIL_LLM` et `ASSIMIL_LLM_JUGE`. Au placement (12 défis, 35
    réponses), Qwen3 8B en jugeait 28 justes en 21 s, Mistral 32 en 12 s ; il écrivait
    le texte du bloc 2 trop court (49 mots pour 150). La carte graphique ne porte plus
    que Whisper, XTTS et la prononciation. En échange, l'IA demande internet, et les
    phrases de l'apprenant partent chez Mistral.

## Le paquet `curriculum/es/`

| Fichier | Contenu | D'où il vient |
|---|---|---|
| `objectives.json` | 125 micro-objectifs : niveau, titre, règle, consigne pour l'IA, critère de validation | Fourni par Ethan, 5 tableaux fusionnés en un |
| `microlessons.json` | Par objectif : 2 à 5 lignes en français, 3 exemples | Écrit par Claude, relu par Ethan |
| `placement_challenges.json` | Un défi par objectif : `complete`, `translate` ou `rewrite`, réponses qui montrent l'objectif (`expected`), réponses justes qui le contournent (`also_correct`), critère | Écrit par Claude, relu par Ethan |
| `lexicon.json` | 5 000 lemmes : rang, catégorie, API castillane, niveau estimé d'après le rang | `build_lexicon.py` |
| `pseudowords.json` | 80 non-mots plausibles | `build_lexicon.py` |
| `phonemes.json` | 28 sons et règles de prosodie, priorité pour un francophone | Fourni par Ethan |
| `themes.json` | Une trentaine de thèmes du quotidien pour le texte du bloc 2, en espagnol et en français | Écrit par Claude, relu par Ethan |
| `placement_sounds.json` | 6 phrases lues à froid au placement, pour les sons d'un francophone | Écrit par Claude, relu par Ethan |

## L'état de l'apprenant (SwiftData)

| Entité | Rôle |
|---|---|
| `ObjectiveProgress` | Un objectif : `locked`, `active`, `acquired`, `to_reinject` ; réussites spontanées. Acquis à 3 ; déblocage souple après 2 jours actif |
| `ObjectiveEvidence` | Journal jamais modifié : une production jugée (conversation, écrit, placement) |
| `LexemeState` | Un lemme : `seen`, `recognized`, `active`. Le statut ne fait que monter |
| `PlacementResult` | Un passage du placement : vocabulaire estimé, niveau, objectif de départ, détail en JSON ; `completedAt` nil tant qu'il n'est pas validé (on reprend où on s'était arrêté) |
| `StudySession` | Un cycle de la séance (plusieurs par jour depuis l'étape 5a, `cycle`) : objectif, thème, avancement des 4 blocs, texte du bloc 2 gardé |
| `WritingRecord` | Un écrit du bloc 4 et sa correction |

Les clés sont préfixées par la langue (« es:obj_014 », « es:hablar »). Les cartes FSRS
restent dans `Card`. La sauvegarde copie le fichier SQLite : elle emporte ces tables
d'office.

Un mot devient **reconnu** quand sa carte `recognize` est connue (ou que le placement
l'a dit) ; **actif** quand sa carte `recall` est connue, ou qu'il a été produit en
conversation ou à l'écrit deux jours différents.

## Les contrats du serveur (API 2)

| Route | Entrée | Sortie |
|---|---|---|
| `POST /placement/evaluate` | `level`, `items[{objective_id, instruction, prompt, expected, also_correct, check, answer}]` (`instruction` optionnel) | `[{objective_id, verdict, analyse_courte}]`, `verdict` : `shown`, `correct_not_shown`, `wrong` |
| `POST /session/generate-input` | `level`, `theme`, `objective`, `known_lemmas[]`, `new_lemmas[6-8]`, `target_words` | `text`, `sentences[{es, fr}]`, `coverage`, `unknown_lemmas[]`, `new_used[]`, `objective_hits[]` (places des phrases, ou null), `attempts`, `new_occurrences[{lemma, sentence, form}]` (étape 4c) |
| `POST /tts` | `sentences[]` (40 au plus) | `audios[{text, audio}]` : un m4a par phrase, en base64 ; `seconds` |
| `POST /conversation/start`, `/turn` | `profile` étendu : `level`, `objective`, `mode` (`roleplay`, `speed`), `allowed_lemmas[]`, `hints` (5b) ; `/turn` : `closing` (5b), `ask` (6b) ; `history[]` : `ask` par message (6b) | + `coverage`, `attempts` (null sans `allowed_lemmas`), `hints[{es, fr}]` (null sans demande) |
| `POST /conversation/review` | + `objective` | + `objective_uses[{said, valide, analyse_courte}]`, `lemmas_produced[]`, `searched[{fr, es, lemma}]` (6b ; null au-delà de l'A1 sans demande) |
| `POST /writing/review` | `text`, `level`, `objective` | `corrections[]` (catégorie `orthographe` en plus), `corrected_text`, `objective_uses[]`, `lemmas_produced[]` |

Tout champ nouveau est optionnel. Le serveur annonce l'API 2 depuis l'étape 3b, avec
l'app qui juge les défis : l'app exige l'égalité, et une app plus ancienne voit le
serveur hors ligne. `objective_uses` est null sans `objective` ; `lemmas_produced`
est null si spaCy n'est pas chargé.

Couverture du bloc 2 : 95 % de mots connus visés, nouvelle formulation par le LLM
sous 92 %. Les noms propres et les nombres ne comptent pas. Les mots nouveaux du jour
comptent comme connus. Les phrases de l'objectif (`objective_hits`) sont repérées par
le juge sur le texte gardé, avec le critère de l'objectif (null s'il ne répond pas) :
l'IA qui écrit les marquait mal.

Au placement, une réponse vide ou identique au paquet (casse et ponctuation mises à
part, accents gardés) est jugée sans l'IA. Les autres vont au juge par paquets de 10 ;
un défi oublié est rejugé seul, puis la route répond 503 plutôt que d'inventer un
verdict.

## Étapes

1. **Le paquet et les modèles** — fait (cette PR) : le référentiel, le script du
   lexique, les six entités, la reprise du vocabulaire Assimil, la relecture d'Ethan
   (110 objectifs OK d'emblée, 15 corrigés).
2. **Le serveur** : les protocoles `LLM` et `TTS`, spaCy, les routes ci-dessus.
3. **Le placement** : vocabulaire sur l'iPhone, défis jugés par le serveur, conversation
   de calibrage et sons. Plan validé le 2026-11-18, une PR par sous-étape :
   - **3a, le vocabulaire** (`VocabularyTest`, `PlacementView`) : le lexique coupé en
     10 tranches de 500 rangs ; 6 mots pleins (noms, verbes, adjectifs, adverbes) et
     2 non-mots par tranche, environ 80 questions. Les mots outils comptent comme
     connus. Part connue d'une tranche : (oui aux mots − oui aux non-mots) / (1 − oui
     aux non-mots). Arrêt après deux tranches de suite sous 20 %. Le niveau est celui
     du lemme dont le rang vaut l'estimation (A0 sous 150). Au-delà de 30 % de oui aux
     non-mots, l'écran prévient. Le résultat ouvre un passage non validé.
   - **3b, les défis** (`ChallengeWalk`, `ChallengeSession`, `PlacementCompletion`) : 4 défis par niveau (3 en A0), envoyés ensemble ; niveau
     réussi à 3 « montré » sur 4 ; un `correct_not_shown` fait poser le défi d'un
     autre objectif du même niveau, 2 fois au plus. On monte tant que ça passe, on
     descend si le premier niveau échoue. Écran du résultat, niveau modifiable. À la
     validation : les niveaux réussis `acquired` (défis faux : `to_reinject`), le
     premier objectif non montré du niveau de travail `active`, les mots testés « oui »
     reconnus. Le vocabulaire connu reste une frontière de rang (`lexiconEstimate`),
     pas des milliers de lignes `LexemeState` : un statut ne descend jamais, une
     frontière se déplace au test suivant. API 2.
   - **3c, la conversation de calibrage** (`CalibrationOutcome`, `ConversationCalibration`) :
     5 réponses, l'IA au niveau des défis, avec l'objectif de départ et les lemmes connus
     (frontière + mots reconnus, `KnownVocabulary`). Sur 3 phrases au moins, plus de la
     moitié corrigées propose un cran plus bas ; Ethan tranche. Les lemmes produits
     comptent tout de suite (reconnus, actifs au deuxième jour de production) ; l'objectif
     jugé est gardé dans le passage, sans preuve (une seule tentative ne dit rien).
     Passable, et sautée sans le module conversation.
   - **3d, les sons** (`SoundCheck`, `placement_sounds.json`) : 6 phrases lues à froid,
     une fois chacune, sans natif ni correction (θ, jota, r, v, chacun dans 3 phrases au
     moins), jugées par `/pronunciation`. Chaque prise est gardée en `PronunciationRecord`
     (leçon 0) : elle nourrit `PhonemeStats` comme les autres. Le bilan (sons faibles,
     même seuil que le profil : 6 occurrences) est montré au résultat ; il ne change pas
     le niveau. Passable, et sauté sans le module prononciation.
4. **La séance du jour** : les 4 blocs, branchés sur l'accueil à côté de la séance
   Assimil. Plan validé le 2026-11-18, une PR par sous-étape :
   - **4a, le squelette** (`DailyPlanner`, `AdaptiveSessionView`) : la séance d'un jour
     est créée au premier passage sur l'accueil, une fois le placement validé.
     L'objectif est l'actif ; deux jours actif sans être acquis, il passe « à
     réinjecter » et le suivant s'ouvre. L'objectif à rappeler au bloc 4 est celui des
     « à réinjecter » revu le moins récemment. Les 7 mots nouveaux sont les premiers mots
     pleins au-delà de la frontière, inconnus de l'état. Le thème tourne dans
     `themes.json` (une trentaine, `es` pour le serveur, `fr` affiché). Ordre fixe des
     blocs, chacun passable ; séance faite quand les quatre sont faits ou passés. Le
     temps de chaque bloc s'affiche (15 min visées), sans chronomètre qui coupe.
   - **4b, Chirurgie** (`SurgeryBlockContent`, `MicroLessonView`) : trois parties à
     ouvrir, cochées quand elles sont finies (depuis la 4d) : les révisions quand la file
     du jour est vide (ou qu'il n'y a rien à revoir), les sons à la dernière phrase jugée,
     la micro-leçon quand on la referme. Les révisions reprennent celles du vocabulaire (les mots
     du lexique les rejoignent en 4c) ; la micro-leçon de l'objectif (lignes, exemples à
     traduction cachée) ; la séance de prononciation centrée sur les sons faibles. Le
     temps du bloc compte les écrans ouverts ; le temps d'étude, lui, n'est pas compté
     deux fois.
   - **4c, Absorption** (`Absorption`, `AbsorptionPreparer`, `AbsorptionBlockContent`) :
     le texte du jour (170 mots visés) et sa voix, préparés en tâche de fond dès l'écran
     de la séance, pendant le bloc 1. Le texte est gardé dans `StudySession.inputData`,
     la voix sur le disque (`absorption/<séance>/NN.m4a`, demandée par paquets de 5 ;
     seule la séance du jour garde la sienne). Lecteur phrase par phrase : écoute,
     traduction à la demande, phrases de l'objectif marquées, mots nouveaux en gras. Les
     mots employés passent « vus » et gardent leur première phrase sur `LexemeState`
     (`contextES`, `contextForm`, `contextFR`, donnés par `new_occurrences`) ; un mot que
     l'IA n'a pas employé reste inconnu, et revient. Chacun devient une carte
     `recognize` du paquet `lexique-es`, dans la même file que les révisions (avant les
     nouvelles d'Assimil, sous le même plafond de 20) : recto la phrase, le mot en gras ;
     verso la traduction de la phrase. Une carte connue fait monter son mot
     (`recognize` : reconnu ; `recall` : actif), pour Assimil comme pour le lexique.
   - **4d, Conversation** (`SessionConversation`, `ConversationBlockContent`,
     `ConversationSetup`) : le jeu de rôle de l'objectif (`mode = roleplay`), au niveau de
     l'objectif, sans faute à surveiller. `allowed_lemmas` : les lemmes connus, plus les
     mots que le texte du bloc 2 a employés (`new_used`), qui vont aussi en `words`. Au
     récapitulatif, chaque `objective_uses` devient une preuve (source `conversation`),
     mais **une production ne compte qu'une réussite au plus** (2026-11-19) : une
     conversation, ou un écrit, n'acquiert pas un objectif seul ; il faut le réemployer à
     l'écrit ou un autre jour. Les `lemmas_produced` montent (`KnownVocabulary`). La partie
     se coche quand le récapitulatif est arrivé ; le bloc montre les emplois du jour et
     se refait. `ConversationSetup` sert aussi au calibrage du placement.
   - **4e, Automatisation** (`SessionAutomation`, `AutomationBlockContent`, `WritingView`,
     `WritingClient`) : deux parties, cochées quand leur correction est arrivée.
     - **La rafale** : automatiser ce qui est su, pas apprendre (réalignée le
       2026-11-20, elle ressemblait trop au jeu de rôle). `mode = speed` sans objectif ni
       `words` ; `allowed_lemmas` : les seuls mots connus, sans ceux du jour ; le niveau
       de l'objectif du jour. Le sujet (`topic`) est un thème familier : celui de la
       séance d'avant la plus récente qui diffère du jour, sinon celui du jour. Le
       serveur, en `speed` sans objectif, pose des questions faciles pour la fluidité.
       Cinq minutes visées par un décompte, sans couper. Pas de preuve d'objectif : les
       lemmes produits montent seuls.
     - **L'écrit** : la consigne est composée sur l'iPhone (le thème du jour, l'objectif
       entre guillemets). L'objectif rappelé et jugé est celui à réinjecter s'il y en a
       un, sinon celui du jour (2026-11-19) : c'est le seul moment où un objectif « à
       réinjecter » gagne une preuve. « Faire corriger » à 80 mots, avertissement
       au-delà de 120. Brouillon gardé ; l'écrit est gardé (`WritingRecord`) avant la
       correction, qui se relance après un échec. Preuves `writing`, une réussite au
       plus ; la catégorie `orthographe` est lue, et un accent changé ressort à l'écrit
       (`WordDiff`, `accents: true`). Les fautes de l'écrit nourrissent `ErrorPatterns`
       (2026-11-20, `docs/module-profil.md`, étape 2) : un écrit compte comme une
       conversation, son récapitulatif dit les fautes qui reviennent, et la consigne
       ajoute « Attention aux accents écrits » quand l'orthographe revient dans deux
       productions ou plus.

5. **Le cycle court** (2026-11-23) : la séance de 60 minutes devient un cycle d'un quart
   d'heure, à enchaîner selon le temps qu'on a (une personne qui a une heure en fait
   trois ou quatre d'affilée). Trois PR : 5a les cycles et les volumes, 5b les débutants
   (amorces de phrases en A0-A1, longueur de l'écrit selon le niveau), 5c la voix et les
   indicateurs (frontière lexicale, réflexe de la rafale).
   - **5a, les cycles** (`DailyPlanner.newCycle`, `StudySession.cycle`). Refaire trois
     fois de suite le même objectif avec les mêmes mots n'apprendrait presque rien :
     **chaque cycle a son objectif**.
     - Le **cycle 1** est celui d'avant : il fait avancer le parcours (objectif actif,
       déblocage souple), tire les 7 mots nouveaux du jour et rappelle l'objectif à
       réinjecter à l'écrit. Il est créé au premier passage sur l'accueil ; sa clé ne
       change pas (« es:2026-11-23 »).
     - Les **cycles 2 et suivants** se lancent depuis l'accueil (« Lancer un nouveau
       cycle »), une fois le précédent fait ou passé (clé « es:2026-11-23#2 »). Ils ne
       font jamais avancer le parcours : sinon une heure d'affilée ouvrirait trois
       objectifs en un jour. Leur objectif est repris : un « à réinjecter » d'abord,
       sinon un acquis à entretenir, chaque fois celui dont la dernière preuve est la
       plus ancienne et qui n'a pas déjà été travaillé aujourd'hui (le tour recommence
       quand tout y est passé). Ses preuves comptent pleinement : on le travaille un
       autre jour que celui où il était actif. Pas de mots nouveaux : le texte et le jeu
       de rôle reprennent ceux du jour. Le thème suivant, pour un texte neuf. L'écrit
       juge l'objectif du cycle (pas de rappel en plus).
     - Volumes : texte du bloc 2 à 95 mots (80 à 110) ; 10 cartes au plus par cycle au
       bloc 1 (celles en apprentissage qui reviennent, puis les dues, puis les
       nouvelles ; la partie se coche à la dernière, ou quand rien n'est à revoir ; la
       révision ouverte depuis l'accueil reste sans plafond) ; les sons faibles au
       premier cycle seulement ; rafale de 3 minutes ; 5 minutes affichées par bloc.
     - L'écrit et le bilan de conversation d'un cycle se lisent depuis son début
       (`startedAt`), plus depuis minuit. La rafale prend le thème du cycle d'avant
       (celui du même jour compte).
   - **5b, les débutants** (`LearnerLevel`, amorces, fin de scène), 2026-11-24. Le
     crosstalk (répondre en français en A0) est reporté : Whisper ne garde qu'une
     langue par prise, et un passage en français serait traduit ou écorché sans
     prévenir, puis jugé comme une production. À reprendre avec un essai sur des prises
     mélangées (Whisper `multilingual`, Voxtral, Azure ou Deepgram), ou un bouton « Je
     ne sais pas le dire » qui envoie une prise en français imposé.
     - **Le niveau de l'apprenant** (`LearnerLevel`) : celui de l'objectif actif, sinon
       celui du placement. Le texte du bloc 2, le jeu de rôle, la rafale, l'écrit et sa
       correction se règlent sur lui, pas sur l'objectif repris d'un cycle 2 : un
       apprenant B1 qui revoit un point A1 ne redevient pas débutant.
     - **Les amorces** (A0, A1) : le profil porte `hints` ; après chaque réplique, un
       second appel à l'IA (`structurer`, la scène en deux répliques) propose trois
       débuts de réponse de 2 à 5 mots, finis par « … », avec leur traduction. Il tourne
       pendant que la voix se fait ; s'il échoue, la réplique arrive sans amorces. Elles
       s'affichent au-dessus du micro tant que c'est à l'apprenant ; on répond toujours
       à la voix. La voix de l'IA est jouée à 0,85 (hauteur gardée), au bloc 3 et à la
       rafale.
     - **La fin de scène** (tous niveaux) : le jeu de rôle se tait après 6 réponses ; la
       sixième part avec `closing`, et l'IA conclut en son rôle, sans question. Le
       calibrage du placement garde sa limite sans conclusion.
     - **L'écrit** : 15 à 30 mots en A0-A1, 50 à 80 au-delà (80 à 120 avant).
   - **5c, la voix et les indicateurs** (2026-11-24), en trois PR.
     - **5c-1, la voix légère** (`VoxtralTTS`, `PocketTTS`, `TTSAvecSecours`,
       `VoiceCache`). La voix par défaut est **Voxtral**, celle de Mistral, par son API
       (Elena, `voice_483`) : une prosodie castillane naturelle, et des mots seuls
       entiers. Elle parle vite pour un apprenant : le serveur la ralentit à 0,9, hauteur
       gardée (`ASSIMIL_VOXTRAL_VITESSE`). **Pocket TTS** (Kyutai, Lola, le modèle
       standard, préféré au 24 couches à l'essai) prend le relais en local quand Mistral
       échoue, tarde (10 s) ou que le PC est hors ligne ; Voxtral est alors laissé de
       côté une minute, pour que chaque phrase n'attende pas le délai. Pocket tourne sur
       le processeur, six fois plus vite que le temps réel sur le Mac ; il est connu pour
       couper les phrases très courtes. `ASSIMIL_TTS=pocket` le force seul, `xtts` rend
       la voix d'avant. Phonon (Gradium) est écarté : sa licence (CC BY-NC) interdirait
       de sortir l'app. Comparaison à l'oreille : `essais/voix.py`.
     - **La voix du bloc 1** : la phrase d'une carte du lexique (au recto) et les trois
       exemples de la micro-leçon ont un haut-parleur. Leur voix est gardée pour
       toujours (`Application Support/voix/<version>/`, un .m4a nommé d'après la
       phrase) : une phrase n'est demandée qu'une fois, ce qui rend la voix en ligne
       presque gratuite. Changer de voix ou de vitesse sur le serveur demande de changer
       `VoiceCache.version` : le cache d'avant part au lancement suivant.
       Elle se prépare en tâche de fond dès l'écran du cycle, par paquets de 5 (les
       exemples de la micro-leçon d'abord, puis les phrases du lexique, la plus récente
       d'abord) ; une phrase pas encore prête est demandée seule à l'appui. Chaque
       phrase du texte du bloc 2 y est aussi copiée quand sa voix arrive : la carte d'un
       mot du texte a sa voix sans rien redemander, même après que la séance a effacé
       son dossier.
     - **5c-2, la frontière lexicale** (`LexicalFrontier`) : sur l'accueil, sous la
       séance adaptative, une fois le placement validé, « 1 240 mots sur 5 000 », une
       barre, et « Environ 84 % de l'espagnol courant ». Les mots connus sont ceux de
       `KnownVocabulary` (la frontière du placement, plus les mots reconnus ou actifs),
       limités au lexique. La couverture est la somme de leurs occurrences dans les
       sous-titres (`count`), rapportée à tous les mots du corpus (`total_count` de
       `lexicon.json`, 413 millions : les 50 000 formes de FrequencyWords, noms propres
       et formes écartées compris). Rapportée aux seuls 5 000 lemmes, les connaître tous
       ferait 100 % ; c'est en fait 92 %. Repères : 500 lemmes couvrent 79 %, 1 000
       en couvrent 84 %, 2 000 en couvrent 89 %. Arrondi à l'unité inférieure.
     - **5c-3, le réflexe de la rafale** (`ReflexMeter`, `VoiceOnsetDetector`) : en
       rafale seulement, l'app mesure le temps entre la fin de la réplique de l'IA (ou
       l'appui sur le micro qui la coupe) et l'arrivée de la voix dans la prise. C'est la
       voix qui compte, pas l'appui : toucher vite puis chercher ses mots n'est pas un
       réflexe. Le micro relève son niveau toutes les 50 ms ; les 150 premières ms après
       l'appui sont ignorées, et il faut deux relevés de suite au-dessus de −35 dB. Une
       réponse commencée en moins de 4,5 s est un réflexe : au-dessus du micro, « Réflexe
       ×3 · 2,1 s » à partir de deux d'affilée, et une réponse lente remet la série à
       zéro. Une prise annulée n'arrête pas le temps ; une prise où la voix n'est pas
       repérée ne compte ni pour ni contre. Le récapitulatif dit la moyenne (« tu prends
       la parole en 3,2 s ») et la meilleure série. Les temps sont gardés dans le
       `ConversationRecord` de la rafale (`reactionTimes`), pour suivre le réflexe d'un
       jour à l'autre ; rien ne les affiche encore.
6. **Le crosstalk** (2026-11-25) : répondre en français en A0-A1 sans que la prise
   soit jugée comme de l'espagnol.
   - **6a, l'essai** (`essais/crosstalk.py`, 20 prises d'Ethan : 6 en espagnol, 3 en
     français, 11 mélangées). Résultats du 2026-11-25 :

     | | espagnol | bascules | ajouts | français gardé | temps |
     |---|---|---|---|---|---|
     | `es` (le serveur) | 98,9 % | 0 | 3 | 4/14 | 0,18 s |
     | `multi` | 90,1 % | 0 | 2 | 8/14 | 0,29 s |
     | `amorce` | 98,9 % | 0 | 0 | 11/14 | 0,27 s |
     | `double` | 98,9 % | 0 | 4 | 8/14 | 0,94 s |
     | `voxtral` | 92,3 % | 0 | 1 | 12/14 | 0,35 s |

     Aucun ne passe la règle (80 % du français gardé, 2 points d'espagnol perdus au
     plus, pas plus d'ajouts que `es`). `amorce` la manque d'une prise. Constats :
     - l'espagnol imposé **traduit le français en silence** (« ¿Cómo se dice
       reservar? », « No he entendido la pregunta ») : le récapitulatif le compte
       comme une production. `amorce` ne le fait jamais ;
     - le mot français seul dans une phrase espagnole n'est rendu par aucun Whisper
       (« furchette », « brillante » pour « bruyante », vrai mot espagnol) ;
     - `double` (Whisper en espagnol et en français imposés, l'IA reconstitue) échoue :
       chaque passe traduit l'autre langue au lieu de la déformer, et l'IA ne peut plus
       savoir ce qui a été dit. En parallèle, les deux passes ne gagnent rien : elles se
       partagent la carte graphique ;
     - Voxtral garde le mieux le français mais met de l'espagnol en français, ou
       invente (« А то. ») ; Deepgram et Azure n'ont pas été essayés ;
     - la langue que Whisper donne pour la prise ne vaut rien (« fr » pour des prises
       mélangées, « ko » une fois) ;
     - un .m4a indexé à la fin (le Dictaphone) ne se décodait pas par un tube : le
       serveur passe désormais par un fichier temporaire (`decoder_16k`).
   - **Décision (6b, 6c)** : en A0-A1, le serveur transcrit avec l'amorce bilingue ;
     le français est repéré par l'IA, au récapitulatif ; un bouton « Je ne sais pas le
     dire » couvre le mot qui manque. À retirer s'il ne sert pas.
   - **6b, le serveur** (`Ecoute`, `langue_d_ecoute`, `MotCherche`) :
     - **L'écoute** : `es` (l'espagnol imposé) à partir de l'A2 et sans profil ;
       `bilingue` en A0-A1 (la langue détectée par morceau, `AMORCE_BILINGUE`) ; `fr`
       pour une demande (`ask`). Le filet : une transcription bilingue qui a des lettres
       d'un autre alphabet que le latin est refaite en espagnol imposé.
     - **Le jeu de rôle** : la consigne dit, à tous les niveaux, de donner l'espagnol
       d'un passage dit en français, dans la conversation. Une demande part avec une
       note à elle (`DEMANDE`) : donner le mot dans son rôle, inviter à dire la phrase,
       sans autre question ; ni la note du tour ni la fin de scène (`closing` est
       ignoré). Le message garde `ask` dans l'historique de l'app ; l'IA le lit comme
       « en francés, porque no sabe decirlo », sans le marqueur, que l'API refuse.
     - **Le récapitulatif** : en A0-A1, ou dès qu'une demande a été faite, la consigne
       dit qu'un passage en français n'est pas une faute, et l'IA rend `searched`
       (`fr`, `es`, `lemma` ; sans hésitation, sans doublon de lemme). Les demandes et
       les passages de `searched` sont retirés avant `lemmas_produced`. Au-delà de
       l'A1 sans demande, rien ne change. Pas d'appel de plus.
     - **Essayé et écarté** : couper la prise sur ses pauses (0,3 s) pour une langue
       par morceau. Whisper ne détecte la langue qu'une fois par fenêtre de 30 s, d'où
       une prise « adaptée » à une seule langue en conversation. Mais sur les 20 prises,
       autant de français gardé (11/14), moins d'espagnol (96,7 %), et des inventions
       sur les morceaux courts.
