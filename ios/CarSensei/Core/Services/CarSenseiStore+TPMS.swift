import Foundation

// MARK: - TPMS: leitura dos pneus, descoberta do módulo e assistente de pareamento de sensores
//
// Realidade do hardware: o vLinker fala no barramento OBD/CAN, não escuta o rádio 433 MHz dos sensores.
// Quem escuta os sensores é o módulo TPMS do carro. Então "ver se o sensor funciona" = ler o que o módulo
// TPMS reporta por roda (pressão, temperatura, ID). "Parear" = gravar o ID do sensor novo nesse módulo (UDS 2E/31).
// Nada aqui é fixo por carro: o app descobre o módulo e os DIDs sondando o barramento, e mostra o hex cru.

extension CarSenseiStore {

    /// DIDs UDS comuns em módulos de TPMS e de carroceria (pressão, temperatura, IDs). São candidatos para sondar,
    /// não um mapa de um carro. A sondagem abre sessão `10 03` e aceita o que responder com valores plausíveis.
    static let tpmsCandidateDIDs: [(hi: UInt8, lo: UInt8, kind: String)] = [
        (0xD0, 0x01, "pressões"), (0xD0, 0x02, "pressões"), (0xD0, 0x03, "pressões"), (0xD0, 0x04, "pressões"),
        (0xD0, 0x05, "pressões"), (0xD0, 0x06, "pressões"), (0xD0, 0x08, "pressões"), (0xD0, 0x10, "pressões"),
        (0xD1, 0x00, "pressões"), (0xD1, 0x01, "pressões"), (0xD1, 0x02, "pressões"),
        (0xB0, 0x01, "pressões"), (0xB0, 0x02, "pressões"), (0xB0, 0x03, "pressões"), (0xB0, 0x04, "pressões"),
        (0x02, 0x01, "pressões"), (0x02, 0x02, "pressões"), (0x02, 0x03, "pressões"), (0x02, 0x04, "pressões"),
        (0xF4, 0x05, "pressões"), (0xF4, 0x06, "pressões"),
        (0x11, 0x01, "pressões"), (0x11, 0x02, "temperaturas"),
        (0x2A, 0x01, "pressões"), (0x2B, 0x01, "temperaturas"),
        (0xC1, 0x00, "IDs"), (0x04, 0x1C, "IDs"),
        (0x40, 0x00, "pressões"), (0x40, 0x01, "pressões"),
        (0xF1, 0xA0, "IDs")
    ]

    /// Endereços candidatos a módulo TPMS/BCM/carroceria (11-bit).
    /// Inclui os pares de resposta mais comuns (`TX + 0x08` e `TX + 0x10`); a busca geral 7XX cobre o resto.
    static let tpmsCandidateModules: [(tx: String, rx: String, label: String)] = [
        ("740", "750", "BCM / Carroceria"),
        ("760", "770", "BCM / Conforto & TPMS"),
        ("765", "775", "BCM / Carroceria (canal B)"),
        ("7A0", "7A8", "Módulo TPMS / Multimídia"),
        ("740", "748", "BCM / Carroceria (alt.)"),
        ("760", "768", "BCM / Conforto (alt.)"),
        ("726", "72E", "Carroceria (alt.)"),
        ("750", "758", "Conforto / Clima"),
        ("710", "718", "Painel de Instrumentos (ICM)"),
        ("710", "720", "Painel de Instrumentos (alt.)"),
        ("730", "738", "Chassi / Estabilidade"),
        ("721", "729", "TPMS dedicado (alt.)")
    ]

    // MARK: Leitura

