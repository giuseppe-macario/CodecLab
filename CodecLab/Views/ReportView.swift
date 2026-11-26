// ReportView.swift
// Sezione Relazione: la relazione su un file originale scritta da CodecLab, sempre aggiornata,
// da copiare o salvare in Markdown.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// La sezione Relazioni: il punto d'arrivo del lavoro su un file.
///
/// Si sceglie un file originale e se ne legge la relazione, scritta da CodecLab con i valori misurati:
/// il file, le codifiche, la qualità (classifica, tempi, tabella), l'audio e, in evidenza,
/// la codifica migliore tra quelle provate. La relazione si ricalcola da sola quando cambiano
/// esperimenti o analisi, e si può copiare o salvare in Markdown.
struct ReportView: View {
    @Environment(AppViewModel.self) private var appModel

    /// La relazione del file scelto; `nil` mentre si raccolgono i dati.
    @State private var report: AnalysisReport?
    /// Vero mentre si raccolgono i dati.
    @State private var isLoading = false

    /// I file originali della Libreria, per nome.
    private var sources: [MediaLibraryItem] {
        appModel.libraryItems.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Il file scelto: quello scelto per ultimo qui o in Analisi qualità, altrimenti quello
    /// dell'esperimento video più recente (o di un esperimento audio), altrimenti il primo della Libreria.
    private var selectedSourceID: UUID? {
        let ids = Set(sources.map(\.id))

        if let focused = appModel.focusedSourceID, ids.contains(focused) {
            return focused
        }

        let recent = appModel.experiments
            .filter { ids.contains($0.sourceVideoID) }
            .max { $0.createdAt < $1.createdAt }?.sourceVideoID

        return recent ?? appModel.audioExperiments.first { ids.contains($0.sourceVideoID) }?.sourceVideoID ?? sources.first?.id
    }

    /// Vero se il file scelto ha esperimenti video o audio: altrimenti la relazione direbbe poco.
    private var hasExperiments: Bool {
        guard let id = selectedSourceID else { return false }
        return appModel.experiments.contains { $0.sourceVideoID == id } || appModel.audioExperiments.contains { $0.sourceVideoID == id }
    }

    /// Ciò da cui dipende la relazione: quando cambia (un altro file, una codifica o un'analisi finita…)
    /// la relazione si ricalcola.
    private var reportKey: String {
        guard let id = selectedSourceID else { return "nessuno" }

        let experiments = appModel.experiments.filter { $0.sourceVideoID == id }
        let experimentIDs = Set(experiments.map(\.id))
        let analyses = appModel.qualityAnalysisResults.filter { experimentIDs.contains($0.experimentID) }
        let audio = appModel.audioExperiments.filter { $0.sourceVideoID == id }

        return [
            id.uuidString,
            experiments.map { "\($0.id)\($0.status)" }.joined(),
            analyses.map(\.id.uuidString).joined(),
            audio.map { "\($0.id)\($0.status)" }.joined()
        ].joined(separator: "|")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Relazioni")
                        .font(.largeTitle.bold())

                    Text("La sintesi del lavoro su un file originale: codifiche, qualità, audio e raccomandazione, generata da CodecLab con i valori misurati ed Apple Intelligence.")
                        .foregroundStyle(.secondary)
                }

                if sources.isEmpty {
                    ContentUnavailableView(
                        "Nessun file nella Libreria",
                        systemImage: "doc.text",
                        description: Text("Aggiungi un file alla Libreria e crea qualche esperimento: qui troverai la relazione.")
                    )
                    .frame(maxWidth: .infinity)
                } else {
                    HStack {
                        Picker("File originale", selection: Binding(
                            get: { selectedSourceID ?? UUID() },
                            set: { appModel.focusedSourceID = $0 }
                        )) {
                            ForEach(sources) { item in
                                Text(item.name).tag(item.id)
                            }
                        }
                        // Larghezza naturale: etichetta e menu restano allineati a sinistra.
                        .fixedSize()

                        Spacer()

                        Button("Copia", systemImage: "doc.on.doc") {
                            if let report {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(report.markdown, forType: .string)
                            }
                        }
                        .disabled(report == nil || !hasExperiments)
                        .help("Copia la relazione in formato Markdown")

                        Button("Salva…", systemImage: "square.and.arrow.down") {
                            if let report {
                                save(report)
                            }
                        }
                        .disabled(report == nil || !hasExperiments)
                        .help("Salva la relazione in un file Markdown (.md)")
                    }

                    if !hasExperiments {
                        ContentUnavailableView(
                            "Nessun esperimento su questo file",
                            systemImage: "testtube.2",
                            description: Text("Crea esperimenti video (per esempio una serie hardware / software) o audio, e analizza la qualità delle codifiche: la relazione si scrive da sola.")
                        )
                        .frame(maxWidth: .infinity)
                    } else if let report {
                        reportContent(report)
                            .opacity(isLoading ? 0.5 : 1)
                    } else {
                        ProgressView("Raccolta dei dati…")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 950, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Relazioni")
        // Si ricalcola quando cambia il file scelto o qualcosa nei suoi esperimenti e analisi.
        .task(id: reportKey) {
            await load()
        }
    }

    // MARK: - Relazione

    /// Titolo e sezioni della relazione, con la raccomandazione in fondo.
    private func reportContent(_ report: AnalysisReport) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Relazione su \(report.sourceName)")
                    .font(.title2.bold())

                Text("Generata da CodecLab il \(report.createdAt.formatted(date: .long, time: .shortened)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(report.sections) { section in
                sectionContent(section)
            }

            // La raccomandazione chiude la relazione, in evidenza.
            if let recommendation = report.recommendation {
                recommendationBox(recommendation, criterion: report.recommendationCriterion)
            }
        }
    }

