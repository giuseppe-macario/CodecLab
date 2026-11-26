// QualityTests.swift
// Calcoli sui risultati delle analisi: BD-rate, percentile del VMAF, dimensioni dei fotogrammi,
// ingrandimento a 1080p, asse logaritmico dei bitrate, classifica e codifica migliore.
//
// Strategia di verifica
// ---------------------
// Test unitari dei calcoli numerici e delle regole di decisione, tutti senza stato e deterministici.
//
// - Test con oracolo: il BD-rate viene confrontato con il risultato di un'implementazione di
//   riferimento indipendente (numpy e scipy in Python), calcolato una volta e scritto nel test.
// - Test metamorfici: invece di un valore atteso, si verifica una relazione che deve valere
//   comunque, per esempio «la stessa qualità con metà del bitrate dà −50%» e «due curve identiche
//   danno 0%».
// - Test di regressione: casi reali che in passato davano risultati sbagliati (curve con VMAF
//   quasi 100, che facevano esplodere il BD-rate) restano nei test, perché l'errore non ritorni.
// - Test delle regole: classifica, codifica migliore e confronti sono provati su casi costruiti
//   dalla specifica (il criterio scritto nella relazione), compresi i casi limite: nessuna codifica
//   a VMAF 90, punti fuori obiettivo, una sola curva.

import Foundation
import Testing
@testable import CodecLab

/// Test numerici del BD-rate (``BDRate``), con oracolo e proprietà metamorfiche.
///
/// - Oracolo: il risultato coincide con quello di numpy (polinomio) e di scipy (PCHIP) sugli stessi punti.
/// - Proprietà metamorfiche: curve identiche danno 0%; la stessa qualità con metà del bitrate dà −50%.
/// - Regressione: con curve quasi a VMAF 100 il risultato resta ragionevole invece di esplodere.
/// - Casi limite: meno di 3 punti o nessuna qualità in comune non danno alcun valore.
@MainActor
struct BDRateTests {

    private let reference: [BDRate.Point] = [
        .init(bitrateKbps: 500, quality: 80),
        .init(bitrateKbps: 1000, quality: 88),
        .init(bitrateKbps: 2000, quality: 93),
        .init(bitrateKbps: 4000, quality: 96),
    ]

    @Test("Curve identiche: nessuna differenza")
    func identical() throws {
        let percent = try #require(BDRate.percent(reference: reference, test: reference))
        #expect(abs(percent) < 1e-9)
    }

    @Test("Stessa qualità con metà del bitrate: −50%")
    func halfBitrate() throws {
        let test = reference.map { BDRate.Point(bitrateKbps: $0.bitrateKbps / 2, quality: $0.quality) }
        let percent = try #require(BDRate.percent(reference: reference, test: test))
        #expect(abs(percent + 50) < 1e-6)
    }

    @Test("Stesso risultato del calcolo di riferimento con numpy")
    func matchesNumpy() throws {
        // numpy.polyfit(qualità, ln(bitrate), 3), integrato sull'intervallo di qualità comune.
        let test: [BDRate.Point] = [
            .init(bitrateKbps: 400, quality: 81),
            .init(bitrateKbps: 800, quality: 88.5),
            .init(bitrateKbps: 1600, quality: 93.5),
            .init(bitrateKbps: 3200, quality: 96.2),
        ]

        let percent = try #require(BDRate.percent(reference: reference, test: test))
        #expect(abs(percent - (-24.7259)) < 0.001)
    }

    @Test("Con 3 punti si usa un polinomio di secondo grado")
    func threePoints() throws {
        let three = Array(reference.prefix(3))
        let test = three.map { BDRate.Point(bitrateKbps: $0.bitrateKbps / 2, quality: $0.quality) }
        let percent = try #require(BDRate.percent(reference: three, test: test))
        #expect(abs(percent + 50) < 1e-6)
    }

    @Test("Qualità vicina al massimo: niente valori assurdi")
    func saturatedCurves() throws {
        // Jockey, spezzone di 1 s: il VMAF arriva quasi a 100 a più bitrate. Il polinomio di terzo
        // grado oscillerebbe (con numpy: circa +1e40 %); l'interpolazione monotona (PCHIP) dà circa −57 %,
        // come scipy.interpolate.PchipInterpolator sugli stessi punti.
        let hardware: [BDRate.Point] = [
            .init(bitrateKbps: 2800, quality: 80.0),
            .init(bitrateKbps: 5900, quality: 87.0),
            .init(bitrateKbps: 10500, quality: 99.6),
            .init(bitrateKbps: 20700, quality: 99.97),
        ]
        let software: [BDRate.Point] = [
            .init(bitrateKbps: 2400, quality: 88.9),
            .init(bitrateKbps: 5000, quality: 98.6),
            .init(bitrateKbps: 10000, quality: 99.93),
            .init(bitrateKbps: 19000, quality: 99.97),
        ]

        let percent = try #require(BDRate.percent(reference: hardware, test: software))
        #expect(abs(percent - (-57.23)) < 0.5)
    }