    public func readTPMS() async {
        guard connectionState == .connectedReady else {
            tpmsStatusText = "Conecte ao vLinker MC+ no carro para ler os pneus."
            return
        }
        isReadingTPMS = true
        pausePollingCounter += 1
        defer {
            pausePollingCounter = max(0, pausePollingCounter - 1)
            isReadingTPMS = false
        }

        // 1. Módulo salvo que nunca trouxe dados de pneu: procura de novo em vez de insistir nele.
        if let saved = confirmedTPMSModule, !saved.looksLikeTPMS {
            confirmedTPMSModule = nil
        }

        var module = confirmedTPMSModule
        if module == nil {
            tpmsStatusText = "Procurando o módulo de TPMS no barramento (7XX)..."
            module = await discoverTPMSModule()
        }

        guard let module else {
            // Nenhum módulo UDS: o painel do carro pode mostrar a pressão porque algum nó publica no barramento.
            if let broadcast = await readTPMSPressuresFromBroadcast() {
                let snapshot = buildBroadcastSnapshot(canId: broadcast.canId, pressures: broadcast.pressures)
                tpmsSnapshot = snapshot
                tpmsStatusText = "Pressão lida do quadro CAN 0x\(broadcast.canId) (o módulo de TPMS não responde UDS neste carro)."
                TissotFeedback.log("TPMS_BROADCAST_READ", ["canId": broadcast.canId, "pressures": broadcast.pressures.map { String(format: "%.0f", $0) }.joined(separator: ",")])
                return
            }
            tpmsSnapshot = TPMSSnapshot(source: .none)
            tpmsStatusText = "Nenhum módulo respondeu e nenhum quadro do barramento trouxe as 4 pressões. Use 'Varredura completa' com a ignição ligada."
            return
        }

        tpmsStatusText = "Lendo pneus no módulo 0x\(module.txHeader) → 0x\(module.rxHeader)..."
        let target = CANTarget(tx: module.txHeader, rx: module.rxHeader)
        _ = try? await protocolEngine.execute("10 03", target: target, timeout: 1.0)

        var tires = WheelPosition.roadWheels.map { TireReading(position: $0) }
        var pressureValues: [Double] = []
        var tempValues: [Double] = []
        var sensorIDs: [String] = []
        var singleWheelPressures: [Double] = []
        var singleWheelTemps: [Double] = []
        var source: TPMSReadSource = .none

        // Prioriza os DIDs que já responderam na descoberta para não perder tempo
        let prioritizedDIDs: [(hi: UInt8, lo: UInt8, kind: String)] = {
            if !module.respondingDIDs.isEmpty {
                let matching = Self.tpmsCandidateDIDs.filter { did in
                    let cmd = String(format: "22 %02X %02X", did.hi, did.lo)
                    return module.respondingDIDs.contains(cmd)
                }
                if !matching.isEmpty { return matching }
            }
            return Self.tpmsCandidateDIDs
        }()

        for did in prioritizedDIDs {
            let cmd = String(format: "22 %02X %02X", did.hi, did.lo)
            guard let (resp, ms) = try? await protocolEngine.execute(cmd, target: target, timeout: 0.9) else { continue }
            let upper = resp.uppercased()
            guard !upper.contains("NO DATA"), !upper.contains("7F"), OBDUDSParser.hasPositiveUDSResponse(resp, service: 0x22) else { continue }
            logTrace(command: "[TPMS \(module.txHeader)/\(module.rxHeader)] \(cmd)", response: resp, durationMs: ms)

            if pressureValues.isEmpty {
                let block = OBDUDSParser.tpmsPressureBlock(fromUDS: resp, wheelCount: 4)
                if !block.isEmpty {
                    pressureValues = block
                    source = .udsModule
                } else if let singleP = Self.extractSingleWheelPressureAndTemp(fromUDS: resp, didHi: did.hi, didLo: did.lo) {
                    singleWheelPressures.append(singleP.pressureKpa)
                    if let t = singleP.tempC { singleWheelTemps.append(t) }
                    if singleWheelPressures.count == 4 {
                        pressureValues = singleWheelPressures
                        if singleWheelTemps.count == 4 && tempValues.isEmpty { tempValues = singleWheelTemps }
                        source = .udsModule
                    }
                }
            }
            if tempValues.isEmpty {
                let tBlock = OBDUDSParser.tpmsTemperatureBlock(fromUDS: resp, wheelCount: 4)
                if !tBlock.isEmpty { tempValues = tBlock }
            }
            if sensorIDs.isEmpty {
                let ids = OBDUDSParser.tpmsSensorIDs(fromUDS: resp)
                if ids.count >= 4 { sensorIDs = Array(ids.prefix(4)) }
            }
        }

        // Fallback: módulo respondeu mas não expôs pressões nos DIDs sondados.
        // Antes de dizer "não tem", procura os 4 valores num quadro do próprio barramento.
        var broadcastCanId: String?
        if pressureValues.isEmpty, let broadcast = await readTPMSPressuresFromBroadcast() {
            pressureValues = broadcast.pressures
            broadcastCanId = broadcast.canId
            source = .canBroadcast
        }

        for (i, pos) in WheelPosition.roadWheels.enumerated() {
            if i < pressureValues.count { tires[i].pressureKpa = pressureValues[i] }
            if i < tempValues.count { tires[i].temperatureC = tempValues[i] }
            if i < sensorIDs.count { tires[i].sensorIdHex = sensorIDs[i] }
            tires[i] = TireReading(
                position: pos,
                pressureKpa: tires[i].pressureKpa,
                temperatureC: tires[i].temperatureC,
                sensorIdHex: tires[i].sensorIdHex,
                sensorMissing: tires[i].pressureKpa == nil && tires[i].sensorIdHex == nil
            )
        }

        let snapshot = TPMSSnapshot(
            tires: tires,
            source: source,
            moduleHeaderTx: broadcastCanId ?? module.txHeader,
            moduleHeaderRx: broadcastCanId == nil ? module.rxHeader : nil,
            systemWarnings: await readTPMSWarnings(target: target)
        )
        tpmsSnapshot = snapshot
        if snapshot.hasAnyReading {
            confirmedTPMSModule = module
            persistTPMSModule(module)
            tpmsStatusText = broadcastCanId == nil
                ? "Leitura concluída: \(snapshot.reportingCount) pneu(s) reportando no módulo 0x\(module.txHeader) → 0x\(module.rxHeader)."
                : "Leitura concluída: \(snapshot.reportingCount) pneu(s) lidos do quadro CAN 0x\(broadcastCanId ?? "")."
        } else {
            tpmsStatusText = "O módulo 0x\(module.txHeader) → 0x\(module.rxHeader) respondeu UDS, mas não expôs os 4 pneus nos DIDs sondados. Veja 'Detalhes técnicos' abaixo."
        }
    }

