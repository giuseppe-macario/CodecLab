// QualityInsights.swift
// I due calcoli della relazione sulla qualità, volutamente semplici: la classifica delle
// configurazioni per VMAF medio e la codifica migliore tra quelle provate, con un solo criterio
// dichiarato. Niente punti di equilibrio, equivalenze o compromessi: ogni regola in più
// funzionava in alcuni casi e sbagliava nei successivi.

import Foundation

/// I due giudizi della relazione sulla qualità, volutamente semplici: la classifica delle configurazioni
/// per VMAF medio e la codifica migliore tra quelle provate.
///
/// La codifica migliore si sceglie con un solo criterio, dichiarato nella relazione: il bitrate obiettivo
/// più basso a cui almeno una configurazione raggiunge un VMAF medio di 90 e, a quel bitrate,
/// la configurazione con il VMAF più alto. Le codifiche fuori obiettivo, che hanno superato di oltre
/// il 25% il bitrate richiesto, sono escluse da entrambi i giudizi, perché non rappresentano quel bitrate.
enum QualityInsights {

    /// Il VMAF medio che la relazione considera soddisfacente: è la soglia del criterio
    /// della codifica migliore. È una soglia pratica diffusa, non uno standard.
    static let goodVMAF = 90.0

    /// Il criterio della codifica migliore, scritto nella relazione.
    static let bestEncodingCriterion = "il bitrate obiettivo più basso a cui almeno una configurazione raggiunge " +
        "un VMAF medio di \(Int(goodVMAF)) e, a quel bitrate, la configurazione con il VMAF più alto"

    /// I punti utili di una curva: entro l'obiettivo, in ordine di bitrate.
    ///
    /// I punti fuori obiettivo (``QualityCurvePoint/isOffTarget``) non rappresentano il bitrate
    /// richiesto: non entrano né nella classifica né nella scelta.
    static func usablePoints(_ points: [QualityCurvePoint]) -> [QualityCurvePoint] {
        points.filter { !$0.isOffTarget }.sorted { $0.bitrateKbps < $1.bitrateKbps }
    }

    // MARK: Classifica

    /// Una configurazione nella classifica.
    struct RankedSeries {
        /// Il nome della curva.
        let series: String
        /// Le impostazioni di una sua codifica (codec, profilo, encoder…).
        let settings: EncodingSettings
        /// Il VMAF medio sui bitrate considerati.
        let meanVMAF: Double
    }

    /// Le configurazioni dalla migliore alla peggiore per VMAF medio, calcolato sui bitrate obiettivo
    /// che tutte hanno provato (così il confronto è alla pari). Senza bitrate in comune,
    /// per esempio con CRF o QP, su tutti i punti di ogni curva.
    ///
    /// - Parameter points: I punti del grafico.
    /// - Returns: La classifica; vuota se non ci sono punti utili.
    static func ranking(of points: [QualityCurvePoint]) -> [RankedSeries] {
        let bySeries = Dictionary(grouping: usablePoints(points), by: \.series)

        let targetSets = bySeries.values.map { Set($0.compactMap { $0.targetKbps.map { Int($0) } }) }
        let common = targetSets.dropFirst().reduce(targetSets.first ?? []) { $0.intersection($1) }

        return bySeries.compactMap { series, curve -> RankedSeries? in
            let considered = common.isEmpty ? curve : curve.filter { point in point.targetKbps.map { common.contains(Int($0)) } ?? false }
            guard let first = considered.first else { return nil }

            let mean = considered.map(\.value).reduce(0, +) / Double(considered.count)
            return RankedSeries(series: series, settings: first.settings, meanVMAF: mean)
        }
        // Dalla media più alta; a parità, per nome, perché l'ordine non cambi da una volta all'altra.
        .sorted { $0.meanVMAF != $1.meanVMAF ? $0.meanVMAF > $1.meanVMAF : $0.series < $1.series }
    }

    // MARK: Codifica migliore

    /// La codifica migliore tra quelle provate (vedi ``bestEncodingCriterion``).
    ///
    /// Si guarda prima il bitrate obiettivo più basso a cui qualche codifica arriva al VMAF medio
    /// di ``goodVMAF``, e lì si prende la codifica con il VMAF più alto. Le codifiche senza bitrate
    /// obiettivo (CRF, QP) si ordinano per bitrate misurato. Se nessuna arriva alla soglia,
    /// vale la codifica con il VMAF più alto in assoluto.
    ///
    /// - Parameter points: I punti del grafico.
    /// - Returns: La codifica e se raggiunge la soglia; `nil` se non ci sono punti utili.
    static func bestEncoding(of points: [QualityCurvePoint]) -> (point: QualityCurvePoint, reachesGoodQuality: Bool)? {
        let usable = usablePoints(points)
        guard let highest = usable.max(by: { $0.value < $1.value }) else { return nil }

        // Il «gradino» di bitrate di ogni punto: l'obiettivo se c'è, altrimenti il bitrate misurato.
        let byLevel = Dictionary(grouping: usable) { $0.targetKbps ?? $0.bitrateKbps }

        for level in byLevel.keys.sorted() {
            if let best = byLevel[level]?.max(by: { $0.value < $1.value }), best.value >= goodVMAF {
                return (best, true)
            }
        }

        return (highest, false)
    }

    // MARK: Nomi brevi

    /// Un nome breve per ogni curva, per le intestazioni della tabella della relazione:
    /// per esempio "H.264 hw" e "HEVC sw".
    ///
    /// - Parameter settings: Le impostazioni di una codifica per curva.
    /// - Returns: Il nome breve per nome della curva; vuoto se due curve avrebbero lo stesso
    ///   nome breve (per esempio stesso codec ed encoder con GOP diversi).
    static func shortSeriesNames(_ settings: [EncodingSettings]) -> [String: String] {
        var names: [String: String] = [:]

        for item in settings {
            let codec = item.codec == .h264 ? "H.264" : "HEVC"
            names[item.curveSeriesName] = "\(codec) \(item.backend.fileNameTag)"
        }

        return Set(names.values).count == names.count ? names : [:]
    }
}
