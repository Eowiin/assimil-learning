import SwiftUI

/// Les deux mélodies superposées : celle du natif et la tienne, alignées dans le
/// temps et ramenées chacune à son propre registre.
///
/// C'est le vrai retour de cet écran. Un chiffre dit *combien* ça s'écarte, la
/// courbe dit *où* — la montée finale d'une question qu'on a aplatie se voit d'un
/// coup d'œil et ne se raconte pas en une phrase.
struct IntonationChart: View {
    let intonation: Intonation

    private var bounds: (low: Double, high: Double) {
        let values = intonation.nativeCurve + intonation.myCurve
        let low = values.min() ?? -6
        let high = values.max() ?? 6
        // Une marge, et une amplitude minimale : sur une phrase très plate, un
        // cadrage serré transformerait un souffle en montagne.
        let padded = max(3.0, (high - low) * 0.15)
        return (low - padded, high + padded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Canvas { context, size in
                let (low, high) = bounds
                let span = max(high - low, 0.001)

                func point(_ index: Int, _ value: Double, of count: Int) -> CGPoint {
                    let x = count <= 1 ? 0 : Double(index) / Double(count - 1)
                    let y = 1 - (value - low) / span
                    return CGPoint(x: x * size.width, y: y * size.height)
                }

                // La médiane du locuteur : le zéro de l'échelle, et la référence
                // visuelle à laquelle chaque montée se rapporte.
                let zero = 1 - (0 - low) / span
                var axis = Path()
                axis.move(to: CGPoint(x: 0, y: zero * size.height))
                axis.addLine(to: CGPoint(x: size.width, y: zero * size.height))
                context.stroke(axis, with: .color(.secondary.opacity(0.3)),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                func curve(_ values: [Double]) -> Path {
                    var path = Path()
                    for (index, value) in values.enumerated() {
                        let p = point(index, value, of: values.count)
                        index == 0 ? path.move(to: p) : path.addLine(to: p)
                    }
                    return path
                }

                context.stroke(curve(intonation.nativeCurve),
                               with: .color(.accentColor),
                               style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                context.stroke(curve(intonation.myCurve),
                               with: .color(.orange),
                               style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
            .frame(height: 120)
            .accessibilityLabel("Courbes d'intonation superposées")

            HStack(spacing: 16) {
                legend(color: .accentColor, label: "Le natif")
                legend(color: .orange, label: "Toi")
                Spacer()
                Text("demi-tons")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func legend(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 14, height: 2.5)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
