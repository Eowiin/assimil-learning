import Foundation
import SwiftData

/// Une prise jugée par le serveur, gardée sur l'iPhone pour le profil d'apprenant
/// (décision 2 du plan de la prononciation). Chaque tentative a sa ligne : on verra
/// ainsi si une faute se corrige au second essai.
@Model
final class PronunciationRecord {
    #Index<PronunciationRecord>([\.judgedAt])

    var judgedAt: Date = Date.now
    var language: String = "es"
    /// D'où vient la phrase : la leçon d'Assimil et son numéro de phrase.
    var lesson: Int = 0
    var sentence: Int = 0
    var text: String = ""
    /// 1 pour la première prise de la phrase dans la séance, 2 pour la suivante…
    var attempt: Int = 1
    /// Les sons fautifs, par symbole (`r`, `θ`…), pour compter sans tout décoder.
    var faultSymbols: [String] = []
    /// Le jugement complet, en JSON, dans la forme où il arrive du serveur.
    var judgement: Data = Data()

    init(judgedAt: Date, sentence: DrillSentence, attempt: Int, result: PronunciationResult) {
        self.judgedAt = judgedAt
        self.lesson = sentence.lesson
        self.sentence = sentence.n
        self.text = sentence.text
        self.attempt = attempt
        self.faultSymbols = result.words.flatMap(\.phonemes).filter(\.fault).map(\.expected)
        self.judgement = (try? JSONEncoder().encode(result)) ?? Data()
    }

    var result: PronunciationResult? {
        try? JSONDecoder().decode(PronunciationResult.self, from: judgement)
    }
}
