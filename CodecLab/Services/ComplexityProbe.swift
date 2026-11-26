// ComplexityProbe.swift
// La codifica di prova che precede «Crea serie»: misura quanto bitrate serve al video
// per una buona qualità, così la scala della serie si adatta al contenuto
// (pochi kb/s per un video quasi fermo, molti per uno molto movimentato).

import Foundation

/// La codifica di prova che misura quanto è difficile comprimere un video, per scegliere i bitrate di «Crea serie».
///
/// Il video viene codificato con x264 a qualità costante (CRF 23): in questa modalità l'encoder non insegue
/// un bitrate ma una qualità, quindi il bitrate che ottiene dice quanti bit servono a quel contenuto.
/// Un video quasi fermo ne richiede pochi, uno molto movimentato o pieno di dettagli molti.
/// Così la scala della serie si adatta al video invece di essere fissa.
///
/// I video fino a 30 secondi si provano per intero; quelli più lunghi su tre campioni da 5 secondi,
/// presi al centro di ciascun terzo, per non aspettare troppo.
enum ComplexityProbe {

    /// Il livello di qualità della prova: il CRF predefinito di x264.
    static let crf = 23
    /// Il preset di x264: veloce, perché la prova deve solo misurare, non produrre un file da guardare.
    static let preset = "veryfast"
    /// La durata di ogni campione, in secondi. Non meno di così: ogni campione comincia con un
    /// fotogramma I, che pesa più degli altri e su campioni brevi gonfierebbe la stima.
    static let sampleSeconds = 5.0
    /// Fino a questa durata il video si codifica per intero: la prova costa poco.
    static let wholeVideoLimitSeconds = 30.0

    /// Le parti del video da codificare.
    ///
    /// Un video breve si codifica tutto. Uno lungo si divide in tre parti uguali, e di ciascuna
    /// si prendono i 5 secondi centrali (intorno a 1/6, 1/2 e 5/6 della durata): così inizio
    /// e fine, spesso con titoli, dissolvenze o nero, restano fuori, e la scelta è sempre
    /// la stessa per lo stesso file.
    ///
    /// - Parameters:
    ///   - start: L'inizio della parte del video usata dalla serie, in secondi (0, o l'inizio dello spezzone).
    ///   - duration: La sua durata, in secondi.
    /// - Returns: I campioni, in ordine.
    static func samples(start: Double, duration: Double) -> [ClipRange] {
        guard duration > wholeVideoLimitSeconds else {
            return [ClipRange(startSeconds: start, durationSeconds: duration)]
        }

        return [1.0 / 6, 1.0 / 2, 5.0 / 6].map { position in
            ClipRange(startSeconds: start + duration * position - sampleSeconds / 2, durationSeconds: sampleSeconds)
        }
    }

    /// Gli argomenti di FFmpeg per codificare un campione.
    ///
    /// Solo la traccia video, con x264 in preset veloce, scritta come flusso H.264 senza
    /// contenitore: la dimensione del file è quella dei soli dati video.
    static func arguments(sourceURL: URL, sample: ClipRange, destinationURL: URL) -> [String] {
        [
            "-hide_banner", "-nostdin", "-y", "-loglevel", "error"
        ] + sample.inputArguments + [
            "-i", sourceURL.path,
            "-map", "0:v:0", "-an",
            "-c:v", "libx264", "-preset", preset, "-crf", String(crf), "-pix_fmt", "yuv420p",
            "-f", "h264", destinationURL.path
        ]
    }

    /// Il bitrate di riferimento del video: il bitrate medio della codifica di prova.
    ///
    /// - Parameters:
    ///   - sourceURL: Il file originale.
    ///   - start: L'inizio della parte del video usata dalla serie, in secondi.
    ///   - duration: La sua durata, in secondi.
    /// - Returns: Il bitrate in kb/s.
    /// - Throws: Un errore di FFmpeg, o se la prova non produce dati.
    static func referenceBitrateKbps(sourceURL: URL, start: Double, duration: Double) async throws -> Double {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("CodecLab-\(UUID().uuidString)-prova", isDirectory: true)

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        var totalBytes: Int64 = 0
        var totalSeconds = 0.0

        for (index, sample) in samples(start: start, duration: duration).enumerated() {
            let destination = directory.appendingPathComponent("campione-\(index).h264")

            _ = try await FFmpegProcessRunner.run(
                executableURL: MediaToolPaths.ffmpeg,
                arguments: arguments(sourceURL: sourceURL, sample: sample, destinationURL: destination)
            )

            let size = (try? fileManager.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
            totalBytes += size
            totalSeconds += sample.durationSeconds
        }

        // Il bitrate medio dei campioni, non il più alto: la serie codifica tutto il video.
        guard totalBytes > 0, totalSeconds > 0 else {
            throw AppError("La codifica di prova non ha prodotto dati: impossibile stimare la difficoltà del video.")
        }

        return Double(totalBytes) * 8 / totalSeconds / 1000
    }
}

/// Il risultato della codifica di prova sull'intero file originale, mostrato nella Libreria.
///
/// Si ottiene dal pulsante della Libreria o da «Crea serie» senza spezzone, e viene salvato insieme
/// all'impronta del file (``FileFingerprint``): se il file cambia, il risultato non viene più mostrato.
struct ComplexityMeasurement: Codable, Sendable {
    /// Il bitrate della codifica di prova (x264, CRF 23), in kb/s.
    let referenceKbps: Double
    /// Vero se la prova è stata fatta su tre campioni invece che sull'intero video.
    let isSampled: Bool
    /// La data della misura.
    let measuredAt: Date
    /// L'impronta del file al momento della misura.
    let file: FileFingerprint
}
