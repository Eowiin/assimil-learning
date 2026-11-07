import SwiftUI

/// Les mots à la suite, qui reviennent à la ligne comme un texte. Ceux qui ne sont pas
/// passés en orange — ici comme dans les réponses dites aux exercices.
struct FlowText: View {
    let verdicts: [WordVerdict]

    var body: some View {
        // `Text` concaténés : le retour à la ligne reste celui d'un paragraphe,
        // là où une grille de vues couperait les mots n'importe où.
        verdicts.reduce(Text("")) { partial, verdict in
            partial + coloured(verdict) + Text(" ")
        }
        .font(.title3)
    }

    private func coloured(_ verdict: WordVerdict) -> Text {
        verdict.isUnderstood
            ? Text(verdict.word)
            : Text(verdict.word).foregroundColor(.orange)
    }
}
