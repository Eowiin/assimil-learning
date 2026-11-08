"""Valeurs de référence de FSRS pour AssimilESTests/FSRSTests.swift.

Joue des scénarios de notes dans py-fsrs (l'implémentation officielle) et imprime,
pour chaque revue, l'état attendu sous forme de lignes Swift à coller dans les tests.

    python3 -m venv /tmp/fsrs && /tmp/fsrs/bin/pip install fsrs==6.3.2
    /tmp/fsrs/bin/python -I tools/vocabulaire/fsrs-reference.py

Mêmes réglages que l'app (`FSRS.Parameters.standard`) : paramètres par défaut,
étapes 1 et 10 minutes, réapprentissage 10 minutes, sans fuzz.
"""

from datetime import datetime, timedelta, timezone

from fsrs import Card, Rating, Scheduler

START = datetime(2026, 1, 1, 9, 0, tzinfo=timezone.utc)

# (nom, [(note, délai depuis la revue précédente)]). Le délai de la première revue
# compte depuis la création de la carte.
SCENARIOS = [
    ("toutBien", [(3, 0), (3, 60), (3, 86400 * 3), (3, 86400 * 8), (3, 86400 * 21)]),
    ("facileDEmblee", [(4, 0), (4, 86400 * 8), (4, 86400 * 30)]),
    ("oubliPuisReapprentissage", [(3, 0), (3, 600), (3, 86400 * 2), (1, 86400 * 5),
                                  (3, 600), (3, 86400), (2, 86400 * 3)]),
    ("difficileEnApprentissage", [(2, 0), (2, 300), (3, 600), (3, 600), (1, 86400 * 2), (1, 300), (4, 120)]),
    ("enRetard", [(3, 0), (3, 600), (3, 86400 * 40), (2, 86400 * 90)]),
    ("memeJourEnRevision", [(4, 0), (3, 3600), (1, 3600), (3, 600)]),
]

STATE = {1: ".learning", 2: ".review", 3: ".relearning"}

scheduler = Scheduler(enable_fuzzing=False)
for name, reviews in SCENARIOS:
    card = Card(due=START)
    now = START
    print(f'    // {name}')
    print(f'    ("{name}", [')
    for rating, delay in reviews:
        now = now + timedelta(seconds=delay)
        card, _ = scheduler.review_card(card, Rating(rating), review_datetime=now)
        step = "nil" if card.step is None else str(card.step)
        print(f"        Expected(rating: {rating}, after: {delay}, state: {STATE[card.state.value]}, step: {step}, "
              f"stability: {card.stability!r}, difficulty: {card.difficulty!r}, "
              f"dueIn: {(card.due - now).total_seconds()!r}),")
    print("    ]),")
