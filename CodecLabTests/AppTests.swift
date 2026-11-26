// AppTests.swift
// Parti dell'app che non riguardano direttamente i video: coda dei lavori, salvataggio dei dati,
// file temporanei, testi mostrati all'utente, relazione e ricerca.
//
// Strategia di verifica
// ---------------------
// Sono test automatici scritti con Swift Testing ed eseguiti in Xcode con ⌘U. Nessun test avvia
// FFmpeg o FFprobe: i risultati non dipendono dagli strumenti installati né dai video sul disco,
// quindi sono ripetibili su qualsiasi Mac.
//
// - Coda dei lavori: test di componente con lavori fittizi (test double) al posto delle codifiche;
//   verificano il comportamento osservabile nel tempo (ordine, annullamento, pausa) attraverso
//   la sola interfaccia della coda, cioè a scatola chiusa.
// - Salvataggio e file temporanei: test di integrazione con il file system reale, in cartelle
//   temporanee create e cancellate da ogni test.
// - Testi, relazione e ricerca: test unitari a scatola chiusa, basati su esempi: a un ingresso
//   noto deve corrispondere esattamente l'uscita attesa (il testo, il filtro).

import Foundation
import Testing
@testable import CodecLab

// MARK: - Coda dei lavori

/// Test di componente della coda dei lavori (``JobQueue``), a scatola chiusa.
///
/// Al posto di codifiche e analisi si usano lavori fittizi: uno annota il proprio nome quando parte,
/// un altro resta in esecuzione finché non viene annullato. Così si verifica il comportamento
/// della coda nel tempo (un lavoro alla volta, in ordine; annullamento; pausa; pulizia dei file
/// parziali) senza dipendere da FFmpeg e in pochi millisecondi.
@MainActor
struct JobQueueTests {

    /// Un lavoro che annota il proprio nome quando viene eseguito.
    private static func job(_ name: String, log: Log, experimentID: UUID = UUID()) -> PreparedJob {
        PreparedJob(
            job: ActiveJob(kind: .encoding, experimentID: experimentID, stage: name, isProgressDeterminate: true, canPause: true)
        ) { _ in
            log.entries.append(name)
        }
    }

    /// Un lavoro che resta in esecuzione finché non viene annullato.
    private static func longJob(experimentID: UUID = UUID(), partialFileURL: URL? = nil) -> PreparedJob {
        PreparedJob(
            job: ActiveJob(kind: .encoding, experimentID: experimentID, stage: "lungo", isProgressDeterminate: true, canPause: true),
            partialFileURL: partialFileURL
        ) { _ in
            try? await Task.sleep(for: .seconds(30))
        }
    }

    private final class Log {
        var entries: [String] = []
    }

