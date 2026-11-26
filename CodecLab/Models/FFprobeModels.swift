// FFprobeModels.swift
// Dati restituiti da FFprobe e risultati delle analisi sul file originale.

import Foundation

/// Le informazioni su un file lette da FFprobe: le tracce che contiene e il contenitore.
///
/// È ciò che CodecLab sa di un file appena aggiunto alla Libreria: se ha video e audio, con quali codec,
/// risoluzione, frame rate, durata e bitrate. Serve anche a decidere se il file si può usare:
/// le immagini e i file non multimediali vengono rifiutati (vedi ``isUsableMedia``).
struct FFprobeDocument: Decodable, Sendable {
    /// Le tracce del file, nell'ordine del contenitore.
    let streams: [FFprobeStream]
    /// Le informazioni sul contenitore.
    let format: FFprobeFormat?

    private enum CodingKeys: String, CodingKey {
        case streams
        case format
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        streams = try container.decodeIfPresent([FFprobeStream].self, forKey: .streams) ?? []
        format = try container.decodeIfPresent(FFprobeFormat.self, forKey: .format)
    }

    /// La prima traccia video vera, quella usata da codifica e analisi (le copertine non contano).
    var videoStream: FFprobeStream? {
        streams.first { $0.codecType == "video" && !$0.isAttachedPicture }
    }

    /// Vero se il file contiene almeno una traccia audio.
    var hasAudio: Bool {
        streams.contains { $0.codecType == "audio" }
    }

    /// Vero se il file è un video o un audio che CodecLab può usare.
    ///
    /// FFprobe legge anche le immagini (PNG, JPEG… come video di un fotogramma) e perfino
    /// i file di testo o sconosciuti (con il formato "tty"): questi non vanno nella Libreria.
    var isUsableMedia: Bool {
        let formats = (format?.formatName ?? "").split(separator: ",").map(String.init)
        let isImageOrText = formats.contains { $0 == "tty" || $0 == "image2" || $0.hasSuffix("_pipe") }
        return !isImageOrText && (videoStream != nil || hasAudio)
    }
}

/// Le informazioni sul contenitore del file (MP4, MOV, MKV…): formato, durata, dimensione e bitrate complessivo.
///
/// FFprobe restituisce i numeri come testo: le proprietà calcolate li convertono in valori pronti all'uso.
struct FFprobeFormat: Decodable, Sendable {
    /// I nomi brevi del formato, per esempio "mov,mp4,m4a,3gp,3g2,mj2".
    let formatName: String?
    /// Il nome descrittivo del formato.
    let longName: String?
    /// La durata, in secondi.
    let duration: String?
    /// La dimensione del file, in byte.
    let size: String?
    /// Il bitrate complessivo, in bit al secondo.
    let bitRate: String?
    /// I metadati del contenitore (titolo, data, encoder…).
    let tags: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case formatName = "format_name"
        case longName = "format_long_name"
        case duration
        case size
        case bitRate = "bit_rate"
        case tags
    }

    /// La durata, in secondi.
    var durationSeconds: Double? { duration.flatMap(Double.init) }
    /// La dimensione del file, in byte.
    var sizeBytes: Int64? { size.flatMap(Int64.init) }
    /// Il bitrate complessivo, in bit al secondo.
    var bitRateBitsPerSecond: Int64? { bitRate.flatMap(Int64.init) }
}

