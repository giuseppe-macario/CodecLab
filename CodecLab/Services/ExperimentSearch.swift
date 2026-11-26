// ExperimentSearch.swift
// La ricerca a parole tra le codifiche, le loro analisi e le relazioni.
//
// La frase la interpreta il codice, con un vocabolario piccolo e chiuso: video, codec, encoder,
// bitrate, VMAF medio e minimo, "sopra", "sotto", "tra … e …". Se resta anche una sola parola
// che il codice non riconosce, la frase non viene interpretata a metà: Apple Intelligence
// la riscrive con il vocabolario di CodecLab, la riscrittura viene mostrata e il codice
// la interpreta come qualsiasi altra frase. Nessun numero dei risultati passa dal modello.

import Foundation
import FoundationModels

// MARK: - Filtro

/// Il filtro di Cerca codifiche: le condizioni che una codifica deve soddisfare per comparire tra i risultati.
///
/// Ogni campo è facoltativo: video, codec, encoder, intervallo di bitrate, VMAF medio e VMAF minimo.
/// I campi impostati compaiono come etichette sopra i risultati, e la ✕ di un'etichetta toglie
/// quella condizione. Il confronto con le codifiche lo fa sempre il codice, con i valori misurati.
struct ExperimentSearchFilter: Equatable {
    /// Una parte del nome del video originale.
    var sourceName: String?
    /// Il codec.
    var codec: VideoCodec?
    /// Il tipo di encoder.
    var backend: EncodingBackend?
    /// Il bitrate minimo, in kb/s: l'obiettivo per le codifiche a bitrate, il misurato per CRF e QP.
    var minimumBitrateKbps: Double?
    /// Il bitrate massimo, in kb/s.
    var maximumBitrateKbps: Double?
    /// Il VMAF medio minimo.
    var minimumMeanVMAF: Double?
    /// Il VMAF medio massimo.
    var maximumMeanVMAF: Double?
    /// Il VMAF minimo (fotogramma peggiore) più basso ammesso.
    var minimumLowestVMAF: Double?
    /// Il VMAF minimo (fotogramma peggiore) più alto ammesso.
    var maximumLowestVMAF: Double?

    /// I campi del filtro, uno per etichetta.
    enum Field: CaseIterable, Hashable {
        case source, codec, backend, minimumBitrate, maximumBitrate
        case minimumMeanVMAF, maximumMeanVMAF, minimumLowestVMAF, maximumLowestVMAF
    }

    /// Vero se nessun campo filtra.
    var isEmpty: Bool { labels.isEmpty }

    /// Vero se il filtro riguarda i valori misurati: allora servono esperimenti analizzati.
    var needsAnalysis: Bool {
        minimumMeanVMAF != nil || maximumMeanVMAF != nil || minimumLowestVMAF != nil || maximumLowestVMAF != nil
    }

    /// Un'etichetta: il campo e il testo mostrato.
    struct Tag: Hashable {
        let field: Field
        let text: String
    }

