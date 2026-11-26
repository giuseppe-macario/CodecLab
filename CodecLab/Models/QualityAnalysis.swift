// QualityAnalysis.swift
// Risultati dell'analisi VMAF/PSNR/SSIM: rapporto di libvmaf e risultato salvato.

import Foundation

// MARK: - Rapporto di libvmaf

/// Le medie delle tre metriche di qualità sull'intero video: VMAF, PSNR della luminanza e SSIM.
///
/// Sono i numeri principali di ogni analisi, quelli delle schede e delle curve.
struct QualityMetricSummary: Codable {
    /// Le statistiche di una metrica: CodecLab usa solo la media.
    struct Statistics: Codable {
        /// La media su tutti i fotogrammi.
        let mean: Double?
    }

    /// VMAF (0–100).
    let vmaf: Statistics?
    /// PSNR della luminanza, in dB.
    let psnrY: Statistics?
    /// SSIM (0–1), calcolato da libvmaf con la funzione "float_ssim".
    let ssim: Statistics?

    enum CodingKeys: String, CodingKey {
        case vmaf
        case psnrY = "psnr_y"
        case ssim = "float_ssim"
    }
}

/// Il rapporto prodotto da libvmaf durante l'analisi: le medie delle metriche e il VMAF di ogni fotogramma.
///
/// Il VMAF fotogramma per fotogramma serve a trovare i momenti peggiori, che la media nasconde,
/// e a disegnare il grafico del VMAF lungo il video.
struct VMAFReport: Decodable {
    /// Il numero di fotogrammi confrontati.
    let comparedFrameCount: Int
    /// Il VMAF di ogni fotogramma, in ordine, arrotondato a due decimali.
    let vmafPerFrame: [Double]
    /// Le medie delle metriche.
    let pooledMetrics: QualityMetricSummary

    /// Crea un rapporto a partire dai suoi valori.
    ///
    /// Serve per combinare due rapporti: quando il video viene ingrandito a 1080p,
    /// il VMAF viene da un calcolo e PSNR e SSIM da un altro.
    ///
    /// - Parameters:
    ///   - comparedFrameCount: Il numero di fotogrammi confrontati.
    ///   - vmafPerFrame: Il VMAF di ogni fotogramma.
    ///   - pooledMetrics: Le medie delle metriche.
    init(comparedFrameCount: Int, vmafPerFrame: [Double], pooledMetrics: QualityMetricSummary) {
        self.comparedFrameCount = comparedFrameCount
        self.vmafPerFrame = vmafPerFrame
        self.pooledMetrics = pooledMetrics
    }

    /// Una voce dell'elenco "frames": ogni fotogramma ha i propri valori, qui serve solo il VMAF.
    private struct FrameEntry: Decodable {
        struct Metrics: Decodable {
            let vmaf: Double?
        }

        let frameNum: Int
        let metrics: Metrics
    }

    enum CodingKeys: String, CodingKey {
        case frames
        case pooledMetrics = "pooled_metrics"
    }

    /// Legge il rapporto, ordina i fotogrammi e arrotonda il VMAF a due decimali,
    /// che bastano e riducono molto lo spazio occupato nei file salvati.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let frames = try container
            .decode([FrameEntry].self, forKey: .frames)
            .sorted { $0.frameNum < $1.frameNum }

        comparedFrameCount = frames.count
        vmafPerFrame = frames.compactMap { $0.metrics.vmaf.map { ($0 * 100).rounded() / 100 } }
        pooledMetrics = try container.decode(QualityMetricSummary.self, forKey: .pooledMetrics)
    }
}

// MARK: - Risultato dell'analisi

/// Il risultato di un'analisi della qualità: quanto il video codificato è fedele all'originale.
///
/// Contiene le medie di VMAF, PSNR e SSIM, il VMAF di ogni fotogramma, il bitrate effettivo,
/// la struttura dei fotogrammi (I, P, B e loro dimensioni) e una copia delle impostazioni di codifica,
/// così il risultato resta leggibile anche se l'esperimento cambia. È il dato da cui nascono
/// le curve, i grafici lungo il video e la relazione.
struct VideoQualityAnalysisResult: Identifiable, Codable {
    /// L'identificativo dell'analisi.
    let id: UUID
    /// L'esperimento analizzato.
    let experimentID: UUID
    /// Il nome del file codificato al momento dell'analisi.
    let outputFileName: String
    /// La data dell'analisi.
    let analyzedAt: Date