/// Una traccia del file (video, audio o altro), come la descrive FFprobe.
///
/// Molti campi esistono solo per un tipo di traccia: per esempio la risoluzione per il video,
/// la frequenza di campionamento per l'audio. La Libreria li mostra nel dettaglio del file,
/// e la relazione ne ricava la descrizione dell'originale.
struct FFprobeStream: Decodable, Sendable {
    /// La posizione della traccia nel contenitore.
    let index: Int?
    /// Il nome breve del codec, per esempio "h264", "aac" o "rawvideo".
    let codecName: String?
    /// Il nome descrittivo del codec.
    let codecLongName: String?
    /// Il profilo del codec, per esempio "High" o "Main 10".
    let profile: String?
    /// Il tipo di traccia: "video", "audio", "subtitle", "data"…
    let codecType: String?
    /// La larghezza del video, in pixel.
    let width: Int?
    /// L'altezza del video, in pixel.
    let height: Int?
    /// Il formato dei pixel, per esempio "yuv420p" o "yuv420p10le".
    let pixelFormat: String?
    /// Il frame rate medio, come frazione (per esempio "30000/1001").
    let frameRateAverage: String?
    /// Il frame rate di base, come frazione: usato se quello medio non è noto.
    let frameRateReal: String?
    /// Il formato dei campioni audio, per esempio "fltp".
    let sampleFormat: String?
    /// La frequenza di campionamento, in Hz.
    let sampleRate: String?
    /// Il numero di canali audio.
    let channels: Int?
    /// La disposizione dei canali, per esempio "stereo".
    let channelLayout: String?
    /// La profondità in bit dei campioni, se dichiarata.
    let bitsPerRawSample: String?
    /// Il bitrate della traccia, in bit al secondo.
    let bitRate: String?
    /// Il numero di fotogrammi dichiarato dal contenitore.
    let frameCount: String?
    /// I metadati della traccia (lingua, nome dell'encoder…).
    let tags: [String: String]?
    /// Le proprietà della traccia, per esempio "attached_pic" per le copertine.
    let disposition: [String: Int]?

    private enum CodingKeys: String, CodingKey {
        case index
        case codecName = "codec_name"
        case codecLongName = "codec_long_name"
        case profile
        case codecType = "codec_type"
        case width
        case height
        case pixelFormat = "pix_fmt"
        case frameRateAverage = "avg_frame_rate"
        case frameRateReal = "r_frame_rate"
        case sampleFormat = "sample_fmt"
        case sampleRate = "sample_rate"
        case channels
        case channelLayout = "channel_layout"
        case bitsPerRawSample = "bits_per_raw_sample"
        case bitRate = "bit_rate"
        case frameCount = "nb_frames"
        case tags
        case disposition
    }

    /// Il bitrate della traccia, in bit al secondo.
    var bitRateBitsPerSecond: Int64? { bitRate.flatMap(Int64.init) }

    /// La copertina di un file audio (MP3, M4A…) compare come traccia video di un solo fotogramma.
    var isAttachedPicture: Bool { disposition?["attached_pic"] == 1 }

    /// Video non compresso (per esempio i file .y4m): ogni fotogramma è salvato per intero,
    /// tutti hanno la stessa dimensione e sono indipendenti (di tipo I).
    var isUncompressedVideo: Bool {
        let uncompressedCodecs: Set = ["rawvideo", "v210", "v308", "v408", "v410", "r210", "r10k", "ayuv", "y41p", "yuv4"]
        return codecType == "video" && uncompressedCodecs.contains(codecName ?? "")
    }

    /// Traccia non compressa (video come sopra, oppure audio PCM): il bitrate è costante per definizione.
    var isUncompressed: Bool {
        isUncompressedVideo || (codecType == "audio" && (codecName ?? "").hasPrefix("pcm_"))
    }
    /// La frequenza di campionamento, in Hz.
    var sampleRateHz: Int? { sampleRate.flatMap(Int.init) }

    /// La profondità in bit del video, dal campo esplicito o, in sua assenza, dal formato dei pixel.
    ///
    /// Restituisce `nil` per i formati che non sa riconoscere.
    var pixelFormatBitDepth: Int? {
        // Preferisce il dato esplicito restituito da FFprobe.
        if let depth = bitsPerRawSample.flatMap(Int.init), depth > 0 {
            return depth
        }

        guard let pixelFormat else { return nil }

        let format = pixelFormat.lowercased()

        // Formati con profondità indicata nel nome.
        for depth in [16, 14, 12, 10, 9] {
            if format.hasSuffix("\(depth)le") ||
                format.hasSuffix("\(depth)be") {
                return depth
            }
        }

        // Formati RGB a 16 bit per componente.
        let sixteenBitFormats = [
            "rgb48le", "rgb48be",
            "bgr48le", "bgr48be",
            "rgba64le", "rgba64be",
            "bgra64le", "bgra64be"
        ]

        if sixteenBitFormats.contains(format) {
            return 16
        }

        // Formati comuni a 8 bit.
        let eightBitFormats = [
            "nv12", "nv21",
            "yuyv422", "uyvy422", "yvyu422",
            "rgb24", "bgr24",
            "rgba", "bgra", "argb", "abgr",
            "gray", "gray8"
        ]

        if format.hasSuffix("p") || eightBitFormats.contains(format) {
            return 8
        }

        return nil
    }