    /// Lê os 4 pneus de um quadro transmitido no barramento (sem UDS). Cobre 2XX–5XX,
    /// onde muitos carros publicam os dados de carroceria/conforto.
    private func readTPMSPressuresFromBroadcast() async -> (canId: String, pressures: [Double])? {
        for mask in ["2XX", "3XX", "4XX", "5XX"] {
            guard let raw = try? await protocolEngine.sniffBroadcastWindow(durationSeconds: 0.5, craFilter: mask) else { continue }
            let frames = OBDUDSParser.parseCANFrames(raw)
            for (canId, bytes) in frames.sorted(by: { $0.key < $1.key }) where bytes.count >= 4 {
                let block = OBDUDSParser.tpmsPressureBlock(fromCANBytes: bytes)
                if block.count == 4 {
                    logTrace(command: "[TPMS CAN \(canId)] 4 pressões", response: bytes.map { String(format: "%02X", $0) }.joined(separator: " "), durationMs: 0)
                    return (canId, block)
                }
            }
        }
        return nil
    }

    private func buildBroadcastSnapshot(canId: String, pressures: [Double]) -> TPMSSnapshot {
        var tires = WheelPosition.roadWheels.map { TireReading(position: $0) }
        for i in tires.indices where i < pressures.count {
            tires[i].pressureKpa = pressures[i]
            tires[i].sensorMissing = false
        }
        return TPMSSnapshot(tires: tires, source: .canBroadcast, moduleHeaderTx: canId, moduleHeaderRx: nil, systemWarnings: [])
    }

