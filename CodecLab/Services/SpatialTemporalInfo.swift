// SpatialTemporalInfo.swift
// SI e TI (Spatial e Temporal Information, ITU-T P.910) del video originale, calcolati
// con il filtro siti di FFmpeg: quanto dettaglio c'è nelle immagini e quanto cambiano nel tempo.

import Foundation

/// Il calcolo di SI e TI del video originale, secondo la raccomandazione ITU-T P.910.
///
/// - SI (Spatial Information) misura il dettaglio di ogni fotogramma: la deviazione standard
///   del gradiente (filtro di Sobel) della luminanza.
/// - TI (Temporal Information) misura quanto cambia l'immagine da un fotogramma al successivo:
///   la deviazione standard della differenza di luminanza tra i due.
///
/// Il video viene prima convertito a 8 bit: il filtro calcola i valori a 10 bit su una scala
/// quattro volte più grande, che non sarebbe confrontabile. La risoluzione resta quella originale.
enum SpatialTemporalInfo {

    /// Gli argomenti di FFmpeg: SI e TI di ogni fotogramma della prima traccia video, scritti su stdout.
    static func arguments(sourceURL: URL) -> [String] {
        [
            "-hide_banner", "-nostdin", "-nostats", "-loglevel", "error",
            "-i", sourceURL.path,
            "-map", "0:v:0", "-an", "-sn",
            "-vf", "format=yuv420p,siti,metadata=mode=print:file=-",
            "-f", "null", "-"
        ]
    }

    /// Calcola SI e TI del file.
    ///
    /// Richiede la decodifica di tutto il video: per i file lunghi è lento.
    ///
    /// - Parameter sourceURL: Il file originale.
    /// - Returns: I valori riassuntivi.
    /// - Throws: Un errore di FFmpeg (per esempio se manca il filtro siti), o se non si ottengono valori.
    static func measure(sourceURL: URL) async throws -> SpatialTemporalSummary {
        let result = try await FFmpegProcessRunner.run(
            executableURL: MediaToolPaths.ffmpeg,
            arguments: arguments(sourceURL: sourceURL)
        )

        let text = result.outputText

        // Con i video lunghi le righe sono centinaia di migliaia: si leggono fuori dal thread principale.
        let summary = await Task.detached(priority: .utility) {
            SpatialTemporalInfo.summarize(perFrame: SpatialTemporalInfo.parse(text))
        }.value

        guard let summary else {
            throw AppError("Il calcolo di SI e TI non ha prodotto valori.")
        }

        return summary
    }

    /// Legge SI e TI di ogni fotogramma dall'output del filtro metadata.
    ///
    /// Le righe utili sono del tipo `lavfi.siti.si=45.12` e `lavfi.siti.ti=3.08`; le altre vengono ignorate.
    ///
    /// - Parameter text: L'output di FFmpeg.
    /// - Returns: I valori SI e TI, nell'ordine dei fotogrammi.
    nonisolated static func parse(_ text: String) -> (si: [Double], ti: [Double]) {
        var si: [Double] = []
        var ti: [Double] = []

        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("lavfi.siti.si="), let value = Double(line.dropFirst("lavfi.siti.si=".count)) {
                si.append(value)
            } else if line.hasPrefix("lavfi.siti.ti="), let value = Double(line.dropFirst("lavfi.siti.ti=".count)) {
                ti.append(value)
            }
        }

        return (si, ti)
    }

    /// Riassume i valori dei fotogrammi in mediana e massimo.
    ///
    /// Il TI del primo fotogramma è sempre 0, perché non c'è un fotogramma precedente: viene escluso.
    ///
    /// - Parameter perFrame: SI e TI di ogni fotogramma.
    /// - Returns: Il riassunto; `nil` se non ci sono valori.
    nonisolated static func summarize(perFrame: (si: [Double], ti: [Double])) -> SpatialTemporalSummary? {
        let ti = Array(perFrame.ti.dropFirst())

        guard let siMedian = median(perFrame.si), let siMax = perFrame.si.max() else {
            return nil
        }

        return SpatialTemporalSummary(
            frameCount: perFrame.si.count,
            siMedian: siMedian,
            siMax: siMax,
            tiMedian: median(ti) ?? 0,
            tiMax: ti.max() ?? 0
        )
    }

    /// La mediana di una serie di valori; `nil` se la serie è vuota.
    nonisolated static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

/// I valori riassuntivi di SI e TI di un video.
///
/// La raccomandazione P.910 usa il massimo nel tempo; la mediana descrive il video nel suo insieme
/// ed è meno sensibile ai pochi fotogrammi estremi, come i cambi di scena per il TI.
nonisolated struct SpatialTemporalSummary: Codable, Equatable, Sendable {
    /// Il numero di fotogrammi analizzati.
    let frameCount: Int
    /// La mediana dello SI dei fotogrammi.
    let siMedian: Double
    /// Il massimo dello SI dei fotogrammi.
    let siMax: Double
    /// La mediana del TI dei fotogrammi (escluso il primo).
    let tiMedian: Double
    /// Il massimo del TI dei fotogrammi (escluso il primo).
    let tiMax: Double
}

/// Il risultato del calcolo di SI e TI sul file originale, mostrato nella Libreria.
///
/// Viene salvato insieme all'impronta del file (``FileFingerprint``): se il file cambia,
/// il risultato non viene più mostrato.
struct SpatialTemporalMeasurement: Codable, Sendable {
    /// I valori.
    let summary: SpatialTemporalSummary
    /// La data del calcolo.
    let measuredAt: Date
    /// L'impronta del file al momento del calcolo.
    let file: FileFingerprint
}
