// Charts.swift
// Grafici della sezione Analisi: curva qualità/bitrate, VMAF lungo il video e QP per fotogramma.
// Il calcolo del BD-rate mostrato sotto le curve è in Services/BDRate.swift.

import Charts
import SwiftUI

// MARK: - Curva qualità/bitrate

/// La metrica sull'asse verticale della curva qualità/bitrate: VMAF medio, 5° percentile del VMAF,
/// PSNR della luminanza o SSIM.
///
/// Il 5° percentile c'è perché la media può nascondere brevi cali di qualità, che invece l'occhio nota:
/// dice quanto è buono il 5% peggiore dei fotogrammi.
enum QualityCurveMetric: String, CaseIterable, Identifiable {
    /// Il VMAF medio.
    case vmaf
    /// Il 5° percentile del VMAF: la qualità dei momenti peggiori.
    case vmafPercentile5
    /// Il PSNR medio della luminanza, in dB.
    case psnrY
    /// L'SSIM medio.
    case ssim

    /// L'identificativo della metrica.
    var id: String { rawValue }

    /// Il nome breve, per il menu.
    var title: String {
        switch self {
        case .vmaf: "VMAF medio"
        case .vmafPercentile5: "VMAF 5° perc."
        case .psnrY: "PSNR Y"
        case .ssim: "SSIM"
        }
    }

    /// Il titolo dell'asse verticale.
    var axisTitle: String {
        switch self {
        case .vmaf: "VMAF medio"
        case .vmafPercentile5: "VMAF, 5° percentile"
        case .psnrY: "PSNR Y (dB)"
        case .ssim: "SSIM"
        }
    }

    /// Il valore della metrica in un'analisi.
    ///
    /// - Parameter result: L'analisi.
    /// - Returns: Il valore, o `nil` se l'analisi non lo contiene.
    func value(from result: VideoQualityAnalysisResult) -> Double? {
        switch self {
        case .vmaf: result.summary.vmaf?.mean
        case .vmafPercentile5: result.vmafPercentile5
        case .psnrY: result.summary.psnrY?.mean
        case .ssim: result.summary.ssim?.mean
        }
    }

    /// Il valore con le cifre decimali e l'unità adatte alla metrica, per esempio "93,25", "42,38 dB" o "0,9791".
    func formatted(_ value: Double) -> String {
        switch self {
        case .vmaf, .vmafPercentile5:
            value.formatted(.number.precision(.fractionLength(2)))
        case .psnrY:
            value.formatted(.number.precision(.fractionLength(2))) + " dB"
        case .ssim:
            value.formatted(.number.precision(.fractionLength(4)))
        }
    }
}

/// Un punto della curva qualità/bitrate: una codifica analizzata, con il suo bitrate effettivo
/// e il valore della metrica scelta.
///
/// Il punto ricorda anche il bitrate richiesto: se l'encoder lo ha superato di oltre il 25%,
/// il punto è «fuori obiettivo», si disegna come cerchio vuoto e non entra nel BD-rate né nella relazione.
struct QualityCurvePoint: Identifiable {
    /// L'identificativo dell'analisi da cui viene il punto.
    let id: UUID
    /// Il bitrate video effettivo, in kb/s.
    let bitrateKbps: Double
    /// Il valore della metrica.
    let value: Double
    /// La curva a cui appartiene il punto (``EncodingSettings/curveSeriesName``).
    let series: String
    /// L'obiettivo della codifica, per esempio "Bitrate obiettivo: 950 kb/s" o "Controllo rate: CRF 23".
    let target: String
    /// Le impostazioni della codifica: servono a scegliere le curve da confrontare nel BD-rate.
    let settings: EncodingSettings

    /// Di quanto il bitrate misurato può superare l'obiettivo prima che il punto sia «fuori obiettivo»: 25%.
    static let offTargetTolerance = 1.25

    /// Il bitrate obiettivo, in kb/s; `nil` per CRF e QP, che non ne hanno uno.
    var targetKbps: Double? {
        settings.effectiveRateControlMode == .bitrate && settings.videoBitrateKbps > 0
            ? Double(settings.videoBitrateKbps) : nil
    }

    /// Vero se il bitrate misurato supera l'obiettivo di oltre il 25%.
    ///
    /// Succede soprattutto con VideoToolbox, che sotto una certa soglia (diversa per ogni video)
    /// non scende: punti con obiettivi diversi finiscono quasi sullo stesso bitrate. Il punto resta
    /// nel grafico, perché è una misura vera, ma non entra nel BD-rate.
    var isOffTarget: Bool {
        guard let targetKbps else { return false }
        return bitrateKbps > targetKbps * Self.offTargetTolerance
    }

    /// Lo scostamento dall'obiettivo in percentuale, per esempio +505; `nil` senza obiettivo.
    var targetDeviationPercent: Double? {
        targetKbps.map { (bitrateKbps / $0 - 1) * 100 }
    }
}

