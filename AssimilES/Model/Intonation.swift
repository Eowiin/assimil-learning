import Foundation

/// La comparaison de deux intonations sur la même phrase.
///
/// **Ce que ça compare, et ce que ça ne compare pas.** Deux courbes de hauteur,
/// chacune ramenée au registre de son locuteur, alignées dans le temps par
/// déformation dynamique (DTW). L'écart rendu est donc une différence de *forme
/// mélodique*, en demi-tons — pas un jugement sur l'accent, que rien ici ne mesure.
///
/// L'alignement temporel est ce qui rend la mesure honnête : sans lui, dire la
/// phrase un peu plus lentement suffirait à tout faire diverger, alors que la
/// mélodie serait la même. Le tempo est mesuré à part, où il veut dire quelque
/// chose.
///
/// **Ce que la mesure discrimine, vérifié sur le corpus.** Le même clip ralenti à
/// 0,8× ou transposé de 3 demi-tons sort à 0,11 demi-ton d'écart médian ; deux
/// phrases différentes sortent à 0,55. Au p90 du premier groupe (0,22), 98 % des
/// paires de phrases différentes sont au-dessus. La mesure sépare donc bien « la
/// même mélodie autrement dite » de « une autre mélodie ».
///
/// **Ce qui reste à calibrer, et qu'aucun corpus ne donne.** Une phrase dite par
/// Ethan tombe entre les deux, et savoir *où* demanderait ses propres
/// enregistrements. Les seuils ci-dessous placent donc les bornes sur ce qui est
/// mesuré, pas sur ce qu'on voudrait qu'elles disent.
struct Intonation {

    /// Écart **médian** en demi-tons le long de l'alignement. Médian et non moyen :
    /// une seule trame où la détection double la fréquence (l'erreur d'octave
    /// classique) fausserait une moyenne, pas une médiane.
    let gapSemitones: Double
    /// Les deux courbes ramenées sur la même échelle de temps, prêtes à être
    /// superposées : le natif tel quel, la prise d'Ethan déformée sur lui.
    let nativeCurve: [Double]
    let myCurve: [Double]
    /// Rapport des durées, avant tout alignement.
    let tempoRatio: Double

    /// La lecture en clair de l'écart.
    ///
    /// **Les seuils sont mesurés, pas choisis.** Deux distributions ont été
    /// calculées sur le corpus (12 clips, 4 leçons, voir le commentaire de type) :
    ///
    /// - la **même** phrase, débit et registre modifiés — donc la même mélodie :
    ///   médiane 0,11, p90 **0,22**, pire cas 0,46 ;
    /// - des phrases **différentes** — donc des mélodies sans rapport :
    ///   p10 0,31, médiane **0,55**, p90 **1,19**, max 2,18.
    ///
    /// Les bornes sont donc : le p90 du « même », la médiane du « différent », son
    /// p90. Mes premiers seuils, inventés (1, 2, 4 demi-tons), classaient deux
    /// phrases sans rapport comme conformes — l'échelle réelle est quatre fois plus
    /// resserrée.
    var verdict: String {
        switch gapSemitones {
        case ..<0.25: "La mélodie suit celle du natif"
        case ..<0.55: "La mélodie est proche"
        case ..<1.20: "La mélodie s'écarte par endroits"
        default: "La mélodie diffère nettement"
        }
    }
}

enum IntonationComparer {

