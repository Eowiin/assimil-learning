import SwiftUI

/// Le deuxième exercice : compléter la phrase espagnole à partir du français.
///
/// Chaque trou montre autant de points que la réponse du livre a de caractères,
/// comme sur la page. On vérifie quand on veut ; un trou refusé reste modifiable,
/// et la correction ne s'affiche que sur demande.
struct FillInExerciseView<Footer: View>: View {
    let exercise: FillInExercise?
    let content: ActivityContent
    @Binding var progress: DailyProgress
    /// Le bouton de fin d'étape. La barre d'accents prend sa place pendant la saisie.
    @ViewBuilder let footer: () -> Footer

    /// Ce qui est tapé et pas encore vérifié. Seules les vérifications sont
    /// sauvegardées : ce sont elles qui font avancer l'exercice.
    @State private var drafts: [Int: [String]] = [:]
    @FocusState private var focus: BlankFocus?

    struct BlankFocus: Hashable {
        let item: Int
        let blank: Int
    }

    /// Sans ¿ ni ¡ : la ponctuation est imprimée autour des trous et n'est pas notée.
    private static var accents: [String] { ["á", "é", "í", "ó", "ú", "ü", "ñ"] }

    /// Hauteur de la barre d'accents qui flotte au-dessus du clavier. Le défilement
    /// automatique ne connaît que le clavier : sans cette marge, la vérification de
    /// la phrase en cours passait sous la barre.
    @ScaledMetric private var accentBarClearance: CGFloat = 72

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Exercice 2 · Complétez").font(.title3.weight(.bold))
                            if let instruction = exercise?.instruction {
                                Text(instruction).font(.subheadline)
                            }
                            Text("Chaque point représente une lettre ou un caractère. Les accents comptent ; "
                                 + "la ponctuation, déjà imprimée, et les majuscules ne sont pas notées.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }

                        if let notice = content.notice {
                            BookNotice(text: notice)
                        }

                        if let exercise {
                            ForEach(exercise.items) { item in
                                card(item)
                                    .id(item.n)
                            }
                        }

                        if content.needsBook {
                            BookConfirmation(stage: .completion,
                                             label: "J'ai fait cet exercice dans le livre",
                                             progress: $progress)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 600, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .contentMargins(.bottom, focus == nil ? 0 : accentBarClearance, for: .scrollContent)
                .onChange(of: focus) {
                    // La phrase entière, vérification comprise, au-dessus de la barre.
                    guard let item = focus?.item else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(item, anchor: .bottom)
                    }
                }
            }

