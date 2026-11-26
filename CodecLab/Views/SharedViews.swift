// SharedViews.swift
// Componenti e formattazioni usati da più sezioni.

import Charts
import Foundation
import SwiftUI

/// Una riga «etichetta → valore» delle tabelle di informazioni, per esempio «Chip → Apple M4» in Sistema.
struct MetadataRow: View {
    /// L'etichetta.
    let title: String
    /// Il valore.
    let value: String

    /// Crea una riga.
    ///
    /// - Parameters:
    ///   - title: L'etichetta.
    ///   - value: Il valore.
    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
        }
        .font(.callout)
    }
}

/// Il valore di una metrica di qualità (VMAF, PSNR o SSIM) con il suo titolo, come compare nelle schede.
struct QualityMetricView: View {
    /// Il nome della metrica.
    let title: String
    /// Il valore; "—" se manca.
    let value: Double?
    /// Le cifre decimali da mostrare.
    let decimals: Int
    /// L'unità di misura, per esempio " dB".
    var suffix = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value.map { $0.formatted(.number.precision(.fractionLength(decimals)).grouping(.never)) + suffix } ?? "—")
                .font(.system(.body, design: .rounded).weight(.semibold))
                .monospacedDigit()
        }
    }
}

/// Le tre metriche medie di un'analisi, una accanto all'altra.
struct QualityMetricsRow: View {
    /// Le medie di VMAF, PSNR-Y e SSIM.
    let summary: QualityMetricSummary

    var body: some View {
        QualityMetricView(title: "VMAF", value: summary.vmaf?.mean, decimals: 2)
        QualityMetricView(title: "PSNR Y", value: summary.psnrY?.mean, decimals: 2, suffix: " dB")
        QualityMetricView(title: "SSIM", value: summary.ssim?.mean, decimals: 4)
    }
}

/// Il riepilogo della qualità nella scheda di un esperimento: le metriche dell'ultima analisi
/// e il collegamento «Vedi analisi» alla sezione Analisi qualità.
struct QualitySummaryView: View {
    /// L'analisi da riassumere.
    let result: VideoQualityAnalysisResult
    /// Apre la sezione Analisi qualità su questa analisi.
    let onShowAnalysis: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            QualityMetricsRow(summary: result.summary)
            Spacer()
            Button("Vedi analisi", action: onShowAnalysis)
                .buttonStyle(.link)
        }
        .padding(.vertical, 4)
    }
}

/// L'avanzamento del lavoro in corso (codifica, analisi o codifica audio), con i pulsanti
/// per metterlo in pausa o annullarlo.
struct JobProgressView: View {
    @Environment(AppViewModel.self) private var appModel

    /// Il lavoro in corso.
    let job: ActiveJob

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(job.stage)
                .font(.callout)

            if job.isProgressDeterminate {
                ProgressView(value: job.progress)
            } else {
                ProgressView()
            }

            HStack {
                if job.isProgressDeterminate {
                    Text("\(Int(job.progress * 100))%")
                        .monospacedDigit()
                }

                Spacer()

                if job.canPause {
                    if job.isPaused {
                        Button("Riprendi", systemImage: "play.fill") {
                            appModel.jobs.resume()
                        }
                    } else {
                        Button("Pausa", systemImage: "pause.fill") {
                            appModel.jobs.pause()
                        }
                    }
                }

                Button("Annulla", systemImage: "stop.fill", role: .destructive) {
                    appModel.jobs.cancel()
                }
            }
            .font(.callout)
        }
    }
}

/// L'indicatore della coda nella barra degli strumenti, visibile da ogni sezione mentre c'è un lavoro.
///
/// Mostra un cerchio con l'avanzamento complessivo e la posizione («3 di 16»); con un clic apre
/// il riquadro completo, con pausa e annullamento.
struct QueueToolbarIndicator: View {
    @Environment(AppViewModel.self) private var appModel

    /// Vero mentre è aperto il riquadro con i dettagli.
    @State private var isPopoverPresented = false

