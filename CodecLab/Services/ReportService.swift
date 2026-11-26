// ReportService.swift
// Relazione su un file originale: i dati di file, esperimenti video, analisi qualità e audio,
// scritta a parole da CodecLab: fatti, classifica per VMAF medio e codifica migliore secondo un criterio dichiarato.

import Foundation

// MARK: - Contenuto della relazione

/// Una tabella della relazione, per esempio il VMAF per bitrate obiettivo, con la sua versione in Markdown.
struct ReportTable: Equatable {
    /// Il titolo, mostrato sopra la tabella; `nil` se basta quello della sezione.
    var title: String? = nil
    /// Le intestazioni delle colonne.
    let headers: [String]
    /// Le righe, con una cella per colonna.
    let rows: [[String]]
    /// Una nota sotto la tabella, per esempio il significato delle celle.
    var note: String? = nil

    /// La tabella in Markdown.
    var markdown: String {
        // Il carattere "|" separa le celle: dentro una cella va preceduto da "\".
        func line(_ cells: [String]) -> String {
            "| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |"
        }

        var lines: [String] = []

        if let title {
            lines += ["**\(title)**", ""]
        }

        lines.append(line(headers))
        lines.append("|" + String(repeating: " --- |", count: headers.count))
        lines += rows.map(line)

        if let note {
            lines += ["", "_\(note)_"]
        }

        return lines.joined(separator: "\n")
    }
}

/// Una sezione della relazione (File originale, Esperimenti video, Qualità, Audio): paragrafi scritti
/// da CodecLab con i valori misurati e, se serve, una tabella.
struct ReportSection: Identifiable {
    /// Il titolo, che fa anche da identificativo.
    let title: String
    /// I paragrafi, composti da CodecLab: frasi già pronte con i valori calcolati, quindi sempre esatte.
    var paragraphs: [String] = []
    /// Le tabelle, dopo i paragrafi: poche, solo dove aiutano a leggere.
    var tables: [ReportTable] = []

    /// Il titolo della sezione.
    var id: String { title }
}

/// La relazione su un file originale: il riassunto, in italiano, di tutto il lavoro fatto su quel file.
///
/// Si legge nella sezione Relazioni e si può copiare o salvare in Markdown. Contiene le sezioni
/// e, in fondo, la codifica migliore tra quelle provate con il criterio usato per sceglierla.
struct AnalysisReport {
    /// Il nome del file originale.
    let sourceName: String
    /// La data di creazione.
    let createdAt: Date
    /// Le sezioni, nell'ordine in cui si leggono.
    var sections: [ReportSection]
    /// La raccomandazione finale, calcolata da CodecLab e messa in evidenza in fondo alla relazione.
    var recommendation: String? = nil
    /// Il criterio con cui è stata scelta la codifica migliore, in un paragrafo a parte e con meno risalto;
    /// `nil` se nessuna codifica raggiunge la soglia (la scelta è allora la più alta, e lo dice già la raccomandazione).
    var recommendationCriterion: String? = nil

    /// La relazione in Markdown, per copiarla o salvarla.
    var markdown: String {
        var parts = [
            "# Relazione su \(sourceName)",
            "_Generata da CodecLab il \(createdAt.formatted(date: .long, time: .shortened))._"
        ]

        for section in sections {
            parts.append("## \(section.title)")
            parts += section.paragraphs
            parts += section.tables.map(\.markdown)
        }

        // La raccomandazione chiude la relazione, in evidenza.
        if let recommendation {
            var quote = "> **Codifica migliore tra quelle provate.** \(recommendation)"
            if let recommendationCriterion {
                // Un nuovo paragrafo nello stesso riquadro, in corsivo: si legge come una nota.
                quote += "\n>\n> _\(recommendationCriterion)_"
            }
            parts.append(quote)
        }

        // Una riga vuota tra i blocchi, come richiede il Markdown per separare paragrafi e tabelle.
        return parts.joined(separator: "\n\n") + "\n"
    }
}

// MARK: - Raccolta dei dati

/// La scrittura della relazione a partire dai dati salvati: tutto il testo è composto da CodecLab
/// con i valori misurati.
///
/// La relazione riporta fatti e applica un solo criterio, dichiarato: descrive il file originale
/// e le codifiche fatte, riporta la classifica per VMAF medio, i tempi e una tabella, e indica
/// la codifica migliore tra quelle provate (vedi ``QualityInsights``). Si aggiorna da sola
/// quando cambiano esperimenti o analisi.
enum ReportBuilder {