    /// Lascia lavorare la coda finché non ha finito (al massimo 2 secondi).
    private func waitUntilIdle(_ queue: JobQueue) async {
        var attempts = 0

        while queue.current != nil || !queue.pending.isEmpty, attempts < 200 {
            attempts += 1
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Aspetta che il primo lavoro sia partito (al massimo 2 secondi).
    private func waitUntilRunning(_ queue: JobQueue) async {
        var attempts = 0

        while queue.current == nil, attempts < 200 {
            attempts += 1
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("I lavori vengono eseguiti uno alla volta, in ordine")
    func order() async {
        let queue = JobQueue()
        let log = Log()
        var finished = 0

        queue.prepare = { queued in Self.job(queued.id.uuidString, log: log) }
        queue.onJobFinished = { finished += 1 }

        let queued = (0..<3).map { _ in QueuedJob(kind: .encoding, experimentID: UUID()) }
        queue.enqueue(queued)
        await waitUntilIdle(queue)

        #expect(log.entries == queued.map(\.id.uuidString))
        #expect(finished == 3)
        #expect(queue.finishedCount == 0)   // Torna a zero quando la coda è vuota
    }

    @Test("Un lavoro che non può partire lascia il posto al successivo")
    func skipsUnpreparedJobs() async {
        let queue = JobQueue()
        let log = Log()
        let skipped = QueuedJob(kind: .qualityAnalysis, experimentID: UUID())
        let next = QueuedJob(kind: .encoding, experimentID: UUID())

        queue.prepare = { queued in
            queued.id == skipped.id ? nil : Self.job("eseguito", log: log)
        }

        queue.enqueue([skipped, next])
        await waitUntilIdle(queue)

        #expect(log.entries == ["eseguito"])
    }

    @Test("Annulla tutto: si ferma il lavoro in corso e non parte nient'altro")
    func cancelAll() async {
        let queue = JobQueue()
        let log = Log()
        let first = QueuedJob(kind: .encoding, experimentID: UUID())

        queue.prepare = { queued in
            queued.id == first.id ? Self.longJob() : Self.job("non doveva partire", log: log)
        }

        queue.enqueue([first, QueuedJob(kind: .encoding, experimentID: UUID()), QueuedJob(kind: .qualityAnalysis, experimentID: UUID())])
        await waitUntilRunning(queue)
        #expect(queue.pending.count == 2)

        queue.cancelAll()
        await waitUntilIdle(queue)

        #expect(queue.current == nil)
        #expect(queue.pending.isEmpty)
        #expect(log.entries.isEmpty)
    }

    @Test("Lavori in corso e in coda di un esperimento")
    func pendingQueries() async {
        let queue = JobQueue()
        let running = UUID()
        let waiting = UUID()

        queue.prepare = { queued in Self.longJob(experimentID: queued.experimentID) }
        queue.enqueue([
            QueuedJob(kind: .encoding, experimentID: running),
            QueuedJob(kind: .qualityAnalysis, experimentID: waiting),
        ])
        await waitUntilRunning(queue)

        #expect(queue.isRunning(running))
        #expect(queue.hasPending(.encoding, for: running))
        #expect(queue.hasPending(.qualityAnalysis, for: waiting))
        #expect(!queue.hasPending(.encoding, for: waiting))

        queue.removeAll(for: [waiting])
        #expect(!queue.hasPending(.qualityAnalysis, for: waiting))

        queue.cancelAll()
        await waitUntilIdle(queue)
    }

    @Test("Pausa e ripresa solo per i lavori che lo permettono")
    func pause() async {
        let queue = JobQueue()
        queue.prepare = { _ in Self.longJob() }
        queue.enqueue(QueuedJob(kind: .encoding, experimentID: UUID()))
        await waitUntilRunning(queue)

        queue.pause()
        #expect(queue.current?.isPaused == true)
        queue.resume()
        #expect(queue.current?.isPaused == false)

        queue.current?.canPause = false
        queue.pause()
        #expect(queue.current?.isPaused == false)

        queue.cancelAll()
        await waitUntilIdle(queue)
    }

    @Test("Alla chiusura dell'app il file parziale viene eliminato")
    func partialFileRemovedOnTermination() async throws {
        let partial = FileManager.default.temporaryDirectory.appendingPathComponent(".codeclab-\(UUID()).mp4.partial")
        try Data("parziale".utf8).write(to: partial)

        let queue = JobQueue()
        queue.prepare = { _ in Self.longJob(partialFileURL: partial) }
        queue.enqueue(QueuedJob(kind: .encoding, experimentID: UUID()))
        await waitUntilRunning(queue)

        queue.stopBeforeTermination()
        #expect(!FileManager.default.fileExists(atPath: partial.path))

        queue.cancel()
        await waitUntilIdle(queue)
    }
}

// MARK: - Salvataggio

/// Test di integrazione del salvataggio (``JSONStore``) con il file system reale.
///
/// Ogni test lavora in una cartella temporanea propria, poi cancellata: verifica che ciò che si salva
/// si rilegga identico e che un file illeggibile venga messo da parte invece di essere sovrascritto,
/// cioè che i dati dell'utente non vadano persi.
@MainActor
struct JSONStoreTests {
    private struct Item: Codable, Equatable {
        let name: String
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("codeclab-test-\(UUID())", isDirectory: true)
    }

    @Test("Senza file l'elenco è vuoto; ciò che si salva si rilegge")
    func roundTrip() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = JSONStore<Item>(fileName: "Elementi.json", directory: directory)
        #expect(try store.load().isEmpty)

        try store.save([Item(name: "a"), Item(name: "b")])
        #expect(try JSONStore<Item>(fileName: "Elementi.json", directory: directory).load() == [Item(name: "a"), Item(name: "b")])
    }

    @Test("Un file illeggibile viene messo da parte, non sovrascritto")
    func unreadableFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("non è JSON".utf8).write(to: directory.appendingPathComponent("Elementi.json"))

        let store = JSONStore<Item>(fileName: "Elementi.json", directory: directory)
        #expect(throws: AppError.self) { try store.load() }

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.count == 1)
        #expect(files.first?.contains("illeggibile") == true)

        // Il file originale non c'è più: si riparte da un elenco vuoto e si può salvare.
        #expect(try store.load().isEmpty)
        try store.save([Item(name: "nuovo")])
    }
}

// MARK: - File temporaneo della codifica

/// Test unitari dei file temporanei della codifica, con il file system reale.
///
/// Verificano il percorso del file parziale, la sua sostituzione con il file definitivo
/// a codifica riuscita e la scelta di nomi che non sovrascrivono file esistenti o già riservati.
@MainActor
struct PartialFileTests {

