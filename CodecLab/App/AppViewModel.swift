// AppViewModel.swift
// Stato dell'applicazione: strumenti, Libreria, esperimenti e analisi.
// Prepara i lavori FFmpeg (codifiche e analisi qualità) che `JobQueue` esegue uno alla volta,
// e ne salva i risultati.

import AppKit
import Foundation
import Observation

/// Il cuore dell'app: lo stato condiviso da tutte le sezioni e le operazioni che lo modificano.
///
/// Contiene tutto ciò che l'utente vede e crea:
/// - lo stato degli strumenti (FFmpeg, FFprobe, encoder hardware, libvmaf);
/// - la Libreria dei file originali;
/// - gli esperimenti video e audio e le analisi della qualità, salvati in file JSON
///   nella cartella Application Support, così restano tra un avvio e l'altro.
///
/// Le viste non eseguono mai FFmpeg da sole: chiedono qui di creare un esperimento o una serie,
/// di avviare un'analisi o di eliminare qualcosa. ``AppViewModel`` controlla che l'operazione sia possibile,
/// prepara il lavoro, lo affida alla coda (``jobs``) e, quando il lavoro finisce, ne salva il risultato.
@MainActor
@Observable
final class AppViewModel {
    // MARK: Strumenti

    /// La versione di FFmpeg; `nil` se non è stato trovato.
    private(set) var ffmpegVersion: String?
    /// La versione di FFprobe; `nil` se non è stato trovato.
    private(set) var ffprobeVersion: String?
    /// Vero se VideoToolbox codifica in H.264; `nil` prima della verifica.
    private(set) var isH264HardwareEncoderAvailable: Bool?
    /// Vero se VideoToolbox codifica in HEVC; `nil` prima della verifica.
    private(set) var isHEVCHardwareEncoderAvailable: Bool?
    /// Vero se FFmpeg include libvmaf; `nil` prima della verifica.
    private(set) var isLibVMAFAvailable: Bool?
    /// Vero se FFmpeg include l'encoder AAC di AudioToolbox; `nil` prima della verifica.
    private(set) var isAppleAACAvailable: Bool?
    /// Le informazioni sotto le voci di Sistema ("h264", "hevc", "libvmaf", "aac_at"): encoder secondo FFmpeg,
    /// versione di libvmaf e modello usato.
    private(set) var toolDetails: [String: String] = [:]
    /// Vero durante la verifica degli strumenti.
    private(set) var isCheckingTools = false
    /// Vero dopo la prima verifica degli strumenti, riuscita o no.
    private(set) var hasCheckedTools = false

    // MARK: File selezionato nella Libreria

    /// L'elemento della Libreria selezionato.
    private(set) var inspectedItemID: UUID?
    /// La posizione attuale del file selezionato.
    private(set) var inspectedURL: URL?
    /// Le informazioni sul file selezionato, lette con FFprobe.
    private(set) var probeDocument: FFprobeDocument?
    /// La scansione dei fotogrammi I/P/B del file selezionato, se è ancora valida.
    private(set) var sourceAnalysisResult: SourceAnalysisResult?
    /// Vero mentre si leggono le informazioni di un file.
    private(set) var isInspectingMedia = false
    /// La codifica di prova del file selezionato, se è ancora valida.
    private(set) var complexityMeasurement: ComplexityMeasurement?
    /// SI e TI del file selezionato, se sono ancora validi.
    private(set) var spatialTemporalMeasurement: SpatialTemporalMeasurement?
    /// Vero durante l'analisi del video originale (fotogrammi I/P/B, SI e TI, codifica di prova).
    private(set) var isAnalyzingSource = false
    /// La parte dell'analisi del video originale in corso, per esempio "SI e TI"; `nil` se non è in corso.
    private(set) var sourceAnalysisStage: String?

    // MARK: File originale scelto in Analisi qualità e Relazione

    /// Il file originale scelto per ultimo in Analisi qualità o in Relazione: le due sezioni
    /// lo condividono, così passando dall'una all'altra si resta sullo stesso file.
    var focusedSourceID: UUID?

    // MARK: Aggiunta di file

    /// Vero mentre è aperta la finestra per aggiungere un file alla Libreria: la aprono
    /// il pulsante della Libreria e il comando Archivio › Aggiungi file… (⌘O).
    var isFileImporterPresented = false

    /// Vero se si può aggiungere un file: servono FFmpeg e FFprobe, e non deve esserne in lettura un altro.
    var canAddFiles: Bool {
        areToolsAvailable && !isInspectingMedia
    }

    // MARK: Ricerca

    /// La frase scritta nella ricerca: resta quando si passa a un'altra sezione e si torna.
    var searchText = ""
    /// Il filtro ricavato dalla frase; `nil` prima della prima ricerca o se la frase non è stata capita.
    var searchFilter: ExperimentSearchFilter?
    /// La frase riscritta da Apple Intelligence, se il codice non aveva capito quella originale.
    var searchRewrite: String?

    // MARK: Dati salvati

    /// I file della Libreria, dal più recente.
    private(set) var libraryItems: [MediaLibraryItem] = []
    /// Gli esperimenti video, dal più recente.
    private(set) var experiments: [EncodingExperiment] = []
    /// Le analisi qualità, dalla più recente.
    private(set) var qualityAnalysisResults: [VideoQualityAnalysisResult] = []
    /// Gli esperimenti audio, dal più recente.
    private(set) var audioExperiments: [AudioExperiment] = []

    // MARK: Lavori e messaggi

    /// La coda dei lavori FFmpeg, con il lavoro in corso.
    let jobs = JobQueue()

    /// Gli esperimenti il cui file originale non è più raggiungibile
    /// (cancellato, o su un disco scollegato). Aggiornati da ``refreshFileAvailability()``.
    private(set) var experimentsMissingSource: Set<UUID> = []
    /// Gli esperimenti il cui file codificato non è più raggiungibile.
    private(set) var experimentsMissingOutput: Set<UUID> = []

    /// Il messaggio di errore mostrato nell'avviso: resta finché l'utente non lo chiude.
    var errorMessage: String?

    /// Vero mentre «Crea serie» esegue la codifica di prova, prima di mettere in coda la serie.
    private(set) var isEstimatingComplexity = false
    /// Vero mentre «Crea serie audio» legge il file, prima di mettere in coda la serie.
    private(set) var isCreatingAudioSeries = false

    private let libraryStore = JSONStore<MediaLibraryItem>(fileName: "MediaLibrary.json")
    private let experimentStore = JSONStore<EncodingExperiment>(fileName: "EncodingExperiments.json")
    private let analysisStore = JSONStore<VideoQualityAnalysisResult>(fileName: "QualityAnalysis.json")
    private let audioStore = JSONStore<AudioExperiment>(fileName: "AudioExperiments.json")

    /// Vero se FFmpeg e FFprobe sono stati trovati: senza, non si può importare né codificare.
    var areToolsAvailable: Bool {
        ffmpegVersion != nil && ffprobeVersion != nil
    }