    /// Prepara la relazione su un file originale.
    ///
    /// Le sezioni senza dati (per esempio l'audio, se non ci sono esperimenti audio) vengono omesse.
    ///
    /// - Parameters:
    ///   - sourceName: Il nome del file originale.
    ///   - item: L'elemento della Libreria, se c'è ancora.
    ///   - document: Le informazioni lette ora da FFprobe; `nil` se il file non è raggiungibile.
    ///   - fileFingerprint: L'impronta attuale del file: le analisi salvate del video originale si usano
    ///     solo se corrispondono; `nil` se il file non è raggiungibile (si usano quelle salvate).
    ///   - experiments: Gli esperimenti video del file.
    ///   - analyses: Le analisi di quegli esperimenti.
    ///   - audioExperiments: Gli esperimenti audio del file.
    /// - Returns: La relazione, con la codifica migliore tra quelle provate, se c'è.
    static func report(
        sourceName: String,
        item: MediaLibraryItem?,
        document: FFprobeDocument?,
        fileFingerprint: FileFingerprint? = nil,
        experiments: [EncodingExperiment],
        analyses: [VideoQualityAnalysisResult],
        audioExperiments: [AudioExperiment]
    ) -> AnalysisReport {
        var sections = [sourceSection(item: item, document: document, fileFingerprint: fileFingerprint)]

        if let section = experimentsSection(experiments, sourceDuration: document?.format?.durationSeconds) {
            sections.append(section)
        }

        let quality = qualitySection(experiments: experiments, analyses: analyses)

        if let section = quality?.section {
            sections.append(section)
        }

        if let section = audioSection(audioExperiments, video: item?.video) {
            sections.append(section)
        }

        return AnalysisReport(
            sourceName: sourceName,
            createdAt: Date(),
            sections: sections,
            recommendation: quality?.bestEncoding,
            recommendationCriterion: quality?.criterion
        )
    }

    // MARK: File originale

    /// Il file originale: che video è, che cosa significa come punto di partenza e, se è stato analizzato
    /// nella Libreria, SI e TI e (per un originale già compresso) la struttura dei fotogrammi.
    private static func sourceSection(item: MediaLibraryItem?, document: FFprobeDocument?, fileFingerprint: FileFingerprint?) -> ReportSection {
        let streams = document?.streams ?? []
        let videoStream = streams.first { $0.codecType == "video" && !$0.isAttachedPicture }
        let audioStream = streams.first { $0.codecType == "audio" }
        let isUncompressed = item?.video?.isUncompressed == true

        var paragraphs: [String] = []

        if document == nil {
            paragraphs.append("Il file originale non è raggiungibile: i dati vengono dalla Libreria.")
        }

        // Un file solo audio, per esempio un MP3: "Il file originale è un file audio mp3, 44100 Hz, 2 canali, 128 kb/s, lungo 2:04."
        if videoStream == nil, item?.video == nil, let audioStream {
            var parts = [streamCodecName(audioStream)]
            if let sampleRate = audioStream.sampleRateHz { parts.append("\(sampleRate) Hz") }
            if let channels = audioStream.channels { parts.append("\(channels) canali") }
            if let bitrate = audioStream.bitRateBitsPerSecond { parts.append(MediaValueFormatter.bitRate(bitrate)) }

            paragraphs.append("Il file originale è un file audio " + parts.joined(separator: ", ") +
                (document?.format?.durationSeconds.map { ", lungo \(timeText($0))" } ?? "") + ".")

            return ReportSection(title: "File originale", paragraphs: paragraphs)
        }

        // "Il file originale è un video non compresso 352×288 a 30 fps, lungo 0:09, senza audio."
        var description = "Il file originale è un video " +
            (isUncompressed ? "non compresso" : videoStream.map(streamCodecName) ?? "compresso")

        if let width = videoStream?.width ?? item?.video?.width, let height = videoStream?.height ?? item?.video?.height {
            description += " \(width)×\(height)"
        }

        if let fps = videoStream?.frameRate ?? item?.video?.framesPerSecond {
            description += " a \(fps.formatted(.number.precision(.fractionLength(0...3)))) fps"
        }

        if let duration = document?.format?.durationSeconds {
            description += ", lungo \(timeText(duration))"
        }

        if let audioStream {
            description += ", con audio \(streamCodecName(audioStream))" + (audioStream.channels.map { " a \($0) canali" } ?? "")
        } else if document != nil {
            description += ", senza audio"
        }

        paragraphs.append(description + ".")

        // Per un originale già compresso conviene ricordare che i suoi difetti restano nelle codifiche.
        if !isUncompressed, let bitrate = videoStream?.bitRateBitsPerSecond ?? item?.video?.bitrateBitsPerSecond {
            paragraphs.append("È già compresso, a \(MediaValueFormatter.bitRate(bitrate)): i suoi difetti restano anche nelle codifiche, " +
                "e le metriche misurano la distanza da questo file, non da un'immagine perfetta.")
        }

        // Le analisi della Libreria valgono solo se il file non è cambiato da allora
        // (se non è raggiungibile, non si può verificare: si usano quelle salvate).
        func isCurrent(_ file: FileFingerprint) -> Bool {
            fileFingerprint.map { $0 == file } ?? true
        }

        // Per un originale non compresso la struttura sarebbe sempre «100% I»: non serve dirlo.
        if !isUncompressed, let scan = item?.frameTypeScan, isCurrent(scan.file), scan.frameTypes.totalFrames > 0 {
            paragraphs.append(frameStructureSentence(scan.frameTypes))
        }

        if let measurement = item?.spatialTemporalMeasurement, isCurrent(measurement.file) {
            let summary = measurement.summary
            paragraphs.append(
                "SI (dettaglio): mediana \(decimal(summary.siMedian, 1)), massimo \(decimal(summary.siMax, 1)). " +
                "TI (variazione tra fotogrammi): mediana \(decimal(summary.tiMedian, 1)), massimo \(decimal(summary.tiMax, 1)). " +
                "Valori secondo ITU-T P.910, sulla luminanza a 8 bit e alla risoluzione originale."
            )
        }

        return ReportSection(title: "File originale", paragraphs: paragraphs)
    }

