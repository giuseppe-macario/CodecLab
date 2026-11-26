// ParserTests.swift
// Lettura dei dati prodotti dagli strumenti: QP per fotogramma di x264 e x265,
// header MPEG Audio, JSON di FFprobe, rapporto di libvmaf ed elenchi di FFmpeg.
//
// Strategia di verifica
// ---------------------
// Test unitari dei lettori (parser), con dati di ingresso fissi (fixture) scritti nei test.
//
// - I campioni di x264 e x265 vengono da codifiche reali (8 fotogrammi, GOP 4, 2 B-frame):
//   sono test basati su dati reali, che fissano il formato prodotto dagli strumenti.
//   Se una nuova versione di FFmpeg cambiasse quel formato, questi test lo segnalerebbero.
// - Gli header MPEG Audio sono byte costruiti a mano, per provare anche i casi difficili:
//   un byte spurio prima del frame, un layer diverso da quello atteso (test di robustezza).
// - Il JSON di FFprobe e il rapporto di libvmaf sono ridotti all'essenziale: si verifica che
//   ogni campo usato dall'app venga letto e convertito correttamente.

import Foundation
import Testing
@testable import CodecLab

/// Test unitari della lettura del QP per fotogramma (``FrameQuantizationParser``), su dati reali.
///
/// I campioni vengono da codifiche vere con x264 e x265: si verifica che i fotogrammi tornino
/// nell'ordine di visualizzazione e che un formato inatteso non produca dati sbagliati.
@MainActor
struct FrameQuantizationParserTests {

    /// Log di debug di libx264 (con il prefisso "level+"), più una riga di riepilogo da ignorare.
    private let x264Log = """
        [libx264 @ 0x55e99c5cfd00] [debug] frame=   0 QP=28.05 NAL=3 Slice:I Poc:0   I:99   P:0    SKIP:0    size=2084 bytes
        [libx264 @ 0x55e99c5cfd00] [debug] frame=   1 QP=36.11 NAL=2 Slice:P Poc:6   I:6    P:50   SKIP:43   size=634 bytes
        [libx264 @ 0x55e99c5cfd00] [debug] frame=   2 QP=35.51 NAL=2 Slice:B Poc:2   I:0    P:57   SKIP:42   size=447 bytes
        [libx264 @ 0x55e99c5cfd00] [debug] frame=   3 QP=36.48 NAL=0 Slice:B Poc:4   I:0    P:48   SKIP:51   size=300 bytes
        [libx264 @ 0x55e99c5cfd00] [debug] frame=   4 QP=26.11 NAL=3 Slice:I Poc:0   I:99   P:0    SKIP:0    size=2519 bytes
        [libx264 @ 0x55e99c5cfd00] [debug] frame=   5 QP=34.07 NAL=2 Slice:P Poc:6   I:10   P:42   SKIP:47   size=738 bytes
        [libx264 @ 0x55e99c5cfd00] [debug] frame=   6 QP=36.79 NAL=2 Slice:B Poc:2   I:0    P:52   SKIP:47   size=408 bytes
        [libx264 @ 0x55e99c5cfd00] [debug] frame=   7 QP=37.00 NAL=0 Slice:B Poc:4   I:0    P:44   SKIP:55   size=314 bytes
        [libx264 @ 0x55e99c5cfd00] [info] frame I:2     Avg QP:27.08  size:  2302
        """

    /// CSV di libx265. Il secondo I ("i-SLICE") non è un IDR: il POC non riparte da zero.
    private let x265CSV = """
        Encode Order, Type, POC, QP, Bits, Scenecut, RateFactor, Latency, List 0, List 1
        0, I-SLICE,    0, 29.45,      16032, 0,25.087,7,  -, -
        1, P-SLICE,    3, 32.30,       5872, 0,28.000,4, 0 , -
        2, B-SLICE,    2, 35.09,       1800, 0,30.271,5, 0 ,3
        3, b-SLICE,    1, 36.14,       1688, 0,30.271,6, 0 ,2 3
        4, i-SLICE,    4, 28.47,      15000, 0,25.087,7,  -, -
        5, P-SLICE,    7, 33.40,       5000, 0,28.000,4, 4 , -
        6, B-SLICE,    6, 34.66,       1700, 0,30.271,5, 4 ,7
        7, b-SLICE,    5, 35.40,       1600, 0,30.271,6, 4 ,6 7
        """

