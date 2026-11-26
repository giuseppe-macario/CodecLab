// EncodingTests.swift
// Impostazioni di codifica: scala dei bitrate e codifica di prova di «Crea serie», formati dei pixel,
// argomenti passati a FFmpeg.
//
// Strategia di verifica
// ---------------------
// Test unitari, senza eseguire FFmpeg.
//
// - Scala dei bitrate: test a scatola chiusa sui valori calcolati, con casi ai limiti
//   (bitrate minimo, scala abbassata sotto il bitrate dell'originale) e un test parametrico che
//   controlla le stesse proprietà su ingressi diversi.
// - Argomenti di FFmpeg e due passate: test a scatola bianca, cioè scritti conoscendo il codice:
//   verificano la riga di comando prodotta per ogni combinazione di encoder e controllo del bitrate.
//   È un test di contratto con FFmpeg: se gli argomenti sono quelli attesi, la codifica fa ciò che
//   l'app dichiara; che FFmpeg li esegua correttamente è invece verificato a mano, usando l'app.

import Foundation
import Testing
@testable import CodecLab

/// Test unitari della serie di «Crea serie» (``ComparisonSeries``) e della codifica di prova (``ComplexityProbe``).
///
/// Verificano a scatola chiusa la scala dei bitrate, con i casi ai limiti (valore minimo,
/// scala abbassata sotto il bitrate dell'originale), e con un test parametrico che le proprietà
/// della scala valgano su ingressi molto diversi. Per la codifica di prova controllano i campioni
/// scelti e gli argomenti di FFmpeg.
@MainActor
struct ComparisonSeriesTests {

    @Test("Metà, lo stesso, il doppio e il quadruplo del bitrate della prova")
    func ladder() {
        #expect(ComparisonSeries.bitratesKbps(referenceKbps: 1500, sourceBitrateKbps: nil) == [750, 1500, 3000, 6000])
        #expect(ComparisonSeries.bitratesKbps(referenceKbps: 183, sourceBitrateKbps: nil) == [92, 180, 370, 730])
    }

    @Test("La scala si abbassa se supera il bitrate dell'originale")
    func cappedBySource() {
        // Il quadruplo di 1000 supererebbe i 1500 kb/s dell'originale: tutto scala di 1500/4000.
        #expect(ComparisonSeries.bitratesKbps(referenceKbps: 1000, sourceBitrateKbps: 1500) == [190, 380, 750, 1500])
    }

    @Test("Minimo di 10 kb/s, senza valori ripetuti")
    func tinyVideo() {
        #expect(ComparisonSeries.bitratesKbps(referenceKbps: 12, sourceBitrateKbps: nil) == [10, 20, 40, 80])
    }

    @Test(
        "Quattro valori distinti, ognuno almeno 1,8 volte il precedente",
        arguments: [(8.0, nil), (95.0, Optional(60.0)), (733.0, nil), (12_345.0, Optional(20_000.0))] as [(Double, Double?)]
    )
    func spacing(reference: Double, source: Double?) {
        let bitrates = ComparisonSeries.bitratesKbps(referenceKbps: reference, sourceBitrateKbps: source)

        #expect(bitrates.count == 4)
        #expect(bitrates.allSatisfy { $0 >= 10 })

        for (previous, next) in zip(bitrates, bitrates.dropFirst()) {
            #expect(Double(next) >= Double(previous) * 1.8)
        }
    }

    @Test("Codifica di prova: video breve per intero, lungo in tre campioni al centro dei terzi")
    func probeSamples() {
        let short = ComplexityProbe.samples(start: 0, duration: 10)
        #expect(short == [ClipRange(startSeconds: 0, durationSeconds: 10)])

        // 60 s: centri a 10, 30 e 50 s, campioni da 5 s.
        let long = ComplexityProbe.samples(start: 0, duration: 60)
        #expect(long.map(\.startSeconds) == [7.5, 27.5, 47.5])
        #expect(long.allSatisfy { $0.durationSeconds == 5 })

        // Con uno spezzone da 100 a 160 s, i campioni stanno dentro lo spezzone.
        #expect(ComplexityProbe.samples(start: 100, duration: 60).map(\.startSeconds) == [107.5, 127.5, 147.5])
    }