    /// La struttura dei fotogrammi dell'originale, per esempio "Contiene 300 fotogrammi: 2% I, 33% P, 65% B."
    private static func frameStructureSentence(_ frames: VideoFrameTypeSummary) -> String {
        var parts = [
            "\(percent(frames.iPercentage)) I",
            "\(percent(frames.pPercentage)) P",
            "\(percent(frames.bPercentage)) B"
        ]

        if frames.otherFrames > 0 {
            parts.append(frames.otherFrames == 1 ? "1 di altro tipo" : "\(frames.otherFrames) di altro tipo")
        }

        return "Contiene \(frames.totalFrames) fotogrammi: " + parts.joined(separator: ", ") + "."
    }

    /// Il codec di una traccia con il profilo, per esempio "H.264 / AVC (High)".
    private static func streamCodecName(_ stream: FFprobeStream) -> String {
        let name = stream.codecName == nil ? "di formato sconosciuto" : stream.codecDisplayName
        return stream.profile.map { "\(name) (\($0))" } ?? name
    }

    // MARK: Esperimenti video

    /// Le codifiche video a parole: serie, codifica di prova, esperimenti singoli.
    ///
    /// - Parameters:
    ///   - experiments: Gli esperimenti video del file.
    ///   - sourceDuration: La durata del file originale, per dire su che cosa è stata fatta la prova; `nil` se non è nota.
    private static func experimentsSection(_ experiments: [EncodingExperiment], sourceDuration: Double?) -> ReportSection? {
        guard !experiments.isEmpty else { return nil }

        var paragraphs: [String] = []

        // Che cosa è stato codificato.
        var overview = seriesDescriptions(experiments)

        // Il bitrate della codifica di prova: di solito uno solo, perché la prova sullo stesso video dà lo stesso valore.
        let references = Set(experiments.compactMap { $0.seriesReferenceKbps.map { Int($0.rounded()) } }).sorted()

        if !references.isEmpty {
            // In kb/s senza arrotondare a Mb/s: è il valore da cui si ricavano i bitrate della serie.
            let values = list(references.map { "\($0) kb/s" })

            // Su che cosa è stata fatta la prova: la parte del video della serie, intera o in tre campioni.
            let seriesDuration = experiments.first { $0.seriesReferenceKbps != nil }?.settings.clip?.durationSeconds ?? sourceDuration
            let sampled = seriesDuration.map { ComplexityProbe.samples(start: 0, duration: $0).count > 1 }
            let coverage = switch sampled {
            case .some(true): "su tre campioni da \(Int(ComplexityProbe.sampleSeconds)) secondi presi al centro di ciascun terzo del video"
            case .some(false): "sull'intero video"
            case .none: "sull'intero video, o su tre campioni da \(Int(ComplexityProbe.sampleSeconds)) secondi se dura più di \(Int(ComplexityProbe.wholeVideoLimitSeconds)) secondi"
            }

            // Se il quadruplo superava il bitrate dell'originale, la scala è stata abbassata in proporzione
            // (vedi ``ComparisonSeries/bitratesKbps(referenceKbps:sourceBitrateKbps:)``): va detto, perché
            // altrimenti «la metà di questo valore» non corrisponderebbe ai bitrate elencati.
            let seriesExperiments = experiments.filter { $0.seriesReferenceKbps != nil }
            let isScaledDown = seriesExperiments.contains { experiment in
                guard let reference = experiment.seriesReferenceKbps, reference > 0 else { return false }
                let highest = seriesExperiments
                    .filter { $0.seriesID == experiment.seriesID }
                    .map { Double($0.settings.videoBitrateKbps) }
                    .max() ?? 0
                return highest < 0.8 * (ComparisonSeries.referenceMultipliers.last ?? 4) * reference
            }

            let series = Set(experiments.compactMap(\.seriesID)).count > 1
                ? "; le serie sono state codificate usando"
                : "; la serie è stata codificata usando"

            let scale = isScaledDown
                ? "; il quadruplo avrebbe però superato il bitrate dell'originale, oltre il quale non c'è qualità da recuperare, " +
                  "quindi la scala è stata abbassata in proporzione" + series +
                  " come valore più alto il bitrate dell'originale e, sotto, la metà, un quarto e un ottavo, arrotondati."
                : series + " la metà di questo valore, lo stesso, il doppio e il quadruplo, arrotondati."

            overview.append(
                "I bitrate sono calcolati a partire da una codifica di prova \(coverage), effettuata con la libreria libx264 " +
                "tramite FFmpeg, in modalità a qualità costante (CRF \(ComplexityProbe.crf), preset \(ComplexityProbe.preset)). " +
                (references.count == 1 ? "Con questa codifica il video ha richiesto in media \(values)" : "Con questa codifica le serie hanno richiesto in media \(values)") +
                scale
            )
        }

        let singles = experiments.filter { $0.seriesID == nil }.count

        if singles > 0 {
            // «inoltre» solo se prima si è parlato delle serie.
            let also = overview.isEmpty ? "" : " inoltre"
            overview.append(singles == 1 ? "C'è\(also) un esperimento singolo." : "Ci sono\(also) \(singles) esperimenti singoli.")
        }

        let pending = experiments.filter { $0.status != .completed }.count

        if pending > 0 {
            overview.append(pending == 1 ? "Un esperimento non è ancora stato codificato." : "\(pending) esperimenti non sono ancora stati codificati.")
        }

        let clips = Set(experiments.compactMap { $0.settings.clip?.description })
        overview += clips.sorted().map { "Le codifiche lavorano su una parte del video (\($0.lowercased()))." }

        paragraphs.append(overview.joined(separator: " "))

        return ReportSection(title: "Esperimenti video", paragraphs: paragraphs)
    }

