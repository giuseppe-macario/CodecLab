// MediaTools.swift
// Tutto ciò che serve per usare FFmpeg e FFprobe: percorsi, verifica degli strumenti,
// esecuzione dei processi con avanzamento, pausa e annullamento.

import Foundation

/// Un errore con un messaggio già pronto da mostrare all'utente, in italiano e senza dettagli tecnici superflui.
nonisolated struct AppError: LocalizedError {
    /// Il messaggio dell'errore.
    let errorDescription: String?

    /// Crea un errore con il messaggio indicato.
    ///
    /// - Parameter message: Il testo mostrato all'utente.
    init(_ message: String) {
        errorDescription = message
    }
}

/// Dove CodecLab cerca FFmpeg e FFprobe: nella cartella in cui li installa Homebrew sui Mac con chip Apple,
/// `/opt/homebrew/bin`.
nonisolated enum MediaToolPaths {
    /// Il percorso di `ffmpeg`.
    static let ffmpeg = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
    /// Il percorso di `ffprobe`.
    static let ffprobe = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
}

// MARK: - Verifica degli strumenti

/// Il risultato della verifica degli strumenti, mostrato nella sezione Sistema: le versioni di FFmpeg
/// e FFprobe, la disponibilità degli encoder hardware, di libvmaf e dell'AAC di Apple,
/// con le informazioni su ciascuno.
struct MediaToolStatus: Sendable {
    /// La prima riga di `ffmpeg -version`.
    let ffmpegVersion: String
    /// La prima riga di `ffprobe -version`.
    let ffprobeVersion: String
    /// Vero se VideoToolbox codifica in H.264 su questo Mac.
    let isH264HardwareEncoderAvailable: Bool
    /// Vero se VideoToolbox codifica in HEVC su questo Mac.
    let isHEVCHardwareEncoderAvailable: Bool
    /// Vero se FFmpeg include libvmaf, necessaria per l'analisi qualità.
    let isLibVMAFAvailable: Bool
    /// Vero se FFmpeg include l'encoder AAC di AudioToolbox (`aac_at`).
    let isAppleAACAvailable: Bool

    /// Le informazioni mostrate sotto ogni voce in Sistema, come la versione per FFmpeg:
    /// nome e descrizione dell'encoder secondo FFmpeg, versione di libvmaf e modello usato.
    var h264EncoderDetail: String? = nil
    var hevcEncoderDetail: String? = nil
    var libVMAFDetail: String? = nil
    var appleAACDetail: String? = nil
}

/// La verifica, all'avvio, che sul Mac ci sia tutto ciò che serve a CodecLab.
///
/// Controlla che FFmpeg e FFprobe esistano e ne legge le versioni, prova a codificare un fotogramma
/// con gli encoder hardware (sono sempre elencati, ma funzionano solo se il chip li supporta)
/// e cerca libvmaf e l'encoder AAC di Apple negli elenchi di FFmpeg. Il risultato compare in Sistema
/// e, se manca qualcosa di essenziale, in un avviso in cima a ogni sezione.
struct MediaToolService {
    /// Verifica gli strumenti: versioni, encoder hardware, libvmaf e AAC di AudioToolbox.
    ///
    /// - Returns: Lo stato di ciascun componente.
    /// - Throws: ``AppError`` se FFmpeg o FFprobe mancano o non si avviano.
    func check() async throws -> MediaToolStatus {
        for url in [MediaToolPaths.ffmpeg, MediaToolPaths.ffprobe] {
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw AppError("\(url.lastPathComponent) non è disponibile in \(url.path). Verifica l'installazione Homebrew.")
            }
        }

        // Le due versioni vengono lette in parallelo.
        async let ffmpeg = versionLine(at: MediaToolPaths.ffmpeg)
        async let ffprobe = versionLine(at: MediaToolPaths.ffprobe)

        let ffmpegVersion = try await ffmpeg
        let ffprobeVersion = try await ffprobe