/// L'asse dei bitrate dei grafici, in scala logaritmica, con valori intermedi leggibili.
///
/// La scala logaritmica rende le curve quasi rette e più facili da confrontare. Lasciato a Swift Charts,
/// però, l'asse mostrerebbe solo le potenze di 10 (10, 100, 1000), troppo poche per leggere i punti.
struct LogBitrateAxis {
    /// Il dominio: dal bitrate più basso al più alto, con un margine del 15% per lato.
    let domain: ClosedRange<Double>
    /// I valori con etichetta e linea di griglia: 1-2-5 per decade negli intervalli ampi,
    /// più fitti in quelli stretti.
    let ticks: [Double]

    /// Calcola l'asse adatto ai punti.
    ///
    /// - Parameter bitratesKbps: I bitrate dei punti, in kb/s. Senza punti, l'asse va da 10 a 10 000 kb/s.
    init(bitratesKbps: [Double]) {
        let values = bitratesKbps.filter { $0 > 0 }

        guard let minimum = values.min(), let maximum = values.max() else {
            domain = 10...10_000
            ticks = [10, 100, 1000, 10_000]
            return
        }

        // Un po' di margine ai lati, perché i punti estremi non tocchino i bordi.
        let lower = minimum / 1.15
        let upper = maximum * 1.15
        let range = lower...upper
        domain = range

        // Più l'intervallo è stretto, più valori intermedi per decade.
        let ratio = upper / lower
        let mantissas: [Double] = ratio > 30 ? [1, 2, 5]
            : ratio > 3 ? [1, 2, 3, 5, 7]
            : [1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8]

        let firstDecade = Int(floor(log10(lower)))
        let lastDecade = Int(floor(log10(upper)))

        ticks = (firstDecade...lastDecade).flatMap { decade in
            mantissas.map { $0 * pow(10, Double(decade)) }
        }
        .filter { range.contains($0) }
    }
}

/// Le analisi di uno stesso video originale e dello stesso spezzone, con i punti delle loro curve.
///
/// Solo queste sono confrontabili tra loro: ogni gruppo ha il suo grafico in Analisi qualità.
struct QualityCurveGroup: Identifiable {
    /// L'identificativo del gruppo: file originale e spezzone.
    let id: String
    /// Il nome del gruppo: il file originale, con lo spezzone se c'è.
    let sourceName: String
    /// I punti delle curve: uno per esperimento, dall'analisi più recente.
    let points: [QualityCurvePoint]
    /// Le analisi del gruppo, nell'ordine dei confronti (vedi ``EncodingSettings/comparisonOrder(_:_:)``).
    let analyses: [VideoQualityAnalysisResult]
}

/// La costruzione dei gruppi di curve a partire dalle analisi salvate: raggruppa le analisi per video
/// e spezzone e, per ogni esperimento, usa l'analisi più recente.
enum QualityCurveGroupBuilder {
    /// Raggruppa le analisi per file originale e spezzone e ne ricava i punti delle curve.
    ///
    /// Per ogni esperimento vale l'analisi più recente. Le analisi senza bitrate effettivo
    /// o senza valore della metrica non danno punti.
    ///
    /// - Parameters:
    ///   - results: Le analisi.
    ///   - experiments: Gli esperimenti, per risalire al file originale.
    ///   - metric: La metrica dell'asse verticale.
    /// - Returns: I gruppi, in ordine di nome.
    static func build(
        results: [VideoQualityAnalysisResult],
        experiments: [EncodingExperiment],
        metric: QualityCurveMetric
    ) -> [QualityCurveGroup] {
        var analysesByGroup: [String: [VideoQualityAnalysisResult]] = [:]
        var namesByGroup: [String: String] = [:]

        for result in results {
            guard let experiment = experiments.first(where: {
                $0.id == result.experimentID
            }) else {
                continue
            }

            let clip = result.encodingSettings.clip
            let groupID = "\(experiment.sourceVideoID)|\(clip.map { "\($0.startSeconds)+\($0.durationSeconds)" } ?? "intero")"

            analysesByGroup[groupID, default: []].append(result)
            namesByGroup[groupID] = clip.map { "\(experiment.sourceName) (\($0.description))" } ?? experiment.sourceName
        }

        return analysesByGroup.map { entry in
            let groupID = entry.key
            let orderedAnalyses = entry.value.sorted {
                $0.analyzedAt > $1.analyzedAt
            }

            // Un solo punto per esperimento: se è stato analizzato più volte, vale l'analisi più recente.
            var plottedExperiments = Set<UUID>()
            let latestAnalyses = orderedAnalyses.filter {
                plottedExperiments.insert($0.experimentID).inserted
            }

            let points = latestAnalyses.compactMap { result -> QualityCurvePoint? in
                guard
                    let measuredBitrate = result.videoBitrateBitsPerSecond,
                    measuredBitrate > 0,
                    let value = metric.value(from: result),
                    value.isFinite
                else {
                    return nil
                }

                return QualityCurvePoint(
                    id: result.id,
                    bitrateKbps: Double(measuredBitrate) / 1000,
                    value: value,
                    series: result.encodingSettings.curveSeriesName,
                    target: result.encodingSettings.rateControlDescription,
                    settings: result.encodingSettings
                )
            }
            .sorted {
                $0.bitrateKbps < $1.bitrateKbps
            }

            // Le schede nell'ordine dei confronti: a ogni bitrate, l'hardware e subito sotto il software.
            // Le analisi ripetute dello stesso esperimento restano dalla più recente.
            let analysesForComparison = orderedAnalyses.sorted { first, second in
                let a = (first.encodingSettings, first.videoBitrateBitsPerSecond.map { Double($0) / 1000 })
                let b = (second.encodingSettings, second.videoBitrateBitsPerSecond.map { Double($0) / 1000 })

                if EncodingSettings.comparisonOrder(a, b) { return true }
                if EncodingSettings.comparisonOrder(b, a) { return false }
                return first.analyzedAt > second.analyzedAt
            }

            return QualityCurveGroup(
                id: groupID,
                sourceName: namesByGroup[groupID] ?? "Video originale",
                points: points,
                analyses: analysesForComparison
            )
        }
        .sorted {
            $0.sourceName.localizedStandardCompare($1.sourceName) == .orderedAscending
        }
    }
}

