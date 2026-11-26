// CodecLabApp.swift
// Punto di ingresso e finestra principale: barra laterale (Sistema, Libreria, Video, Audio, Apple Intelligence),
// e avviso se mancano strumenti essenziali.

import SwiftUI
import UniformTypeIdentifiers

/// Il punto di ingresso di CodecLab: apre la finestra principale e, su richiesta, le finestre dei grafici ingranditi.
///
/// Crea una sola volta lo stato condiviso, ``AppViewModel``, e lo passa a tutte le finestre, così ogni sezione
/// vede gli stessi file, esperimenti e analisi. Aggiunge anche il comando Archivio › Aggiungi file… (⌘O).
@main
struct CodecLabApp: App {
    /// Lo stato dell'app, messo a disposizione di tutte le viste tramite l'ambiente.
    @State private var appModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
        }
        .commands {
            // Archivio › Aggiungi file… (⌘O), al posto di «Nuova finestra».
            CommandGroup(replacing: .newItem) {
                Button("Aggiungi file…") {
                    appModel.isFileImporterPresented = true
                }
                .keyboardShortcut("o")
                .disabled(!appModel.canAddFiles)
            }
        }

        // I grafici ingranditi, ciascuno nella sua finestra (vedi ``ChartWindowView``).
        WindowGroup("Grafico", for: ChartWindowRequest.self) { $request in
            ChartWindowView(request: request)
                .environment(appModel)
        }
        .defaultSize(width: 1200, height: 800)
    }
}

/// Le sezioni elencate nella barra laterale, nell'ordine in cui si lavora.
///
/// Si parte da Sistema (gli strumenti installati) e Libreria (i file originali), si prosegue con gli esperimenti
/// video e audio e con l'analisi della qualità, e si arriva alle relazioni e alla ricerca.
enum ContentSection: Hashable {
    /// I file importati e le loro informazioni.
    case library
    /// Gli esperimenti video: configurazione, codifica, serie di confronto.
    case experiments
    /// L'analisi qualità: metriche, curve, fotogrammi peggiori.
    case analysis
    /// Gli esperimenti audio.
    case audio
    /// La ricerca a parole tra esperimenti, analisi e relazioni, con Apple Intelligence.
    case search
    /// La relazione su un file originale: il punto d'arrivo del lavoro.
    case report
    /// Il Mac in uso e lo stato di FFmpeg e dei suoi componenti; è la sezione iniziale.
    case system
}

/// La finestra principale: a sinistra la barra laterale con le sezioni, a destra la sezione scelta.
///
/// Oltre a mostrare le sezioni, la finestra si occupa di ciò che vale per tutte:
/// - un avviso in cima se mancano FFmpeg, FFprobe o libvmaf, con il collegamento a Sistema;
/// - la finestra per aggiungere un file alla Libreria;
/// - i messaggi di errore;
/// - l'indicatore della coda dei lavori nella barra degli strumenti.
///
/// Gestisce anche i collegamenti tra le sezioni, per esempio «Vedi analisi» da un esperimento
/// o «Vedi la relazione su questo file» da un'analisi.
struct ContentView: View {
    @Environment(AppViewModel.self) private var appModel

    /// La sezione mostrata.
    @State private var selectedSection: ContentSection? = .system
    /// L'analisi da mostrare aprendo Analisi qualità con «Vedi analisi»; torna `nil` dopo lo scorrimento.
    @State private var analysisToShowID: UUID?

    /// Vero se c'è un errore da mostrare; chiudere l'avviso cancella il messaggio.
    private var isErrorPresented: Binding<Bool> {
        Binding(
            get: { appModel.errorMessage != nil },
            set: { if !$0 { appModel.dismissError() } }
        )
    }

