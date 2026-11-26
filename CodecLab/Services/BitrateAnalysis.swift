// BitrateAnalysis.swift
// Classificazione CBR/VBR delle tracce audio e video sui primi 60 secondi del file.
// - MP1/MP2/MP3: lettura diretta degli header dei frame MPEG Audio.
// - Altri codec: stima statistica sulla dimensione dei pacchetti in finestre di 5 secondi.

import Foundation

/// La classificazione del bitrate delle tracce audio e video come costante (CBR) o variabile (VBR),
/// sui primi 60 secondi del file.
///
/// - MP1, MP2 e MP3: si leggono direttamente gli header dei frame MPEG Audio, che dichiarano il bitrate.
/// - Tutti gli altri codec: si stima dalla dimensione dei pacchetti, in finestre di 5 secondi.
extension FFprobeService {
    private static let bitrateSampleDurationSeconds = 60.0
    private static let bitrateWindowDurationSeconds = 5.0
    private static let minimumMPEGAudioFramesForDirectDetection = 10

    /// Analizza il bitrate dei primi 60 secondi di ogni traccia audio e video.
    ///
    /// Per MP1/MP2/MP3 prova prima il rilevamento diretto dai frame MPEG Audio;
    /// per gli altri codec, o se il rilevamento diretto non riesce, usa la stima statistica.
    ///
    /// - Parameters:
    ///   - mediaURL: Il file da analizzare.
    ///   - streams: Le tracce del file, lette da ``probe(_:)``.
    /// - Returns: L'analisi di ogni traccia audio e video, per indice di traccia.
    /// - Throws: Un errore se FFprobe non riesce a leggere i pacchetti.
    func analyzeBitrate(
        _ mediaURL: URL,
        streams: [FFprobeStream]
    ) async throws -> [Int: StreamBitrateAnalysis] {
        let eligibleStreams = streams.filter {
            ($0.codecType == "video" || $0.codecType == "audio") && $0.index != nil
        }
        let eligibleIndexes = Set(eligibleStreams.compactMap(\.index))

        guard !eligibleIndexes.isEmpty else { return [:] }

        let arguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-read_intervals", "%+\(Int(Self.bitrateSampleDurationSeconds))",
            "-show_packets",
            "-show_entries", "packet=stream_index,size,pts_time,dts_time,duration_time",
            "-of", "compact=p=0:nk=0",
            mediaURL.path
        ]

        let result = try await FFmpegProcessRunner.run(
            executableURL: MediaToolPaths.ffprobe,
            arguments: arguments
        )

        var packetsByStream: [Int: [FFprobePacketSample]] = [:]

        for line in result.outputText.split(whereSeparator: \.isNewline) {
            var fields: [String: String] = [:]

            for field in line.split(separator: "|", omittingEmptySubsequences: true) {
                guard let separator = field.firstIndex(of: "=") else { continue }
                let key = String(field[..<separator])
                let value = String(field[field.index(after: separator)...])
                fields[key] = value
            }

            guard
                let streamIndex = fields["stream_index"].flatMap(Int.init),
                eligibleIndexes.contains(streamIndex),
                let packetSize = fields["size"].flatMap(Int64.init),
                packetSize >= 0,
                let timestamp = fields["dts_time"].flatMap(Double.init)
                    ?? fields["pts_time"].flatMap(Double.init),
                timestamp.isFinite
            else {
                continue
            }

            let packetDuration = fields["duration_time"]
                .flatMap(Double.init)
                .flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0

            packetsByStream[streamIndex, default: []].append(
                FFprobePacketSample(
                    timestamp: timestamp,
                    duration: packetDuration,
                    sizeBytes: packetSize
                )
            )
        }

        var analyses: [Int: StreamBitrateAnalysis] = [:]

        for stream in eligibleStreams {
            guard let streamIndex = stream.index else { continue }

            guard let packets = packetsByStream[streamIndex], !packets.isEmpty else {
                analyses[streamIndex] = StreamBitrateAnalysis(
                    streamIndex: streamIndex,
                    mode: .undetermined,
                    classificationMethod: .estimated,
                    averageBitRateBitsPerSecond: nil,
                    sampledDurationSeconds: 0,
                    coefficientOfVariation: nil,
                    analyzedWindowCount: 0,
                    analyzedFrameCount: 0,
                    mpegAudioHeaderMarker: nil,
                    hasLAMEEncoderTag: false
                )
                continue
            }

            analyses[streamIndex] = Self.makeBitrateAnalysis(
                streamIndex: streamIndex,
                packets: packets,
                codecType: stream.codecType
            )
        }

