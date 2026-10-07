import SwiftUI
import UIKit

/// Un même vocabulaire de couleurs et de commandes dans tous les parcours.
///
/// Deux bleus, deux rôles : `accent` pour le texte et les icônes, éclairci en
/// sombre pour rester lisible sur le noir ; `button` pour les fonds des actions,
/// sous un libellé blanc, assez soutenu dans les deux modes (≥ 5:1). Un fond
/// d'action teinté par `accent` tombait à 2,3:1 en sombre.
enum StudyStyle {
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.53, green: 0.64, blue: 1, alpha: 1)
            : UIColor(red: 0.20, green: 0.31, blue: 0.83, alpha: 1)
    })
    static let ink = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .white
            : UIColor(red: 0.10, green: 0.13, blue: 0.22, alpha: 1)
    })
    static let paper = Color(uiColor: .systemBackground)
    static let surface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.12, green: 0.14, blue: 0.20, alpha: 1)
            : UIColor(red: 0.95, green: 0.96, blue: 0.99, alpha: 1)
    })
    static let yellow = Color(red: 1, green: 0.80, blue: 0.28)
    static let button = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.25, green: 0.37, blue: 0.92, alpha: 1)
            : UIColor(red: 0.20, green: 0.31, blue: 0.83, alpha: 1)
    })
    /// Le fond de la phrase en cours. À 5 % d'accent, il disparaissait en sombre.
    static let highlight = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.53, green: 0.64, blue: 1, alpha: 0.16)
            : UIColor(red: 0.20, green: 0.31, blue: 0.83, alpha: 0.07)
    })
}

struct StudyPrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(StudyStyle.button, in: RoundedRectangle(cornerRadius: 16))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Le numéro du volume est le repère commun entre séance et bibliothèque.
struct LessonCover: View {
    let number: Int
    var size: CGFloat = 64

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 10).fill(StudyStyle.yellow)
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.black.opacity(0.06), lineWidth: 1)
            Rectangle().fill(.black.opacity(0.08)).frame(width: 2).padding(.leading, 7)
            VStack(alignment: .leading, spacing: 0) {
                Text("ES").font(.system(size: size * 0.14, weight: .heavy))
                Spacer(minLength: 2)
                Text(number.formatted(.number.precision(.integerLength(2))))
                    .font(.system(size: size * 0.37, weight: .bold, design: .rounded))
                Rectangle().frame(height: 2).opacity(0.35)
            }
            .padding(.vertical, size * 0.15)
            .padding(.leading, size * 0.24)
            .padding(.trailing, size * 0.14)
            .foregroundStyle(Color(red: 0.24, green: 0.20, blue: 0.12))
        }
        .frame(width: size, height: size * 1.2)
        .accessibilityHidden(true)
    }
}

extension View {
    func studySection() -> some View {
        self.padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StudyStyle.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    func studyListBackground() -> some View {
        self.scrollContentBackground(.hidden)
            .background(StudyStyle.paper)
    }
}