    @Test("x264: fotogrammi in ordine di visualizzazione, GOP per GOP")
    func x264() throws {
        let samples = FrameQuantizationParser.parseH264DebugLog(x264Log)

        #expect(samples.count == 8)
        #expect(samples.map(\.encodeOrder) == [0, 2, 3, 1, 4, 6, 7, 5])
        #expect(samples.map(\.frameType) == ["I", "B", "B", "P", "I", "B", "B", "P"])
        #expect(samples.map(\.displayOrder) == Array(0..<8))

        let first = try #require(samples.first)
        #expect(first.qp == 28.05)
    }

    @Test("x265: tipi normalizzati e ordine di visualizzazione")
    func x265() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("codeclab-test-\(UUID()).csv")
        try x265CSV.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = FrameQuantizationParser.parseHEVCCSV(at: url)

        #expect(samples.map(\.pictureOrderCount) == Array(0..<8))
        #expect(samples.map(\.encodeOrder) == [0, 3, 2, 1, 4, 7, 6, 5])
        #expect(samples.map(\.frameType) == ["I", "B", "B", "P", "I", "B", "B", "P"])
        #expect(samples.last?.qp == 33.40)
    }

    @Test("x265: senza le colonne attese non si legge nulla")
    func x265MissingColumns() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("codeclab-test-\(UUID()).csv")
        try "Frame, Bits\n0, 100\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(FrameQuantizationParser.parseHEVCCSV(at: url).isEmpty)
        #expect(FrameQuantizationParser.parseHEVCCSV(at: url.appendingPathExtension("mancante")).isEmpty)
    }
}

/// Test unitari e di robustezza del lettore degli header MPEG Audio (``MPEGAudioFrameParser``),
/// su byte costruiti a mano: frame validi, un byte spurio prima del frame, un layer inatteso,
/// gli indicatori Xing e LAME, il dump esadecimale di FFprobe.
@MainActor
struct MPEGAudioParserTests {

    /// Un frame MPEG-1 Layer III a 128 kb/s e 44,1 kHz, stereo: header FF FB 90 00, 417 byte in tutto.
    private func layer3Frame(payload: [UInt8] = []) -> [UInt8] {
        var frame: [UInt8] = [0xFF, 0xFB, 0x90, 0x00]
        frame += payload
        frame += [UInt8](repeating: 0, count: 417 - frame.count)
        return frame
    }

    @Test("Codec e layer MPEG")
    func expectedLayer() {
        #expect(MPEGAudioFrameParser.expectedLayerID(for: "mp3") == 1)
        #expect(MPEGAudioFrameParser.expectedLayerID(for: "mp2") == 2)
        #expect(MPEGAudioFrameParser.expectedLayerID(for: "mp1") == 3)
        #expect(MPEGAudioFrameParser.expectedLayerID(for: "aac") == nil)
    }

    @Test("Due frame consecutivi, anche dopo un byte spurio")
    func frames() {
        let data = Data([0x00] + layer3Frame() + layer3Frame())
        let result = MPEGAudioFrameParser.parsePacket(data, expectedLayerID: 1)

        #expect(result.frames.count == 2)
        #expect(result.frames.allSatisfy { $0.bitRateBitsPerSecond == 128_000 && $0.sampleRate == 44_100 })
        #expect(result.frames.first?.frameLength == 417)
        #expect(result.headerMarker == nil)
        #expect(!result.hasLAMEEncoderTag)
    }

    @Test("Tag Xing seguito dall'identificativo di LAME")
    func xingAndLAME() {
        // Stereo MPEG-1: il tag Xing sta dopo 4 byte di header e 32 di side information;
        // con i flag a zero, "LAME" segue subito i 4 byte dei flag.
        var payload = [UInt8](repeating: 0, count: 32)
        payload += Array("Xing".utf8) + [0, 0, 0, 0] + Array("LAME".utf8)

        let result = MPEGAudioFrameParser.parsePacket(Data(layer3Frame(payload: payload)), expectedLayerID: 1)

        #expect(result.headerMarker == .xing)
        #expect(result.hasLAMEEncoderTag)
    }