    /// Il frame rate: quello medio o, se non è noto, quello di base.
    var frameRate: Double? {
        Self.parseRational(frameRateAverage) ?? Self.parseRational(frameRateReal)
    }

    /// Converte una frazione di FFprobe, come "30000/1001", in un numero.
    ///
    /// - Parameter value: La frazione.
    /// - Returns: Il valore, o `nil` se la frazione non è valida (per esempio "0/0").
    private static func parseRational(_ value: String?) -> Double? {
        guard let value else { return nil }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let numerator = Double(parts[0]),
              let denominator = Double(parts[1]),
              denominator != 0 else { return nil }

        let result = numerator / denominator
        return result.isFinite ? result : nil
    }
}

// MARK: - Classificazione della modalità bitrate

/// Se una traccia ha un bitrate costante (CBR) o variabile (VBR), oppure se non è stato possibile stabilirlo.
enum StreamBitrateMode: Sendable {
    /// Bitrate costante (CBR).
    case constant
    /// Bitrate variabile (VBR).
    case variable
    /// Dati insufficienti per stabilirlo.
    case undetermined
}

/// Come è stato stabilito il tipo di bitrate: leggendo gli header del flusso (preciso, solo per l'audio MPEG)
/// o stimandolo dalle dimensioni dei pacchetti (per tutti gli altri codec).
enum StreamBitrateClassificationMethod: Sendable, Equatable {
    /// Dagli header dei frame (solo MPEG Audio).
    case direct
    /// Dalla variabilità della dimensione dei pacchetti.
    case estimated
}

/// L'indicatore che alcuni encoder MP3 scrivono nel primo frame («Xing», «Info» o «VBRI»):
/// dice se il file è a bitrate costante o variabile senza doverlo leggere tutto.
enum MPEGAudioHeaderMarker: Sendable {
    /// "Xing": scritto dagli encoder per i file a bitrate variabile.
    case xing
    /// "Info": la variante dell'indicatore Xing per i file a bitrate costante.
    case info
    /// "VBRI": l'indicatore dell'encoder Fraunhofer, per i file a bitrate variabile.
    case vbri
}

/// L'analisi del bitrate di una traccia, sui primi 60 secondi del file: costante o variabile,
/// con il metodo usato e i valori misurati.
///
/// La mostra la Libreria nel dettaglio del file. Sapere se l'originale è a bitrate costante o variabile
/// aiuta a interpretare i confronti.
struct StreamBitrateAnalysis: Sendable {
    /// La posizione della traccia nel contenitore.
    let streamIndex: Int
    /// Costante, variabile o indeterminato.
    let mode: StreamBitrateMode
    /// Come è stata ottenuta la classificazione.
    let classificationMethod: StreamBitrateClassificationMethod
    /// Il bitrate medio misurato, in bit al secondo.
    let averageBitRateBitsPerSecond: Int64?
    /// La durata analizzata, in secondi.
    let sampledDurationSeconds: Double
    /// La variabilità del bitrate tra le finestre di 5 secondi (deviazione standard / media).
    let coefficientOfVariation: Double?
    /// Il numero di finestre di 5 secondi analizzate.
    let analyzedWindowCount: Int
    /// Il numero di frame MPEG Audio letti (0 per gli altri codec).
    let analyzedFrameCount: Int
    /// L'indicatore trovato nel primo frame MPEG Audio, se presente.
    let mpegAudioHeaderMarker: MPEGAudioHeaderMarker?
    /// Vero se il file MPEG Audio è stato prodotto con LAME.
    let hasLAMEEncoderTag: Bool
}

// MARK: - Distribuzione dei tipi di fotogramma

/// Quanti fotogrammi I, P e B contiene un video.
///
/// I fotogrammi I sono immagini complete, i P e i B sono costruiti a partire da altri fotogrammi
/// e costano molto meno. La proporzione dice come l'encoder ha strutturato il video:
/// per esempio VideoToolbox, di solito, non usa fotogrammi B.
struct VideoFrameTypeSummary: Codable, Equatable, Sendable {
    /// I fotogrammi I, codificati senza riferimenti ad altri.
    let iFrames: Int
    /// I fotogrammi P, predetti da fotogrammi precedenti.
    let pFrames: Int
    /// I fotogrammi B, predetti da fotogrammi precedenti e successivi.
    let bFrames: Int
    /// I fotogrammi di tipo diverso o sconosciuto.
    let otherFrames: Int

