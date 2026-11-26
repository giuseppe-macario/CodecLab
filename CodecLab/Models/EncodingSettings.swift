// EncodingSettings.swift
// Parametri di una codifica: codec, profilo, encoder, controllo del rate, GOP, audio.

import Foundation

/// I codec video che CodecLab sa usare: H.264 (detto anche AVC), il più diffuso, e H.265 (HEVC),
/// più recente ed efficiente.
///
/// Ogni codec si può usare via hardware (VideoToolbox) o via software (x264 per H.264, x265 per HEVC):
/// il nome dell'encoder per FFmpeg dipende da entrambe le scelte.
enum VideoCodec: String, Codable, CaseIterable, Identifiable {
    /// H.264 / AVC.
    case h264
    /// H.265 / HEVC.
    case hevc

    /// L'identificativo del codec, salvato nei file JSON.
    var id: String { rawValue }

    /// Il nome del codec mostrato all'utente.
    var title: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "H.265 / HEVC"
        }
    }

    /// I profili disponibili per il codec, nell'ordine in cui vengono proposti.
    var profiles: [VideoProfile] {
        switch self {
        case .h264: [.baseline, .main, .high]
        case .hevc: [.main, .main10]
        }
    }

    /// Il nome dell'encoder di FFmpeg per questo codec.
    ///
    /// - Parameter backend: Codifica hardware (VideoToolbox) o software (x264, x265).
    /// - Returns: Il valore dell'opzione `-c:v`, per esempio `libx264` o `hevc_videotoolbox`.
    func encoderName(using backend: EncodingBackend) -> String {
        switch (self, backend) {
        case (.h264, .hardware): "h264_videotoolbox"
        case (.hevc, .hardware): "hevc_videotoolbox"
        case (.h264, .software): "libx264"
        case (.hevc, .software): "libx265"
        }
    }
}

/// Il profilo di codifica: l'insieme di strumenti di compressione che l'encoder può usare.
///
/// Non è un livello di qualità, ma di compatibilità: un profilo più ricco comprime meglio,
/// ma richiede un lettore che lo supporti. Per H.264: Baseline, Main e High; per HEVC: Main e Main 10 (10 bit).
enum VideoProfile: String, Codable, CaseIterable, Identifiable {
    /// H.264 Baseline: senza B-frame né CABAC.
    case baseline
    /// H.264 Main o HEVC Main (8 bit).
    case main
    /// H.264 High: aggiunge la trasformata 8×8.
    case high
    /// HEVC Main 10: video a 10 bit.
    case main10

    /// Il nome del profilo per FFmpeg (opzione `-profile:v`).
    var id: String { rawValue }

    /// Il nome del profilo mostrato all'utente.
    var title: String {
        switch self {
        case .baseline: "Baseline"
        case .main: "Main"
        case .high: "High"
        case .main10: "Main 10"
        }
    }
}

/// Dove avviene la codifica: sul blocco video del chip Apple (hardware, tramite VideoToolbox)
/// o sulla CPU (software, con x264 e x265).
///
/// L'hardware è molto più veloce e consuma poco; il software è più lento ma, a parità di bitrate,
/// di solito dà una qualità più alta. Confrontare i due è lo scopo principale di «Crea serie».
enum EncodingBackend: String, Codable, CaseIterable, Identifiable {
    /// Il codificatore video del chip, tramite VideoToolbox.
    case hardware
    /// La CPU, con x264 o x265.
    case software

    /// L'identificativo, salvato nei file JSON.
    var id: String { rawValue }

    /// La descrizione mostrata all'utente.
    var title: String {
        switch self {
        case .hardware: "via hardware"
        case .software: "via software"
        }
    }

    /// La sigla nei nomi dei file creati dalle serie: "hw" o "sw".
    var fileNameTag: String {
        switch self {
        case .hardware: "hw"
        case .software: "sw"
        }
    }
}

/// Che cosa fare della traccia audio quando si codifica un video: copiarla così com'è, senza perdita
/// e senza tempo aggiuntivo, oppure ricodificarla in AAC a un bitrate scelto.
enum AudioEncodingMode: String, Codable, CaseIterable, Identifiable {
    /// Copiare l'audio originale senza ricodificarlo.
    case passthrough
    /// Ricodificare l'audio in AAC.
    case aac

    /// L'identificativo, salvato nei file JSON.
    var id: String { rawValue }

    /// La descrizione mostrata all'utente.
    var title: String {
        switch self {
        case .passthrough: "Mantieni audio originale"
        case .aac: "Converti in AAC"
        }
    }
}

