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

    /// Escuta passivamente o barramento CAN por `durationSeconds` sem formatação ISO-TP (`AT CAF0`),
    /// opcionalmente filtrando por máscara `AT CRA` (ex.: `"3XX"`, `"4XX"`, `"5XX"`), e restaura `AT CAF1` ao final.
    public func sniffBroadcastWindow(
        durationSeconds: Double = 0.85,
        craFilter: String? = nil
    ) async throws -> String {
        while isBusy {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        isBusy = true
        defer { isBusy = false }

        currentTarget = nil
        flowControlKnown = false

        _ = try? await bleManager.sendRawCommand("AT CAF0", timeoutSeconds: 1.0)
        _ = try? await bleManager.sendRawCommand("AT H1", timeoutSeconds: 1.0)
        if let cra = craFilter {
            _ = try? await bleManager.sendRawCommand("AT CRA \(cra)", timeoutSeconds: 1.0)
        } else {
            _ = try? await bleManager.sendRawCommand("AT AR", timeoutSeconds: 1.0)
            _ = try? await bleManager.sendRawCommand("AT CRA", timeoutSeconds: 1.0)
        }

        let captured = (try? await bleManager.captureMonitorWindow("AT MA", durationSeconds: durationSeconds)) ?? ""

        // Restaura modo ISO-TP padrão e filtro de recepção automático (AT AR) para UDS/OBD-II
        _ = try? await bleManager.sendRawCommand("AT AR", timeoutSeconds: 1.0)
        _ = try? await bleManager.sendRawCommand("AT CRA", timeoutSeconds: 1.0)
        _ = try? await bleManager.sendRawCommand("AT CAF1", timeoutSeconds: 1.0)
        return captured.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Envia um quadro CAN bruto (sem byte PCI ISO-TP) em rajada com `AT R0` (sem esperar resposta UDS)
    /// para reproduzir um pacote aprendido da tela touch, restaurando `AT R1`, `AT CAF1` e `AT AR` ao final.
    public func sendRawCANFrame(canIdHex: String, dataBytesHex: String, repeatCount: Int = 4) async throws -> String {
        while isBusy {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        isBusy = true
        defer { isBusy = false }

        currentTarget = nil
        flowControlKnown = false

        _ = try? await bleManager.sendRawCommand("AT CAF0", timeoutSeconds: 1.0)
        _ = try? await bleManager.sendRawCommand("AT R0", timeoutSeconds: 1.0)
        _ = try? await bleManager.sendRawCommand("AT SH \(canIdHex)", timeoutSeconds: 1.0)
        var lastResp = ""
        let count = max(1, min(repeatCount, 10))
        for i in 0..<count {
            lastResp = (try? await bleManager.sendRawCommand(dataBytesHex, timeoutSeconds: 0.8)) ?? ""
            if i + 1 < count {
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
        _ = try? await bleManager.sendRawCommand("AT R1", timeoutSeconds: 1.0)
        _ = try? await bleManager.sendRawCommand("AT CAF1", timeoutSeconds: 1.0)
        _ = try? await bleManager.sendRawCommand("AT AR", timeoutSeconds: 1.0)
        return lastResp.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Varredura completa: sonda TODOS os endereços de diagnóstico `0x700...0x77F` (não apenas a lista fixa)
    /// com `3E 00` (TesterPresent), que cabe em um único quadro e responde em <25 ms, e devolve os que existem.
    /// Usado quando a lista fixa não acha o módulo (ex.: módulo de TPMS fora dos endereços conhecidos).
    public func sweepUDSModules7XX(
        range: ClosedRange<Int> = 0x700...0x77F,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async -> [(tx: String, rx: String, response: String)] {
        while isBusy {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        isBusy = true
        defer { isBusy = false }

        currentTarget = nil
        flowControlKnown = false

        _ = try? await bleManager.sendRawCommand("AT CAF1", timeoutSeconds: 1.0)
        _ = try? await bleManager.sendRawCommand("AT H1", timeoutSeconds: 1.0)
        _ = try? await bleManager.sendRawCommand("AT FC SM 0", timeoutSeconds: 1.0)
        _ = try? await bleManager.sendRawCommand("AT CRA 7XX", timeoutSeconds: 1.0)

        var hits: [(tx: String, rx: String, response: String)] = []
        for addr in range {
            let tx = String(format: "%03X", addr)
            onProgress?("Varrendo 0x\(tx) (\(addr - range.lowerBound + 1)/\(range.count))...")
            _ = try? await bleManager.sendRawCommand("AT SH \(tx)", timeoutSeconds: 0.6)
            guard let raw = try? await bleManager.sendRawCommand("3E 00", timeoutSeconds: 0.25) else { continue }
            let upper = raw
                .replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: ">", with: "")
                .uppercased()
            if upper.contains("NO DATA") || upper.contains("?") { continue }
            for line in upper.components(separatedBy: "\n") {
                let tokens = line.trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                guard tokens.count >= 2 else { continue }
                let rx = tokens[0]
                guard rx.count == 3, rx.hasPrefix("7"), Int(rx, radix: 16) != nil else { continue }
                hits.append((tx: tx, rx: rx, response: tokens.joined(separator: " ")))
                break
            }
        }

        _ = try? await bleManager.sendRawCommand("AT AR", timeoutSeconds: 1.0)
        _ = try? await bleManager.sendRawCommand("AT CRA", timeoutSeconds: 1.0)
        return hits
    }

    /// Sonda uma lista de endereços `tx` UDS com filtro aberto `AT CRA 7XX` (descobre automaticamente se o módulo
    /// responde em `tx + 0x08`, `tx + 0x80`, ou qualquer outro ID `7XX`).
    public func discoverUDSModulesWildcard7XX(
        candidates: [(tx: String, fallbackRx: String, label: String)],
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async -> [(tx: String, rx: String, label: String, detail: String)] {
        while isBusy {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        isBusy = true
        defer { isBusy = false }

        currentTarget = nil
        flowControlKnown = false

        _ = try? await bleManager.sendRawCommand("AT CAF1", timeoutSeconds: 1.0)
        _ = try? await bleManager.sendRawCommand("AT H1", timeoutSeconds: 1.0)
        _ = try? await bleManager.sendRawCommand("AT FC SM 0", timeoutSeconds: 1.0)
        _ = try? await bleManager.sendRawCommand("AT CRA 7XX", timeoutSeconds: 1.0)

        var discovered: [(tx: String, rx: String, label: String, detail: String)] = []

        for cand in candidates {
            onProgress?("Sondando 0x\(cand.tx) (\(cand.label))...")
            _ = try? await bleManager.sendRawCommand("AT SH \(cand.tx)", timeoutSeconds: 0.8)

            // `10 03` (Sessão Estendida) ou `3E 00` (TesterPresent) cabem sempre em 1 único quadro CAN (Single Frame),
            // respondendo em <25ms com `50 03`, `7E 00` ou `7F <svc> <nrc>`, revelando o ID real de resposta nos 3 primeiros chars!
            for probeCmd in ["10 03", "10 01", "3E 00"] {
                guard let raw = try? await bleManager.sendRawCommand(probeCmd, timeoutSeconds: 0.45) else { continue }
                let trimmed = raw
                    .replacingOccurrences(of: "\r", with: "\n")
                    .replacingOccurrences(of: ">", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let upper = trimmed.uppercased()
                if upper.isEmpty || upper.contains("NO DATA") || upper.contains("ERROR") || upper.contains("?") {
                    continue
                }
                // Extrai o cabeçalho CAN de 3 dígitos hexadecimais da primeira linha válida (ex.: "79C 06 50 03...")
                let lines = upper.components(separatedBy: "\n")
                var detectedRx: String? = nil
                var cleanLine = ""
                for line in lines {
                    let tokens = line.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    guard tokens.count >= 2 else { continue }
                    let first = tokens[0]
                    if first.count == 3, first.hasPrefix("7"), Int(first, radix: 16) != nil {
                        detectedRx = first
                        cleanLine = tokens.joined(separator: " ")
                        break
                    }
                }
                if let rx = detectedRx {
                    discovered.append((
                        tx: cand.tx,
                        rx: rx,
                        label: cand.label,
                        detail: "\(probeCmd) → \(cleanLine)"
                    ))
                    break
                }
            }
        }

        _ = try? await bleManager.sendRawCommand("AT AR", timeoutSeconds: 1.0)
        _ = try? await bleManager.sendRawCommand("AT CRA", timeoutSeconds: 1.0)
        return discovered
    }
}
