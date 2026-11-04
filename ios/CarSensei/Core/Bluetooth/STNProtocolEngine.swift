import Foundation

/// Endereço CAN físico de um módulo (`AT SH` = transmissão, `AT CRA` = filtro de recepção).
/// `rx == nil` significa broadcast OBD-II funcional (`7DF`, aceita qualquer resposta).
public struct CANTarget: Equatable, Sendable {
    public let tx: String
    public let rx: String?

    public init(tx: String, rx: String?) {
        self.tx = tx
        self.rx = rx
    }

    public static let broadcast = CANTarget(tx: "7DF", rx: nil)
    public static let ecm = CANTarget(tx: "7E0", rx: "7E8")
    public static let tcu = CANTarget(tx: "7E1", rx: "7E9")
    public static let hvac = CANTarget(tx: "744", rx: "74C")
    public static let hvacB = CANTarget(tx: "750", rx: "758")
    public static let bdm = CANTarget(tx: "740", rx: "748")
}

/// Fila serial de comandos para o vLinker MC+ (STN2120) e ELM327 genérico via CoreBluetooth.
/// O endereçamento faz parte de cada comando: quem chama `execute(_:target:)` tem a garantia de que
/// `AT SH`/`AT CRA` e o comando saem juntos, sem que outra tarefa (ex.: o loop de telemetria) troque o módulo no meio.
public actor STNProtocolEngine {
    private let bleManager: BLEConnectionManager
    private var isBusy: Bool = false
    /// Endereço configurado no adaptador agora. `nil` = desconhecido (após `AT Z`, `AT D` ou comando manual).
    private var currentTarget: CANTarget?
    /// ID dos quadros de controle de fluxo (ISO-TP) configurado no adaptador; `nil` = automático do ELM.
    private var flowControlHeader: String?
    private var flowControlDataSet = false
    /// `false` depois de reset/comando manual: o próximo endereçamento reenvia a configuração inteira.
    private var flowControlKnown = false

    public init(bleManager: BLEConnectionManager) {
        self.bleManager = bleManager
    }

    /// Envia um comando. Com `target`, garante o endereçamento antes; sem `target` (comandos `AT`/`ST`),
    /// envia como está.
    public func execute(
        _ command: String,
        target: CANTarget? = nil,
        timeout: Double = 3.0
    ) async throws -> (response: String, durationMs: Int) {
        // ponytail: espera ativa de 25 ms em vez de fila FIFO; trocar por fila de continuations se houver disputa real.
        while isBusy {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        isBusy = true
        defer { isBusy = false }

        if let target, target != currentTarget {
            currentTarget = nil
            _ = try await bleManager.sendRawCommand("AT SH \(target.tx)", timeoutSeconds: 1.2)
            if let rx = target.rx {
                _ = try await bleManager.sendRawCommand("AT CRA \(rx)", timeoutSeconds: 1.2)
            } else {
                // No STN1151/STN2120, `AT CRA` sem argumentos retorna `?`; `AT AR` (Automatic Receive) limpa a máscara de hardware.
                _ = try? await bleManager.sendRawCommand("AT AR", timeoutSeconds: 1.0)
                _ = try? await bleManager.sendRawCommand("AT CRA", timeoutSeconds: 1.0)
            }
            // Respostas longas (ISO-TP): o quadro de controle de fluxo vai no ID de transmissão do módulo.
            // O automático do ELM usa (resposta − 8), que erra em módulos com outro par (ex.: 718/798).
            let wantedFC: String? = target.rx == nil ? nil : target.tx
            if !flowControlKnown || wantedFC != flowControlHeader {
                if let header = wantedFC {
                    if !flowControlDataSet {
                        _ = try await bleManager.sendRawCommand("AT FC SD 30 00 00", timeoutSeconds: 1.2)
                        flowControlDataSet = true
                    }
                    _ = try await bleManager.sendRawCommand("AT FC SH \(header)", timeoutSeconds: 1.2)
                    if flowControlHeader == nil || !flowControlKnown {
                        _ = try await bleManager.sendRawCommand("AT FC SM 1", timeoutSeconds: 1.2)
                    }
                } else {
                    _ = try await bleManager.sendRawCommand("AT FC SM 0", timeoutSeconds: 1.2)
                }
                flowControlHeader = wantedFC
                flowControlKnown = true
            }
            currentTarget = target
        }

        // Comando manual que mexe no endereçamento ou reinicia o chip: o endereço atual deixa de ser conhecido.
        let upper = command.uppercased().replacingOccurrences(of: " ", with: "")
        if ["ATSH", "ATCRA", "ATZ", "ATD", "ATWS", "ATCF", "ATCM", "ATFC"].contains(where: upper.hasPrefix),
           !upper.hasPrefix("ATDP") {
            currentTarget = nil
            if !upper.hasPrefix("ATSH") && !upper.hasPrefix("ATCRA") {
                flowControlKnown = false
                flowControlDataSet = false
            }
        }

        let start = DispatchTime.now()
        let raw = try await bleManager.sendRawCommand(command, timeoutSeconds: timeout)
        let end = DispatchTime.now()
        let ms = Int((end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        return (raw.trimmingCharacters(in: .whitespacesAndNewlines), ms)
    }

    /// Identifica o adaptador (`vLinker MC+ STN2120` vs `ELM327 Básico`) e negocia o protocolo CAN
    /// (tenta `AT SP 6` e cai para `AT SP 0`, busca automática).
    public func initializeMultiVehicleCANProfile(connectedBLEDeviceName: String?) async throws -> (firmware: String, tier: AdapterCapabilityTier, protocolName: String) {
        currentTarget = nil
        flowControlKnown = false
        flowControlDataSet = false

        // 1. Acorda o chip STN2120 do modo BatterySaver™ (sleep < 3 mA) antes de enviar comandos de configuração
        _ = try? await execute("AT", timeout: 0.9)
        try? await Task.sleep(nanoseconds: 180_000_000)

        // 2. Warm Start (`AT WS`) restaura os padrões sem derrubar a ponte BLE UART (muito mais rápido e estável que `AT Z`)
        if (try? await execute("AT WS", timeout: 1.6)) == nil {
            _ = try? await execute("AT D", timeout: 1.4)
        }
        try? await Task.sleep(nanoseconds: 220_000_000)

        // 3. Desativa eco (`AT E0`) com retentativa tolerante caso o adaptador ainda esteja saindo de sleep
        var echoOffOK = (try? await execute("AT E0", timeout: 1.8)) != nil
        if !echoOffOK {
            try? await Task.sleep(nanoseconds: 350_000_000)
            echoOffOK = (try? await execute("AT E0", timeout: 2.0)) != nil
        }
        if !echoOffOK {
            try? await Task.sleep(nanoseconds: 450_000_000)
            _ = try await execute("AT E0", timeout: 2.4)
        }
        _ = try await execute("AT L0", timeout: 1.5)
        _ = try await execute("AT H1", timeout: 1.5)
        _ = try await execute("AT CAF1", timeout: 1.5)
        _ = try await execute("AT CFC1", timeout: 1.5)
        _ = try? await execute("AT AR", timeout: 1.2)

        // Sonda comandos STN / Vgate para saber se é um vLinker MC+ original
        let (stiResp, _) = (try? await execute("STI", timeout: 1.4)) ?? ("", 0)
        let (atiResp, _) = (try? await execute("AT I", timeout: 1.4)) ?? ("", 0)
        let bleUpper = (connectedBLEDeviceName ?? "").uppercased()
        let stiUpper = stiResp.uppercased()
        let atiUpper = atiResp.uppercased()

        let isVLinker = (!stiUpper.isEmpty && !stiUpper.contains("?"))
            || stiUpper.contains("STN")
            || atiUpper.contains("VLINKER")
            || atiUpper.contains("VGATE")
            || bleUpper.contains("VLINKER")
            || bleUpper.contains("MC-IOS")

        let tier: AdapterCapabilityTier = isVLinker ? .vLinkerPro : .genericELM327
        let fwText = (!stiUpper.isEmpty && !stiUpper.contains("?"))
            ? stiResp.replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            : atiResp.replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespacesAndNewlines)

        // ISO 15765-4 CAN 11 bits 500 kbaud (a maioria dos carros atuais)
        _ = try await execute("AT SP 6", timeout: 1.5)
        if isVLinker {
            _ = try? await execute("AT ST 19", timeout: 1.2)
            _ = try? await execute("AT AT 2", timeout: 1.2)
            // Garante que o BatterySaver™ (sleep < 3 mA com carro desligado e wake automático pelo CAN/BLE) esteja ativo no STN
            _ = try? await execute("STSLU ON, ON", timeout: 1.0)
        }

        // Usa AT TP A6 (prioriza ISO 15765-4 CAN 11/500 com fallback automático se conectado em outro protocolo)
        // sem perder o perfil CAN 500k caso o usuário conecte com a ignição ainda desligada.
        let (probe0100, _) = (try? await execute("01 00", target: .broadcast, timeout: 2.2)) ?? ("", 0)
        if !probe0100.contains("41") {
            _ = try? await execute("AT TP A6", timeout: 1.5)
        }

        let (dpResp, _) = (try? await execute("AT DP", timeout: 1.4)) ?? ("ISO 15765-4 (CAN 11/500)", 0)
        let cleanProto = dpResp
            .replacingOccurrences(of: ">", with: "")
            .replacingOccurrences(of: "AUTO,", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (
            firmware: fwText.isEmpty ? (isVLinker ? "vLinker MC+ (STN2120)" : "ELM327 OBD-II") : fwText,
            tier: tier,
            protocolName: (cleanProto.isEmpty || cleanProto.uppercased() == "AUTO")
                ? "ISO 15765-4 CAN (11 bit ID, 500 kbaud)"
                : cleanProto
        )
    }

}
