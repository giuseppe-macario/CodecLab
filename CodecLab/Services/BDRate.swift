// BDRate.swift
// Il BD-rate (Bjøntegaard Delta rate): la differenza media di bitrate tra due curve qualità/bitrate
// a parità di qualità. Lo usa la tabella sotto il grafico delle curve, in Analisi qualità.

import Foundation

/// Il BD-rate (Bjøntegaard Delta rate): di quanto bitrate in più o in meno ha bisogno una configurazione
/// rispetto a un'altra per ottenere la stessa qualità.
///
/// È il numero standard per confrontare due encoder: −30% significa che, a parità di qualità,
/// la configurazione in esame usa il 30% di bitrate in meno del riferimento. CodecLab lo mostra
/// sotto la curva qualità/bitrate, confrontando il software con l'hardware e HEVC con H.264.
///
/// Il calcolo approssima il logaritmo del bitrate con un polinomio di terzo grado della qualità
/// e ne fa la media sull'intervallo di qualità comune alle due curve. Quando la qualità si avvicina
/// al massimo (VMAF quasi 100 a più bitrate) il polinomio oscilla e darebbe valori assurdi:
/// in quel caso, riconoscibile perché il polinomio non cresce sempre con la qualità, si usa
/// un'interpolazione a tratti che non può oscillare (PCHIP), come nella versione aggiornata del metodo.
enum BDRate {
    /// Un punto di una curva.
    struct Point {
        let bitrateKbps: Double
        let quality: Double
    }

    /// Un confronto tra due curve.
    struct Comparison {
        /// La curva in esame.
        let series: String
        /// La curva di riferimento.
        let reference: String
        /// Il BD-rate; `nil` se non è calcolabile.
        let percent: Double?
        /// Perché il BD-rate non è calcolabile, per esempio "meno di 3 punti entro l'obiettivo"; `nil` se lo è.
        let reason: String?
    }

    /// I confronti significativi tra le curve di un grafico.
    ///
    /// - Ogni curva software si confronta con la curva hardware dello stesso codec e profilo:
    ///   quanto bitrate risparmia il software, cioè quanto si perde con l'hardware.
    /// - Ogni curva HEVC si confronta con la curva H.264 dello stesso tipo di encoder.
    ///
    /// Se nessuna coppia corrisponde a queste regole, tutte le curve si confrontano con la prima
    /// H.264 in ordine alfabetico (o con la prima in assoluto).
    ///
    /// I punti fuori obiettivo (``QualityCurvePoint/isOffTarget``) non entrano nel calcolo.
    ///
    /// - Parameter points: I punti del grafico, di una o più curve.
    /// - Returns: I confronti, nell'ordine delle regole; vuoto se c'è una sola curva.
    static func comparisons(of points: [QualityCurvePoint]) -> [Comparison] {
        let pointsBySeries = Dictionary(grouping: points, by: \.series)
        let names = pointsBySeries.keys.sorted()

        // Con una sola curva non c'è niente da confrontare.
        guard names.count >= 2 else { return [] }

        // Le impostazioni sono le stesse per tutti i punti di una curva: basta il primo.
        func settings(_ name: String) -> EncodingSettings? {
            pointsBySeries[name]?.first?.settings
        }

        var pairs: [(series: String, reference: String)] = []

        for name in names {
            guard let tested = settings(name) else { continue }

            if tested.backend == .software, let reference = names.first(where: { candidate in
                guard let other = settings(candidate) else { return false }
                return other.backend == .hardware && other.codec == tested.codec && other.profile == tested.profile
            }) {
                pairs.append((name, reference))
            }
        }

        for name in names {
            guard let tested = settings(name), tested.codec == .hevc else { continue }

            if let reference = names.first(where: { candidate in
                guard let other = settings(candidate) else { return false }
                return other.codec == .h264 && other.backend == tested.backend
            }) {
                pairs.append((name, reference))
            }
        }

        if pairs.isEmpty {
            let reference = names.first { settings($0)?.codec == .h264 } ?? names[0]
            pairs = names.filter { $0 != reference }.map { ($0, reference) }
        }

        // Solo i punti entro l'obiettivo: quelli fuori obiettivo si accumulano sulla soglia
        // dell'encoder e renderebbero instabile il polinomio.
        func curve(_ name: String) -> [Point] {
            pointsBySeries[name, default: []]
                .filter { !$0.isOffTarget }
                .map { Point(bitrateKbps: $0.bitrateKbps, quality: $0.value) }
        }

        return pairs.map { pair in
            let reference = curve(pair.reference)
            let test = curve(pair.series)
            let value = percent(reference: reference, test: test)

            let reason: String? = if value != nil {
                nil
            } else if min(reference.count, test.count) < minimumPointCount {
                "meno di \(minimumPointCount) punti entro l'obiettivo"
            } else {
                "le curve non hanno valori di qualità in comune"
            }

            return Comparison(series: pair.series, reference: pair.reference, percent: value, reason: reason)
        }
    }