    @Test("Il file parziale è nascosto, accanto alla destinazione")
    func partialURL() {
        let output = URL(fileURLWithPath: "/Users/prova/Video/serie_h264_500k.mp4")
        #expect(EncodingService.partialURL(for: output).path == "/Users/prova/Video/.serie_h264_500k.mp4.partial")
    }

    @Test("A codifica riuscita il parziale prende il posto della destinazione")
    func moveIntoPlace() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codeclab-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let output = directory.appendingPathComponent("uscita.mp4")
        let partial = EncodingService.partialURL(for: output)

        // Destinazione assente
        try Data("primo".utf8).write(to: partial)
        try EncodingService.moveIntoPlace(partial, to: output)
        #expect(try String(contentsOf: output, encoding: .utf8) == "primo")

        // Destinazione già presente: viene sostituita
        try Data("secondo".utf8).write(to: partial)
        try EncodingService.moveIntoPlace(partial, to: output)
        #expect(try String(contentsOf: output, encoding: .utf8) == "secondo")
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test("Nomi delle serie: un numero in più se il file esiste, è in scrittura o è riservato")
    func availableFileURL() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codeclab-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func next(_ reserved: Set<String> = []) -> String {
            AppViewModel.availableFileURL(in: directory, name: "akiyo_hevc_275k_hw", extension: "mp4", reserved: reserved).lastPathComponent
        }

        #expect(next() == "akiyo_hevc_275k_hw.mp4")

        // Il file esiste già
        try Data().write(to: directory.appendingPathComponent("akiyo_hevc_275k_hw.mp4"))
        #expect(next() == "akiyo_hevc_275k_hw_2.mp4")

        // Una codifica sta scrivendo il _2
        try Data().write(to: EncodingService.partialURL(for: directory.appendingPathComponent("akiyo_hevc_275k_hw_2.mp4")))
        #expect(next() == "akiyo_hevc_275k_hw_3.mp4")

        // Un lavoro in coda produrrà il _3
        let reserved = directory.appendingPathComponent("akiyo_hevc_275k_hw_3.mp4").standardizedFileURL.path
        #expect(next([reserved]) == "akiyo_hevc_275k_hw_4.mp4")
    }
}

// MARK: - Testi

/// Test unitari a scatola chiusa dei testi mostrati all'utente: durate, bitrate e riepilogo
/// di ciò che si elimina insieme a un file. Ogni caso confronta il testo prodotto con quello atteso.
@MainActor
struct TextTests {