    /// Extrai pressão (e temperatura opcional) quando um DID representa uma única roda (ex.: 02 01..02 04 ou D0 01..D0 04).
    private static func extractSingleWheelPressureAndTemp(fromUDS raw: String, didHi: UInt8, didLo: UInt8) -> (pressureKpa: Double, tempC: Double?)? {
        let bytes = OBDUDSParser.extractPayloadBytes(from: raw)
        guard let idx = bytes.firstIndex(of: 0x62), idx + 3 < bytes.count,
              bytes[idx + 1] == didHi, bytes[idx + 2] == didLo else { return nil }
        let payload = Array(bytes[(idx + 3)...])
        guard payload.count >= 1 && payload.count <= 6 else { return nil }
        for (i, b) in payload.enumerated() {
            if let p = OBDUDSParser.tpmsPressureKpa(fromByte: b), p >= 150 && p <= 360 {
                let temp = (i + 1 < payload.count) ? OBDUDSParser.tpmsTemperatureC(fromByte: payload[i + 1]) : nil
                return (p, temp)
            }
        }
        return nil
    }

    /// Descobre automaticamente os módulos ativos no barramento usando filtro wildcard `AT CRA 7XX`
    /// (captura tanto respostas `TX + 0x08` quanto `TX + 0x10` / `TX + 0x80`) e sonda os DIDs de TPMS.
    @discardableResult
    public func discoverTPMSModule(deep: Bool = false) async -> TPMSModuleCandidate? {
        var found: [TPMSModuleCandidate] = []
        var best: TPMSModuleCandidate?

        // 1. Descoberta rápida com wildcard `AT CRA 7XX` para achar os pares (TX, RX) reais que respondem neste veículo
        let uniqueTxProbes: [(tx: String, fallbackRx: String, label: String)] = [
            ("740", "750", "BCM / Carroceria"),
            ("760", "770", "BCM / Conforto & TPMS"),
            ("765", "775", "BCM / Canal B"),
            ("7A0", "7A8", "Módulo TPMS / Multimídia"),
            ("726", "72E", "Carroceria (alt.)"),
            ("750", "758", "Conforto / Clima"),
            ("710", "718", "Painel de Instrumentos (ICM)"),
            ("730", "738", "Chassi / Estabilidade"),
            ("721", "729", "TPMS dedicado")
        ]

        let wildcardHits = await protocolEngine.discoverUDSModulesWildcard7XX(candidates: uniqueTxProbes) { [weak self] msg in
            Task { @MainActor in
                self?.tpmsStatusText = msg
            }
        }

        // Varredura completa: em vez de confiar só na lista fixa, sonda todo o range 0x700–0x77F.
        var probes: [(tx: String, rx: String, label: String)] = wildcardHits.map { ($0.tx, $0.rx, $0.label) }
        if deep {
            tpmsStatusText = "Varredura completa: sondando 0x700–0x77F..."
            let swept = await protocolEngine.sweepUDSModules7XX { [weak self] msg in
                Task { @MainActor in self?.tpmsStatusText = msg }
            }
            for hit in swept where !probes.contains(where: { $0.tx == hit.tx }) {
                probes.append((hit.tx, hit.rx, "Módulo 0x\(hit.tx) (varredura)"))
            }
            TissotFeedback.log("TPMS_SWEEP_7XX", [
                "hits": swept.map { "\($0.tx)/\($0.rx)" }.joined(separator: "|"),
                "count": swept.count
            ])
        }

        let modulesToProbe: [(tx: String, rx: String, label: String)] = probes.isEmpty
            ? Self.tpmsCandidateModules
            : probes

        var rawPositiveDumps: [String] = []
        var sessionDumps: [String] = []

        for cand in modulesToProbe {
            tpmsStatusText = "Sondando DIDs de pneu em 0x\(cand.tx) → 0x\(cand.rx) (\(cand.label))..."
            let target = CANTarget(tx: cand.tx, rx: cand.rx)
            var responding: [String] = []
            var looksLikeTPMS = false
            var identifier: String?
            var singleWheelHits = 0

            // Abre sessão diagnóstica estendida (10 03) para destravar leitura de DIDs de carroceria/TPMS
            let (sessResp, _) = (try? await protocolEngine.execute("10 03", target: target, timeout: 0.9)) ?? ("", 0)
            let cleanSess = OBDUDSParser.extractPayloadBytes(from: sessResp).map { String(format: "%02X", $0) }.joined(separator: " ")
            sessionDumps.append("\(cand.tx)/\(cand.rx):\(cleanSess.isEmpty ? "sem resposta" : cleanSess)")
            let moduleAlive = sessResp.uppercased().contains("50") || sessResp.uppercased().contains("7F")

            if let (idResp, _) = try? await protocolEngine.execute("22 F1 97", target: target, timeout: 0.9),
               OBDUDSParser.hasPositiveUDSResponse(idResp, service: 0x22) {
                identifier = OBDUDSParser.parseASCIIIdentifier(idResp)
            }

            var consecutiveTimeouts = 0
            // Módulo que respondeu `10 03` merece a lista inteira: o DID do pneu pode estar depois dos
            // quatro primeiros. Bug antigo: parava em `D0 04`, reportava `dids:0` e concluía
            // "não expôs os pneus" sem nunca ter tentado `C1 00`, `F4 05`, `02 01`...
            // A varredura curta (2 timeouts) fica só para endereço que não deu sinal de vida.
            for did in Self.tpmsCandidateDIDs {
                let cmd = String(format: "22 %02X %02X", did.hi, did.lo)
                let didTimeout = moduleAlive ? 0.55 : 0.75
                guard let (resp, ms) = try? await protocolEngine.execute(cmd, target: target, timeout: didTimeout) else {
                    consecutiveTimeouts += 1
                    if !moduleAlive && consecutiveTimeouts >= 2 { break }
                    continue
                }
                let upper = resp.uppercased()
                if upper.contains("NO DATA") {
                    consecutiveTimeouts += 1
                    if !moduleAlive { break }
                    continue
                }
                consecutiveTimeouts = 0
                guard OBDUDSParser.hasPositiveUDSResponse(resp, service: 0x22), !upper.contains("7F") else { continue }
                responding.append(cmd)
                let cleanHex = OBDUDSParser.extractPayloadBytes(from: resp).map { String(format: "%02X", $0) }.joined(separator: " ")
                rawPositiveDumps.append("\(cand.tx)/\(cand.rx)[\(cmd)]=\(cleanHex)")
                logTrace(command: "[TPMS? \(cand.tx)/\(cand.rx)] \(cmd)", response: resp, durationMs: ms)

                if !OBDUDSParser.tpmsPressureBlock(fromUDS: resp, wheelCount: 4).isEmpty
                    || OBDUDSParser.tpmsSensorIDs(fromUDS: resp).count >= 4 {
                    looksLikeTPMS = true
                } else if Self.extractSingleWheelPressureAndTemp(fromUDS: resp, didHi: did.hi, didLo: did.lo) != nil {
                    singleWheelHits += 1
                    if singleWheelHits >= 2 { looksLikeTPMS = true }
                }
            }

            if !responding.isEmpty || identifier != nil || moduleAlive {
                let c = TPMSModuleCandidate(
                    txHeader: cand.tx,
                    rxHeader: cand.rx,
                    identifier: identifier ?? cand.label,
                    respondingDIDs: responding,
                    looksLikeTPMS: looksLikeTPMS
                )
                found.append(c)
                if looksLikeTPMS && best == nil { best = c }
            }
        }

        TissotFeedback.log("TPMS_DISCOVERY_SUMMARY", [
            "deep": deep,
            "probed": modulesToProbe.map { "\($0.tx)/\($0.rx)" }.joined(separator: ","),
            "modules_found": found.map { "\($0.txHeader)/\($0.rxHeader)(tpms:\($0.looksLikeTPMS),dids:\($0.respondingDIDs.count))" }.joined(separator: "|"),
            "positive_dids": String(rawPositiveDumps.joined(separator: ";").prefix(1200)),
            "session_dumps": String(sessionDumps.joined(separator: ";").prefix(800))
        ])

        tpmsModuleCandidates = found
        let chosen = best ?? found.first(where: { $0.looksLikeTPMS })
        if let chosen {
            // Só guarda como "módulo TPMS" quando há evidência de pneu; senão o app ficava preso
            // num BCM que responde sessão mas não tem DID de pneu.
            confirmedTPMSModule = chosen
            persistTPMSModule(chosen)
        } else {
            confirmedTPMSModule = nil
        }
        return chosen
    }

