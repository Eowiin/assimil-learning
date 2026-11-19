import SwiftUI
import SwiftData

/// Le bloc 3, « Conversation » : le jeu de rôle de l'objectif du jour. L'IA joue la
/// scène de l'objectif, au niveau de l'objectif, avec les mots connus et ceux du texte
/// du jour. Au récapitulatif, chaque emploi de l'objectif devient une preuve (une
/// réussite au plus par conversation) et les mots dits montent.
struct ConversationBlockContent: View {
    let session: StudySession
    let pack: CurriculumPack
    /// La conversation s'ouvre par-dessus le bloc : son temps n'est pas celui du bloc seul.
    let onOpen: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(ServerStatus.self) private var server
    /// Le réglage de la conversation ouverte ; nil quand elle est fermée.
    @State private var opened: ConversationSetup?

    private var objective: CurriculumPack.Objective? { session.objectiveID.flatMap(pack.objective) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let objective {
                VStack(alignment: .leading, spacing: 6) {
                    Text(objective.title)
                        .font(.title3.weight(.semibold))
                    Text(objective.rule)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .studySection()
            }
            Text("L'IA joue une scène où l'objectif vient tout seul. Parle autant que tu veux, "
                 + "puis touche Terminer : le récapitulatif dit où tu l'as employé.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if session.blocks.parts[SessionConversation.part] != nil {
                Label(tallyLine, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(StudyStyle.accent)
                    .accessibilityIdentifier("roleplay-tally")
            }
            // Fait, il se refait, mais « Bloc fait » redevient l'action principale.
            if done {
                Button("Refaire le jeu de rôle", systemImage: "bubble.left.and.bubble.right", action: open)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .disabled(unavailable != nil)
                    .accessibilityIdentifier("roleplay-start")
            } else {
                Button("Lancer le jeu de rôle", systemImage: "bubble.left.and.bubble.right", action: open)
                    .buttonStyle(StudyPrimaryButtonStyle())
                    .disabled(unavailable != nil)
                    .accessibilityIdentifier("roleplay-start")
            }
            if let unavailable {
                Text(unavailable)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationDestination(isPresented: Binding(get: { opened != nil }, set: { if !$0 { opened = nil } })) {
            if let opened, let service = server.conversation {
                ConversationView(service: service, setup: opened)
            }
        }
    }

    private var done: Bool { session.blocks.parts[SessionConversation.part] != nil }

    /// « 2 emplois réussis sur 3 », pour toute la séance.
    private var tallyLine: String {
        let tally = SessionConversation.tally(for: session, language: pack.language, in: context)
        switch tally.total {
        case 0: return "Fait · objectif pas encore employé"
        case 1: return tally.valid == 1 ? "Fait · objectif employé et réussi" : "Fait · objectif tenté, pas encore réussi"
        default: return "Fait · \(tally.valid) emploi\(tally.valid > 1 ? "s" : "") réussi\(tally.valid > 1 ? "s" : "") sur \(tally.total)"
        }
    }

    /// Pourquoi le jeu de rôle ne peut pas s'ouvrir, nil s'il le peut.
    private var unavailable: String? {
        if objective == nil { return "Pas d'objectif aujourd'hui : pas de jeu de rôle." }
        if server.conversation == nil { return "Le PC ne répond pas : passe ce bloc, ou reviens plus tard." }
        return nil
    }

    private func open() {
        guard let profile = SessionConversation.profile(for: session, pack: pack, in: context) else { return }
        let intro = "Jeu de rôle · \(objective?.title ?? "")"
            + (profile.words.isEmpty ? "" : " · mots du jour : " + profile.words.joined(separator: ", "))
        onOpen()
        opened = ConversationSetup(profile: profile, intro: intro, onReview: { review in
            try? SessionConversation.record(review, in: session, pack: pack, at: .now, in: context)
            try? context.save()
        })
    }
}
