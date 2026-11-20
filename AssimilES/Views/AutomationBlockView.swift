import SwiftUI
import SwiftData

/// Le bloc 4, « Automatisation » : cinq minutes de questions faciles en rafale sur un
/// thème familier, avec les mots déjà sus, puis un écrit de 80 à 120 mots, corrigé, qui rappelle l'objectif à réinjecter.
/// Chaque partie se coche quand son récapitulatif est arrivé.
struct AutomationBlockContent: View {
    let session: StudySession
    let pack: CurriculumPack
    /// Une partie s'ouvre par-dessus le bloc : son temps n'est pas celui du bloc seul.
    let onOpen: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(ServerStatus.self) private var server
    @State private var openedPart: AutomationPart?
    /// Le réglage de la rafale ouverte, fixé à l'ouverture.
    @State private var speedSetup: ConversationSetup?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(AutomationPart.allCases) { part in row(part) }
        }
        .navigationDestination(item: $openedPart) { part in destination(part) }
    }

    private func row(_ part: AutomationPart) -> some View {
        let state = availability(part)
        let done = session.blocks.parts[part.key] != nil
        return Button {
            open(part)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: done ? "checkmark.circle.fill" : part.symbol)
                    .font(.title2)
                    .foregroundStyle(StudyStyle.accent)
                    .frame(width: 44, height: 44)
                    .background(StudyStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text(part.title).font(.headline)
                    Text(state.detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if state.openable {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!state.openable)
        .accessibilityIdentifier("automation-\(part.rawValue)")
    }

    private func availability(_ part: AutomationPart) -> (detail: String, openable: Bool) {
        let done = session.blocks.parts[part.key] != nil
        switch part {
        case .speed:
            if server.conversation == nil { return ("Le PC ne répond pas : cette partie attendra", false) }
            if done { return ("Fait · tu peux recommencer", true) }
            let theme = SessionAutomation.familiarTheme(for: session, pack: pack, in: context)
            return ("5 minutes de questions faciles" + (theme.map { " · \($0.fr.lowercasedFirst)" } ?? "")
                    + ", avec les mots que tu connais : réponds vite", true)
        case .writing:
            if done { return ("Corrigé · relire la correction", true) }
            if server.writing == nil { return ("Le PC ne répond pas : cette partie attendra", false) }
            return (SessionAutomation.writingPrompt(for: session, pack: pack), true)
        }
    }

    private func open(_ part: AutomationPart) {
        if part == .speed {
            let profile = SessionAutomation.speedProfile(for: session, pack: pack, in: context)
            let theme = SessionAutomation.familiarTheme(for: session, pack: pack, in: context)
            let intro = "Questions en rafale" + (theme.map { " · \($0.fr.lowercasedFirst)" } ?? "")
                + " : rien de nouveau, réponds vite avec ce que tu sais déjà, sans chercher la phrase parfaite."
            speedSetup = ConversationSetup(profile: profile, intro: intro, targetSeconds: SessionAutomation.speedSeconds,
                                           title: AutomationPart.speed.title, topic: theme?.es,
                                           onReview: { review in
                try? SessionConversation.record(review, in: session, pack: pack, part: AutomationPart.speed.key,
                                                at: .now, in: context)
                try? context.save()
            })
        }
        onOpen()
        openedPart = part
    }

    @ViewBuilder
    private func destination(_ part: AutomationPart) -> some View {
        switch part {
        case .speed:
            if let speedSetup, let service = server.conversation {
                ConversationView(service: service, setup: speedSetup)
            }
        case .writing:
            WritingView(session: session, pack: pack, service: server.writing)
        }
    }
}

/// L'écrit du bloc 4 : la consigne, le texte et son compteur, puis la correction. Le
/// brouillon est gardé si l'on quitte l'écran ; un écrit envoyé est gardé même si la
/// correction échoue, et se renvoie.
struct WritingView: View {
    let session: StudySession
    let pack: CurriculumPack
    /// Nil sans PC : une correction déjà arrivée se relit quand même.
    let service: (any WritingService)?

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case editing
        case sending
        case failed(String)
        case reviewed(WritingReview)
    }

    @State private var text = ""
    @State private var phase: Phase = .editing
    @State private var record: WritingRecord?
    @State private var clock = BlockClock()
    @FocusState private var editorFocused: Bool

    private var objective: CurriculumPack.Objective? { SessionAutomation.writingObjective(for: session, pack: pack) }
    private var prompt: String { SessionAutomation.writingPrompt(for: session, pack: pack) }
    private var count: Int { SessionAutomation.wordCount(text) }
    private var draftKey: String { "writing-draft.\(session.key)" }

    var body: some View {
        Group {
            if case .reviewed(let review) = phase {
                ConversationRecapView(review: .done(review.corrections), objectiveUses: review.objectiveUses,
                                      correctedText: review.correctedText) {}
            } else {
                editor
            }
        }
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudyStyle.paper)
        .navigationTitle(isReviewed ? "Correction" : "Court écrit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            // Le clavier cache le bas de l'écran : le compteur reste en vue au-dessus.
            ToolbarItemGroup(placement: .keyboard) {
                Text("\(count) / \(SessionAutomation.writingWords.upperBound)")
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .fixedSize()
                    .foregroundStyle(countColor)
                Spacer()
                Button("OK") { editorFocused = false }
                    .accessibilityIdentifier("writing-keyboard-done")
            }
            ToolbarItem(placement: .confirmationAction) {
                if isReviewed {
                    Button("Fermer") { dismiss() }
                        .accessibilityIdentifier("writing-close")
                }
            }
        }
        .onAppear(perform: load)
        .onDisappear(perform: recordTime)
        .onChange(of: scenePhase) {
            if scenePhase == .active { clock.resume() } else { clock.pause() }
        }
        .onChange(of: text) { saveDraft() }
    }

    private var isReviewed: Bool {
        if case .reviewed = phase { return true }
        return false
    }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(prompt)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("writing-prompt")
                    if let objective {
                        Text(objective.rule)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .studySection()
                TextEditor(text: $text)
                    .focused($editorFocused)
                    .frame(minHeight: 220)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(StudyStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.sentences)
                    .disabled(phase == .sending)
                    .accessibilityIdentifier("writing-text")
                counter
                switch phase {
                case .sending:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("L'IA corrige ton texte…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                case .failed(let reason):
                    Text(reason)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                    send(label: "Réessayer")
                case .editing, .reviewed:
                    send(label: "Faire corriger")
                }
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// « 87 mots · vise 80 à 120 » ; au-delà, un avertissement, rien de bloqué.
    private var counter: some View {
        let range = SessionAutomation.writingWords
        let tooLong = count > range.upperBound
        return Text(tooLong ? "\(count) mots · un peu long, vise \(range.upperBound) au plus"
                            : "\(count) mot\(count > 1 ? "s" : "") · vise \(range.lowerBound) à \(range.upperBound)")
            .font(.footnote.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(countColor)
            .accessibilityIdentifier("writing-count")
    }

    /// Gris sous 80 mots, la couleur de l'app de 80 à 120, orange au-delà.
    private var countColor: Color {
        let range = SessionAutomation.writingWords
        return count > range.upperBound ? .orange : count >= range.lowerBound ? StudyStyle.accent : .secondary
    }

    private func send(label: String) -> some View {
        Button(label) { Task { await submit() } }
            .buttonStyle(StudyPrimaryButtonStyle())
            .disabled(count < SessionAutomation.writingWords.lowerBound || service == nil)
            .accessibilityIdentifier("writing-submit")
    }

    // MARK: - Les données

    private func load() {
        clock.resume()
        guard record == nil else { return }
        if let existing = SessionAutomation.writing(for: session, in: context) {
            record = existing
            text = existing.text
            if let review = existing.writingReview { phase = .reviewed(review) }
        } else {
            text = UserDefaults.standard.string(forKey: draftKey) ?? ""
        }
    }

    private func saveDraft() {
        guard record?.review == nil, phase != .sending else { return }
        UserDefaults.standard.set(text, forKey: draftKey)
    }

    /// L'écrit est gardé avant la correction : un échec ne le perd pas.
    private func submit() async {
        guard let service else { return }
        editorFocused = false
        let written = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved: WritingRecord
        if let record {
            record.text = written
            record.writtenAt = .now
            saved = record
        } else {
            saved = WritingRecord(writtenAt: .now, language: pack.language, objectiveID: objective?.id,
                                  prompt: prompt, text: written)
            context.insert(saved)
            record = saved
        }
        try? context.save()
        phase = .sending
        do {
            let review = try await service.review(text: written, level: objective?.level,
                                                  objective: objective.map(ConversationObjective.init))
            try SessionAutomation.recordWriting(review, on: saved, in: session, pack: pack, at: .now, in: context)
            try? context.save()
            UserDefaults.standard.removeObject(forKey: draftKey)
            withAnimation { phase = .reviewed(review) }
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func recordTime() {
        clock.pause()
        StudyTime.record(clock.take(), as: .adaptive, in: context)
        try? context.save()
    }
}