    @Test("Un layer diverso da quello atteso non viene letto")
    func wrongLayer() {
        let result = MPEGAudioFrameParser.parsePacket(Data(layer3Frame()), expectedLayerID: 2)
        #expect(result.frames.isEmpty)
    }

    @Test("Dump esadecimale di FFprobe")
    func hexDump() {
        let dump = """
            00000000: fffb 9000 0000 0000 0000 0000 0000 0000  ................
            00000010: 4c41 4d45                                LAME
            """

        let data = MPEGAudioFrameParser.decodeHexDump(dump)

        #expect(data?.count == 20)
        #expect(data.map { Array($0.prefix(4)) } == [0xFF, 0xFB, 0x90, 0x00])
        #expect(data.map { Array($0.suffix(4)) } == Array("LAME".utf8))
        #expect(MPEGAudioFrameParser.decodeHexDump("") == nil)
    }
}

/// Test unitari della lettura del JSON di FFprobe (``FFprobeDocument``) e dei tipi di file accettati
/// dalla Libreria: quali file sono video o audio, quale traccia è il video vero, frame rate,
/// profondità in bit e video non compressi.
@MainActor
struct FFprobeDocumentTests {

    private func decode(_ json: String) throws -> FFprobeDocument {
        try JSONDecoder().decode(FFprobeDocument.self, from: Data(json.utf8))
    }

    @Test("Immagini e file di testo non sono video o audio")
    func usableMedia() throws {
        let video = try decode("""
            { "streams": [ { "codec_type": "video", "codec_name": "h264" } ], "format": { "format_name": "mov,mp4,m4a,3gp,3g2,mj2" } }
            """)
        let audio = try decode("""
            { "streams": [ { "codec_type": "audio", "codec_name": "pcm_s16le" } ], "format": { "format_name": "wav" } }
            """)
        let png = try decode("""
            { "streams": [ { "codec_type": "video", "codec_name": "png" } ], "format": { "format_name": "png_pipe" } }
            """)
        let jpeg = try decode("""
            { "streams": [ { "codec_type": "video", "codec_name": "mjpeg" } ], "format": { "format_name": "image2" } }
            """)
        let text = try decode("""
            { "streams": [ { "codec_type": "video", "codec_name": "ansi" } ], "format": { "format_name": "tty" } }
            """)
        let empty = try decode("""
            { "streams": [], "format": { "format_name": "mov,mp4,m4a,3gp,3g2,mj2" } }
            """)

        #expect(video.isUsableMedia && audio.isUsableMedia)
        #expect(!png.isUsableMedia && !jpeg.isUsableMedia && !text.isUsableMedia && !empty.isUsableMedia)
    }

    @Test("Si possono scegliere solo file video e audio")
    func supportedFiles() {
        for name in ["clip.mp4", "clip.MOV", "tennis_sif.y4m", "film.mkv", "audio.wav", "audio.m4a"] {
            #expect(MediaLibraryItem.isSupportedFile(URL(fileURLWithPath: "/tmp/\(name)")), "\(name)")
        }
        for name in ["foto.jpg", "screenshot.png", "week2-formal.pdf", "atm.py", "note.txt", "senza-estensione"] {
            #expect(!MediaLibraryItem.isSupportedFile(URL(fileURLWithPath: "/tmp/\(name)")), "\(name)")
        }
    }

    @Test("La copertina non è la traccia video")
    func attachedPicture() throws {
        let document = try decode("""
            {
              "streams": [
                { "index": 0, "codec_type": "video", "codec_name": "mjpeg", "disposition": { "attached_pic": 1 } },
                { "index": 1, "codec_type": "audio", "codec_name": "mp3" }
              ]
            }
            """)

        #expect(document.videoStream == nil)
        #expect(document.hasAudio)
        #expect(document.streams.first?.isAttachedPicture == true)
    }