    /// Le etichette mostrate sopra i risultati, nell'ordine dei campi.
    var labels: [Tag] {
        func kbps(_ value: Double) -> String { MediaValueFormatter.bitRate(Int64((value * 1000).rounded())) }
        func vmaf(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1))) }

        var labels: [Tag] = []
        func add(_ field: Field, _ text: String) { labels.append(Tag(field: field, text: text)) }
        if let sourceName { add(.source, "Video: \(sourceName)") }
        if let codec { add(.codec, codec.title) }
        if let backend { add(.backend, backend == .hardware ? "Hardware" : "Software") }
        if let minimumBitrateKbps { add(.minimumBitrate, "Bitrate ≥ \(kbps(minimumBitrateKbps))") }
        if let maximumBitrateKbps { add(.maximumBitrate, "Bitrate ≤ \(kbps(maximumBitrateKbps))") }
        if let minimumMeanVMAF { add(.minimumMeanVMAF, "VMAF medio ≥ \(vmaf(minimumMeanVMAF))") }
        if let maximumMeanVMAF { add(.maximumMeanVMAF, "VMAF medio ≤ \(vmaf(maximumMeanVMAF))") }
        if let minimumLowestVMAF { add(.minimumLowestVMAF, "VMAF minimo ≥ \(vmaf(minimumLowestVMAF))") }
        if let maximumLowestVMAF { add(.maximumLowestVMAF, "VMAF minimo ≤ \(vmaf(maximumLowestVMAF))") }
        return labels
    }

    /// Toglie un campo dal filtro (la ✕ di un'etichetta).
    mutating func remove(_ field: Field) {
        switch field {
        case .source: sourceName = nil
        case .codec: codec = nil
        case .backend: backend = nil
        case .minimumBitrate: minimumBitrateKbps = nil
        case .maximumBitrate: maximumBitrateKbps = nil
        case .minimumMeanVMAF: minimumMeanVMAF = nil
        case .maximumMeanVMAF: maximumMeanVMAF = nil
        case .minimumLowestVMAF: minimumLowestVMAF = nil
        case .maximumLowestVMAF: maximumLowestVMAF = nil
        }
    }

    /// Vero se un esperimento soddisfa il filtro.
    ///
    /// - Parameters:
    ///   - settings: Le impostazioni di codifica.
    ///   - sourceName: Il nome del video originale.
    ///   - measuredKbps: Il bitrate video misurato, in kb/s; `nil` se non ancora codificato.
    ///   - meanVMAF: Il VMAF medio dell'ultima analisi; `nil` se non analizzato.
    ///   - lowestVMAF: Il VMAF del fotogramma peggiore.
    func matches(
        settings: EncodingSettings,
        sourceName: String,
        measuredKbps: Double?,
        meanVMAF: Double?,
        lowestVMAF: Double?
    ) -> Bool {
        if let name = self.sourceName, !sourceName.localizedCaseInsensitiveContains(name) { return false }
        if let codec, settings.codec != codec { return false }
        if let backend, settings.backend != backend { return false }

        // Il bitrate di riferimento: l'obiettivo, se c'è; altrimenti il misurato.
        let bitrate = settings.effectiveRateControlMode == .bitrate ? Double(settings.videoBitrateKbps) : measuredKbps
        if minimumBitrateKbps != nil || maximumBitrateKbps != nil {
            guard let bitrate else { return false }
            if let minimumBitrateKbps, bitrate < minimumBitrateKbps { return false }
            if let maximumBitrateKbps, bitrate > maximumBitrateKbps { return false }
        }

        func within(_ value: Double?, _ lower: Double?, _ upper: Double?) -> Bool {
            guard lower != nil || upper != nil else { return true }
            guard let value else { return false }
            return value >= (lower ?? -.infinity) && value <= (upper ?? .infinity)
        }

        return within(meanVMAF, minimumMeanVMAF, maximumMeanVMAF) && within(lowestVMAF, minimumLowestVMAF, maximumLowestVMAF)
    }
}

// MARK: - Interpretazione

/// La ricerca a parole di Cerca codifiche: trasforma una frase come «HEVC via hardware su Sintel
/// con VMAF sopra 90» in un filtro (``ExperimentSearchFilter``).
///
/// La frase la interpreta il codice, con un vocabolario piccolo e chiuso: nomi dei video, codec, encoder,
/// bitrate in kb/s o Mb/s, VMAF medio e minimo, e le parole che indicano il verso («sopra», «sotto»,
/// «tra … e …»). Se nella frase resta anche una sola parola sconosciuta, la frase non viene usata a metà:
/// Apple Intelligence, se disponibile, la riscrive con il vocabolario di CodecLab, la riscrittura viene
/// mostrata all'utente e il codice la interpreta come qualsiasi altra frase. Nessun numero dei risultati
/// passa dal modello linguistico.
enum ExperimentSearch {

    /// Il risultato dell'interpretazione di una frase.
    struct Interpretation: Equatable {
        /// Il filtro ricavato dalle parole riconosciute.
        var filter = ExperimentSearchFilter()
        /// Le parole che il codice non ha riconosciuto, nell'ordine della frase.
        var unknownWords: [String] = []

        /// Vero se ogni parola della frase è stata riconosciuta.
        var isComplete: Bool { unknownWords.isEmpty }
    }

    /// Le parole che non portano condizioni: articoli, preposizioni, verbi di richiesta…
    private static let ignoredWords: Set<String> = [
        "a", "abbia", "abbiano", "agli", "ai", "al", "alla", "alle", "allo", "analisi", "cerca", "cercami",
        "che", "codec", "codifica", "codificate", "codificati", "codifiche", "con", "da", "dal", "dalla",
        "dei", "degli", "del", "della", "delle", "dello", "di", "e", "ed", "elenca", "encoder", "encoding",
        "esperimenti", "esperimento", "file", "gli", "ha", "hanno", "i", "il", "in", "l", "la", "le", "lo",
        "mostra", "mostrami", "nel", "nella", "pari", "per", "quale", "quali", "quelle", "quelli",
        "relazione", "relazioni", "sono", "su", "sul", "sulla", "trova", "trovami", "tutte", "tutti",
        "un", "una", "uno", "uguale", "valore", "valori", "via", "video", "voglio", "vorrei"
    ]