    @Test("Codifica di prova: solo video, x264 CRF 23 veryfast, flusso H.264 senza contenitore")
    func probeArguments() {
        let arguments = ComplexityProbe.arguments(
            sourceURL: URL(fileURLWithPath: "/tmp/originale.y4m"),
            sample: ClipRange(startSeconds: 7.5, durationSeconds: 5),
            destinationURL: URL(fileURLWithPath: "/tmp/prova.h264")
        )
        let joined = arguments.joined(separator: " ")

        #expect(joined.contains("-ss 7.5 -t 5.0 -i /tmp/originale.y4m"))
        #expect(joined.contains("-map 0:v:0 -an"))
        #expect(joined.contains("-c:v libx264 -preset veryfast -crf 23"))
        #expect(joined.hasSuffix("-f h264 /tmp/prova.h264"))
    }

    @Test("Otto impostazioni: lo stesso codec via hardware (una passata) e via software (due passate)")
    func seriesSettings() {
        var base = EncodingSettings()
        base.codec = .hevc
        base.profile = .main10
        base.rateControlMode = .constantQuality
        base.gopSize = 50

        let settings = ComparisonSeries.settings(from: base, bitratesKbps: [100, 200, 400, 800])

        #expect(settings.count == 8)
        #expect(settings.allSatisfy { $0.codec == .hevc && $0.profile == .main10 && $0.gopSize == 50 })
        #expect(settings.allSatisfy { $0.rateControlMode == .bitrate })
        #expect(settings.prefix(4).allSatisfy { $0.backend == .hardware && !$0.usesTwoPass })
        #expect(settings.suffix(4).allSatisfy { $0.backend == .software && $0.usesTwoPass })
        #expect(settings.map(\.videoBitrateKbps) == [100, 200, 400, 800, 100, 200, 400, 800])
    }

    @Test("Passate stabilite da CodecLab: due solo via software con il controllo a bitrate")
    func standardPasses() {
        var settings = EncodingSettings()
        settings.backend = .software
        #expect(settings.withStandardPasses.usesTwoPass)

        settings.rateControlMode = .constantQuality
        #expect(settings.withStandardPasses.twoPass == nil)

        settings.rateControlMode = .bitrate
        settings.backend = .hardware
        #expect(settings.withStandardPasses.twoPass == nil)
    }
}

/// Test unitari delle impostazioni di codifica (``EncodingSettings``): formato dei pixel,
/// controllo del bitrate con VideoToolbox, nome della curva e argomenti dello spezzone.
@MainActor
struct EncodingSettingsTests {

    @Test("Formato dei pixel: 10 bit solo per HEVC Main 10")
    func pixelFormat() {
        var settings = EncodingSettings()
        #expect(settings.pixelFormat == "yuv420p")
        #expect(settings.analysisPixelFormat == "yuv420p")

        settings.codec = .hevc
        settings.profile = .main10
        settings.backend = .hardware
        #expect(settings.pixelFormat == "p010le")

        settings.backend = .software
        #expect(settings.pixelFormat == "yuv420p10le")
        #expect(settings.analysisPixelFormat == "yuv420p10le")
    }

    @Test("Con VideoToolbox vale sempre il controllo a bitrate")
    func hardwareUsesBitrate() {
        var settings = EncodingSettings()
        settings.rateControlMode = .constantQuality
        settings.backend = .hardware
        #expect(settings.effectiveRateControlMode == .bitrate)

        settings.backend = .software
        #expect(settings.effectiveRateControlMode == .constantQuality)
        #expect(settings.rateControlDescription == "Controllo rate: CRF 23")
    }

    @Test("Prove che differiscono solo per il bitrate stanno sulla stessa curva")
    func curveSeriesName() {
        var low = EncodingSettings()
        low.videoBitrateKbps = 500
        var high = low
        high.videoBitrateKbps = 2000
        #expect(low.curveSeriesName == high.curveSeriesName)

        var other = low
        other.codec = .hevc
        other.profile = .main
        #expect(low.curveSeriesName != other.curveSeriesName)
    }