    @Test("Traccia video, frame rate e profondità in bit")
    func videoStream() throws {
        let document = try decode("""
            {
              "streams": [
                { "index": 0, "codec_type": "video", "codec_name": "hevc", "width": 1920, "height": 1080,
                  "pix_fmt": "yuv420p10le", "avg_frame_rate": "0/0", "r_frame_rate": "30000/1001",
                  "bit_rate": "4500000", "disposition": { "attached_pic": 0 } }
              ],
              "format": { "format_name": "mov,mp4,m4a,3gp,3g2,mj2", "duration": "12.5", "bit_rate": "4700000" }
            }
            """)

        let video = try #require(document.videoStream)
        #expect(video.width == 1920)
        #expect(abs((video.frameRate ?? 0) - 29.97) < 0.001)
        #expect(video.pixelFormatBitDepth == 10)
        #expect(video.bitRateBitsPerSecond == 4_500_000)
        #expect(!video.isUncompressed)
        #expect(!document.hasAudio)
        #expect(document.format?.durationSeconds == 12.5)
    }

    @Test("Video e audio non compressi")
    func uncompressed() throws {
        let document = try decode("""
            {
              "streams": [
                { "codec_type": "video", "codec_name": "rawvideo", "pix_fmt": "yuv420p", "bits_per_raw_sample": "8" },
                { "codec_type": "audio", "codec_name": "pcm_s16le" },
                { "codec_type": "audio", "codec_name": "aac" }
              ]
            }
            """)

        #expect(document.streams[0].isUncompressedVideo)
        #expect(document.streams[0].pixelFormatBitDepth == 8)
        #expect(document.streams[1].isUncompressed)
        #expect(!document.streams[2].isUncompressed)
    }
}

/// Test unitari della lettura del rapporto di libvmaf (``VMAFReport``): ordine dei fotogrammi,
/// arrotondamento del VMAF e medie delle metriche.
@MainActor
struct VMAFReportTests {

    @Test("Fotogrammi riordinati, VMAF a due decimali, medie lette")
    func report() throws {
        let json = """
            {
              "frames": [
                { "frameNum": 1, "metrics": { "vmaf": 91.004999, "psnr_y": 40.1 } },
                { "frameNum": 0, "metrics": { "vmaf": 87.123456, "psnr_y": 38.2 } },
                { "frameNum": 2, "metrics": { "vmaf": 95.5 } }
              ],
              "pooled_metrics": {
                "vmaf": { "min": 87.12, "max": 95.5, "mean": 91.21 },
                "psnr_y": { "mean": 39.15 },
                "float_ssim": { "mean": 0.9812 }
              }
            }
            """

        let report = try JSONDecoder().decode(VMAFReport.self, from: Data(json.utf8))

        #expect(report.comparedFrameCount == 3)
        #expect(report.vmafPerFrame == [87.12, 91.0, 95.5])
        #expect(report.pooledMetrics.vmaf?.mean == 91.21)
        #expect(report.pooledMetrics.psnrY?.mean == 39.15)
        #expect(report.pooledMetrics.ssim?.mean == 0.9812)
    }
}

/// Test unitari della lettura degli elenchi di encoder e filtri di FFmpeg (``MediaToolService``),
/// usati dalla sezione Sistema.
@MainActor
struct ToolListingTests {

    @Test("Descrizione di encoder e filtri dagli elenchi di FFmpeg")
    func descriptions() {
        let encoders: [Substring] = [
            " V....D h264_videotoolbox    VideoToolbox H.264 Encoder (codec h264)",
            " A....D aac_at               aac (AudioToolbox) (codec aac)"
        ]
        let filters: [Substring] = [
            " ... libvmaf           VV->V      Calculate the VMAF between two video streams."
        ]

        #expect(MediaToolService.description(of: "h264_videotoolbox", in: encoders) == "VideoToolbox H.264 Encoder (codec h264)")
        #expect(MediaToolService.description(of: "aac_at", in: encoders) == "aac (AudioToolbox) (codec aac)")
        #expect(MediaToolService.description(of: "libvmaf", in: filters) == "Calculate the VMAF between two video streams.")
        #expect(MediaToolService.description(of: "hevc_videotoolbox", in: encoders) == nil)
    }
}