    /// I punti minimi per curva: con 3 si usa un polinomio di secondo grado.
    static let minimumPointCount = 3

    /// Il BD-rate di una curva rispetto a un'altra.
    ///
    /// Con 4 o più punti per curva è il metodo classico, con un polinomio di terzo grado;
    /// con 3 punti il polinomio è di secondo grado, perché non ce ne sono abbastanza per il terzo.
    ///
    /// - Parameters:
    ///   - reference: La curva di riferimento.
    ///   - test: La curva in esame.
    /// - Returns: La differenza percentuale di bitrate (−30 significa il 30% di bitrate in meno),
    ///   o `nil` se una curva ha meno di 3 punti o le curve non hanno qualità in comune.
    static func percent(reference: [Point], test: [Point]) -> Double? {
        guard reference.count >= minimumPointCount, test.count >= minimumPointCount,
              let referenceFit = Polynomial(fitting: reference),
              let testFit = Polynomial(fitting: test) else {
            return nil
        }

        let low = max(referenceFit.minQuality, testFit.minQuality)
        let high = min(referenceFit.maxQuality, testFit.maxQuality)

        guard high > low else { return nil }

        let averageLogDifference: Double

        if referenceFit.isIncreasing(from: low, to: high), testFit.isIncreasing(from: low, to: high) {
            averageLogDifference =
                (testFit.integral(from: low, to: high) - referenceFit.integral(from: low, to: high)) / (high - low)
        } else {
            // Polinomio instabile (per esempio qualità vicina al massimo): interpolazione monotona.
            guard let referenceCurve = MonotoneCurve(points: reference),
                  let testCurve = MonotoneCurve(points: test) else {
                return nil
            }

            averageLogDifference =
                (testCurve.integral(from: low, to: high) - referenceCurve.integral(from: low, to: high)) / (high - low)
        }

        let result = (exp(averageLogDifference) - 1) * 100
        return result.isFinite ? result : nil
    }

    /// Una curva ln(bitrate) in funzione della qualità, interpolata a tratti con cubiche di Hermite
    /// monotone (metodo di Fritsch e Carlson, detto PCHIP): passa per tutti i punti e, tra due punti,
    /// non sale né scende oltre i loro valori, quindi non oscilla.
    struct MonotoneCurve {
        /// Le qualità dei punti, in ordine crescente.
        private let qualities: [Double]
        /// ln(bitrate) dei punti.
        private let values: [Double]
        /// La pendenza della curva in ogni punto.
        private let slopes: [Double]

        /// - Parameter points: I punti della curva (almeno 2, con qualità tutte diverse).
        /// - Returns: `nil` se i punti sono meno di 2 o due punti hanno la stessa qualità.
        init?(points: [Point]) {
            let sorted = points.sorted { $0.quality < $1.quality }
            let x = sorted.map(\.quality)
            let y = sorted.map { log($0.bitrateKbps) }
            let n = x.count

            guard n >= 2, zip(x, x.dropFirst()).allSatisfy({ $1 > $0 }) else { return nil }

            // Pendenze dei segmenti, poi pendenze nei punti: zero se la curva cambia verso,
            // altrimenti la media armonica pesata (Fritsch–Carlson), che garantisce la monotonia.
            let h = (0..<(n - 1)).map { x[$0 + 1] - x[$0] }
            let delta = (0..<(n - 1)).map { (y[$0 + 1] - y[$0]) / h[$0] }
            var d = Array(repeating: 0.0, count: n)

            if n == 2 {
                d = [delta[0], delta[0]]
            } else {
                for k in 1..<(n - 1) where delta[k - 1] * delta[k] > 0 {
                    let w1 = 2 * h[k] + h[k - 1]
                    let w2 = h[k] + 2 * h[k - 1]
                    d[k] = (w1 + w2) / (w1 / delta[k - 1] + w2 / delta[k])
                }

                // Estremi: formula a tre punti, limitata perché non cambi verso né esageri.
                func endSlope(_ h0: Double, _ h1: Double, _ d0: Double, _ d1: Double) -> Double {
                    var slope = ((2 * h0 + h1) * d0 - h0 * d1) / (h0 + h1)
                    if slope * d0 <= 0 {
                        slope = 0
                    } else if d0 * d1 < 0, abs(slope) > abs(3 * d0) {
                        slope = 3 * d0
                    }
                    return slope
                }

                d[0] = endSlope(h[0], h[1], delta[0], delta[1])
                d[n - 1] = endSlope(h[n - 2], h[n - 3], delta[n - 2], delta[n - 3])
            }

            qualities = x
            values = y
            slopes = d
        }