    /// Una frase per ogni serie di confronto, per esempio
    /// "Una serie hardware / software con H.265 / HEVC Main, a 260, 520, 1000 e 2100 kb/s."
    private static func seriesDescriptions(_ experiments: [EncodingExperiment]) -> [String] {
        let series = Dictionary(grouping: experiments.filter { $0.seriesID != nil }, by: { $0.seriesID ?? UUID() })
            .values
            .sorted { ($0.map(\.createdAt).min() ?? .distantPast) < ($1.map(\.createdAt).min() ?? .distantPast) }

        // Che cosa confronta ogni serie e a quali bitrate; le serie dello stesso tipo e con gli stessi
        // bitrate (per esempio una H.264 e una HEVC dopo la stessa prova) vanno in una frase sola.
        var groups: [(isHardwareSoftware: Bool, bitrates: [Int], names: [String])] = []

        for members in series {
            guard let first = members.first?.settings else { continue }

            let isHardwareSoftware = Set(members.map(\.settings.backend)).count > 1
            let bitrates = Set(members.map(\.settings.videoBitrateKbps)).sorted()
            let name = isHardwareSoftware ? "\(first.codec.title) \(first.profile.title)" : proseName(first)

            if let index = groups.firstIndex(where: { $0.isHardwareSoftware == isHardwareSoftware && $0.bitrates == bitrates }) {
                groups[index].names.append(name)
            } else {
                groups.append((isHardwareSoftware, bitrates, [name]))
            }
        }

        return groups.map { group in
            let bitrates = list(group.bitrates.map { "\($0)" })
            let kind = group.isHardwareSoftware ? "hardware / software" : ""

            guard group.names.count > 1 else {
                return group.isHardwareSoftware
                    ? "Una serie hardware / software con \(group.names[0]), a \(bitrates) kb/s."
                    : "Una serie \(group.names[0]), a \(bitrates) kb/s."
            }

            let count = group.names.count == 2 ? "Due" : "\(group.names.count)"
            let each = group.names.map { group.isHardwareSoftware ? "una con \($0)" : "una \($0)" }
            return "\(count) serie \(kind)".trimmingCharacters(in: .whitespaces) +
                ", \(list(each)), " + (group.names.count == 2 ? "entrambe" : "tutte") + " a \(bitrates) kb/s."
        }
    }