/// La curva qualità/bitrate di un video: una linea per configurazione, un punto per codifica.
///
/// È il grafico principale di Analisi qualità: a parità di bitrate, la curva più in alto è la migliore.
/// Passando il puntatore su un punto se ne leggono i dettagli; con un clic, o con il pulsante «Ingrandisci»,
/// il grafico si apre in una finestra più grande. Sotto la curva, la tabella del BD-rate.
struct QualityCurveChartView: View {
    /// Il gruppo da disegnare.
    let group: QualityCurveGroup
    /// La metrica dell'asse verticale.
    let metric: QualityCurveMetric
    /// L'altezza del grafico: più grande nella finestra ingrandita.
    var chartHeight: CGFloat = 300
    /// Apre il grafico in una finestra a parte (pulsante e clic sul grafico); `nil` nella finestra stessa.
    var onEnlarge: (() -> Void)? = nil

    /// Il punto sotto il puntatore.
    @State private var hoveredPointID: UUID?

    /// Il punto sotto il puntatore.
    private var hoveredPoint: QualityCurvePoint? {
        group.points.first { $0.id == hoveredPointID }
    }

    /// L'asse dei bitrate, calcolato sui punti del gruppo.
    private var bitrateAxis: LogBitrateAxis {
        LogBitrateAxis(bitratesKbps: group.points.map(\.bitrateKbps))
    }

    /// Una riga della tabella del BD-rate.
    private struct BDRateRow: Identifiable {
        let id: String
        let series: String      // Configurazione confrontata
        let reference: String   // Configurazione di riferimento
        let percent: Double?
        let reason: String?     // Perché non è calcolabile
    }

    /// I confronti del BD-rate tra le curve del grafico (vedi ``BDRate/comparisons(of:)``).
    private var bdRateRows: [BDRateRow] {
        BDRate.comparisons(of: group.points).map {
            BDRateRow(id: "\($0.series)|\($0.reference)", series: $0.series, reference: $0.reference, percent: $0.percent, reason: $0.reason)
        }
    }

    /// Vero se almeno una configurazione ha due o più bitrate: solo allora c'è una curva da disegnare.
    /// Con punti isolati il grafico non direbbe nulla in più dei numeri delle schede.
    private var hasCurve: Bool {
        Dictionary(grouping: group.points, by: \.series).values.contains { points in
            Set(points.map(\.bitrateKbps)).count >= 2
        }
    }

    /// Le righe del riquadro sul punto sotto il puntatore.
    private func tooltipLines(for point: QualityCurvePoint) -> [String] {
        var lines = [
            point.series,
            point.target,
            "Bitrate misurato: \(MediaValueFormatter.bitRate(Int64(point.bitrateKbps * 1000)))"
        ]

        if point.isOffTarget, let deviation = point.targetDeviationPercent {
            lines.append("Fuori obiettivo (\(deviation.formatted(.number.precision(.fractionLength(0)).sign(strategy: .always())) + " %")): escluso dal BD-rate")
        }

        lines.append("\(metric.title): \(metric.formatted(point.value))")
        return lines
    }