    /// La grandezza a cui si riferisce un numero.
    private enum Metric { case bitrate, meanVMAF, lowestVMAF }

    /// Il verso di una condizione.
    private enum Direction { case lowerBound, upperBound, range }

    /// Interpreta una frase con il vocabolario di CodecLab.
    ///
    /// - Parameters:
    ///   - query: La frase dell'utente.
    ///   - sourceNames: I nomi dei video originali della Libreria.
    /// - Returns: Il filtro e le parole non riconosciute.
    static func interpret(_ query: String, sourceNames: [String]) -> Interpretation {
        let words = tokens(of: normalized(query))
        var result = Interpretation()

        // 1. Il video: una parola che compare nel nome di un solo video della Libreria (estensione esclusa).
        var sourceTokenIndices: Set<Int> = []
        var mentionedSources: [String] = []
        let wordsBySource = significantWords(of: sourceNames)

        for (index, token) in words.enumerated() {
            if let source = wordsBySource.first(where: { $0.words.contains(token) })?.name {
                sourceTokenIndices.insert(index)
                if !mentionedSources.contains(source) { mentionedSources.append(source) }
            }
        }

        if mentionedSources.count == 1 {
            result.filter.sourceName = mentionedSources[0]
        } else if mentionedSources.count > 1 {
            // Più video: il filtro ne ammette uno solo, quindi la frase non è interpretabile così.
            result.unknownWords += sourceTokenIndices.sorted().map { words[$0] }
        }

        // 2. Il resto: codec, encoder, grandezze, versi e numeri.
        var codecs: Set<VideoCodec> = []
        var backends: Set<EncodingBackend> = []
        var metric: Metric?
        var metricNamedSinceLastNumber = false
        var direction: Direction?
        var index = 0

        /// Annota la grandezza nominata: "VMAF minimo" vale come VMAF minimo, in qualsiasi ordine.
        func name(_ named: Metric) {
            if named == .meanVMAF, metricNamedSinceLastNumber, metric == .lowestVMAF { return }
            metric = named
            metricNamedSinceLastNumber = true
        }

        while index < words.count {
            let token = words[index]

            if sourceTokenIndices.contains(index) || ignoredWords.contains(token) {
                index += 1
                continue
            }

            if let value = Double(token) {
                // I numeri: uno solo, o due con "tra … e …"; poi l'eventuale unità.
                var values = [value]
                var next = index + 1

                if direction == .range, next + 1 < words.count, ["e", "a"].contains(words[next]), let second = Double(words[next + 1]) {
                    values.append(second)
                    next += 2
                }

                var numberMetric = metric
                var scale = 1.0
                if next < words.count, words[next] == "kbps" || words[next] == "mbps" {
                    numberMetric = .bitrate
                    scale = words[next] == "mbps" ? 1000 : 1
                    next += 1
                } else if !metricNamedSinceLastNumber || numberMetric == nil {
                    // "almeno 90 di VMAF": la grandezza può venire dopo il numero.
                    numberMetric = metricNamed(after: next, in: words) ?? numberMetric
                }

                if let numberMetric, applies(values.map { $0 * scale }, to: numberMetric, direction: direction, filter: &result.filter) {
                    metric = numberMetric
                } else {
                    result.unknownWords += words[index..<next].map { $0 }
                }

                direction = nil
                metricNamedSinceLastNumber = false
                index = next
                continue
            }

            switch token {
            case "h264", "avc": codecs.insert(.h264)
            case "hevc": codecs.insert(.hevc)
            case "x264", "libx264": codecs.insert(.h264); backends.insert(.software)
            case "x265", "libx265": codecs.insert(.hevc); backends.insert(.software)
            case "hardware", "videotoolbox": backends.insert(.hardware)
            case "software": backends.insert(.software)
            case "bitrate", "kbps", "mbps": name(.bitrate)
            case "vmaf", "qualita", "medio", "media": name(.meanVMAF)
            case "minimo", "peggiore", "peggior", "fotogramma", "fotogrammi", "frame": name(.lowestVMAF)
            case "sopra", "oltre", "almeno", "maggiore", "superiore", "piu": direction = .lowerBound
            case "sotto", "meno", "minore", "inferiore", "massimo", "fino", "entro": direction = .upperBound
            case "tra", "fra": direction = .range
            default: result.unknownWords.append(token)
            }

            index += 1
        }

        // "H.264 e HEVC" (o "hardware e software") vuol dire entrambi: nessun filtro.
        result.filter.codec = codecs.count == 1 ? codecs.first : nil
        result.filter.backend = backends.count == 1 ? backends.first : nil
        return result
    }