        // Gli encoder di VideoToolbox sono sempre elencati da FFmpeg, ma funzionano solo se
        // il chip li supporta: vanno provati. Per libvmaf e aac_at basta l'elenco.
        let h264Available = await testHardwareEncoder(named: "h264_videotoolbox")
        let hevcAvailable = await testHardwareEncoder(named: "hevc_videotoolbox")
        // Gli elenchi di encoder e filtri, letti una volta sola: servono sia a sapere se un
        // componente c'è, sia a mostrarne la descrizione.
        let encoders = await listing(by: "-encoders")
        let filters = await listing(by: "-filters")

        let libVMAFAvailable = Self.description(of: "libvmaf", in: filters) != nil
        let appleAACAvailable = Self.description(of: "aac_at", in: encoders) != nil

        // libvmaf non dichiara la sua versione a FFmpeg: la si legge dalla cartella di Homebrew.
        let libVMAFDetail = libVMAFAvailable
            ? [Self.homebrewVersion(of: "libvmaf").map { "libvmaf \($0)" } ?? "Filtro libvmaf di FFmpeg",
               "modello vmaf_v0.6.1"].joined(separator: " · ")
            : nil

        return MediaToolStatus(
            ffmpegVersion: ffmpegVersion,
            ffprobeVersion: ffprobeVersion,
            isH264HardwareEncoderAvailable: h264Available,
            isHEVCHardwareEncoderAvailable: hevcAvailable,
            isLibVMAFAvailable: libVMAFAvailable,
            isAppleAACAvailable: appleAACAvailable,
            h264EncoderDetail: Self.description(of: "h264_videotoolbox", in: encoders).map { "h264_videotoolbox · \($0)" },
            hevcEncoderDetail: Self.description(of: "hevc_videotoolbox", in: encoders).map { "hevc_videotoolbox · \($0)" },
            libVMAFDetail: libVMAFDetail,
            appleAACDetail: Self.description(of: "aac_at", in: encoders).map { "aac_at · \($0)" }
        )
    }

    /// Le righe di un elenco di FFmpeg (`-encoders` o `-filters`); vuoto se FFmpeg non risponde.
    private func listing(by listOption: String) async -> [Substring] {
        let result = try? await FFmpegProcessRunner.run(
            executableURL: MediaToolPaths.ffmpeg,
            arguments: ["-hide_banner", listOption]
        )

        return result?.outputText.split(whereSeparator: \.isNewline) ?? []
    }

    /// La descrizione di un componente in un elenco di FFmpeg; `nil` se il componente non c'è.
    ///
    /// Le righe sono del tipo " V....D h264_videotoolbox   VideoToolbox H.264 Encoder (codec h264)"
    /// oppure " ... libvmaf   VV->V   Calculate the VMAF between two video streams.": il nome è la
    /// seconda parola; nei filtri, dopo il nome, c'è anche il tipo di ingressi e uscite ("VV->V").
    ///
    /// - Parameters:
    ///   - name: Il nome del componente, per esempio `libvmaf` o `aac_at`.
    ///   - lines: Le righe dell'elenco.
    static func description(of name: String, in lines: [Substring]) -> String? {
        for line in lines {
            let words = line.split(separator: " ")
            guard words.dropFirst().first == Substring(name) else { continue }

            var rest = words.dropFirst(2)
            if let first = rest.first, first.contains("->") { rest = rest.dropFirst() }
            return rest.joined(separator: " ")
        }

        return nil
    }

    /// La versione di un pacchetto Homebrew, dal nome della sua cartella in /opt/homebrew/Cellar
    /// (la più recente, se ce n'è più d'una); `nil` se il pacchetto non è installato così.
    static func homebrewVersion(of package: String) -> String? {
        let folder = "/opt/homebrew/Cellar/\(package)"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: folder))?.filter { !$0.hasPrefix(".") } ?? []
        return versions.max { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    /// Codifica un fotogramma di prova, senza ripiego software.
    ///
    /// - Parameter encoderName: L'encoder di VideoToolbox, per esempio `h264_videotoolbox`.
    /// - Returns: Vero se la codifica riesce, cioè se l'encoder hardware è disponibile.
    private func testHardwareEncoder(named encoderName: String) async -> Bool {
        let result = try? await FFmpegProcessRunner.run(
            executableURL: MediaToolPaths.ffmpeg,
            arguments: [
                "-hide_banner",
                "-loglevel", "error",
                "-f", "lavfi",
                "-i", "color=c=black:s=640x360:r=30:d=0.1",
                "-frames:v", "1",
                "-an",
                "-c:v", encoderName,
                "-allow_sw", "0",       // Senza ripiego software: deve rispondere il chip.
                "-f", "null",
                "-"
            ]
        )

        return result != nil
    }

    /// La prima riga dell'output di `-version`, per esempio "ffmpeg version 8.0 Copyright…".
    ///
    /// - Parameter executableURL: Il programma da interrogare.
    /// - Returns: La riga con la versione.
    /// - Throws: Un errore se il programma non si avvia o termina con un errore.
    private func versionLine(at executableURL: URL) async throws -> String {
        let result = try await FFmpegProcessRunner.run(
            executableURL: executableURL,
            arguments: ["-hide_banner", "-loglevel", "error", "-version"]
        )

        return result.outputText
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? "Versione non rilevata"
    }
}