    var body: some View {
        GroupBox {
            if group.points.isEmpty {
                Text("Non è disponibile un bitrate video effettivo associato a questa metrica.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
            } else if !hasCurve {
                Text("Il grafico compare quando una configurazione ha almeno due bitrate: crea una serie in Esperimenti video.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                Chart {
                    ForEach(group.points) { point in
                        LineMark(
                            x: .value("Bitrate", point.bitrateKbps),
                            y: .value(metric.title, point.value),
                            series: .value("Configurazione", point.series)
                        )
                        .interpolationMethod(.linear)
                        .foregroundStyle(by: .value("Configurazione", point.series))

                        // Pieno se la codifica ha rispettato l'obiettivo, vuoto se è fuori obiettivo.
                        if point.isOffTarget {
                            PointMark(
                                x: .value("Bitrate", point.bitrateKbps),
                                y: .value(metric.title, point.value)
                            )
                            .foregroundStyle(by: .value("Configurazione", point.series))
                            .symbol(.circle.strokeBorder(lineWidth: 2))
                            .symbolSize(75)
                        } else {
                            PointMark(
                                x: .value("Bitrate", point.bitrateKbps),
                                y: .value(metric.title, point.value)
                            )
                            .foregroundStyle(by: .value("Configurazione", point.series))
                            .symbolSize(75)
                        }
                    }

                    if let hovered = hoveredPoint {
                        RuleMark(x: .value("Bitrate", hovered.bitrateKbps))
                            .foregroundStyle(.gray.opacity(0.4))
                            .annotation(
                                position: .top,
                                spacing: 0,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                            ) {
                                ChartTooltip(lines: tooltipLines(for: hovered))
                            }
                    }
                }
                .chartOverlay { proxy in
                    ChartPointerOverlay(proxy: proxy, onHover: { location in
                        hoveredPointID = location.flatMap { location in
                            let positions = group.points.map { proxy.position(for: ($0.bitrateKbps, $0.value)) }
                            return ChartPointerOverlay.nearestIndex(to: location, among: positions).map { group.points[$0].id }
                        }
                    }, onClick: onEnlarge.map { enlarge -> (CGPoint) -> Void in { _ in enlarge() } })
                }
                // Bitrate in scala logaritmica: la qualità cresce circa col logaritmo del bitrate,
                // quindi le curve diventano quasi rette e il confronto è più leggibile.
                // L'asse Y si adatta ai valori, così le differenze piccole restano visibili.
                .chartXScale(domain: bitrateAxis.domain, type: .log)
                .chartXAxis {
                    AxisMarks(values: bitrateAxis.ticks) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let kbps = value.as(Double.self) {
                                Text(kbps.formatted(.number))
                            }
                        }
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxisLabel("Bitrate video effettivo (kb/s, scala logaritmica)")
                .chartYAxisLabel(metric.axisTitle)
                .chartLegend(position: .bottom)
                .frame(height: chartHeight)
                .padding(.vertical, 8)

                Text("Una linea collega prove dello stesso video con codec, profilo, encoder, GOP e modalità di controllo uguali. Varia il bitrate target, il CRF o il QP per ottenere più punti della stessa curva. Per ogni esperimento vale l'analisi più recente.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if group.points.contains(where: \.isOffTarget) {
                    Label("Cerchio vuoto: punto fuori obiettivo. Il bitrate misurato supera l'obiettivo di oltre il 25%, perché l'encoder non è riuscito ad avvicinarsi al bitrate obiettivo. Il punto resta nel grafico ma non viene considerato nel calcolo del BD-rate.", systemImage: "circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !bdRateRows.isEmpty {
                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("BD-rate (differenza di bitrate a parità di qualità)")
                            .font(.subheadline.weight(.semibold))

                        ForEach(bdRateRows) { row in
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 1) {
                                    // Configurazione, «rispetto a» in un'etichetta e riferimento, di seguito:
                                    // vanno a capo solo se non stanno su una riga.
                                    FlowLayout(spacing: 6) {
                                        Text(row.series)
                                            .lineLimit(1)
                                            .truncationMode(.middle)

                                        Text("rispetto a")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.tint)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 1)
                                            .background(.tint.opacity(0.15), in: Capsule())

                                        Text(row.reference)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    .font(.callout)

                                    if let reason = row.reason {
                                        Text("Non calcolabile: \(reason).")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                // Con il segno anche se positivo: "+12,3 %" significa più bitrate del riferimento.
                                Text(row.percent.map { $0.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always()).grouping(.never)) + " %" } ?? "—")
                                    .font(.system(.body, design: .rounded).weight(.semibold))
                                    .monospacedDigit()
                            }
                        }

                        Text("Il BD-rate (Bjøntegaard Delta rate, il metodo standard per confrontare due encoder) è la differenza media di bitrate a parità di \(metric.title): un valore negativo indica che la configurazione richiede meno bitrate del riferimento per la stessa qualità. Il software si confronta con l'hardware dello stesso codec; HEVC con H.264 a parità di encoder. Contano solo i punti entro l'obiettivo: ne servono almeno 3 per curva, con valori di qualità in comune.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.sourceName)
                        .font(.headline)

                    Text("Curva \(metric.title) rispetto al bitrate")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let onEnlarge {
                    EnlargeChartButton(action: onEnlarge)
                }
            }
        }
    }
}

/// Il pulsante con le due frecce che apre un grafico in una finestra a parte, più grande.
struct EnlargeChartButton: View {
    let action: () -> Void