    /// Lê os IDs de sensor que o módulo do carro tem GRAVADOS hoje.
    /// Serve para o caminho mais barato do pareamento: clonar esses IDs em sensores programáveis
    /// (NFC/pelo celular) e não precisar de relearn nenhum. Também confirma se o módulo ainda
    /// guarda os sensores antigos depois da troca.
    public func readTPMSStoredIDs() async {
        guard connectionState == .connectedReady else {
            tpmsStatusText = "Conecte ao vLinker MC+ no carro para ler os IDs gravados."
            return
        }
        isReadingTPMS = true
        pausePollingCounter += 1
        defer {
            pausePollingCounter = max(0, pausePollingCounter - 1)
            isReadingTPMS = false
        }

        var found = confirmedTPMSModule
        if found == nil {
            found = await discoverTPMSModule()
        }
        guard var module = found else {
            tpmsStatusText = "Nenhum módulo respondeu. Rode a 'Varredura completa' primeiro."
            return
        }
        // Se o módulo achado não tem evidência de pneu, tenta a varredura ampla antes de desistir.
        if !module.looksLikeTPMS, let deep = await discoverTPMSModule(deep: true), deep.looksLikeTPMS {
            module = deep
        }

        let target = CANTarget(tx: module.txHeader, rx: module.rxHeader)
        _ = try? await protocolEngine.execute("10 03", target: target, timeout: 1.0)
        let ids = await readCurrentSensorIDs(target: target)

        TissotFeedback.log("TPMS_STORED_IDS", [
            "module": "\(module.txHeader)/\(module.rxHeader)",
            "ids": ids.joined(separator: " "),
            "count": ids.count
        ])

        if ids.isEmpty {
            tpmsStatusText = "O módulo 0x\(module.txHeader) → 0x\(module.rxHeader) não devolveu IDs nos DIDs conhecidos. Envie o relato com esta tela aberta."
        } else {
            tpmsStatusText = "IDs gravados no módulo (0x\(module.txHeader)): \(ids.joined(separator: " • "))"
        }
    }

