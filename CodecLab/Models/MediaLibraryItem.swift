// MediaLibraryItem.swift
// Elemento della Libreria (con le tracce che contiene) e gestione dei bookmark che permettono di ritrovare i file.

import Foundation
import UniformTypeIdentifiers

/// Un file della Libreria: il video (o l'audio) originale da cui partono tutti gli esperimenti.
///
/// Si aggiunge con «Aggiungi file…», con ⌘O o trascinandolo dal Finder. All'aggiunta CodecLab ne legge
/// con FFprobe le caratteristiche principali (se ha video e audio, risoluzione, frame rate, durata),
/// così le sezioni possono proporre solo i file adatti e limitare gli spezzoni alla durata del file
/// senza riaprirlo ogni volta.
///
/// Il file non viene copiato: viene ritrovato tramite bookmark (``Bookmark``), anche se nel frattempo
/// è stato spostato o rinominato.
struct MediaLibraryItem: Identifiable, Codable {
    /// L'identificativo dell'elemento, a cui fanno riferimento gli esperimenti.
    let id: UUID
    /// Il nome del file al momento dell'importazione.
    let name: String
    /// La data di importazione.
    let dateAdded: Date
    /// Il bookmark del file.
    var bookmarkData: Data

    /// Vero se il file ha una traccia video (le copertine dei file audio non contano).
    ///
    /// Gli Esperimenti video propongono solo i file con video.
    let hasVideo: Bool
    /// Vero se il file ha almeno una traccia audio.
    ///
    /// Gli Esperimenti audio propongono solo i file con audio.
    let hasAudio: Bool

    /// L'ultima scansione dei fotogrammi I/P/B, se è stata eseguita.
    var frameTypeScan: SourceAnalysisResult?

    /// L'ultima misura della difficoltà di compressione, se è stata eseguita.
    ///
    /// Manca nei file aggiunti prima che venisse registrata: si ottiene dalla Libreria.
    var complexityMeasurement: ComplexityMeasurement?

    /// L'ultimo calcolo di SI e TI, se è stato eseguito.
    var spatialTemporalMeasurement: SpatialTemporalMeasurement?

    /// Le caratteristiche della traccia video; `nil` per i file solo audio.
    ///
    /// Se mancano, vengono completate riselezionando il file nella Libreria.
    var video: VideoSummary?

    /// La durata del file, in secondi: limita lo spezzone negli esperimenti.
    ///
    /// Manca nei file aggiunti prima che venisse registrata: si completa riselezionando il file nella Libreria.
    var durationSeconds: Double?

    /// Crea l'elemento per un file appena importato.
    ///
    /// - Parameters:
    ///   - url: Il file da importare.
    ///   - document: Le informazioni lette da FFprobe.
    /// - Throws: Un errore se non è possibile creare il bookmark del file.
    init(url: URL, document: FFprobeDocument) throws {
        id = UUID()
        name = url.lastPathComponent
        dateAdded = Date()
        bookmarkData = try Bookmark.create(for: url)
        hasVideo = document.videoStream != nil
        hasAudio = document.hasAudio
        video = VideoSummary(document: document)
        durationSeconds = document.format?.durationSeconds
    }
}

/// Le caratteristiche del video originale che servono spesso: risoluzione, frame rate, bitrate
/// e se è compresso o no.
///
/// Sono lette una volta, all'aggiunta del file alla Libreria, e servono per esempio a proporre il GOP
/// consigliato o a dire nella relazione se l'originale è già compresso.
struct VideoSummary: Codable, Equatable {
    /// La larghezza, in pixel.
    let width: Int
    /// L'altezza, in pixel.
    let height: Int
    /// Il frame rate.
    let framesPerSecond: Double
    /// Il bitrate della traccia video (o, se non è noto, dell'intero file), in bit al secondo.
    let bitrateBitsPerSecond: Int64?
    /// Vero se il video non è compresso, come nei file .y4m.
    let isUncompressed: Bool

