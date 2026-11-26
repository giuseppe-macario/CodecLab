// ExperimentsView.swift
// Sezione Esperimenti video: creazione delle configurazioni di codifica,
// avvio di codifica e analisi qualità, avanzamento del lavoro in corso.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// La sezione Esperimenti video: dove si preparano e si lanciano le codifiche.
///
/// Si sceglie il file originale e si configurano codec, profilo, encoder, controllo del bitrate,
/// audio ed eventuale spezzone (GOP e, via software, B-frame sulla stessa riga). Poi:
/// - «Crea serie hardware / software» prepara otto codifiche, con bitrate adatti al video,
///   per confrontare i due encoder;
/// - «Crea esperimento» prepara una singola codifica con le impostazioni scelte.
///
/// Codifiche e analisi partono in coda. Sotto, l'elenco degli esperimenti salvati, con stato, misure,
/// riepilogo della qualità e collegamento all'analisi.
struct ExperimentsView: View {
    @Environment(AppViewModel.self) private var appModel

    /// Apre la sezione Analisi qualità sull'analisi indicata.
    let onShowAnalysis: (UUID) -> Void

    /// Il file originale scelto per i nuovi esperimenti.
    @State private var selectedSourceID: UUID?
    /// Le impostazioni dei nuovi esperimenti.
    @State private var experimentSettings = EncodingSettings()
    /// L'esperimento di cui si sta confermando l'eliminazione.
    @State private var experimentToDeleteID: UUID?
    /// Vero mentre è aperta la conferma dell'eliminazione.
    @State private var isDeleteExperimentConfirmationPresented = false

    /// Solo i file con una traccia video (esclusi quelli solo audio).
    private var videoItems: [MediaLibraryItem] {
        appModel.libraryItems.filter(\.hasVideo)
    }

    /// Falso se il video scelto non ha una traccia audio: in quel caso le opzioni audio non servono.
    private var selectedSourceHasAudio: Bool {
        videoItems.first { $0.id == sourceSelection.wrappedValue }?.hasAudio ?? true
    }

    // MARK: GOP e B-frame

    /// Il numero di B-frame consigliato (il valore predefinito di x264 e x265).
    private static let recommendedBFrameCount = 3

    /// Il frame rate del video scelto, se è noto.
    private var selectedFrameRate: Double? {
        videoItems.first { $0.id == sourceSelection.wrappedValue }?.video?.framesPerSecond
    }

    /// Il GOP consigliato: due secondi di fotogrammi (60 se il frame rate non è noto).
    private var recommendedGOP: Int {
        selectedFrameRate.map { min(max(Int(($0 * 2).rounded()), 1), 600) } ?? 60
    }

    /// Vero se GOP e B-frame sono quelli consigliati.
    private var hasRecommendedAdvancedSettings: Bool {
        experimentSettings.gopSize == recommendedGOP && experimentSettings.bFrameCount == Self.recommendedBFrameCount
    }

    /// Il GOP massimo in fotogrammi e, se il frame rate è noto, in secondi: "GOP: max 60 fotogrammi (2,0 s)".
    private var gopLabel: String {
        let frames = "GOP: max \(experimentSettings.gopSize) fotogrammi"
        guard let fps = selectedFrameRate, fps > 0 else { return frames }
        let seconds = Double(experimentSettings.gopSize) / fps
        return frames + " (\(seconds.formatted(.number.precision(.fractionLength(1)))) s)"
    }

    /// Il file originale scelto, solo se è ancora tra quelli con video.
    ///
    /// Scegliere un file imposta il GOP suggerito (due secondi), a meno che nel frattempo
    /// l'utente non abbia cambiato file o GOP.
    private var sourceSelection: Binding<UUID?> {
        Binding(
            get: {
                guard let id = selectedSourceID,
                      videoItems.contains(where: { $0.id == id }) else {
                    return nil
                }
                return id
            },
            set: { newValue in
                selectedSourceID = newValue

                guard let sourceID = newValue else {
                    return
                }

                let currentGOP = experimentSettings.gopSize

                Task {
                    guard let suggestedGOP = await appModel.suggestedGOP(
                        for: sourceID
                    ) else {
                        return
                    }

                    // Evita di applicare suggerimenti relativi
                    // a una selezione precedente.
                    guard selectedSourceID == sourceID,
                          experimentSettings.gopSize == currentGOP else {
                        return
                    }

                    experimentSettings.gopSize = suggestedGOP
                }
            }
        )
    }