    // MARK: Qualità

    /// La sezione Qualità e il testo della codifica migliore.
    ///
    /// Tre fatti: che cosa misura il VMAF, la classifica per VMAF medio, i tempi; poi la tabella.
    private static func qualitySection(
        experiments: [EncodingExperiment],
        analyses: [VideoQualityAnalysisResult]
    ) -> (section: ReportSection, bestEncoding: String?, criterion: String?)? {
        // Per ogni esperimento vale l'analisi più recente, come nei grafici.
        let latest = Dictionary(grouping: analyses, by: \.experimentID).compactMap { $0.value.max { $0.analyzedAt < $1.analyzedAt } }
        guard !latest.isEmpty else { return nil }

        let resultsByID = Dictionary(uniqueKeysWithValues: latest.map { ($0.id, $0) })
        let experimentsByID = Dictionary(uniqueKeysWithValues: experiments.map { ($0.id, $0) })

        // Il VMAF minimo e il tempo di codifica di un punto delle curve.
        func minimum(_ point: QualityCurvePoint) -> Double? { resultsByID[point.id]?.vmafMinimum }
        func encodingSeconds(_ point: QualityCurvePoint) -> Double? {
            resultsByID[point.id].flatMap { experimentsByID[$0.experimentID]?.outputInfo?.encodingDurationSeconds }
        }

        var paragraphs = [
            "Il VMAF, da 0 a 100, stima la qualità percepita. Consideriamo soddisfacente un VMAF medio da \(Int(QualityInsights.goodVMAF)) in su." +
            (latest.contains { $0.vmafAt1080p == true }
                ? " Per i video più piccoli di 1080p è calcolato sui video ingranditi a 1080p, come richiede il modello: i valori risultano più severi."
                : "")
        ]
        var tables: [ReportTable] = []

        // Un gruppo per spezzone, come nei grafici; la codifica migliore si sceglie nel gruppo più grande.
        let groups = QualityCurveGroupBuilder.build(results: latest, experiments: experiments, metric: .vmaf)

        for group in groups {
            let prefix = groups.count > 1 ? "\(group.sourceName): " : ""
            let ranking = QualityInsights.ranking(of: group.points)

            if ranking.count > 1 {
                paragraphs.append(prefix + "Ai bitrate provati da tutte le configurazioni, la classifica per VMAF medio è: " +
                    ranking.map { "\(proseName($0.settings)) \(decimal($0.meanVMAF, 1))" }.joined(separator: "; ") + ".")
            } else if let only = ranking.first {
                paragraphs.append(prefix + "Il VMAF medio di \(proseName(only.settings)) ai bitrate provati è \(decimal(only.meanVMAF, 1)).")
            }

            let pointsBySeries = Dictionary(grouping: group.points, by: \.series)
            let curves = ranking.map(\.series) + pointsBySeries.keys.filter { key in !ranking.contains { $0.series == key } }.sorted()

            if let table = qualityTable(group: group, curves: curves, pointsBySeries: pointsBySeries, minimum: minimum, showsGroup: groups.count > 1) {
                tables.append(table)
            }
        }

        // I tempi: software rispetto a hardware, in media.
        func averageTime(_ backend: EncodingBackend) -> Double? {
            let times = experiments.filter { $0.settings.backend == backend }.compactMap { $0.outputInfo?.encodingDurationSeconds }
            return times.isEmpty ? nil : times.reduce(0, +) / Double(times.count)
        }

        if let hardware = averageTime(.hardware), let software = averageTime(.software), hardware > 0 {
            paragraphs.append("La codifica via software ha richiesto in media \(times(software / hardware)) di quella via hardware.")
        }

        // La codifica migliore, nel gruppo con più punti (di solito il video intero).
        var bestEncoding: String?
        var criterion: String?

        if let group = groups.max(by: { $0.points.count < $1.points.count }),
           let best = QualityInsights.bestEncoding(of: group.points) {
            let point = best.point
            let settings = point.settings

            let rateControl = switch settings.effectiveRateControlMode {
            case .bitrate: "bitrate obiettivo \(settings.videoBitrateKbps) kb/s" + (settings.usesTwoPass ? " in due passate" : "")
            case .constantQuality: "CRF \(settings.crfValue)"
            case .constantQuantizer: "QP \(settings.quantizerValue)"
            }

            let seconds = encodingSeconds(point)
            let description = "\(proseName(settings)), \(rateControl) (\(kbpsText(point.bitrateKbps)) misurati): " +
                "VMAF medio \(decimal(point.value, 1))" + (minimum(point).map { ", minimo \(decimal($0, 1))" } ?? "") +
                (seconds.map { "; codificata in \(timeText($0))" } ?? "") + "."

            var text = (groups.count > 1 ? "Per \(group.sourceName): " : "") +
                (best.reachesGoodQuality
                    ? description
                    : "Nessuna codifica raggiunge un VMAF medio di \(Int(QualityInsights.goodVMAF)). Quella con il VMAF più alto è " + description)

            // Un fatto sul tempo: allo stesso bitrate, la configurazione più veloce che arriva anch'essa alla soglia.
            if best.reachesGoodQuality, let target = point.targetKbps, let seconds, seconds > 0 {
                let faster = QualityInsights.usablePoints(group.points).compactMap { other -> (point: QualityCurvePoint, seconds: Double)? in
                    guard other.series != point.series, other.targetKbps == target, other.value >= QualityInsights.goodVMAF,
                          let otherSeconds = encodingSeconds(other), otherSeconds > 0, otherSeconds < seconds else { return nil }
                    return (other, otherSeconds)
                }

                if let fastest = faster.min(by: { $0.seconds < $1.seconds }) {
                    text += " Allo stesso bitrate arriva a \(Int(QualityInsights.goodVMAF)) anche \(proseName(fastest.point.settings)) " +
                        "(VMAF medio \(decimal(fastest.point.value, 1))" + (minimum(fastest.point).map { ", minimo \(decimal($0, 1))" } ?? "") +
                        "), codificata in \(timeText(fastest.seconds)): circa " +
                        "\(ratioText(seconds / fastest.seconds)) volte più veloce."
                }
            }

            // Il criterio si applica solo se qualche codifica arriva alla soglia; altrimenti la frase
            // «quella con il VMAF più alto» dice già come è stata scelta.
            bestEncoding = text
            criterion = best.reachesGoodQuality ? "Criterio: \(QualityInsights.bestEncodingCriterion)." : nil
        }

        return (ReportSection(title: "Qualità", paragraphs: paragraphs, tables: tables), bestEncoding, criterion)
    }