    var body: some View {
        Button("Ingrandisci", systemImage: "arrow.up.left.and.arrow.down.right", action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Apri il grafico in una finestra più grande")
    }
}

// MARK: - Valori lungo il video

/// I valori di ogni fotogramma lungo il video, in grafici impilati sullo stesso asse: VMAF, QP
/// (solo per le codifiche software) e dimensione dei fotogrammi o bitrate di ogni secondo.
///
/// Il puntatore li attraversa tutti insieme: così si vede se un calo di qualità coincide con un QP più alto,
/// con fotogrammi più piccoli o con un fotogramma I. Un clic sulla curva del VMAF apre il confronto
/// di quel fotogramma con l'originale.
struct FrameTimelineView: View {
    /// Il VMAF di ogni fotogramma.
    let vmaf: [Double]
    /// Il 5° percentile del VMAF, disegnato come linea orizzontale.
    let percentile5: Double?
    /// Il QP di ogni fotogramma, in ordine di visualizzazione; vuoto per VideoToolbox.
    var quantization: [FrameQuantizationSample] = []
    /// La dimensione di ogni fotogramma, in byte; vuoto nelle analisi che non la registravano.
    var frameSizes: [Int] = []
    /// Il tipo di ogni fotogramma, una lettera per fotogramma; vuoto se non è noto.
    var frameTypes: String = ""
    /// Il frame rate: serve per l'istante di ogni fotogramma e per il bitrate al secondo.
    var framesPerSecond: Double? = nil
    /// L'istante dell'originale da cui parte il confronto (inizio dello spezzone, oppure 0).
    var startSeconds: Double = 0
    /// Se presente, un clic sulla curva del VMAF apre il confronto del fotogramma indicato.
    var onSelectFrame: ((Int) -> Void)? = nil
    /// Quanto più alti disegnare i grafici: 1 nella scheda, di più nella finestra ingrandita.
    var heightScale: CGFloat = 1
    /// Apre i grafici in una finestra a parte; `nil` nella finestra stessa.
    var onEnlarge: (() -> Void)? = nil

    /// Il fotogramma sotto il puntatore, condiviso da tutti i grafici.
    @State private var hoveredFrame: Int?
    /// Le dimensioni per fotogramma o il bitrate al secondo.
    @State private var showsBitratePerSecond = false

    /// Il numero massimo di punti disegnati per VMAF e dimensioni.
    private static let maximumPoints = 600
    /// La larghezza delle etichette dell'asse verticale, uguale per tutti i grafici.
    private static let axisLabelWidth: CGFloat = 52
    /// I colori dei tipi di fotogramma, uguali nei grafici del QP e delle dimensioni.
    private static let typeColors: [(type: String, color: Color)] = [("I", .orange), ("P", .blue), ("B", .green), (unknownType, .gray)]

    /// Il nome dei fotogrammi di tipo sconosciuto (dati mancanti o lettera non riconosciuta).
    private static let unknownType = "Non noto"

    /// Il tipo di un fotogramma da mostrare: I, P, B oppure «Non noto».
    private static func typeName(_ type: String) -> String {
        let letter = type.uppercased()
        return ["I", "P", "B"].contains(letter) ? letter : unknownType
    }

    /// La scala dei colori con i soli tipi presenti: la legenda non mostra tipi che il grafico non ha.
    private static func typeScale(_ types: [String]) -> (domain: [String], range: [Color]) {
        let present = Set(types)
        let entries = typeColors.filter { present.contains($0.type) }
        return (entries.map(\.type), entries.map(\.color))
    }

    /// Un punto disegnato: il fotogramma e il suo valore.
    private struct Point: Identifiable {
        let frame: Int
        let value: Double
        var type: String = "Non noto"
        var id: Int { frame }
    }

    /// Il numero di fotogrammi: il più lungo degli elenchi.
    private var frameCount: Int {
        max(vmaf.count, quantization.count, frameSizes.count)
    }

    /// L'asse orizzontale, uguale per tutti i grafici.
    private var frameDomain: ClosedRange<Int> {
        0...max(frameCount - 1, 1)
    }

    /// I tipi dei fotogrammi, solo se corrispondono uno a uno alle dimensioni.
    private var sizeTypes: [String]? {
        frameTypes.count == frameSizes.count ? frameTypes.map(String.init) : nil
    }

    // MARK: Dati dei grafici

    /// Raggruppa i valori in al massimo 600 intervalli e per ciascuno tiene il fotogramma
    /// con il valore estremo.
    ///
    /// - Parameters:
    ///   - values: Un valore per fotogramma.
    ///   - lowest: Vero per tenere il valore più basso, falso per il più alto.
    /// - Returns: Gli indici dei fotogrammi scelti.
    private static func reducedFrames(of values: [Double], lowest: Bool) -> [Int] {
        // Fotogrammi per intervallo: 1 finché i fotogrammi sono al massimo 600.
        let bucketSize = max(1, Int((Double(values.count) / Double(maximumPoints)).rounded(.up)))

        return stride(from: 0, to: values.count, by: bucketSize).compactMap { start in
            // Gli indici di una porzione di array sono quelli dell'array intero:
            // il risultato è già il numero del fotogramma.
            let bucket = values.indices[start..<min(start + bucketSize, values.count)]
            return lowest
                ? bucket.min { values[$0] < values[$1] }
                : bucket.max { values[$0] < values[$1] }
        }
    }

    /// I punti del VMAF: per ogni intervallo, il fotogramma peggiore.
    private var vmafPoints: [Point] {
        Self.reducedFrames(of: vmaf, lowest: true).map { Point(frame: $0, value: vmaf[$0]) }
    }

    /// I punti delle dimensioni, in kB: per ogni intervallo, il fotogramma più grande.
    private var sizePoints: [Point] {
        let kilobytes = frameSizes.map { Double($0) / 1000 }
        let types = sizeTypes

        return Self.reducedFrames(of: kilobytes, lowest: false).map {
            Point(frame: $0, value: kilobytes[$0], type: Self.typeName(types?[$0] ?? ""))
        }
    }

