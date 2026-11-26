// AnalysisView.swift
// Sezione Analisi qualità: curve bitrate/qualità e dettaglio di ogni analisi.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// La sezione Analisi qualità: dove si leggono i risultati delle analisi e si confrontano le codifiche.
///
/// In cima, per il video scelto, la curva qualità/bitrate di ogni configurazione, con il BD-rate
/// che riassume quanto bitrate risparmia una configurazione rispetto a un'altra. Sotto, una scheda
/// per ogni analisi: le metriche medie, il VMAF, il QP e la dimensione di ogni fotogramma lungo il video,
/// e il confronto visivo di un fotogramma con l'originale. La guida, chiusa all'inizio, spiega
/// parametri di codifica e metriche.
struct AnalysisView: View {
    @Environment(AppViewModel.self) private var appModel
    /// Apre i grafici ingranditi in una finestra a parte (vedi ``ChartWindowView``).
    @Environment(\.openWindow) private var openWindow
    /// La metrica delle curve.
    @State private var selectedCurveMetric: QualityCurveMetric = .vmaf
    /// L'analisi di cui si sta confermando l'eliminazione.
    @State private var analysisToDeleteID: UUID?
    /// Vero mentre è aperta la conferma dell'eliminazione.
    @State private var isDeleteAnalysisConfirmationPresented = false
    /// Il confronto di fotogrammi aperto, se c'è.
    @State private var frameComparison: FrameComparison?
    /// L'analisi di cui si stanno estraendo i fotogrammi da confrontare.
    @State private var loadingComparisonID: UUID?

    /// L'analisi su cui portarsi all'apertura, da «Vedi analisi» in Esperimenti video;
    /// torna `nil` dopo lo scorrimento.
    @Binding var analysisToShowID: UUID?
    /// Apre la sezione Relazione sul file originale indicato.
    let onShowReport: (UUID) -> Void
    /// L'analisi evidenziata per un momento dopo lo scorrimento.
    @State private var highlightedAnalysisID: UUID?

    /// Video scelto nel filtro: "tutti" oppure l'identificativo del video originale.
    /// Finché l'utente non sceglie, si mostra il video dell'analisi più recente.
    @State private var chosenSource: String?

    /// Il valore del filtro che mostra tutti i video.
    private static let allSources = "tutti"

    /// Un video originale proposto nel filtro.
    private struct SourceOption: Identifiable {
        let id: UUID
        let name: String
    }

    /// Gli esperimenti video, per identificativo.
    private var experimentsByID: [UUID: EncodingExperiment] {
        Dictionary(uniqueKeysWithValues: appModel.experiments.map { ($0.id, $0) })
    }