    /// Varredura completa pedida pelo usuário: sonda todo o range 0x700–0x77F e, se nenhum módulo
    /// expuser pressão por UDS, tenta as 4 pressões num quadro do barramento.
    public func deepScanTPMS() async {
        guard connectionState == .connectedReady else {
            tpmsStatusText = "Conecte ao vLinker MC+ no carro para varrer os módulos."
            return
        }
        forgetTPMSModule()
        tpmsStatusText = "Varredura completa dos módulos (0x700–0x77F)..."
        let found = await discoverTPMSModule(deep: true)
        if found?.looksLikeTPMS == true {
            await readTPMS()
        } else if let broadcast = await readTPMSPressuresFromBroadcast() {
            tpmsSnapshot = buildBroadcastSnapshot(canId: broadcast.canId, pressures: broadcast.pressures)
            tpmsStatusText = "A varredura não achou módulo de TPMS por UDS, mas o barramento traz as 4 pressões (CAN 0x\(broadcast.canId))."
        } else {
            tpmsStatusText = "Varredura concluída: nenhum módulo expôs pressão e nenhum quadro trouxe as 4 pressões. Envie o relato com esta tela aberta."
        }
    }

    /// Lê os DTCs do módulo TPMS (UDS 19 02) e traduz os mais comuns para linguagem simples.
    private func readTPMSWarnings(target: CANTarget) async -> [String] {
        guard let (resp, ms) = try? await protocolEngine.execute("19 02 FF", target: target, timeout: 1.8),
              OBDUDSParser.hasPositiveUDSResponse(resp, service: 0x19) else { return [] }
        logTrace(command: "[TPMS \(target.tx)] 19 02 FF", response: resp, durationMs: ms)
        let module = ECUTargetModule(id: "TPMS", code: "TPMS", name: "Monitoramento de Pressão dos Pneus", txHeader: target.tx, rxHeader: target.rx ?? "", systemCategory: "TPMS")
        let faults = OBDUDSParser.parseUDS1902DTCs(resp, module: module)
        return faults.map { "\($0.displayCode): \($0.interpretation.headline)" }
    }