// MARK: - Esecuzione dei processi

/// Ciò che un processo terminato ha scritto (output e messaggi di errore) e il suo codice di uscita.
struct ProcessExecutionResult: Sendable {
    /// Il codice di uscita: 0 se il processo è terminato senza errori.
    let exitCode: Int32
    /// Quanto scritto su stdout.
    let standardOutput: Data
    /// Quanto scritto su stderr.
    let standardError: Data

    /// stdout come testo.
    var outputText: String {
        String(decoding: standardOutput, as: UTF8.self)
    }

    /// stderr come testo.
    var errorText: String {
        String(decoding: standardError, as: UTF8.self)
    }

    /// Le ultime righe utili di stderr, senza i messaggi di debug (che possono essere migliaia).
    var errorSummary: String {
        // Le etichette di livello ci sono solo con `-loglevel level+…` (la codifica x264);
        // negli altri casi FFmpeg scrive solo gli errori e il filtro non toglie nulla.
        let noise = ["[debug]", "[trace]", "[verbose]", "[info]"]

        return errorText
            .split(whereSeparator: \.isNewline)
            .filter { line in !noise.contains { line.contains($0) } }
            .suffix(20)
            .joined(separator: "\n")
    }
}

/// L'esecuzione di FFmpeg e FFprobe come processi separati, con avanzamento, pausa e annullamento.
///
/// Tutti i lavori di CodecLab passano da qui. L'avanzamento viene letto dalle righe che FFmpeg scrive
/// con l'opzione `-progress`; la pausa sospende il processo, e l'annullamento lo termina.
enum FFmpegProcessRunner {

