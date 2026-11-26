// SystemView.swift
// Sezione Sistema: computer in uso, encoder hardware, versioni di FFmpeg e FFprobe, Apple Intelligence.

import Darwin
import Foundation
import SwiftUI

/// La sezione Sistema, la prima che si vede: che cosa c'è sul Mac e che cosa serve a CodecLab.
///
/// Mostra il Mac in uso (chip, CPU, memoria, versione di macOS) e lo stato di ciò che l'app usa:
/// gli encoder hardware H.264 e HEVC, FFmpeg e FFprobe di Homebrew, libvmaf per l'analisi della qualità,
/// l'encoder AAC di Apple e il modello linguistico di Apple Intelligence, ciascuno con versione
/// o descrizione. Se manca qualcosa di essenziale, lo si capisce qui.
struct SystemView: View {
    @Environment(AppViewModel.self) private var appModel

    /// Le informazioni sul Mac, lette una sola volta: la vista viene ricreata a ogni aggiornamento dello stato.
    private static let computer = ComputerInformation.current

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {

                // MARK: - Intestazione

                VStack(alignment: .leading, spacing: 6) {
                    Text("CodecLab")
                        .font(.largeTitle.bold())

                    Text("Ambiente di codifica e analisi della qualità audio/video")
                        .foregroundStyle(.secondary)
                }

                // MARK: - Computer in uso

                GroupBox("Computer in uso") {
                    Grid(
                        alignment: .leading,
                        horizontalSpacing: 18,
                        verticalSpacing: 9
                    ) {
                        MetadataRow("Chip", Self.computer.chip)
                        MetadataRow("CPU", Self.computer.cpu)
                        MetadataRow("Memoria", Self.computer.memory)
                        MetadataRow("Sistema", Self.computer.macOS)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                // MARK: - Encoder hardware

                GroupBox("Encoder hardware Apple Silicon") {
                    VStack(alignment: .leading, spacing: 12) {

                        availabilityRow(
                            name: "H.264 (VideoToolbox)",
                            isAvailable: appModel.isH264HardwareEncoderAvailable,
                            detail: appModel.toolDetails["h264"]
                        )

                        Divider()

                        availabilityRow(
                            name: "HEVC (VideoToolbox)",
                            isAvailable: appModel.isHEVCHardwareEncoderAvailable,
                            detail: appModel.toolDetails["hevc"]
                        )

                        if appModel.isCheckingTools {
                            HStack {
                                ProgressView()
                                    .controlSize(.small)

                                Text("Verifica degli encoder hardware…")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        } else if appModel.isH264HardwareEncoderAvailable == nil ||
                                    appModel.isHEVCHardwareEncoderAvailable == nil {
                            Text("In attesa della verifica degli strumenti multimediali.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                // MARK: - Motori multimediali

                GroupBox("Motori multimediali") {
                    VStack(alignment: .leading, spacing: 12) {
                        toolStatusRow(
                            name: "FFmpeg (Homebrew)",
                            version: appModel.ffmpegVersion
                        )

                        Divider()

                        toolStatusRow(
                            name: "FFprobe (Homebrew)",
                            version: appModel.ffprobeVersion
                        )

                        Divider()

                        availabilityRow(
                            name: "libvmaf (analisi qualità)",
                            isAvailable: appModel.isLibVMAFAvailable,
                            detail: appModel.toolDetails["libvmaf"]
                        )

                        Divider()

                        availabilityRow(
                            name: "AAC (AudioToolbox)",
                            isAvailable: appModel.isAppleAACAvailable,
                            detail: appModel.toolDetails["aac_at"]
                        )

                        if !appModel.areToolsAvailable &&
                            appModel.isCheckingTools {
                            HStack {
                                ProgressView()
                                    .controlSize(.small)

                                Text("Verifica degli strumenti installati…")
                                    .foregroundStyle(.secondary)
                                    .font(.callout)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                // MARK: - Apple Intelligence

                GroupBox("Apple Intelligence") {
                    VStack(alignment: .leading, spacing: 12) {
                        availabilityRow(
                            name: "Modello linguistico",
                            isAvailable: ExperimentSearch.isAppleIntelligenceAvailable,
                            detail: ExperimentSearch.languageModelDetail
                        )

                        if !ExperimentSearch.isAppleIntelligenceAvailable {
                            Text(ExperimentSearch.unavailableReason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }
            .padding(24)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Sistema")
    }

    // MARK: - Righe di stato

    /// La riga di FFmpeg o FFprobe: nome, versione rilevata e disponibilità.
    ///
    /// - Parameters:
    ///   - name: Il nome dello strumento.
    ///   - version: La versione; `nil` se lo strumento non è stato trovato o non è ancora stato verificato.
    private func toolStatusRow(
        name: String,
        version: String?
    ) -> some View {
        let isAvailable: Bool? = version != nil
            ? true
            : (appModel.hasCheckedTools && !appModel.isCheckingTools ? false : nil)

        return HStack(alignment: .top) {
            statusIcon(isAvailable)

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .fontWeight(.medium)

                if let version {
                    Text(version)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            statusText(isAvailable)
        }
    }

    /// La riga di un componente (encoder hardware, libvmaf, AAC di AudioToolbox, Apple Intelligence):
    /// nome, informazioni in piccolo e disponibilità.
    ///
    /// - Parameters:
    ///   - name: Il nome del componente.
    ///   - isAvailable: La disponibilità; `nil` se non è ancora stata verificata.
    ///   - detail: Le informazioni sotto il nome, come la versione per FFmpeg; `nil` per nessuna.
    private func availabilityRow(
        name: String,
        isAvailable: Bool?,
        detail: String? = nil
    ) -> some View {
        HStack(alignment: detail == nil ? .center : .top) {
            statusIcon(isAvailable)

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .fontWeight(.medium)

                if let detail {
                    Text(detail)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            statusText(isAvailable)
        }
    }

    /// L'icona di stato: verde se disponibile, grigia altrimenti.
    private func statusIcon(_ isAvailable: Bool?) -> some View {
        let symbol = switch isAvailable {
        case .some(true): "checkmark.circle.fill"
        case .some(false): "xmark.circle"
        case .none: "questionmark.circle"
        }

        return Image(systemName: symbol)
            .foregroundStyle(isAvailable == true ? Color.green : Color.secondary)
    }

    /// Il testo di stato: «Disponibile», «Non disponibile» o «Da verificare».
    private func statusText(_ isAvailable: Bool?) -> some View {
        let status = switch isAvailable {
        case .some(true): "Disponibile"
        case .some(false): "Non disponibile"
        case .none: "Da verificare"
        }

        return Text(status)
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Informazioni sul computer

/// Il riepilogo del Mac in uso: chip, core, memoria e versione di macOS.
private struct ComputerInformation {
    /// Il nome del chip, per esempio "Apple M3 Pro".
    let chip: String
    /// I core, per esempio "12 core (6 prestazioni + 6 efficienza)".
    let cpu: String
    /// La memoria, per esempio "36 GB".
    let memory: String
    /// La versione del sistema, per esempio "macOS 26.1".
    let macOS: String

    /// Le informazioni sul Mac in uso.
    static var current: ComputerInformation {
        let info = ProcessInfo.processInfo
        let version = info.operatingSystemVersion
        let patch = version.patchVersion > 0 ? ".\(version.patchVersion)" : ""

        // I chip Apple hanno core di due tipi: prestazioni (perflevel0) ed efficienza (perflevel1).
        var cpu = sysctlInteger("hw.physicalcpu").map { "\($0) core" } ?? "Non disponibile"

        if let performance = sysctlInteger("hw.perflevel0.physicalcpu"),
           let efficiency = sysctlInteger("hw.perflevel1.physicalcpu") {
            cpu += " (\(performance) prestazioni + \(efficiency) efficienza)"
        }

        return ComputerInformation(
            chip: sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon",
            cpu: cpu,
            memory: ByteCountFormatter.string(fromByteCount: Int64(info.physicalMemory), countStyle: .memory),
            macOS: "macOS \(version.majorVersion).\(version.minorVersion)\(patch)"
        )
    }

    // MARK: Lettura dei parametri di sistema (sysctl)

    /// Legge un parametro di sistema di tipo testo.
    ///
    /// - Parameter key: Il nome del parametro, per esempio "machdep.cpu.brand_string".
    /// - Returns: Il valore, o `nil` se il parametro non esiste.
    private static func sysctlString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return nil }

        // Il valore è una stringa C: il byte nullo finale non fa parte del testo.
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// Legge un parametro di sistema di tipo intero.
    ///
    /// - Parameter key: Il nome del parametro, per esempio "hw.physicalcpu".
    /// - Returns: Il valore, o `nil` se il parametro non esiste.
    private static func sysctlInteger(_ key: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(key, &value, &size, nil, 0) == 0 else { return nil }

        return Int(value)
    }
}