    private func persistTPMSModule(_ module: TPMSModuleCandidate) {
        if let data = try? JSONEncoder().encode(module) {
            UserDefaults.standard.set(data, forKey: tpmsModuleKey)
        }
    }

    public func forgetTPMSModule() {
        confirmedTPMSModule = nil
        tpmsModuleCandidates = []
        UserDefaults.standard.removeObject(forKey: tpmsModuleKey)
    }

    // MARK: Assistente de pareamento (gravar IDs novos no módulo)

    /// Grava os IDs de sensor informados nas posições das rodas, no módulo TPMS do carro.
    /// Experimental e dependente do fabricante: alguns módulos exigem SecurityAccess (27) com chave
    /// proprietária, e aí o pareamento por OBD não é possível sem a ferramenta da concessionária.
    /// `sensorIDsByWheel`: ID hex de 8 dígitos (4 bytes) por roda, lido no próprio sensor ou pela ativação.
    public func pairTPMSSensors(sensorIDsByWheel: [WheelPosition: String]) async {
        guard connectionState == .connectedReady else {
            appendPairingLog(command: "-", response: "-", interpretation: "Conecte ao vLinker MC+ com a ignição ligada e o motor desligado.", success: false)
            pairingStage = .failed
            return
        }
        isPairingTPMS = true
        pausePollingCounter += 1
        pairingLog = []
        defer {
            pausePollingCounter = max(0, pausePollingCounter - 1)
            isPairingTPMS = false
        }

        // 1. Localiza o módulo
        pairingStage = .locatingModule
        var module = confirmedTPMSModule
        if module == nil { module = await discoverTPMSModule() }
        guard let module else {
            appendPairingLog(command: "descoberta", response: "nenhum módulo", interpretation: "Não achei o módulo de TPMS. Rode a leitura primeiro.", success: false)
            pairingStage = .failed
            return
        }
        let target = CANTarget(tx: module.txHeader, rx: module.rxHeader)
        appendPairingLog(command: "módulo", response: "0x\(module.txHeader)", interpretation: "Usando o módulo 0x\(module.txHeader) para o pareamento.", success: true)

        // 2. Lê os IDs atuais (para comparar depois)
        pairingStage = .readingCurrentIDs
        let before = await readCurrentSensorIDs(target: target)
        appendPairingLog(command: "22 (IDs atuais)", response: before.isEmpty ? "nenhum" : before.joined(separator: " "), interpretation: before.isEmpty ? "O módulo não devolveu IDs gravados agora." : "IDs atuais lidos.", success: true)

        // 3. Sessão diagnóstica estendida
        pairingStage = .openingSession
        guard let (sess, _) = try? await protocolEngine.execute("10 03", target: target, timeout: 1.5) else {
            appendPairingLog(command: "10 03", response: "sem resposta", interpretation: "O módulo não abriu sessão estendida. Pareamento interrompido.", success: false)
            pairingStage = .failed
            return
        }
        let sessOK = sess.uppercased().contains("50 03")
        appendPairingLog(command: "10 03", response: sess, interpretation: sessOK ? "Sessão estendida aberta." : "O módulo recusou a sessão estendida (resposta \(sess.trimmingCharacters(in: .whitespacesAndNewlines))).", success: sessOK)
        if !sessOK { pairingStage = .failed; return }

        // 4. Tenta rotina de relearn (31 01) — muitos carros aprendem os sensores que estão transmitindo.
        pairingStage = .writingIDs
        var anyWriteOK = false
        if let (routine, rms) = try? await protocolEngine.execute("31 01 FF 00", target: target, timeout: 2.0) {
            let ok = routine.uppercased().contains("71 01")
            appendPairingLog(command: "31 01 FF 00 (relearn)", response: routine, interpretation: ok ? "Rotina de aprendizado aceita. Alguns carros aprendem só rodando com os pneus calibrados." : "Rotina de aprendizado não aceita neste módulo.", success: ok)
            anyWriteOK = anyWriteOK || ok
            _ = rms
        }

        // 5. Grava cada ID informado via WriteDataByIdentifier (2E). O DID de cada roda não é padronizado,
        //    então tenta os DIDs que já responderam como "IDs" na descoberta.
        let writeDIDs = Self.tpmsCandidateDIDs.filter { $0.kind == "IDs" }
        for pos in WheelPosition.roadWheels {
            guard let idHex = sensorIDsByWheel[pos], idHex.count == 8,
                  let idBytes = Self.hexToBytes(idHex) else { continue }
            var wrote = false
            for did in writeDIDs {
                let cmd = String(format: "2E %02X %02X %@", did.hi, did.lo, idBytes.map { String(format: "%02X", $0) }.joined(separator: " "))
                guard let (resp, _) = try? await protocolEngine.execute(cmd, target: target, timeout: 1.8) else { continue }
                let ok = resp.uppercased().contains("6E")
                appendPairingLog(command: "\(pos.shortLabel): \(cmd)", response: resp, interpretation: ok ? "ID gravado para \(pos.label)." : interpretWriteError(resp), success: ok)
                if ok { wrote = true; anyWriteOK = true; break }
                if resp.uppercased().contains("7F 2E 33") || resp.uppercased().contains("7F 2E 35") {
                    pairingStage = .securityAccess
                    appendPairingLog(command: "27 01", response: "necessário", interpretation: "O módulo exige desbloqueio de segurança (SecurityAccess) com chave do fabricante. Sem essa chave, o pareamento por OBD não é possível neste carro — é o caso em que só a concessionária resolve.", success: false)
                    break
                }
            }
            _ = wrote
        }

        // 6. Verifica
        pairingStage = .verifying
_ = try? await protocolEngine.execute("10 01", target: target, timeout: 1.0) // volta à sessão padrão
        let after = await readCurrentSensorIDs(target: target)
        appendPairingLog(command: "22 (IDs após)", response: after.isEmpty ? "nenhum" : after.joined(separator: " "), interpretation: after.isEmpty ? "O módulo não devolveu IDs para confirmar." : "IDs após o pareamento lidos.", success: !after.isEmpty)

        let changed = after != before && !after.isEmpty
        if anyWriteOK || changed {
            pairingStage = .done
            tpmsStatusText = "Pareamento enviado. Calibre os pneus na pressão correta e rode alguns minutos para o painel confirmar."
        } else {
            pairingStage = .failed
            tpmsStatusText = "Não consegui confirmar a gravação dos IDs neste carro. Veja o registro passo a passo."
        }
        await readTPMS()
    }

