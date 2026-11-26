// SourceDetailView.swift
// Dettaglio del file selezionato nella Libreria: contenitore, tracce, bitrate
// e analisi del video originale (fotogrammi I/P/B, SI e TI, codifica di prova).

import Foundation
import SwiftUI

/// Il dettaglio del file selezionato nella Libreria: contenitore, tracce, bitrate e analisi
/// del video originale.
///
/// L'analisi, avviata con un solo pulsante, conta i fotogrammi I, P e B, calcola SI e TI ed esegue
/// la codifica di prova; ogni risultato viene salvato e riproposto finché il file non cambia.
struct SourceDetailView: View {
    @Environment(AppViewModel.self) private var appModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                if appModel.isInspectingMedia {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)

                        Text("Lettura delle informazioni multimediali…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                // MARK: - Informazioni del file

                if let url = appModel.inspectedURL,
                   let document = appModel.probeDocument {

                    MediaDetailsView(
                        url: url,
                        document: document
                    )

                    // MARK: - Analisi del video originale (solo se c'è una traccia video vera)

                    if let video = document.videoStream {
                        analysisBox(isUncompressed: video.isUncompressedVideo)
                    }

                } else if !appModel.isInspectingMedia {

                    ContentUnavailableView(
                        "Nessun file selezionato",
                        systemImage: "film",
                        description: Text(
                            "Seleziona un file nell'elenco per vederne le informazioni."
                        )
                    )
                }
            }
            .padding(24)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Analisi del video originale

    /// Vero se c'è almeno un risultato dell'analisi del video originale.
    private var hasSourceAnalysis: Bool {
        appModel.sourceAnalysisResult != nil
            || appModel.spatialTemporalMeasurement != nil
            || appModel.complexityMeasurement != nil
    }

    /// La data dell'analisi più recente tra le tre parti.
    private var latestSourceAnalysisDate: Date? {
        [
            appModel.sourceAnalysisResult?.analyzedAt,
            appModel.spatialTemporalMeasurement?.measuredAt,
            appModel.complexityMeasurement?.measuredAt
        ].compactMap { $0 }.max()
    }

