// EncodingExperiment.swift
// Esperimenti video (un video originale, le impostazioni di codifica e il file prodotto)
// ed esperimenti audio (la sola traccia audio, codificata in AAC a un certo bitrate).

import Foundation

/// Lo stato di un esperimento video o audio: pronto, completato o fallito.
///
/// Lo stato salvato non dice se l'esperimento è in coda o in codifica in questo momento: quell'informazione
/// è nella coda dei lavori (``JobQueue``), da cui le viste la ricavano. Così, se l'app viene chiusa
/// durante una codifica, al riavvio l'esperimento torna semplicemente «Pronto».
enum ExperimentStatus: String, Codable, CaseIterable {
    /// Creato, ma non ancora codificato (o codifica annullata).
    case ready
    /// Codifica riuscita: il file prodotto è disponibile.
    case completed
    /// L'ultima codifica è fallita e non c'è un risultato precedente valido.
    case failed

    /// Il nome dello stato mostrato all'utente.
    var title: String {
        switch self {
        case .ready: "Pronto"
        case .completed: "Completato"
        case .failed: "Errore"
        }
    }
}

/// Le misure del video prodotto da una codifica riuscita: dimensione del file, durata, bitrate effettivo
/// e tempo impiegato.
///
/// Il bitrate effettivo può differire da quello richiesto: è quello che conta nei grafici e nella relazione.
/// Per le codifiche software contiene anche il QP di ogni fotogramma.
struct EncodingOutputInfo: Codable, Equatable {
    /// La dimensione del file, in byte.
    var fileSizeBytes: Int64?
    /// La durata del video prodotto, in secondi.
    var durationSeconds: Double?
    /// Il tempo impiegato per la codifica, in secondi, escluse le pause.
    var encodingDurationSeconds: Double?
    /// Il bitrate effettivo della traccia video, in bit al secondo.
    var videoBitrateBitsPerSecond: Int64?
    /// Il bitrate effettivo della traccia audio, in bit al secondo.
    var audioBitrateBitsPerSecond: Int64?
    /// Il bitrate complessivo del file, in bit al secondo.
    var totalBitrateBitsPerSecond: Int64?
    /// Il QP di ogni fotogramma, solo per le codifiche software.
    var frameQuantizationSamples: [FrameQuantizationSample]? = nil
}

/// Il QP (parametro di quantizzazione) di un fotogramma, come lo riporta l'encoder software.
///
/// Il QP dice quanto l'encoder ha «arrotondato» i dettagli di quel fotogramma: più è alto, meno bit
/// e più perdita di qualità. Lo mostra il grafico del QP lungo il video, allineato al VMAF, per capire
/// se un calo di qualità dipende da una quantizzazione più forte. VideoToolbox non fornisce questo dato.
struct FrameQuantizationSample: Codable, Equatable, Identifiable, Sendable {
    /// La posizione del fotogramma nell'ordine di codifica (0, 1, 2, …).
    let encodeOrder: Int
    /// Il Picture Order Count, che stabilisce l'ordine di visualizzazione all'interno di un GOP.
    let pictureOrderCount: Int
    /// Il tipo di fotogramma: "I", "P" o "B".
    let frameType: String
    /// Il QP medio del fotogramma.
    let qp: Double

    /// La posizione nel video (0, 1, 2, …), calcolata da ``FrameQuantizationParser``.
    var displayOrder = 0

    /// L'identificativo del campione: la sua posizione nell'ordine di codifica.
    var id: Int { encodeOrder }
}

/// Un esperimento video: un file originale, le impostazioni con cui codificarlo e, dopo la codifica,
/// il file prodotto con le sue misure.
///
/// È l'unità di lavoro di Esperimenti video: si crea singolarmente o in gruppo con «Crea serie»,
/// si codifica, e poi si analizza in Analisi qualità. Gli esperimenti di una serie condividono
/// lo stesso ``seriesID`` e il bitrate della codifica di prova da cui è stata ricavata la scala.
///
/// I file vengono ritrovati tramite bookmark, così restano raggiungibili anche se vengono spostati o rinominati.
struct EncodingExperiment: Identifiable, Codable {
    /// L'identificativo dell'esperimento.
    let id: UUID
    /// L'identificativo del file originale nella Libreria (``MediaLibraryItem/id``).
    let sourceVideoID: UUID
    /// Il nome del file originale, mostrato anche se il file non è più raggiungibile.
    let sourceName: String
    /// Il bookmark del file originale.
    var sourceBookmarkData: Data
    /// La data di creazione dell'esperimento.
    let createdAt: Date

    /// Le impostazioni di codifica.
    var settings: EncodingSettings
    /// Lo stato salvato dell'esperimento.
    var status: ExperimentStatus

    /// Il nome del file prodotto, presente dopo una codifica riuscita.
    var outputFileName: String?
    /// Il bookmark del file prodotto.
    var outputBookmarkData: Data?
    /// Le misure del file prodotto.
    var outputInfo: EncodingOutputInfo?

