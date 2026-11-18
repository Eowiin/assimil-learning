import SwiftUI

/// Un défi du placement à la fois : la consigne, l'énoncé, la réponse au clavier. La
/// dictée du clavier iOS permet de répondre à l'oral. Rien n'est corrigé pendant le
/// test : le détail est au résultat.
struct ChallengeView: View {
    let session: ChallengeSession
    let onFinish: (String) -> Void

    @State private var answer = ""
    @FocusState private var focused: Bool

    private static let accents = ["á", "é", "í", "ó", "ú", "ñ", "¿"]

    var body: some View {
        Group {
            switch session.phase {
            case .answering:
                if let challenge = session.current { question(challenge) }
            case .judging:
                waiting
            case .failed(let reason):
                failure(reason)
            case .finished:
                waiting
            }
        }
        .onChange(of: session.phase, initial: true) {
            if case .finished(let working) = session.phase { onFinish(working) }
        }
    }

    private func question(_ challenge: PlacementChallenge) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Défi \(session.number) · niveau \(session.level)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("challenge-number")
                Text(challenge.instruction)
                    .font(.headline)
                Text(challenge.prompt)
                    .font(.system(.title2, design: .serif))
                    .accessibilityIdentifier("challenge-prompt")
                TextField(challenge.type == .complete ? "Ce qui manque" : "Ta réponse en espagnol",
                          text: $answer, axis: .vertical)
                    .font(.title3)
                    .lineLimit(1...5)
                    .textInputAutocapitalization(.sentences)
                    // La correction automatique du français réécrirait l'espagnol.
                    .autocorrectionDisabled()
                    .focused($focused)
                    .padding(12)
                    .background(StudyStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("challenge-answer")
                Button("Valider") { submit(answer) }
                    .buttonStyle(StudyPrimaryButtonStyle())
                    .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("challenge-submit")
                Button("Je ne sais pas") { submit("") }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("challenge-skip")
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        // Un nouveau défi repart d'une réponse vide, clavier ouvert.
        .id(session.number)
        .onAppear { focused = true }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                ForEach(Self.accents, id: \.self) { letter in
                    Button(letter) { answer += letter }
                        .accessibilityIdentifier("accent-\(letter)")
                }
            }
        }
    }

    private var waiting: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Le PC corrige tes réponses…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("challenge-judging")
    }

    private func failure(_ reason: String) -> some View {
        VStack(spacing: 12) {
            Text(reason)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
            Text("Tes réponses sont gardées : rien n'est perdu.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Réessayer", systemImage: "arrow.clockwise") {
                Task { await session.retry() }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("challenge-retry")
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func submit(_ text: String) {
        let sent = text
        answer = ""
        Task { await session.submit(sent) }
    }
}

/// Le résultat des défis : le niveau proposé, modifiable, et le détail. Rien n'est
/// écrit dans l'état tant qu'on ne valide pas.
struct PlacementResultView: View {
    let result: PlacementResult
    let pack: CurriculumPack
    let proposed: String
    let onValidate: (String) -> Void

    @State private var level: String
    @State private var showsDetail = false

    init(result: PlacementResult, pack: CurriculumPack, proposed: String, onValidate: @escaping (String) -> Void) {
        self.result = result
        self.pack = pack
        self.proposed = proposed
        self.onValidate = onValidate
        _level = State(initialValue: proposed)
    }

    private var records: [ChallengeRecord] { result.placementDetails.challenges }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Niveau \(proposed)")
                        .font(.largeTitle.weight(.bold))
                        .accessibilityIdentifier("placement-proposed")
                    Text("Le premier niveau dont tu n'as pas montré les trois quarts des objectifs.")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(ChallengeWalk.outcomes(records), id: \.level) { outcome in
                        Label(Self.line(outcome),
                              systemImage: outcome.passed ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(outcome.passed ? StudyStyle.accent : .secondary)
                    }
                    if let vocabulary = result.placementDetails.vocabulary {
                        Label("Vocabulaire : environ \(VocabularyTest.rounded(vocabulary.estimate).formatted()) mots "
                              + "(\(vocabulary.level))", systemImage: "character.book.closed")
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Picker("Niveau de travail", selection: $level) {
                        ForEach(CurriculumPack.levels, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("placement-level")
                    if let start = PlacementCompletion.previewStart(workingLevel: level, records: records, pack: pack) {
                        Text("Premier objectif : \(start.title)")
                            .font(.subheadline)
                    }
                    Text("Les objectifs des niveaux en dessous sont considérés comme acquis, sauf ceux que tu "
                         + "as ratés ici : ils reviendront dans les séances.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button(level == proposed ? "Valider le niveau \(level)" : "Valider le niveau \(level) à la place") {
                    onValidate(level)
                }
                .buttonStyle(StudyPrimaryButtonStyle())
                .accessibilityIdentifier("placement-validate")

                DisclosureGroup("Le détail des \(records.count) défis", isExpanded: $showsDetail) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(records.enumerated()), id: \.offset) { _, record in
                            detail(record)
                        }
                    }
                    .padding(.top, 8)
                }
                .accessibilityIdentifier("placement-detail")
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func detail(_ record: ChallengeRecord) -> some View {
        let challenge = pack.challenges.first { $0.id == record.challengeID }
        return VStack(alignment: .leading, spacing: 4) {
            Label(pack.objective(record.objectiveID)?.title ?? record.objectiveID,
                  systemImage: Self.symbol(record.verdict))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Self.color(record.verdict))
            if let challenge { Text(challenge.prompt).font(.footnote).foregroundStyle(.secondary) }
            Text(record.answer.isEmpty ? "Sans réponse" : "« \(record.answer) »")
                .font(.footnote)
            Text(record.analysis)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// « B1 : 3 objectifs montrés sur 4 », plus les réponses qui l'ont contourné.
    static func line(_ outcome: ChallengeWalk.LevelOutcome) -> String {
        var text = "\(outcome.level) : \(outcome.shown) montré\(outcome.shown > 1 ? "s" : "") "
            + "sur \(outcome.shown + outcome.wrong)"
        if outcome.notShown > 0 { text += ", \(outcome.notShown) contourné\(outcome.notShown > 1 ? "s" : "")" }
        return text
    }

    static func symbol(_ verdict: ChallengeVerdict) -> String {
        switch verdict {
        case .shown: "checkmark.circle.fill"
        case .correctNotShown: "arrow.uturn.right.circle"
        case .wrong: "xmark.circle"
        }
    }

    static func color(_ verdict: ChallengeVerdict) -> Color {
        switch verdict {
        case .shown: StudyStyle.accent
        case .correctNotShown: .orange
        case .wrong: .red
        }
    }
}
