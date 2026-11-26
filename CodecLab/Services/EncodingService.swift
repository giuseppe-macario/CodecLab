// EncodingService.swift
// Codifica di un video con FFmpeg e raccolta dei metadati del file prodotto,
// compreso il QP per fotogramma riportato da libx264/libx265. Codifica della sola traccia audio.

import Foundation

/// Il risultato di una codifica video riuscita: le misure del file prodotto e, per le codifiche software,
/// il QP di ogni fotogramma.
struct EncodingServiceOutput {
    /// Il nome del file prodotto.
    let outputFileName: String
    /// Il bookmark del file prodotto.
    let outputBookmarkData: Data
    /// Le misure del file prodotto.
    let outputInfo: EncodingOutputInfo
}

/// La codifica di un video con FFmpeg, secondo le impostazioni di un esperimento.
///
/// Traduce ``EncodingSettings`` negli argomenti di FFmpeg (encoder, profilo, controllo del bitrate,
/// GOP, B-frame, audio, spezzone), esegue le due passate quando servono, scrive prima un file parziale
/// che diventa definitivo solo a codifica riuscita, e infine misura il file prodotto con FFprobe.
/// Per x264 e x265 raccoglie anche il QP di ogni fotogramma dai loro log.
struct EncodingService {

    /// Il file in cui FFmpeg scrive durante la codifica, nascosto nella stessa cartella della destinazione.
    ///
    /// Diventa il file finale solo se la codifica riesce: un errore o un annullamento
    /// non toccano quindi un eventuale risultato precedente.
    ///
    /// - Parameter outputURL: La destinazione della codifica.
    /// - Returns: Per esempio `.video.mp4.partial` accanto a `video.mp4`.
    static func partialURL(for outputURL: URL) -> URL {
        outputURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).partial")
    }

    /// Mette il file temporaneo di una codifica riuscita al posto della destinazione.
    ///
    /// - Parameters:
    ///   - partialURL: Il file temporaneo.
    ///   - outputURL: La destinazione, che viene sostituita se esiste già.
    /// - Throws: Un errore se lo spostamento non riesce.
    static func moveIntoPlace(_ partialURL: URL, to outputURL: URL) throws {
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: outputURL.path) {
            _ = try fileManager.replaceItemAt(outputURL, withItemAt: partialURL)
        } else {
            try fileManager.moveItem(at: partialURL, to: outputURL)
        }
    }

    /// Codifica il video secondo le impostazioni e misura il file prodotto.
    ///
    /// - Parameters:
    ///   - settings: Le impostazioni di codifica.
    ///   - sourceURL: Il file originale.
    ///   - outputURL: La destinazione.
    ///   - processControl: Il controllo per pausa e annullamento.
    ///   - elapsedDuration: Restituisce il tempo di lavoro trascorso, escluse le pause.
    ///   - onProgress: Chiamata con l'avanzamento (0–1), da un thread secondario.
    /// - Returns: Il nome, il bookmark e le misure del file prodotto.
    /// - Throws: ``AppError`` se l'originale non ha video, se l'audio non può essere copiato
    ///   o se FFmpeg fallisce; `CancellationError` se la codifica viene annullata.
    func encode(
        settings: EncodingSettings,
        sourceURL: URL,
        outputURL: URL,
        processControl: FFmpegProcessControl,
        elapsedDuration: () -> TimeInterval,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> EncodingServiceOutput {
        let fileManager = FileManager.default
        let partialURL = Self.partialURL(for: outputURL)

        // libx265 scrive il QP per fotogramma in un CSV; libx264 nel log di debug.
        let csvURL: URL? = settings.backend == .software && settings.codec == .hevc
            ? fileManager.temporaryDirectory.appendingPathComponent("CodecLab-\(UUID().uuidString)-qp.csv")
            : nil

        // Le statistiche della prima passata, in una cartella temporanea eliminata alla fine
        // (x264 e x265 vi scrivono più file).
        let statsDirectory: URL? = settings.usesTwoPass
            ? fileManager.temporaryDirectory.appendingPathComponent("CodecLab-\(UUID().uuidString)-2pass", isDirectory: true)
            : nil
        let statsURL = statsDirectory?.appendingPathComponent(settings.codec == .hevc ? "x265.log" : "x264")

        // Dopo una codifica riuscita il file parziale è già diventato quello finale:
        // qui si eliminano solo i resti di un errore o di un annullamento.
        defer {
            try? fileManager.removeItem(at: partialURL)

            if let csvURL {
                try? fileManager.removeItem(at: csvURL)
            }

            if let statsDirectory {
                try? fileManager.removeItem(at: statsDirectory)
            }
        }

        let sourceDocument = try await FFprobeService().probe(sourceURL)

        guard sourceDocument.videoStream != nil else {
            throw AppError("Il file non contiene una traccia video.")
        }

        try Self.checkAudioCanBeCopied(settings: settings, source: sourceDocument)

        let durationSeconds = settings.clip?.durationSeconds ?? sourceDocument.format?.durationSeconds

        // Prima passata: l'encoder analizza tutto il video e scrive le statistiche, così nella seconda
        // distribuisce i bit sapendo già dove servono. Ciascuna passata vale metà dell'avanzamento.
        if let statsDirectory, let statsURL {
            try fileManager.createDirectory(at: statsDirectory, withIntermediateDirectories: true)

            _ = try await FFmpegProcessRunner.run(
                executableURL: MediaToolPaths.ffmpeg,
                arguments: Self.arguments(
                    settings: settings,
                    sourceURL: sourceURL,
                    destinationURL: partialURL,
                    csvURL: nil,
                    twoPass: TwoPass(number: 1, statsURL: statsURL)
                ),
                durationSeconds: durationSeconds,
                processControl: processControl,
                onProgress: { onProgress($0 * 0.5) }
            )
        }

        // In due passate, la seconda occupa la seconda metà dell'avanzamento;
        // in una passata sola, tutto l'avanzamento.
        let progressStart = statsURL == nil ? 0.0 : 0.5
        let progressScale = 1 - progressStart

        let secondPassProgress: @Sendable (Double) -> Void = { fraction in
            onProgress(progressStart + fraction * progressScale)
        }

        let result = try await FFmpegProcessRunner.run(
            executableURL: MediaToolPaths.ffmpeg,
            arguments: Self.arguments(
                settings: settings,
                sourceURL: sourceURL,
                destinationURL: partialURL,
                csvURL: csvURL,
                twoPass: statsURL.map { TwoPass(number: 2, statsURL: $0) }
            ),
            durationSeconds: durationSeconds,
            processControl: processControl,
            onProgress: secondPassProgress
        )

        // Il QP si legge prima di spostare il file: stderr e CSV non dipendono dal file prodotto.
        let samples: [FrameQuantizationSample] = switch (settings.backend, settings.codec) {
        case (.software, .h264): FrameQuantizationParser.parseH264DebugLog(result.errorText)
        case (.software, .hevc): csvURL.map(FrameQuantizationParser.parseHEVCCSV(at:)) ?? []
        case (.hardware, _): []
        }

        try Self.moveIntoPlace(partialURL, to: outputURL)

        // I bitrate effettivi si leggono dal file prodotto: possono scostarsi molto dall'obiettivo.
        let document = try await FFprobeService().probe(outputURL)
        let video = document.videoStream
        let audio = document.streams.first { $0.codecType == "audio" }

        let outputInfo = EncodingOutputInfo(
            fileSizeBytes: document.format?.sizeBytes,
            durationSeconds: document.format?.durationSeconds,
            encodingDurationSeconds: elapsedDuration(),
            videoBitrateBitsPerSecond: video?.bitRateBitsPerSecond,
            audioBitrateBitsPerSecond: audio?.bitRateBitsPerSecond,
            totalBitrateBitsPerSecond: document.format?.bitRateBitsPerSecond,
            frameQuantizationSamples: samples.isEmpty ? nil : samples
        )

        return EncodingServiceOutput(
            outputFileName: outputURL.lastPathComponent,
            outputBookmarkData: try Bookmark.create(for: outputURL),
            outputInfo: outputInfo
        )
    }

    /// I codec audio che si possono copiare senza ricodifica in un file MP4.
    private static let mp4CompatibleAudioCodecs: Set = ["aac", "mp3", "alac", "ac3", "eac3"]

    /// Verifica che l'audio originale si possa copiare in un file MP4.
    ///
    /// Con «Mantieni audio originale», un codec non ammesso nell'MP4 (per esempio il PCM
    /// dei file MOV) farebbe fallire FFmpeg: meglio fermarsi subito con un messaggio chiaro.
    ///
    /// - Parameters:
    ///   - settings: Le impostazioni di codifica.
    ///   - source: Le informazioni sul file originale.
    /// - Throws: ``AppError`` se l'audio va copiato ma il suo codec non è ammesso.
    private static func checkAudioCanBeCopied(settings: EncodingSettings, source: FFprobeDocument) throws {
        guard settings.audioMode == .passthrough else { return }

        let incompatible = source.streams
            .filter { $0.codecType == "audio" }
            .compactMap(\.codecName)
            .filter { !mp4CompatibleAudioCodecs.contains($0) }

        if let codec = incompatible.first {
            throw AppError("L'audio originale (\(codec)) non può essere copiato in un file MP4. Scegli «Converti in AAC».")
        }
    }

    // MARK: - Argomenti FFmpeg

    /// Una passata di una codifica in due passate (solo encoder software, controllo a bitrate).
    struct TwoPass {
        /// 1: analizza il video e scrive le statistiche; 2: codifica usandole.
        let number: Int
        /// Il file delle statistiche: per x264 il prefisso dei suoi file, per x265 il file stesso.
        let statsURL: URL
    }

    /// Gli argomenti di FFmpeg per una codifica video.
    ///
    /// - Parameters:
    ///   - settings: Le impostazioni di codifica.
    ///   - sourceURL: Il file originale.
    ///   - destinationURL: Il file da scrivere (quello temporaneo).
    ///   - csvURL: Dove libx265 deve scrivere il QP per fotogramma; `nil` per gli altri encoder.
    ///   - twoPass: La passata, per le codifiche in due passate; `nil` per quelle in una passata.
    /// - Returns: Gli argomenti, nell'ordine richiesto da FFmpeg.
    static func arguments(
        settings: EncodingSettings,
        sourceURL: URL,
        destinationURL: URL,
        csvURL: URL?,
        twoPass: TwoPass? = nil
    ) -> [String] {
        let isFirstPass = twoPass?.number == 1

        // Il QP per fotogramma di libx264 compare solo nel log di debug (della passata che produce il file).
        // Il prefisso "level+" etichetta ogni riga con il suo livello ([debug], [error]…),
        // così in caso di errore si mostrano solo le righe rilevanti.
        let logLevel = settings.backend == .software && settings.codec == .h264 && !isFirstPass
            ? "level+debug"
            : "error"

        var arguments = [
            "-hide_banner",
            "-loglevel", logLevel,
            "-y"
        ]

        arguments += settings.clip?.inputArguments ?? []

        arguments += ["-i", sourceURL.path, "-map", "0:v:0"]    // La prima traccia video…

        // …e tutte le tracce audio, se ce ne sono; la prima passata analizza solo il video.
        if !isFirstPass {
            arguments += ["-map", "0:a?"]
        }

        arguments += [
            "-c:v", settings.codec.encoderName(using: settings.backend),
            "-g", "\(settings.gopSize)",
            "-profile:v", settings.profile.rawValue,
            "-pix_fmt", settings.pixelFormat
        ]

        switch settings.backend {
        case .software:
            switch settings.rateControlMode {
            case .bitrate:
                arguments += ["-b:v", "\(settings.videoBitrateKbps)k"]
            case .constantQuality:
                arguments += ["-crf", "\(min(max(settings.crfValue, 0), 51))"]
            case .constantQuantizer:
                arguments += ["-qp", "\(min(max(settings.quantizerValue, 0), 51))"]
            }

            arguments += ["-bf", "\(min(max(settings.bFrameCount, 0), 16))"]
            arguments += ["-preset", "medium"]

            // libx265 riceve le sue opzioni in un'unica stringa "chiave=valore:chiave=valore".
            var x265Parameters: [String] = []

            if let csvURL {
                x265Parameters += ["csv=\(csvURL.path)", "csv-log-level=1"]
            }

            if let twoPass {
                // x264 usa le opzioni generali di FFmpeg; x265 le proprie.
                if settings.codec == .hevc {
                    x265Parameters += ["pass=\(twoPass.number)", "stats=\(twoPass.statsURL.path)"]
                } else {
                    arguments += ["-pass", "\(twoPass.number)", "-passlogfile", twoPass.statsURL.path]
                }
            }

            if !x265Parameters.isEmpty {
                arguments += ["-x265-params", x265Parameters.joined(separator: ":")]
            }

        case .hardware:
            // VideoToolbox usa il controllo a bitrate e non deve ripiegare sul software.
            arguments += ["-b:v", "\(settings.videoBitrateKbps)k"]
            arguments += ["-allow_sw", "0"]
        }

        // Con l'etichetta "hvc1" i file HEVC si aprono in QuickTime e nelle app di Apple.
        if settings.codec == .hevc {
            arguments += ["-tag:v", "hvc1"]
        }

        // La prima passata non produce un file: servono solo le statistiche.
        if isFirstPass {
            return arguments + ["-an", "-progress", "pipe:1", "-nostats", "-f", "null", "-"]
        }

        switch settings.audioMode {
        case .passthrough:
            arguments += ["-c:a", "copy"]
        case .aac:
            arguments += ["-c:a", "aac", "-b:a", "\(settings.audioBitrateKbps)k"]
        }

        arguments += [
            "-map_metadata", "0",           // Mantiene i metadati dell'originale.
            "-movflags", "+faststart",      // Indice all'inizio del file: si apre senza leggerlo tutto.
            "-progress", "pipe:1",          // Avanzamento su stdout, letto da FFmpegProcessRunner.
            "-nostats",
            // Il file temporaneo non ha l'estensione .mp4: il formato va indicato.
            "-f", "mp4",
            destinationURL.path
        ]

        return arguments
    }
}