        // Il rilevamento diretto viene applicato solo a MPEG Audio Layer I/II/III.
        // Se FFprobe non riesce a fornire i payload, resta disponibile la stima statistica.
        do {
            let directAnalyses = try await analyzeMPEGAudioBitrate(
                mediaURL,
                streams: eligibleStreams,
                fallbackAnalyses: analyses
            )
            analyses.merge(directAnalyses) { _, direct in direct }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Rilevamento diretto non riuscito: resta la stima statistica.
        }

        return analyses
    }

    /// Classifica le tracce MPEG Audio leggendo gli header dei loro frame.
    ///
    /// Il payload dei pacchetti arriva da FFprobe come dump esadecimale. La modalità viene
    /// classificata osservando il bitrate index dei frame, non la dimensione dei pacchetti
    /// né il solo indicatore Xing/Info/VBRI.
    ///
    /// - Parameters:
    ///   - mediaURL: Il file da analizzare.
    ///   - streams: Le tracce del file.
    ///   - fallbackAnalyses: Le stime statistiche, da cui riprendere la durata analizzata.
    /// - Returns: L'analisi diretta delle tracce MPEG Audio con almeno 10 frame coerenti.
    /// - Throws: Un errore se FFprobe non riesce a leggere i pacchetti.
    private func analyzeMPEGAudioBitrate(
        _ mediaURL: URL,
        streams: [FFprobeStream],
        fallbackAnalyses: [Int: StreamBitrateAnalysis]
    ) async throws -> [Int: StreamBitrateAnalysis] {
        let mpegAudioStreams = streams.compactMap { stream -> (index: Int, layerID: Int)? in
            guard stream.codecType == "audio",
                  let index = stream.index,
                  let codecName = stream.codecName?.lowercased(),
                  let layerID = MPEGAudioFrameParser.expectedLayerID(for: codecName) else {
                return nil
            }
            return (index, layerID)
        }

        guard !mpegAudioStreams.isEmpty else { return [:] }

        let arguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-read_intervals", "%+\(Int(Self.bitrateSampleDurationSeconds))",
            "-select_streams", "a",
            "-show_packets",
            "-show_data",
            "-show_entries", "packet=stream_index,data",
            "-of", "json",
            mediaURL.path
        ]

        let result = try await FFmpegProcessRunner.run(
            executableURL: MediaToolPaths.ffprobe,
            arguments: arguments
        )

        let packetDocument = try Self.decodeJSON(FFprobePacketDataDocument.self, from: result)

        let layerByStream = Dictionary(
            uniqueKeysWithValues: mpegAudioStreams.map { ($0.index, $0.layerID) }
        )

        var framesByStream: [Int: [MPEGAudioFrameHeader]] = [:]
        var markersByStream: [Int: MPEGAudioHeaderMarker] = [:]
        var hasLAMEByStream: [Int: Bool] = [:]

        for packet in packetDocument.packets {
            guard let streamIndex = packet.streamIndex,
                  let expectedLayerID = layerByStream[streamIndex],
                  let encodedData = packet.data,
                  let payload = MPEGAudioFrameParser.decodeHexDump(encodedData) else {
                continue
            }

            let parsedPacket = MPEGAudioFrameParser.parsePacket(
                payload,
                expectedLayerID: expectedLayerID
            )

            if !parsedPacket.frames.isEmpty {
                framesByStream[streamIndex, default: []].append(contentsOf: parsedPacket.frames)
            }

            if markersByStream[streamIndex] == nil,
               let marker = parsedPacket.headerMarker {
                markersByStream[streamIndex] = marker
            }

            if parsedPacket.hasLAMEEncoderTag {
                hasLAMEByStream[streamIndex] = true
            }
        }

        var analyses: [Int: StreamBitrateAnalysis] = [:]

        for stream in mpegAudioStreams {
            let streamIndex = stream.index
            guard let frames = framesByStream[streamIndex],
                  frames.count >= Self.minimumMPEGAudioFramesForDirectDetection else {
                // Con meno di 10 frame non forziamo una classificazione diretta:
                // l'eventuale stima statistica resta disponibile come fallback.
                continue
            }

            let configurations = Set(frames.map {
                "\($0.versionID)-\($0.layerID)-\($0.sampleRate)"
            })

            // Un cambio di versione/layer/frequenza nel campione rende la classificazione
            // diretta ambigua: in questo caso manteniamo il risultato statistico.
            guard configurations.count == 1 else { continue }

            let distinctBitrates = Set(frames.map(\.bitRateBitsPerSecond))
            let mode: StreamBitrateMode = distinctBitrates.count == 1 ? .constant : .variable
            let averageFrameBitrate = Int64(
                (Double(frames.reduce(Int64(0)) { $0 + $1.bitRateBitsPerSecond }) /
                 Double(frames.count)).rounded()
            )
            let fallback = fallbackAnalyses[streamIndex]

            analyses[streamIndex] = StreamBitrateAnalysis(
                streamIndex: streamIndex,
                mode: mode,
                classificationMethod: .direct,
                averageBitRateBitsPerSecond: averageFrameBitrate,
                sampledDurationSeconds: fallback?.sampledDurationSeconds ?? 0,
                coefficientOfVariation: nil,
                analyzedWindowCount: 0,
                analyzedFrameCount: frames.count,
                mpegAudioHeaderMarker: markersByStream[streamIndex],
                hasLAMEEncoderTag: hasLAMEByStream[streamIndex] ?? false
            )
        }

        return analyses
    }

    // MARK: - Calcolo della stima bitrate

    /// Stima la modalità del bitrate dalla variabilità dei pacchetti.
    ///
    /// Il bitrate viene calcolato in finestre di 5 secondi, escluse la prima e l'ultima perché
    /// potrebbero essere parziali. La traccia è considerata a bitrate costante se il coefficiente
    /// di variazione non supera 0,08 per l'audio o 0,18 per il video, che ha i picchi dei
    /// fotogrammi I. Servono almeno 4 finestre.
    ///
    /// - Parameters:
    ///   - streamIndex: L'indice della traccia.
    ///   - packets: I pacchetti della traccia.
    ///   - codecType: "audio" o "video".
    /// - Returns: L'analisi stimata.
    private static func makeBitrateAnalysis(
        streamIndex: Int,
        packets: [FFprobePacketSample],
        codecType: String?
    ) -> StreamBitrateAnalysis {
        let sortedPackets = packets.sorted { $0.timestamp < $1.timestamp }
        let firstTimestamp = sortedPackets.first?.timestamp ?? 0
        let lastTimestamp = sortedPackets.reduce(firstTimestamp) {
            max($0, $1.timestamp + $1.duration)
        }
        let sampledDuration = max(0, lastTimestamp - firstTimestamp)
        let totalBytes = sortedPackets.reduce(Int64(0)) { $0 + $1.sizeBytes }

        let averageBitRate: Int64? = sampledDuration > 0
            ? Int64((Double(totalBytes) * 8 / sampledDuration).rounded())
            : nil

        // Escludiamo la prima e l'ultima finestra perché potrebbero essere
        // parziali. Le finestre interne sono tutte di 5 secondi.
        let bucketIndexes = sortedPackets.map {
            Int(floor(($0.timestamp - firstTimestamp) / bitrateWindowDurationSeconds))
        }
        let lastBucket = bucketIndexes.max() ?? 0
        var bytesByBucket: [Int: Int64] = [:]

        for (packet, bucket) in zip(sortedPackets, bucketIndexes) {
            bytesByBucket[bucket, default: 0] += packet.sizeBytes
        }

        var windowBitrates: [Double] = []
        if lastBucket > 1 {
            for bucket in 1..<lastBucket {
                let bytes = bytesByBucket[bucket, default: 0]
                let rate = Double(bytes) * 8 / bitrateWindowDurationSeconds
                windowBitrates.append(rate)
            }
        }

        let mean = windowBitrates.isEmpty
            ? 0
            : windowBitrates.reduce(0, +) / Double(windowBitrates.count)

        let coefficientOfVariation: Double? = {
            guard windowBitrates.count >= 4, mean > 0 else { return nil }
            let variance = windowBitrates.reduce(0.0) {
                $0 + (($1 - mean) * ($1 - mean))
            } / Double(windowBitrates.count)
            return sqrt(variance) / mean
        }()

        let mode: StreamBitrateMode
        if let coefficientOfVariation {
            // Il video tollera una dispersione maggiore per i picchi dei frame
            // intra; l'audio CBR tende invece ad avere pacchetti più regolari.
            let threshold = codecType == "audio" ? 0.08 : 0.18
            mode = coefficientOfVariation <= threshold ? .constant : .variable
        } else {
            mode = .undetermined
        }

        return StreamBitrateAnalysis(
            streamIndex: streamIndex,
            mode: mode,
            classificationMethod: .estimated,
            averageBitRateBitsPerSecond: averageBitRate,
            sampledDurationSeconds: sampledDuration,
            coefficientOfVariation: coefficientOfVariation,
            analyzedWindowCount: windowBitrates.count,
            analyzedFrameCount: 0,
            mpegAudioHeaderMarker: nil,
            hasLAMEEncoderTag: false
        )
    }
}