    @Test("Durate")
    func duration() {
        #expect(MediaValueFormatter.duration(65) == "1:05")
        #expect(MediaValueFormatter.duration(3725) == "1:02:05")
        #expect(MediaValueFormatter.duration(-1) == "—")
        #expect(MediaValueFormatter.duration(.nan) == "—")
    }

    @Test("Bitrate in kb/s e, da 1 Mb/s, in Mb/s")
    func bitRate() {
        #expect(MediaValueFormatter.bitRate(950_000) == "950 kb/s")
        #expect(MediaValueFormatter.bitRate(999_400) == "999 kb/s")

        // La soglia si applica dopo l'arrotondamento. Il separatore decimale dipende dalla lingua.
        let oneMbps = 1.0.formatted(.number.precision(.fractionLength(1))) + " Mb/s"
        #expect(MediaValueFormatter.bitRate(999_600) == oneMbps)
        #expect(MediaValueFormatter.bitRate(1_500_000) == 1.5.formatted(.number.precision(.fractionLength(1))) + " Mb/s")
    }

    @Test("Cosa si elimina insieme a un file della Libreria")
    func dependentsDescription() {
        typealias Dependents = AppViewModel.LibraryItemDependents

        #expect(Dependents(videoExperiments: 15, audioExperiments: 10, analyses: 12).description
                == "15 esperimenti video, 10 esperimenti audio e 12 analisi")
        #expect(Dependents(videoExperiments: 1, audioExperiments: 0, analyses: 1).description
                == "1 esperimento video e 1 analisi")
        #expect(Dependents(videoExperiments: 0, audioExperiments: 3, analyses: 0).description
                == "3 esperimenti audio")
        #expect(Dependents().isEmpty)
        #expect(!Dependents(audioExperiments: 1).isEmpty)
    }
}

// MARK: - Relazione

/// Test unitari a scatola chiusa della relazione (``ReportBuilder``).
///
/// La relazione è testo: i test confrontano frasi e tabelle prodotte con quelle attese, parola per parola,
/// partendo da dati costruiti nel test. Una modifica involontaria a una frase fa fallire il test.
@MainActor
struct ReportTests {