// MARK: - Codifica solo audio

/// La codifica della traccia audio di un file in AAC, in un file .m4a: è il lavoro degli Esperimenti audio.
///
/// Codifica la prima traccia audio, del file intero o di uno spezzone, con l'encoder e il bitrate scelti,
/// e misura il file prodotto.
struct AudioEncodingService {
    /// Codifica la traccia audio e misura il file prodotto.
    ///
    /// - Parameters:
    ///   - experiment: L'esperimento audio: encoder, bitrate e spezzone.
    ///   - sourceURL: Il file originale.
    ///   - outputURL: La destinazione (.m4a).
    ///   - processControl: Il controllo per pausa e annullamento.
    ///   - elapsedDuration: Restituisce il tempo di lavoro trascorso, escluse le pause.
    ///   - onProgress: Chiamata con l'avanzamento (0–1), da un thread secondario.
    /// - Returns: Il bookmark e le misure del file prodotto.
    /// - Throws: ``AppError`` se l'originale non ha audio o se FFmpeg fallisce;
    ///   `CancellationError` se la codifica viene annullata.
    func encode(
        _ experiment: AudioExperiment,
        sourceURL: URL,
        outputURL: URL,
        processControl: FFmpegProcessControl,
        elapsedDuration: () -> TimeInterval,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> (bookmark: Data, info: AudioOutputInfo) {
        let partialURL = EncodingService.partialURL(for: outputURL)

        defer {
            try? FileManager.default.removeItem(at: partialURL)
        }

        let source = try await FFprobeService().probe(sourceURL)

        guard source.hasAudio else {
            throw AppError("Il file non contiene una traccia audio.")
        }

        _ = try await FFmpegProcessRunner.run(
            executableURL: MediaToolPaths.ffmpeg,
            arguments: ["-hide_banner", "-loglevel", "error", "-y"]
                + (experiment.clip?.inputArguments ?? [])
                + [
                    "-i", sourceURL.path,
                    "-map", "0:a:0",    // Solo la prima traccia audio,
                    "-vn",              // senza video né copertina.
                    "-c:a", experiment.encoder.rawValue,
                    "-b:a", "\(experiment.bitrateKbps)k",
                    "-progress", "pipe:1",
                    "-nostats",
                    "-f", "mp4",        // Il file temporaneo non ha l'estensione .m4a: il formato va indicato.
                    partialURL.path
                ],
            durationSeconds: experiment.clip?.durationSeconds ?? source.format?.durationSeconds,
            processControl: processControl,
            onProgress: onProgress
        )

        try EncodingService.moveIntoPlace(partialURL, to: outputURL)

        let document = try await FFprobeService().probe(outputURL)
        let audio = document.streams.first { $0.codecType == "audio" }

        let info = AudioOutputInfo(
            fileName: outputURL.lastPathComponent,
            fileSizeBytes: document.format?.sizeBytes,
            bitrateBitsPerSecond: audio?.bitRateBitsPerSecond ?? document.format?.bitRateBitsPerSecond,
            durationSeconds: document.format?.durationSeconds,
            encodingDurationSeconds: elapsedDuration()
        )

        let bookmark = try Bookmark.create(for: outputURL)
        return (bookmark, info)
    }
}

// MARK: - QP per fotogramma

/// La lettura del QP di ogni fotogramma dai dati scritti dagli encoder software: il log di debug di x264
/// e il file CSV di x265.
///
/// Gli encoder elencano i fotogrammi nell'ordine in cui li codificano, che con i B-frame non è quello
/// in cui si vedono: il lettore li riporta nell'ordine di visualizzazione, per allinearli al VMAF.
enum FrameQuantizationParser {