/// Un pacchetto letto con `ffprobe -show_packets`.
private struct FFprobePacketSample: Sendable {
    /// L'istante del pacchetto, in secondi.
    let timestamp: Double
    /// La durata del pacchetto, in secondi (0 se non è nota).
    let duration: Double
    /// La dimensione del pacchetto, in byte.
    let sizeBytes: Int64
}

/// L'elenco dei pacchetti con il loro contenuto, letto con `ffprobe -show_data`.
private struct FFprobePacketDataDocument: Decodable {
    let packets: [FFprobePacketData]

    private enum CodingKeys: String, CodingKey {
        case packets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        packets = try container.decodeIfPresent([FFprobePacketData].self, forKey: .packets) ?? []
    }
}

/// Un pacchetto con il suo contenuto, come dump esadecimale.
private struct FFprobePacketData: Decodable {
    let streamIndex: Int?
    let data: String?

    private enum CodingKeys: String, CodingKey {
        case streamIndex = "stream_index"
        case data
    }
}

/// L'header di un frame MPEG Audio (MP1, MP2, MP3): versione, layer, bitrate e frequenza di campionamento.
struct MPEGAudioFrameHeader: Sendable {
    /// La versione: 3 = MPEG-1, 2 = MPEG-2, 0 = MPEG-2.5.
    let versionID: Int
    /// Il layer, come codificato nell'header: 3 = Layer I, 2 = Layer II, 1 = Layer III.
    let layerID: Int
    /// La frequenza di campionamento, in Hz.
    let sampleRate: Int
    /// Il bitrate del frame, in bit al secondo.
    let bitRateBitsPerSecond: Int64
    /// La lunghezza del frame, in byte, header compreso.
    let frameLength: Int
    /// La modalità dei canali: 3 = mono.
    let channelMode: Int
}

