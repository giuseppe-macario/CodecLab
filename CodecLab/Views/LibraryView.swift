// LibraryView.swift
// Sezione Libreria: i file importati a sinistra; a destra le informazioni del file selezionato
// (contenitore, tracce, bitrate) e la scansione dei fotogrammi I/P/B.

import SwiftUI

/// La sezione Libreria: i file originali su cui lavorare.
///
/// A sinistra l'elenco dei file, con «Aggiungi file…» e «Rimuovi file» in cima; si possono anche
/// trascinare i file dal Finder. A destra le informazioni del file selezionato: contenitore, tracce,
/// bitrate e la scansione dei fotogrammi I, P e B. Rimuovere un file non lo cancella dal disco,
/// ma elimina gli esperimenti fatti su di esso, dopo una conferma.
struct LibraryView: View {
    @Environment(AppViewModel.self) private var appModel

    /// L'altezza fissa delle righe dell'elenco.
    private static let rowHeight: CGFloat = 40

    /// Il file selezionato che non si trova più.
    @State private var unavailableItem: MediaLibraryItem?
    /// Vero mentre è aperto l'avviso sul file non raggiungibile.
    @State private var isUnavailableAlertPresented = false

    /// Il file da rimuovere, se ha esperimenti: la rimozione va confermata.
    @State private var itemToRemove: MediaLibraryItem?
    /// Vero mentre è aperta la conferma della rimozione.
    @State private var isRemoveConfirmationPresented = false

    /// La selezione coincide con il file aperto: sceglierne uno ne legge le informazioni.
    private var selection: Binding<UUID?> {
        Binding(
            get: { appModel.inspectedItemID },
            set: { id in
                guard let id, id != appModel.inspectedItemID,
                      let item = appModel.libraryItems.first(where: { $0.id == id }) else {
                    return
                }

                openItem(item)
            }
        )
    }

    var body: some View {
        Group {
            // Libreria vuota: un solo invito, al centro. Altrimenti l'elenco e le informazioni del file.
            if appModel.libraryItems.isEmpty {
                ContentUnavailableView {
                    Label("La libreria è vuota", systemImage: "film.stack")
                } description: {
                    Text("Importa un file video o audio per iniziare.")
                } actions: {
                    addFileButton
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    VStack(spacing: 0) {
                        // In cima all'elenco: aggiungere e rimuovere file.
                        HStack {
                            addFileButton

                            Button("Rimuovi file") {
                                requestRemovalOfSelectedItem()
                            }
                            .disabled(appModel.inspectedItemID == nil)
                            .help("Rimuovi dalla Libreria il file selezionato, con i suoi esperimenti; il file originale non viene cancellato (anche con il tasto Elimina o il clic destro)")

                            Spacer()
                        }
                        .controlSize(.small)
                        .padding(8)

                        Divider()

                        fileList
                    }
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 400)

                    SourceDetailView()
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        // Si possono anche trascinare i file dal Finder: solo video e audio, gli altri vengono rifiutati.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(MediaLibraryItem.isSupportedFile)
            guard appModel.canAddFiles, !files.isEmpty else { return false }

            Task {
                for url in files {
                    await appModel.inspectMedia(at: url)
                }
            }
            return true
        }
        .navigationTitle("Libreria")
        .alert(
            "File originale non raggiungibile",
            isPresented: $isUnavailableAlertPresented
        ) {
            Button(unavailableItemHasExperiments ? "Rimuovi file ed esperimenti" : "Rimuovi dalla Libreria", role: .destructive) {
                if let item = unavailableItem {
                    appModel.removeFromLibrary(id: item.id)
                }

                unavailableItem = nil
            }

            Button("Annulla", role: .cancel) {
                unavailableItem = nil
            }
        } message: {
            Text(
                "CodecLab non riesce a raggiungere «\(unavailableItem?.name ?? "il file selezionato")». Il file potrebbe essere stato spostato, rinominato o trovarsi su un disco non collegato. Se confermi, l'elemento verrà rimosso dalla Libreria\(unavailableItem.map { removalDetails(for: $0) } ?? ".")"
            )
        }
        .confirmationDialog(
            "Rimuovere «\(itemToRemove?.name ?? "il file")» dalla Libreria?",
            isPresented: $isRemoveConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Rimuovi file ed esperimenti", role: .destructive) {
                if let item = itemToRemove {
                    appModel.removeFromLibrary(id: item.id)
                }

                itemToRemove = nil
            }

            Button("Annulla", role: .cancel) {
                itemToRemove = nil
            }
        } message: {
            Text("Il file verrà rimosso\(itemToRemove.map { removalDetails(for: $0) } ?? ".")")
        }
    }