    @Test("Meno di 3 punti o qualità senza intervallo comune: nessun valore")
    func notComputable() {
        #expect(BDRate.percent(reference: Array(reference.prefix(2)), test: reference) == nil)

        let disjoint = reference.map { BDRate.Point(bitrateKbps: $0.bitrateKbps, quality: $0.quality - 50) }
        #expect(BDRate.percent(reference: reference, test: disjoint) == nil)
    }
}

/// Test unitari delle statistiche del VMAF: il 5° percentile e le dimensioni dell'ingrandimento a 1080p,
/// anche per i video verticali.
@MainActor
struct VMAFStatisticsTests {

    @Test("5° percentile con il metodo del rango più vicino")
    func percentile() {
        let values = (1...100).map(Double.init).shuffled()
        #expect(VideoQualityAnalysisResult.percentile(5, of: values) == 5)

        // Con 10 fotogrammi il 5% peggiore è il solo fotogramma peggiore.
        #expect(VideoQualityAnalysisResult.percentile(5, of: [90, 70, 95, 88, 91, 93, 94, 89, 92, 96]) == 70)
        #expect(VideoQualityAnalysisResult.percentile(5, of: []) == nil)
    }

    @Test("Ingrandimento: il lato corto diventa 1080, anche per i video verticali")
    func upscaleFilter() {
        #expect(QualityAnalysisService.upscaleFilter(width: 352, height: 288) == "scale=-2:1080:flags=bicubic")
        #expect(QualityAnalysisService.upscaleFilter(width: 720, height: 1280) == "scale=1080:-2:flags=bicubic")
    }
}

/// Test unitari dell'asse logaritmico dei bitrate (``LogBitrateAxis``): valori intermedi leggibili,
/// un dominio che contiene tutti i punti e il caso senza punti.
@MainActor
struct LogBitrateAxisTests {

    private func ticks(_ minimum: Double, _ maximum: Double) -> [Int] {
        LogBitrateAxis(bitratesKbps: [minimum, maximum]).ticks.map { Int($0.rounded()) }
    }

    @Test("Valori intermedi adatti all'ampiezza dell'intervallo")
    func ticks() {
        #expect(ticks(83, 690) == [100, 200, 300, 500, 700])
        #expect(ticks(900, 7600) == [1000, 2000, 3000, 5000, 7000])
        #expect(ticks(300, 600) == [300, 400, 500, 600])
        #expect(ticks(20, 5000) == [20, 50, 100, 200, 500, 1000, 2000, 5000])
    }

    @Test("Il dominio include tutti i punti, con un margine")
    func domain() {
        let axis = LogBitrateAxis(bitratesKbps: [83, 250, 690])
        #expect(axis.domain.lowerBound < 83)
        #expect(axis.domain.upperBound > 690)
        #expect(axis.ticks.allSatisfy { axis.domain.contains($0) })
    }

    @Test("Senza punti: un asse generico")
    func empty() {
        let axis = LogBitrateAxis(bitratesKbps: [])
        #expect(axis.ticks == [10, 100, 1000, 10_000])
    }
}

/// Test unitari dei calcoli sulle dimensioni dei fotogrammi (``FrameSizeStatistics``) e del conteggio
/// dei tipi di fotogramma, compresi frame rate non interi o non validi.
@MainActor
struct FrameSizeTests {

    @Test("Pacchetti in ordine di visualizzazione, come nei fotogrammi decodificati")
    func displayOrder() {
        // Pacchetti reali di una codifica x264 con 2 B-frame (istante in secondi, byte),
        // nell'ordine del file; FFprobe mostra i fotogrammi decodificati in questo ordine:
        // 2785, 447, 300, 634, 2519, 408, 314, 738.
        let packets: [(presentationTime: Double?, sizeBytes: Int)] = [
            (0.00, 2785), (0.12, 634), (0.04, 447), (0.08, 300),
            (0.16, 2519), (0.28, 738), (0.20, 408), (0.24, 314),
        ]

        #expect(FFprobeService.sizesInDisplayOrder(packets) == [2785, 447, 300, 634, 2519, 408, 314, 738])
    }