    /// Il codec scelto; se il profilo attuale non è disponibile per il nuovo codec, passa al primo che lo è.
    private var codecSelection: Binding<VideoCodec> {
        Binding(
            get: {
                experimentSettings.codec
            },
            set: { newCodec in
                experimentSettings.codec = newCodec

                if !newCodec.profiles.contains(experimentSettings.profile),
                   let firstProfile = newCodec.profiles.first {
                    experimentSettings.profile = firstProfile
                }
            }
        )
    }

    /// Il tipo di encoder scelto; passando all'hardware, il controllo del rate torna a bitrate.
    private var backendSelection: Binding<EncodingBackend> {
        Binding(
            get: {
                experimentSettings.backend
            },
            set: { newBackend in
                experimentSettings.backend = newBackend

                // I controlli CRF e QP sono riservati agli encoder software.
                if newBackend == .hardware {
                    experimentSettings.rateControlMode = .bitrate
                }
            }
        )
    }

    /// Il profilo scelto, sempre tra quelli del codec.
    private var profileSelection: Binding<VideoProfile> {
        Binding(
            get: {
                let profiles = experimentSettings.codec.profiles

                if profiles.contains(experimentSettings.profile) {
                    return experimentSettings.profile
                }

                return profiles.first ?? .main
            },
            set: {
                experimentSettings.profile = $0
            }
        )
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                VStack(alignment: .leading, spacing: 4) {
                    Text("Esperimenti video")
                        .font(.largeTitle.bold())

                    Text("Configura e conserva le impostazioni di codifica.")
                        .foregroundStyle(.secondary)
                }

                GroupBox("Nuovo esperimento") {
                    VStack(alignment: .leading, spacing: 14) {

                        if videoItems.isEmpty {
                            Text("Importa prima un video nella libreria.")
                                .foregroundStyle(.secondary)
                        } else {

                            Picker("Video originale", selection: sourceSelection) {
                                Text("Seleziona un video")
                                    .tag(nil as UUID?)

                                ForEach(videoItems) { item in
                                    Text(item.name)
                                        .tag(Optional(item.id))
                                }
                            }

                            Divider()

                            Picker("Codec video", selection: codecSelection) {
                                ForEach(VideoCodec.allCases) { codec in
                                    Text(codec.title).tag(codec)
                                }
                            }
                            
                            Picker("Profilo", selection: profileSelection) {
                                ForEach(experimentSettings.codec.profiles) { profile in
                                    Text(profile.title)
                                        .tag(profile)
                                }
                            }

                            Picker("Encoder", selection: backendSelection) {
                                ForEach(EncodingBackend.allCases) { backend in
                                    Text(backend.title).tag(backend)
                                }
                            }

                            Divider()

                            // Via hardware il controllo del rate è sempre a bitrate: il menu serve solo via software.
                            if experimentSettings.backend == .software {
                                Picker(
                                    "Controllo del rate",
                                    selection: $experimentSettings.rateControlMode
                                ) {
                                    ForEach(EncodingRateControlMode.allCases) { mode in
                                        Text(mode.title).tag(mode)
                                    }
                                }
                            }

                            if experimentSettings.backend == .software,
                               experimentSettings.rateControlMode == .constantQuality {
                                Stepper(
                                    "CRF: \(experimentSettings.crfValue)",
                                    value: $experimentSettings.crfValue,
                                    in: 0...51
                                )

                                Text("CRF più basso tende a produrre qualità maggiore e file più grandi. Il bitrate risultante varia in base al contenuto.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                            } else if experimentSettings.backend == .software,
                                      experimentSettings.rateControlMode == .constantQuantizer {
                                Stepper(
                                    "QP: \(experimentSettings.quantizerValue)",
                                    value: $experimentSettings.quantizerValue,
                                    in: 0...51
                                )

                                Text("QP più alto applica in genere una quantizzazione più forte, riducendo il bitrate ma aumentando la distorsione.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                            } else {
                                HStack {
                                    Text("Bitrate video (kb/s)")

                                    TextField("Bitrate", value: $experimentSettings.videoBitrateKbps, format: .number)
                                        .frame(width: 90)

                                    Stepper("Bitrate video", value: $experimentSettings.videoBitrateKbps, in: 10...50_000, step: 100)
                                        .labelsHidden()
                                }

                                // Le passate dipendono dall'encoder: si dice qui, dove si sceglie il bitrate.
                                Text(experimentSettings.backend == .software
                                     ? "Via software la codifica avviene in due passate: la prima analizza tutto il video, la seconda distribuisce i bit sapendo già dove servono. Il bitrate obiettivo è rispettato meglio, ma serve circa il doppio del tempo."
                                     : "Codifica in una passata tramite VideoToolbox")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            // GOP e B-frame sulla stessa riga; i B-frame si configurano solo via software.
                            HStack(spacing: 24) {
                                Stepper(gopLabel, value: $experimentSettings.gopSize, in: 1...600)

                                if experimentSettings.backend == .software {
                                    Stepper(
                                        "B-frame: max \(experimentSettings.bFrameCount) consecutivi",
                                        value: $experimentSettings.bFrameCount,
                                        in: 0...16
                                    )
                                }

                                Spacer()
                            }

                            Text("Valori consigliati per la maggior parte dei confronti. Cambiarli crea configurazioni diverse, che nei grafici appaiono come curve separate.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Button("Ripristina valori consigliati") {
                                experimentSettings.gopSize = recommendedGOP
                                experimentSettings.bFrameCount = Self.recommendedBFrameCount
                            }
                            .disabled(hasRecommendedAdvancedSettings)

                            Divider()

                            ClipEditor(
                                clip: $experimentSettings.clip,
                                sourceDuration: videoItems.first { $0.id == sourceSelection.wrappedValue }?.durationSeconds
                            )

                            Divider()

                            Picker("Audio", selection: $experimentSettings.audioMode) {
                                ForEach(AudioEncodingMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            // Senza traccia audio la scelta non avrebbe effetto.
                            .disabled(!selectedSourceHasAudio)

                            if !selectedSourceHasAudio {
                                Text("Il video scelto non ha una traccia audio: il file codificato sarà solo video.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if experimentSettings.audioMode == .aac {
                                Stepper(
                                    "Bitrate audio: \(experimentSettings.audioBitrateKbps) kb/s",
                                    value: $experimentSettings.audioBitrateKbps,
                                    in: 64...320,
                                    step: 32
                                )
                            }

                            Divider()

                            Text("«Crea serie» genera 8 esperimenti con il codec e il profilo scelti qui sopra, per confrontare la codifica via hardware (a una passata) con quella via software (a due passate): 4 bitrate uguali per i due encoder, scelti con una codifica di prova: x264 a qualità costante (CRF 23) misura quanto bitrate serve al video, e la serie usa metà, lo stesso, il doppio e il quadruplo di quel valore. Così la scala si adatta al contenuto: bassa per un video quasi fermo, alta per uno molto movimentato. I video oltre 30 secondi si provano su tre campioni da 5 secondi. Usa GOP, B-frame (solo via software), audio e spezzone impostati qui sopra; codifiche e analisi partono in coda. Per confrontare anche H.264 e HEVC, crea una serie per ciascun codec sullo stesso file: le curve finiscono nello stesso grafico.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack {
                                // La prova dura da un istante a qualche secondo: senza avviso il clic sembrerebbe ignorato.
                                if appModel.isEstimatingComplexity {
                                    ProgressView()
                                        .controlSize(.small)

                                    Text("Codifica di prova per scegliere i bitrate…")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button("Crea serie hardware / software", systemImage: "square.stack.3d.up") {
                                    if let sourceID = sourceSelection.wrappedValue,
                                       let folder = chooseOutputFolder() {
                                        // Le impostazioni si copiano al clic: la serie usa queste,
                                        // anche se il modulo cambia mentre si legge il video.
                                        let base = experimentSettings

                                        Task {
                                            await appModel.createComparisonSeries(sourceID: sourceID, base: base, outputFolder: folder)
                                        }
                                    }
                                }
                                // Niente serie nuove mentre la coda lavora: si crea al termine o dopo l'annullamento.
                                .disabled(sourceSelection.wrappedValue == nil || !appModel.areToolsAvailable ||
                                          appModel.isEstimatingComplexity || appModel.jobs.isBusy)
                                .help(appModel.jobs.isBusy ? "Disponibile al termine dei lavori in corso (o dopo averli annullati)" : "Crea gli otto esperimenti della serie e mette in coda codifiche e analisi")

                                Button("Crea esperimento", systemImage: "plus.circle.fill") {
                                    if let sourceID = sourceSelection.wrappedValue {
                                        appModel.createExperiment(sourceID: sourceID, settings: experimentSettings)
                                    }
                                }
                                .disabled(sourceSelection.wrappedValue == nil || appModel.jobs.isBusy)
                                .help(appModel.jobs.isBusy ? "Disponibile al termine dei lavori in corso (o dopo averli annullati)" : "Crea un esperimento con queste impostazioni, da codificare con ▶")
                            }

                            // Lo stato della coda, sotto i pulsanti che la riempiono.
                            QueueStatusView()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
                }

                
                GroupBox("Esperimenti salvati") {
                    if appModel.experiments.isEmpty {
                        Text("Non ci sono ancora esperimenti.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(appModel.experiments) { experiment in
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 5) {
                                            // Il nome del file codificato, se c'è già; altrimenti quello dell'originale.
                                            Text(experiment.outputFileName ?? experiment.sourceName)
                                                .fontWeight(.semibold)

                                            Text(experiment.outputFileName == nil
                                                 ? "Da codificare"
                                                 : "Originale: \(experiment.sourceName)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)

                                            Text(experiment.settings.codecDescription)
                                                .font(.callout)
                                                .foregroundStyle(.secondary)

                                            Text(
                                                "\(experiment.settings.rateControlDescription) · " +
                                                "\(experiment.settings.structureDescription) · " +
                                                statusTitle(for: experiment)
                                            )
                                            .font(.caption)
                                            .foregroundStyle(.secondary)

                                            if let clip = experiment.settings.clip {
                                                Text(clip.description)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }

                                            Text(experiment.createdAt.formatted(
                                                date: .abbreviated,
                                                time: .shortened
                                            ))
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            
                                            experimentOutputSummary(experiment)

                                            if let missingFiles = appModel.missingFilesDescription(for: experiment.id) {
                                                Label(
                                                    "\(missingFiles) " + (isSourceMissing(experiment)
                                                        ? "Ripristina il file originale (o ricollega il disco) per codificare e analizzare."
                                                        : "Ricodifica l'esperimento per analizzarlo o confrontarne i fotogrammi."),
                                                    systemImage: "exclamationmark.triangle"
                                                )
                                                .font(.caption)
                                                .foregroundStyle(.orange)
                                            }
                                        }

                                        Spacer()

                                        // Se un altro lavoro è in corso, codifica e analisi vengono accodate.
                                        Button {
                                            if let outputURL = chooseOutputURL(for: experiment) {
                                                appModel.jobs.enqueue(QueuedJob(kind: .encoding, experimentID: experiment.id, outputURL: outputURL))
                                            }
                                        } label: {
                                            Image(systemName: "play.fill")
                                        }
                                        .buttonStyle(.borderless)
                                        .disabled(
                                            !appModel.areToolsAvailable ||
                                            appModel.jobs.hasPending(.encoding, for: experiment.id) ||
                                            isSourceMissing(experiment)
                                        )
                                        .help(
                                            isSourceMissing(experiment)
                                                ? "Il file originale non è più disponibile"
                                                : (appModel.jobs.current == nil ? "Avvia codifica" : "Aggiungi la codifica alla coda")
                                        )

                                        // L'analisi si può accodare anche dietro una codifica non ancora finita
                                        // (se quella codifica viene annullata o fallisce, l'analisi viene tolta dalla coda).
                                        if experiment.status == .completed ||
                                            appModel.jobs.hasPending(.encoding, for: experiment.id) {
                                            Button {
                                                appModel.jobs.enqueue(QueuedJob(kind: .qualityAnalysis, experimentID: experiment.id))
                                            } label: {
                                                Image(systemName: "waveform.path.ecg")
                                            }
                                            .buttonStyle(.borderless)
                                            .disabled(
                                                !appModel.areToolsAvailable ||
                                                appModel.isLibVMAFAvailable != true ||
                                                appModel.jobs.hasPending(.qualityAnalysis, for: experiment.id) ||
                                                !canAnalyze(experiment)
                                            )
                                            .help(
                                                appModel.isLibVMAFAvailable == false
                                                    ? "Analisi non disponibile: FFmpeg non include libvmaf"
                                                    : !canAnalyze(experiment)
                                                        ? (appModel.missingFilesDescription(for: experiment.id) ?? "")
                                                        : (appModel.jobs.current == nil ? "Analizza qualità" : "Aggiungi l'analisi alla coda")
                                            )
                                        }

                                        Button(role: .destructive) {
                                            experimentToDeleteID = experiment.id
                                            isDeleteExperimentConfirmationPresented = true
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .buttonStyle(.borderless)
                                        .help("Elimina esperimento e analisi associate")
                                        .disabled(appModel.jobs.current?.experimentID == experiment.id)
                                    }
                                    
                                    if let job = appModel.jobs.current, job.experimentID == experiment.id {
                                        JobProgressView(job: job)
                                    }

                                    queuedJobsView(for: experiment)

                                    if let result = appModel.latestQualityAnalysis(for: experiment.id) {
                                        QualitySummaryView(result: result) {
                                            onShowAnalysis(result.id)
                                        }
                                    }
                                }

                                if experiment.id != appModel.experiments.last?.id {
                                    Divider()
                                }
                            }
                        }
                        .padding(.vertical, 5)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 950, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Esperimenti video")
        .onAppear {
            appModel.refreshFileAvailability()
        }
        .confirmationDialog(
            "Vuoi eliminare questo esperimento e le analisi associate?",
            isPresented: $isDeleteExperimentConfirmationPresented,
            titleVisibility: .visible
        ) {
            if let id = experimentToDeleteID {
                let series = appModel.seriesMembers(of: id)

                Button(series.count > 1 ? "Elimina solo questo esperimento" : "Elimina", role: .destructive) {
                    appModel.removeExperiments(ids: [id])
                    experimentToDeleteID = nil
                }

                if series.count > 1 {
                    Button("Elimina tutta la serie (\(series.count) esperimenti)", role: .destructive) {
                        appModel.removeExperiments(ids: Set(series.map(\.id)))
                        experimentToDeleteID = nil
                    }
                    .disabled(series.contains { $0.id == appModel.jobs.current?.experimentID })
                }
            }

            Button("Annulla", role: .cancel) {
                experimentToDeleteID = nil
            }
        } message: {
            Text("I video codificati vengono spostati nel Cestino. Una serie con un lavoro in corso si può eliminare dopo averlo annullato.")
        }
    }
    

    /// Chiede la cartella in cui salvare i video di una serie: si sceglie una volta, i nomi sono automatici.
    ///
    /// - Returns: La cartella, o `nil` se l'utente annulla.
    private func chooseOutputFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Cartella per i video della serie"
        panel.prompt = "Scegli"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true

        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Chiede dove salvare il video codificato di un esperimento.
    ///
    /// - Parameter experiment: L'esperimento.
    /// - Returns: Il file, o `nil` se l'utente annulla.
    private func chooseOutputURL(for experiment: EncodingExperiment) -> URL? {
        let baseName = URL(fileURLWithPath: experiment.sourceName)
            .deletingPathExtension()
            .lastPathComponent

        let panel = NSSavePanel()
        panel.title = "Salva il video codificato"
        panel.prompt = "Salva"
        panel.nameFieldStringValue =
            "\(baseName)_\(experiment.settings.codec.rawValue).mp4"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK else {
            return nil
        }

        return panel.url
    }
    

        

    /// Le misure del video codificato: dimensione, durata, bitrate e tempo di codifica.
    private func experimentOutputSummary(
        _ experiment: EncodingExperiment
    ) -> some View {
        Group {
            if let outputInfo = experiment.outputInfo {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Risultato della codifica")
                        .font(.caption.weight(.semibold))

                    Grid(
                        alignment: .leading,
                        horizontalSpacing: 18,
                        verticalSpacing: 6
                    ) {
                        if let fileSize = outputInfo.fileSizeBytes {
                            MetadataRow("Dimensione file", MediaValueFormatter.bytes(fileSize))
                        }

                        if let duration = outputInfo.durationSeconds {
                            MetadataRow("Durata video", MediaValueFormatter.duration(duration))
                        }

                        if let bitrate = outputInfo.videoBitrateBitsPerSecond {
                            MetadataRow("Bitrate video effettivo", MediaValueFormatter.bitRate(bitrate))
                        }

                        if let bitrate = outputInfo.audioBitrateBitsPerSecond {
                            MetadataRow("Bitrate audio effettivo", MediaValueFormatter.bitRate(bitrate))
                        }

                        if let bitrate = outputInfo.totalBitrateBitsPerSecond {
                            MetadataRow("Bitrate complessivo", MediaValueFormatter.bitRate(bitrate))
                        }

                        if let duration = outputInfo.encodingDurationSeconds {
                            MetadataRow("Tempo di codifica", MediaValueFormatter.duration(duration))
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }
    

    // MARK: - Lavoro in corso

    /// Vero se il file originale dell'esperimento non è più raggiungibile.
    private func isSourceMissing(_ experiment: EncodingExperiment) -> Bool {
        appModel.experimentsMissingSource.contains(experiment.id)
    }

    /// Vero se l'esperimento si può analizzare.
    ///
    /// L'analisi richiede l'originale e il file codificato, a meno che quest'ultimo
    /// non stia per essere rigenerato da una codifica in coda.
    private func canAnalyze(_ experiment: EncodingExperiment) -> Bool {
        !isSourceMissing(experiment) && (
            !appModel.experimentsMissingOutput.contains(experiment.id) ||
            appModel.jobs.hasPending(.encoding, for: experiment.id)
        )
    }

    /// Lo stato mostrato: «In codifica» durante la codifica, altrimenti quello salvato.
    private func statusTitle(for experiment: EncodingExperiment) -> String {
        appModel.jobs.current?.experimentID == experiment.id && appModel.jobs.current?.kind == .encoding
            ? "In codifica"
            : experiment.status.title
    }

    /// I lavori dell'esperimento in attesa, con la posizione in coda e il pulsante per toglierli.
    private func queuedJobsView(for experiment: EncodingExperiment) -> some View {
        ForEach(Array(appModel.jobs.pending.enumerated()), id: \.element.id) { position, queued in
            if queued.experimentID == experiment.id {
                HStack {
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)

                    Text("In coda: \(queued.kind == .encoding ? "codifica" : "analisi qualità") (posizione \(position + 1))")
                        .font(.callout)

                    Spacer()

                    Button("Togli dalla coda", systemImage: "xmark.circle") {
                        appModel.jobs.remove(id: queued.id)
                    }
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .help("Togli dalla coda")
                }
            }
        }
    }
}