    /// Mette i fotogrammi nell'ordine in cui vengono mostrati e ne numera la posizione.
    ///
    /// Il POC riparte da zero a ogni IDR (con x264, a ogni GOP chiuso): i fotogrammi vengono
    /// quindi divisi in gruppi seguendo l'ordine di codifica e ordinati per POC dentro ogni gruppo.
    ///
    /// - Parameter samples: I campioni, in qualsiasi ordine.
    /// - Returns: I campioni in ordine di visualizzazione, con ``FrameQuantizationSample/displayOrder`` impostato.
    static func inDisplayOrder(_ samples: [FrameQuantizationSample]) -> [FrameQuantizationSample] {
        var groups: [[FrameQuantizationSample]] = []

        for sample in samples.sorted(by: { $0.encodeOrder < $1.encodeOrder }) {
            if groups.isEmpty || (sample.frameType == "I" && sample.pictureOrderCount == 0) {
                groups.append([])
            }
            groups[groups.count - 1].append(sample)
        }

        let ordered = groups.flatMap { $0.sorted { $0.pictureOrderCount < $1.pictureOrderCount } }

        return ordered.enumerated().map { position, sample in
            var sample = sample
            sample.displayOrder = position
            return sample
        }
    }

    /// Legge il QP dal log di debug di libx264.
    ///
    /// Le righe utili sono del tipo `frame=   3 QP=24.00 NAL=2 Slice:B Poc:4 …`; le altre vengono ignorate.
    ///
    /// - Parameter log: Il contenuto di stderr della codifica.
    /// - Returns: I campioni, in ordine di visualizzazione.
    static func parseH264DebugLog(_ log: String) -> [FrameQuantizationSample] {
        let pattern = #/frame=\s*(?<order>\d+)\s+QP=\s*(?<qp>\d+(?:\.\d+)?)\s+.*?Slice:(?<type>[IPB])\s+Poc:\s*(?<poc>-?\d+)/#

        let samples = log.split(whereSeparator: \.isNewline).compactMap { line -> FrameQuantizationSample? in
            guard
                let match = line.firstMatch(of: pattern),
                let encodeOrder = Int(match.order),
                let qp = Double(match.qp),
                let poc = Int(match.poc)
            else {
                return nil
            }

            return FrameQuantizationSample(
                encodeOrder: encodeOrder,
                pictureOrderCount: poc,
                frameType: String(match.type),
                qp: qp
            )
        }

        return inDisplayOrder(samples)
    }