    /// L'identificativo comune a tutti gli esperimenti creati insieme da «Crea serie»;
    /// `nil` per quelli creati singolarmente.
    var seriesID: UUID? = nil
    /// Per gli esperimenti di una serie, il bitrate della codifica di prova da cui è stata ricavata
    /// la scala (vedi ``ComplexityProbe``), in kb/s.
    var seriesReferenceKbps: Double? = nil

    /// Crea un esperimento pronto per la codifica.
    ///
    /// - Parameters:
    ///   - source: Il file originale, preso dalla Libreria.
    ///   - settings: Le impostazioni di codifica.
    init(source: MediaLibraryItem, settings: EncodingSettings) {
        id = UUID()
        sourceVideoID = source.id
        sourceName = source.name
        sourceBookmarkData = source.bookmarkData
        createdAt = Date()

        self.settings = settings
        status = .ready
    }
}

// MARK: - Esperimento audio

/// I due encoder AAC che Esperimenti audio mette a confronto: quello interno di FFmpeg e quello di Apple
/// (AudioToolbox), lo stesso usato da macOS.
enum AudioEncoder: String, Codable, CaseIterable, Identifiable {
    /// L'encoder AAC interno di FFmpeg.
    case ffmpeg = "aac"
    /// L'encoder AAC di Apple, dal framework AudioToolbox di macOS.
    case apple = "aac_at"

    /// Il nome dell'encoder per FFmpeg.
    var id: String { rawValue }

    /// Il nome dell'encoder mostrato all'utente.
    var title: String {
        switch self {
        case .ffmpeg: "AAC (FFmpeg)"
        case .apple: "AAC (AudioToolbox)"
        }
    }
}

/// Un esperimento audio: la sola traccia audio di un file, codificata in AAC a un certo bitrate.
///
/// Serve a misurare quanto pesa l'audio e quanto devia dal bitrate richiesto, con i due encoder.
/// L'audio si studia separatamente dal video: la dimensione di un file completo è la somma delle due parti,
/// quindi non serve codificare ogni combinazione di video e audio.
struct AudioExperiment: Identifiable, Codable {
    /// I bitrate (kb/s) di una serie audio.
    static let seriesBitratesKbps = [64, 96, 128, 192, 256]

    /// L'identificativo dell'esperimento.
    let id: UUID
    /// L'identificativo del file originale nella Libreria (``MediaLibraryItem/id``).
    let sourceVideoID: UUID
    /// Il nome del file originale.
    let sourceName: String
    /// Il bookmark del file originale.
    var sourceBookmarkData: Data
    /// L'encoder AAC usato.
    let encoder: AudioEncoder
    /// Il bitrate obiettivo, in kb/s.
    let bitrateKbps: Int
    /// La parte del file da codificare; `nil` per il file intero.
    let clip: ClipRange?

    /// Lo stato salvato dell'esperimento.
    var status: ExperimentStatus = .ready
    /// Il bookmark del file .m4a prodotto.
    var outputBookmarkData: Data?
    /// Le misure del file prodotto, presenti dopo una codifica riuscita.
    var output: AudioOutputInfo?

    /// Crea un esperimento audio pronto per la codifica.
    ///
    /// - Parameters:
    ///   - source: Il file originale, preso dalla Libreria.
    ///   - encoder: L'encoder AAC da usare.
    ///   - bitrateKbps: Il bitrate obiettivo, in kb/s.
    ///   - clip: La parte del file da codificare; `nil` per il file intero.
    init(source: MediaLibraryItem, encoder: AudioEncoder, bitrateKbps: Int, clip: ClipRange?) {
        id = UUID()
        sourceVideoID = source.id
        sourceName = source.name
        sourceBookmarkData = source.bookmarkData
        self.encoder = encoder
        self.bitrateKbps = bitrateKbps
        self.clip = clip
    }
}

/// Le misure del file .m4a prodotto da un esperimento audio: dimensione, bitrate effettivo, durata
/// e tempo di codifica.
struct AudioOutputInfo: Codable {
    /// Il nome del file .m4a.
    let fileName: String
    /// La dimensione del file, in byte.
    let fileSizeBytes: Int64?
    /// Il bitrate misurato della traccia audio, in bit al secondo.
    let bitrateBitsPerSecond: Int64?
    /// La durata dell'audio prodotto, in secondi.
    let durationSeconds: Double?
    /// Il tempo impiegato per la codifica, in secondi, escluse le pause.
    let encodingDurationSeconds: Double
}

extension AudioExperiment {
    /// Il bitrate misurato per ogni bitrate obiettivo, in media tra gli encoder.
    ///
    /// - Parameter experiments: Gli esperimenti audio; quelli non ancora codificati non contano.
    /// - Returns: Il bitrate misurato medio, in kb/s, per bitrate obiettivo.
    static func averageMeasuredKbps(_ experiments: [AudioExperiment]) -> [Int: Double] {
        let measured = experiments.compactMap { experiment in
            experiment.output?.bitrateBitsPerSecond.map { (target: experiment.bitrateKbps, kbps: Double($0) / 1000) }
        }

        return Dictionary(grouping: measured, by: \.target)
            .mapValues { values in values.map(\.kbps).reduce(0, +) / Double(values.count) }
    }
}