    /// Mette i numeri di una condizione nel filtro.
    ///
    /// - Returns: Falso se la condizione non ha senso (VMAF oltre 100, "tra" con un solo numero,
    ///   un valore di VMAF senza verso).
    private static func applies(_ values: [Double], to metric: Metric, direction: Direction?, filter: inout ExperimentSearchFilter) -> Bool {
        if metric != .bitrate, !values.allSatisfy({ (0...100).contains($0) }) { return false }
        if metric == .bitrate, !values.allSatisfy({ $0 > 0 }) { return false }

        let bounds: (lower: Double?, upper: Double?)
        switch direction {
        case .range:
            guard values.count == 2 else { return false }
            bounds = (values.min(), values.max())
        case .lowerBound:
            bounds = (values[0], nil)
        case .upperBound:
            bounds = (nil, values[0])
        case nil:
            // "a 2000 kb/s" è un bitrate preciso; "VMAF 90" invece non dice se sopra o sotto.
            guard metric == .bitrate else { return false }
            bounds = (values[0], values[0])
        }

        switch metric {
        case .bitrate:
            if let lower = bounds.lower { filter.minimumBitrateKbps = lower }
            if let upper = bounds.upper { filter.maximumBitrateKbps = upper }
        case .meanVMAF:
            if let lower = bounds.lower { filter.minimumMeanVMAF = lower }
            if let upper = bounds.upper { filter.maximumMeanVMAF = upper }
        case .lowestVMAF:
            if let lower = bounds.lower { filter.minimumLowestVMAF = lower }
            if let upper = bounds.upper { filter.maximumLowestVMAF = upper }
        }

        return true
    }

    /// La grandezza nominata subito dopo un numero, saltando le parole senza significato.
    private static func metricNamed(after index: Int, in tokens: [String]) -> Metric? {
        for token in tokens.dropFirst(index) {
            switch token {
            case "vmaf", "qualita", "medio", "media": return .meanVMAF
            case "minimo", "peggiore", "peggior", "fotogramma", "frame": return .lowestVMAF
            case "bitrate": return .bitrate
            default:
                if !ignoredWords.contains(token) { return nil }
            }
        }
        return nil
    }

    // MARK: Parole