    private func readCurrentSensorIDs(target: CANTarget) async -> [String] {
        for did in Self.tpmsCandidateDIDs where did.kind == "IDs" {
            let cmd = String(format: "22 %02X %02X", did.hi, did.lo)
            if let (resp, _) = try? await protocolEngine.execute(cmd, target: target, timeout: 1.2),
               OBDUDSParser.hasPositiveUDSResponse(resp, service: 0x22) {
                let ids = OBDUDSParser.tpmsSensorIDs(fromUDS: resp)
                if !ids.isEmpty { return Array(ids.prefix(4)) }
            }
        }
        return []
    }

    private func interpretWriteError(_ resp: String) -> String {
        let u = resp.uppercased()
        if u.contains("7F 2E 31") { return "O módulo recusou o DID (requestOutOfRange): este não é o endereço de ID deste carro." }
        if u.contains("7F 2E 22") { return "Condição não atendida: ligue a ignição com o motor desligado e o carro parado." }
        if u.contains("7F 2E 7F") || u.contains("7F 2E 11") { return "Serviço não suportado neste módulo." }
        return "Gravação não confirmada (resposta \(resp.trimmingCharacters(in: .whitespacesAndNewlines)))."
    }

    private func appendPairingLog(command: String, response: String, interpretation: String, success: Bool) {
        pairingLog.append(TPMSPairingLogEntry(command: command, response: response, interpretation: interpretation, success: success))
    }

    static func hexToBytes(_ hex: String) -> [UInt8]? {
        let clean = hex.filter { $0.isHexDigit }
        guard clean.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            guard let b = UInt8(clean[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        return bytes
    }
}