    /// Legge il QP dal file CSV di libx265, con le colonne "Encode Order", "Type", "POC" e "QP".
    ///
    /// - Parameter url: Il file CSV.
    /// - Returns: I campioni, in ordine di visualizzazione; un elenco vuoto se il file
    ///   non è leggibile o non ha le colonne attese.
    static func parseHEVCCSV(at url: URL) -> [FrameQuantizationSample] {
        guard let csv = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }

        let lines = csv.split(whereSeparator: \.isNewline)

        func fields(_ line: Substring) -> [String] {
            line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }

        let headers = lines.first.map(fields) ?? []

        guard
            let orderIndex = headers.firstIndex(of: "Encode Order"),
            let typeIndex = headers.firstIndex(of: "Type"),
            let pocIndex = headers.firstIndex(of: "POC"),
            let qpIndex = headers.firstIndex(of: "QP")
        else {
            return []
        }

        let requiredIndex = max(orderIndex, typeIndex, pocIndex, qpIndex)
        var samples: [FrameQuantizationSample] = []

        for line in lines.dropFirst() {
            let values = fields(line)

            guard
                values.count > requiredIndex,
                let encodeOrder = Int(values[orderIndex]),
                let poc = Int(values[pocIndex]),
                let qp = Double(values[qpIndex]),
                qp.isFinite,
                let firstType = values[typeIndex].first
            else {
                continue
            }

            let frameType = String(firstType).uppercased()

            guard ["I", "P", "B"].contains(frameType) else {
                continue
            }

            samples.append(
                FrameQuantizationSample(
                    encodeOrder: encodeOrder,
                    pictureOrderCount: poc,
                    frameType: frameType,
                    qp: qp
                )
            )
        }

        return inDisplayOrder(samples)
    }
}
