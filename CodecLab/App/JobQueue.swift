// JobQueue.swift
// Coda dei lavori FFmpeg: un lavoro alla volta, nell'ordine di arrivo, con pausa,
// annullamento e cronometro. La coda non sa che cosa fanno i lavori: li prepara
// AppViewModel (`prepare`), che ne gestisce anche i risultati.

import Foundation
import Observation

/// Il lavoro in esecuzione in questo momento: una codifica, un'analisi della qualità o una codifica audio.
///
/// Contiene ciò che serve a mostrarlo: il tipo di lavoro, la fase («Prima passata», «Analisi VMAF»…),
/// l'avanzamento e lo stato della pausa. È osservabile in modo autonomo: quando l'avanzamento cambia,
/// molte volte al secondo, si aggiornano solo le barre di avanzamento, non il resto della finestra.
@Observable
final class ActiveJob {
    /// I tipi di lavoro.
    enum Kind {
        /// La codifica di un esperimento video.
        case encoding
        /// L'analisi qualità di un esperimento video.
        case qualityAnalysis
        /// La codifica di un esperimento audio.
        case audioEncoding
    }

    /// L'identificativo del lavoro.
    let id = UUID()
    /// Il tipo di lavoro.
    let kind: Kind
    /// L'esperimento, video o audio secondo il tipo di lavoro.
    let experimentID: UUID
    /// La fase in corso, mostrata all'utente.
    var stage: String
    /// L'avanzamento (0–1).
    var progress: Double = 0
    /// Falso se l'avanzamento non si può misurare: si mostra una barra indeterminata.
    var isProgressDeterminate: Bool
    /// Vero se il lavoro si può mettere in pausa in questo momento.
    var canPause: Bool
    /// Vero se il lavoro è in pausa.
    var isPaused = false

    /// Crea la descrizione di un lavoro.
    ///
    /// - Parameters:
    ///   - kind: Il tipo di lavoro.
    ///   - experimentID: L'esperimento.
    ///   - stage: La fase iniziale, mostrata all'utente.
    ///   - isProgressDeterminate: Vero se l'avanzamento si può misurare.
    ///   - canPause: Vero se il lavoro si può mettere in pausa.
    init(kind: Kind, experimentID: UUID, stage: String, isProgressDeterminate: Bool, canPause: Bool) {
        self.kind = kind
        self.experimentID = experimentID
        self.stage = stage
        self.isProgressDeterminate = isProgressDeterminate
        self.canPause = canPause
    }
}

/// Un lavoro in attesa nella coda: parte quando quelli prima di lui sono terminati.
///
/// Contiene solo ciò che serve a riconoscerlo (il tipo e l'esperimento a cui si riferisce): il lavoro vero
/// viene preparato al momento di partire, così usa i dati più aggiornati.
struct QueuedJob: Identifiable {
    /// L'identificativo del lavoro in coda.
    let id = UUID()
    /// Il tipo di lavoro.
    let kind: ActiveJob.Kind
    /// L'esperimento, video o audio secondo il tipo di lavoro.
    let experimentID: UUID
    /// Il file da produrre; solo per le codifiche.
    var outputURL: URL? = nil
}

/// Un lavoro pronto a partire: come mostrarlo all'utente e che cosa eseguire.
///
/// Lo prepara ``AppViewModel`` quando il lavoro arriva in testa alla coda. La funzione ``work`` esegue
/// FFmpeg, salva il risultato e gestisce da sé errori e annullamento; il file parziale, se c'è,
/// viene eliminato quando il lavoro viene annullato o l'app viene chiusa.
struct PreparedJob {
    /// La descrizione del lavoro, mostrata durante l'esecuzione.
    let job: ActiveJob
    /// Il file temporaneo da eliminare se l'app si chiude durante il lavoro.
    var partialFileURL: URL? = nil
    /// Il lavoro da eseguire.
    let work: @MainActor (JobContext) async -> Void
}

/// Ciò che la coda mette a disposizione del lavoro in esecuzione: il modo di comunicare fase e avanzamento,
/// il controllo del processo FFmpeg (con cui la coda può metterlo in pausa o terminarlo)
/// e il cronometro, che esclude le pause.
struct JobContext {
    /// La descrizione del lavoro: il lavoro può aggiornarne fase e avanzamento.
    let job: ActiveJob
    /// Il controllo da passare a FFmpeg, per pausa e annullamento.
    let control: FFmpegProcessControl
    /// Restituisce il tempo di lavoro trascorso, escluse le pause.
    let elapsedDuration: () -> TimeInterval
    /// Aggiorna l'avanzamento; si può chiamare da qualsiasi thread.
    let onProgress: @Sendable (Double) -> Void
}