    /// Il bitrate di ogni secondo, in kb/s, disegnato a metà del secondo.
    private var bitratePoints: [Point] {
        guard let framesPerSecond else { return [] }

        return FrameSizeStatistics.bitratePerSecondKbps(frameSizes: frameSizes, framesPerSecond: framesPerSecond)
            .enumerated()
            .map { Point(frame: min(Int(((Double($0.offset) + 0.5) * framesPerSecond).rounded()), frameSizes.count - 1), value: $0.element) }
    }

    /// Il campione del QP di un fotogramma.
    private func quantizationSample(at frame: Int) -> FrameQuantizationSample? {
        // Di solito la posizione nell'elenco coincide con quella nel video: si evita di cercare.
        if quantization.indices.contains(frame), quantization[frame].displayOrder == frame {
            return quantization[frame]
        }

        return quantization.first { $0.displayOrder == frame }
    }

    /// Il fotogramma sotto il puntatore (conta solo la posizione orizzontale).
    private func frameIndex(at location: CGPoint, proxy: ChartProxy) -> Int? {
        guard frameCount > 0, let value = proxy.value(atX: location.x, as: Double.self) else {
            return nil
        }

        // Ai bordi dell'area il valore può cadere appena fuori dall'elenco.
        return min(max(Int(value.rounded()), 0), frameCount - 1)
    }

    /// Il livello che segue il puntatore, uguale per tutti i grafici; il clic solo dove indicato.
    private func pointerOverlay(_ proxy: ChartProxy, clickable: Bool = false) -> some View {
        var onClick: ((CGPoint) -> Void)?

        if clickable, let onSelectFrame {
            onClick = { location in
                if let frame = frameIndex(at: location, proxy: proxy) {
                    onSelectFrame(frame)
                }
            }
        }

        return ChartPointerOverlay(
            proxy: proxy,
            onHover: { location in
                hoveredFrame = location.flatMap { frameIndex(at: $0, proxy: proxy) }
            },
            onClick: onClick
        )
    }

    /// L'asse verticale con etichette di larghezza fissa: così le aree dei dati dei grafici
    /// impilati sono larghe uguali e lo stesso fotogramma cade alla stessa altezza in tutti.
    private func alignedYAxis(fractionDigits: Int = 0) -> some AxisContent {
        AxisMarks(position: .leading) { value in
            AxisGridLine()
            AxisTick()
            AxisValueLabel {
                if let number = value.as(Double.self) {
                    Text(number.formatted(.number.precision(.fractionLength(fractionDigits))))
                        .frame(width: Self.axisLabelWidth, alignment: .trailing)
                }
            }
        }
    }

    // MARK: Grafici

    var body: some View {
        // Calcolato su tutti i fotogrammi, non sui punti disegnati.
        let worstFrame = vmaf.indices.min { vmaf[$0] < vmaf[$1] }

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Lungo il video")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                // Qui il clic sul VMAF confronta un fotogramma: per ingrandire c'è il pulsante.
                if let onEnlarge {
                    EnlargeChartButton(action: onEnlarge)
                }
            }

            if !vmaf.isEmpty {
                vmafChart(worstFrame: worstFrame)
            }

            if !quantization.isEmpty {
                quantizationChart
            }

            if !frameSizes.isEmpty {
                sizeChart
            }

            Text(captionText(worstFrame: worstFrame))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Il VMAF di ogni fotogramma, con il 5° percentile e il fotogramma peggiore.
    private func vmafChart(worstFrame: Int?) -> some View {
        Chart {
            ForEach(vmafPoints) { point in
                LineMark(x: .value("Fotogramma", point.frame), y: .value("VMAF", point.value))
                    .interpolationMethod(.linear)
            }

            if let percentile5 {
                RuleMark(y: .value("5° percentile", percentile5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary)
            }

            if let worstFrame {
                PointMark(x: .value("Fotogramma", worstFrame), y: .value("VMAF", vmaf[worstFrame]))
                    .foregroundStyle(.red)
                    .symbolSize(60)
            }

            if let hoveredFrame, vmaf.indices.contains(hoveredFrame) {
                RuleMark(x: .value("Fotogramma", hoveredFrame))
                    .foregroundStyle(.gray.opacity(0.4))
                    .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartTooltip(lines: vmafTooltipLines(for: hoveredFrame))
                    }

                PointMark(x: .value("Fotogramma", hoveredFrame), y: .value("VMAF", vmaf[hoveredFrame]))
                    .symbolSize(40)
            }
        }
        .chartOverlay { pointerOverlay($0, clickable: true) }
        .chartXScale(domain: frameDomain)
        .chartYScale(domain: .automatic(includesZero: false))
        .chartYAxis { alignedYAxis() }
        .chartYAxisLabel("VMAF")
        .frame(height: 180 * heightScale)
    }

