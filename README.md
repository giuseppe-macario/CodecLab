# CodecLab

Un laboratorio per Mac che codifica i video in H.264 (AVC) e H.265 (HEVC), misura la qualità delle codifiche e spiega i risultati in una relazione.

Comprimere un video vuol dire scegliere un codec, un encoder e un bitrate, e ogni scelta cambia qualità, dimensione del file e tempo di codifica. CodecLab mostra queste differenze con i numeri, sullo stesso video.

## Cosa fa

- **Analizza** il video originale: struttura dei fotogrammi I, P e B, SI e TI (ITU-T P.910) e bitrate di una codifica di prova.
- **Codifica** lo stesso video con configurazioni diverse, via hardware (VideoToolbox di Apple Silicon) o via software (x264 e x265 con FFmpeg), in una coda di lavori. «Crea serie» prepara da sola otto codifiche, con bitrate adatti al video, per confrontare le codifiche hardware e software.
- **Misura** la qualità di ogni codifica rispetto all'originale con VMAF, PSNR e SSIM, calcolati da libvmaf.
- **Mostra** curve qualità/bitrate, BD-rate e l'andamento di VMAF, QP e dimensione dei fotogrammi lungo il video, con il confronto visivo dei fotogrammi.
- **Scrive** una relazione per ogni file: fatti misurati, classifica per VMAF medio e codifica migliore secondo un criterio dichiarato, anche con Apple Intelligence¹.
- **Esperimenti audio** in AAC e **ricerca a parole** tra le codifiche, anche con Apple Intelligence¹.

¹: Apple Intelligence è facoltativa e deve essere attivata in macOS.

## Requisiti

- macOS 26 o successivo, su un Mac con chip Apple.
- Xcode, per compilare l'app.
- FFmpeg di Homebrew (include libvmaf):

  ```sh
  brew install ffmpeg
  ```

  CodecLab cerca `ffmpeg` e `ffprobe` in `/opt/homebrew/bin`. La sezione Sistema dell'app mostra se manca qualcosa.

## Compilare ed eseguire

1. Apri `CodecLab.xcodeproj` in Xcode.
2. Scegli lo schema **CodecLab** e premi ⌘R.

I test si eseguono in Xcode con ⌘U e non avviano FFmpeg.

## Documentazione

La documentazione del codice è scritta nei commenti, in stile Apple, e in Xcode si genera con **Product › Build Documentation**. Si può anche scaricare in formato HTML, o pubblicare su GitHub Pages, con il workflow **Documentazione e app** (scheda Actions) da avviare manualmente.

## Download

Il workflow **Documentazione e app** genera la [documentazione disponibile su GitHub Pages](https://giuseppe-macario.github.io/CodecLab/documentation/codeclab/) e il [file eseguibile dell'applicazione](https://github.com/giuseppe-macario/CodecLab/releases).

## Struttura del progetto

| Cartella | Contenuto |
|---|---|
| `CodecLab/App` | Punto di ingresso, stato condiviso e coda dei lavori |
| `CodecLab/Models` | File della Libreria, esperimenti, impostazioni e risultati delle analisi |
| `CodecLab/Services` | Esecuzione di FFmpeg e FFprobe, lettura dei risultati, calcoli e relazione |
| `CodecLab/Views` | Sezioni della finestra e grafici |
| `CodecLabTests` | Test con Swift Testing |