    @Test("Spezzone: argomenti di FFmpeg prima di -i")
    func clipArguments() {
        let clip = ClipRange(startSeconds: 12.5, durationSeconds: 20)
        #expect(clip.inputArguments == ["-ss", "12.5", "-t", "20.0"])
    }
}

/// Test a scatola bianca degli argomenti passati a FFmpeg (``EncodingService``).
///
/// Per ogni combinazione di encoder e controllo del bitrate si verifica la riga di comando prodotta,
/// senza eseguirla: è il contratto tra CodecLab e FFmpeg.
@MainActor
struct FFmpegArgumentsTests {
    private let source = URL(fileURLWithPath: "/tmp/sorgente.mov")
    private let destination = URL(fileURLWithPath: "/tmp/.uscita.mp4.partial")

    private func arguments(_ settings: EncodingSettings, csvURL: URL? = nil) -> [String] {
        EncodingService.arguments(settings: settings, sourceURL: source, destinationURL: destination, csvURL: csvURL)
    }

    /// Il valore che segue un'opzione, per esempio "23" dopo "-crf".
    private func value(after option: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: option).flatMap { index in
            arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        }
    }

    @Test("x264 con CRF: log di debug per il QP, B-frame e preset")
    func softwareH264() {
        var settings = EncodingSettings()
        settings.backend = .software
        settings.rateControlMode = .constantQuality
        settings.crfValue = 30
        settings.bFrameCount = 2

        let arguments = arguments(settings)

        #expect(value(after: "-loglevel", in: arguments) == "level+debug")
        #expect(value(after: "-c:v", in: arguments) == "libx264")
        #expect(value(after: "-crf", in: arguments) == "30")
        #expect(value(after: "-bf", in: arguments) == "2")
        #expect(value(after: "-preset", in: arguments) == "medium")
        #expect(value(after: "-pix_fmt", in: arguments) == "yuv420p")
        #expect(!arguments.contains("-b:v"))
        #expect(!arguments.contains("-allow_sw"))
        #expect(arguments.last == destination.path)
    }

    @Test("CRF, QP e B-frame vengono limitati ai valori ammessi")
    func clamping() {
        var settings = EncodingSettings()
        settings.backend = .software
        settings.rateControlMode = .constantQuantizer
        settings.quantizerValue = 80
        settings.bFrameCount = 40

        let arguments = arguments(settings)

        #expect(value(after: "-qp", in: arguments) == "51")
        #expect(value(after: "-bf", in: arguments) == "16")
    }

    @Test("VideoToolbox HEVC: bitrate, niente ripiego software, tag hvc1")
    func hardwareHEVC() {
        var settings = EncodingSettings()
        settings.codec = .hevc
        settings.profile = .main10
        settings.backend = .hardware
        settings.rateControlMode = .constantQuality   // Ignorato via hardware
        settings.videoBitrateKbps = 2500

        let arguments = arguments(settings)

        #expect(value(after: "-loglevel", in: arguments) == "error")
        #expect(value(after: "-b:v", in: arguments) == "2500k")
        #expect(value(after: "-allow_sw", in: arguments) == "0")
        #expect(value(after: "-tag:v", in: arguments) == "hvc1")
        #expect(value(after: "-pix_fmt", in: arguments) == "p010le")
        #expect(!arguments.contains("-crf"))
        #expect(!arguments.contains("-bf"))
    }

    @Test("Lo spezzone va prima del file di ingresso")
    func clipBeforeInput() throws {
        var settings = EncodingSettings()
        settings.clip = ClipRange(startSeconds: 30, durationSeconds: 10)

        let arguments = arguments(settings)
        let seek = try #require(arguments.firstIndex(of: "-ss"))
        let input = try #require(arguments.firstIndex(of: "-i"))

        #expect(seek < input)
        #expect(value(after: "-i", in: arguments) == source.path)
    }

    @Test("x265: il CSV del QP per fotogramma")
    func hevcCSV() {
        var settings = EncodingSettings()
        settings.codec = .hevc
        settings.profile = .main
        settings.backend = .software

        let csv = URL(fileURLWithPath: "/tmp/qp.csv")
        let arguments = arguments(settings, csvURL: csv)

        #expect(value(after: "-c:v", in: arguments) == "libx265")
        #expect(value(after: "-x265-params", in: arguments) == "csv=/tmp/qp.csv:csv-log-level=1")
    }

    @Test("Audio copiato o ricodificato in AAC")
    func audio() {
        var settings = EncodingSettings()
        #expect(value(after: "-c:a", in: arguments(settings)) == "copy")

        settings.audioMode = .aac
        settings.audioBitrateKbps = 96
        let arguments = arguments(settings)
        #expect(value(after: "-c:a", in: arguments) == "aac")
        #expect(value(after: "-b:a", in: arguments) == "96k")
    }
}

