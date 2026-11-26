// SearchView.swift
// Sezione Cerca codifiche: si scrive una frase, Apple Intelligence la traduce in un filtro (le etichette)
// e CodecLab elenca le codifiche che lo soddisfano, raggruppate per video, con i collegamenti
// all'analisi e alla relazione.

import SwiftUI

/// La sezione Cerca codifiche: trovare le codifiche scrivendo che cosa si cerca, per esempio
/// «HEVC via hardware con VMAF sopra 90».
///
/// La frase diventa un filtro, mostrato come etichette che si possono togliere; i risultati sono
/// raggruppati per video, con i collegamenti all'analisi di ogni codifica e alla relazione del video.
/// Gli esempi sotto la descrizione usano i video della Libreria. Vedi ``ExperimentSearch``
/// per come viene interpretata la frase.
struct SearchView: View {
    @Environment(AppViewModel.self) private var appModel

    /// Apre un'analisi in Analisi qualità.
    let onShowAnalysis: (UUID) -> Void
    /// Apre la relazione su un file originale.
    let onShowReport: (UUID) -> Void

    /// Gli esempi mostrati sotto la descrizione: un clic li cerca. Usano i video della Libreria,
    /// così funzionano davvero.
    private var examples: [String] {
        let names = sourceNames
        let words = names.compactMap { ExperimentSearch.identifyingWord(of: $0, among: names) }

        return [
            words.first.map { "HEVC via hardware su \($0) con VMAF sopra 90" } ?? "HEVC via hardware con VMAF sopra 90",
            "Codifiche software sotto 1 Mb/s",
            "H.264 con il fotogramma peggiore sotto 50",
            (words.dropFirst().first ?? words.first).map { "\($0) tra 2000 e 5000 kb/s" } ?? "Bitrate tra 2000 e 5000 kb/s",
            "Via hardware con VMAF medio tra 80 e 90"
        ]
    }

    /// Vero mentre Apple Intelligence riformula la frase.
    @State private var isRewriting = false
    /// Il messaggio dell'ultima ricerca, se la frase non è stata capita.
    @State private var message: String?

    /// Una codifica trovata, con la sua ultima analisi.
    private struct Match: Identifiable {
        let experiment: EncodingExperiment
        let analysis: VideoQualityAnalysisResult?
        var id: UUID { experiment.id }

        var measuredKbps: Double? {
            experiment.outputInfo?.videoBitrateBitsPerSecond.map { Double($0) / 1000 }
        }
    }

    /// Le codifiche di un video.
    private struct SourceGroup: Identifiable {
        let sourceID: UUID
        let sourceName: String
        let matches: [Match]
        var id: UUID { sourceID }
    }