    /// La frase in minuscolo, senza accenti e con le espressioni comuni ridotte a una parola:
    /// "H.264" → "h264", "H.265" → "hevc", "kb/s" → "kbps", "Mb/s" → "mbps", "1,5" → "1.5", "≥" → "sopra".
    static func normalized(_ text: String) -> String {
        var text = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "it_IT")).lowercased()
        let replacements: [(pattern: String, template: String)] = [
            (#"\bh\.?\s?264\b"#, " h264 "),
            (#"\bh\.?\s?265\b"#, " hevc "),
            (#"(\d)(?=(kb|mb|mega))"#, "$1 "),
            (#"\b(kb/s|kbps|kbit/s|kbit|kb)\b"#, " kbps "),
            (#"\b(mb/s|mbps|mbit/s|mbit|mb|mega)\b"#, " mbps "),
            (#"(\d),(\d)"#, "$1.$2"),
            (#">=|≥|>"#, " sopra "),
            (#"<=|≤|<"#, " sotto ")
        ]

        for replacement in replacements {
            text = text.replacingOccurrences(of: replacement.pattern, with: replacement.template, options: .regularExpression)
        }
        return text
    }

    /// Le parole di una frase già normalizzata: lettere e cifre, e i numeri con il punto decimale.
    static func tokens(of text: String) -> [String] {
        text.matches(of: #/[a-z0-9]+(?:\.[0-9]+)?/#).map { String($0.output) }
    }

    /// Per ogni video, le parole che lo identificano: almeno tre caratteri, non solo cifre,
    /// non del vocabolario e presenti nel nome di quel solo video.
    private static func significantWords(of sourceNames: [String]) -> [(name: String, words: Set<String>)] {
        let all = sourceNames.map { name in
            (name: name, words: Set(tokens(of: normalized((name as NSString).deletingPathExtension)).filter { word in
                word.count >= 3 && Double(word) == nil && !ignoredWords.contains(word) &&
                    !["h264", "hevc", "kbps", "mbps", "hardware", "software"].contains(word)
            }))
        }

        return all.map { entry in
            let shared = all.filter { $0.name != entry.name }.reduce(into: Set<String>()) { $0.formUnion($1.words) }
            return (entry.name, entry.words.subtracting(shared))
        }
    }

    /// La parola con cui si può nominare un video nella ricerca, per esempio "Sintel" per "sintel_1080p.mov";
    /// `nil` se il nome non ha parole che lo distinguano dagli altri video.
    static func identifyingWord(of sourceName: String, among sourceNames: [String]) -> String? {
        guard let words = significantWords(of: sourceNames).first(where: { $0.name == sourceName })?.words else { return nil }
        let word = tokens(of: normalized((sourceName as NSString).deletingPathExtension)).first { words.contains($0) }
        return word.map { $0.prefix(1).uppercased() + $0.dropFirst() }
    }

    // MARK: Apple Intelligence

    /// Vero se Apple Intelligence è disponibile su questo Mac.
    static var isAppleIntelligenceAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Le caratteristiche del modello, chieste a Foundation Models, per la sezione Sistema:
    /// per esempio "Foundation Models · contesto di 8192 token · 16 lingue, italiano compreso · macOS 27.2.1".
    ///
    /// Il modello non dichiara un numero di versione: è quello incluso in macOS, di cui si indica la versione.
    static var languageModelDetail: String {
        let model = SystemLanguageModel.default
        var parts = ["Foundation Models"]

        // La dimensione del contesto si può chiedere da macOS 26.4.
        if #available(macOS 26.4, *) {
            parts.append("contesto di \(model.contextSize) token")
        }

        let languages = model.supportedLanguages.count
        if languages > 0 {
            let italian = model.supportsLocale(Locale(identifier: "it_IT"))
            parts.append("\(languages) lingue" + (italian ? ", italiano compreso" : ", italiano escluso"))
        }

        let version = ProcessInfo.processInfo.operatingSystemVersion
        parts.append("macOS \(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : ""))

        return parts.joined(separator: " · ")
    }

    /// Il motivo per cui Apple Intelligence non è disponibile, da mostrare all'utente.
    static var unavailableReason: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return ""
        case .unavailable(.deviceNotEligible):
            return "Questo Mac non supporta Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence non è attiva: si attiva in Impostazioni di Sistema › Apple Intelligence e Siri."
        case .unavailable(.modelNotReady):
            return "Il modello non è ancora pronto (per esempio è in fase di download)."
        case .unavailable:
            return "Apple Intelligence non è disponibile."
        }
    }

    /// Fa riscrivere ad Apple Intelligence una frase con il vocabolario di CodecLab.
    ///
    /// Il modello restituisce solo una frase, che poi il codice interpreta e che viene mostrata
    /// all'utente: un errore è visibile e non entra mai nei numeri.
    ///
    /// - Parameters:
    ///   - query: La frase dell'utente.
    ///   - sourceNames: I nomi dei video originali della Libreria.
    /// - Returns: La frase riscritta, su una riga.
    static func rewrite(_ query: String, sourceNames: [String]) async throws -> String {
        let instructions = """
            Riscrivi la richiesta dell'utente usando solo queste espressioni: \
            il nome di un video (\(sourceNames.isEmpty ? "nessun video disponibile" : sourceNames.joined(separator: "; "))), \
            H.264, HEVC, hardware, software, bitrate in kb/s o Mb/s, VMAF medio, VMAF minimo (il fotogramma peggiore), \
            sopra, sotto, tra … e …. Scrivi i numeri in cifre. \
            Se la richiesta parla di buona qualità senza un numero, usa "VMAF medio sopra 90". \
            Non aggiungere condizioni che la richiesta non contiene. Rispondi solo con la frase riscritta.
            Esempi:
            "roba fatta col chip sotto i due mega" → "hardware sotto 2 Mb/s"
            "codifiche non hardware" → "software"
            "x265 con almeno novanta di vmaf" → "HEVC software VMAF medio sopra 90"
            """

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: query, options: GenerationOptions(samplingMode: .greedy))

        return response.content
            .split(whereSeparator: \.isNewline).first.map { String($0) }?
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"«»“”'"))
            ?? ""
    }
}