    @Test("Tabella in Markdown, con il carattere | protetto")
    func tableMarkdown() {
        let table = ReportTable(title: "Prova", headers: ["A", "B"], rows: [["1", "x|y"]])

        #expect(table.markdown == """
            **Prova**

            | A | B |
            | --- | --- |
            | 1 | x\\|y |
            """)
    }

    @Test("Relazione su un file senza esperimenti: solo il file originale, senza conclusioni né raccomandazione")
    func reportWithoutExperiments() throws {
        let document = try JSONDecoder().decode(FFprobeDocument.self, from: Data("""
            {
              "streams": [
                { "codec_type": "video", "codec_name": "h264", "profile": "High", "width": 1280, "height": 720,
                  "avg_frame_rate": "25/1", "pix_fmt": "yuv420p" },
                { "codec_type": "audio", "codec_name": "aac", "sample_rate": "48000", "channels": 2 }
              ],
              "format": { "format_long_name": "QuickTime / MOV", "duration": "65", "bit_rate": "2500000" }
            }
            """.utf8))

        let report = ReportBuilder.report(
            sourceName: "prova.mp4",
            item: nil,
            document: document,
            experiments: [],
            analyses: [],
            audioExperiments: []
        )

        #expect(report.sections.map(\.title) == ["File originale"])
        #expect(report.recommendation == nil)

        // Una frase, senza tabelle.
        let section = try #require(report.sections.first)
        #expect(section.tables.isEmpty)
        #expect(section.paragraphs.first == "Il file originale è un video H.264 / AVC (High) 1280×720 a 25 fps, lungo 1:05, con audio AAC a 2 canali.")

        #expect(report.markdown.hasPrefix("# Relazione su prova.mp4"))
        #expect(report.markdown.contains("## File originale"))
    }

}

// MARK: - Ricerca

/// Test unitari a scatola chiusa della ricerca a parole (``ExperimentSearch``).
///
/// Le frasi sono scelte per classi di equivalenza: frasi che il codice deve capire (gli esempi
/// mostrati nell'app e altre formulazioni) e frasi che non deve interpretare a metà (parole sconosciute,
/// negazioni, due video insieme). Per ciascuna si verifica il filtro ottenuto.
///
/// La riformulazione con Apple Intelligence non è testata qui: dipende da un modello esterno
/// e non è deterministica. Il suo risultato, però, passa sempre dallo stesso interprete verificato
/// da questi test.
@MainActor
struct ExperimentSearchTests {

    /// Impostazioni di prova: HEVC via hardware a 2000 kb/s.
    private static var hevcHardware: EncodingSettings {
        var settings = EncodingSettings()
        settings.codec = .hevc
        settings.profile = .main
        settings.backend = .hardware
        settings.videoBitrateKbps = 2000
        return settings
    }

    @Test("Un filtro vuoto lascia passare tutte le codifiche")
    func emptyFilterMatchesEverything() {
        let filter = ExperimentSearchFilter()
        #expect(filter.isEmpty)
        #expect(filter.matches(settings: Self.hevcHardware, sourceName: "sintel.mov", measuredKbps: nil, meanVMAF: nil, lowestVMAF: nil))
    }

    @Test("Filtro per video, codec, encoder e bitrate")
    func filtersBySettingsAndSource() {
        var filter = ExperimentSearchFilter()
        filter.sourceName = "Sintel"
        filter.codec = .hevc
        filter.backend = .hardware
        filter.minimumBitrateKbps = 1500

        #expect(filter.matches(settings: Self.hevcHardware, sourceName: "sintel_1080p.mov", measuredKbps: 2050, meanVMAF: nil, lowestVMAF: nil))
        #expect(!filter.matches(settings: Self.hevcHardware, sourceName: "parkrun.mov", measuredKbps: 2050, meanVMAF: nil, lowestVMAF: nil))

        filter.maximumBitrateKbps = 1800
        #expect(!filter.matches(settings: Self.hevcHardware, sourceName: "sintel_1080p.mov", measuredKbps: 2050, meanVMAF: nil, lowestVMAF: nil))
    }

    @Test("Le condizioni sul VMAF valgono solo per le codifiche analizzate")
    func qualityConditionsNeedAnAnalysis() {
        var filter = ExperimentSearchFilter()
        filter.minimumMeanVMAF = 90
        filter.maximumLowestVMAF = 50

        #expect(filter.needsAnalysis)
        #expect(!filter.matches(settings: Self.hevcHardware, sourceName: "a", measuredKbps: 2000, meanVMAF: nil, lowestVMAF: nil))
        #expect(filter.matches(settings: Self.hevcHardware, sourceName: "a", measuredKbps: 2000, meanVMAF: 90.2, lowestVMAF: 33.3))
        #expect(!filter.matches(settings: Self.hevcHardware, sourceName: "a", measuredKbps: 2000, meanVMAF: 90.2, lowestVMAF: 62.5))
        #expect(!filter.matches(settings: Self.hevcHardware, sourceName: "a", measuredKbps: 2000, meanVMAF: 89.9, lowestVMAF: 33.3))
    }

    @Test("Togliere un'etichetta toglie la sua condizione")
    func removingALabelClearsItsField() {
        var filter = ExperimentSearchFilter()
        filter.codec = .h264
        filter.minimumMeanVMAF = 90
        #expect(filter.labels.map(\.text) == ["H.264", "VMAF medio ≥ 90"])

        filter.remove(.codec)
        #expect(filter.codec == nil)
        #expect(filter.labels.map(\.field) == [.minimumMeanVMAF])
    }

    private static let names = [
        "sintel_1080p.mov",
        "parkrun_1080p50.y4m",
        "Inchiesta su Selvaggia Lucarelli_720p.mp4"
    ]

    private static func interpret(_ query: String) -> ExperimentSearch.Interpretation {
        ExperimentSearch.interpret(query, sourceNames: names)
    }

    @Test("Gli esempi mostrati nell'app vengono capiti")
    func examplesAreUnderstood() {
        var filter = Self.interpret("HEVC via hardware su Sintel con VMAF sopra 90")
        var expected = ExperimentSearchFilter()
        expected.sourceName = "sintel_1080p.mov"
        expected.codec = .hevc
        expected.backend = .hardware
        expected.minimumMeanVMAF = 90
        #expect(filter == ExperimentSearch.Interpretation(filter: expected))

        filter = Self.interpret("Codifiche software sotto 1 Mb/s")
        expected = ExperimentSearchFilter()
        expected.backend = .software
        expected.maximumBitrateKbps = 1000
        #expect(filter == ExperimentSearch.Interpretation(filter: expected))

        filter = Self.interpret("H.264 con il fotogramma peggiore sotto 50")
        expected = ExperimentSearchFilter()
        expected.codec = .h264
        expected.maximumLowestVMAF = 50
        #expect(filter == ExperimentSearch.Interpretation(filter: expected))

        filter = Self.interpret("Parkrun tra 2000 e 5000 kb/s")
        expected = ExperimentSearchFilter()
        expected.sourceName = "parkrun_1080p50.y4m"
        expected.minimumBitrateKbps = 2000
        expected.maximumBitrateKbps = 5000
        #expect(filter == ExperimentSearch.Interpretation(filter: expected))

        filter = Self.interpret("Codifiche hardware VMAF maggiore di 95")
        expected = ExperimentSearchFilter()
        expected.backend = .hardware
        expected.minimumMeanVMAF = 95
        #expect(filter == ExperimentSearch.Interpretation(filter: expected))
    }

    @Test("Altre formulazioni: ordine delle parole, sinonimi, intervalli, unità")
    func otherPhrasings() {
        #expect(Self.interpret("minimo VMAF sotto 50").filter.maximumLowestVMAF == 50)
        #expect(Self.interpret("minimo VMAF sotto 50").filter.maximumMeanVMAF == nil)
        #expect(Self.interpret("almeno 90 di VMAF").filter.minimumMeanVMAF == 90)

        let range = Self.interpret("VMAF sopra 80 e sotto 95").filter
        #expect(range.minimumMeanVMAF == 80 && range.maximumMeanVMAF == 95)

        let exact = Self.interpret("x265 a 2000kbps").filter
        #expect(exact.codec == .hevc && exact.backend == .software)
        #expect(exact.minimumBitrateKbps == 2000 && exact.maximumBitrateKbps == 2000)

        // "H.264 e HEVC": entrambi, quindi nessun filtro sul codec.
        let both = Self.interpret("H.264 e HEVC sopra 1,5 Mb/s")
        #expect(both.isComplete && both.filter.codec == nil && both.filter.minimumBitrateKbps == 1500)

        #expect(Self.interpret("Inchiesta hardware").filter.sourceName == "Inchiesta su Selvaggia Lucarelli_720p.mp4")
        #expect(Self.interpret("tutte le codifiche") == ExperimentSearch.Interpretation())
    }

    @Test("Le parole sconosciute non vengono mai ignorate")
    func unknownWordsAreNeverIgnored() {
        // "non" cambierebbe il senso: la frase non va interpretata a metà.
        #expect(Self.interpret("codifiche non hardware").unknownWords == ["non"])
        #expect(Self.interpret("roba fatta col chip sotto i due mega").unknownWords == ["roba", "fatta", "col", "chip", "due"])
        // Un VMAF senza verso, o due video insieme, non sono interpretabili.
        #expect(Self.interpret("VMAF 90").unknownWords == ["90"])
        #expect(Self.interpret("Sintel e parkrun").unknownWords == ["sintel", "parkrun"])
    }

    @Test("La parola che identifica un video della Libreria")
    func identifyingWords() {
        #expect(ExperimentSearch.identifyingWord(of: "sintel_1080p.mov", among: Self.names) == "Sintel")
        #expect(ExperimentSearch.identifyingWord(of: "parkrun_1080p50.y4m", among: Self.names) == "Parkrun")
    }
}