    /// Il tempo impiegato per l'analisi, in secondi, escluse le pause.
    let analysisDurationSeconds: Double

    /// Il numero di fotogrammi dell'originale (o dello spezzone).
    let originalFrameCount: Int?
    /// Il numero di fotogrammi del video codificato.
    let outputFrameCount: Int?

    /// La dimensione del video codificato, in byte.
    let outputFileSizeBytes: Int64?
    /// Il bitrate effettivo della traccia video codificata, in bit al secondo: l'ascissa delle curve.
    let videoBitrateBitsPerSecond: Int64?

    /// Una copia delle impostazioni di codifica, conservata insieme al risultato.
    let encodingSettings: EncodingSettings

    /// Quanti fotogrammi I, P e B contiene il video codificato.
    let frameTypeSummary: VideoFrameTypeSummary?
    /// Il QP di ogni fotogramma, per le codifiche software.
    let frameQuantizationSamples: [FrameQuantizationSample]?

    /// Il numero di fotogrammi confrontati.
    let comparedFrameCount: Int
    /// Le medie di VMAF, PSNR-Y e SSIM.
    let summary: QualityMetricSummary

    /// Il VMAF di ogni fotogramma: da qui si ricavano i momenti peggiori, che la media nasconde.
    let vmafPerFrame: [Double]

    /// Vero se il VMAF è stato calcolato dopo aver ingrandito i video a 1080p, come
    /// raccomandato per il modello vmaf_v0.6.1 (PSNR e SSIM restano alla risoluzione originale).
    /// Nil nelle analisi fatte prima di questa modifica.
    let vmafAt1080p: Bool?

    /// La dimensione di ogni fotogramma del video codificato, in byte, nell'ordine di visualizzazione.
    /// Nil nelle analisi fatte prima che venisse registrata.
    let frameSizes: [Int]?

    /// Il tipo di ogni fotogramma del video codificato, una lettera per fotogramma
    /// ("IBBPBBP…"), nello stesso ordine di ``frameSizes``.
    let frameTypes: String?

    /// Il frame rate del video codificato.
    let framesPerSecond: Double?

    /// Il 5% dei fotogrammi ha un VMAF inferiore o uguale a questo valore.
    var vmafPercentile5: Double? {
        Self.percentile(5, of: vmafPerFrame)
    }

    /// Il VMAF del fotogramma peggiore.
    var vmafMinimum: Double? {
        vmafPerFrame.min()
    }

    /// Crea il risultato di un'analisi appena conclusa.
    ///
    /// - Parameters:
    ///   - experiment: L'esperimento analizzato.
    ///   - report: Il rapporto di libvmaf.
    ///   - originalFrameCount: Il numero di fotogrammi dell'originale.
    ///   - outputFrameCount: Il numero di fotogrammi del video codificato.
    ///   - analysisDurationSeconds: Il tempo impiegato, in secondi.
    ///   - outputFileSizeBytes: La dimensione del video codificato, in byte.
    ///   - videoBitrateBitsPerSecond: Il bitrate effettivo della traccia video.
    ///   - frameTypeSummary: Quanti fotogrammi I, P e B contiene il video codificato.
    ///   - frameQuantizationSamples: Il QP di ogni fotogramma.
    ///   - vmafAt1080p: Vero se il VMAF è stato calcolato dopo aver ingrandito i video a 1080p.
    ///   - frameSizes: La dimensione di ogni fotogramma, in byte.
    ///   - frameTypes: Il tipo di ogni fotogramma, una lettera per fotogramma.
    ///   - framesPerSecond: Il frame rate del video codificato.
    init(
        experiment: EncodingExperiment,
        report: VMAFReport,
        originalFrameCount: Int? = nil,
        outputFrameCount: Int? = nil,
        analysisDurationSeconds: Double,
        outputFileSizeBytes: Int64? = nil,
        videoBitrateBitsPerSecond: Int64? = nil,
        frameTypeSummary: VideoFrameTypeSummary? = nil,
        frameQuantizationSamples: [FrameQuantizationSample]? = nil,
        vmafAt1080p: Bool = false,
        frameSizes: [Int]? = nil,
        frameTypes: String? = nil,
        framesPerSecond: Double? = nil
    ) {
        id = UUID()
        experimentID = experiment.id
        outputFileName = experiment.outputFileName ?? "Risultato"
        analyzedAt = Date()

        self.analysisDurationSeconds = analysisDurationSeconds
        self.originalFrameCount = originalFrameCount
        self.outputFrameCount = outputFrameCount
        self.outputFileSizeBytes = outputFileSizeBytes
        self.videoBitrateBitsPerSecond = videoBitrateBitsPerSecond
        encodingSettings = experiment.settings
        self.frameTypeSummary = frameTypeSummary
        self.frameQuantizationSamples = frameQuantizationSamples

        comparedFrameCount = report.comparedFrameCount
        summary = report.pooledMetrics

        vmafPerFrame = report.vmafPerFrame
        self.vmafAt1080p = vmafAt1080p
        self.frameSizes = frameSizes
        self.frameTypes = frameTypes
        self.framesPerSecond = framesPerSecond
    }