    /// Carica i dati salvati e si prepara a gestire la coda dei lavori.
    ///
    /// Se un file di dati non è leggibile, viene messo da parte e l'errore
    /// viene mostrato all'utente (vedi ``JSONStore/load()``).
    init() {
        var loadErrors: [String] = []

        do { libraryItems = try libraryStore.load() } catch { loadErrors.append(error.localizedDescription) }
        do { experiments = try experimentStore.load() } catch { loadErrors.append(error.localizedDescription) }
        do { qualityAnalysisResults = try analysisStore.load() } catch { loadErrors.append(error.localizedDescription) }
        do { audioExperiments = try audioStore.load() } catch { loadErrors.append(error.localizedDescription) }

        if !loadErrors.isEmpty {
            errorMessage = loadErrors.joined(separator: "\n\n")
        }

        // Alla chiusura dell'app FFmpeg non deve restare in esecuzione (o sospeso) da solo.
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.jobs.stopBeforeTermination()
            }
        }

        // Tornando nell'app (per esempio dopo aver cancellato file nel Finder) si ricontrollano i file.
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshFileAvailability()
            }
        }

        jobs.prepare = { [weak self] in self?.prepareJob($0) }
        jobs.onJobFinished = { [weak self] in self?.refreshFileAvailability() }

        refreshFileAvailability()
    }

    // MARK: - Strumenti

    /// Verifica FFmpeg, FFprobe e i loro componenti e aggiorna lo stato degli strumenti.
    ///
    /// Se FFmpeg o FFprobe mancano, l'errore viene mostrato all'utente.
    func checkTools() async {
        guard !isCheckingTools else { return }

        isCheckingTools = true
        defer {
            isCheckingTools = false
            hasCheckedTools = true
        }

        do {
            let status = try await MediaToolService().check()
            ffmpegVersion = status.ffmpegVersion
            ffprobeVersion = status.ffprobeVersion
            isH264HardwareEncoderAvailable = status.isH264HardwareEncoderAvailable
            isHEVCHardwareEncoderAvailable = status.isHEVCHardwareEncoderAvailable
            isLibVMAFAvailable = status.isLibVMAFAvailable
            isAppleAACAvailable = status.isAppleAACAvailable
            toolDetails = [
                "h264": status.h264EncoderDetail,
                "hevc": status.hevcEncoderDetail,
                "libvmaf": status.libVMAFDetail,
                "aac_at": status.appleAACDetail
            ].compactMapValues { $0 }
        } catch {
            ffmpegVersion = nil
            ffprobeVersion = nil
            report(error)
        }
    }

    // MARK: - Sorgente

    /// Legge le informazioni di un file e lo seleziona, aggiungendolo alla Libreria se non c'è già.
    ///
    /// Se il file ha una scansione I/P/B salvata e non è cambiato da allora, la ripropone.
    ///
    /// - Parameter url: Il file.
    /// - Returns: Vero se le informazioni sono state lette; in caso di errore, l'errore è già stato mostrato.
    @discardableResult
    func inspectMedia(at url: URL) async -> Bool {
        guard !isInspectingMedia else { return false }

        isInspectingMedia = true
        defer { isInspectingMedia = false }

        let document: FFprobeDocument

        // Se FFprobe non legge il file, o lo legge ma non è un video o un audio, un messaggio comprensibile
        // al posto dell'errore tecnico di FFprobe.
        let notMediaError = AppError("«\(url.lastPathComponent)» non è un file video o audio leggibile: non è stato aggiunto alla Libreria.")

        do {
            guard let probed = try? await FFprobeService().probe(url), probed.isUsableMedia else {
                throw notMediaError
            }

            document = probed
            probeDocument = document
            inspectedURL = url
            sourceAnalysisResult = nil
            complexityMeasurement = nil
            spatialTemporalMeasurement = nil
        } catch {
            report(error)
            return false
        }

        inspectedItemID = addToLibrary(url, document: document)

        // Ripropone la scansione salvata, ma solo se il file non è cambiato da allora.
        if let scan = libraryItems.first(where: { $0.id == inspectedItemID })?.frameTypeScan,
           scan.file == FileFingerprint(of: url) {
            sourceAnalysisResult = scan
        }

        // Lo stesso per la misura della difficoltà di compressione.
        if let measurement = libraryItems.first(where: { $0.id == inspectedItemID })?.complexityMeasurement,
           measurement.file == FileFingerprint(of: url) {
            complexityMeasurement = measurement
        }

        // E per SI e TI.
        if let measurement = libraryItems.first(where: { $0.id == inspectedItemID })?.spatialTemporalMeasurement,
           measurement.file == FileFingerprint(of: url) {
            spatialTemporalMeasurement = measurement
        }

        return true
    }

    /// Analizza il video originale selezionato: fotogrammi I/P/B, SI e TI, codifica di prova.
    ///
    /// Le tre parti vengono eseguite una dopo l'altra, sempre sul file selezionato alla partenza;
    /// ogni risultato viene salvato nella Libreria appena è pronto. Se una parte non riesce,
    /// l'errore viene mostrato e le altre proseguono.
    func analyzeSource() async {
        guard let url = inspectedURL, let itemID = inspectedItemID, !isAnalyzingSource else { return }

        isAnalyzingSource = true
        defer {
            isAnalyzingSource = false
            sourceAnalysisStage = nil
        }

        // La durata serve alla codifica di prova; quella del documento solo se è dello stesso file.
        let duration = libraryItems.first { $0.id == itemID }?.durationSeconds
            ?? (inspectedItemID == itemID ? probeDocument?.format?.durationSeconds : nil)

        sourceAnalysisStage = "Fotogrammi I, P e B"
        await scanFrameTypes(url: url, itemID: itemID)

        sourceAnalysisStage = "SI e TI"
        await measureSpatialTemporal(url: url, itemID: itemID)

        sourceAnalysisStage = "Codifica di prova"
        await measureComplexity(url: url, itemID: itemID, duration: duration)
    }

    /// La scansione dei fotogrammi I/P/B, salvata nella Libreria.
    ///
    /// - Parameters:
    ///   - url: Il file.
    ///   - itemID: L'elemento della Libreria.
    private func scanFrameTypes(url: URL, itemID: UUID) async {
        do {
            let frameTypes = try await FFprobeService().frameTypeSummary(url)
            let result = SourceAnalysisResult(frameTypes: frameTypes, analyzedAt: Date(), file: FileFingerprint(of: url))

            // Salvato sul file su cui è partita l'analisi, anche se nel frattempo
            // ne è stato selezionato un altro; mostrato solo se è ancora quello selezionato.
            saveLibrary(libraryItems.map {
                var item = $0
                if item.id == itemID { item.frameTypeScan = result }
                return item
            })

            if inspectedItemID == itemID {
                sourceAnalysisResult = result
            }
        } catch {
            report(error, context: "Scansione dei fotogrammi non riuscita")
        }
    }

    /// Il calcolo di SI e TI (``SpatialTemporalInfo``), salvato nella Libreria.
    ///
    /// - Parameters:
    ///   - url: Il file.
    ///   - itemID: L'elemento della Libreria.
    private func measureSpatialTemporal(url: URL, itemID: UUID) async {
        do {
            let summary = try await SpatialTemporalInfo.measure(sourceURL: url)
            let measurement = SpatialTemporalMeasurement(summary: summary, measuredAt: Date(), file: FileFingerprint(of: url))

            saveLibrary(libraryItems.map {
                var item = $0
                if item.id == itemID { item.spatialTemporalMeasurement = measurement }
                return item
            })

            if inspectedItemID == itemID {
                spatialTemporalMeasurement = measurement
            }
        } catch {
            report(error, context: "Calcolo di SI e TI non riuscito")
        }
    }

    /// La codifica di prova di «Crea serie» (``ComplexityProbe``) sull'intero video, salvata nella Libreria.
    ///
    /// - Parameters:
    ///   - url: Il file.
    ///   - itemID: L'elemento della Libreria.
    ///   - duration: La durata del video, in secondi.
    private func measureComplexity(url: URL, itemID: UUID, duration: Double?) async {
        do {
            guard let duration, duration > 0 else {
                throw AppError("Impossibile leggere la durata del video originale.")
            }

            let reference = try await ComplexityProbe.referenceBitrateKbps(sourceURL: url, start: 0, duration: duration)
            saveComplexityMeasurement(referenceKbps: reference, duration: duration, sourceURL: url, itemID: itemID)
        } catch {
            report(error, context: "Codifica di prova non riuscita")
        }
    }

    /// Salva nella Libreria una codifica di prova fatta sull'intero video,
    /// e la mostra se il file è ancora quello selezionato.
    ///
    /// - Parameters:
    ///   - referenceKbps: Il bitrate della codifica di prova, in kb/s.
    ///   - duration: La durata del video provato, in secondi: dice se la prova è stata fatta su campioni.
    ///   - sourceURL: Il file, per la sua impronta.
    ///   - itemID: L'elemento della Libreria.
    private func saveComplexityMeasurement(referenceKbps: Double, duration: Double, sourceURL: URL, itemID: UUID) {
        let measurement = ComplexityMeasurement(
            referenceKbps: referenceKbps,
            isSampled: ComplexityProbe.samples(start: 0, duration: duration).count > 1,
            measuredAt: Date(),
            file: FileFingerprint(of: sourceURL)
        )

        saveLibrary(libraryItems.map {
            var item = $0
            if item.id == itemID { item.complexityMeasurement = measurement }
            return item
        })

        if inspectedItemID == itemID {
            complexityMeasurement = measurement
        }
    }

    // MARK: - Libreria

    /// Aggiunge un file alla Libreria, se non c'è già.
    ///
    /// - Parameters:
    ///   - url: Il file.
    ///   - document: Le informazioni lette da FFprobe.
    /// - Returns: L'identificativo dell'elemento, nuovo o esistente; `nil` se non è stato possibile aggiungerlo.
    private func addToLibrary(_ url: URL, document: FFprobeDocument) -> UUID? {
        let target = url.standardizedFileURL

        // Lo stesso file può essere riaggiunto: si confronta la posizione attuale di ogni elemento.
        let existing = libraryItems.first { item in
            var data = item.bookmarkData
            return (try? Bookmark.resolve(&data, fileName: item.name))?.standardizedFileURL == target
        }

        if let existing {
            // Se all'importazione i dati del video o la durata non erano stati letti (per esempio
            // frame rate sconosciuto, o file aggiunto con una versione precedente), si completano ora.
            let summary = existing.video ?? VideoSummary(document: document)
            let duration = existing.durationSeconds ?? document.format?.durationSeconds

            if summary != existing.video || duration != existing.durationSeconds {
                saveLibrary(libraryItems.map {
                    var item = $0
                    if item.id == existing.id {
                        item.video = summary
                        item.durationSeconds = duration
                    }
                    return item
                })
            }

            return existing.id
        }

        do {
            let item = try MediaLibraryItem(url: url, document: document)
            saveLibrary([item] + libraryItems)
            return item.id
        } catch {
            report(error, context: "Impossibile aggiungere il file alla libreria")
            return nil
        }
    }

    /// Apre un elemento della Libreria e ne legge le informazioni.
    ///
    /// - Parameter item: L'elemento.
    /// - Returns: Vero se le informazioni sono state lette.
    /// - Throws: ``MediaLibraryError/fileNotReachable(name:)`` se il file non è più raggiungibile.
    func openLibraryItem(_ item: MediaLibraryItem) async throws -> Bool {
        let url = try libraryURL(for: item.id)
        return await inspectMedia(at: url)
    }

    /// Quanti esperimenti e analisi dipendono da un file della Libreria.
    ///
    /// Serve a chiedere conferma prima di rimuovere un file: rimuoverlo elimina anche questi dati,
    /// e il messaggio dice esattamente che cosa sparisce.
    struct LibraryItemDependents {
        /// Il numero di esperimenti video.
        var videoExperiments = 0
        /// Il numero di esperimenti audio.
        var audioExperiments = 0
        /// Il numero di analisi qualità.
        var analyses = 0

        /// Vero se dal file non dipende nulla e lo si può rimuovere senza chiedere conferma.
        var isEmpty: Bool { videoExperiments + audioExperiments == 0 }

        /// L'elenco per il messaggio di conferma, per esempio "15 esperimenti video, 10 esperimenti audio e 12 analisi".
        var description: String {
            let parts = [
                (videoExperiments, "esperimento video", "esperimenti video"),
                (audioExperiments, "esperimento audio", "esperimenti audio"),
                (analyses, "analisi", "analisi"),
            ]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.0 == 1 ? $0.1 : $0.2)" }

            return parts.count > 1
                ? parts.dropLast().joined(separator: ", ") + " e " + parts.last!
                : parts.first ?? ""
        }
    }

    /// Conta gli esperimenti e le analisi che dipendono da un file della Libreria.
    ///
    /// - Parameter id: L'elemento della Libreria.
    /// - Returns: I conteggi.
    func dependents(ofLibraryItem id: UUID) -> LibraryItemDependents {
        let videoIDs = Set(experiments.filter { $0.sourceVideoID == id }.map(\.id))

        return LibraryItemDependents(
            videoExperiments: videoIDs.count,
            audioExperiments: audioExperiments.filter { $0.sourceVideoID == id }.count,
            analyses: qualityAnalysisResults.filter { videoIDs.contains($0.experimentID) }.count
        )
    }

    /// Rimuove un file dalla Libreria insieme ai suoi esperimenti video e audio e alle loro analisi.
    ///
    /// I file codificati vanno nel Cestino; il file originale non viene toccato. Se un lavoro
    /// su quel file è in corso, la rimozione viene rifiutata con un messaggio.
    ///
    /// - Parameter id: L'elemento della Libreria.
    func removeFromLibrary(id: UUID) {
        let videoIDs = Set(experiments.filter { $0.sourceVideoID == id }.map(\.id))
        let audioIDs = Set(audioExperiments.filter { $0.sourceVideoID == id }.map(\.id))

        if let current = jobs.current, videoIDs.union(audioIDs).contains(current.experimentID) {
            report(AppError("Un lavoro su questo file è in corso: annullalo prima di rimuovere il file dalla Libreria."))
            return
        }

        guard videoIDs.isEmpty || removeExperiments(ids: videoIDs),
              audioIDs.isEmpty || removeAudioExperiments(ids: audioIDs) else { return }

        saveLibrary(libraryItems.filter { $0.id != id })

        if inspectedItemID == id {
            inspectedItemID = nil
            inspectedURL = nil
            probeDocument = nil
            sourceAnalysisResult = nil
            complexityMeasurement = nil
            spatialTemporalMeasurement = nil
        }
    }

    /// Rilegge con FFprobe le informazioni di un file della Libreria, per la relazione.
    ///
    /// - Parameter id: L'elemento della Libreria.
    /// - Returns: Le informazioni, o `nil` se il file non è raggiungibile o leggibile.
    ///   Nessun errore viene mostrato: la relazione si scrive comunque, con i dati salvati.
    func probeLibraryItem(_ id: UUID) async -> FFprobeDocument? {
        guard let url = try? libraryURL(for: id) else { return nil }
        return try? await FFprobeService().probe(url)
    }

    /// L'impronta attuale di un file della Libreria, per sapere se le analisi salvate lo descrivono ancora.
    ///
    /// - Parameter id: L'elemento della Libreria.
    /// - Returns: L'impronta; `nil` se il file non è raggiungibile.
    func fileFingerprint(of id: UUID) -> FileFingerprint? {
        guard let url = try? libraryURL(for: id) else { return nil }
        return FileFingerprint(of: url)
    }

    /// Il GOP suggerito per un file: due secondi di fotogrammi.
    ///
    /// - Parameter sourceID: L'elemento della Libreria.
    /// - Returns: Il numero di fotogrammi (1–600), o `nil` se il video non è leggibile.
    func suggestedGOP(for sourceID: UUID) async -> Int? {
        do {
            let url = try libraryURL(for: sourceID)
            let document = try await FFprobeService().probe(url)

            guard let videoStream = document.videoStream else {
                throw AppError("Il file selezionato non contiene una traccia video.")
            }

            guard let fps = videoStream.frameRate, fps.isFinite, fps > 0 else {
                throw AppError("Impossibile determinare la frequenza dei fotogrammi.")
            }

            return min(max(Int((fps * 2).rounded()), 1), 600)
        } catch {
            report(error, context: "Impossibile leggere il video")
            return nil
        }
    }

    // MARK: - Disponibilità dei file

    /// Controlla quali esperimenti hanno perso il file originale o quello codificato.
    ///
    /// Si esegue all'avvio, al ritorno nell'app, aprendo Esperimenti video o Analisi e alla
    /// fine di ogni lavoro: non a ogni ridisegno, perché risolvere i bookmark accede al disco.
    func refreshFileAvailability() {
        var missingSource = Set<UUID>()
        var missingOutput = Set<UUID>()

        // Qui i bookmark aggiornati non vengono salvati: lo fa chi apre davvero i file.
        for experiment in experiments {
            var source = experiment.sourceBookmarkData
            if (try? Bookmark.resolve(&source, fileName: experiment.sourceName)) == nil {
                missingSource.insert(experiment.id)
            }

            if var output = experiment.outputBookmarkData,
               (try? Bookmark.resolve(&output, fileName: experiment.outputFileName ?? "")) == nil {
                missingOutput.insert(experiment.id)
            }
        }

        // Assegnati solo se cambiano, per non ridisegnare le viste inutilmente.
        if missingSource != experimentsMissingSource { experimentsMissingSource = missingSource }
        if missingOutput != experimentsMissingOutput { experimentsMissingOutput = missingOutput }
    }

    /// La descrizione dei file mancanti di un esperimento, mostrata accanto ai pulsanti disattivati.
    ///
    /// - Parameter experimentID: L'esperimento.
    /// - Returns: La descrizione, o `nil` se i file sono tutti disponibili.
    func missingFilesDescription(for experimentID: UUID) -> String? {
        switch (experimentsMissingSource.contains(experimentID), experimentsMissingOutput.contains(experimentID)) {
        case (true, true): "Il file originale e quello codificato non sono più disponibili."
        case (true, false): "Il file originale non è più disponibile."
        case (false, true): "Il file codificato non è più disponibile."
        case (false, false): nil
        }
    }

    // MARK: - Esperimenti

    /// Crea un esperimento video, pronto per la codifica.
    ///
    /// - Parameters:
    ///   - sourceID: Il file originale, nella Libreria.
    ///   - settings: Le impostazioni di codifica.
    func createExperiment(sourceID: UUID, settings: EncodingSettings) {
        // Niente esperimenti nuovi mentre la coda lavora (i pulsanti sono già disattivati).
        guard !jobs.isBusy else { return }

        do {
            // Verifica che il file originale sia raggiungibile (e aggiorna il bookmark se serve).
            _ = try libraryURL(for: sourceID)

            guard let source = libraryItems.first(where: { $0.id == sourceID }) else {
                throw MediaLibraryError.itemNotFound
            }

            // Un esperimento identico (stesso file, stesse impostazioni) darebbe lo stesso risultato:
            // per rifarlo c'è ▶ sulla sua scheda. Evita anche i doppioni da doppio clic.
            let standard = settings.withStandardPasses

            guard !experiments.contains(where: { $0.sourceVideoID == sourceID && $0.settings == standard }) else {
                throw AppError("Esiste già un esperimento con queste impostazioni per questo file. Per rifarlo, usa ▶ sulla sua scheda.")
            }

            saveExperiments([EncodingExperiment(source: source, settings: standard)] + experiments)
        } catch {
            report(error)
        }
    }

    /// Crea la serie di confronto hardware / software per il codec scelto e ne mette in coda
    /// codifiche e analisi.
    ///
    /// Gli otto esperimenti usano i quattro bitrate di ``ComparisonSeries``, ricavati da una
    /// codifica di prova (``ComplexityProbe``) che misura la difficoltà del video.
    /// Codifica e analisi di ogni esperimento si alternano, così le curve si riempiono man mano.
    /// L'analisi viene messa in coda solo se FFmpeg include libvmaf.
    ///
    /// - Parameters:
    ///   - sourceID: Il file originale, nella Libreria.
    ///   - base: Le impostazioni di partenza (encoder, GOP, audio, spezzone…).
    ///   - outputFolder: La cartella in cui salvare i video, con nomi automatici.
    func createComparisonSeries(sourceID: UUID, base: EncodingSettings, outputFolder: URL) async {
        // Una serie alla volta, e solo a coda ferma: un secondo clic durante la prova non fa nulla.
        guard !isEstimatingComplexity, !jobs.isBusy else { return }

        isEstimatingComplexity = true
        defer { isEstimatingComplexity = false }

        do {
            let sourceURL = try libraryURL(for: sourceID)
            let document = try await FFprobeService().probe(sourceURL)

            guard let video = document.videoStream else {
                throw AppError("Il file non contiene una traccia video.")
            }

            guard let source = libraryItems.first(where: { $0.id == sourceID }) else {
                throw MediaLibraryError.itemNotFound
            }

            // La parte del video su cui lavora la serie: lo spezzone, se c'è, altrimenti tutto.
            guard let duration = base.clip?.durationSeconds ?? document.format?.durationSeconds, duration > 0 else {
                throw AppError("Impossibile leggere la durata del video originale.")
            }

            // Senza spezzone la prova riguarda l'intero file: se è già salvata nella Libreria
            // e il file non è cambiato, la si riusa (sullo stesso file dà sempre lo stesso risultato).
            let savedReference = base.clip == nil
                ? source.complexityMeasurement.flatMap { $0.file == FileFingerprint(of: sourceURL) ? $0.referenceKbps : nil }
                : nil

            let reference: Double

            if let savedReference {
                reference = savedReference
            } else {
                reference = try await ComplexityProbe.referenceBitrateKbps(
                    sourceURL: sourceURL,
                    start: base.clip?.startSeconds ?? 0,
                    duration: duration
                )

                // Senza spezzone la prova riguarda l'intero file: la si salva anche nella Libreria.
                if base.clip == nil {
                    saveComplexityMeasurement(referenceKbps: reference, duration: duration, sourceURL: sourceURL, itemID: sourceID)
                }
            }

            // Il bitrate dell'originale limita la scala solo se è compresso: un video non compresso
            // ha un bitrate enorme, che non dice nulla sulla qualità da recuperare.
            let sourceBitrate = source.video?.isUncompressed == true
                ? nil
                : (video.bitRateBitsPerSecond ?? document.format?.bitRateBitsPerSecond)

            let bitrates = ComparisonSeries.bitratesKbps(
                referenceKbps: reference,
                sourceBitrateKbps: sourceBitrate.map { Double($0) / 1000 }
            )

            let seriesSettings = ComparisonSeries.settings(from: base, bitratesKbps: bitrates)

            // La stessa serie sullo stesso file esiste già: la prova dà sempre la stessa scala,
            // quindi rifarla produrrebbe gli stessi otto esperimenti.
            let isDuplicate = seriesSettings.allSatisfy { settings in
                experiments.contains { $0.sourceVideoID == sourceID && $0.settings == settings }
            }

            guard !isDuplicate else {
                throw AppError("Esiste già una serie identica per questo file: stesse impostazioni e stessi bitrate.")
            }

            let seriesID = UUID()
            let series = seriesSettings
                .map { settings in
                    var experiment = EncodingExperiment(source: source, settings: settings)
                    experiment.seriesID = seriesID
                    experiment.seriesReferenceKbps = reference
                    return experiment
                }

            saveExperiments(series + experiments)
            enqueueSeries(series, sourceName: source.name, outputFolder: outputFolder)
        } catch {
            report(error, context: "Impossibile creare la serie")
        }
    }

    /// Mette in coda codifica e analisi degli esperimenti di una serie, alternate:
    /// così le curve si riempiono man mano. L'analisi solo se FFmpeg include libvmaf.
    ///
    /// - Parameters:
    ///   - series: Gli esperimenti, nell'ordine in cui lavorarli.
    ///   - sourceName: Il nome del file originale, base dei nomi dei video.
    ///   - outputFolder: La cartella dei video.
    private func enqueueSeries(_ series: [EncodingExperiment], sourceName: String, outputFolder: URL) {
        let baseName = URL(fileURLWithPath: sourceName).deletingPathExtension().lastPathComponent
        var reserved = reservedOutputPaths()

        let queued = series.flatMap { experiment in
            let settings = experiment.settings
            // Per esempio akiyo_hevc_275k_hw.mp4; un numero in più se il nome è già preso.
            let outputURL = Self.availableFileURL(
                in: outputFolder,
                name: "\(baseName)_\(settings.codec.rawValue)_\(settings.videoBitrateKbps)k_\(settings.backend.fileNameTag)",
                extension: "mp4",
                reserved: reserved
            )
            reserved.insert(outputURL.standardizedFileURL.path)

            let encoding = QueuedJob(kind: .encoding, experimentID: experiment.id, outputURL: outputURL)

            return isLibVMAFAvailable == true
                ? [encoding, QueuedJob(kind: .qualityAnalysis, experimentID: experiment.id)]
                : [encoding]
        }

        jobs.enqueue(queued)
    }

    /// Gli esperimenti della stessa serie di quello indicato, compreso lui.
    ///
    /// - Parameter id: Un esperimento.
    /// - Returns: Tutta la serie, o il solo esperimento se non fa parte di una serie.
    func seriesMembers(of id: UUID) -> [EncodingExperiment] {
        guard let experiment = findExperiment(id) else { return [] }
        guard let seriesID = experiment.seriesID else { return [experiment] }
        return experiments.filter { $0.seriesID == seriesID }
    }

    /// Elimina degli esperimenti video, le loro analisi e i loro lavori in coda,
    /// e sposta nel Cestino i video codificati.
    ///
    /// Esperimenti e analisi vengono eliminati insieme, o per niente.
    ///
    /// - Parameter ids: Gli esperimenti.
    /// - Returns: Vero se sono stati eliminati; falso se uno è in lavorazione o se il salvataggio
    ///   non è riuscito (in questo caso l'errore viene mostrato).
    @discardableResult
    func removeExperiments(ids: Set<UUID>) -> Bool {
        guard !ids.isEmpty, !ids.contains(where: { jobs.isRunning($0) }) else { return false }

        let removed = experiments.filter { ids.contains($0.id) }
        let updatedExperiments = experiments.filter { !ids.contains($0.id) }
        let updatedAnalyses = qualityAnalysisResults.filter { !ids.contains($0.experimentID) }

        // Esperimenti e analisi associate vengono eliminati insieme, o per niente.
        do {
            try experimentStore.save(updatedExperiments)

            do {
                try analysisStore.save(updatedAnalyses)
            } catch {
                try? experimentStore.save(experiments)
                throw error
            }

            experiments = updatedExperiments
            qualityAnalysisResults = updatedAnalyses
            jobs.removeAll(for: ids)
        } catch {
            report(error, context: "Impossibile eliminare l'esperimento")
            return false
        }

        for experiment in removed {
            moveToTrash(experiment.outputBookmarkData, fileName: experiment.outputFileName)
        }
        refreshFileAvailability()
        return true
    }

    // MARK: - Preparazione dei lavori

    /// Prepara il lavoro arrivato in testa alla coda; è la funzione ``JobQueue/prepare`` della coda.
    ///
    /// - Parameter next: Il lavoro.
    /// - Returns: Il lavoro pronto, o `nil` se non può partire (l'errore viene mostrato).
    private func prepareJob(_ next: QueuedJob) -> PreparedJob? {
        // Le verifiche (esperimento esistente, file raggiungibili) si fanno ora e non all'accodamento:
        // nel frattempo, con una coda lunga, un file potrebbe essere sparito.
        switch next.kind {
        case .encoding:
            next.outputURL.flatMap { prepareEncoding(experimentID: next.experimentID, outputURL: $0) }
        case .qualityAnalysis:
            prepareQualityAnalysis(experimentID: next.experimentID)
        case .audioEncoding:
            next.outputURL.flatMap { prepareAudioEncoding(experimentID: next.experimentID, outputURL: $0) }
        }
    }

    // MARK: - Codifica

    /// Prepara la codifica di un esperimento video.
    ///
    /// A codifica riuscita l'esperimento viene aggiornato con il file prodotto. Se la codifica
    /// viene annullata o fallisce, si tolgono dalla coda anche i lavori successivi dello stesso
    /// esperimento (nelle serie, la sua analisi), che non avrebbero nulla da analizzare.
    ///
    /// - Parameters:
    ///   - experimentID: L'esperimento.
    ///   - outputURL: Il file da produrre.
    /// - Returns: Il lavoro, o `nil` se l'esperimento non c'è più o il file originale non è raggiungibile.
    private func prepareEncoding(experimentID: UUID, outputURL: URL) -> PreparedJob? {
        guard let experiment = findExperiment(experimentID) else { return nil }

        guard experiment.settings.codec.profiles.contains(experiment.settings.profile) else {
            report(AppError("Profilo non compatibile con il codec."))
            return nil
        }

        let sourceURL: URL

        do {
            sourceURL = try experimentSourceURL(experimentID)
        } catch {
            report(error)
            return nil
        }

        let job = ActiveJob(
            kind: .encoding,
            experimentID: experimentID,
            stage: "Codifica \(experiment.settings.codec.title) · \(experiment.settings.rateControlDescription)…",
            isProgressDeterminate: true,
            canPause: true
        )

        return PreparedJob(job: job, partialFileURL: EncodingService.partialURL(for: outputURL)) { [self] context in
            do {
                let output = try await EncodingService().encode(
                    settings: experiment.settings,
                    sourceURL: sourceURL,
                    outputURL: outputURL,
                    processControl: context.control,
                    elapsedDuration: context.elapsedDuration,
                    onProgress: context.onProgress
                )

                updateExperiment(experimentID) {
                    $0.status = .completed
                    $0.outputFileName = output.outputFileName
                    $0.outputBookmarkData = output.outputBookmarkData
                    $0.outputInfo = output.outputInfo
                }
            } catch is CancellationError {
                // Annullata: l'esperimento e un eventuale risultato precedente restano invariati.
                // L'analisi in coda dopo questa codifica (nelle serie) non avrebbe niente da analizzare.
                jobs.removeAll(for: [experimentID])
            } catch {
                // Un tentativo fallito non cancella un risultato precedente valido.
                updateExperiment(experimentID) {
                    if $0.status != .completed {
                        $0.status = .failed
                    }
                }
                jobs.removeAll(for: [experimentID])
                report(error)
            }
        }
    }

    // MARK: - Analisi qualità

    /// L'analisi più recente di un esperimento.
    ///
    /// - Parameter experimentID: L'esperimento.
    /// - Returns: L'analisi, o `nil` se l'esperimento non è stato analizzato.
    func latestQualityAnalysis(for experimentID: UUID) -> VideoQualityAnalysisResult? {
        qualityAnalysisResults
            .filter { $0.experimentID == experimentID }
            .max { $0.analyzedAt < $1.analyzedAt }
    }

    /// Il frame rate del video codificato: quello letto durante l'analisi o, nelle analisi
    /// che non lo registravano, i fotogrammi confrontati divisi per la durata del video.
    ///
    /// - Parameter result: L'analisi.
    /// - Returns: I fotogrammi al secondo; `nil` se non si possono ricavare.
    func framesPerSecond(of result: VideoQualityAnalysisResult) -> Double? {
        if let framesPerSecond = result.framesPerSecond, framesPerSecond > 0 {
            return framesPerSecond
        }

        guard let duration = experiments.first(where: { $0.id == result.experimentID })?.outputInfo?.durationSeconds,
              duration > 0, !result.vmafPerFrame.isEmpty else {
            return nil
        }

        // Presuppone un frame rate costante: serve solo a mostrare l'istante, non entra nei calcoli.
        return Double(result.vmafPerFrame.count) / duration
    }

    /// Estrae lo stesso fotogramma dall'originale e dal video codificato, come immagini PNG.
    ///
    /// - Parameters:
    ///   - result: L'analisi.
    ///   - index: Il numero del fotogramma, contato come in libvmaf.
    /// - Returns: Le due immagini, o `nil` se un file non è raggiungibile (l'errore viene mostrato).
    func frameImages(for result: VideoQualityAnalysisResult, index: Int) async -> (original: Data, encoded: Data)? {
        do {
            let sourceURL = try experimentSourceURL(result.experimentID)
            let outputURL = try experimentOutputURL(result.experimentID)

            let original = try await QualityAnalysisService.extractFrame(
                from: sourceURL,
                index: index,
                clip: result.encodingSettings.clip
            )
            let encoded = try await QualityAnalysisService.extractFrame(from: outputURL, index: index, clip: nil)

            return (original, encoded)
        } catch {
            refreshFileAvailability()
            report(error, context: "Impossibile estrarre il fotogramma")
            return nil
        }
    }

    /// Elimina un'analisi.
    ///
    /// - Parameter id: L'analisi.
    func removeQualityAnalysisResult(id: UUID) {
        saveAnalyses(qualityAnalysisResults.filter { $0.id != id })
    }

    /// Prepara l'analisi qualità di un esperimento codificato.
    ///
    /// - Parameter experimentID: L'esperimento.
    /// - Returns: Il lavoro, o `nil` se la codifica non è completata, se manca libvmaf
    ///   o se un file non è raggiungibile (l'errore viene mostrato).
    private func prepareQualityAnalysis(experimentID: UUID) -> PreparedJob? {
        guard let experiment = findExperiment(experimentID) else { return nil }

        guard experiment.status == .completed else {
            report(AppError("È necessario completare prima la codifica."))
            return nil
        }

        guard isLibVMAFAvailable == true else {
            report(AppError("FFmpeg non include libvmaf: l'analisi qualità non è disponibile. Installa una build di FFmpeg con libvmaf."))
            return nil
        }

        let sourceURL: URL
        let outputURL: URL

        do {
            sourceURL = try experimentSourceURL(experimentID)
            outputURL = try experimentOutputURL(experimentID)
        } catch {
            report(error)
            return nil
        }

        // La pausa è possibile solo durante il calcolo VMAF, il passaggio più lungo.
        let job = ActiveJob(
            kind: .qualityAnalysis,
            experimentID: experimentID,
            stage: "Preparazione dell'analisi…",
            isProgressDeterminate: false,
            canPause: false
        )

        return PreparedJob(job: job) { [self] context in
            do {
                let analysis = try await QualityAnalysisService().analyze(
                    experiment: findExperiment(experimentID) ?? experiment,
                    sourceURL: sourceURL,
                    outputURL: outputURL,
                    processControl: context.control,
                    elapsedDuration: context.elapsedDuration,
                    onStage: { stage in context.job.stage = stage },
                    onVMAFStarted: { isDeterminate in
                        context.job.isProgressDeterminate = isDeterminate
                        context.job.canPause = true
                    },
                    onProgress: context.onProgress
                )

                saveAnalyses([analysis] + qualityAnalysisResults)
            } catch is CancellationError {
                // Annullata: non viene salvato alcun risultato parziale.
            } catch {
                report(error, context: "Analisi qualità non riuscita")
            }
        }
    }

    // MARK: - Audio

    /// Crea una serie audio e ne mette in coda le codifiche.
    ///
    /// La prima traccia audio del file, o dello spezzone, viene codificata con ogni encoder
    /// AAC disponibile ai bitrate di ``AudioExperiment/seriesBitratesKbps``.
    ///
    /// - Parameters:
    ///   - sourceID: Il file originale, nella Libreria.
    ///   - clip: La parte del file da codificare; `nil` per il file intero.
    ///   - outputFolder: La cartella in cui salvare i file .m4a, con nomi automatici.
    func createAudioSeries(sourceID: UUID, clip: ClipRange?, outputFolder: URL) async {
        // Una serie alla volta, e solo a coda ferma: un secondo clic mentre si legge il file non fa nulla.
        guard !isCreatingAudioSeries, !jobs.isBusy else { return }

        isCreatingAudioSeries = true
        defer { isCreatingAudioSeries = false }

        do {
            let sourceURL = try libraryURL(for: sourceID)
            let document = try await FFprobeService().probe(sourceURL)

            guard document.hasAudio else {
                throw AppError("Il file non contiene una traccia audio.")
            }

            guard let source = libraryItems.first(where: { $0.id == sourceID }) else {
                throw MediaLibraryError.itemNotFound
            }

            // L'AAC di AudioToolbox si usa solo se FFmpeg lo include.
            let encoders = AudioEncoder.allCases.filter { $0 != .apple || isAppleAACAvailable == true }

            let series = encoders.flatMap { encoder in
                AudioExperiment.seriesBitratesKbps.map {
                    AudioExperiment(source: source, encoder: encoder, bitrateKbps: $0, clip: clip)
                }
            }

            saveAudioExperiments(series + audioExperiments)

            let baseName = URL(fileURLWithPath: source.name).deletingPathExtension().lastPathComponent

            var reserved = reservedOutputPaths()

            jobs.enqueue(series.map { experiment in
                // Per esempio akiyo_aac_at_96k.m4a; un numero in più se il nome è già preso.
                let outputURL = Self.availableFileURL(
                    in: outputFolder,
                    name: "\(baseName)_\(experiment.encoder.rawValue)_\(experiment.bitrateKbps)k",
                    extension: "m4a",
                    reserved: reserved
                )
                reserved.insert(outputURL.standardizedFileURL.path)

                return QueuedJob(kind: .audioEncoding, experimentID: experiment.id, outputURL: outputURL)
            })
        } catch {
            report(error, context: "Impossibile creare la serie audio")
        }
    }

    /// Elimina degli esperimenti audio e i loro lavori in coda, e sposta nel Cestino i file .m4a.
    ///
    /// - Parameter ids: Gli esperimenti.
    /// - Returns: Vero se sono stati eliminati; falso se uno è in lavorazione o se il salvataggio
    ///   non è riuscito (in questo caso l'errore viene mostrato).
    @discardableResult
    func removeAudioExperiments(ids: Set<UUID>) -> Bool {
        guard !ids.isEmpty, !ids.contains(where: { jobs.isRunning($0) }) else { return false }

        let removed = audioExperiments.filter { ids.contains($0.id) }

        do {
            try audioStore.save(audioExperiments.filter { !ids.contains($0.id) })
        } catch {
            report(error, context: "Impossibile eliminare l'esperimento audio")
            return false
        }

        audioExperiments.removeAll { ids.contains($0.id) }
        jobs.removeAll(for: ids)

        for experiment in removed {
            moveToTrash(experiment.outputBookmarkData, fileName: experiment.output?.fileName)
        }
        return true
    }

    /// I file che i lavori in coda devono ancora produrre: non vanno assegnati ad altre codifiche.
    private func reservedOutputPaths() -> Set<String> {
        Set(jobs.pending.compactMap { $0.outputURL?.standardizedFileURL.path })
    }

    /// Il primo nome libero per un file delle serie: `nome.estensione`, poi `nome_2.estensione`, `nome_3.estensione`…
    ///
    /// Un nome è occupato se il file esiste, se una codifica lo sta scrivendo (c'è il suo file parziale)
    /// o se un lavoro in coda lo produrrà. Così rifare una serie nella stessa cartella
    /// non sovrascrive i file della serie precedente.
    ///
    /// - Parameters:
    ///   - folder: La cartella.
    ///   - name: Il nome senza estensione, per esempio `akiyo_hevc_275k_hw`.
    ///   - fileExtension: L'estensione, per esempio `mp4`.
    ///   - reserved: I percorsi già assegnati ad altri lavori.
    /// - Returns: Il file da produrre.
    static func availableFileURL(
        in folder: URL,
        name: String,
        extension fileExtension: String,
        reserved: Set<String>
    ) -> URL {
        let fileManager = FileManager.default

        var attempt = 1

        while true {
            let fileName = attempt == 1 ? "\(name).\(fileExtension)" : "\(name)_\(attempt).\(fileExtension)"
            let url = folder.appendingPathComponent(fileName)

            let isTaken = reserved.contains(url.standardizedFileURL.path)
                || fileManager.fileExists(atPath: url.path)
                || fileManager.fileExists(atPath: EncodingService.partialURL(for: url).path)

            if !isTaken { return url }
            attempt += 1
        }
    }

    /// Sposta nel Cestino un file prodotto da CodecLab. Un file già sparito non è un errore.
    ///
    /// - Parameters:
    ///   - bookmarkData: Il bookmark del file.
    ///   - fileName: Il nome del file, per i messaggi.
    private func moveToTrash(_ bookmarkData: Data?, fileName: String?) {
        guard var data = bookmarkData,
              let url = try? Bookmark.resolve(&data, fileName: fileName ?? "codificato"),
              FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            report(error, context: "Impossibile spostare nel Cestino «\(url.lastPathComponent)»")
        }
    }

    /// Prepara la codifica di un esperimento audio.
    ///
    /// - Parameters:
    ///   - experimentID: L'esperimento.
    ///   - outputURL: Il file .m4a da produrre.
    /// - Returns: Il lavoro, o `nil` se l'esperimento non c'è più o il file originale non è raggiungibile.
    private func prepareAudioEncoding(experimentID: UUID, outputURL: URL) -> PreparedJob? {
        guard let experiment = audioExperiments.first(where: { $0.id == experimentID }) else { return nil }

        let sourceURL: URL

        do {
            sourceURL = try audioSourceURL(experimentID)
        } catch {
            report(error)
            return nil
        }

        let job = ActiveJob(
            kind: .audioEncoding,
            experimentID: experimentID,
            stage: "Codifica audio (\(experiment.encoder.title), \(experiment.bitrateKbps) kb/s)…",
            isProgressDeterminate: true,
            canPause: true
        )

        return PreparedJob(job: job, partialFileURL: EncodingService.partialURL(for: outputURL)) { [self] context in
            do {
                let output = try await AudioEncodingService().encode(
                    experiment,
                    sourceURL: sourceURL,
                    outputURL: outputURL,
                    processControl: context.control,
                    elapsedDuration: context.elapsedDuration,
                    onProgress: context.onProgress
                )

                updateAudioExperiment(experimentID) {
                    $0.status = .completed
                    $0.outputBookmarkData = output.bookmark
                    $0.output = output.info
                }
            } catch is CancellationError {
                // Annullata: l'esperimento resta com'era.
            } catch {
                updateAudioExperiment(experimentID) {
                    if $0.status != .completed {
                        $0.status = .failed
                    }
                }
                report(error)
            }
        }
    }

    // MARK: - Errori

    /// Chiude il messaggio di errore.
    func dismissError() {
        errorMessage = nil
    }

    /// Mostra un errore all'utente. Se c'è già un messaggio, il nuovo viene aggiunto in coda.
    ///
    /// - Parameters:
    ///   - error: L'errore.
    ///   - context: Che cosa non è riuscito, messo prima della descrizione dell'errore.
    private func report(_ error: Error, context: String? = nil) {
        let message = context.map { "\($0): \(error.localizedDescription)" } ?? error.localizedDescription

        errorMessage = errorMessage.map { "\($0)\n\n\(message)" } ?? message
    }

    // MARK: - Salvataggio

    /// Salva la Libreria e, se il salvataggio riesce, la aggiorna; altrimenti mostra l'errore.
    private func saveLibrary(_ items: [MediaLibraryItem]) {
        do {
            try libraryStore.save(items)
            libraryItems = items
        } catch {
            report(error, context: "Impossibile salvare la libreria")
        }
    }

    /// Salva gli esperimenti video e, se il salvataggio riesce, li aggiorna; altrimenti mostra l'errore.
    private func saveExperiments(_ updated: [EncodingExperiment]) {
        do {
            try experimentStore.save(updated)
            experiments = updated
        } catch {
            report(error, context: "Impossibile salvare gli esperimenti")
        }
    }

    /// Salva le analisi e, se il salvataggio riesce, le aggiorna; altrimenti mostra l'errore.
    private func saveAnalyses(_ updated: [VideoQualityAnalysisResult]) {
        do {
            try analysisStore.save(updated)
            qualityAnalysisResults = updated
        } catch {
            report(error, context: "Impossibile salvare le analisi")
        }
    }

    /// Salva gli esperimenti audio e, se il salvataggio riesce, li aggiorna; altrimenti mostra l'errore.
    private func saveAudioExperiments(_ updated: [AudioExperiment]) {
        do {
            try audioStore.save(updated)
            audioExperiments = updated
        } catch {
            report(error, context: "Impossibile salvare gli esperimenti audio")
        }
    }

    /// Modifica un esperimento audio e lo salva. Se l'esperimento non c'è più, non fa nulla.
    private func updateAudioExperiment(_ id: UUID, _ change: (inout AudioExperiment) -> Void) {
        guard let index = audioExperiments.firstIndex(where: { $0.id == id }) else { return }

        var updated = audioExperiments
        change(&updated[index])
        saveAudioExperiments(updated)
    }

    /// L'esperimento video con l'identificativo indicato.
    private func findExperiment(_ id: UUID) -> EncodingExperiment? {
        experiments.first { $0.id == id }
    }

    /// Modifica un esperimento video e lo salva. Se l'esperimento non c'è più, non fa nulla.
    private func updateExperiment(_ id: UUID, _ change: (inout EncodingExperiment) -> Void) {
        guard let index = experiments.firstIndex(where: { $0.id == id }) else { return }

        var updated = experiments
        change(&updated[index])
        saveExperiments(updated)
    }

    // MARK: - Risoluzione dei file tramite bookmark
    // Se macOS aggiorna un bookmark (file spostato o rinominato), la nuova versione viene salvata.

    /// La posizione attuale di un file della Libreria; salva il bookmark aggiornato, se serve.
    ///
    /// - Throws: ``MediaLibraryError`` se l'elemento non c'è più o il file non è raggiungibile.
    private func libraryURL(for id: UUID) throws -> URL {
        guard let item = libraryItems.first(where: { $0.id == id }) else {
            throw MediaLibraryError.itemNotFound
        }

        var data = item.bookmarkData
        let url = try Bookmark.resolve(&data, fileName: item.name)

        if data != item.bookmarkData {
            saveLibrary(libraryItems.map {
                var updated = $0
                if updated.id == id { updated.bookmarkData = data }
                return updated
            })
        }

        return url
    }

    /// La posizione attuale del file originale di un esperimento video.
    ///
    /// - Throws: Un errore se l'esperimento non c'è più o il file non è raggiungibile.
    private func experimentSourceURL(_ id: UUID) throws -> URL {
        guard let experiment = findExperiment(id) else {
            throw AppError("Esperimento non trovato.")
        }

        var data = experiment.sourceBookmarkData
        let url = try Bookmark.resolve(&data, fileName: experiment.sourceName)

        if data != experiment.sourceBookmarkData {
            updateExperiment(id) { $0.sourceBookmarkData = data }
        }

        return url
    }

    /// La posizione attuale del file originale di un esperimento audio.
    ///
    /// - Throws: Un errore se l'esperimento non c'è più o il file non è raggiungibile.
    private func audioSourceURL(_ id: UUID) throws -> URL {
        guard let experiment = audioExperiments.first(where: { $0.id == id }) else {
            throw AppError("Esperimento audio non trovato.")
        }

        var data = experiment.sourceBookmarkData
        let url = try Bookmark.resolve(&data, fileName: experiment.sourceName)

        if data != experiment.sourceBookmarkData {
            updateAudioExperiment(id) { $0.sourceBookmarkData = data }
        }

        return url
    }

    /// La posizione attuale del video codificato di un esperimento.
    ///
    /// - Throws: Un errore se l'esperimento non è stato codificato o il file non è raggiungibile.
    private func experimentOutputURL(_ id: UUID) throws -> URL {
        guard let experiment = findExperiment(id), var data = experiment.outputBookmarkData else {
            throw AppError("Questo esperimento non dispone ancora di un video codificato.")
        }

        let url = try Bookmark.resolve(&data, fileName: experiment.outputFileName ?? "codificato")

        if data != experiment.outputBookmarkData {
            updateExperiment(id) { $0.outputBookmarkData = data }
        }

        return url
    }
}