    /// `nil` quand l'un des deux enregistrements n'a pas assez de voisement pour
    /// qu'on puisse parler de mélodie — trop court, trop bas, ou du souffle.
    static func compare(native: PitchTrack, mine: PitchTrack) -> Intonation? {
        guard native.isUsable, mine.isUsable else { return nil }

        let a = contour(of: native)
        let b = contour(of: mine)
        guard a.count >= 4, b.count >= 4 else { return nil }

        let path = align(a, b)
        guard !path.isEmpty else { return nil }

        let differences = path.map { abs(a[$0.i] - b[$0.j]) }.sorted()
        let gap = differences[differences.count / 2]

        // La prise d'Ethan replacée sur l'échelle de temps du natif : pour chaque
        // trame du natif, la moyenne des trames qui lui sont appariées.
        var mapped = [Double](repeating: 0, count: a.count)
        var counts = [Int](repeating: 0, count: a.count)
        for step in path {
            mapped[step.i] += b[step.j]
            counts[step.i] += 1
        }
        for index in mapped.indices where counts[index] > 0 {
            mapped[index] /= Double(counts[index])
        }

        return Intonation(gapSemitones: gap,
                          nativeCurve: a,
                          myCurve: mapped,
                          tempoRatio: mine.duration / max(native.duration, 0.001))
    }

    /// La courbe utile : du premier au dernier son voisé, les trous courts comblés
    /// par interpolation.
    ///
    /// Combler est ici légitime et ne l'était pas dans `PitchTrack` : une consonne
    /// sourde au milieu d'un mot n'interrompt pas la mélodie que l'oreille entend,
    /// elle la traverse. On ne comble que **l'intérieur**, jamais les bords.
    static func contour(of track: PitchTrack) -> [Double] {
        let values = track.frames.map(\.semitones)
        guard let first = values.firstIndex(where: { $0 != nil }),
              let last = values.lastIndex(where: { $0 != nil })
        else { return [] }

        var out: [Double] = []
        var lastKnown = values[first]!
        var pendingGap = 0

        for index in first...last {
            if let value = values[index] {
                if pendingGap > 0 {
                    // Interpolation linéaire sur le trou qu'on vient de traverser.
                    for step in 1...pendingGap {
                        let ratio = Double(step) / Double(pendingGap + 1)
                        out.append(lastKnown + (value - lastKnown) * ratio)
                    }
                    pendingGap = 0
                }
                out.append(value)
                lastKnown = value
            } else {
                pendingGap += 1
            }
        }
        return out
    }

    /// Largeur de la bande de Sakoe-Chiba, en fraction de la longueur.
    ///
    /// **Sans elle, la mesure ne mesure rien.** Un DTW libre peut apparier une
    /// trame contre vingt, et rapproche donc n'importe quelles courbes : deux
    /// phrases *différentes* du corpus ne sortaient qu'à 1,7 demi-ton, à peine plus
    /// que le même clip ralenti. La bande interdit de s'écarter de plus de 20 % de
    /// la diagonale — au-delà, ce n'est plus la même phrase dite autrement.
    static let bandFraction = 0.2

    /// Déformation temporelle dynamique, avec le coût le plus simple qui soit :
    /// la distance en demi-tons entre deux trames.
    static func align(_ a: [Double], _ b: [Double]) -> [(i: Int, j: Int)] {
        let n = a.count, m = b.count
        let infinity = Double.greatestFiniteMagnitude
        var cost = [[Double]](repeating: [Double](repeating: infinity, count: m + 1),
                              count: n + 1)
        cost[0][0] = 0

        let slope = Double(m) / Double(n)
        let band = max(4.0, bandFraction * Double(max(n, m)))

        for i in 1...n {
            for j in 1...m {
                // Hors bande : la case reste à l'infini, le chemin ne peut pas
                // passer par là.
                guard abs(Double(j) - Double(i) * slope) <= band else { continue }
                let local = abs(a[i - 1] - b[j - 1])
                let best = min(cost[i - 1][j], cost[i][j - 1], cost[i - 1][j - 1])
                guard best < infinity else { continue }
                cost[i][j] = local + best
            }
        }
        guard cost[n][m] < infinity else { return [] }

        var path: [(i: Int, j: Int)] = []
        var i = n, j = m
        while i > 0, j > 0 {
            path.append((i - 1, j - 1))
            let diagonal = cost[i - 1][j - 1]
            let up = cost[i - 1][j]
            let left = cost[i][j - 1]
            if diagonal <= up, diagonal <= left { i -= 1; j -= 1 }
            else if up <= left { i -= 1 }
            else { j -= 1 }
        }
        return path.reversed()
    }
}