    /// Il riquadro della raccomandazione.
    private func recommendationBox(_ recommendation: String, criterion: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Codifica migliore tra quelle provate", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.tint)

            Text(recommendation)
                .font(.body.weight(.medium))

            // Il criterio in un paragrafo a parte, con meno risalto della risposta.
            if let criterion {
                Text(criterion)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.tint.opacity(0.4)))
    }

    /// Una sezione: titolo, paragrafi e tabelle.
    private func sectionContent(_ section: ReportSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title)
                .font(.title3.weight(.semibold))

            ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(Array(section.tables.enumerated()), id: \.offset) { _, table in
                tableContent(table)
            }
        }
    }

    /// Una tabella della relazione, con la nota sotto.
    private func tableContent(_ table: ReportTable) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = table.title {
                Text(title)
                    .font(.callout.weight(.semibold))
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    ForEach(Array(table.headers.enumerated()), id: \.offset) { _, header in
                        Text(header)
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                Divider()

                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell)
                        }
                    }
                    .font(.callout)
                    .monospacedDigit()
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

            if let note = table.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Preparazione

    /// Raccoglie i dati e prepara la relazione.
    private func load() async {
        guard let sourceID = selectedSourceID, hasExperiments else {
            report = nil
            return
        }

        isLoading = true
        defer { isLoading = false }

        let item = appModel.libraryItems.first { $0.id == sourceID }
        let experiments = appModel.experiments.filter { $0.sourceVideoID == sourceID }
        let experimentIDs = Set(experiments.map(\.id))
        let analyses = appModel.qualityAnalysisResults.filter { experimentIDs.contains($0.experimentID) }
        let audioExperiments = appModel.audioExperiments.filter { $0.sourceVideoID == sourceID }
        let sourceName = item?.name ?? experiments.first?.sourceName ?? "file"

        // Contenitore e tracce si rileggono dal file; se non è raggiungibile, si usano i dati salvati.
        let document = await appModel.probeLibraryItem(sourceID)

        report = ReportBuilder.report(
            sourceName: sourceName,
            item: item,
            document: document,
            fileFingerprint: appModel.fileFingerprint(of: sourceID),
            experiments: experiments,
            analyses: analyses,
            audioExperiments: audioExperiments
        )
    }

    // MARK: - Salvataggio

    /// Chiede dove salvare la relazione e la scrive in Markdown.
    private func save(_ report: AnalysisReport) {
        let baseName = URL(fileURLWithPath: report.sourceName).deletingPathExtension().lastPathComponent

        let panel = NSSavePanel()
        panel.title = "Salva la relazione"
        panel.nameFieldStringValue = "Relazione \(baseName).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try report.markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            appModel.errorMessage = "Impossibile salvare la relazione: \(error.localizedDescription)"
        }
    }
}