/// Il modo in cui l'encoder decide quanti bit usare.
///
/// - **Bitrate**: si chiede un bitrate medio; è l'unico modo disponibile con VideoToolbox
///   e quello usato nelle serie, perché permette di confrontare encoder diversi allo stesso bitrate.
/// - **CRF**: si chiede una qualità costante e il bitrate dipende dal contenuto (solo x264 e x265).
/// - **QP**: si fissa la quantizzazione, senza adattamenti; utile per studiare il QP (solo x264 e x265).
enum EncodingRateControlMode: String, Codable, CaseIterable, Identifiable {
    /// Un bitrate medio obiettivo (l'unica modalità di VideoToolbox).
    case bitrate
    /// Qualità percepita circa costante (CRF), solo via software.
    case constantQuality
    /// Quantizzazione costante (QP), solo via software.
    case constantQuantizer

    /// L'identificativo, salvato nei file JSON.
    var id: String { rawValue }

    /// La descrizione mostrata all'utente.
    var title: String {
        switch self {
        case .bitrate: "Bitrate target"
        case .constantQuality: "Qualità costante (CRF)"
        case .constantQuantizer: "Quantizzatore fisso (QP)"
        }
    }
}

// MARK: - Spezzone

/// La parte del file da usare negli esperimenti: un inizio e una durata, in secondi.
///
/// Codificare e analizzare 10–20 secondi rappresentativi è molto più veloce che lavorare sull'intero file,
/// e per un confronto tra configurazioni di solito basta. Lo stesso spezzone viene usato anche
/// dall'analisi della qualità, per confrontare le stesse immagini.
struct ClipRange: Codable, Equatable, Hashable {
    /// L'inizio dello spezzone, in secondi dall'inizio del file.
    var startSeconds: Double = 0
    /// La durata dello spezzone, in secondi.
    var durationSeconds: Double = 20

    /// Gli argomenti di FFmpeg da mettere prima di `-i`.
    ///
    /// La lettura parte da ``startSeconds`` con precisione al fotogramma, perché
    /// il video viene decodificato, e dura ``durationSeconds``.
    var inputArguments: [String] {
        ["-ss", String(startSeconds), "-t", String(durationSeconds)]
    }

    /// La descrizione mostrata all'utente, per esempio "Spezzone da 30 s, durata 20 s".
    var description: String {
        "Spezzone da \(startSeconds.formatted()) s, durata \(durationSeconds.formatted()) s"
    }
}

// MARK: - Impostazioni di codifica

/// Tutte le impostazioni di una codifica video: codec, profilo, encoder, controllo del bitrate,
/// GOP, B-frame, audio ed eventuale spezzone.
///
/// È ciò che si sceglie in Esperimenti video. Da qui derivano gli argomenti passati a FFmpeg
/// (vedi ``EncodingService``) e il nome della curva su cui finisce la codifica nei grafici:
/// due esperimenti che differiscono solo per il bitrate stanno sulla stessa curva.
struct EncodingSettings: Codable, Equatable {
    /// Il codec video.
    var codec: VideoCodec = .h264
    /// Codifica hardware o software.
    var backend: EncodingBackend = .hardware
    /// Il profilo; deve essere tra quelli di ``VideoCodec/profiles``.
    var profile: VideoProfile = .high

    /// La modalità di controllo del rate scelta; via hardware vale sempre ``EncodingRateControlMode/bitrate``.
    var rateControlMode: EncodingRateControlMode = .bitrate
    /// Il valore CRF (0–51), per ``EncodingRateControlMode/constantQuality``.
    var crfValue: Int = 23
    /// Il QP dei fotogrammi P (0–51), per ``EncodingRateControlMode/constantQuantizer``.
    var quantizerValue: Int = 23
    /// Il bitrate video obiettivo, in kb/s, per ``EncodingRateControlMode/bitrate``.
    var videoBitrateKbps: Int = 1000
    /// La distanza massima tra due fotogrammi chiave, in fotogrammi.
    var gopSize: Int = 60
    /// Il numero massimo di B-frame consecutivi; solo via software.
    var bFrameCount: Int = 3

    /// Che cosa fare della traccia audio.
    var audioMode: AudioEncodingMode = .passthrough
    /// Il bitrate audio, in kb/s, se l'audio viene ricodificato in AAC.
    var audioBitrateKbps: Int = 128

    /// La parte del video da usare; `nil` per il video intero.
    var clip: ClipRange? = nil

    /// Vero se la codifica è in due passate. CodecLab lo imposta da sé con ``withStandardPasses``.
    /// Opzionale, così gli esperimenti salvati prima si leggono ancora (e restano in una passata,
    /// com'erano stati codificati). Vale solo se ``usesTwoPass``.
    var twoPass: Bool? = nil