/// Test a scatola bianca della codifica in due passate: quando si usa (solo via software, con il controllo
/// a bitrate) e quali argomenti ricevono x264 e x265 nella prima e nella seconda passata.
@MainActor
struct TwoPassTests {
    private let source = URL(fileURLWithPath: "/tmp/sorgente.mov")
    private let destination = URL(fileURLWithPath: "/tmp/.uscita.mp4.partial")

    private func value(after option: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: option).flatMap { index in
            arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        }
    }

    private func softwareSettings(_ codec: VideoCodec) -> EncodingSettings {
        var settings = EncodingSettings()
        settings.codec = codec
        settings.profile = codec == .hevc ? .main : .high
        settings.backend = .software
        settings.twoPass = true
        return settings
    }

    @Test("Due passate solo via software e con il controllo a bitrate")
    func availability() {
        var settings = softwareSettings(.h264)
        #expect(settings.usesTwoPass)
        #expect(settings.rateControlDescription == "Bitrate obiettivo: 1000 kb/s (due passate)")

        settings.rateControlMode = .constantQuality
        #expect(!settings.usesTwoPass)

        settings = softwareSettings(.h264)
        settings.backend = .hardware
        #expect(!settings.usesTwoPass)

        // Le prove in una e in due passate stanno su curve diverse.
        var onePass = softwareSettings(.h264)
        onePass.twoPass = nil
        #expect(onePass.curveSeriesName != softwareSettings(.h264).curveSeriesName)
    }

    @Test("x264, prima passata: solo video, statistiche, nessun file prodotto")
    func x264FirstPass() {
        let stats = URL(fileURLWithPath: "/tmp/stats/x264")
        let arguments = EncodingService.arguments(
            settings: softwareSettings(.h264), sourceURL: source, destinationURL: destination,
            csvURL: nil, twoPass: .init(number: 1, statsURL: stats)
        )

        #expect(value(after: "-pass", in: arguments) == "1")
        #expect(value(after: "-passlogfile", in: arguments) == stats.path)
        #expect(value(after: "-loglevel", in: arguments) == "error")
        #expect(!arguments.contains("0:a?"))
        #expect(Array(arguments.suffix(3)) == ["-f", "null", "-"])
    }

    @Test("x264, seconda passata: file prodotto e log del QP")
    func x264SecondPass() {
        let stats = URL(fileURLWithPath: "/tmp/stats/x264")
        let arguments = EncodingService.arguments(
            settings: softwareSettings(.h264), sourceURL: source, destinationURL: destination,
            csvURL: nil, twoPass: .init(number: 2, statsURL: stats)
        )

        #expect(value(after: "-pass", in: arguments) == "2")
        #expect(value(after: "-loglevel", in: arguments) == "level+debug")
        #expect(arguments.contains("0:a?"))
        #expect(arguments.last == destination.path)
    }

    @Test("x265: passata e statistiche nelle sue opzioni, insieme al CSV del QP")
    func x265SecondPass() {
        let arguments = EncodingService.arguments(
            settings: softwareSettings(.hevc), sourceURL: source, destinationURL: destination,
            csvURL: URL(fileURLWithPath: "/tmp/qp.csv"),
            twoPass: .init(number: 2, statsURL: URL(fileURLWithPath: "/tmp/stats/x265.log"))
        )

        #expect(value(after: "-x265-params", in: arguments) == "csv=/tmp/qp.csv:csv-log-level=1:pass=2:stats=/tmp/stats/x265.log")
        #expect(!arguments.contains("-pass"))
    }
}