    /// La tabella della qualità di un gruppo: una riga per bitrate obiettivo, una colonna per curva,
    /// con il VMAF medio e, tra parentesi, il minimo. `nil` se non ci sono codifiche a bitrate.
    private static func qualityTable(
        group: QualityCurveGroup,
        curves: [String],
        pointsBySeries: [String: [QualityCurvePoint]],
        minimum: (QualityCurvePoint) -> Double?,
        showsGroup: Bool
    ) -> ReportTable? {
        let targets = Set(group.points.compactMap { $0.targetKbps.map { Int($0) } }).sorted()
        guard !targets.isEmpty, !curves.isEmpty else { return nil }

        let settings = curves.compactMap { pointsBySeries[$0]?.first?.settings }
        let shortNames = QualityInsights.shortSeriesNames(settings)
        var hasOffTarget = false

        let rows = targets.map { target -> [String] in
            ["\(target) kb/s"] + curves.map { curve -> String in
                guard let point = pointsBySeries[curve]?.first(where: { $0.targetKbps.map { Int($0) } == target }) else { return "—" }

                hasOffTarget = hasOffTarget || point.isOffTarget
                return decimal(point.value, 1) + (minimum(point).map { " (\(decimal($0, 1)))" } ?? "") + (point.isOffTarget ? " *" : "")
            }
        }

        let headers = ["Obiettivo"] + curves.map { curve in
            shortNames[curve] ?? pointsBySeries[curve]?.first.map { proseName($0.settings) } ?? curve
        }

        return ReportTable(
            title: "VMAF per bitrate obiettivo" + (showsGroup ? " — \(group.sourceName)" : ""),
            headers: headers,
            rows: rows,
            note: "Ogni cella: VMAF medio e, tra parentesi, VMAF minimo (il fotogramma peggiore)." +
                (hasOffTarget ? " L'asterisco indica una codifica fuori obiettivo (oltre il 25% sopra il bitrate richiesto), esclusa dalla classifica e dalla scelta." : "")
        )
    }

