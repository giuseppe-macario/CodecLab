// AudioView.swift
// Sezione Esperimenti audio: serie di codifiche AAC della sola traccia audio, a diversi bitrate,
// e peso dell'audio sul file insieme al video originale.

import AppKit
import SwiftUI

/// La sezione Esperimenti audio: quanto pesa la traccia audio di un file a diversi bitrate AAC.
///
/// «Crea serie audio» codifica la traccia con i due encoder AAC (FFmpeg e Apple) a cinque bitrate.
/// Per ogni codifica si vedono il bitrate effettivo, la dimensione e il tempo, e, se il file ha anche
/// un video, quanto l'audio pesa sul file completo. La qualità dell'audio non viene misurata,
/// perché FFmpeg non ha una metrica percettiva per l'audio.
struct AudioView: View {
    @Environment(AppViewModel.self) private var appModel
    /// Apre la relazione su un file originale.
    let onShowReport: (UUID) -> Void
    /// Il file scelto per la nuova serie.
    @State private var selectedSourceID: UUID?
    /// Lo spezzone della nuova serie; `nil` per il file intero.
    @State private var clip: ClipRange?
    /// L'esperimento di cui si sta confermando l'eliminazione.
    @State private var experimentToDelete: AudioExperiment?
    /// Vero mentre è aperta la conferma dell'eliminazione.
    @State private var isDeleteConfirmationPresented = false

    /// Gli esperimenti audio dello stesso file e dello stesso spezzone: solo questi sono confrontabili.
    private struct AudioGroup: Identifiable {
        let id: String
        let title: String
        let experiments: [AudioExperiment]
    }