/// I frame MPEG Audio trovati in un pacchetto e l'eventuale indicatore «Xing», «Info» o «VBRI» del primo frame.
struct MPEGAudioPacketParseResult {
    /// Gli header dei frame, in ordine.
    let frames: [MPEGAudioFrameHeader]
    /// L'indicatore Xing, Info o VBRI, se presente.
    let headerMarker: MPEGAudioHeaderMarker?
    /// Vero se compare l'identificativo dell'encoder LAME.
    let hasLAMEEncoderTag: Bool
}

/// Un lettore minimo degli header MPEG Audio, usato per capire se un MP3 è a bitrate costante o variabile.
///
/// Non decodifica l'audio: legge soltanto la parola di sincronizzazione, la versione, il layer,
/// il bitrate, la frequenza e la lunghezza di ogni frame.
enum MPEGAudioFrameParser {
    /// Il layer, come codificato nell'header, che corrisponde a un codec di FFprobe.
    ///
    /// - Parameter codecName: Il nome del codec: "mp1", "mp2" o "mp3".
    /// - Returns: 3, 2 o 1; `nil` per gli altri codec.
    static func expectedLayerID(for codecName: String) -> Int? {
        switch codecName {
        case "mp1": return 3
        case "mp2": return 2
        case "mp3": return 1
        default: return nil
        }
    }

    /// Converte in byte il dump esadecimale restituito da FFprobe.
    ///
    /// Ogni riga ha l'offset, la colonna esadecimale e, separata da due spazi, quella ASCII.
    ///
    /// - Parameter dump: Il dump, per esempio `00000000: fffb 9000 …  ....`.
    /// - Returns: I byte, o `nil` se il dump non ne contiene.
    static func decodeHexDump(_ dump: String) -> Data? {
        var bytes = Data()

        for line in dump.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let afterOffset = line[line.index(after: colon)...]
            let lineText = String(afterOffset)
            let hexColumn = lineText.range(of: "  ").map {
                String(lineText[..<$0.lowerBound])
            } ?? lineText

            for token in hexColumn.split(whereSeparator: \.isWhitespace) {
                let hex = String(token)
                guard (hex.count == 2 || hex.count == 4),
                      hex.allSatisfy({ $0.isHexDigit }) else {
                    break
                }

                var position = hex.startIndex
                while position < hex.endIndex {
                    let next = hex.index(position, offsetBy: 2)
                    guard let byte = UInt8(hex[position..<next], radix: 16) else {
                        break
                    }
                    bytes.append(byte)
                    position = next
                }
            }
        }