    // MARK: Audio

    /// Le codifiche audio a parole: encoder e bitrate provati, precisione e peso sul file.
    private static func audioSection(_ experiments: [AudioExperiment], video: VideoSummary?) -> ReportSection? {
        guard !experiments.isEmpty else { return nil }

        // Gli encoder per nome: «l'encoder di AudioToolbox e quello di FFmpeg».
        let encoderNames = AudioEncoder.allCases.filter { encoder in experiments.contains { $0.encoder == encoder } }
            .map { $0 == .apple ? "AudioToolbox" : "FFmpeg" }
        let encoders = encoderNames.count == 2
            ? "con l'encoder di \(encoderNames[0]) e quello di \(encoderNames[1])"
            : "con l'encoder di \(encoderNames.first ?? "FFmpeg")"
        let bitrates = Set(experiments.map(\.bitrateKbps)).sorted().map { "\($0)" }

        var sentences = [
            "Sono state provate \(experiments.count) codifiche AAC, \(encoders), a \(list(bitrates)) kb/s."
        ]

        // Gli encoder che si discostano di più del 5% dall'obiettivo.
        let deviating = experiments.compactMap { experiment -> String? in
            guard let measured = experiment.output?.bitrateBitsPerSecond, experiment.bitrateKbps > 0 else { return nil }

            let deviation = (Double(measured) / 1000 - Double(experiment.bitrateKbps)) / Double(experiment.bitrateKbps) * 100
            return abs(deviation) > 5 ? "\(experiment.encoder.title) a \(experiment.bitrateKbps) kb/s (\(signedPercent(deviation)))" : nil
        }

        if !deviating.isEmpty {
            sentences.append("Si discostano dal bitrate obiettivo di oltre il 5%: \(list(deviating)).")
        } else if experiments.contains(where: { $0.output != nil }) {
            sentences.append("Tutti gli encoder hanno rispettato il bitrate obiettivo entro il 5%.")
        }

        // Il peso dell'audio con il video originale, dal bitrate più basso al più alto.
        if let video, !video.isUncompressed, let videoBitrate = video.bitrateBitsPerSecond {
            let videoKbps = Double(videoBitrate) / 1000
            let measured = AudioExperiment.averageMeasuredKbps(experiments)

            if let low = measured.keys.min(), let high = measured.keys.max(), low != high,
               let lowKbps = measured[low], let highKbps = measured[high] {
                sentences.append(
                    "Insieme al video originale (\(MediaValueFormatter.bitRate(videoBitrate))), l'audio pesa tra " +
                    "\(percent(lowKbps / (videoKbps + lowKbps) * 100)) del file a \(low) kb/s e " +
                    "\(percent(highKbps / (videoKbps + highKbps) * 100)) a \(high) kb/s."
                )
            }
        }

        // Le dimensioni dei file, dal bitrate più basso al più alto.
        let sized = experiments.compactMap { experiment in experiment.output?.fileSizeBytes.map { (experiment.bitrateKbps, $0) } }

        if let smallest = sized.min(by: { $0.1 < $1.1 }), let largest = sized.max(by: { $0.1 < $1.1 }), smallest.1 != largest.1 {
            sentences.append("I file vanno da \(MediaValueFormatter.bytes(smallest.1)) a \(smallest.0) kb/s " +
                "a \(MediaValueFormatter.bytes(largest.1)) a \(largest.0) kb/s.")
        }

        // I tempi dei due encoder, se ci sono entrambi.
        func averageTime(_ encoder: AudioEncoder) -> Double? {
            let times = experiments.filter { $0.encoder == encoder }.compactMap { $0.output?.encodingDurationSeconds }
            return times.isEmpty ? nil : times.reduce(0, +) / Double(times.count)
        }

        if let apple = averageTime(.apple), let ffmpeg = averageTime(.ffmpeg), apple > 0, ffmpeg > 0 {
            let ratio = max(apple, ffmpeg) / min(apple, ffmpeg)
            let faster = apple < ffmpeg ? "AudioToolbox" : "FFmpeg"

            sentences.append(ratio < 1.5
                ? "I due encoder hanno richiesto tempi simili."
                : "L'encoder di \(faster) è stato in media circa \(ratioText(ratio)) volte più veloce.")
        }

        let clips = Set(experiments.compactMap { $0.clip?.description })
        sentences += clips.sorted().map { "Le codifiche audio lavorano su una parte del file (\($0.lowercased()))." }

        // Senza una misura della qualità dell'audio non c'è una codifica da consigliare.
        sentences.append("FFmpeg non fornisce una metrica percettiva per l'audio (come il VMAF per il video), quindi CodecLab non può misurarne la qualità né indicare una codifica audio migliore.")

        return ReportSection(title: "Audio", paragraphs: [sentences.joined(separator: " ")])
    }