    /// Ricava le caratteristiche dalla traccia video del documento.
    ///
    /// - Parameter document: Le informazioni lette da FFprobe.
    /// - Returns: `nil` se il file non ha video o non se ne conoscono risoluzione e frame rate.
    init?(document: FFprobeDocument) {
        guard let stream = document.videoStream,
              let width = stream.width, let height = stream.height,
              let fps = stream.frameRate, fps > 0 else {
            return nil
        }

        self.width = width
        self.height = height
        framesPerSecond = fps
        bitrateBitsPerSecond = stream.bitRateBitsPerSecond ?? document.format?.bitRateBitsPerSecond
        isUncompressed = stream.isUncompressedVideo
    }
}

/// Gli errori che riguardano i file della Libreria e degli esperimenti, con un messaggio comprensibile:
/// per esempio un file originale spostato su un disco non collegato.
enum MediaLibraryError: LocalizedError {
    /// Il file non si trova più: cancellato, spostato su un disco scollegato o non accessibile.
    case fileNotReachable(name: String)
    /// L'elemento è stato rimosso dalla Libreria.
    case itemNotFound

    /// Il messaggio mostrato all'utente.
    var errorDescription: String? {
        switch self {
        case .fileNotReachable(let name):
            "Il file «\(name)» non è più raggiungibile."
        case .itemNotFound:
            "L'elemento non è più presente nella Libreria."
        }
    }
}

// MARK: - Bookmark

/// La creazione e la risoluzione dei bookmark: riferimenti a un file che macOS sa ritrovare
/// anche se il file viene spostato o rinominato.
///
/// CodecLab non copia i video, che possono essere molto grandi: ne ricorda la posizione con un bookmark.
/// Quando macOS segnala un bookmark come obsoleto, viene rigenerato e salvato di nuovo.
/// L'app non usa il sandbox, quindi bastano bookmark normali.
enum Bookmark {
    /// Crea il bookmark di un file.
    ///
    /// - Parameter url: Il file.
    /// - Returns: I dati del bookmark, da salvare.
    /// - Throws: Un errore se il file non esiste o non è accessibile.
    static func create(for url: URL) throws -> Data {
        try url.bookmarkData()
    }

    /// Risolve un bookmark e verifica che il file esista.
    ///
    /// - Parameters:
    ///   - data: Il bookmark. Se è obsoleto viene sostituito da uno nuovo, che il chiamante deve salvare.
    ///   - fileName: Il nome del file, usato nel messaggio di errore.
    /// - Returns: La posizione attuale del file.
    /// - Throws: ``MediaLibraryError/fileNotReachable(name:)`` se il file non è raggiungibile.
    static func resolve(_ data: inout Data, fileName: String) throws -> URL {
        var isStale = false

        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale),
              (try? url.checkResourceIsReachable()) == true else {
            throw MediaLibraryError.fileNotReachable(name: fileName)
        }

        if isStale, let refreshed = try? create(for: url) {
            data = refreshed
        }

        return url
    }
}

// MARK: - File accettati

extension MediaLibraryItem {
    /// I tipi di file che si possono aggiungere alla Libreria: video e audio riconosciuti da macOS,
    /// più i formati usati nei test di codifica che macOS non conosce (Y4M, MKV, flussi grezzi…).
    /// Immagini, PDF, testo e simili non si possono scegliere né trascinare.
    static let allowedContentTypes: [UTType] = [.audiovisualContent] +
        ["y4m", "mkv", "webm", "ivf", "h264", "264", "h265", "265", "hevc", "ts", "m2ts", "mts", "flac", "opus", "ogg", "mka"]
            .compactMap { UTType(filenameExtension: $0) }

    /// Vero se il file è di un tipo che si può aggiungere alla Libreria (dall'estensione).
    ///
    /// - Parameter url: Il file.
    static func isSupportedFile(_ url: URL) -> Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return allowedContentTypes.contains { type.conforms(to: $0) }
    }
}