    var body: some View {
        if let position = appModel.jobs.position {
            Button {
                isPopoverPresented.toggle()
            } label: {
                HStack(spacing: 6) {
                    ProgressView(value: appModel.jobs.overallProgress ?? 0)
                        .progressViewStyle(.circular)
                        .controlSize(.small)

                    Text("\(position.current) di \(position.total)")
                        .monospacedDigit()
                }
            }
            .help("Lavori in corso: clic per i dettagli")
            .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
                QueueStatusView()
                    .padding(12)
                    .frame(width: 340)
                    .textSelection(.enabled)
            }
        }
    }
}

/// Lo stato della coda dei lavori, sotto i pulsanti che la riempiono: «Crea serie» e «Crea esperimento»
/// in Esperimenti video, «Crea serie audio» in Esperimenti audio.
///
/// Mostra il lavoro in corso, l'avanzamento complessivo e i pulsanti per annullare. Senza lavori in corso
/// non mostra nulla.
struct QueueStatusView: View {
    @Environment(AppViewModel.self) private var appModel

    /// Vero mentre è aperta la conferma di «Annulla tutto».
    @State private var isCancelAllConfirmationPresented = false

    var body: some View {
        if let job = appModel.jobs.current, let position = appModel.jobs.position {
            let current = position.current
            let total = position.total
            let overall = appModel.jobs.overallProgress ?? 0

            VStack(alignment: .leading, spacing: 6) {
                Text(total > 1 ? "Lavoro \(current) di \(total) · \(Int(overall * 100))%" : "Lavoro in corso")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()

                // Sempre due righe, anche se la fase ne occupa una: così il riquadro non cambia altezza
                // a ogni passaggio tra codifica, analisi e le loro fasi.
                Text(job.isPaused ? "In pausa · \(job.stage)" : job.stage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)

                // L'avanzamento del singolo lavoro è già sotto il suo esperimento: qui quello di tutta la coda.
                // Con un solo lavoro senza avanzamento misurabile la barra resta indeterminata.
                if total > 1 || job.isProgressDeterminate {
                    ProgressView(value: overall)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }

                // Sempre presente, anche durante l'ultimo lavoro: prima spariva quando la coda si svuotava,
                // e il riquadro cambiava altezza.
                Button("Annulla tutto", systemImage: "stop.fill", role: .destructive) {
                    isCancelAllConfirmationPresented = true
                }
                .font(.caption)
                .help("Annulla il lavoro in corso e togli dalla coda tutti quelli in attesa")
                .confirmationDialog(
                    "Annullare tutti i lavori?",
                    isPresented: $isCancelAllConfirmationPresented,
                    titleVisibility: .visible
                ) {
                    Button("Annulla tutti i lavori", role: .destructive) {
                        appModel.jobs.cancelAll()
                    }

                    Button("Continua", role: .cancel) {}
                } message: {
                    let count = appModel.jobs.pending.count
                    let others = count == 0 ? "" : count == 1 ? " e l'altro verrà tolto dalla coda" : " e gli altri \(count) verranno tolti dalla coda"
                    Text("Il lavoro in corso verrà interrotto\(others). Gli esperimenti restano e potrai rilanciarli.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// L'interruttore «Usa solo uno spezzone del file», con inizio e durata in secondi.
///
/// Lo spezzone resta sempre dentro il file: l'inizio non supera la fine del video e la durata
/// non va oltre ciò che resta. Si usa in Esperimenti video e in Esperimenti audio.
struct ClipEditor: View {
    /// Lo spezzone; `nil` per usare il file intero.
    @Binding var clip: ClipRange?
    /// La durata del file scelto, in secondi: lo spezzone non può andare oltre. `nil` se non è nota.
    var sourceDuration: Double? = nil

    /// La durata massima ammessa dal file (10 minuti se non è nota).
    private var maximumSeconds: Double {
        sourceDuration.map { max(1, $0) } ?? 600
    }

    /// Attiva o disattiva lo spezzone; il nuovo spezzone dura 20 secondi, o meno se il file è più corto.
    private var isEnabled: Binding<Bool> {
        Binding(
            get: { clip != nil },
            set: { isOn in
                guard isOn else {
                    clip = nil
                    return
                }

                var newClip = ClipRange()
                newClip.durationSeconds = min(newClip.durationSeconds, maximumSeconds)
                clip = newClip
            }
        )
    }

    /// L'inizio dello spezzone: da zero fino a un secondo prima della fine del file.
    private var start: Binding<Double> {
        Binding(
            get: { clip?.startSeconds ?? 0 },
            set: { newValue in
                clip?.startSeconds = min(max(0, newValue), maximumSeconds - 1)
                fitToSource()
            }
        )
    }

    /// La durata dello spezzone: almeno un secondo, e non oltre la fine del file.
    private var duration: Binding<Double> {
        Binding(
            get: { clip?.durationSeconds ?? 20 },
            set: { clip?.durationSeconds = min(max(1, $0), availableSeconds) }
        )
    }

    /// I secondi che restano dall'inizio dello spezzone alla fine del file.
    private var availableSeconds: Double {
        max(1, maximumSeconds - (clip?.startSeconds ?? 0))
    }

    /// Riporta lo spezzone dentro il file: serve quando cambia l'inizio o si sceglie un file più corto.
    private func fitToSource() {
        guard var current = clip else { return }

        current.startSeconds = min(max(0, current.startSeconds), maximumSeconds - 1)
        current.durationSeconds = min(max(1, current.durationSeconds), max(1, maximumSeconds - current.startSeconds))

        if current != clip {
            clip = current
        }
    }

    var body: some View {
        Toggle("Usa solo uno spezzone del file", isOn: isEnabled)

        if clip != nil {
            HStack(spacing: 20) {
                HStack {
                    Text("Inizio (s)")

                    TextField("Inizio", value: start, format: .number)
                        .frame(width: 80)
                }

                Stepper(
                    "Durata: \(duration.wrappedValue.formatted()) s",
                    value: duration,
                    in: 1...availableSeconds,
                    step: 5
                )
            }
            // Un file più corto, scelto dopo aver impostato lo spezzone, lo riporta nei limiti.
            .onChange(of: sourceDuration) {
                fitToSource()
            }
            .onAppear {
                fitToSource()
            }

            Text((sourceDuration.map { "Il file dura \(MediaValueFormatter.duration($0)). " } ?? "") +
                 "Bastano 10–20 secondi con una scena impegnativa (movimento, dettagli fini, buio): i confronti restano validi e richiedono molto meno tempo.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Grafici: puntatore e informazioni

/// Un livello trasparente sopra un grafico, che segue il puntatore e i clic.
///
/// Riporta la posizione nell'area dei dati del grafico, così il grafico può mostrare il punto più vicino
/// al puntatore o reagire a un clic, per esempio aprendo il confronto di un fotogramma.
struct ChartPointerOverlay: View {
    /// Il grafico, per conoscere la posizione dell'area dei dati.
    let proxy: ChartProxy
    /// Chiamata quando il puntatore si muove sul grafico, con `nil` quando esce.
    let onHover: (CGPoint?) -> Void
    /// Chiamata con la posizione di un clic; `nil` se il grafico non reagisce ai clic.
    var onClick: ((CGPoint) -> Void)? = nil

    var body: some View {
        GeometryReader { geometry in
            if let plotFrame = proxy.plotFrame {
                // Il livello copre tutto il grafico, assi compresi, ma le posizioni di Swift Charts
                // partono dall'angolo dell'area dei dati: va tolto lo scostamento tra le due.
                let origin = geometry[plotFrame].origin

                // Trasparente ma sensibile al puntatore in ogni punto.
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            onHover(CGPoint(x: location.x - origin.x, y: location.y - origin.y))
                        case .ended:
                            onHover(nil)
                        }
                    }
                    .onTapGesture { location in
                        onClick?(CGPoint(x: location.x - origin.x, y: location.y - origin.y))
                    }
            }
        }
    }

    /// L'indice dell'elemento più vicino al puntatore, misurando la distanza sullo schermo.
    ///
    /// - Parameters:
    ///   - location: La posizione del puntatore.
    ///   - positions: Le posizioni degli elementi sullo schermo; `nil` per quelli non visibili.
    ///   - maximumDistance: La distanza massima, in punti.
    /// - Returns: L'indice, o `nil` se nessun elemento è abbastanza vicino.
    static func nearestIndex(
        to location: CGPoint,
        among positions: [CGPoint?],
        maximumDistance: CGFloat = 40
    ) -> Int? {
        let distances = positions.enumerated().compactMap { index, position -> (Int, CGFloat)? in
            guard let position else { return nil }

            // Distanza in punti dello schermo: sugli assi i valori hanno unità diverse,
            // e un asse è logaritmico, quindi non si possono confrontare direttamente.
            return (index, hypot(position.x - location.x, position.y - location.y))
        }

        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 <= maximumDistance else {
            return nil
        }

        return nearest.0
    }
}

/// Il riquadro con le informazioni sul punto indicato dal puntatore in un grafico.
struct ChartTooltip: View {
    /// Le righe da mostrare: la prima in grassetto.
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(index == 0 ? .caption.weight(.semibold) : .caption)
                    .monospacedDigit()
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
    }
}

/// La scrittura di durate, dimensioni e bitrate nel formato italiano: «1:05», «4,9 MB», «755 kb/s», «1,2 Mb/s».
///
/// Le funzioni sono pure, senza stato: si possono usare da qualsiasi contesto.
nonisolated enum MediaValueFormatter {
    /// Una durata, per esempio "1:05" o "1:02:05".
    ///
    /// - Parameter seconds: La durata, in secondi.
    /// - Returns: Minuti e secondi, con le ore solo se servono; "—" se il valore non è valido.
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }

        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60

        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%d:%02d", minutes, remainder)
    }

    /// Un istante con i decimi di secondo, per esempio "0:04,3" o "1:12,0".
    ///
    /// - Parameter seconds: L'istante, in secondi.
    /// - Returns: Il testo; "—" se il valore non è valido.
    static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }

        let minutes = Int(seconds / 60)
        let remainder = seconds - Double(minutes * 60)

        return "\(minutes):" + remainder.formatted(.number.precision(.integerAndFractionLength(integer: 2, fraction: 1)))
    }

    /// Una dimensione di file, per esempio "1,5 MB".
    ///
    /// - Parameter bytes: La dimensione, in byte.
    /// - Returns: Il testo, nel formato del Finder.
    static func bytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Un bitrate: "950 kb/s" sotto 1 Mb/s, "1,5 Mb/s" da 1 Mb/s in su.
    ///
    /// La soglia si applica dopo l'arrotondamento: 999,6 kb/s diventa "1,0 Mb/s".
    /// Il separatore decimale è quello della lingua di sistema.
    ///
    /// - Parameter bitsPerSecond: Il bitrate, in bit al secondo.
    /// - Returns: Il testo.
    static func bitRate(_ bitsPerSecond: Int64) -> String {
        let kbps = Double(bitsPerSecond) / 1_000

        // La soglia si confronta dopo l'arrotondamento: 999,6 kb/s diventa "1,0 Mb/s", non "1000 kb/s".
        guard kbps.rounded() >= 1_000 else {
            return "\(Int(kbps.rounded())) kb/s"
        }

        return (kbps / 1_000).formatted(.number.precision(.fractionLength(1))) + " Mb/s"
    }
}

// MARK: - Disposizione a capo

/// Dispone le viste in righe, andando a capo quando non c'è più spazio, come le parole di un testo.
///
/// La usano le etichette di Cerca codifiche e le righe del BD-rate, dove i nomi delle configurazioni
/// possono essere lunghi.
struct FlowLayout: Layout {
    /// Lo spazio tra le viste e tra le righe.
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let frames = arrange(subviews, width: width)
        let usedWidth = frames.map(\.maxX).max() ?? 0
        return CGSize(width: proposal.width ?? usedWidth, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, arrange(subviews, width: bounds.width)) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    /// La posizione di ogni vista: si va a capo quando la riga è piena; una vista più larga
    /// dello spazio disponibile viene ristretta (e il suo testo accorciato).
    private func arrange(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, width)

            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }

            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        // Nella stessa riga, le viste più basse (per esempio un'etichetta piccola tra due testi)
        // vengono centrate in verticale.
        for row in Set(frames.map(\.minY)) {
            let indices = frames.indices.filter { frames[$0].minY == row }
            let height = indices.map { frames[$0].height }.max() ?? 0
            for index in indices {
                frames[index].origin.y += (height - frames[index].height) / 2
            }
        }

        return frames
    }
}
