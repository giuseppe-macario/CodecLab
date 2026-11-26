// FFprobeService.swift
// Lettura delle informazioni di un file con FFprobe: tracce, formato, fotogrammi.
// L'analisi CBR/VBR del bitrate è in BitrateAnalysis.swift.

import Foundation

/// La lettura delle informazioni di un file con FFprobe: tracce, contenitore, pacchetti e tipi di fotogramma.
///
/// È usata ogni volta che CodecLab deve sapere qualcosa di un file: quando lo si aggiunge alla Libreria,
/// quando si misura un file codificato, quando si scansionano i fotogrammi. L'analisi CBR/VBR del bitrate
/// è in un'estensione, nel file BitrateAnalysis.swift.
struct FFprobeService: Sendable {

    /// Legge il formato e le tracce di un file.
    ///
    /// - Parameter mediaURL: Il file da esaminare.
    /// - Returns: Le informazioni restituite da FFprobe.
    /// - Throws: Un errore se FFprobe non riesce a leggere il file.
    func probe(_ mediaURL: URL) async throws -> FFprobeDocument {
        let result = try await FFmpegProcessRunner.run(
            executableURL: MediaToolPaths.ffprobe,
            arguments: [
                "-hide_banner",
                "-loglevel", "error",
                "-print_format", "json",
                "-show_format",
                "-show_streams",
                mediaURL.path
            ]
        )

        return try Self.decodeJSON(FFprobeDocument.self, from: result)
    }

    /// Conta i fotogrammi della prima traccia video decodificandoli tutti: lento, ma esatto.
    ///
    /// - Parameter mediaURL: Il file da esaminare.
    /// - Returns: Il numero di fotogrammi, o `nil` se FFprobe non lo restituisce.
    /// - Throws: Un errore se FFprobe non riesce a leggere il file.
    func countVideoFrames(_ mediaURL: URL) async throws -> Int? {
        let result = try await FFmpegProcessRunner.run(
            executableURL: MediaToolPaths.ffprobe,
            arguments: [
                "-hide_banner",
                "-loglevel", "error",
                "-select_streams", "v:0",
                "-count_frames",
                "-show_entries", "stream=nb_read_frames",
                "-of", "default=nokey=1:noprint_wrappers=1",
                mediaURL.path
            ]
        )

        return Int(result.outputText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Conta i fotogrammi I, P e B della prima traccia video.
    ///
    /// - Parameter mediaURL: Il file da esaminare.
    /// - Returns: Quanti fotogrammi ci sono di ciascun tipo.
    /// - Throws: Un errore se FFprobe non riesce a leggere il file.
    func frameTypeSummary(_ mediaURL: URL) async throws -> VideoFrameTypeSummary {
        VideoFrameTypeSummary(frameTypes: try await frameTypes(mediaURL))
    }

    /// Il tipo di ogni fotogramma della prima traccia video, nell'ordine di visualizzazione.
    ///
    /// Richiede la decodifica del video: per i file lunghi è lento.
    ///
    /// - Parameter mediaURL: Il file da esaminare.
    /// - Returns: "I", "P" o "B" per ogni fotogramma; "?" per i tipi sconosciuti.
    /// - Throws: Un errore se FFprobe non riesce a leggere il file.
    func frameTypes(_ mediaURL: URL) async throws -> [String] {
        let result = try await FFmpegProcessRunner.run(
            executableURL: MediaToolPaths.ffprobe,
            arguments: [
                "-hide_banner",
                "-loglevel", "error",
                "-select_streams", "v:0",
                "-show_frames",
                "-show_entries", "frame=pict_type",
                "-of", "csv=p=0",
                mediaURL.path
            ]
        )

        // I fotogrammi decodificati escono nell'ordine di visualizzazione.
        return result.outputText.split(whereSeparator: \.isNewline).compactMap { line in
            // Il formato CSV può includere side data dopo una virgola.
            // Il primo campo resta il valore pict_type richiesto.
            let frameType = String(line.split(separator: ",", maxSplits: 1).first ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()

            switch frameType {
            case "": return nil
            case "I", "P", "B": return frameType
            default: return "?"
            }
        }
    }

    /// La dimensione di ogni fotogramma della prima traccia video, nell'ordine di visualizzazione.
    ///
    /// Legge solo i pacchetti, senza decodificare il video: è veloce anche per i file lunghi
    /// e funziona con qualsiasi encoder, VideoToolbox compreso.
    ///
    /// - Parameter mediaURL: Il file da esaminare.
    /// - Returns: La dimensione di ogni fotogramma, in byte.
    /// - Throws: Un errore se FFprobe non riesce a leggere il file.
    func frameSizes(_ mediaURL: URL) async throws -> [Int] {
        let result = try await FFmpegProcessRunner.run(
            executableURL: MediaToolPaths.ffprobe,
            arguments: [
                "-hide_banner",
                "-loglevel", "error",
                "-select_streams", "v:0",
                "-show_packets",
                "-show_entries", "packet=pts_time,size",
                "-of", "json",
                mediaURL.path
            ]
        )

        let document = try Self.decodeJSON(PacketSizeDocument.self, from: result)

        return Self.sizesInDisplayOrder(document.packets.map {
            (presentationTime: $0.ptsTime.flatMap(Double.init), sizeBytes: $0.size.flatMap(Int.init) ?? 0)
        })
    }

    /// Mette le dimensioni dei pacchetti nell'ordine di visualizzazione.
    ///
    /// Con i B-frame i pacchetti sono salvati nell'ordine di decodifica, diverso da quello
    /// di visualizzazione: si ordinano per istante di presentazione. Se a qualche pacchetto
    /// manca l'istante, si lascia l'ordine del file.
    ///
    /// - Parameter packets: Istante di presentazione (in secondi) e dimensione di ogni pacchetto,
    ///   nell'ordine del file.
    /// - Returns: Le dimensioni, nell'ordine di visualizzazione.
    static func sizesInDisplayOrder(_ packets: [(presentationTime: Double?, sizeBytes: Int)]) -> [Int] {
        guard packets.allSatisfy({ $0.presentationTime != nil }) else {
            return packets.map(\.sizeBytes)
        }

        // A parità di istante vale l'ordine del file, perché l'ordinamento non è stabile.
        return packets.enumerated()
            .sorted { ($0.element.presentationTime!, $0.offset) < ($1.element.presentationTime!, $1.offset) }
            .map(\.element.sizeBytes)
    }

    /// Decodifica l'output JSON di FFprobe.
    ///
    /// - Parameters:
    ///   - type: Il tipo da decodificare.
    ///   - result: L'output del processo.
    /// - Returns: Il valore decodificato.
    /// - Throws: ``AppError`` se il JSON non è valido.
    static func decodeJSON<T: Decodable>(
        _ type: T.Type,
        from result: ProcessExecutionResult
    ) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: result.standardOutput)
        } catch {
            throw AppError("FFprobe ha restituito un JSON non valido.\n\(error.localizedDescription)")
        }
    }
}

/// L'elenco dei pacchetti letto con `ffprobe -show_packets`, con istante e dimensione.
private struct PacketSizeDocument: Decodable {
    /// Un pacchetto: FFprobe restituisce i numeri come testo.
    struct Packet: Decodable {
        let ptsTime: String?
        let size: String?

        private enum CodingKeys: String, CodingKey {
            case ptsTime = "pts_time"
            case size
        }
    }

    let packets: [Packet]
}
