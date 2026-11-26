// JSONStore.swift
// Salva e carica un elenco di elementi in un file JSON in ~/Library/Application Support/CodecLab
// (o in un'altra cartella, per i test).

import Foundation

/// Un elenco di elementi salvato in un file JSON: è il modo in cui CodecLab conserva i dati tra un avvio e l'altro.
///
/// Libreria, esperimenti video e audio e analisi hanno ciascuno il proprio file, nella cartella
/// Application Support. Ogni salvataggio riscrive il file per intero, in modo atomico: se l'app si chiude
/// a metà, resta la versione precedente. Un file illeggibile non viene sovrascritto ma messo da parte.
final class JSONStore<Element: Codable> {
    /// Il nome del file, per esempio "EncodingExperiments.json".
    let fileName: String
    /// La cartella del file.
    let directory: URL

    /// Vero se il file esistente non è leggibile e non è stato possibile metterlo da parte:
    /// in questo caso non si salva, per non sovrascriverlo.
    private var isReadOnly = false

    /// Crea un archivio; il file viene letto solo da ``load()``.
    ///
    /// - Parameters:
    ///   - fileName: Il nome del file.
    ///   - directory: La cartella del file: ~/Library/Application Support/CodecLab, o un'altra per i test.
    init(
        fileName: String,
        directory: URL = URL.applicationSupportDirectory.appendingPathComponent("CodecLab", isDirectory: true)
    ) {
        self.fileName = fileName
        self.directory = directory
    }

    private var fileURL: URL {
        directory.appendingPathComponent(fileName)
    }

    /// Legge gli elementi salvati.
    ///
    /// Se il file esiste ma non è leggibile, viene rinominato (così il salvataggio successivo
    /// non lo sovrascrive) e viene lanciato un errore che indica dove è stato spostato.
    ///
    /// - Returns: Gli elementi, o un elenco vuoto se il file non esiste.
    /// - Throws: ``AppError`` se il file non è leggibile.
    func load() throws -> [Element] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([Element].self, from: data)
        } catch {
            // Per esempio "MediaLibrary.illeggibile-1763478000.json": l'istante evita di sovrascrivere
            // una copia messa da parte in precedenza.
            let backupURL = fileURL
                .deletingPathExtension()
                .appendingPathExtension("illeggibile-\(Int(Date().timeIntervalSince1970)).json")

            do {
                try FileManager.default.moveItem(at: fileURL, to: backupURL)
            } catch {
                // Non si è riusciti a metterlo da parte: da qui in poi non si salva, per non perderlo.
                isReadOnly = true
                throw AppError("Impossibile leggere \(fileName). Le modifiche non verranno salvate.")
            }

            throw AppError(
                """
                Impossibile leggere \(fileName): \(error.localizedDescription)
                Il file è stato conservato come \(backupURL.lastPathComponent).
                """
            )
        }
    }

    /// Salva gli elementi, creando la cartella se serve.
    ///
    /// - Parameter elements: L'elenco completo da salvare.
    /// - Throws: Un errore se la scrittura non riesce, o ``AppError`` se il file
    ///   esistente non era leggibile e non è stato possibile metterlo da parte.
    func save(_ elements: [Element]) throws {
        guard !isReadOnly else {
            throw AppError("\(fileName) non è leggibile: le modifiche non vengono salvate per non sovrascriverlo.")
        }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let data = try JSONEncoder().encode(elements)
        // Scrittura atomica: un'interruzione a metà non lascia un file troncato.
        try data.write(to: fileURL, options: .atomic)
    }
}
