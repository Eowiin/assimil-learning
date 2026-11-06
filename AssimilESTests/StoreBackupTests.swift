import Foundation
import SwiftData
import Testing
@testable import AssimilES

@Suite("Sauvegarde du stockage")
@MainActor
struct StoreBackupTests {

    @Test("La copie s'ouvre comme un stockage et contient les dernières écritures")
    func backupReopens() throws {
        let url = Fixture.storeURL()
        let container = try Fixture.container(at: url)
        let context = container.mainContext
        context.insert(DifficultSentence(lessonNumber: 12, sentenceNumber: 4, isExercise: false))
        context.insert(StudyDay(day: Fixture.calendar.startOfDay(for: Fixture.date(day: 8)), seconds: 420))

        // Le conteneur reste ouvert pendant la copie, comme dans l'app : les
        // écritures sont encore dans `-wal`, c'est ce que la copie doit emporter.
        let destination = url.deletingLastPathComponent().appendingPathComponent("export", isDirectory: true)
        let folder = try StoreBackup.make(from: context, into: destination, now: Fixture.date(day: 8, hour: 15, minute: 30))

        #expect(folder.lastPathComponent == "AssimilES-sauvegarde-2026-09-08-1530")
        let copied = folder.appendingPathComponent(url.lastPathComponent)
        let reopened = try Fixture.container(at: copied)
        let marks = try reopened.mainContext.fetch(FetchDescriptor<DifficultSentence>())
        #expect(marks.map(\.key) == ["L012-S04"])
        #expect(try reopened.mainContext.fetch(FetchDescriptor<StudyDay>()).first?.seconds == 420)
    }

    @Test("Deux exports dans la même minute : le second remplace le premier")
    func sameMinuteReplaces() throws {
        let url = Fixture.storeURL()
        let container = try Fixture.container(at: url)
        try container.mainContext.save()
        let destination = url.deletingLastPathComponent().appendingPathComponent("export", isDirectory: true)
        let now = Fixture.date(day: 8)

        let first = try StoreBackup.make(from: container.mainContext, into: destination, now: now)
        let second = try StoreBackup.make(from: container.mainContext, into: destination, now: now)
        #expect(first == second)
        #expect(FileManager.default.fileExists(atPath: second.appendingPathComponent(url.lastPathComponent).path))
    }

    @Test("Un stockage en mémoire n'a rien à exporter")
    func inMemoryRefused() throws {
        let container = try Fixture.container()
        #expect(throws: StoreBackup.BackupError.self) {
            try StoreBackup.make(from: container.mainContext, into: FileManager.default.temporaryDirectory)
        }
    }
}