        /// ln(bitrate) alla qualità indicata (entro l'intervallo dei punti).
        func value(at quality: Double) -> Double {
            let k = max(0, min(qualities.count - 2, (qualities.lastIndex { $0 <= quality } ?? 0)))
            let h = qualities[k + 1] - qualities[k]
            let t = (quality - qualities[k]) / h
            let t2 = t * t
            let t3 = t2 * t

            return (2 * t3 - 3 * t2 + 1) * values[k] + (t3 - 2 * t2 + t) * h * slopes[k] +
                (-2 * t3 + 3 * t2) * values[k + 1] + (t3 - t2) * h * slopes[k + 1]
        }

        /// L'integrale tra due qualità, con la regola di Simpson su 2000 intervalli: più che sufficiente
        /// per una curva così regolare.
        func integral(from low: Double, to high: Double) -> Double {
            let steps = 2000
            let step = (high - low) / Double(steps)

            let sum = (0...steps).reduce(0.0) { total, i in
                let weight: Double = (i == 0 || i == steps) ? 1 : (i % 2 == 1 ? 4 : 2)
                return total + weight * value(at: low + Double(i) * step)
            }

            return sum * step / 3
        }
    }

    /// Il polinomio ln(bitrate) = c₀ + c₁x + c₂x² + c₃x³, con x = qualità − media delle qualità;
    /// di secondo grado (senza c₃) se i punti sono solo 3.
    ///
    /// Centrare i valori rende il calcolo numericamente più stabile.
    private struct Polynomial {
        let coefficients: [Double]
        let center: Double
        let minQuality: Double
        let maxQuality: Double

        /// Calcola il polinomio con i minimi quadrati: con 4 punti (o 3, di secondo grado)
        /// passa esattamente per tutti.
        ///
        /// - Parameter points: I punti della curva.
        /// - Returns: `nil` se il sistema è singolare, per esempio con due punti della stessa qualità.
        init?(fitting points: [Point]) {
            let qualities = points.map(\.quality)

            center = qualities.reduce(0, +) / Double(qualities.count)
            minQuality = qualities.min() ?? 0
            maxQuality = qualities.max() ?? 0

            // Tanti coefficienti quanti i punti, fino a 4 (terzo grado).
            let size = min(4, points.count)

            // Equazioni normali come matrice size×(size+1): A[i][j] = Σ xⁱ⁺ʲ,
            // ultima colonna Σ xⁱ·ln(bitrate).
            var matrix = Array(repeating: Array(repeating: 0.0, count: size + 1), count: size)

            for point in points {
                let x = point.quality - center
                let y = log(point.bitrateKbps)

                for i in 0..<size {
                    for j in 0..<size {
                        matrix[i][j] += pow(x, Double(i + j))
                    }
                    matrix[i][size] += pow(x, Double(i)) * y
                }
            }

            guard let solution = Self.solve(matrix) else { return nil }
            coefficients = solution
        }

        /// Vero se il polinomio cresce sempre tra due qualità: più qualità, più bitrate.
        /// Se non è così, il polinomio sta oscillando e il suo integrale non è affidabile.
        func isIncreasing(from low: Double, to high: Double) -> Bool {
            let samples = 200
            var previous = value(at: low)

            for i in 1...samples {
                let current = value(at: low + (high - low) * Double(i) / Double(samples))
                if current < previous - 1e-9 { return false }
                previous = current
            }

            return true
        }

        /// ln(bitrate) alla qualità indicata.
        func value(at quality: Double) -> Double {
            let x = quality - center
            return coefficients.enumerated().reduce(0) { $0 + $1.element * pow(x, Double($1.offset)) }
        }

        /// L'integrale del polinomio tra due valori di qualità.
        func integral(from low: Double, to high: Double) -> Double {
            let l = low - center
            let h = high - center

            return coefficients.enumerated().reduce(0) { sum, term in
                let power = Double(term.offset + 1)
                return sum + term.element * (pow(h, power) - pow(l, power)) / power
            }
        }

        /// Risolve un sistema lineare con l'eliminazione di Gauss e pivot parziale.
        ///
        /// - Parameter augmented: La matrice completa, con i termini noti nell'ultima colonna.
        /// - Returns: Le soluzioni, o `nil` se il sistema è singolare.
        private static func solve(_ augmented: [[Double]]) -> [Double]? {
            var m = augmented
            let n = m.count

            for column in 0..<n {
                guard let pivot = (column..<n).max(by: { abs(m[$0][column]) < abs(m[$1][column]) }),
                      abs(m[pivot][column]) > 1e-12 else {
                    return nil
                }

                m.swapAt(column, pivot)

                for row in 0..<n where row != column {
                    let factor = m[row][column] / m[column][column]

                    for k in column...n {
                        m[row][k] -= factor * m[column][k]
                    }
                }
            }

            return (0..<n).map { m[$0][n] / m[$0][$0] }
        }
    }
}