    /// I video originali che hanno almeno un'analisi.
    private var sourceOptions: [SourceOption] {
        let experiments = experimentsByID
        var seen = Set<UUID>()

        return appModel.qualityAnalysisResults
            .compactMap { experiments[$0.experimentID] }
            .filter { seen.insert($0.sourceVideoID).inserted }
            .map { SourceOption(id: $0.sourceVideoID, name: $0.sourceName) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Il valore effettivo del filtro: la scelta dell'utente se è ancora valida, altrimenti il file
    /// scelto per ultimo qui o in Relazione, altrimenti il video dell'analisi più recente.
    private var selectedSource: String {
        let options = sourceOptions

        if let chosenSource,
           chosenSource == Self.allSources || options.contains(where: { $0.id.uuidString == chosenSource }) {
            return chosenSource
        }

        if let focused = appModel.focusedSourceID, options.contains(where: { $0.id == focused }) {
            return focused.uuidString
        }

        let latest = appModel.qualityAnalysisResults.max { $0.analyzedAt < $1.analyzedAt }
        return latest.flatMap { experimentsByID[$0.experimentID]?.sourceVideoID.uuidString } ?? Self.allSources
    }

    /// Le analisi del video scelto nel filtro.
    private var filteredResults: [VideoQualityAnalysisResult] {
        let source = selectedSource

        guard source != Self.allSources else { return appModel.qualityAnalysisResults }

        let experiments = experimentsByID
        return appModel.qualityAnalysisResults.filter {
            experiments[$0.experimentID]?.sourceVideoID.uuidString == source
        }
    }

    /// I gruppi di curve delle analisi filtrate, per la metrica scelta.
    private var qualityCurveGroups: [QualityCurveGroup] {
        QualityCurveGroupBuilder.build(
            results: filteredResults,
            experiments: appModel.experiments,
            metric: selectedCurveMetric
        )
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                // Pigro: grafici e schede vengono disegnati solo quando entrano nella finestra.
                // Con molte analisi, disegnarli tutti insieme bloccava per un paio di secondi
                // il menu del video originale.
                LazyVStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Analisi qualità")
                            .font(.largeTitle.bold())

                        Text("Curve bitrate-qualità basate su VMAF, PSNR-Y e SSIM.")
                            .foregroundStyle(.secondary)
                    }

                    encodingConceptsSection

                    if appModel.jobs.current?.kind == .qualityAnalysis {
                        ProgressView("Analisi in corso…")
                    }

                    if appModel.qualityAnalysisResults.isEmpty {
                        ContentUnavailableView(
                            "Nessuna analisi disponibile",
                            systemImage: "waveform.path.ecg",
                            description: Text(
                                "Completa una codifica e avvia un'analisi della qualità."
                            )
                        )
                        .frame(maxWidth: .infinity)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            // Si legge il valore effettivo del filtro e si salva la scelta dell'utente
                            // (vedi `selectedSource`).
                            Picker(
                                "Video originale",
                                selection: Binding(get: { selectedSource }, set: { choice in
                                    chosenSource = choice
                                    // Un file preciso vale anche per la Relazione.
                                    if let id = UUID(uuidString: choice) { appModel.focusedSourceID = id }
                                })
                            ) {
                                Text("Tutti i video")
                                    .tag(Self.allSources)

                                ForEach(sourceOptions) { option in
                                    Text(option.name)
                                        .tag(option.id.uuidString)
                                }
                            }
                            // Larghezza naturale: etichetta e menu restano allineati a sinistra.
                            .fixedSize()

                            reportPrompt
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Tipo di curva")
                                .font(.subheadline.weight(.semibold))

                            Picker("Tipo di curva", selection: $selectedCurveMetric) {
                                ForEach(QualityCurveMetric.allCases) { metric in
                                    Text(metric.title).tag(metric)
                                }
                            }
                            .pickerStyle(.segmented)

                            Text(curveDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        let groups = qualityCurveGroups

                        if groups.isEmpty {
                            ContentUnavailableView(
                                "Dati insufficienti per le curve",
                                systemImage: "chart.xyaxis.line",
                                description: Text(
                                    "Servono un bitrate video effettivo e una metrica valida per almeno un risultato."
                                )
                            )
                            .frame(maxWidth: .infinity)
                        } else {
                            // Un grafico per gruppo (stesso file e stesso spezzone), seguito dalle schede
                            // delle sue analisi. Grafico e schede sono elementi distinti della pila pigra,
                            // così ciascuno viene disegnato solo quando serve.
                            ForEach(groups) { group in
                                QualityCurveChartView(group: group, metric: selectedCurveMetric) {
                                    openWindow(value: ChartWindowRequest.curves(groupID: group.id, metric: selectedCurveMetric.rawValue))
                                }

                                ForEach(group.analyses) { result in
                                    qualityAnalysisCard(result)
                                        .id(result.id)  // Per lo scorrimento da «Vedi analisi»
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color.accentColor, lineWidth: 2)
                                                .opacity(highlightedAnalysisID == result.id ? 1 : 0)
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
            .task(id: analysisToShowID) {
                await scrollToRequestedAnalysis(with: scrollProxy)
            }
            .task(id: highlightedAnalysisID) {
                await fadeHighlight()
            }
        }
        .navigationTitle("Analisi qualità")
        .onAppear {
            // I pulsanti del confronto dipendono dalla presenza dei file.
            appModel.refreshFileAvailability()
        }
        .sheet(item: $frameComparison) { comparison in
            FrameComparisonView(comparison: comparison)
                .textSelection(.enabled)
        }
        .confirmationDialog(
            "Vuoi eliminare definitivamente questa analisi?",
            isPresented: $isDeleteAnalysisConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Sì", role: .destructive) {
                if let id = analysisToDeleteID {
                    appModel.removeQualityAnalysisResult(id: id)
                }

                analysisToDeleteID = nil
            }

            Button("Annulla", role: .cancel) {
                analysisToDeleteID = nil
            }
        }
    }

    /// Il collegamento alla relazione sul file scelto; niente con "Tutti i video".
    @ViewBuilder
    private var reportPrompt: some View {
        if let sourceID = UUID(uuidString: selectedSource) {
            Button("Vedi la relazione su questo file", systemImage: "doc.text") {
                onShowReport(sourceID)
            }
            .buttonStyle(.link)
            .help("Apre la sezione Relazioni su questo file originale")
        }
    }

    /// La spiegazione della metrica scelta, sotto il menu.
    private var curveDescription: String {
        switch selectedCurveMetric {
        case .vmaf:
            "Rate-quality: il VMAF cresce generalmente con il bitrate; valori più alti indicano qualità percettiva migliore."
        case .vmafPercentile5:
            "Il 5% dei fotogrammi ha un VMAF inferiore a questo valore: misura la qualità dei momenti peggiori, che la media tende a nascondere."
        case .psnrY:
            "Rate-quality: il PSNR-Y è espresso in dB. Valori più alti indicano un errore pixel-wise inferiore."
        case .ssim:
            "Rate-quality: SSIM confronta struttura e luminanza. Valori più vicini a 1 indicano maggiore similarità."
        }
    }

    /// Le voci della guida ai parametri di codifica e alle metriche: titolo e testo.
    ///
    /// Le stesse voci si leggono nella sezione e si copiano o salvano in Markdown.
    private static let guideEntries: [(title: String, text: String)] = [
        (
            "Analisi del video originale",
            "Nella Libreria, «Avvia analisi» esamina il video originale in tre modi. Conta i fotogrammi e li classifica in I, P e B: in un video non compresso sono tutti I, in uno già compresso si vede com'è stato codificato. Calcola SI (Spatial Information) e TI (Temporal Information) secondo la raccomandazione ITU-T P.910 sulla luminanza a 8 bit e alla risoluzione originale. Lo SI è la deviazione standard dei bordi dell'immagine (filtro di Sobel) e misura il dettaglio di ogni fotogramma. Il TI è la deviazione standard della differenza tra un fotogramma e il precedente e misura quanto l'immagine cambia nel tempo. Per ciascuno si indicano la mediana e il massimo: la P.910 usa il massimo, mentre la mediana è meno sensibile ai singoli fotogrammi estremi, come i cambi di scena per il TI. I valori dipendono dalla risoluzione, quindi si confrontano tra video della stessa dimensione; il TI cresce anche con il dettaglio di ciò che si muove. Infine esegue la codifica di prova di «Crea serie» (x264, CRF \(ComplexityProbe.crf), preset \(ComplexityProbe.preset)), che misura il bitrate richiesto dal video."
        ),
        (
            "Controllo del rate: bitrate, CRF e QP",
            "Bitrate: si indica un bitrate obiettivo medio in kb/s (kilobit al secondo), che l'encoder distribuisce tra le scene senza limiti ai picchi (non è un bitrate costante, CBR); è l'unica modalità disponibile con VideoToolbox, il codificatore hardware di Apple. Via hardware la codifica avviene in una sola passata, scoprendo il video man mano: con bitrate bassi l'inizio può risultare molto degradato. Via software CodecLab codifica sempre in due passate: la prima analizza tutto il video, la seconda distribuisce i bit dove servono e rispetta meglio il bitrate richiesto. CRF (Constant Rate Factor; solo x264 e x265): si indica un livello di qualità; l'encoder varia la quantizzazione tra i fotogrammi e al loro interno per mantenere una qualità percepita circa costante, e il bitrate dipende dal contenuto. QP (Quantization Parameter; solo x264 e x265): quantizzazione costante, senza adattamenti al contenuto. Il valore vale per i P-frame; gli I usano circa 3 punti in meno e i B circa 2 in più. Può essere utile per studiare la quantizzazione, ma è molto meno utile per l'uso reale."
        ),
        (
            "GOP e fotogrammi I/P/B",
            "Il GOP (Group of Pictures) è la distanza massima tra due fotogrammi I; l'encoder può inserirne prima, per esempio a un cambio di scena. Un fotogramma I (intra-coded) è codificato da solo (predizione spaziale); un P (predicted) si basa su fotogrammi già codificati; un B (bi-predictive) può usare riferimenti precedenti e successivi. P e B sfruttano la somiglianza tra fotogrammi e quindi costano molto meno di un I. Il numero massimo di B-frame consecutivi si imposta solo via software; via hardware la scelta resta a VideoToolbox, che di solito non li usa."
        ),
        (
            "Quantizzazione e QP per fotogramma",
            "Dopo la trasformata, i coefficienti vengono quantizzati: un QP più alto significa passi più ampi, meno dettaglio, meno bit e più distorsione (in H.264 e H.265, 6 punti di QP in più dimezzano all'incirca il bitrate). Per le codifiche software CodecLab registra il QP medio di ogni fotogramma, come riportato da x264 e x265: all'interno del fotogramma il QP varia da blocco a blocco, e qui non è visibile. Con VideoToolbox questa informazione non è disponibile."
        ),
        (
            "Grafici lungo il video",
            "Nella scheda di ogni analisi, i grafici impilati seguono il video fotogramma per fotogramma: VMAF, QP (solo via software) e dimensione dei fotogrammi, colorata per tipo (I, P, B), con sotto il bitrate di ogni secondo. Il puntatore li attraversa tutti insieme: così si vede se un calo di qualità coincide con un QP più alto, con fotogrammi più piccoli o con un fotogramma I. Con un clic sulla curva del VMAF si confronta quel fotogramma con l'originale."
        ),
        (
            "Profili",
            "Il profilo stabilisce quali strumenti di compressione possono essere usati. H.264: Baseline non usa i B-frame né la codifica entropica CABAC (Context-Adaptive Binary Arithmetic Coding); Main li consente; High aggiunge la trasformata 8×8. A parità di bitrate, Baseline rende quindi meno. H.265: Main ammette solo video a 8 bit; Main 10 anche a 10 bit (CodecLab codifica in Main 10 a 10 bit)."
        ),
        (
            "Hardware e software",
            "VideoToolbox usa l'encoder hardware del chip Apple Silicon: è molto veloce e impegna poco la CPU, ma a parità di bitrate in genere comprime peggio e offre meno controlli. x264 e x265 lavorano invece solo con la CPU: sono più lenti, ma più efficienti e configurabili. In CodecLab usano sempre il preset «medium»; preset più lenti comprimerebbero ancora meglio. VideoToolbox, inoltre, può rifiutarsi di scendere sotto una certa soglia di bitrate (diversa per ogni video): anche chiedendo meno, il bitrate prodotto resta all'incirca su quella soglia. «Crea serie hardware / software» codifica lo stesso video a quattro bitrate con entrambi gli encoder (per un totale di otto codifiche) per confrontarle sullo stesso grafico; i bitrate vengono calcolati automaticamente con una codifica di prova, che misura quanto il video è difficile da comprimere; per confrontare due codec diversi, creare due serie sullo stesso file."
        ),
        (
            "Metriche",
            "VMAF (Video Multimethod Assessment Fusion) stima la qualità percepita da 0 a 100, con un modello addestrato su giudizi di spettatori, tarato per un video 1080p (1920×1080) visualizzato su un televisore: per questo CodecLab ingrandisce a 1080p i video più piccoli prima di calcolarlo. Come ordine di grandezza, si cita spesso che circa 6 punti corrispondono a una differenza appena percettibile: differenze di 1–2 punti difficilmente si vedono. PSNR-Y (Peak Signal-to-Noise Ratio, calcolato sulla luminanza Y, in decibel) misura la differenza pixel per pixel: è un valore oggettivo, ma non rispecchia necessariamente la percezione umana. SSIM (Structural Similarity Index, da 0 a 1) confronta luminanza, contrasto e struttura locali dell'immagine. Per tutte e tre, valori più alti sono migliori. Poiché la media può nascondere cali momentanei, il 5° percentile e il minimo del VMAF mostrano più chiaramente i momenti peggiori."
        ),
        (
            "Curve e BD-rate",
            "Ogni punto della curva è una codifica: bitrate effettivo misurato e qualità. A parità di bitrate, la curva più in alto è la migliore. Il BD-rate (Bjøntegaard Delta rate, il metodo standard per confrontare due encoder) riassume la distanza tra due curve come differenza media di bitrate a parità di qualità: −30% significa che per la stessa qualità serve il 30% di bitrate in meno. Ogni curva software si confronta con l'hardware dello stesso codec e profilo, e ogni curva H.265 con l'H.264 dello stesso encoder; ogni riga della tabella indica il suo riferimento. Contano solo i punti entro l'obiettivo (un cerchio vuoto indica che l'encoder ha superato di oltre il 25% il bitrate richiesto): ne servono almeno 3 per curva, con valori di qualità in comune."
        )
    ]

    /// Il titolo della guida.
    private static let guideTitle = "Guida ai parametri di codifica e alle metriche"

    /// La guida in Markdown, da copiare o salvare.
    static var guideMarkdown: String {
        "# \(guideTitle)\n\n" + guideEntries.map { "## \($0.title)\n\n\($0.text)" }.joined(separator: "\n\n") + "\n"
    }

    /// La guida ai parametri di codifica e alle metriche, chiusa finché l'utente non la apre.
    private var encodingConceptsSection: some View {
        DisclosureGroup(Self.guideTitle) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button("Copia", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.guideMarkdown, forType: .string)
                    }
                    .help("Copia la guida in formato Markdown")

                    Button("Salva…", systemImage: "square.and.arrow.down") {
                        saveGuide()
                    }
                    .help("Salva la guida in un file Markdown (.md)")
                }
                .controlSize(.small)

                ForEach(Self.guideEntries.indices, id: \.self) { index in
                    let entry = Self.guideEntries[index]

                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.title)
                            .font(.subheadline.weight(.semibold))
                        Text(entry.text)
                            .font(.callout)
                    }
                }
            }
            .padding(.top, 10)
        }
        .padding(.vertical, 4)
    }

    /// Salva la guida in un file Markdown scelto dall'utente.
    private func saveGuide() {
        let panel = NSSavePanel()
        panel.title = "Salva la guida"
        panel.nameFieldStringValue = "Guida CodecLab.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try Self.guideMarkdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            appModel.errorMessage = "Impossibile salvare la guida: \(error.localizedDescription)"
        }
    }

    /// Porta la vista sull'analisi richiesta da «Vedi analisi» e la evidenzia per un momento.
    ///
    /// Prima sceglie nel filtro il video originale dell'analisi, perché la scheda sia tra quelle mostrate;
    /// poi attende che la vista si aggiorni e scorre fino alla scheda.
    ///
    /// - Parameter scrollProxy: Il controllo dello scorrimento.
    private func scrollToRequestedAnalysis(with scrollProxy: ScrollViewProxy) async {
        guard let analysisID = analysisToShowID else { return }

        if let result = appModel.qualityAnalysisResults.first(where: { $0.id == analysisID }),
           let experiment = experimentsByID[result.experimentID] {
            chosenSource = experiment.sourceVideoID.uuidString
        }

        // Il tempo per disegnare le schede del video scelto: senza, la scheda potrebbe non esistere ancora.
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }

        withAnimation {
            scrollProxy.scrollTo(analysisID, anchor: .top)
        }

        highlightedAnalysisID = analysisID

        // Azzerare la richiesta interrompe questo compito (la sua chiave cambia): va fatto per ultimo.
        analysisToShowID = nil
    }

    /// Toglie l'evidenziazione della scheda dopo un paio di secondi.
    private func fadeHighlight() async {
        guard highlightedAnalysisID != nil else { return }

        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }

        withAnimation {
            highlightedAnalysisID = nil
        }
    }

    /// La scheda di un'analisi: metriche, note sul calcolo, configurazione, fotogrammi,
    /// VMAF lungo il video, QP per fotogramma e tempi.
    ///
    /// - Parameter result: L'analisi.
    private func qualityAnalysisCard(
        _ result: VideoQualityAnalysisResult
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    result.analyzedAt.formatted(
                        date: .long,
                        time: .shortened
                    )
                )
                .font(.caption)
                .foregroundStyle(.tertiary)

                Divider()

                HStack(alignment: .center, spacing: 24) {
                    QualityMetricsRow(summary: result.summary)
                    QualityMetricView(title: "VMAF 5° perc.", value: result.vmafPercentile5, decimals: 2)
                    QualityMetricView(title: "VMAF minimo", value: result.vmafMinimum, decimals: 2)
                }

                // Come è stato calcolato il VMAF; `nil` nelle analisi salvate prima
                // che i video piccoli venissero ingranditi a 1080p.
                if result.vmafAt1080p == true {
                    Text("VMAF calcolato sui video ingranditi a 1080p, come richiede il modello; PSNR e SSIM alla risoluzione originale.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if result.vmafAt1080p == nil {
                    Text("Analisi precedente: se il video è più piccolo di 1080p, il VMAF è stato calcolato alla risoluzione originale. Rifai l'analisi per confrontarla con le nuove.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if !result.vmafPerFrame.isEmpty {
                    // Il confronto estrae i fotogrammi dai file: se mancano, lo si dice subito.
                    let missingFiles = appModel.missingFilesDescription(for: result.experimentID)
                    // Un confronto alla volta: mentre si estraggono i fotogrammi, i clic sono ignorati.
                    let canCompare = missingFiles == nil && loadingComparisonID == nil

                    FrameTimelineView(
                        vmaf: result.vmafPerFrame,
                        percentile5: result.vmafPercentile5,
                        quantization: result.frameQuantizationSamples ?? [],
                        frameSizes: result.frameSizes ?? [],
                        frameTypes: result.frameTypes ?? "",
                        framesPerSecond: appModel.framesPerSecond(of: result),
                        startSeconds: result.encodingSettings.clip?.startSeconds ?? 0,
                        onSelectFrame: canCompare ? { index in
                            Task { await showFrame(of: result, index: index) }
                        } : nil,
                        onEnlarge: {
                            openWindow(value: ChartWindowRequest.timeline(analysisID: result.id))
                        }
                    )

                    Button {
                        if let index = result.worstFrameIndex {
                            Task { await showFrame(of: result, index: index) }
                        }
                    } label: {
                        if loadingComparisonID == result.id {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Confronta il fotogramma peggiore", systemImage: "rectangle.split.2x1")
                        }
                    }
                    .disabled(loadingComparisonID != nil || missingFiles != nil)

                    if let missingFiles {
                        Label(
                            "\(missingFiles) " + (appModel.experimentsMissingSource.contains(result.experimentID)
                                ? "Ripristina il file originale (o ricollega il disco) per confrontare i fotogrammi."
                                : "Ricodifica l'esperimento per confrontare i fotogrammi."),
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }

                Divider()

                analysisEncodingSettingsSection(result)

                Divider()

                frameComparisonSection(result)

                Divider()

                analysisTimingSection(result)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        } label: {
            HStack {
                Text("File codificato: \(result.outputFileName)")
                    .font(.subheadline)

                Spacer()

                Button(role: .destructive) {
                    analysisToDeleteID = result.id
                    isDeleteAnalysisConfirmationPresented = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Elimina questa analisi")
            }
        }
    }

    /// La configurazione della codifica analizzata.
    ///
    /// - Parameter result: L'analisi.
    private func analysisEncodingSettingsSection(
        _ result: VideoQualityAnalysisResult
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Configurazione della codifica")
                .font(.subheadline.weight(.semibold))

            let settings = result.encodingSettings

            Text(settings.codecDescription)
                .font(.callout)

            Text("\(settings.rateControlDescription) · \(settings.structureDescription)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let clip = settings.clip {
                Text(clip.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Il numero di fotogrammi di un video, con il suo titolo; "—" se non è noto.
    private func frameCountMetric(
        _ title: String,
        value: Int?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value.map { $0.formatted() } ?? "—")
                .font(.system(.body, design: .rounded).weight(.semibold))
                .monospacedDigit()
        }
    }
    
    /// I fotogrammi di originale e codificato e quelli confrontati, la distribuzione I/P/B
    /// del video codificato e, per le codifiche software, il QP per fotogramma.
    ///
    /// - Parameter result: L'analisi.
    private func frameComparisonSection(
        _ result: VideoQualityAnalysisResult
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Confronto dei fotogrammi")
                .font(.subheadline.weight(.semibold))

            HStack(alignment: .top, spacing: 24) {
                frameCountMetric(
                    "Originale",
                    value: result.originalFrameCount
                )

                frameCountMetric(
                    "Codificato",
                    value: result.outputFrameCount
                )

                frameCountMetric(
                    "Confrontati",
                    value: result.comparedFrameCount
                )
            }

            if let types = result.frameTypeSummary {
                Divider()

                Text("Distribuzione dei frame codificati")
                    .font(.caption.weight(.semibold))

                HStack(alignment: .top, spacing: 24) {
                    frameCountMetric(
                        "I · \(types.iPercentage.formatted(.number.precision(.fractionLength(1)).grouping(.never)))%",
                        value: types.iFrames
                    )

                    frameCountMetric(
                        "P · \(types.pPercentage.formatted(.number.precision(.fractionLength(1)).grouping(.never)))%",
                        value: types.pFrames
                    )

                    frameCountMetric(
                        "B · \(types.bPercentage.formatted(.number.precision(.fractionLength(1)).grouping(.never)))%",
                        value: types.bFrames
                    )

                    if types.otherFrames > 0 {
                        frameCountMetric(
                            "Altri",
                            value: types.otherFrames
                        )
                    }
                }
            }
            
            if let samples = result.frameQuantizationSamples, !samples.isEmpty {
                FrameQuantizationView(samples: samples)
            } else if result.encodingSettings.backend == .hardware {
                Text("QP per frame non disponibile con VideoToolbox.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Il tempo impiegato dall'analisi, la dimensione e il bitrate video del file codificato.
    ///
    /// - Parameter result: L'analisi.
    private func analysisTimingSection(
        _ result: VideoQualityAnalysisResult
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Prestazioni dell'analisi")
                .font(.subheadline.weight(.semibold))

            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tempo impiegato")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(MediaValueFormatter.duration(result.analysisDurationSeconds))
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                }

                if let fileSize = result.outputFileSizeBytes {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Dimensione file")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(MediaValueFormatter.bytes(fileSize))
                            .font(.callout.weight(.medium))
                            .monospacedDigit()
                    }
                }

                if let bitrate = result.videoBitrateBitsPerSecond {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Bitrate video misurato")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(MediaValueFormatter.bitRate(bitrate))
                            .font(.callout.weight(.medium))
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    /// Estrae un fotogramma dall'originale e dal codificato e li mostra affiancati.
    ///
    /// - Parameters:
    ///   - result: L'analisi.
    ///   - index: Il numero del fotogramma, contato come in libvmaf.
    private func showFrame(of result: VideoQualityAnalysisResult, index: Int) async {
        guard result.vmafPerFrame.indices.contains(index) else { return }

        // Finché l'estrazione non finisce, la scheda mostra l'attesa e gli altri confronti sono disattivati.
        loadingComparisonID = result.id
        defer { loadingComparisonID = nil }

        // In caso di errore, `frameImages` lo ha già mostrato.
        guard let images = await appModel.frameImages(for: result, index: index),
              let original = NSImage(data: images.original),
              let encoded = NSImage(data: images.encoded) else {
            return
        }

        frameComparison = FrameComparison(
            frameIndex: index,
            vmaf: result.vmafPerFrame[index],
            isWorst: index == result.worstFrameIndex,
            original: original,
            encoded: encoded
        )
    }

}

// MARK: - Confronto visivo

/// Lo stesso fotogramma dell'originale e del video codificato, estratto dai due file e pronto per il confronto,
/// con il suo VMAF.
struct FrameComparison: Identifiable {
    /// L'identificativo del confronto.
    let id = UUID()
    /// Il numero del fotogramma, contato come in libvmaf.
    let frameIndex: Int
    /// Il VMAF del fotogramma.
    let vmaf: Double
    /// Vero se è il fotogramma peggiore dell'analisi.
    let isWorst: Bool
    /// Il fotogramma dell'originale.
    let original: NSImage
    /// Il fotogramma del video codificato.
    let encoded: NSImage
}

/// Il confronto visivo di un fotogramma: originale e codificato affiancati, per vedere con i propri occhi
/// che cosa misura il VMAF.
///
/// Si apre con «Confronta il fotogramma peggiore» o con un clic sulla curva del VMAF. Ingrandimento
/// e spostamento valgono per entrambe le immagini, che mostrano sempre la stessa zona; lo spostamento
/// è limitato, così l'immagine ingrandita non lascia mai spazi vuoti.
struct FrameComparisonView: View {
    /// I fotogrammi da confrontare.
    let comparison: FrameComparison

    @Environment(\.dismiss) private var dismiss

    /// L'ingrandimento (1 = immagine adattata al riquadro).
    @State private var zoom: CGFloat = 1
    /// L'ingrandimento all'inizio del gesto di pizzico.
    @State private var zoomAtGestureStart: CGFloat = 1
    /// Lo spostamento dell'immagine rispetto al centro, in punti.
    @State private var offset: CGSize = .zero
    /// Lo spostamento all'inizio del trascinamento.
    @State private var offsetAtDragStart: CGSize = .zero
    /// La dimensione di ciascun pannello.
    @State private var panelSize: CGSize = .zero

    /// L'ingrandimento massimo.
    private static let maximumZoom: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(
                    "Fotogramma \(comparison.frameIndex) · VMAF \(comparison.vmaf.formatted(.number.precision(.fractionLength(2)).grouping(.never)))" +
                    (comparison.isWorst ? " · il peggiore" : "")
                )
                    .font(.headline)

                Spacer()

                Button("Riduci", systemImage: "minus.magnifyingglass") { changeZoom(by: 0.5) }
                    .labelStyle(.iconOnly)
                    .disabled(zoom <= 1)

                Text("\(Int((zoom * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 56)

                Button("Ingrandisci", systemImage: "plus.magnifyingglass") { changeZoom(by: 2) }
                    .labelStyle(.iconOnly)
                    .disabled(zoom >= Self.maximumZoom)

                Button("Adatta", action: fitToWindow)
                    .disabled(zoom == 1)
            }

            HStack(spacing: 12) {
                framePanel("Originale", comparison.original)
                framePanel("Codificato", comparison.encoded)
            }
            .gesture(dragGesture)
            .simultaneousGesture(magnifyGesture)
            .onTapGesture(count: 2) {
                if zoom == 1 {
                    changeZoom(by: 4)
                } else {
                    fitToWindow()
                }
            }

            HStack {
                Text("Pizzica sul trackpad, usa i pulsanti o fai doppio clic per ingrandire; trascina per spostarti. I due fotogrammi si muovono insieme. Guarda soprattutto bordi, sfumature, zone scure e in movimento.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Chiudi") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 1000, idealWidth: 1300, minHeight: 650, idealHeight: 850)
    }

    /// Un pannello con il suo titolo e l'immagine, ingrandita e spostata come l'altro.
    private func framePanel(_ title: String, _ image: NSImage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            // Ingrandita, l'immagine mostra i pixel netti: è così che si vedono gli artefatti.
            Image(nsImage: image)
                .resizable()
                .interpolation(zoom > 1 ? .none : .high)
                .scaledToFit()
                // Lo spostamento si applica dopo l'ingrandimento: è in punti dello schermo,
                // per questo il suo limite si calcola sull'immagine già ingrandita.
                .scaleEffect(zoom)
                .offset(offset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .contentShape(Rectangle())
                .background(.quaternary)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    // I due riquadri hanno la stessa misura; al ridimensionamento il limite cambia.
                    panelSize = size
                    offset = clampedOffset(offset, zoom: zoom)
                    offsetAtDragStart = offset
                }
        }
    }

    // MARK: - Ingrandimento e spostamento

    /// Imposta l'ingrandimento mantenendo al centro la stessa zona dell'immagine
    /// (per quanto lo consente il limite allo spostamento).
    private func setZoom(_ value: CGFloat) {
        let newZoom = min(max(value, 1), Self.maximumZoom)

        // `offset` è la distanza del centro dell'immagine da quello del riquadro: ingrandendo,
        // la stessa zona si allontana in proporzione, quindi lo spostamento va scalato.
        let ratio = newZoom / zoom

        offset = clampedOffset(CGSize(width: offset.width * ratio, height: offset.height * ratio), zoom: newZoom)
        offsetAtDragStart = offset
        zoom = newZoom
    }

    /// Dimensione dell'immagine adattata al riquadro (scaledToFit), prima dell'ingrandimento.
    /// Originale e codificato hanno la stessa risoluzione: basta uno dei due.
    private var fittedImageSize: CGSize {
        let image = comparison.original.size

        guard image.width > 0, image.height > 0, panelSize.width > 0, panelSize.height > 0 else {
            return panelSize
        }

        let scale = min(panelSize.width / image.width, panelSize.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    /// Limita lo spostamento: su ogni asse al massimo metà della parte di immagine che sporge
    /// dal riquadro. Così il bordo dell'immagine non entra mai nel riquadro; se su un asse
    /// l'immagine è più piccola del riquadro, su quell'asse resta centrata.
    private func clampedOffset(_ proposed: CGSize, zoom: CGFloat) -> CGSize {
        // L'immagine è centrata: la parte che sporge si divide a metà tra i due lati.
        let fitted = fittedImageSize
        let maxX = max(0, (fitted.width * zoom - panelSize.width) / 2)
        let maxY = max(0, (fitted.height * zoom - panelSize.height) / 2)

        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }

    /// Moltiplica l'ingrandimento per un fattore (pulsanti + e −, doppio clic).
    private func changeZoom(by factor: CGFloat) {
        setZoom(zoom * factor)
        zoomAtGestureStart = zoom
    }

    /// Torna all'immagine intera, centrata.
    private func fitToWindow() {
        setZoom(1)
        zoomAtGestureStart = 1
    }

    /// Il trascinamento dell'immagine ingrandita.
    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                // Senza ingrandimento l'immagine sta tutta nel riquadro: non c'è nulla da spostare.
                guard zoom > 1 else { return }

                // `translation` si misura dall'inizio del trascinamento, non dall'ultimo aggiornamento.
                offset = clampedOffset(
                    CGSize(
                        width: offsetAtDragStart.width + value.translation.width,
                        height: offsetAtDragStart.height + value.translation.height
                    ),
                    zoom: zoom
                )
            }
            .onEnded { _ in
                offsetAtDragStart = offset
            }
    }

    /// Il pizzico sul trackpad per ingrandire o ridurre.
    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                // `magnification` è relativo all'inizio del gesto.
                setZoom(zoomAtGestureStart * value.magnification)
            }
            .onEnded { _ in
                zoomAtGestureStart = zoom
            }
    }
}