    /// Le stesse impostazioni con il numero di passate stabilito da CodecLab: due passate per
    /// le codifiche software a bitrate, una per tutte le altre (VideoToolbox ne fa una sola,
    /// e CRF e QP non hanno un bitrate da rispettare).
    var withStandardPasses: EncodingSettings {
        var settings = self
        settings.twoPass = backend == .software && rateControlMode == .bitrate ? true : nil
        return settings
    }

    /// Vero se la codifica avviene in due passate: richiesta, via software e con controllo a bitrate.
    ///
    /// La prima passata analizza tutto il video; la seconda distribuisce i bit sapendo già dove
    /// servono. Evita, tra l'altro, l'avvio a qualità molto bassa delle codifiche a bitrate ridotto.
    var usesTwoPass: Bool {
        twoPass == true && backend == .software && rateControlMode == .bitrate
    }

    /// La modalità di controllo del rate effettivamente usata.
    ///
    /// VideoToolbox usa solo il controllo a bitrate: CRF e QP valgono per gli encoder software.
    var effectiveRateControlMode: EncodingRateControlMode {
        backend == .software ? rateControlMode : .bitrate
    }

    /// Il formato dei pixel del video codificato: sempre 4:2:0, a 10 bit solo per HEVC Main 10.
    ///
    /// Fissarlo evita errori con sorgenti a 10 bit o 4:2:2/4:4:4
    /// (per esempio H.264 High non accetta i 10 bit).
    var pixelFormat: String {
        guard profile == .main10 else { return "yuv420p" }
        return backend == .hardware ? "p010le" : "yuv420p10le"  // VideoToolbox vuole p010le
    }

    /// Il formato in cui originale e codificato vengono confrontati da libvmaf,
    /// che richiede due ingressi con lo stesso formato.
    var analysisPixelFormat: String {
        profile == .main10 ? "yuv420p10le" : "yuv420p"
    }

    // MARK: Descrizioni condivise da Esperimenti video e Analisi

    /// Codec, profilo e tipo di encoder, per esempio "H.264 · High · via software".
    var codecDescription: String {
        "\(codec.title) · \(profile.title) · \(backend.title)"
    }

    /// Il controllo del rate, per esempio "Bitrate obiettivo: 1000 kb/s" o "Controllo rate: CRF 23".
    var rateControlDescription: String {
        switch effectiveRateControlMode {
        case .bitrate: "Bitrate obiettivo: \(videoBitrateKbps) kb/s" + (usesTwoPass ? " (due passate)" : "")
        case .constantQuality: "Controllo rate: CRF \(crfValue)"
        case .constantQuantizer: "Controllo rate: QP \(quantizerValue)"
        }
    }

    /// GOP e B-frame, per esempio "GOP 60 · B-frame 3" (i B-frame sono configurabili solo via software).
    var structureDescription: String {
        backend == .software ? "GOP \(gopSize) · B-frame \(bFrameCount)" : "GOP \(gopSize)"
    }

    /// Il nome della serie nei grafici: le prove con lo stesso nome stanno sulla stessa curva.
    ///
    /// Comprende tutto tranne il valore di bitrate, CRF o QP, che è ciò che varia lungo la curva.
    var curveSeriesName: String {
        let rateMode = switch effectiveRateControlMode {
        case .bitrate: usesTwoPass ? "Bitrate obiettivo, due passate" : "Bitrate obiettivo"
        case .constantQuality: "CRF"
        case .constantQuantizer: "QP"
        }

        return "\(codecDescription) · \(structureDescription) · \(rateMode)"
    }
}

// MARK: - Ordine dei confronti

extension EncodingSettings {
    /// Vero se la prima codifica va elencata prima della seconda, nell'ordine che mette vicine
    /// le codifiche da confrontare: per bitrate, e a parità di bitrate H.264 prima di HEVC
    /// e hardware prima di software.
    ///
    /// Il bitrate è l'obiettivo per le codifiche a bitrate (così la coppia hardware/software
    /// allo stesso obiettivo resta vicina anche se i bitrate misurati differiscono un po'),
    /// quello misurato per CRF e QP.
    ///
    /// - Parameters:
    ///   - first: Impostazioni e bitrate misurato (in kb/s) della prima codifica.
    ///   - second: Impostazioni e bitrate misurato della seconda.
    static func comparisonOrder(
        _ first: (settings: EncodingSettings, measuredKbps: Double?),
        _ second: (settings: EncodingSettings, measuredKbps: Double?)
    ) -> Bool {
        func key(_ entry: (settings: EncodingSettings, measuredKbps: Double?)) -> (Double, Int, Int, String) {
            let settings = entry.settings
            let rate = settings.effectiveRateControlMode == .bitrate
                ? Double(settings.videoBitrateKbps)
                : entry.measuredKbps ?? .infinity

            return (
                rate,
                VideoCodec.allCases.firstIndex(of: settings.codec) ?? 0,
                settings.backend == .hardware ? 0 : 1,
                settings.curveSeriesName
            )
        }

        return key(first) < key(second)
    }
}