    /// I gruppi di esperimenti, in ordine di nome; dentro ogni gruppo, per encoder e bitrate.
    private var groups: [AudioGroup] {
        let grouped = Dictionary(grouping: appModel.audioExperiments) { experiment in
            "\(experiment.sourceVideoID)|\(experiment.clip.map { "\($0.startSeconds)+\($0.durationSeconds)" } ?? "intero")"
        }

        return grouped.map { id, experiments in
            let first = experiments[0]

            return AudioGroup(
                id: id,
                title: first.clip.map { "\(first.sourceName) (\($0.description))" } ?? first.sourceName,
                experiments: experiments.sorted {
                    ($0.encoder.rawValue, $0.bitrateKbps) < ($1.encoder.rawValue, $1.bitrateKbps)
                }
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Solo i file con una traccia audio (video con audio o file solo audio).
    private var audioItems: [MediaLibraryItem] {
        appModel.libraryItems.filter(\.hasAudio)
    }

    /// Gli encoder usati dalle serie, per esempio "AAC (FFmpeg) e AAC (AudioToolbox)".
    private var encodersDescription: String {
        appModel.isAppleAACAvailable == true
            ? "\(AudioEncoder.ffmpeg.title) e \(AudioEncoder.apple.title)"
            : AudioEncoder.ffmpeg.title
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Esperimenti audio")
                        .font(.largeTitle.bold())

                    Text("Peso della traccia audio a diversi bitrate AAC.")
                        .foregroundStyle(.secondary)
                }

                GroupBox("Nuova serie audio") {
                    VStack(alignment: .leading, spacing: 14) {
                        if audioItems.isEmpty {
                            Text("Importa prima nella libreria un file con una traccia audio.")
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("File originale", selection: $selectedSourceID) {
                                Text("Seleziona un file")
                                    .tag(nil as UUID?)

                                ForEach(audioItems) { item in
                                    Text(item.name)
                                        .tag(Optional(item.id))
                                }
                            }

                            ClipEditor(clip: $clip, sourceDuration: audioItems.first { $0.id == selectedSourceID }?.durationSeconds)

                            Divider()

                            Text("Codifica solo la prima traccia audio con \(encodersDescription) a \(AudioExperiment.seriesBitratesKbps.map(String.init).joined(separator: ", ")) kb/s. Sono codifiche veloci, eseguite in coda. La qualità dell'audio non viene ancora misurata: per ora si confrontano bitrate effettivo, dimensione e tempo.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack {
                                Spacer()

                                Button("Crea serie audio", systemImage: "waveform") {
                                    if let sourceID = selectedSourceID, let folder = chooseOutputFolder() {
                                        // Lo spezzone si copia al clic, come le impostazioni della serie video.
                                        let clip = clip

                                        Task {
                                            await appModel.createAudioSeries(sourceID: sourceID, clip: clip, outputFolder: folder)
                                        }
                                    }
                                }
                                .disabled(
                                    !audioItems.contains { $0.id == selectedSourceID } ||
                                    !appModel.areToolsAvailable ||
                                    appModel.isCreatingAudioSeries ||
                                    appModel.jobs.isBusy   // Si crea al termine dei lavori o dopo l'annullamento.
                                )
                                .help(appModel.jobs.isBusy ? "Disponibile al termine dei lavori in corso (o dopo averli annullati)" : "Crea la serie audio e mette in coda le codifiche")
                            }

                            // Lo stato della coda, sotto il pulsante che la riempie.
                            QueueStatusView()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
                }

                if let job = appModel.jobs.current, job.kind == .audioEncoding {
                    JobProgressView(job: job)
                }

                if appModel.audioExperiments.isEmpty {
                    ContentUnavailableView(
                        "Nessuna serie audio",
                        systemImage: "waveform",
                        description: Text("Scegli un file con una traccia audio e crea una serie audio.")
                    )
                    .frame(maxWidth: .infinity)
                } else {
                    ForEach(groups) { group in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 16) {
                                resultsGrid(group.experiments)

                                // Il peso dell'audio sul totale ha senso solo se il file ha anche un video.
                                if let first = group.experiments.first, sourceHasVideo(first) {
                                    audioShareTable(for: group.experiments, source: first)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                        } label: {
                            HStack {
                                Text(group.title)
                                    .font(.headline)

                                Spacer()

                                // La relazione comprende anche gli esperimenti audio del file.
                                if let sourceID = group.experiments.first?.sourceVideoID,
                                   appModel.libraryItems.contains(where: { $0.id == sourceID }) {
                                    Button("Vedi la relazione su questo file", systemImage: "doc.text") {
                                        onShowReport(sourceID)
                                    }
                                    .buttonStyle(.link)
                                    .help("Apre la sezione Relazioni su questo file originale")
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 950, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Esperimenti audio")
        .confirmationDialog(
            experimentToDelete.map { "Eliminare l'esperimento \($0.encoder.title) a \($0.bitrateKbps) kb/s?" } ?? "",
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            // Come per i video: si elimina l'esperimento o, in blocco, tutta la serie dello stesso file
            // (e dello stesso spezzone).
            let series = experimentToDelete.map(seriesExperiments(of:)) ?? []

            Button(series.count > 1 ? "Elimina solo questo esperimento" : "Elimina", role: .destructive) {
                if let experiment = experimentToDelete {
                    appModel.removeAudioExperiments(ids: [experiment.id])
                }

                experimentToDelete = nil
            }

            if series.count > 1 {
                Button("Elimina tutta la serie (\(series.count) esperimenti)", role: .destructive) {
                    appModel.removeAudioExperiments(ids: Set(series.map(\.id)))
                    experimentToDelete = nil
                }
            }

            Button("Annulla", role: .cancel) {
                experimentToDelete = nil
            }
        } message: {
            Text(experimentToDelete.map(seriesExperiments(of:)).map { $0.count > 1 } == true
                 ? "I file .m4a eliminati verranno spostati nel Cestino."
                 : "Il file .m4a verrà spostato nel Cestino.")
        }
    }

    /// Gli esperimenti della stessa serie: stesso file originale e stesso spezzone.
    ///
    /// - Parameter experiment: Un esperimento della serie.
    private func seriesExperiments(of experiment: AudioExperiment) -> [AudioExperiment] {
        appModel.audioExperiments.filter {
            $0.sourceVideoID == experiment.sourceVideoID && $0.clip == experiment.clip
        }
    }

    // MARK: - Risultati

    /// La tabella dei risultati: encoder, bitrate obiettivo e misurato, dimensione, tempo e stato.
    private func resultsGrid(_ experiments: [AudioExperiment]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            GridRow {
                Text("Encoder")
                Text("Obiettivo")
                Text("Misurato")
                Text("Dimensione")
                Text("Tempo")
                Text("Stato")
                Text("")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            ForEach(experiments) { experiment in
                GridRow {
                    Text(experiment.encoder.title)
                    Text("\(experiment.bitrateKbps) kb/s")
                    Text(experiment.output?.bitrateBitsPerSecond.map(MediaValueFormatter.bitRate) ?? "—")
                    Text(experiment.output?.fileSizeBytes.map(MediaValueFormatter.bytes) ?? "—")
                    Text(experiment.output.map { MediaValueFormatter.duration($0.encodingDurationSeconds) } ?? "—")
                    Text(statusTitle(for: experiment))
                        .foregroundStyle(.secondary)

                    Button(role: .destructive) {
                        experimentToDelete = experiment
                        isDeleteConfirmationPresented = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(appModel.jobs.current?.experimentID == experiment.id)
                    .help("Elimina il risultato e sposta il file .m4a nel Cestino")
                }
                .font(.callout)
                .monospacedDigit()
            }
        }
    }

    /// Vero se il file originale dell'esperimento ha anche una traccia video.
    private func sourceHasVideo(_ experiment: AudioExperiment) -> Bool {
        appModel.libraryItems.first { $0.id == experiment.sourceVideoID }?.hasVideo ?? false
    }

    /// La tabella del peso dell'audio se lo si unisce al video del file originale,
    /// l'unica combinazione concreta di bitrate audio e video.
    ///
    /// Per l'audio vale il bitrate misurato, in media tra gli encoder. Se il video non è
    /// compresso o il suo bitrate non è noto, al posto della tabella compare una spiegazione.
    ///
    /// - Parameters:
    ///   - experiments: Gli esperimenti del gruppo.
    ///   - experiment: Un esperimento del gruppo, da cui ricavare il file originale.
    @ViewBuilder
    private func audioShareTable(for experiments: [AudioExperiment], source experiment: AudioExperiment) -> some View {
        let summary = appModel.libraryItems.first { $0.id == experiment.sourceVideoID }?.video
        // Il bitrate del video originale; `nil` se non è noto o se il video non è compresso
        // (accanto a un video non compresso il peso dell'audio è trascurabile).
        let videoKbps = summary.flatMap { summary in
            summary.isUncompressed ? nil : summary.bitrateBitsPerSecond.map { Double($0) / 1000 }
        }

        // Bitrate audio misurato per ogni obiettivo, in media tra gli encoder.
        let measured = AudioExperiment.averageMeasuredKbps(experiments)

        VStack(alignment: .leading, spacing: 8) {
            Text("Peso dell'audio con il video originale")
                .font(.subheadline.weight(.semibold))

            if let videoKbps {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        Text("Audio")
                        Text("Peso sul file")
                        Text("Dimensione al minuto")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                    ForEach(measured.keys.sorted(), id: \.self) { target in
                        let audioKbps = measured[target] ?? 0
                        let totalKbps = videoKbps + audioKbps

                        GridRow {
                            Text("\(target) kb/s")
                            Text((audioKbps / totalKbps).formatted(.percent.precision(.fractionLength(0))))
                            // kb/s × 1000 = bit/s; × 60 s ÷ 8 = byte al minuto.
                            Text(MediaValueFormatter.bytes(Int64(totalKbps * 1000 * 60 / 8)))
                        }
                        .font(.callout)
                        .monospacedDigit()
                    }
                }

                Text("Video del file originale: \(MediaValueFormatter.bitRate(Int64(videoKbps * 1000))). Per l'audio vale il bitrate misurato (media tra gli encoder). La dimensione al minuto è quella di video e audio insieme.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(summary?.isUncompressed == true
                     ? "Il video originale non è compresso: accanto a lui il peso dell'audio è trascurabile e il confronto non è significativo."
                     : "Bitrate del video originale non disponibile: riseleziona il file nella Libreria per leggerlo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Lo stato mostrato: «In codifica», «In coda» o quello salvato.
    private func statusTitle(for experiment: AudioExperiment) -> String {
        if appModel.jobs.current?.experimentID == experiment.id {
            return "In codifica"
        }

        if appModel.jobs.pending.contains(where: { $0.experimentID == experiment.id }) {
            return "In coda"
        }

        return experiment.status.title
    }

    /// Chiede la cartella in cui salvare i file della serie: si sceglie una volta, i nomi sono automatici.
    ///
    /// - Returns: La cartella, o `nil` se l'utente annulla.
    private func chooseOutputFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Cartella per i file audio della serie"
        panel.prompt = "Scegli"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true

        return panel.runModal() == .OK ? panel.url : nil
    }
}
