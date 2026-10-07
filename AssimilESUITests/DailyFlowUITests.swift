import XCTest

/// Les parcours principaux, dans le simulateur, sur des textes fictifs et un
/// stockage isolé (voir `AppEnvironment`). Chaque étape laisse une capture.
final class DailyFlowUITests: XCTestCase {

    private let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/text", isDirectory: true)

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(store: URL, lesson: Int, dayOffset: Int = 0) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ASSIMIL_STORE"] = store.path
        app.launchEnvironment["ASSIMIL_TEXT_DIR"] = fixtures.path
        app.launchEnvironment["ASSIMIL_DAY_OFFSET"] = String(dayOffset)
        app.launchArguments += ["-currentLesson", String(lesson)]
        app.launch()
        return app
    }

    private func newStore() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("assimil-ui-\(UUID().uuidString).store")
    }

    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "absent : \(element)", file: file, line: line)
        // Une ligne rognée en bas de la liste passe pour « touchable » alors que son
        // centre est sous le bouton d'étape, ou sous la barre d'accents qui flotte
        // au-dessus du clavier pendant la saisie : l'appui irait à cette barre.
        let app = XCUIApplication()
        let bottomBars = [app.buttons["stage-footer"], app.buttons["accent-á"]]
        func covered() -> Bool {
            guard element.identifier != "stage-footer", !element.identifier.hasPrefix("accent-"),
                  let bar = bottomBars.first(where: \.exists)
            else { return false }
            return element.frame.maxY > bar.frame.minY - 60
        }
        var swipes = 0
        while !element.isHittable || covered(), swipes < 6 {
            XCUIApplication().swipeUp(velocity: .slow)
            swipes += 1
        }
        // Un appui pendant la décélération d'un défilement ne fait que l'arrêter :
        // on laisse la liste se poser avant d'appuyer.
        if swipes > 0 { Thread.sleep(forTimeInterval: 1) }
        element.tap()
    }

    private func waitEnabled(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let enabled = NSPredicate(format: "isEnabled == true")
        let expectation = XCTNSPredicateExpectation(predicate: enabled, object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 5), .completed,
                       "toujours désactivé : \(element)", file: file, line: line)
    }

    func testOrdinarySessionThenTomorrow() throws {
        let store = newStore()
        var app = launch(store: store, lesson: 1)
        snapshot(app, "01-accueil")

        tap(app.buttons["start-session"])
        XCTAssertTrue(app.buttons["stage-action"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Frase de prueba uno."].exists)
        snapshot(app, "02-decouverte")

        // Sortir et revenir : rien n'est validé, la séance est à reprendre.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["start-session"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["today-done"].exists)
        XCTAssertTrue(app.buttons["start-session"].label.contains("Reprendre"))
        tap(app.buttons["start-session"])

        tap(app.buttons["stage-action"])
        XCTAssertTrue(app.staticTexts["Note fictive pour la phrase un."].waitForExistence(timeout: 5))
        snapshot(app, "03-comprehension")

        // Fermeture de l'app à l'étape Répétition, puis reprise.
        tap(app.buttons["stage-footer"])
        XCTAssertTrue(app.buttons["stage-action"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["stage-action"].label, "Passer aux exercices")
        snapshot(app, "04-repetition")
        app.terminate()

        app = launch(store: store, lesson: 1)
        XCTAssertTrue(app.buttons["start-session"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["start-session"].label.lowercased().contains("répétition"))
        tap(app.buttons["start-session"])
        tap(app.buttons["stage-action"])

        // Exercice 1 : chercher, afficher le corrigé, s'évaluer.
        XCTAssertTrue(app.staticTexts["Ejercicio ficticio uno."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["stage-footer"].isEnabled)
        tap(app.buttons["reveal-1"])
        XCTAssertTrue(app.staticTexts["Exercice fictif un."].waitForExistence(timeout: 3))
        snapshot(app, "05-traduction-corrige")
        for n in 1...5 {
            if n > 1 { tap(app.buttons["reveal-\(n)"]) }
            tap(app.buttons["assess-knew-\(n)"])
        }
        waitEnabled(app.buttons["stage-footer"])
        tap(app.buttons["stage-footer"])

        // Exercice 2 : une erreur d'accent, la correction, puis la réussite.
        let blank = app.textFields["blank-2-0"]
        tap(blank)
        blank.typeText("estas")
        // Le trou en cours et la vérification de sa phrase restent au-dessus de la
        // barre d'accents, sans avoir à fermer le clavier (#2).
        XCTAssertTrue(app.buttons["accent-á"].waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 1)
        let accentBarTop = app.buttons["accent-á"].frame.minY
        XCTAssertLessThanOrEqual(blank.frame.maxY, accentBarTop, "trou sous la barre d'accents")
        XCTAssertLessThanOrEqual(app.buttons["check-2"].frame.maxY, accentBarTop, "« Vérifier » sous la barre d'accents")
        snapshot(app, "06a-completer-saisie")
        tap(app.textFields["blank-2-1"])
        app.textFields["blank-2-1"].typeText("aca")
        tap(app.buttons["check-2"])
        XCTAssertTrue(app.staticTexts["Trou 1 : presque — vérifie les accents."].waitForExistence(timeout: 3))
        snapshot(app, "06-completer-erreur")

        tap(blank)
        blank.buttons["Clear text"].tapIfExists()
        blank.clearAndType("est")
        // Pendant la saisie, la barre d'accents tient entière dans l'écran et le bouton
        // d'étape s'efface ; une touche écrit dans le trou sans fermer le clavier.
        XCTAssertTrue(app.buttons["accent-á"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["stage-footer"].exists)
        let screen = app.windows.firstMatch.frame
        for id in ["á", "é", "í", "ó", "ú", "ü", "ñ"].map({ "accent-\($0)" }) {
            let key = app.buttons[id]
            XCTAssertTrue(key.isHittable && screen.contains(key.frame), "\(id) hors écran")
        }
        app.buttons["accent-á"].tap()
        blank.typeText("s")
        snapshot(app, "06b-completer-accents")
        let second = app.textFields["blank-2-1"]
        second.clearAndType("acá")
        tap(app.buttons["check-2"])
        // Une erreur, puis la correction : le verdict d'avant disparaît (#3).
        let first = app.textFields["blank-1-0"]
        tap(first)
        first.typeText("soi\n")
        tap(app.buttons["check-1"])
        let stale = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'vérifie à nouveau'"))
        XCTAssertTrue(stale.firstMatch.waitForExistence(timeout: 3))
        tap(app.buttons["reveal-fill-1"])
        XCTAssertFalse(stale.firstMatch.waitForExistence(timeout: 1), "verdict d'avant toujours affiché")
        snapshot(app, "07-completer-corrige")
        // Le bouton de la dernière activité valide la séance et ramène à l'accueil (#11).
        waitEnabled(app.buttons["stage-footer"])
        XCTAssertEqual(app.buttons["stage-footer"].label, "Valider la séance")
        tap(app.buttons["stage-footer"])

        XCTAssertTrue(app.staticTexts["today-done"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["tomorrow"].label.hasPrefix("Demain : leçon 2"))
        XCTAssertFalse(app.buttons["start-session"].exists)
        snapshot(app, "09-accueil-termine")

        // Relance le même jour : toujours terminée, aucune nouvelle leçon.
        app.terminate()
        app = launch(store: store, lesson: 1)
        XCTAssertTrue(app.staticTexts["today-done"].waitForExistence(timeout: 5))

        // Le lendemain : la leçon 2 est proposée.
        app.terminate()
        app = launch(store: store, lesson: 1, dayOffset: 1)
        XCTAssertTrue(app.buttons["start-session"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Leçon 2 · 7 phrases"].exists || app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Leçon 2'")).firstMatch.exists)
        snapshot(app, "10-lendemain")
    }

    func testMarkSurvivesAbruptQuit() throws {
        // Une phrase marquée est enregistrée tout de suite : un arrêt brutal juste
        // après ne la perd pas (#4).
        let store = newStore()
        var app = launch(store: store, lesson: 1)
        app.tabBars.buttons["Leçons"].tap()
        tap(app.staticTexts["Lección ficticia"])
        // Le titre ouvre la leçon et ne se marque pas : on passe à la phrase 1.
        tap(app.buttons["Phrase suivante"])
        app.buttons["play-pause"].tap()
        waitEnabled(app.buttons["Marquer à revoir"])
        tap(app.buttons["Marquer à revoir"])
        XCTAssertTrue(app.buttons["Retirer des phrases à revoir"].waitForExistence(timeout: 3))
        app.terminate()

        app = launch(store: store, lesson: 1)
        app.tabBars.buttons["Réviser"].tap()
        XCTAssertTrue(app.staticTexts["Frase de prueba uno."].waitForExistence(timeout: 5),
                      "la phrase marquée a été perdue")
        snapshot(app, "16-drapeau-apres-relance")
    }

    func testWeeklyReviewWithoutExercises() throws {
        let app = launch(store: newStore(), lesson: 7)
        XCTAssertTrue(app.buttons["start-session"].waitForExistence(timeout: 5))
        // Trois étapes, sans les deux exercices.
        XCTAssertEqual(app.otherElements["stage-progress"].value as? String, "Étape 1 sur 3 · Découverte")
        snapshot(app, "11-revision-accueil")

        tap(app.buttons["start-session"])
        tap(app.buttons["stage-action"])
        // Texte non fourni pour la leçon 7 : la synthèse et le texte renvoient au livre.
        XCTAssertTrue(app.otherElements["book-notice"].waitForExistence(timeout: 5)
                      || app.staticTexts["book-notice"].exists)
        snapshot(app, "12-revision-comprehension")
        tap(app.buttons["stage-footer"])
        XCTAssertEqual(app.buttons["stage-action"].label, "Valider la séance")
        tap(app.buttons["stage-action"])
        XCTAssertTrue(app.staticTexts["today-done"].waitForExistence(timeout: 5))
        snapshot(app, "13-revision-validee")
    }

    func testMissingExercisesDoneInBook() throws {
        // Leçon 3 : pas de texte fictif, donc exercice 1 partiel et exercice 2 non importé.
        let app = launch(store: newStore(), lesson: 3)
        tap(app.buttons["start-session"])
        tap(app.buttons["stage-action"])
        tap(app.buttons["stage-footer"])
        tap(app.buttons["stage-action"])

        XCTAssertTrue(app.buttons["done-in-book"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["stage-footer"].isEnabled)
        snapshot(app, "14-exercice1-manquant")
        tap(app.buttons["done-in-book"])
        tap(app.buttons["stage-footer"])

        XCTAssertTrue(app.buttons["done-in-book"].waitForExistence(timeout: 5))
        snapshot(app, "15-exercice2-non-importe")
        tap(app.buttons["done-in-book"])
        tap(app.buttons["stage-footer"])
        XCTAssertTrue(app.staticTexts["today-done"].waitForExistence(timeout: 5))
    }
}

/// Vérification sur les **vrais** textes embarqués, qui ne sont pas versionnés : ignorée
/// par défaut. `TEST_RUNNER_ASSIMIL_REAL_TEXT=1 xcodebuild test …` pour la lancer.
final class RealTextUITests: XCTestCase {

    func testLessonOneExerciseTwoOnRealText() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ASSIMIL_REAL_TEXT"] == "1",
                          "textes réels non demandés")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ASSIMIL_STORE"] = FileManager.default.temporaryDirectory
            .appendingPathComponent("assimil-real-\(UUID().uuidString).store").path
        app.launchArguments += ["-currentLesson", "1"]
        app.launch()

        func tap(_ element: XCUIElement) {
            XCTAssertTrue(element.waitForExistence(timeout: 5), "absent : \(element)")
            let footer = app.buttons["stage-footer"]
            var swipes = 0
            while !element.isHittable
                    || (element.identifier != "stage-footer" && footer.exists
                        && element.frame.maxY > footer.frame.minY - 60),
                  swipes < 6 {
                app.swipeUp(velocity: .slow)
                swipes += 1
            }
            if swipes > 0 { Thread.sleep(forTimeInterval: 1) }
            element.tap()
        }

        tap(app.buttons["start-session"])
        tap(app.buttons["stage-action"])
        tap(app.buttons["stage-footer"])
        tap(app.buttons["stage-action"])
        for n in 1...5 {
            tap(app.buttons["reveal-\(n)"])
            tap(app.buttons["assess-knew-\(n)"])
        }
        tap(app.buttons["stage-footer"])

        XCTAssertTrue(app.textFields["blank-1-0"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["book-notice"].exists)
        let first = XCTAttachment(screenshot: app.screenshot())
        first.name = "reel-exercice2"
        first.lifetime = .keepAlways
        add(first)

        tap(app.buttons["reveal-fill-2"])
        let revealed = XCTAttachment(screenshot: app.screenshot())
        revealed.name = "reel-exercice2-correction"
        revealed.lifetime = .keepAlways
        add(revealed)
    }
}

private extension XCUIElement {
    func tapIfExists() {
        if exists { tap() }
    }

    func clearAndType(_ text: String) {
        tap()
        if let current = value as? String, !current.isEmpty, current != placeholderValue {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        typeText(text)
    }
}