    /// Il QP di ogni fotogramma, colorato per tipo.
    private var quantizationChart: some View {
        Chart {
            ForEach(quantization) { sample in
                PointMark(x: .value("Fotogramma", sample.displayOrder), y: .value("QP", sample.qp))
                    .foregroundStyle(by: .value("Tipo", Self.typeName(sample.frameType)))
                    .symbolSize(12)
            }

            if let hoveredFrame {
                RuleMark(x: .value("Fotogramma", hoveredFrame))
                    .foregroundStyle(.gray.opacity(0.4))
                    .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        if let sample = quantizationSample(at: hoveredFrame) {
                            ChartTooltip(lines: [
                                "QP: \(sample.qp.formatted(.number.precision(.fractionLength(2)))) · tipo \(sample.frameType)",
                                "Ordine di codifica: \(sample.encodeOrder)"
                            ])
                        }
                    }
            }
        }
        .chartOverlay { pointerOverlay($0) }
        .chartXScale(domain: frameDomain)
        .chartYScale(domain: .automatic(includesZero: false))
        .chartYAxis { alignedYAxis() }
        .chartYAxisLabel("QP")
        .chartForegroundStyleScale(
            domain: Self.typeScale(quantization.map { Self.typeName($0.frameType) }).domain,
            range: Self.typeScale(quantization.map { Self.typeName($0.frameType) }).range
        )
        .chartLegend(position: .top, alignment: .trailing)
        .frame(height: 140 * heightScale)
    }

    /// La dimensione di ogni fotogramma, colorata per tipo, oppure il bitrate al secondo.
    private var sizeChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Il bitrate al secondo richiede il frame rate.
            if framesPerSecond != nil {
                Picker("Dimensioni", selection: $showsBitratePerSecond) {
                    Text("Dimensione dei fotogrammi").tag(false)
                    Text("Bitrate al secondo").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            Chart {
                if showsBitratePerSecond {
                    let points = bitratePoints

                    ForEach(points) { point in
                        // Una linea sottile come quella del VMAF, per confrontarle a colpo d'occhio.
                        LineMark(x: .value("Fotogramma", point.frame), y: .value("kb/s", point.value))
                            .interpolationMethod(.linear)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }

                    if !points.isEmpty {
                        RuleMark(y: .value("Media", points.map(\.value).reduce(0, +) / Double(points.count)))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(sizePoints) { point in
                        // Barre sottili (una per fotogramma o per intervallo): con la larghezza automatica
                        // si sovrapporrebbero, e il grafico non sarebbe confrontabile con la linea del VMAF.
                        BarMark(x: .value("Fotogramma", point.frame), y: .value("kB", point.value), width: .fixed(1.5))
                            .foregroundStyle(by: .value("Tipo", point.type))
                    }
                }

                if let hoveredFrame, frameSizes.indices.contains(hoveredFrame) {
                    RuleMark(x: .value("Fotogramma", hoveredFrame))
                        .foregroundStyle(.gray.opacity(0.4))
                        .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            ChartTooltip(lines: [sizeTooltipLine(for: hoveredFrame)])
                        }
                }
            }
            .chartOverlay { pointerOverlay($0) }
            .chartXScale(domain: frameDomain)
            .chartYAxis { alignedYAxis() }
            .chartYAxisLabel(showsBitratePerSecond ? "kb/s" : "kB")
            .chartXAxisLabel("Fotogramma")
            .chartForegroundStyleScale(
                domain: Self.typeScale(sizePoints.map(\.type)).domain,
                range: Self.typeScale(sizePoints.map(\.type)).range
            )
            .chartLegend(showsBitratePerSecond || sizeTypes == nil ? .hidden : .visible)
            .chartLegend(position: .top, alignment: .trailing)
            .frame(height: 140 * heightScale)
        }
    }

    // MARK: Testi

    /// Le righe del riquadro del VMAF: fotogramma, istante nell'originale, VMAF.
    private func vmafTooltipLines(for frame: Int) -> [String] {
        var lines = ["Fotogramma \(frame)"]

        if let framesPerSecond, framesPerSecond > 0 {
            lines.append("Istante nell'originale: \(MediaValueFormatter.timecode(startSeconds + Double(frame) / framesPerSecond))")
        }

        lines.append("VMAF: \(vmaf[frame].formatted(.number.precision(.fractionLength(2))))")

        if onSelectFrame != nil {
            lines.append("Clic per confrontare questo fotogramma")
        }

        return lines
    }

    /// La riga del riquadro delle dimensioni: il fotogramma o il secondo sotto il puntatore.
    private func sizeTooltipLine(for frame: Int) -> String {
        if showsBitratePerSecond, let framesPerSecond {
            let second = Int(Double(frame) / framesPerSecond)
            let bitrates = FrameSizeStatistics.bitratePerSecondKbps(frameSizes: frameSizes, framesPerSecond: framesPerSecond)

            guard bitrates.indices.contains(second) else { return "" }
            return "Secondo \(second + 1): \(MediaValueFormatter.bitRate(Int64(bitrates[second] * 1000)))"
        }

        let type = sizeTypes.map { " · tipo \($0[frame])" } ?? ""
        return "Dimensione: \(MediaValueFormatter.bytes(Int64(frameSizes[frame])))\(type)"
    }