// MARK: - Serie di confronto hardware / software

/// Le otto codifiche di «Crea serie»: lo stesso codec via hardware e via software, agli stessi quattro bitrate.
///
/// È il modo più rapido per confrontare i due encoder: quattro punti per encoder bastano per tracciare due curve
/// qualità/bitrate e calcolare il BD-rate. I bitrate non sono fissi ma si adattano al video: una codifica di prova
/// (vedi ``ComplexityProbe``) misura quanto è difficile comprimerlo, e la serie usa la metà, lo stesso, il doppio
/// e il quadruplo di quel valore, senza superare il bitrate dell'originale.
enum ComparisonSeries {

    /// I quattro punti rispetto al bitrate di riferimento della codifica di prova (vedi ``ComplexityProbe``):
    /// metà, uguale, il doppio e il quadruplo.
    ///
    /// La prova misura quanto è difficile comprimere il video, ma a CRF 23 la qualità, misurata con
    /// il VMAF, è ancora media (con un CIF ingrandito a 1080p, circa 70): servono due raddoppi in più
    /// per arrivare dove la curva si appiattisce, che è la cosa più utile da vedere. Così la scala
    /// va da una qualità scarsa a una alta, che il video sia quasi fermo o molto movimentato.
    static let referenceMultipliers = [0.5, 1, 2, 4]

    /// I quattro bitrate della serie, ricavati dal bitrate di riferimento della codifica di prova.
    ///
    /// Se il più alto supera il bitrate dell'originale, la scala viene abbassata in proporzione:
    /// oltre quel valore non c'è qualità da recuperare. I valori sono arrotondati a due cifre
    /// significative, con un minimo di 10 kb/s, e ognuno è almeno 1,8 volte il precedente.
    ///
    /// - Parameters:
    ///   - referenceKbps: Il bitrate della codifica di prova, in kb/s.
    ///   - sourceBitrateKbps: Il bitrate video dell'originale, in kb/s, se noto e se l'originale è compresso.
    /// - Returns: Quattro bitrate crescenti, in kb/s.
    static func bitratesKbps(referenceKbps: Double, sourceBitrateKbps: Double?) -> [Int] {
        var values = referenceMultipliers.map { $0 * referenceKbps }

        if let sourceBitrateKbps, let highest = values.last, highest > sourceBitrateKbps {
            values = values.map { $0 * sourceBitrateKbps / highest }
        }

        // Arrotondati a due cifre significative, con un minimo di 10 kb/s. Se il minimo
        // (o l'arrotondamento) avvicina troppo due valori, il successivo diventa il doppio:
        // i quattro punti devono restare distinti, altrimenti la curva perde un punto.
        var bitrates: [Int] = []

        for value in values {
            var kbps = max(10, roundedToTwoSignificantDigits(value))

            if let previous = bitrates.last, Double(kbps) < Double(previous) * 1.8 {
                kbps = previous * 2
            }

            bitrates.append(kbps)
        }

        return bitrates
    }

    /// Arrotonda a due cifre significative: 45,6 → 46 · 182,3 → 180 · 7450 → 7500.
    private static func roundedToTwoSignificantDigits(_ value: Double) -> Int {
        guard value >= 1 else { return 1 }

        let magnitude = pow(10, floor(log10(value)) - 1)
        return Int((value / magnitude).rounded() * magnitude)
    }

    /// Le otto impostazioni della serie.
    ///
    /// Codec e profilo sono quelli di partenza; il controllo è a bitrate, l'unico che funziona
    /// anche via hardware, e via software in due passate.
    ///
    /// - Parameters:
    ///   - base: Le impostazioni di partenza (codec, profilo, GOP, B-frame, audio, spezzone…).
    ///   - bitratesKbps: I bitrate della serie, in kb/s.
    /// - Returns: Prima le codifiche via hardware, poi quelle via software, nell'ordine dei bitrate.
    static func settings(from base: EncodingSettings, bitratesKbps: [Int]) -> [EncodingSettings] {
        [EncodingBackend.hardware, .software].flatMap { backend in
            bitratesKbps.map { kbps in
                var settings = base
                settings.backend = backend
                settings.rateControlMode = .bitrate
                settings.videoBitrateKbps = kbps
                return settings.withStandardPasses
            }
        }
    }
}