    // MARK: Formattazione

    /// Il nome di una configurazione nelle frasi, per esempio "H.265 / HEVC Main via software".
    private static func proseName(_ settings: EncodingSettings) -> String {
        "\(settings.codec.title) \(settings.profile.title) \(settings.backend.title)"
    }

    /// Un bitrate in kb/s come testo, per esempio "254 kb/s" o "1,2 Mb/s".
    private static func kbpsText(_ kbps: Double) -> String {
        MediaValueFormatter.bitRate(Int64((kbps * 1000).rounded()))
    }

    /// Un numero con le cifre decimali indicate; "—" se manca.
    private static func decimal(_ value: Double?, _ digits: Int) -> String {
        value.map { minusSign($0.formatted(.number.precision(.fractionLength(digits)))) } ?? "—"
    }

    /// "12,5%"
    private static func percent(_ value: Double) -> String {
        minusSign(value.formatted(.number.precision(.fractionLength(1)))) + "%"
    }

    /// "+12,5%" o "−3,0%": il segno anche per i valori positivi.
    private static func signedPercent(_ value: Double) -> String {
        (value >= 0 ? "+" : "") + percent(value)
    }

    /// Il segno meno tipografico (−) al posto del trattino (-) dei numeri formattati: "−4,2" invece di "-4,2".
    private static func minusSign(_ number: String) -> String {
        number.replacingOccurrences(of: "-", with: "−")
    }

    /// Un rapporto tra tempi a parole: "circa il doppio del tempo", "circa 4,8 volte il tempo".
    private static func times(_ ratio: Double) -> String {
        if (1.8..<2.25).contains(ratio) { return "circa il doppio del tempo" }
        return "circa \(ratioText(ratio)) volte il tempo"
    }

    /// Una durata o un tempo di codifica: sotto il minuto in secondi con un decimale ("4,6 s"),
    /// perché "0:05" e "0:01" sarebbero troppo grossolani per confrontarli; poi minuti e secondi ("1:09").
    private static func timeText(_ seconds: Double) -> String {
        seconds < 59.95
            ? "\(seconds.formatted(.number.precision(.fractionLength(1)))) s"
            : MediaValueFormatter.duration(seconds)
    }

    /// Un rapporto da leggere dopo «circa»: un decimale sotto 10 ("4,8"), intero da 10 in su ("17"),
    /// dove il decimale darebbe una precisione che «circa» smentisce.
    private static func ratioText(_ ratio: Double) -> String {
        ratio.formatted(.number.precision(.fractionLength(ratio >= 10 ? 0 : 1)))
    }

    /// Un elenco in italiano: "a", "a e b", "a, b e c".
    private static func list(_ items: [String]) -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " e " + last
    }
}
