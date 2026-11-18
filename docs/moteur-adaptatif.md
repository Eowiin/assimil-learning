# Le moteur adaptatif

**Validé le 2026-11-17.** Remplace le cadrage v3 (PR #80, parcours d'unités) : la
progression ne suit plus des leçons ni des unités, mais 125 micro-objectifs du CECRL
(A0 à C2), un lexique de fréquence et les sons faibles de l'apprenant. La séance du
jour dure 60 minutes, en 4 blocs de 15. La séance Assimil reste sur l'accueil à côté,
tant que la nouvelle n'a pas fait ses preuves.

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
8. **Le LLM et la voix passent derrière des protocoles** (`LLM` : Ollama ou Mistral,
   choisi par `ASSIMIL_LLM` ; `TTS` : XTTS v2 isolé, prêt pour une voix en ligne).
9. **Les jugements vont à Mistral** (2026-11-18), par `ASSIMIL_LLM_JUGE=mistral` :
   récapitulatif, écrit, puis placement. La conversation reste sur Qwen3, en local. À
   l'essai sur obj_031, Qwen3 8B corrigeait des phrases justes et jugeait l'objectif
   au hasard (tout validé, puis tout refusé, à température 0) ; Mistral presque sans
   faute, en 2 à 4 s.

## Le paquet `curriculum/es/`

| Fichier | Contenu | D'où il vient |
|---|---|---|
| `objectives.json` | 125 micro-objectifs : niveau, titre, règle, consigne pour l'IA, critère de validation | Fourni par Ethan, 5 tableaux fusionnés en un |
| `microlessons.json` | Par objectif : 2 à 5 lignes en français, 3 exemples | Écrit par Claude, relu par Ethan |
| `placement_challenges.json` | Un défi par objectif : `complete`, `translate` ou `rewrite`, réponses qui montrent l'objectif (`expected`), réponses justes qui le contournent (`also_correct`), critère | Écrit par Claude, relu par Ethan |
| `lexicon.json` | 5 000 lemmes : rang, catégorie, API castillane, niveau estimé d'après le rang | `build_lexicon.py` |
| `pseudowords.json` | 80 non-mots plausibles | `build_lexicon.py` |
| `phonemes.json` | 28 sons et règles de prosodie, priorité pour un francophone | Fourni par Ethan |

## L'état de l'apprenant (SwiftData)

| Entité | Rôle |
|---|---|
| `ObjectiveProgress` | Un objectif : `locked`, `active`, `acquired`, `to_reinject` ; réussites spontanées. Acquis à 3 ; déblocage souple après 2 jours actif |
| `ObjectiveEvidence` | Journal jamais modifié : une production jugée (conversation, écrit, placement) |
| `LexemeState` | Un lemme : `seen`, `recognized`, `active`. Le statut ne fait que monter |
| `PlacementResult` | Un passage du placement : vocabulaire estimé, niveau, objectif de départ, détail en JSON |
| `StudySession` | La séance d'un jour : objectif, thème, avancement des 4 blocs, texte du bloc 2 gardé |
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
| `POST /session/generate-input` | `level`, `theme`, `objective`, `known_lemmas[]`, `new_lemmas[6-8]`, `target_words` | `text`, `sentences[{es, fr}]`, `coverage`, `unknown_lemmas[]`, `new_used[]`, `objective_hits[]` (places des phrases), `attempts` |
| `POST /tts` | `sentences[]` (40 au plus) | `audios[{text, audio}]` : un m4a par phrase, en base64 ; `seconds` |
| `POST /conversation/start`, `/turn` | `profile` étendu : `level`, `objective`, `mode` (`roleplay`, `speed`), `allowed_lemmas[]` | + `coverage`, `attempts` (null sans `allowed_lemmas`) |
| `POST /conversation/review` | + `objective` | + `objective_uses[{said, valide, analyse_courte}]`, `lemmas_produced[]` |
| `POST /writing/review` | `text`, `level`, `objective` | `corrections[]` (catégorie `orthographe` en plus), `corrected_text`, `objective_uses[]`, `lemmas_produced[]` |

Tout champ nouveau est optionnel : l'app d'avant le moteur continue de marcher. Le
serveur annonce encore l'API 1, parce que l'app exige l'égalité : il passera à 2 avec
l'app qui la connaît. `objective_uses` est null sans `objective` ; `lemmas_produced`
est null si spaCy n'est pas chargé.

Couverture du bloc 2 : 95 % de mots connus visés, nouvelle formulation par le LLM
sous 92 %. Les noms propres et les nombres ne comptent pas. Les mots nouveaux du jour
comptent comme connus. Les phrases de l'objectif (`objective_hits`) sont celles que
l'IA marque en écrivant : rien ne les juge.

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
   de calibrage et sons.
4. **La séance du jour** : les 4 blocs, branchés sur l'accueil à côté de la séance
   Assimil.
