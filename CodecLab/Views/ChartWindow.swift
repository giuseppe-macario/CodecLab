// ChartWindow.swift
// La finestra con un grafico ingrandito: la curva qualità/bitrate di un video, oppure i grafici
// lungo il video di un'analisi. Si apre dal pulsante «Ingrandisci» (o con un clic sulla curva)
// in Analisi qualità, e si aggiorna da sola quando cambiano le analisi.

import SwiftUI

/// Il grafico da aprire in una finestra a parte: la curva qualità/bitrate di un video o i grafici
/// lungo il video di un'analisi.
///
/// È il valore con cui la finestra viene aperta, quindi contiene solo identificativi, non i dati:
/// la finestra li ritrova da sé e resta aggiornata. Usa solo tipi semplici (ed è `nonisolated`)
/// perché macOS lo salva e lo ripristina fuori dal thread principale.
nonisolated enum ChartWindowRequest: Codable, Hashable, Sendable {
    /// La curva di un gruppo (file originale e spezzone) per una metrica (il `rawValue` di ``QualityCurveMetric``).
    case curves(groupID: String, metric: String)
    /// I grafici lungo il video di un'analisi.
    case timeline(analysisID: UUID)
}

/// La finestra di un grafico ingrandito, aperta con il pulsante «Ingrandisci» (o con un clic sulla curva)
/// in Analisi qualità.
///
/// È ridimensionabile e mostra lo stesso grafico più grande, con le stesse informazioni al passaggio
/// del puntatore. Se le analisi del grafico vengono eliminate, lo dice invece di mostrare un grafico vuoto.
struct ChartWindowView: View {
    @Environment(AppViewModel.self) private var appModel

    /// Il grafico da mostrare; `nil` se la finestra viene ripristinata senza valore.
    let request: ChartWindowRequest?

    var body: some View {
        ScrollView {
            content
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 700, minHeight: 500)
        // Tutte le scritte della finestra si possono selezionare e copiare.
        .textSelection(.enabled)
        .navigationTitle(title)
    }

    /// Il grafico richiesto o, se i dati non ci sono più (analisi eliminata), un avviso.
    @ViewBuilder
    private var content: some View {
        switch request {
        case .curves(let groupID, let metricName):
            if let metric = QualityCurveMetric(rawValue: metricName), let group = curveGroup(id: groupID, metric: metric) {
                QualityCurveChartView(group: group, metric: metric, chartHeight: 520)
            } else {
                unavailable
            }

        case .timeline(let analysisID):
            if let result = appModel.qualityAnalysisResults.first(where: { $0.id == analysisID }), !result.vmafPerFrame.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(result.outputFileName)
                        .font(.headline)

                    Text(result.encodingSettings.codecDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    FrameTimelineView(
                        vmaf: result.vmafPerFrame,
                        percentile5: result.vmafPercentile5,
                        quantization: result.frameQuantizationSamples ?? [],
                        frameSizes: result.frameSizes ?? [],
                        frameTypes: result.frameTypes ?? "",
                        framesPerSecond: appModel.framesPerSecond(of: result),
                        startSeconds: result.encodingSettings.clip?.startSeconds ?? 0,
                        heightScale: 2
                    )
                    .padding(.top, 10)
                }
            } else {
                unavailable
            }

        case nil:
            unavailable
        }
    }

    /// L'avviso quando il grafico non esiste più.
    private var unavailable: some View {
        ContentUnavailableView(
            "Grafico non disponibile",
            systemImage: "chart.xyaxis.line",
            description: Text("Le analisi di questo grafico sono state eliminate.")
        )
        .frame(maxWidth: .infinity, minHeight: 400)
    }

    /// Il titolo della finestra.
    private var title: String {
        switch request {
        case .curves(let groupID, let metricName):
            guard let metric = QualityCurveMetric(rawValue: metricName) else { return "Grafico" }
            let name = curveGroup(id: groupID, metric: metric)?.sourceName
            return "Curva \(metric.title)" + (name.map { " · \($0)" } ?? "")
        case .timeline(let analysisID):
            let name = appModel.qualityAnalysisResults.first { $0.id == analysisID }?.outputFileName
            return "Lungo il video" + (name.map { " · \($0)" } ?? "")
        case nil:
            return "Grafico"
        }
    }

    /// Il gruppo di curve, ricostruito dalle analisi attuali con le stesse regole di Analisi qualità.
    private func curveGroup(id: String, metric: QualityCurveMetric) -> QualityCurveGroup? {
        QualityCurveGroupBuilder.build(
            results: appModel.qualityAnalysisResults,
            experiments: appModel.experiments,
            metric: metric
        )
        .first { $0.id == id }
    }
}