    /// Pulsante «Rimuovi file», menu contestuale e tasto Elimina passano tutti da qui:
    /// se il file ha esperimenti, la rimozione va confermata.
    private func requestRemoval(of item: MediaLibraryItem) {
        if appModel.dependents(ofLibraryItem: item.id).isEmpty {
            appModel.removeFromLibrary(id: item.id)
        } else {
            itemToRemove = item
            isRemoveConfirmationPresented = true
        }
    }

    /// Chiede di rimuovere il file selezionato, se c'è.
    private func requestRemovalOfSelectedItem() {
        if let item = appModel.libraryItems.first(where: { $0.id == appModel.inspectedItemID }) {
            requestRemoval(of: item)
        }
    }

    /// Vero se dal file non raggiungibile dipendono esperimenti.
    private var unavailableItemHasExperiments: Bool {
        unavailableItem.map { !appModel.dependents(ofLibraryItem: $0.id).isEmpty } ?? false
    }

    /// Completa la frase "…verrà rimosso dalla Libreria" con ciò che sparisce insieme al file.
    ///
    /// - Parameter item: Il file da rimuovere.
    /// - Returns: Il resto della frase, dal punto in cui si interrompe.
    private func removalDetails(for item: MediaLibraryItem) -> String {
        let dependents = appModel.dependents(ofLibraryItem: item.id)
        let experiments = dependents.isEmpty
            ? ""
            : " insieme a \(dependents.description); i file codificati verranno spostati nel Cestino"

        return experiments + ". Il file originale non verrà cancellato."
    }

    // MARK: - Elenco dei file

    /// Il pulsante per aggiungere un file: al centro se la Libreria è vuota, in cima all'elenco altrimenti.
    private var addFileButton: some View {
        Button("Aggiungi file…") {
            appModel.isFileImporterPresented = true
        }
        // Senza FFprobe non si potrebbe leggere il file.
        .disabled(!appModel.canAddFiles)
        .help("Aggiungi un file video o audio (⌘O, oppure trascinalo qui dal Finder)")
    }

    /// L'elenco dei file.
    private var fileList: some View {
        List(selection: selection) {
            ForEach(appModel.libraryItems) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.hasVideo ? "film" : "waveform")
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .lineLimit(1)

                        Text(item.dateAdded.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                // Altezza fissa: le righe hanno sempre nome e data. Con un'altezza calcolata,
                // una riga inserita in cima e selezionata subito veniva disegnata troppo bassa.
                .frame(height: Self.rowHeight)
                .tag(item.id)
                .contextMenu {
                    Button("Rimuovi dalla libreria", role: .destructive) {
                        requestRemoval(of: item)
                    }
                }
            }
        }
        .environment(\.defaultMinListRowHeight, Self.rowHeight)
        // Nell'elenco il clic seleziona il file: qui le scritte non sono selezionabili.
        .textSelection(.disabled)
        .onDeleteCommand {
            requestRemovalOfSelectedItem()
        }
    }

    // MARK: - Apertura di un file

    /// Apre un file della Libreria; se non si trova più, mostra l'avviso che propone di rimuoverlo.
    ///
    /// - Parameter item: Il file.
    private func openItem(_ item: MediaLibraryItem) {
        Task {
            do {
                _ = try await appModel.openLibraryItem(item)
            } catch MediaLibraryError.fileNotReachable {
                unavailableItem = item
                isUnavailableAlertPresented = true
            } catch {
                appModel.errorMessage = error.localizedDescription
            }
        }
    }
}