/// La coda dei lavori di FFmpeg: esegue un lavoro alla volta, nell'ordine in cui è stato chiesto.
///
/// Codifiche e analisi impegnano molto il Mac; eseguirle in parallelo non le renderebbe più veloci
/// e falserebbe i tempi misurati. Per questo «Crea serie», che chiede otto codifiche e otto analisi,
/// le mette in fila qui.
///
/// La coda non sa che cosa fanno i lavori: quando uno arriva in testa chiede ad ``AppViewModel`` di prepararlo,
/// lo esegue e passa al successivo. Si occupa di ciò che vale per tutti: pausa e ripresa, annullamento di un lavoro
/// o di tutti, e un cronometro che esclude le pause, così i tempi di codifica restano confrontabili.
@Observable
final class JobQueue {
    /// Il lavoro in corso, se c'è.
    private(set) var current: ActiveJob?
    /// I lavori in attesa, in ordine.
    private(set) var pending: [QueuedJob] = []

    /// Lavori conclusi da quando la coda ha iniziato a lavorare: serve per mostrare
    /// "lavoro 3 di 16". Torna a zero quando non resta più nulla da fare.
    private(set) var finishedCount = 0

    /// Prepara un lavoro arrivato in testa alla coda. Restituisce nil se non può partire
    /// (per esempio un file non raggiungibile): l'errore è già stato segnalato e si passa al successivo.
    @ObservationIgnored var prepare: (QueuedJob) -> PreparedJob? = { _ in nil }

    /// Chiamata alla fine di ogni lavoro, riuscito, fallito o annullato.
    @ObservationIgnored var onJobFinished: () -> Void = {}

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var control = FFmpegProcessControl()
    @ObservationIgnored private var stopwatch = PausableStopwatch()
    @ObservationIgnored private var partialFileURL: URL?

    // MARK: - Coda

    /// Aggiunge dei lavori in fondo alla coda e avvia il primo, se la coda era ferma.
    ///
    /// - Parameter jobs: I lavori, nell'ordine in cui eseguirli.
    func enqueue(_ jobs: [QueuedJob]) {
        pending += jobs
        startNext()
    }

    /// Aggiunge un lavoro in fondo alla coda e lo avvia, se la coda era ferma.
    ///
    /// - Parameter job: Il lavoro.
    func enqueue(_ job: QueuedJob) {
        enqueue([job])
    }

    /// Toglie un lavoro in attesa.
    ///
    /// - Parameter id: L'identificativo del lavoro in coda.
    func remove(id: UUID) {
        pending.removeAll { $0.id == id }
    }

    /// Toglie tutti i lavori in attesa di alcuni esperimenti. Il lavoro in corso non viene toccato.
    ///
    /// - Parameter experimentIDs: Gli esperimenti.
    func removeAll(for experimentIDs: Set<UUID>) {
        pending.removeAll { experimentIDs.contains($0.experimentID) }
    }

    /// Vero se il lavoro in corso riguarda l'esperimento.
    ///
    /// - Parameter experimentID: L'esperimento.
    func isRunning(_ experimentID: UUID) -> Bool {
        current?.experimentID == experimentID
    }

    /// Vero se per l'esperimento c'è un lavoro di questo tipo in corso o in coda.
    ///
    /// - Parameters:
    ///   - kind: Il tipo di lavoro.
    ///   - experimentID: L'esperimento.
    func hasPending(_ kind: ActiveJob.Kind, for experimentID: UUID) -> Bool {
        (current?.kind == kind && current?.experimentID == experimentID)
            || pending.contains { $0.kind == kind && $0.experimentID == experimentID }
    }

    // MARK: - Avanzamento della coda

    /// Vero se c'è un lavoro in corso o in attesa: finché è così non si creano esperimenti né serie.
    var isBusy: Bool {
        current != nil || !pending.isEmpty
    }

    /// La posizione del lavoro in corso nella coda, per esempio 3 di 16; `nil` se la coda è ferma.
    var position: (current: Int, total: Int)? {
        guard current != nil else { return nil }
        return (finishedCount + 1, finishedCount + 1 + pending.count)
    }

