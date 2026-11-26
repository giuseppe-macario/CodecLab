// QualityAnalysisService.swift
// Confronta il video codificato con l'originale: conteggio dei fotogrammi,
// distribuzione I/P/B e metriche VMAF, PSNR e SSIM calcolate da libvmaf.

import Foundation

/// L'analisi della qualità: il confronto del video codificato con l'originale, fotogramma per fotogramma.
///
/// Conta i fotogrammi dei due video, legge i tipi e le dimensioni dei fotogrammi codificati e calcola
/// con libvmaf le tre metriche: VMAF, PSNR della luminanza e SSIM. Il VMAF usa un modello pensato
/// per il 1080p: per questo i video più piccoli vengono ingranditi a 1080p prima di calcolarlo.
/// Estrae anche i singoli fotogrammi per il confronto visivo.
struct QualityAnalysisService {

    /// Analizza la qualità di un esperimento codificato.
    ///
    /// Se il lato corto del video è inferiore a 1080 punti, il VMAF viene calcolato dopo
    /// aver ingrandito entrambi i video a 1080p, come raccomandato per il modello vmaf_v0.6.1;
    /// PSNR e SSIM restano alla risoluzione originale.
    ///
    /// - Parameters:
    ///   - experiment: L'esperimento da analizzare.
    ///   - sourceURL: Il file originale.
    ///   - outputURL: Il file codificato.
    ///   - processControl: Il controllo per pausa e annullamento.
    ///   - elapsedDuration: Restituisce il tempo di lavoro trascorso, escluse le pause.
    ///   - onStage: Chiamata all'inizio di ogni fase, con la descrizione da mostrare.
    ///   - onVMAFStarted: Chiamata all'inizio del calcolo VMAF, il passaggio più lungo;
    ///     indica se l'avanzamento sarà misurabile.
    ///   - onProgress: Chiamata con l'avanzamento del calcolo VMAF (0–1), da un thread secondario.
    /// - Returns: Il risultato dell'analisi, da salvare.
    /// - Throws: ``AppError`` se un file non ha video o se FFmpeg fallisce;
    ///   `CancellationError` se l'analisi viene annullata.
    func analyze(
        experiment: EncodingExperiment,
        sourceURL: URL,
        outputURL: URL,
        processControl: FFmpegProcessControl,
        elapsedDuration: () -> TimeInterval,
        onStage: (String) -> Void,
        onVMAFStarted: (_ isProgressDeterminate: Bool) -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> VideoQualityAnalysisResult {
        onStage("Lettura delle informazioni video…")

        let probeService = FFprobeService()
        let sourceDocument = try await probeService.probe(sourceURL)
        let outputDocument = try await probeService.probe(outputURL)

        guard let sourceVideo = sourceDocument.videoStream,
              let outputVideo = outputDocument.videoStream else {
            throw AppError("Impossibile trovare la traccia video originale o codificata.")
        }

        let clip = experiment.settings.clip

        // Con uno spezzone, i fotogrammi del file originale intero non sono un termine di confronto.
        var originalFrameCount: Int?

        if clip == nil {
            onStage("Conteggio dei fotogrammi originali…")
            originalFrameCount = Int(sourceVideo.frameCount ?? "")

            // Non tutti i contenitori dichiarano il numero di fotogrammi: allora si contano (lento).
            if originalFrameCount == nil {
                originalFrameCount = try await probeService.countVideoFrames(sourceURL)
            }
        }

        onStage("Rilevamento fotogrammi I/P/B…")
        // Facoltative: se non riescono, l'analisi prosegue senza tipi e dimensioni dei fotogrammi.
        // `try?` però nasconderebbe anche l'annullamento, che quindi si controlla subito dopo.
        let frameTypes = try? await probeService.frameTypes(outputURL)
        try Task.checkCancellation()

        let frameTypeSummary = frameTypes.map(VideoFrameTypeSummary.init(frameTypes:))

        onStage("Lettura delle dimensioni dei fotogrammi…")
        let frameSizes = try? await probeService.frameSizes(outputURL)
        try Task.checkCancellation()

        var outputFrameCount = Int(outputVideo.frameCount ?? "")

        // Se il contenitore non lo dichiara, il conteggio della scansione I/P/B evita
        // una seconda decodifica completa.
        if outputFrameCount == nil || outputFrameCount == 0,
           let total = frameTypeSummary?.totalFrames, total > 0 {
            outputFrameCount = total
        }

        if outputFrameCount == nil {
            outputFrameCount = try await probeService.countVideoFrames(outputURL)
        }

        onStage("Analisi VMAF, PSNR e SSIM…")
        let duration = clip?.durationSeconds ?? sourceDocument.format?.durationSeconds
        // Senza durata non si può calcolare la percentuale: la barra resta indeterminata.
        onVMAFStarted(duration.map { $0.isFinite && $0 > 0 } ?? false)

        // Il modello VMAF è tarato per video 1080p: i video più piccoli vanno ingranditi prima.
        let shorterSide = min(outputVideo.width ?? 1920, outputVideo.height ?? 1080)
        let upscale = shorterSide < 1080

        let report = try await Self.runVMAF(
            referenceURL: sourceURL,
            referenceClip: clip,
            distortedURL: outputURL,
            pixelFormat: experiment.settings.analysisPixelFormat,
            upscaleScale: upscale ? Self.upscaleFilter(width: outputVideo.width, height: outputVideo.height) : nil,
            durationSeconds: duration,
            processControl: processControl,
            onProgress: onProgress
        )

        return VideoQualityAnalysisResult(
            experiment: experiment,
            report: report,
            originalFrameCount: originalFrameCount,
            outputFrameCount: outputFrameCount,
            analysisDurationSeconds: elapsedDuration(),
            outputFileSizeBytes: outputDocument.format?.sizeBytes
                ?? experiment.outputInfo?.fileSizeBytes,
            videoBitrateBitsPerSecond: outputVideo.bitRateBitsPerSecond
                ?? experiment.outputInfo?.videoBitrateBitsPerSecond,
            frameTypeSummary: (frameTypeSummary?.totalFrames ?? 0) > 0 ? frameTypeSummary : nil,
            frameQuantizationSamples: experiment.outputInfo?.frameQuantizationSamples,
            vmafAt1080p: upscale,
            frameSizes: frameSizes.flatMap { $0.isEmpty ? nil : $0 },
            frameTypes: frameTypes.flatMap { $0.isEmpty ? nil : $0.joined() },
            framesPerSecond: outputVideo.frameRate
        )
    }

    // MARK: - VMAF

    /// Il filtro che porta il lato corto a 1080 punti, mantenendo le proporzioni
    /// (anche per i video verticali). Bicubico, come raccomandato per il VMAF.
    ///
    /// - Parameters:
    ///   - width: La larghezza del video.
    ///   - height: L'altezza del video.
    /// - Returns: Il filtro `scale` di FFmpeg.
    static func upscaleFilter(width: Int?, height: Int?) -> String {
        (width ?? 0) >= (height ?? 0)
            ? "scale=-2:1080:flags=bicubic"
            : "scale=1080:-2:flags=bicubic"
    }

    /// Esegue libvmaf e legge i rapporti JSON prodotti.
    ///
    /// - Senza ingrandimento: un solo calcolo, con VMAF, PSNR e SSIM.
    /// - Con ingrandimento: i due video vengono sdoppiati nello stesso passaggio;
    ///   una copia ingrandita serve per il VMAF, l'altra (originale) per PSNR e SSIM.
    ///
    /// - Parameters:
    ///   - referenceURL: Il file originale.
    ///   - referenceClip: Lo spezzone dell'originale da confrontare; `nil` per il file intero.
    ///   - distortedURL: Il file codificato.
    ///   - pixelFormat: Il formato dei pixel in cui confrontare i due video.
    ///   - upscaleScale: Il filtro di ingrandimento; `nil` per confrontare i video così come sono.
    ///   - durationSeconds: La durata da analizzare, per l'avanzamento.
    ///   - processControl: Il controllo per pausa e annullamento.
    ///   - onProgress: Chiamata con l'avanzamento (0–1).
    /// - Returns: Il rapporto, con il VMAF dal calcolo ingrandito se c'è.
    /// - Throws: ``AppError`` se FFmpeg fallisce o non produce un rapporto valido.
    private static func runVMAF(
        referenceURL: URL,
        referenceClip: ClipRange?,
        distortedURL: URL,
        pixelFormat: String,
        upscaleScale: String?,
        durationSeconds: Double?,
        processControl: FFmpegProcessControl,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> VMAFReport {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let vmafReportURL = temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        let nativeReportURL = temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")

        defer {
            try? FileManager.default.removeItem(at: vmafReportURL)
            try? FileManager.default.removeItem(at: nativeReportURL)
        }

        // Lascia un processore libero per il sistema.
        let threadCount = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        let model = "model=version=vmaf_v0.6.1:n_threads=\(threadCount)"

        // Entrambi i video vengono portati allo stesso formato dei pixel (libvmaf lo richiede)
        // e ripartono da zero, così i fotogrammi vengono confrontati in ordine.
        let prepare = "format=\(pixelFormat),settb=AVTB,setpts=PTS-STARTPTS"

        let filter: String
        let outputs: [String]

        // Nel grafo dei filtri l'ingresso 0 è il video codificato e l'1 l'originale: libvmaf vuole
        // prima il video da valutare ("distorted") e poi quello di riferimento.
        if let upscaleScale {
            // Ogni video viene sdoppiato: una copia ingrandita per il VMAF, l'altra intatta
            // per PSNR e SSIM. Due uscite nulle, perché interessano solo i rapporti JSON.
            filter = """
            [0:v]\(prepare),split=2[dist][distNative];\
            [1:v]\(prepare),split=2[ref][refNative];\
            [dist]\(upscaleScale)[distHD];\
            [ref]\(upscaleScale)[refHD];\
            [distHD][refHD]libvmaf=log_fmt=json:log_path=\(vmafReportURL.path):\(model)[vmafOut];\
            [distNative][refNative]libvmaf=log_fmt=json:log_path=\(nativeReportURL.path):\(model):feature=name=psnr|name=float_ssim[nativeOut]
            """
            outputs = ["-map", "[vmafOut]", "-f", "null", "-", "-map", "[nativeOut]", "-f", "null", "-"]
        } else {
            // Un solo calcolo: VMAF, PSNR e SSIM sulle immagini così come sono.
            filter = """
            [0:v]\(prepare)[dist];\
            [1:v]\(prepare)[ref];\
            [dist][ref]libvmaf=log_fmt=json:log_path=\(vmafReportURL.path):\(model):feature=name=psnr|name=float_ssim
            """
            outputs = ["-an", "-f", "null", "-"]    // Nessun file prodotto: interessa solo il rapporto.
        }

        _ = try await FFmpegProcessRunner.run(
            executableURL: MediaToolPaths.ffmpeg,
            arguments: [
                "-hide_banner",
                "-loglevel", "error",
                "-i", distortedURL.path
            ]
            // Se la codifica usa uno spezzone, l'originale va letto dallo stesso punto.
            + (referenceClip?.inputArguments ?? [])
            + [
                "-i", referenceURL.path,
                "-lavfi", filter,
                "-progress", "pipe:1",
                "-nostats"
            ]
            + outputs,
            durationSeconds: durationSeconds,
            processControl: processControl,
            onProgress: onProgress
        )

        let vmafReport = try readReport(at: vmafReportURL)

        guard upscaleScale != nil else {
            return vmafReport
        }

        // VMAF (per fotogramma e media) dal calcolo a 1080p, PSNR e SSIM da quello originale.
        let nativeReport = try readReport(at: nativeReportURL)

        return VMAFReport(
            comparedFrameCount: vmafReport.comparedFrameCount,
            vmafPerFrame: vmafReport.vmafPerFrame,
            pooledMetrics: QualityMetricSummary(
                vmaf: vmafReport.pooledMetrics.vmaf,
                psnrY: nativeReport.pooledMetrics.psnrY,
                ssim: nativeReport.pooledMetrics.ssim
            )
        )
    }

    /// Legge un rapporto JSON di libvmaf.
    ///
    /// - Parameter url: Il file del rapporto.
    /// - Returns: Il rapporto.
    /// - Throws: ``AppError`` se il file manca o non è valido.
    private static func readReport(at url: URL) throws -> VMAFReport {
        guard let data = try? Data(contentsOf: url) else {
            throw AppError("FFmpeg non ha prodotto il rapporto dell'analisi.")
        }

        do {
            return try JSONDecoder().decode(VMAFReport.self, from: data)
        } catch {
            throw AppError("Rapporto VMAF non valido: \(error.localizedDescription)")
        }
    }

    // MARK: - Confronto visivo

    /// Estrae un fotogramma come immagine PNG.
    ///
    /// - Parameters:
    ///   - url: Il file video.
    ///   - index: Il numero del fotogramma, contato dall'inizio del video o dello spezzone, come in libvmaf.
    ///   - clip: Lo spezzone da cui contare; `nil` per il file intero.
    /// - Returns: I dati dell'immagine PNG.
    /// - Throws: ``AppError`` se FFmpeg non restituisce il fotogramma.
    static func extractFrame(from url: URL, index: Int, clip: ClipRange?) async throws -> Data {
        let result = try await FFmpegProcessRunner.run(
            executableURL: MediaToolPaths.ffmpeg,
            arguments: ["-hide_banner", "-loglevel", "error"]
                + (clip?.inputArguments ?? [])
                + [
                    "-i", url.path,
                    "-map", "0:v:0",
                    "-vf", "select=eq(n\\,\(index))",
                    "-frames:v", "1",
                    "-f", "image2pipe",
                    "-c:v", "png",
                    "-"
                ]
        )

        guard !result.standardOutput.isEmpty else {
            throw AppError("FFmpeg non ha restituito il fotogramma \(index).")
        }

        return result.standardOutput
    }
}