    @Test("Se manca un istante, resta l'ordine del file")
    func missingTimestamps() {
        let packets: [(presentationTime: Double?, sizeBytes: Int)] = [(0.08, 1), (nil, 2), (0.04, 3)]
        #expect(FFprobeService.sizesInDisplayOrder(packets) == [1, 2, 3])
    }

    @Test("Bitrate di ogni secondo, compreso l'ultimo secondo incompleto")
    func bitratePerSecond() {
        // 25 fps: un secondo da 1000 byte a fotogramma, uno da 500, poi 10 fotogrammi da 2000.
        let sizes = Array(repeating: 1000, count: 25) + Array(repeating: 500, count: 25) + Array(repeating: 2000, count: 10)
        let bitrates = FrameSizeStatistics.bitratePerSecondKbps(frameSizes: sizes, framesPerSecond: 25)

        #expect(bitrates == [200, 100, 400])
    }

    @Test("Frame rate non intero e frame rate non valido")
    func unusualFrameRates() {
        // A 29,97 fps i primi due secondi contengono 30 fotogrammi ciascuno.
        let bitrates = FrameSizeStatistics.bitratePerSecondKbps(frameSizes: Array(repeating: 1000, count: 60), framesPerSecond: 29.97)
        #expect(bitrates.count == 2)
        #expect(bitrates.allSatisfy { abs($0 - 239.76) < 0.001 })

        #expect(FrameSizeStatistics.bitratePerSecondKbps(frameSizes: [1000], framesPerSecond: 0).isEmpty)
    }

    @Test("Conteggio dei tipi di fotogramma")
    func frameTypeSummary() {
        let summary = VideoFrameTypeSummary(frameTypes: ["I", "B", "B", "P", "I", "?"])

        #expect(summary.iFrames == 2)
        #expect(summary.pFrames == 1)
        #expect(summary.bFrames == 2)
        #expect(summary.otherFrames == 1)
    }
}

/// Test delle regole che scelgono quali curve confrontare nel BD-rate e quali punti escludere:
/// software contro hardware, HEVC contro H.264, punti fuori obiettivo, una sola curva.
@MainActor
struct BDRateComparisonTests {

    /// Un punto di una curva con le impostazioni indicate.
    private func point(
        _ codec: VideoCodec, _ backend: EncodingBackend,
        targetKbps: Int, measuredKbps: Double, quality: Double
    ) -> QualityCurvePoint {
        var settings = EncodingSettings()
        settings.codec = codec
        settings.profile = codec == .hevc ? .main : .high
        settings.backend = backend
        settings.videoBitrateKbps = targetKbps
        settings = settings.withStandardPasses

        return QualityCurvePoint(
            id: UUID(),
            bitrateKbps: measuredKbps,
            value: quality,
            series: settings.curveSeriesName,
            target: settings.rateControlDescription,
            settings: settings
        )
    }

    /// Quattro punti di una curva, ciascuno con il bitrate misurato uguale all'obiettivo.
    private func curve(_ codec: VideoCodec, _ backend: EncodingBackend, shift: Double) -> [QualityCurvePoint] {
        [(500.0, 80.0), (1000, 88), (2000, 93), (4000, 96)].map { bitrate, quality in
            point(codec, backend, targetKbps: Int(bitrate * shift), measuredKbps: bitrate * shift, quality: quality)
        }
    }

    @Test("Software contro hardware dello stesso codec, HEVC contro H.264 dello stesso encoder")
    func pairs() throws {
        let points = curve(.h264, .hardware, shift: 1) + curve(.h264, .software, shift: 0.8)
            + curve(.hevc, .hardware, shift: 0.7) + curve(.hevc, .software, shift: 0.5)

        let comparisons = BDRate.comparisons(of: points)
        let pairs = Set(comparisons.map { "\($0.series) → \($0.reference)" })

        func name(_ codec: VideoCodec, _ backend: EncodingBackend) -> String {
            curve(codec, backend, shift: 1)[0].series
        }

        #expect(comparisons.count == 4)
        #expect(pairs.contains("\(name(.h264, .software)) → \(name(.h264, .hardware))"))
        #expect(pairs.contains("\(name(.hevc, .software)) → \(name(.hevc, .hardware))"))
        #expect(pairs.contains("\(name(.hevc, .hardware)) → \(name(.h264, .hardware))"))
        #expect(pairs.contains("\(name(.hevc, .software)) → \(name(.h264, .software))"))

        // Stessa qualità con l'80% del bitrate: −20%.
        let softwareH264 = try #require(comparisons.first { $0.series == name(.h264, .software) })
        #expect(abs((softwareH264.percent ?? 0) + 20) < 1e-6)
    }