    /// Il riquadro dell'analisi del video originale: fotogrammi I/P/B, SI e TI, codifica di prova,
    /// calcolati insieme con un solo pulsante.
    ///
    /// - Parameter isUncompressed: Vero se il video non è compresso: la scansione darà solo fotogrammi I.
    private func analysisBox(isUncompressed: Bool) -> some View {
        GroupBox("Analisi del video originale") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Conta i fotogrammi e li classifica in I, P e B; calcola SI (Spatial Information, il dettaglio di ogni fotogramma) e TI (Temporal Information, quanto l'immagine cambia da un fotogramma al successivo) secondo la raccomandazione ITU-T P.910, sulla luminanza a 8 bit e alla risoluzione originale; esegue la codifica di prova con cui «Crea serie» sceglie i bitrate, con x264 a qualità costante (CRF \(ComplexityProbe.crf), preset \(ComplexityProbe.preset)). I video oltre \(Int(ComplexityProbe.wholeVideoLimitSeconds)) secondi si provano su tre campioni da \(Int(ComplexityProbe.sampleSeconds)) secondi. Può richiedere tempo per file lunghi.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if isUncompressed {
                    Label(
                        "Video non compresso: ogni fotogramma è salvato per intero e non dipende dagli altri, quindi la scansione darà sempre il 100% di fotogrammi I.",
                        systemImage: "info.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                HStack {
                    Button {
                        Task {
                            await appModel.analyzeSource()
                        }
                    } label: {
                        Label(hasSourceAnalysis ? "Ripeti analisi" : "Avvia analisi", systemImage: "waveform.path.ecg")
                    }
                    .disabled(appModel.isAnalyzingSource)

                    if appModel.isAnalyzingSource {
                        ProgressView()
                            .controlSize(.small)

                        Text("\(appModel.sourceAnalysisStage ?? "Analisi")…")
                            .foregroundStyle(.secondary)
                    }
                }

                if let result = appModel.sourceAnalysisResult {
                    Divider()
                    sectionTitle("Fotogrammi I, P e B")

                    metricRow("Fotogrammi video letti", String(result.frameTypes.totalFrames))
                    metricRow("Frame I", countAndPercentage(result.frameTypes.iFrames, result.frameTypes.iPercentage))
                    metricRow("Frame P", countAndPercentage(result.frameTypes.pFrames, result.frameTypes.pPercentage))
                    metricRow("Frame B", countAndPercentage(result.frameTypes.bFrames, result.frameTypes.bPercentage))

                    if result.frameTypes.otherFrames > 0 {
                        metricRow("Altri frame", String(result.frameTypes.otherFrames))
                    }
                }

                if let measurement = appModel.spatialTemporalMeasurement {
                    let summary = measurement.summary

                    Divider()
                    sectionTitle("SI e TI")

                    metricRow("SI, mediana", oneDecimal(summary.siMedian))
                    metricRow("SI, massimo", oneDecimal(summary.siMax))
                    metricRow("TI, mediana", oneDecimal(summary.tiMedian))
                    metricRow("TI, massimo", oneDecimal(summary.tiMax))

                    Text("La raccomandazione P.910 usa il massimo; la mediana è meno sensibile ai singoli fotogrammi estremi, come i cambi di scena per il TI.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let measurement = appModel.complexityMeasurement {
                    Divider()
                    sectionTitle("Codifica di prova")

                    metricRow(
                        measurement.isSampled
                            ? "Bitrate a CRF \(ComplexityProbe.crf) (tre campioni da \(Int(ComplexityProbe.sampleSeconds)) s)"
                            : "Bitrate a CRF \(ComplexityProbe.crf)",
                        MediaValueFormatter.bitRate(Int64((measurement.referenceKbps * 1000).rounded()))
                    )
                }

                if let date = latestSourceAnalysisDate {
                    Text("Analisi completata: \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    /// Il titolo di una parte dei risultati.
    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
    }

    /// Un valore con un decimale, per esempio "45,2".
    private func oneDecimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    // MARK: - Metriche

    /// Una riga "etichetta → valore" della scansione I/P/B.
    private func metricRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .font(.system(.body, design: .rounded, weight: .medium))
                .monospacedDigit()
        }
    }

    /// Un conteggio con la sua percentuale, per esempio "120 (40,0%)".
    private func countAndPercentage(
        _ count: Int,
        _ percentage: Double
    ) -> String {
        "\(count) (\(percentage.formatted(.number.precision(.fractionLength(1))))%)"
    }
}

// MARK: - Dettagli del file

/// Le informazioni su contenitore e tracce di un file, con l'analisi del bitrate (costante o variabile).
///
/// L'analisi del bitrate parte quando la vista compare e riguarda i primi 60 secondi del file.
struct MediaDetailsView: View {
    /// Il file.
    let url: URL
    /// Le informazioni lette da FFprobe.
    let document: FFprobeDocument

    /// L'analisi del bitrate di ogni traccia, per indice di traccia.
    @State private var bitrateAnalyses: [Int: StreamBitrateAnalysis] = [:]
    /// Vero durante l'analisi del bitrate.
    @State private var isAnalyzingBitrates = false
    /// L'errore dell'analisi del bitrate, se non è riuscita.
    @State private var bitrateAnalysisError: String?

    var body: some View {
        GroupBox("Informazioni del file") {
            VStack(alignment: .leading, spacing: 14) {
                Text(url.lastPathComponent)
                    .font(.headline)

                if let format = document.format {
                    let container = containerInformation(for: format)

                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                        MetadataRow("Contenitore", container.name)
                        MetadataRow("Famiglia", container.family)

                        if let duration = format.durationSeconds {
                            MetadataRow("Durata", MediaValueFormatter.duration(duration))
                        }

                        if let size = format.sizeBytes {
                            MetadataRow("Dimensione", MediaValueFormatter.bytes(size))
                        }

                        if let bitRate = format.bitRateBitsPerSecond {
                            MetadataRow("Bitrate complessivo", MediaValueFormatter.bitRate(bitRate))
                        }
                    }
                }

                if !document.streams.isEmpty {
                    Divider()
                    Text("Tracce")
                        .font(.headline)

                    ForEach(Array(document.streams.enumerated()), id: \.offset) { entry in
                        streamDetails(entry.element, position: entry.offset)

                        if entry.offset < document.streams.count - 1 {
                            Divider()
                        }
                    }
                }

                if isAnalyzingBitrates {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Analisi della modalità bitrate…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if let bitrateAnalysisError {
                    Text("Classificazione CBR/VBR non disponibile: \(bitrateAnalysisError)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !bitrateAnalyses.isEmpty {
                    Text("MP1/MP2/MP3: rilevamento diretto di CBR o VBR dagli header dei frame sul campione iniziale (max 60 s). Altri codec: stima statistica sui pacchetti. Un bitrate variabile rilevato può corrispondere a VBR o ABR.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        // Riparte quando cambia il file; il task precedente viene annullato.
        .task(id: url.standardizedFileURL.path) {
            await loadBitrateAnalysis()
        }
    }

    // MARK: - Analisi bitrate

    /// Analizza il bitrate delle tracce del file.
    private func loadBitrateAnalysis() async {
        guard !document.streams.isEmpty else { return }

        isAnalyzingBitrates = true
        bitrateAnalysisError = nil
        bitrateAnalyses = [:]    // Niente risultati del file precedente mentre si analizza il nuovo.
        defer { isAnalyzingBitrates = false }

        do {
            bitrateAnalyses = try await FFprobeService().analyzeBitrate(
                url,
                streams: document.streams
            )
        } catch {
            bitrateAnalysisError = error.localizedDescription
        }
    }

    // MARK: - Contenitore

    /// Il nome del contenitore e la sua famiglia, ricavati dal formato e dalla marca
    /// dichiarata nel file (per esempio "MP4", famiglia "QuickTime / ISO Base Media").
    ///
    /// - Parameter format: Le informazioni sul contenitore.
    /// - Returns: Il nome e la famiglia del contenitore.
    private func containerInformation(
        for format: FFprobeFormat
    ) -> (name: String, family: String) {
        let brand = metadataTag("major_brand", in: format.tags)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        let fileExtension = url.pathExtension.lowercased()

        // FFprobe chiama "mov,mp4,m4a,3gp,3g2,mj2" tutta la famiglia ISO: il formato preciso
        // si ricava dalla marca dichiarata nel file ("major_brand").
        if brand.hasPrefix("qt") {
            return ("MOV", "QuickTime / ISO Base Media")
        }

        if brand.hasPrefix("3gp") {
            return ("3GP", "3GPP")
        }

        if brand.hasPrefix("3g2") {
            return ("3G2", "3GPP2")
        }

        if brand.hasPrefix("mj2") {
            return ("MJ2", "Motion JPEG 2000")
        }

        let isoBaseMediaBrands = [
            "isom", "iso2", "iso3", "iso4", "iso5", "iso6",
            "mp41", "mp42", "avc1", "dash", "msnv", "m4v", "m4a", "f4v"
        ]

        if isoBaseMediaBrands.contains(where: { brand.hasPrefix($0) }) {
            let name: String
            switch fileExtension {
            case "m4a": name = "M4A"
            case "m4v": name = "M4V"
            default: name = "MP4"
            }
            return (name, "QuickTime / ISO Base Media")
        }

        // Marca assente o sconosciuta: si ricorre all'estensione.
        switch fileExtension {
        case "mp4": return ("MP4", "QuickTime / ISO Base Media")
        case "mov": return ("MOV", "QuickTime / ISO Base Media")
        case "m4a": return ("M4A", "QuickTime / ISO Base Media")
        case "m4v": return ("M4V", "QuickTime / ISO Base Media")
        case "3gp": return ("3GP", "3GPP")
        case "3g2": return ("3G2", "3GPP2")
        case "mj2": return ("MJ2", "Motion JPEG 2000")
        case "mkv": return ("MKV", "Matroska")
        case "webm": return ("WebM", "WebM")
        case "avi": return ("AVI", "Audio Video Interleave")
        case "ts", "m2ts": return ("MPEG-TS", "MPEG Transport Stream")
        default:
            return (
                format.longName ?? format.formatName ?? "Non identificato",
                format.longName ?? "Formato contenitore rilevato da FFmpeg"
            )
        }
    }

    /// Il valore di un metadato, cercato senza distinguere maiuscole e minuscole.
    ///
    /// - Parameters:
    ///   - name: Il nome del metadato, per esempio "major_brand".
    ///   - tags: I metadati.
    /// - Returns: Il valore, o `nil` se il metadato non c'è.
    private func metadataTag(_ name: String, in tags: [String: String]?) -> String? {
        guard let tags else { return nil }
        return tags.first {
            $0.key.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }

    // MARK: - Tracce

    /// Le informazioni su una traccia: codec, profilo, risoluzione o frequenza, bitrate.
    ///
    /// - Parameters:
    ///   - stream: La traccia.
    ///   - position: La posizione nell'elenco, usata se FFprobe non indica l'indice della traccia.
    @ViewBuilder
    private func streamDetails(_ stream: FFprobeStream, position: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(streamTypeLabel(stream.codecType)) · Traccia \(stream.index ?? position)")
                .font(.subheadline.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                switch stream.codecType {
                case "video":
                    MetadataRow("Codec video", codecDisplayName(for: stream))

                    if let profile = stream.profile, !profile.isEmpty {
                        MetadataRow("Profilo", profile)
                    }

                    if let width = stream.width, let height = stream.height {
                        MetadataRow("Risoluzione", "\(width) × \(height)")
                    }

                    if let pixelDescription = pixelFormatDescription(for: stream) {
                        MetadataRow("Formato pixel", pixelDescription)
                    }

                    if let frameRate = stream.frameRate {
                        MetadataRow("Frame rate", "\(frameRate.formatted(.number.precision(.fractionLength(0...3)))) fps")
                    }

                    bitrateRow(for: stream, mediaType: "video")

                case "audio":
                    MetadataRow("Codec audio", codecDisplayName(for: stream))

                    if let profile = stream.profile, !profile.isEmpty {
                        MetadataRow("Profilo", profile)
                    }

                    if let sampleRate = stream.sampleRateHz {
                        MetadataRow("Frequenza di campionamento", "\(sampleRate) Hz")
                    }

                    if let channels = stream.channels {
                        let layout = stream.channelLayout.map { " (\($0))" } ?? ""
                        MetadataRow("Canali", "\(channels)\(layout)")
                    }

                    if let sampleFormat = stream.sampleFormat, !sampleFormat.isEmpty {
                        MetadataRow("Formato campioni", sampleFormat)
                    }

                    bitrateRow(for: stream, mediaType: "audio")

                    if let analysis = stream.index.flatMap({ bitrateAnalyses[$0] }),
                       analysis.classificationMethod == .direct,
                       analysis.mpegAudioHeaderMarker != nil {
                        MetadataRow("Indicatore MPEG Audio", mpegAudioMarkerDescription(for: analysis))
                    }

                case "subtitle":
                    MetadataRow("Codec sottotitoli", codecDisplayName(for: stream))

                default:
                    MetadataRow("Codec", codecDisplayName(for: stream))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    /// Le righe del bitrate di una traccia: valore e modalità (costante o variabile).
    ///
    /// - Parameters:
    ///   - stream: La traccia.
    ///   - mediaType: "video" o "audio".
    @ViewBuilder
    private func bitrateRow(for stream: FFprobeStream, mediaType: String) -> some View {
        let analysis = stream.index.flatMap { bitrateAnalyses[$0] }

        let bitrate: Int64? = analysis?.classificationMethod == .direct
            ? (analysis?.averageBitRateBitsPerSecond ?? stream.bitRateBitsPerSecond)
            : (stream.bitRateBitsPerSecond ?? analysis?.averageBitRateBitsPerSecond)

        if let bitrate {
            MetadataRow("Bitrate \(mediaType)", MediaValueFormatter.bitRate(bitrate))
        } else if isAnalyzingBitrates {
            MetadataRow("Bitrate \(mediaType)", "Analisi in corso…")
        } else {
            MetadataRow("Bitrate \(mediaType)", "Non disponibile")
        }

        // In una traccia non compressa (video raw, audio PCM) il bitrate è costante per definizione:
        // non serve stimarlo, e la stima statistica con file brevi non riuscirebbe a classificarlo.
        MetadataRow(
            "Modalità bitrate (CBR, VBR, …)",
            stream.isUncompressed ? "Costante (non compresso)" : bitrateModeDescription(for: analysis)
        )
    }

    /// La descrizione della modalità del bitrate e di come è stata stabilita.
    ///
    /// - Parameter analysis: L'analisi della traccia; `nil` se non è disponibile.
    /// - Returns: Per esempio "CBR" se letta dagli header, "Variabile (stimata)" se stimata sui pacchetti.
    private func bitrateModeDescription(
        for analysis: StreamBitrateAnalysis?
    ) -> String {
        guard let analysis else {
            if isAnalyzingBitrates {
                return "Analisi in corso…"
            }

            return bitrateAnalysisError == nil
                ? "Non determinabile"
                : "Analisi non disponibile"
        }

        switch analysis.classificationMethod {
        case .direct:
            switch analysis.mode {
            case .constant:
                return "CBR"

            case .variable:
                return "VBR"

            case .undetermined:
                return "Non determinabile"
            }

        case .estimated:
            switch analysis.mode {
            case .constant:
                return "Costante (stimata)"

            case .variable:
                return "Variabile (stimata)"

            case .undetermined:
                return "Non determinabile"
            }
        }
    }
    
    /// La descrizione dell'indicatore Xing, Info o VBRI e dell'encoder LAME di un file MPEG Audio.
    ///
    /// - Parameter analysis: L'analisi della traccia.
    /// - Returns: La descrizione.
    private func mpegAudioMarkerDescription(
        for analysis: StreamBitrateAnalysis
    ) -> String {
        let marker: String
        switch analysis.mpegAudioHeaderMarker {
        case .xing: marker = "Xing"
        case .info: marker = "Info"
        case .vbri: marker = "VBRI"
        case nil: marker = "Nessuno rilevato"
        }

        return analysis.hasLAMEEncoderTag ? "\(marker) · tag LAME" : marker
    }

    // MARK: - Nomi codec

    /// Il nome del codec mostrato all'utente (vedi ``FFprobeStream/codecDisplayName``).
    private func codecDisplayName(for stream: FFprobeStream) -> String {
        stream.codecDisplayName
    }

    // MARK: - Formato pixel

    /// Il formato dei pixel con profondità e sottocampionamento, per esempio "yuv420p (8 bit, 4:2:0)".
    ///
    /// - Parameter stream: La traccia video.
    /// - Returns: La descrizione, o `nil` se la traccia non indica il formato.
    private func pixelFormatDescription(for stream: FFprobeStream) -> String? {
        guard let pixelFormat = stream.pixelFormat, !pixelFormat.isEmpty else {
            return nil
        }

        var details: [String] = []
        if let bitDepth = stream.pixelFormatBitDepth {
            details.append("\(bitDepth) bit")
        }
        if let chroma = chromaSubsampling(for: pixelFormat) {
            details.append(chroma)
        }

        guard !details.isEmpty else { return pixelFormat }
        return "\(pixelFormat) (\(details.joined(separator: ", ")))"
    }

    /// Il sottocampionamento della crominanza ("4:2:0", "4:2:2", "4:4:4"), ricavato dal formato dei pixel.
    ///
    /// - Parameter pixelFormat: Il formato dei pixel.
    /// - Returns: Il sottocampionamento, o `nil` se non si riconosce.
    private func chromaSubsampling(for pixelFormat: String) -> String? {
        let format = pixelFormat.lowercased()

        if format.contains("420") ||
            ["nv12", "nv21", "p010le", "p010be", "p016le", "p016be"].contains(format) {
            return "4:2:0"
        }

        if format.contains("422") || ["nv16", "p210le", "p210be"].contains(format) {
            return "4:2:2"
        }

        if format.contains("444") {
            return "4:4:4"
        }

        return nil
    }

    /// Il nome del tipo di traccia mostrato all'utente: "Video", "Audio", "Sottotitoli"…
    private func streamTypeLabel(_ type: String?) -> String {
        switch type {
        case "video": "Video"
        case "audio": "Audio"
        case "subtitle": "Sottotitoli"
        case "data": "Dati"
        case "attachment": "Allegato"
        default: "Altra traccia"
        }
    }
}