    /// Esegue un programma e ne raccoglie l'output, fuori dal thread principale.
    ///
    /// stderr viene scritto su un file temporaneo, perché una pipe piena bloccherebbe FFmpeg.
    /// Se il task viene annullato, il processo viene terminato.
    ///
    /// - Parameters:
    ///   - executableURL: Il programma da eseguire.
    ///   - arguments: Gli argomenti.
    ///   - durationSeconds: La durata del video in lavorazione, per calcolare l'avanzamento.
    ///   - processControl: Il controllo che permette di sospendere, riprendere e terminare il processo.
    ///   - onProgress: Chiamata con l'avanzamento (0–1), da un thread secondario. Richiede
    ///     l'opzione `-progress pipe:1` e una durata.
    /// - Returns: L'output del processo.
    /// - Throws: ``AppError`` con le ultime righe utili di stderr se il processo termina
    ///   con un codice diverso da zero; `CancellationError` se il task è stato annullato.
    static func run(
        executableURL: URL,
        arguments: [String],
        durationSeconds: Double? = nil,
        processControl: FFmpegProcessControl? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> ProcessExecutionResult {

        let control = processControl ?? FFmpegProcessControl()

        let result = try await withTaskCancellationHandler {
            // Il processo viene seguito su un thread secondario: `waitUntilExit()` è bloccante.
            try await Task.detached(priority: .utility) {

                let fileManager = FileManager.default

                // stderr va su file: una pipe piena bloccherebbe FFmpeg.
                let stderrURL = fileManager.temporaryDirectory
                    .appendingPathComponent("CodecLab-\(UUID().uuidString)-stderr.tmp")

                guard fileManager.createFile(atPath: stderrURL.path, contents: Data()) else {
                    throw AppError("Impossibile creare i file temporanei per acquisire l'output del processo.")
                }

                defer {
                    try? fileManager.removeItem(at: stderrURL)
                }

                let stderrHandle = try FileHandle(forWritingTo: stderrURL)

                defer {
                    try? stderrHandle.close()
                }

                let stdoutPipe = Pipe()
                let stdoutReader = stdoutPipe.fileHandleForReading
                let stdoutWriter = stdoutPipe.fileHandleForWriting

                let output = ProcessOutputCollector(
                    durationSeconds: durationSeconds,
                    onProgress: onProgress
                )

                // stdout viene letto man mano che arriva: contiene le righe di `-progress`
                // (o il JSON di FFprobe). Un blocco vuoto indica la fine del flusso.
                let readerFinished = Task {
                    await withCheckedContinuation { continuation in
                        stdoutReader.readabilityHandler = { handle in
                            let data = handle.availableData

                            if data.isEmpty {
                                handle.readabilityHandler = nil
                                continuation.resume()
                            } else {
                                output.append(data)
                            }
                        }
                    }
                }

                // Comunque vada, alla fine si smette di leggere e si chiude la pipe.
                defer {
                    stdoutReader.readabilityHandler = nil
                    try? stdoutReader.close()
                    try? stdoutWriter.close()
                }

                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments
                process.standardOutput = stdoutWriter
                process.standardError = stderrHandle

                do {
                    try process.run()
                } catch {
                    // Il processo non è partito: chiudendo la pipe, il lettore riceve la fine
                    // del flusso e termina.
                    try? stdoutWriter.close()
                    await readerFinished.value
                    control.clear(process)
                    throw error
                }

                control.install(process)

                // Il processo ha una sua copia dell'estremità di scrittura: chiudendo la nostra,
                // la fine del flusso arriva quando FFmpeg termina.
                try? stdoutWriter.close()

                process.waitUntilExit()

                // Si aspetta anche la fine della lettura, per non perdere le ultime righe.
                await readerFinished.value

                control.clear(process)

                // I dati di stderr devono essere su disco prima di rileggere il file.
                try stderrHandle.synchronize()

                return ProcessExecutionResult(
                    exitCode: process.terminationStatus,
                    standardOutput: output.data,
                    standardError: try Data(contentsOf: stderrURL)
                )

            }.value

        } onCancel: {
            control.cancel()
        }

        // Un processo terminato dall'annullamento esce con un errore: va trattato
        // come annullamento, non mostrato all'utente.
        try Task.checkCancellation()

        guard result.exitCode == 0 else {
            let details = result.errorSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = executableURL.lastPathComponent

            throw AppError(
                details.isEmpty
                    ? "\(name) è terminato con codice \(result.exitCode)."
                    : "\(name) è terminato con codice \(result.exitCode):\n\(details)"
            )
        }

        return result
    }
}

// MARK: - Lettura avanzamento FFmpeg

/// Raccoglie stdout e ne ricava l'avanzamento dalle righe di `-progress pipe:1` di FFmpeg.
///
/// I dati arrivano da un thread secondario: l'accesso è protetto da un lock.
private nonisolated final class ProcessOutputCollector: @unchecked Sendable {

    private let lock = NSLock()

    private let durationSeconds: Double?
    private let onProgress: (@Sendable (Double) -> Void)?

    private var collectedData = Data()
    /// L'ultima riga ricevuta, non ancora completa.
    private var pendingText = ""

    /// Crea un raccoglitore.
    ///
    /// - Parameters:
    ///   - durationSeconds: La durata del video, per calcolare l'avanzamento.
    ///   - onProgress: Chiamata con l'avanzamento (0–1).
    init(
        durationSeconds: Double?,
        onProgress: (@Sendable (Double) -> Void)?
    ) {
        self.durationSeconds = durationSeconds
        self.onProgress = onProgress
    }

    /// Tutti i dati raccolti finora.
    var data: Data {
        lock.lock()
        defer { lock.unlock() }

        return collectedData
    }

    /// Aggiunge i dati ricevuti e comunica l'avanzamento contenuto nelle righe complete.
    ///
    /// - Parameter data: I nuovi dati letti da stdout.
    func append(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        var progressUpdates: [Double] = []

        lock.lock()

        // Una riga può arrivare spezzata in due blocchi: la parte incompleta
        // resta in `pendingText` fino al blocco successivo.
        collectedData.append(data)
        pendingText += text

        while let newline = pendingText.firstIndex(of: "\n") {
            let line = String(pendingText[..<newline])
            pendingText = String(pendingText[pendingText.index(after: newline)...])

            if let progress = progressValue(from: line) {
                progressUpdates.append(progress)
            }
        }

        lock.unlock()

        // Fuori dal lock: chi riceve l'avanzamento non deve poter bloccare la lettura.
        for progress in progressUpdates {
            onProgress?(progress)
        }
    }

    /// Ricava l'avanzamento da una riga di `-progress`.
    ///
    /// - Parameter line: Una riga come `out_time_us=12000000` o `progress=end`.
    /// - Returns: L'avanzamento (0–1), o `nil` se la riga non lo indica.
    private func progressValue(from line: String) -> Double? {
        guard
            let separator = line.firstIndex(of: "="),
            let durationSeconds,
            durationSeconds.isFinite,
            durationSeconds > 0
        else {
            return nil
        }

        let key = String(line[..<separator])
        let value = String(line[line.index(after: separator)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if key == "progress", value == "end" {
            return 1
        }

        guard key == "out_time_us", let microseconds = Double(value)
        else {
            return nil
        }

        // Al massimo 99,9%: il 100% arriva con "progress=end", quando FFmpeg ha davvero finito.
        return min(max(microseconds / 1_000_000 / durationSeconds, 0), 0.999)
    }
}

// MARK: - Controllo del processo

/// Il telecomando del processo FFmpeg in esecuzione: permette di sospenderlo, riprenderlo e terminarlo.
///
/// I comandi ricevuti prima che il processo parta vengono applicati appena parte. Viene usato sia
/// dall'interfaccia sia dal thread che esegue il processo: l'accesso è protetto da un lock.
nonisolated final class FFmpegProcessControl: @unchecked Sendable {

    private let lock = NSLock()

    private var process: Process?
    /// Pausa richiesta dall'utente (anche prima che il processo parta).
    private var isPaused = false
    /// Vero se il processo è stato davvero sospeso.
    private var isSuspended = false
    private var isCancelled = false

    /// Collega il processo appena avviato, applicando una pausa o un annullamento già richiesti.
    ///
    /// - Parameter process: Il processo avviato.
    func install(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }

        self.process = process

        if isCancelled {
            process.terminate()
        } else if isPaused, process.isRunning {
            isSuspended = process.suspend()
        }
    }

    /// Scollega il processo terminato.
    ///
    /// - Parameter process: Il processo terminato; se nel frattempo ne è stato collegato un altro, non succede nulla.
    func clear(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }

        if self.process === process {
            self.process = nil
            isSuspended = false
            isPaused = false
        }
    }

    /// Sospende il processo (segnale SIGSTOP).
    func pause() {
        lock.lock()
        defer { lock.unlock() }

        guard !isCancelled, !isPaused else { return }
        isPaused = true

        // Se il processo non è ancora partito, la pausa viene applicata da `install(_:)`.
        if let process, process.isRunning {
            isSuspended = process.suspend()
        }
    }

    /// Riprende il processo sospeso (segnale SIGCONT).
    func resume() {
        lock.lock()
        defer { lock.unlock() }

        guard isPaused else { return }
        isPaused = false

        if isSuspended, let process, process.isRunning {
            _ = process.resume()
        }

        isSuspended = false
    }

    /// Termina il processo e impedisce che un processo collegato in seguito venga eseguito.
    func cancel() {
        lock.lock()
        defer { lock.unlock() }

        isCancelled = true

        if let process, process.isRunning {
            // Un processo sospeso non riceverebbe il segnale di terminazione.
            if isSuspended {
                _ = process.resume()
                isSuspended = false
            }

            process.terminate()
        }
    }
}