    /// La spiegazione sotto i grafici.
    private func captionText(worstFrame: Int?) -> String {
        var parts: [String] = []

        if let worstFrame {
            parts.append("Il punto rosso è il fotogramma peggiore (n. \(worstFrame), VMAF \(vmaf[worstFrame].formatted(.number.precision(.fractionLength(2)).grouping(.never)))); la linea tratteggiata è il 5° percentile.")
        }

        parts.append("I grafici condividono l'asse dei fotogrammi: un calo del VMAF insieme a un QP più alto o a fotogrammi più piccoli indica che l'encoder ha risparmiato bit in quel punto.")

        if frameSizes.isEmpty {
            parts.append("Le dimensioni dei fotogrammi non sono disponibili per questa analisi: rifalla per vederle.")
        }

        if onSelectFrame != nil {
            parts.append("Fai clic sulla curva del VMAF per confrontare un fotogramma con l'originale.")
        }

        return parts.joined(separator: " ")
    }
}

// MARK: - QP per fotogramma

/// Il QP delle codifiche software: la media per tipo di fotogramma (I, P, B) e l'elenco completo
/// dei valori, fotogramma per fotogramma.
///
/// L'andamento del QP lungo il video, allineato al VMAF, è invece in ``FrameTimelineView``.
struct FrameQuantizationView: View {
    /// I campioni, in ordine di visualizzazione.
    let samples: [FrameQuantizationSample]

    var body: some View {
        // I campioni arrivano già nell'ordine di visualizzazione (vedi `FrameQuantizationParser`).
        VStack(alignment: .leading, spacing: 12) {

            Divider()

            Text("Quantizzazione effettiva per fotogramma")
                .font(.subheadline.weight(.semibold))

            HStack(alignment: .top, spacing: 24) {

                frameQuantizationTypeMetric(
                    "I",
                    samples: samples
                )

                frameQuantizationTypeMetric(
                    "P",
                    samples: samples
                )

                frameQuantizationTypeMetric(
                    "B",
                    samples: samples
                )
            }

            DisclosureGroup(
                "Dettaglio dei valori per fotogramma (\(samples.count))"
            ) {

                VStack(alignment: .leading, spacing: 6) {

                    HStack(spacing: 8) {
                        Text("Fotogramma")
                            .frame(width: 80, alignment: .center)

                        Text("Ordine di codifica")
                            .frame(width: 120, alignment: .center)

                        Text("POC")
                            .frame(width: 50, alignment: .center)

                        Text("Tipo")
                            .frame(width: 40, alignment: .center)

                        Text("QP")
                            .frame(width: 50, alignment: .center)
                    }
                    .font(.caption.weight(.semibold))

                    Divider()

                    ScrollView {
                        // Con i video lunghi le righe sono migliaia: si creano solo quelle visibili.
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(samples) { sample in
                                HStack(spacing: 8) {
                                    // La posizione nel video: il POC non va bene, perché in H.264 cresce di 2.
                                    Text(sample.displayOrder.formatted())
                                        .frame(width: 80, alignment: .center)

                                    Text(sample.encodeOrder.formatted())
                                        .frame(width: 120, alignment: .center)

                                    Text(sample.pictureOrderCount.formatted())
                                        .frame(width: 50, alignment: .center)

                                    Text(sample.frameType)
                                        .frame(width: 40, alignment: .center)

                                    Text(sample.qp.formatted(.number.precision(.fractionLength(2)).grouping(.never)))
                                        .frame(width: 50, alignment: .center)
                                }
                                .font(.system(.caption, design: .monospaced))
                            }
                        }
                    }
                    .frame(
                        height: min(
                            220,
                            CGFloat(samples.count) * 25
                        )
                    )
                }
                .padding(.top, 6)
            }

            Text(
                "I fotogrammi sono nell'ordine di visualizzazione; «Ordine di codifica» indica in che ordine l'encoder li ha codificati. " +
                "I due ordini differiscono perché un B usa come riferimento anche fotogrammi successivi, che vanno quindi codificati prima. " +
                "Il POC (Picture Order Count) è il numero con cui il decoder ridispone i fotogrammi nel corretto ordine di visualizzazione. " +
                "Il QP è quello riportato dall'encoder per ogni fotogramma; il grafico è nel pannello «Lungo il video». " +
                "I valori medi I/P/B sono calcolati sui rispettivi fotogrammi."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// Il QP medio e il numero dei fotogrammi di un tipo.
    ///
    /// - Parameters:
    ///   - frameType: "I", "P" o "B".
    ///   - samples: Tutti i campioni.
    private func frameQuantizationTypeMetric(
        _ frameType: String,
        samples: [FrameQuantizationSample]
    ) -> some View {

        let matchingSamples = samples.filter {
            $0.frameType == frameType
        }

        let meanQP: Double? = matchingSamples.isEmpty
            ? nil
            : matchingSamples.reduce(0.0) { $0 + $1.qp }
                / Double(matchingSamples.count)

        return VStack(alignment: .leading, spacing: 4) {

            Text("\(frameType)-frame")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(
                meanQP.map {
                    $0.formatted(.number.precision(.fractionLength(2)).grouping(.never))
                } ?? "—"
            )
            .font(.system(.body, design: .rounded).weight(.semibold))
            .monospacedDigit()

            Text("\(matchingSamples.count) frame")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