    /// L'avanzamento complessivo della coda (0–1): i lavori conclusi più la parte svolta di quello in corso.
    /// Ogni lavoro conta allo stesso modo, anche se una codifica e un'analisi durano diversamente.
    var overallProgress: Double? {
        guard let current, let position else { return nil }
        return (Double(finishedCount) + (current.isProgressDeterminate ? current.progress : 0)) / Double(position.total)
    }

    // MARK: - Lavoro in corso

    /// Mette in pausa il lavoro in corso, se lo permette.
    func pause() {
        guard let current, current.canPause, !current.isPaused else { return }

        control.pause()
        stopwatch.pause()
        current.isPaused = true
    }

    /// Riprende il lavoro in pausa.
    func resume() {
        guard let current, current.isPaused else { return }

        control.resume()
        stopwatch.resume()
        current.isPaused = false
    }

    /// Annulla il lavoro in corso; poi parte il successivo.
    func cancel() {
        task?.cancel()
    }

    /// Svuota la coda e poi annulla il lavoro in corso: al termine non parte nient'altro.
    func cancelAll() {
        pending.removeAll()
        cancel()
    }

    /// Alla chiusura dell'app FFmpeg non deve restare in esecuzione (o sospeso) da solo,
    /// e il lavoro non fa in tempo a ripulire: il file parziale va eliminato qui.
    func stopBeforeTermination() {
        pending.removeAll()
        guard current != nil else { return }

        control.cancel()

        if let partialFileURL {
            try? FileManager.default.removeItem(at: partialFileURL)
        }
    }

    // MARK: - Avvio e conclusione

    /// Avvia i lavori in testa alla coda finché uno parte davvero o la coda si svuota.
    private func startNext() {
        // Un lavoro che non può partire viene scartato e si prova subito il successivo.
        while current == nil, !pending.isEmpty {
            let next = pending.removeFirst()

            if let prepared = prepare(next) {
                start(prepared)
            }
        }
    }

    /// Esegue un lavoro preparato e, alla fine, lo conclude.
    ///
    /// - Parameter prepared: Il lavoro.
    private func start(_ prepared: PreparedJob) {
        let job = prepared.job

        // Un controllo nuovo per ogni lavoro: un annullamento non deve restare attivo per il successivo.
        let control = FFmpegProcessControl()

        self.control = control
        stopwatch.start()
        partialFileURL = prepared.partialFileURL
        current = job

        let context = JobContext(
            job: job,
            control: control,
            elapsedDuration: { [weak self] in self?.stopwatch.elapsed ?? 0 },
            // L'avanzamento arriva da un thread secondario. Se arriva a lavoro concluso,
            // aggiorna un oggetto che nessuna vista mostra più.
            onProgress: { [weak job] progress in
                Task { @MainActor [weak job] in
                    job?.progress = progress
                }
            }
        )

        // Il task eredita il main actor: `work` e `finish()` vi girano, mentre FFmpeg lavora altrove.
        // Annullare il task (`cancel()`) termina il processo FFmpeg in corso.
        task = Task {
            await prepared.work(context)
            finish()
        }
    }

    /// Conclude il lavoro terminato (riuscito, fallito o annullato) e avvia il successivo.
    private func finish() {
        current = nil
        task = nil
        partialFileURL = nil
        stopwatch.reset()
        finishedCount += 1
        onJobFinished()

        startNext()

        // Coda vuota: il contatore "lavoro N di M" riparte da capo alla prossima.
        if current == nil {
            finishedCount = 0
        }
    }
}

/// Misura la durata effettiva di un lavoro, escludendo le pause.
private struct PausableStopwatch {
    private var accumulatedTime: TimeInterval = 0
    private var startTime: TimeInterval?

    private var now: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    /// Il tempo trascorso dall'avvio, escluse le pause, in secondi.
    var elapsed: TimeInterval {
        accumulatedTime + (startTime.map { now - $0 } ?? 0)
    }

    /// Azzera il cronometro e lo avvia.
    mutating func start() {
        accumulatedTime = 0
        startTime = now
    }

    /// Ferma il conteggio.
    mutating func pause() {
        guard let startTime else { return }

        accumulatedTime += now - startTime
        self.startTime = nil
    }

    /// Riprende il conteggio.
    mutating func resume() {
        guard startTime == nil else { return }

        startTime = now
    }

    /// Azzera il cronometro.
    mutating func reset() {
        accumulatedTime = 0
        startTime = nil
    }
}