    var body: some View {
        NavigationSplitView {
            // Sistema in cima; poi l'ordine segue il lavoro: file → esperimenti → analisi → relazione.
            List(selection: $selectedSection) {
                Label("Sistema", systemImage: "desktopcomputer")
                    .tag(ContentSection.system)

                Label("Libreria", systemImage: "film.stack")
                    .tag(ContentSection.library)

                Section("Video") {
                    Label("Esperimenti video", systemImage: "testtube.2")
                        .tag(ContentSection.experiments)

                    Label("Analisi qualità", systemImage: "waveform.path.ecg")
                        .tag(ContentSection.analysis)
                }

                Section("Audio") {
                    Label("Esperimenti audio", systemImage: "waveform")
                        .tag(ContentSection.audio)
                }

                // Apple Intelligence traduce in un filtro le frasi della ricerca.
                Section("Apple Intelligence") {
                    Label("Relazioni", systemImage: "doc.text")
                        .tag(ContentSection.report)

                    Label("Cerca codifiche", systemImage: "magnifyingglass")
                        .tag(ContentSection.search)
                }
            }
            .navigationTitle("CodecLab")
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)

        } detail: {
            VStack(spacing: 0) {
                toolsWarning

                // Senza selezione (per esempio dopo un clic nel vuoto della barra) si mostra Sistema.
                switch selectedSection ?? .system {
                case .library:
                    LibraryView()

                case .experiments:
                    ExperimentsView { analysisID in
                        analysisToShowID = analysisID
                        selectedSection = .analysis
                    }

                case .analysis:
                    AnalysisView(analysisToShowID: $analysisToShowID) { sourceID in
                        appModel.focusedSourceID = sourceID
                        selectedSection = .report
                    }

                case .audio:
                    AudioView { sourceID in
                        appModel.focusedSourceID = sourceID
                        selectedSection = .report
                    }

                case .search:
                    SearchView { analysisID in
                        analysisToShowID = analysisID
                        selectedSection = .analysis
                    } onShowReport: { sourceID in
                        appModel.focusedSourceID = sourceID
                        selectedSection = .report
                    }

                case .report:
                    ReportView()

                case .system:
                    SystemView()
                }
            }
            // Tutte le scritte delle sezioni si possono selezionare e copiare.
            // La barra laterale resta esclusa: lì il clic sceglie la sezione.
            .textSelection(.enabled)
            // Lo stato della coda, visibile da ogni sezione mentre c'è un lavoro.
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    QueueToolbarIndicator()
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .fileImporter(
            isPresented: Binding(
                get: { appModel.isFileImporterPresented },
                set: { appModel.isFileImporterPresented = $0 }
            ),
            allowedContentTypes: MediaLibraryItem.allowedContentTypes,   // Solo video e audio: il resto è in grigio.
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                // Aggiunge il file alla Libreria, lo seleziona e mostra la Libreria
                // (il comando ⌘O si può usare da qualsiasi sezione).
                selectedSection = .library
                Task { await appModel.inspectMedia(at: url) }

            case .failure(let error):
                appModel.errorMessage = error.localizedDescription
            }
        }
        .alert("Operazione non riuscita", isPresented: isErrorPresented) {
            Button("OK") {
                appModel.dismissError()
            }
        } message: {
            Text(appModel.errorMessage ?? "Errore sconosciuto")
        }
        // La verifica degli strumenti parte all'apertura della finestra.
        .task {
            await appModel.checkTools()
        }
    }

    // MARK: - Avviso strumenti

    /// Se manca qualcosa di essenziale, lo si vede in ogni sezione, senza dover aprire Sistema.
    private var toolsWarningMessage: String? {
        guard appModel.hasCheckedTools, !appModel.isCheckingTools else { return nil }

        if !appModel.areToolsAvailable {
            return "FFmpeg o FFprobe non trovati in /opt/homebrew/bin: codifiche e analisi non sono disponibili."
        }

        if appModel.isLibVMAFAvailable == false {
            return "FFmpeg non include libvmaf: l'analisi qualità non è disponibile."
        }

        return nil
    }

    /// La striscia di avviso in cima, se mancano strumenti essenziali.
    @ViewBuilder
    private var toolsWarning: some View {
        if let message = toolsWarningMessage {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)

                Text(message)
                    .font(.callout)

                Spacer()

                if selectedSection != .system {
                    Button("Vedi Sistema") {
                        selectedSection = .system
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.yellow.opacity(0.15))
        }
    }
}