        return bytes.isEmpty ? nil : bytes
    }

    /// Cerca i frame MPEG Audio consecutivi in un pacchetto.
    ///
    /// I byte che non formano un header valido vengono saltati uno alla volta.
    ///
    /// - Parameters:
    ///   - data: Il contenuto del pacchetto.
    ///   - expectedLayerID: Il layer atteso: i frame di un altro layer vengono ignorati.
    /// - Returns: I frame trovati e gli indicatori del primo frame.
    static func parsePacket(
        _ data: Data,
        expectedLayerID: Int
    ) -> MPEGAudioPacketParseResult {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else {
            return MPEGAudioPacketParseResult(
                frames: [],
                headerMarker: nil,
                hasLAMEEncoderTag: false
            )
        }

        var frames: [MPEGAudioFrameHeader] = []
        var detectedMarker: MPEGAudioHeaderMarker?
        var detectedLAME = false
        var offset = 0

        while offset + 4 <= bytes.count {
            guard let header = parseHeader(
                in: bytes,
                at: offset,
                expectedLayerID: expectedLayerID
            ), header.frameLength <= bytes.count - offset else {
                offset += 1
                continue
            }

            frames.append(header)

            let markerInfo = inspectHeaderMarker(
                in: bytes,
                frameOffset: offset,
                header: header
            )

            if detectedMarker == nil, let marker = markerInfo.marker {
                detectedMarker = marker
            }
            detectedLAME = detectedLAME || markerInfo.hasLAMEEncoderTag

            offset += header.frameLength
        }

        return MPEGAudioPacketParseResult(
            frames: frames,
            headerMarker: detectedMarker,
            hasLAMEEncoderTag: detectedLAME
        )
    }

    /// Legge l'header di un frame.
    ///
    /// - Parameters:
    ///   - bytes: Il contenuto del pacchetto.
    ///   - offset: La posizione dell'header.
    ///   - expectedLayerID: Il layer atteso.
    /// - Returns: L'header, o `nil` se in quella posizione non c'è un header valido del layer atteso.
    private static func parseHeader(
        in bytes: [UInt8],
        at offset: Int,
        expectedLayerID: Int
    ) -> MPEGAudioFrameHeader? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }

        let raw = (UInt32(bytes[offset]) << 24) |
            (UInt32(bytes[offset + 1]) << 16) |
            (UInt32(bytes[offset + 2]) << 8) |
            UInt32(bytes[offset + 3])

        // Sync word MPEG Audio: 11 bit a 1.
        guard (raw & 0xFFE0_0000) == 0xFFE0_0000 else { return nil }

        let versionID = Int((raw >> 19) & 0x3)
        let layerID = Int((raw >> 17) & 0x3)
        let bitrateIndex = Int((raw >> 12) & 0xF)
        let sampleRateIndex = Int((raw >> 10) & 0x3)
        let padding = Int((raw >> 9) & 0x1)
        let channelMode = Int((raw >> 6) & 0x3)
        let emphasis = Int(raw & 0x3)

        guard versionID != 1,
              layerID != 0,
              layerID == expectedLayerID,
              bitrateIndex > 0,
              bitrateIndex < 15,
              sampleRateIndex < 3,
              emphasis != 2 else {
            return nil
        }

        let bitrateTable: [Int]
        if versionID == 3 {
            switch layerID {
            case 3: // MPEG-1 Layer I
                bitrateTable = [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448, 0]
            case 2: // MPEG-1 Layer II
                bitrateTable = [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 0]
            default: // MPEG-1 Layer III
                bitrateTable = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0]
            }
        } else {
            switch layerID {
            case 3: // MPEG-2/2.5 Layer I
                bitrateTable = [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256, 0]
            default: // MPEG-2/2.5 Layer II/III
                bitrateTable = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0]
            }
        }

        let baseSampleRates = [44_100, 48_000, 32_000]
        let sampleRate: Int
        switch versionID {
        case 3: sampleRate = baseSampleRates[sampleRateIndex]
        case 2: sampleRate = baseSampleRates[sampleRateIndex] / 2
        default: sampleRate = baseSampleRates[sampleRateIndex] / 4
        }

        let bitRateBitsPerSecond = Int64(bitrateTable[bitrateIndex] * 1_000)
        let frameLength: Int

        if layerID == 3 {
            frameLength = ((12 * Int(bitRateBitsPerSecond) / sampleRate) + padding) * 4
        } else if layerID == 1 && versionID != 3 {
            frameLength = (72 * Int(bitRateBitsPerSecond) / sampleRate) + padding
        } else {
            frameLength = (144 * Int(bitRateBitsPerSecond) / sampleRate) + padding
        }

        guard frameLength >= 4 else { return nil }

        return MPEGAudioFrameHeader(
            versionID: versionID,
            layerID: layerID,
            sampleRate: sampleRate,
            bitRateBitsPerSecond: bitRateBitsPerSecond,
            frameLength: frameLength,
            channelMode: channelMode
        )
    }

    /// Cerca nel frame gli indicatori Xing, Info o VBRI e l'identificativo di LAME.
    ///
    /// - Parameters:
    ///   - bytes: Il contenuto del pacchetto.
    ///   - frameOffset: La posizione del frame.
    ///   - header: L'header del frame.
    /// - Returns: L'indicatore trovato e se il file è stato prodotto con LAME.
    private static func inspectHeaderMarker(
        in bytes: [UInt8],
        frameOffset: Int,
        header: MPEGAudioFrameHeader
    ) -> (marker: MPEGAudioHeaderMarker?, hasLAMEEncoderTag: Bool) {
        // VBRI si trova a 32 byte dall'inizio dei dati successivi all'header MPEG.
        let vbriOffset = frameOffset + 4 + 32
        if matchesASCII("VBRI", in: bytes, at: vbriOffset) {
            return (.vbri, false)
        }

        // Xing/Info è presente nei frame Layer III, dopo il side information.
        guard header.layerID == 1 else { return (nil, false) }

        let isMPEG1 = header.versionID == 3
        let isMono = header.channelMode == 3
        let sideInformationLength: Int

        if isMPEG1 {
            sideInformationLength = isMono ? 17 : 32
        } else {
            sideInformationLength = isMono ? 9 : 17
        }

        // Il CRC non sposta questo offset nei tag Xing/Info.
        let xingOffset = frameOffset + 4 + sideInformationLength

        let marker: MPEGAudioHeaderMarker
        if matchesASCII("Xing", in: bytes, at: xingOffset) {
            marker = .xing
        } else if matchesASCII("Info", in: bytes, at: xingOffset) {
            marker = .info
        } else {
            return (nil, false)
        }

        // Dopo l'identificatore ci sono 4 byte di flag e, in base ai flag,
        // i campi frame count, byte count, TOC e quality. LAME può seguire.
        let flagsOffset = xingOffset + 4
        guard flagsOffset + 4 <= bytes.count else { return (marker, false) }

        let flags = (UInt32(bytes[flagsOffset]) << 24) |
            (UInt32(bytes[flagsOffset + 1]) << 16) |
            (UInt32(bytes[flagsOffset + 2]) << 8) |
            UInt32(bytes[flagsOffset + 3])

        var encoderOffset = flagsOffset + 4
        if (flags & 0x1) != 0 { encoderOffset += 4 }
        if (flags & 0x2) != 0 { encoderOffset += 4 }
        if (flags & 0x4) != 0 { encoderOffset += 100 }
        if (flags & 0x8) != 0 { encoderOffset += 4 }

        let hasLAME = matchesASCII("LAME", in: bytes, at: encoderOffset)
        return (marker, hasLAME)
    }

    /// Vero se in una posizione si trova il testo indicato.
    ///
    /// - Parameters:
    ///   - string: Il testo, in ASCII.
    ///   - bytes: I byte in cui cercare.
    ///   - offset: La posizione.
    /// - Returns: Vero se i byte coincidono.
    private static func matchesASCII(
        _ string: String,
        in bytes: [UInt8],
        at offset: Int
    ) -> Bool {
        let expected = Array(string.utf8)
        guard offset >= 0, offset + expected.count <= bytes.count else { return false }
        return Array(bytes[offset..<(offset + expected.count)]) == expected
    }
}