    @Test("Fuori obiettivo oltre il 25% sopra; CRF e QP non lo sono mai")
    func offTarget() {
        #expect(point(.hevc, .hardware, targetKbps: 46, measuredKbps: 278, quality: 70).isOffTarget)
        #expect(!point(.hevc, .hardware, targetKbps: 1000, measuredKbps: 1200, quality: 90).isOffTarget)
        #expect(!point(.hevc, .hardware, targetKbps: 1000, measuredKbps: 600, quality: 90).isOffTarget)

        var settings = EncodingSettings()
        settings.backend = .software
        settings.rateControlMode = .constantQuality
        settings.videoBitrateKbps = 100

        let crf = QualityCurvePoint(
            id: UUID(), bitrateKbps: 5000, value: 95,
            series: settings.curveSeriesName, target: settings.rateControlDescription, settings: settings
        )
        #expect(!crf.isOffTarget)
    }

    @Test("I punti fuori obiettivo non entrano nel BD-rate")
    func offTargetExcluded() throws {
        // L'hardware non scende sotto 278 kb/s: il primo punto è fuori obiettivo, ne restano 3.
        var hardware = curve(.hevc, .hardware, shift: 1)
        hardware[0] = point(.hevc, .hardware, targetKbps: 46, measuredKbps: 278, quality: 70)
        // Anche il software con gli stessi 3 livelli di qualità, perché i due polinomi siano confrontabili esattamente.
        let software = Array(curve(.hevc, .software, shift: 0.8).dropFirst())

        let comparison = try #require(BDRate.comparisons(of: hardware + software).first)
        #expect(abs((comparison.percent ?? 0) + 20) < 1e-6)
        #expect(comparison.reason == nil)

        // Con due punti fuori obiettivo ne restano 2: non calcolabile, con il motivo.
        hardware[1] = point(.hevc, .hardware, targetKbps: 90, measuredKbps: 280, quality: 71)
        let failed = try #require(BDRate.comparisons(of: hardware + software).first)
        #expect(failed.percent == nil)
        #expect(failed.reason?.contains("entro l'obiettivo") == true)
    }

    @Test("Con una sola curva non c'è confronto")
    func singleCurve() {
        #expect(BDRate.comparisons(of: curve(.h264, .hardware, shift: 1)).isEmpty)
    }
}

// MARK: - Confronti per la relazione

/// Test delle regole della relazione (``QualityInsights``), costruiti a partire dalla specifica:
/// il criterio della codifica migliore scritto nella relazione, la classifica per VMAF medio
/// e l'ordine dei confronti. Comprendono i casi limite (nessuna codifica a VMAF 90, punti fuori obiettivo).
@MainActor
struct QualityInsightsTests {

    /// I punti di una curva, con il bitrate misurato uguale all'obiettivo salvo indicazione.
    private func curve(
        _ backend: EncodingBackend,
        _ values: [(target: Int, measured: Double, vmaf: Double)]
    ) -> [QualityCurvePoint] {
        values.map { value in
            var settings = EncodingSettings()
            settings.backend = backend
            settings.videoBitrateKbps = value.target
            settings = settings.withStandardPasses

            return QualityCurvePoint(
                id: UUID(),
                bitrateKbps: value.measured,
                value: value.vmaf,
                series: settings.curveSeriesName,
                target: settings.rateControlDescription,
                settings: settings
            )
        }
    }

    // Tennis, H.264: hardware e software agli stessi bitrate obiettivo.
    private var tennisHardwareH264: [QualityCurvePoint] {
        curve(.hardware, [(290, 290, 47.0), (580, 580, 59.7), (1200, 1200, 75.2), (2300, 2300, 87.9)])
    }

    private var tennisSoftwareH264: [QualityCurvePoint] {
        curve(.software, [(290, 290, 58.0), (580, 580, 71.5), (1200, 1200, 84.9), (2300, 2300, 93.7)])
    }