    /// Il numero totale di fotogrammi.
    var totalFrames: Int {
        iFrames + pFrames + bFrames + otherFrames
    }

    /// La percentuale di fotogrammi I (0–100).
    var iPercentage: Double {
        percentage(iFrames)
    }

    /// La percentuale di fotogrammi P (0–100).
    var pPercentage: Double {
        percentage(pFrames)
    }

    /// La percentuale di fotogrammi B (0–100).
    var bPercentage: Double {
        percentage(bFrames)
    }

    /// La percentuale di `count` sul totale; 0 se il video non ha fotogrammi.
    private func percentage(_ count: Int) -> Double {
        guard totalFrames > 0 else { return 0 }
        return Double(count) / Double(totalFrames) * 100
    }
}

extension VideoFrameTypeSummary {
    /// Conta i fotogrammi di ciascun tipo.
    ///
    /// - Parameter frameTypes: Il tipo di ogni fotogramma: "I", "P", "B" o altro.
    init(frameTypes: [String]) {
        self.init(
            iFrames: frameTypes.count { $0 == "I" },
            pFrames: frameTypes.count { $0 == "P" },
            bFrames: frameTypes.count { $0 == "B" },
            otherFrames: frameTypes.count { !["I", "P", "B"].contains($0) }
        )
    }
}

/// La scansione dei fotogrammi del file originale: quanti I, P e B contiene e la loro sequenza.
///
/// Si avvia dalla Libreria e viene salvata insieme all'impronta del file (``FileFingerprint``):
/// se il file cambia, il risultato non viene più mostrato, perché non lo descriverebbe più.
struct SourceAnalysisResult: Codable, Sendable {
    /// Quanti fotogrammi di ciascun tipo contiene il video.
    let frameTypes: VideoFrameTypeSummary
    /// La data della scansione.
    let analyzedAt: Date
    /// L'impronta del file al momento della scansione.
    let file: FileFingerprint
}

/// L'impronta di un file: dimensione e data di modifica.
///
/// Se una delle due cambia, il file non è più quello analizzato. È un controllo rapido,
/// che non richiede di rileggere il file.
struct FileFingerprint: Codable, Equatable, Sendable {
    /// La dimensione, in byte.
    let sizeBytes: Int64?
    /// La data dell'ultima modifica.
    let modificationDate: Date?

    /// Legge l'impronta di un file.
    ///
    /// - Parameter url: Il file. Se non è leggibile, entrambi i valori sono `nil`.
    init(of url: URL) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        sizeBytes = values?.fileSize.map(Int64.init)
        modificationDate = values?.contentModificationDate
    }
}

// MARK: - Nome del codec

extension FFprobeStream {
    /// Il nome del codec mostrato all'utente, con le maiuscole corrette: FFprobe lo scrive
    /// in minuscolo ("h264", "vp9"), qui diventa "H.264 / AVC", "VP9". Usato nella Libreria e nella relazione.
    var codecDisplayName: String {
        switch codecName?.lowercased() ?? "" {
        case "h264", "avc": return "H.264 / AVC"
        case "hevc", "h265": return "H.265 / HEVC"
        case "av1": return "AV1"
        case "mpeg4": return "MPEG-4 Part 2"
        case "mpeg2video": return "MPEG-2 Video"
        case "prores": return "Apple ProRes"
        case "vp8": return "VP8"
        case "vp9": return "VP9"
        case "aac": return "AAC"
        case "mp3": return "MP3"
        case "mp2": return "MPEG Audio Layer II"
        case "mp1": return "MPEG Audio Layer I"
        case "ac3": return "Dolby Digital (AC-3)"
        case "eac3": return "Dolby Digital Plus (E-AC-3)"
        case "alac": return "Apple Lossless (ALAC)"
        case "flac": return "FLAC"
        case "opus": return "Opus"
        case "vorbis": return "Vorbis"
        case "pcm_s16le": return "PCM 16 bit"
        case "pcm_s24le": return "PCM 24 bit"
        case "pcm_s32le": return "PCM 32 bit"
        case "rawvideo": return "Non compresso (raw video)"
        default:
            if let longName = codecLongName, !longName.isEmpty {
                return longName
            }
            return codecName?.uppercased() ?? "Codec sconosciuto"
        }
    }
}