    /// I nomi dei video originali della Libreria.
    private var sourceNames: [String] {
        appModel.libraryItems.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// I risultati del filtro, raggruppati per video e ordinati come nei confronti.
    private var groups: [SourceGroup] {
        guard let filter = appModel.searchFilter else { return [] }

        let matches = appModel.experiments.compactMap { experiment -> Match? in
            let analysis = appModel.latestQualityAnalysis(for: experiment.id)
            let match = Match(experiment: experiment, analysis: analysis)

            return filter.matches(
                settings: experiment.settings,
                sourceName: experiment.sourceName,
                measuredKbps: match.measuredKbps,
                meanVMAF: analysis?.summary.vmaf?.mean,
                lowestVMAF: analysis?.vmafMinimum
            ) ? match : nil
        }

        return Dictionary(grouping: matches, by: \.experiment.sourceVideoID)
            .map { sourceID, matches in
                SourceGroup(
                    sourceID: sourceID,
                    sourceName: matches[0].experiment.sourceName,
                    matches: matches.sorted {
                        EncodingSettings.comparisonOrder(
                            ($0.experiment.settings, $0.measuredKbps),
                            ($1.experiment.settings, $1.measuredKbps)
                        )
                    }
                )
            }
            .sorted { $0.sourceName.localizedStandardCompare($1.sourceName) == .orderedAscending }
    }

    var body: some View {
        @Bindable var appModel = appModel

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Cerca codifiche")
                        .font(.largeTitle.bold())

                    Text("Cerca tra le codifiche, le loro analisi e le relazioni. CodecLab traduce la tua richiesta in un filtro e mostra le codifiche che lo soddisfano; se la richiesta contiene parole che CodecLab non conosce, Apple Intelligence la riformula.")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Per esempio:")
                        .foregroundStyle(.secondary)

                    ForEach(examples, id: \.self) { example in
                        Button(example) {
                            appModel.searchText = example
                            Task { await search() }
                        }
                        .buttonStyle(.link)
                        .disabled(isRewriting)
                    }
                }
                .font(.callout)

                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        TextField(
                            "Richiesta",
                            text: $appModel.searchText,
                            prompt: Text("Scrivi che cosa cerchi")
                        )
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await search() } }

                        Button("Cerca") {
                            Task { await search() }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isRewriting || appModel.searchText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    if isRewriting {
                        ProgressView("Apple Intelligence sta provando a interpretare la richiesta…")
                            .controlSize(.small)
                    } else if let message {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let rewrite = appModel.searchRewrite {
                        Label("Riformulata da Apple Intelligence come «\(rewrite)».", systemImage: "apple.intelligence")
                            .foregroundStyle(.secondary)
                    }

                    if let filter = appModel.searchFilter, !isRewriting {
                        results(for: filter)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 950, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Cerca codifiche")
    }

    // MARK: - Ricerca

    /// Interpreta la frase; se contiene parole sconosciute, la fa riformulare ad Apple Intelligence
    /// e interpreta la riformulazione. Una frase capita solo in parte non viene mai usata.
    private func search() async {
        let query = appModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isRewriting else { return }

        message = nil
        appModel.searchRewrite = nil

        let interpretation = ExperimentSearch.interpret(query, sourceNames: sourceNames)
        if interpretation.isComplete {
            appModel.searchFilter = interpretation.filter
            return
        }

        appModel.searchFilter = nil

        guard ExperimentSearch.isAppleIntelligenceAvailable else {
            message = "CodecLab non ha potuto interpretare la tua richiesta, e Apple Intelligence non è disponibile (vedi Sistema)."
            return
        }

        isRewriting = true
        defer { isRewriting = false }

        do {
            let rewrite = try await ExperimentSearch.rewrite(query, sourceNames: sourceNames)
            let second = ExperimentSearch.interpret(rewrite, sourceNames: sourceNames)

            if !rewrite.isEmpty, second.isComplete {
                appModel.searchFilter = second.filter
                appModel.searchRewrite = rewrite
            } else {
                message = Self.notUnderstoodMessage
            }
        } catch {
            message = Self.notUnderstoodMessage
        }
    }

    /// Il messaggio per una richiesta che né CodecLab né Apple Intelligence hanno capito.
    private static let notUnderstoodMessage = "Né CodecLab né Apple Intelligence hanno potuto interpretare la tua richiesta."

    // MARK: - Risultati

    /// Le etichette del filtro e i risultati.
    @ViewBuilder
    private func results(for filter: ExperimentSearchFilter) -> some View {
        if !filter.isEmpty {
            // Le etichette vanno a capo quando non stanno su una riga: il nome di un video può essere lungo.
            FlowLayout(spacing: 6) {
                ForEach(filter.labels, id: \.field) { label in
                    Button {
                        appModel.searchFilter?.remove(label.field)
                    } label: {
                        HStack(spacing: 4) {
                            Text(label.text)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.bold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.tint.opacity(0.15), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Togli questa condizione")
                }
            }
        }

        let groups = groups

        if groups.isEmpty {
            ContentUnavailableView(
                "Nessuna codifica trovata",
                systemImage: "magnifyingglass",
                description: Text(filter.needsAnalysis
                    ? "Nessuna codifica analizzata soddisfa tutte le condizioni. Prova a togliere un'etichetta."
                    : "Nessuna codifica soddisfa tutte le condizioni. Prova a togliere un'etichetta.")
            )
            .frame(maxWidth: .infinity)
        } else {
            Text(groups.count == 1 && groups[0].matches.count == 1
                 ? "1 codifica trovata."
                 : "\(groups.map(\.matches.count).reduce(0, +)) codifiche trovate in \(groups.count == 1 ? "1 video" : "\(groups.count) video").")
                .font(.callout)
                .foregroundStyle(.secondary)

            ForEach(groups) { group in
                groupContent(group)
            }
        }
    }

    /// Le codifiche di un video, con il collegamento alla relazione.
    private func groupContent(_ group: SourceGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(group.sourceName)
                    .font(.title3.weight(.semibold))

                Spacer()

                if appModel.libraryItems.contains(where: { $0.id == group.sourceID }) {
                    Button("Vedi la relazione su questo file", systemImage: "doc.text") {
                        onShowReport(group.sourceID)
                    }
                    .buttonStyle(.link)
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(group.matches.enumerated()), id: \.element.id) { index, match in
                    if index > 0 { Divider() }
                    row(match)
                }
            }
            .padding(.horizontal, 12)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    /// Una codifica: impostazioni, bitrate, VMAF e collegamento all'analisi.
    private func row(_ match: Match) -> some View {
        let settings = match.experiment.settings

        let rate: String = switch settings.effectiveRateControlMode {
        case .bitrate: "obiettivo \(settings.videoBitrateKbps) kb/s"
        case .constantQuality: "CRF \(settings.crfValue)"
        case .constantQuantizer: "QP \(settings.quantizerValue)"
        }

        var details = [rate]
        if let measured = match.experiment.outputInfo?.videoBitrateBitsPerSecond {
            details.append("misurato \(MediaValueFormatter.bitRate(measured))")
        }
        if let clip = settings.clip {
            details.append(clip.description)
        }

        let quality: String
        if let analysis = match.analysis, let mean = analysis.summary.vmaf?.mean {
            quality = "VMAF medio \(mean.formatted(.number.precision(.fractionLength(1))))" +
                (analysis.vmafMinimum.map { " · minimo \($0.formatted(.number.precision(.fractionLength(1))))" } ?? "")
        } else if match.experiment.status == .completed {
            quality = "Non analizzata"
        } else {
            quality = match.experiment.status.title
        }

        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(settings.codec.title) \(settings.profile.title) \(settings.backend.title)")
                    .font(.body.weight(.medium))

                Text(details.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let fileName = match.experiment.outputFileName {
                    Text(fileName)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Text(quality)
                .font(.callout.monospacedDigit())
                .foregroundStyle(match.analysis == nil ? .secondary : .primary)

            if let analysis = match.analysis {
                Button("Vedi analisi") {
                    onShowAnalysis(analysis.id)
                }
                .buttonStyle(.link)
            }
        }
        .padding(.vertical, 8)
    }
}