            // La barre d'accents flotte au-dessus du clavier, à la hauteur du bouton
            // d'étape : il s'efface le temps de la saisie.
            if focus == nil {
                footer()
            }
        }
        .toolbar {
            // Chaque touche de cette barre occupe ~52 pt, même regroupée avec les autres
            // dans un seul élément : neuf lettres et « OK » sortaient de l'écran de
            // l'iPhone 11, et sept lettres plus « OK » débordaient encore. Restent les
            // sept lettres ; « OK » est la touche Retour, au dernier trou de la phrase.
            ToolbarItemGroup(placement: .keyboard) {
                ForEach(Self.accents, id: \.self) { letter in
                    Button(letter) { insert(letter) }
                        .accessibilityIdentifier("accent-\(letter)")
                }
            }
        }
    }

    // MARK: - Une phrase

    private func card(_ item: FillInItem) -> some View {
        let attempt = progress.fillIn(item.n)
        let typed = current(item)
        let verdicts = attempt.checks > 0 ? FillInGrader.grade(attempt.typed, item: item) : []

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(item.n)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .trailing)
                Text(item.fr ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if attempt.solved {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(StudyStyle.accent)
                        .accessibilityLabel("Réussie")
                } else if attempt.revealed {
                    Image(systemName: "eye.circle").foregroundStyle(.orange)
                        .accessibilityLabel("Correction consultée")
                }
            }

            FlowLayout(spacing: 5, lineSpacing: 10) {
                ForEach(tokens(item)) { token in
                    switch token.kind {
                    case .word(let word):
                        Text(word).font(.title3)
                            .layoutValue(key: AttachedToPrevious.self, value: token.attached)
                    case .blank(let blank):
                        field(item, blank, verdict: shownVerdict(blank, verdicts: verdicts, attempt: attempt, typed: typed),
                              locked: attempt.solved)
                            .layoutValue(key: AttachedToPrevious.self, value: token.attached)
                    }
                }
            }
            .padding(.leading, 28)

            feedback(item, attempt: attempt, verdicts: verdicts)
                .padding(.leading, 28)

            if !attempt.solved {
                HStack(spacing: 10) {
                    Button {
                        var updated = attempt
                        updated.check(current(item), item: item)
                        progress.setFillIn(item.n, updated)
                        drafts[item.n] = nil
                        focus = nil
                    } label: {
                        Text("Vérifier").frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(typed.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                    .accessibilityIdentifier("check-\(item.n)")

                    if !attempt.revealed {
                        Button {
                            var updated = attempt
                            updated.revealed = true
                            progress.setFillIn(item.n, updated)
                        } label: {
                            Text("Voir la correction").frame(maxWidth: .infinity, minHeight: 34)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("reveal-fill-\(item.n)")
                    }
                }
                .padding(.leading, 28)
            }
        }
        .padding(16)
        .background(StudyStyle.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private func field(_ item: FillInItem, _ blank: FillInBlank, verdict: BlankVerdict?, locked: Bool) -> some View {
        let dots = String(repeating: "·", count: max(1, blank.expected.count))
        let width = CGFloat(max(3, blank.expected.count)) * 12 + 18
        return TextField(dots, text: binding(item, blank.index))
            .font(.title3)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focus, equals: BlankFocus(item: item.n, blank: blank.index))
            .submitLabel(blank.index + 1 < item.blanks.count ? .next : .done)
            .onSubmit { focusNext(after: item, blank: blank) }
            .disabled(locked)
            .frame(width: width)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 7).fill(color(for: verdict).opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(color(for: verdict), lineWidth: 1))
            .accessibilityLabel("Phrase \(item.n), trou \(blank.index + 1)")
            .accessibilityValue(verdict.map(Self.spoken) ?? "")
            .accessibilityIdentifier("blank-\(item.n)-\(blank.index)")
    }

    @ViewBuilder
    private func feedback(_ item: FillInItem, attempt: FillInAttempt, verdicts: [BlankVerdict]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if attempt.checks > 0, !attempt.solved {
                let accepted = verdicts.filter(\.isAccepted).count
                Text("\(accepted) trou\(accepted > 1 ? "s" : "") sur \(verdicts.count) juste\(accepted > 1 ? "s" : "") "
                     + "— corrige les autres et vérifie à nouveau.")
                    .font(.subheadline)
            }
            ForEach(Array(verdicts.enumerated()), id: \.offset) { index, verdict in
                switch verdict {
                case .accentMismatch:
                    Label("Trou \(index + 1) : presque — vérifie les accents.", systemImage: "character.cursor.ibeam")
                        .font(.caption).foregroundStyle(.orange)
                case .acceptedIgnoringCase(let expected):
                    Label("Trou \(index + 1) : juste — le livre écrit « \(expected) ».", systemImage: "textformat")
                        .font(.caption).foregroundStyle(.secondary)
                default:
                    EmptyView()
                }
            }
            if attempt.revealed || attempt.solved {
                solution(item)
            }
        }
    }

    /// La phrase complète, les mots du corrigé en évidence.
    private func solution(_ item: FillInItem) -> some View {
        item.segments.reduce(Text("")) { text, segment in
            switch segment {
            case .text(let part): text + Text(part)
            case .blank(let blank): text + Text(blank.expected).bold().foregroundColor(StudyStyle.accent)
            }
        }
        .font(.body)
        .accessibilityLabel("Correction : \(item.solution)")
    }

    // MARK: - État

    private func current(_ item: FillInItem) -> [String] {
        let base = drafts[item.n] ?? progress.fillIn(item.n).typed
        let count = item.blanks.count
        return Array((base + Array(repeating: "", count: max(0, count - base.count))).prefix(count))
    }

    private func binding(_ item: FillInItem, _ index: Int) -> Binding<String> {
        Binding(get: { current(item)[index] },
                set: { value in
                    var values = current(item)
                    values[index] = value
                    drafts[item.n] = values
                })
    }

    /// Un verdict ne colore un trou que tant qu'on n'a pas retouché ce qui a été vérifié.
    private func shownVerdict(_ blank: FillInBlank, verdicts: [BlankVerdict],
                              attempt: FillInAttempt, typed: [String]) -> BlankVerdict? {
        guard verdicts.indices.contains(blank.index),
              attempt.typed.indices.contains(blank.index),
              attempt.typed[blank.index] == typed[blank.index]
        else { return nil }
        return verdicts[blank.index]
    }

    private func color(for verdict: BlankVerdict?) -> Color {
        switch verdict {
        case .correct, .acceptedIgnoringCase: StudyStyle.accent
        case .accentMismatch: .orange
        case .incorrect: .red
        case .empty, nil: .secondary.opacity(0.5)
        }
    }

    private static func spoken(_ verdict: BlankVerdict) -> String {
        switch verdict {
        case .correct, .acceptedIgnoringCase: "juste"
        case .accentMismatch: "accent à vérifier"
        case .incorrect: "à corriger"
        case .empty: "vide"
        }
    }

    private func insert(_ letter: String) {
        guard let focus, let item = exercise?.items.first(where: { $0.n == focus.item }) else { return }
        var values = current(item)
        guard values.indices.contains(focus.blank) else { return }
        values[focus.blank] += letter
        drafts[item.n] = values
    }

    private func focusNext(after item: FillInItem, blank: FillInBlank) {
        if blank.index + 1 < item.blanks.count {
            focus = BlankFocus(item: item.n, blank: blank.index + 1)
        } else {
            focus = nil
        }
    }

    // MARK: - Mise en ligne

    private struct Token: Identifiable {
        enum Kind { case word(String), blank(FillInBlank) }
        let id: Int
        let kind: Kind
        /// Collé au précédent, sans espace : « ¿Cómo [estás]? » ne doit pas afficher
        /// un point d'interrogation détaché.
        let attached: Bool
    }

    private func tokens(_ item: FillInItem) -> [Token] {
        var tokens: [Token] = []
        var pendingAttach = false
        for segment in item.segments {
            switch segment {
            case .text(let text):
                let startsWithSpace = text.first?.isWhitespace ?? true
                let words = text.split(whereSeparator: \.isWhitespace)
                for (index, word) in words.enumerated() {
                    let attached = index == 0 && !startsWithSpace && !tokens.isEmpty
                    tokens.append(Token(id: tokens.count, kind: .word(String(word)), attached: attached))
                }
                pendingAttach = !(text.last?.isWhitespace ?? true)
            case .blank(let blank):
                tokens.append(Token(id: tokens.count, kind: .blank(blank), attached: pendingAttach && !tokens.isEmpty))
                pendingAttach = true
            }
        }
        return tokens
    }
}

struct AttachedToPrevious: LayoutValueKey {
    static let defaultValue = false
}

/// Des vues à la suite, qui passent à la ligne comme un texte.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = proposal.width ?? rows.map(\.width).max() ?? 0
        return CGSize(width: width.isFinite ? width : (rows.map(\.width).max() ?? 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.x,
                                y: bounds.minY + row.y + (row.height - item.size.height) / 2),
                    proposal: ProposedViewSize(item.size))
            }
        }
    }

    private struct Row {
        var items: [(index: Int, x: CGFloat, size: CGSize)] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let gap = row.items.isEmpty || subview[AttachedToPrevious.self] ? 0 : spacing
            if !row.items.isEmpty, row.width + gap + size.width > width {
                let y = row.y + row.height + lineSpacing
                rows.append(row)
                row = Row(items: [(index, 0, size)], y: y, width: size.width, height: size.height)
            } else {
                row.items.append((index, row.width + gap, size))
                row.width += gap + size.width
                row.height = max(row.height, size.height)
            }
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