    @Test("Classifica per VMAF medio ai bitrate provati da tutte, senza i punti fuori obiettivo")
    func ranking() throws {
        // L'hardware non scende sotto 250 kb/s: i primi due punti sono fuori obiettivo e restano fuori,
        // e la classifica usa solo i bitrate in comune (340 e 680).
        let hardware = curve(.hardware, [(85, 250, 73.0), (170, 251, 73.4), (340, 340, 80.8), (680, 680, 90.2)])
        let software = curve(.software, [(85, 85, 66.2), (170, 170, 80.8), (340, 340, 89.0), (680, 680, 93.8)])

        let ranking = QualityInsights.ranking(of: hardware + software)

        #expect(ranking.map(\.series) == [software[0].series, hardware[0].series])
        let first = try #require(ranking.first)
        let last = try #require(ranking.last)
        #expect(abs(first.meanVMAF - 91.4) < 1e-9)
        #expect(abs(last.meanVMAF - 85.5) < 1e-9)
    }

    @Test("Codifica migliore: il bitrate più basso che arriva a VMAF 90 e, lì, il VMAF più alto")
    func bestEncoding() throws {
        // A 2300 kb/s solo il software arriva a 90 (93,7); l'hardware si ferma a 87,9.
        let best = try #require(QualityInsights.bestEncoding(of: tennisHardwareH264 + tennisSoftwareH264))

        #expect(best.reachesGoodQuality)
        #expect(best.point.series == tennisSoftwareH264[0].series)
        #expect(best.point.targetKbps == 2300)

        // A 1600 kb/s arrivano a 90 entrambi: vince il VMAF più alto, non il bitrate misurato più basso.
        let sintel = curve(.hardware, [(810, 800, 82.3), (1600, 1550, 90.7)]) + curve(.software, [(810, 825, 88.8), (1600, 1600, 94.5)])
        let sintelBest = try #require(QualityInsights.bestEncoding(of: sintel))

        #expect(sintelBest.point.value == 94.5)
    }

    @Test("Nessuna codifica a VMAF 90: vale la codifica con il VMAF più alto")
    func bestEncodingBelowThreshold() throws {
        let points = curve(.hardware, [(500, 500, 40.0), (1000, 1000, 60.0)]) + curve(.software, [(500, 500, 45.0), (1000, 1000, 70.0)])
        let best = try #require(QualityInsights.bestEncoding(of: points))

        #expect(!best.reachesGoodQuality)
        #expect(best.point.value == 70)
    }

    @Test("Nomi brevi per la tabella, solo se non si confondono")
    func shortNames() {
        var hevc = EncodingSettings()
        hevc.codec = .hevc
        hevc.profile = .main

        let names = QualityInsights.shortSeriesNames([tennisHardwareH264[0].settings, tennisSoftwareH264[0].settings, hevc])
        #expect(names[tennisHardwareH264[0].series] == "H.264 hw")
        #expect(names[tennisSoftwareH264[0].series] == "H.264 sw")
        #expect(names[hevc.curveSeriesName] == "HEVC hw")

        // Stesso codec ed encoder, GOP diversi: i nomi brevi coinciderebbero, quindi niente nomi brevi.
        var longGOP = tennisHardwareH264[0].settings
        longGOP.gopSize = 250
        #expect(QualityInsights.shortSeriesNames([tennisHardwareH264[0].settings, longGOP]).isEmpty)
    }

    @Test("Ordine dei confronti: per bitrate obiettivo, poi H.264 prima di HEVC e hardware prima di software")
    func comparisonOrder() {
        func settings(_ codec: VideoCodec, _ backend: EncodingBackend, _ kbps: Int) -> (settings: EncodingSettings, measuredKbps: Double?) {
            var settings = EncodingSettings()
            settings.codec = codec
            settings.profile = codec == .hevc ? .main : .high
            settings.backend = backend
            settings.videoBitrateKbps = kbps
            return (settings, Double(kbps) * 1.05)
        }

        let shuffled = [
            settings(.hevc, .software, 100), settings(.h264, .software, 200), settings(.h264, .hardware, 100),
            settings(.hevc, .hardware, 100), settings(.h264, .software, 100), settings(.h264, .hardware, 200)
        ]

        let ordered = shuffled.sorted(by: EncodingSettings.comparisonOrder).map {
            "\($0.settings.codec.rawValue) \($0.settings.backend.rawValue) \($0.settings.videoBitrateKbps)"
        }

        #expect(ordered == [
            "h264 hardware 100", "h264 software 100", "hevc hardware 100", "hevc software 100",
            "h264 hardware 200", "h264 software 200"
        ])
    }
}