    /// Il fotogramma con il VMAF più basso (contato dall'inizio del video o dello spezzone).
    var worstFrameIndex: Int? {
        vmafPerFrame.indices.min { vmafPerFrame[$0] < vmafPerFrame[$1] }
    }

    /// Il percentile con il metodo del "rango più vicino".
    ///
    /// Il 5° percentile è il valore sotto cui, o al quale, cade il 5% peggiore dei fotogrammi.
    ///
    /// - Parameters:
    ///   - percent: Il percentile (0–100).
    ///   - values: I valori, in qualsiasi ordine.
    /// - Returns: Il valore del percentile, o `nil` se non ci sono valori.
    static func percentile(_ percent: Double, of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }

        let sorted = values.sorted()
        let rank = Int((percent / 100 * Double(sorted.count)).rounded(.up))

        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }
}

// MARK: - Dimensioni dei fotogrammi

/// I calcoli sulle dimensioni dei fotogrammi del video codificato: il loro ordine di visualizzazione
/// e il bitrate di ogni secondo.
///
/// Servono al grafico «Dimensione dei fotogrammi / Bitrate al secondo», che mostra dove l'encoder
/// ha speso più bit.
enum FrameSizeStatistics {

    /// Il bitrate di ogni secondo di video.
    ///
    /// I fotogrammi vengono raggruppati per secondo in base al frame rate; l'ultimo gruppo
    /// può essere più corto di un secondo, e il suo bitrate tiene conto della durata effettiva.
    ///
    /// - Parameters:
    ///   - frameSizes: La dimensione di ogni fotogramma, in byte, nell'ordine di visualizzazione.
    ///   - framesPerSecond: Il frame rate.
    /// - Returns: Il bitrate di ogni secondo, in kb/s; vuoto se il frame rate non è valido.
    static func bitratePerSecondKbps(frameSizes: [Int], framesPerSecond: Double) -> [Double] {
        guard framesPerSecond.isFinite, framesPerSecond > 0 else { return [] }

        var bytes: [Int] = []
        var frameCounts: [Int] = []

        for (index, size) in frameSizes.enumerated() {
            // Con frame rate non interi (29,97) i secondi non hanno tutti lo stesso numero di fotogrammi.
            let second = Int(Double(index) / framesPerSecond)

            // Con meno di un fotogramma al secondo, alcuni secondi restano senza fotogrammi.
            while bytes.count <= second {
                bytes.append(0)
                frameCounts.append(0)
            }

            bytes[second] += size
            frameCounts[second] += 1
        }

        return zip(bytes, frameCounts).map { bytes, frames in
            // byte × 8 = bit; diviso per la durata del gruppo (fotogrammi ÷ frame rate) e per 1000.
            // Un secondo senza fotogrammi dura un secondo intero.
            Double(bytes * 8) / (frames > 0 ? Double(frames) / framesPerSecond : 1) / 1000
        }
    }
}

