# ``CodecLab``

Un laboratorio per Mac che codifica i video in H.264 e HEVC, misura la qualità delle codifiche e spiega i risultati in una relazione.

## Overview

Comprimere un video vuol dire scegliere: con quale codec (H.264 o HEVC), con quale encoder (il blocco video del chip Apple, veloce, oppure x264 e x265 sulla CPU, lenti ma più efficienti) e con quanti bit al secondo. Ogni scelta cambia la qualità, la dimensione del file e il tempo di codifica. CodecLab serve a vedere queste differenze con i numeri, sullo stesso video, invece di indovinarle.

L'app fa quattro cose:

- **Codifica** lo stesso video con configurazioni diverse, una alla volta, in una coda di lavori che si può mettere in pausa o annullare. Con «Crea serie» prepara da sola otto codifiche che bastano per un confronto completo tra hardware e software.
- **Misura** la qualità di ogni codifica confrontandola fotogramma per fotogramma con l'originale, con tre metriche: VMAF, che stima la qualità percepita da uno spettatore, PSNR e SSIM.
- **Mostra** i risultati in grafici: la curva qualità/bitrate di ogni configurazione, il BD-rate (quanto bitrate risparmia una configurazione rispetto a un'altra, a parità di qualità), il VMAF, il QP e la dimensione di ogni fotogramma lungo il video.
- **Scrive** una relazione per ogni file originale: i fatti misurati, una classifica per VMAF medio e la codifica migliore tra quelle provate, scelta con un criterio dichiarato.

CodecLab non elabora i video da solo: si appoggia a FFmpeg e FFprobe, installati con Homebrew. FFprobe legge le caratteristiche dei file. FFmpeg esegue le codifiche software, con x264 e x265, e le analisi della qualità, con libvmaf; per le codifiche hardware, invece, fa da tramite verso VideoToolbox, cioè il blocco video del chip Apple, che svolge il lavoro vero e proprio (lo stesso vale per l'encoder AAC di Apple, AudioToolbox). CodecLab prepara i comandi, li esegue in coda e ne legge i risultati.

### Come si usa

1. In **Sistema** si controlla che FFmpeg, FFprobe, libvmaf e gli encoder hardware siano disponibili.
2. In **Libreria** si aggiunge un file video (o audio): CodecLab ne legge contenitore, tracce e bitrate. Con «Avvia analisi» esamina il video originale: struttura dei fotogrammi I, P e B, SI e TI (ITU-T P.910) e bitrate di una codifica di prova.
3. In **Esperimenti video** si sceglie il file e si crea una serie hardware / software, oppure singoli esperimenti con impostazioni a scelta. Codifiche e analisi partono in coda.
4. In **Analisi qualità** si leggono curve, BD-rate e grafici di ogni codifica, e si confrontano a occhio i fotogrammi con l'originale.
5. In **Relazioni** si legge la sintesi del lavoro su un file, da copiare o salvare in Markdown.

**Esperimenti audio** misura invece il peso della traccia audio a diversi bitrate AAC, e **Cerca codifiche** trova le codifiche scrivendo una frase, per esempio «HEVC via hardware con VMAF sopra 90».

### Requisiti

- macOS 26 o successivo, su un Mac con chip Apple.
- FFmpeg e FFprobe di Homebrew, in `/opt/homebrew/bin`, con libvmaf per l'analisi della qualità.
- Apple Intelligence è facoltativa e deve essere attivata in macOS.

### Come è organizzato il codice

Il progetto è diviso in quattro cartelle, che corrispondono agli argomenti qui sotto:

- **App**: il punto di ingresso, lo stato condiviso (``AppViewModel``) e la coda dei lavori (``JobQueue``).
- **Models**: i dati, cioè file della Libreria, esperimenti, impostazioni di codifica e risultati delle analisi, salvati in file JSON.
- **Services**: il lavoro vero e proprio, cioè l'esecuzione di FFmpeg e FFprobe, la lettura dei loro risultati e i calcoli (BD-rate, classifica, relazione, ricerca).
- **Views**: le sezioni della finestra e i grafici.

Le viste non eseguono mai FFmpeg direttamente: chiedono ad ``AppViewModel``, che prepara il lavoro, lo mette in coda e ne salva il risultato. I calcoli sui risultati sono funzioni senza stato, verificate dai test.

## Topics

### L'app e il suo stato

- ``CodecLabApp``
- ``ContentView``
- ``ContentSection``
- ``AppViewModel``

### La coda dei lavori

- ``JobQueue``
- ``ActiveJob``
- ``QueuedJob``
- ``PreparedJob``
- ``JobContext``

### File della Libreria

- ``MediaLibraryItem``
- ``VideoSummary``
- ``Bookmark``
- ``MediaLibraryError``
- ``FFprobeDocument``
- ``FFprobeStream``
- ``FFprobeFormat``

### Analisi del video originale

- ``SourceAnalysisResult``
- ``SpatialTemporalInfo``
- ``SpatialTemporalSummary``
- ``SpatialTemporalMeasurement``
- ``ComplexityProbe``
- ``ComplexityMeasurement``
- ``FileFingerprint``

### Esperimenti e impostazioni di codifica

- ``EncodingExperiment``
- ``EncodingSettings``
- ``VideoCodec``
- ``VideoProfile``
- ``EncodingBackend``
- ``EncodingRateControlMode``
- ``AudioEncodingMode``
- ``ClipRange``
- ``ComparisonSeries``
- ``ExperimentStatus``
- ``EncodingOutputInfo``
- ``AudioExperiment``
- ``AudioEncoder``
- ``AudioOutputInfo``

### Codifica e strumenti esterni

- ``EncodingService``
- ``AudioEncodingService``
- ``FFmpegProcessRunner``
- ``FFmpegProcessControl``
- ``FFprobeService``
- ``MediaToolService``
- ``MediaToolStatus``
- ``MediaToolPaths``
- ``AppError``

### Analisi della qualità

- ``QualityAnalysisService``
- ``VideoQualityAnalysisResult``
- ``VMAFReport``
- ``QualityMetricSummary``
- ``FrameQuantizationSample``
- ``FrameQuantizationParser``
- ``FrameSizeStatistics``
- ``VideoFrameTypeSummary``

### Curve, BD-rate e relazione

- ``QualityCurvePoint``
- ``QualityCurveGroup``
- ``QualityCurveGroupBuilder``
- ``QualityCurveMetric``
- ``BDRate``
- ``QualityInsights``
- ``ReportBuilder``
- ``AnalysisReport``
- ``ReportSection``
- ``ReportTable``

### Ricerca

- ``ExperimentSearch``
- ``ExperimentSearchFilter``

### Sezioni della finestra

- ``SystemView``
- ``LibraryView``
- ``SourceDetailView``
- ``ExperimentsView``
- ``AnalysisView``
- ``AudioView``
- ``ReportView``
- ``SearchView``

### Grafici e componenti condivisi

- ``QualityCurveChartView``
- ``FrameTimelineView``
- ``FrameQuantizationView``
- ``FrameComparisonView``
- ``ChartWindowView``
- ``ChartWindowRequest``
- ``QueueToolbarIndicator``
- ``QueueStatusView``
- ``ClipEditor``
- ``MediaValueFormatter``

### Salvataggio

- ``JSONStore``
