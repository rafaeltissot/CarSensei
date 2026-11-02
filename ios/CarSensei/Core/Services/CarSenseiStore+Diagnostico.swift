import Foundation

// MARK: - Varredura multimódulo (OBD-II + UDS $19) e limpeza segura de falhas (KOEO)

extension CarSenseiStore {

    /// Estado atual da condição KOEO (Key On, Engine Off — Ignição Ligada, Motor Desligado e Carro Parado)
    /// exigida pela norma ISO 14229 / SAE J1979 para enviar `14 FF FF FF` ou `04` com segurança.
    public var koeoClearSafetyAssessment: (canClear: Bool, badgeText: String, detailText: String) {
        guard connectionState == .connectedReady else {
            return (
                false,
                "Scanner desconectado",
                "Conecte ao vLinker MC+ com a ignição ligada e o motor desligado (0 RPM) para liberar a limpeza."
            )
        }
        // Sem leitura de RPM e velocidade não existe KOEO confirmado: a trava é fechada por padrão.
        guard let speed = liveTelemetry.speedKmh, let rpm = liveTelemetry.rpm else {
            return (
                false,
                "Aguardando leitura de RPM e velocidade",
                "A limpeza só é liberada depois de ler a rotação (PID 01 0C) e a velocidade (PID 01 0D) do carro. Ligue a ignição (painel aceso) e toque em Escanear Veículo."
            )
        }
        if speed > 0.5 {
            return (
                false,
                "BLOQUEADO: Carro em movimento (\(Int(speed)) km/h)",
                "Nunca apague códigos com o veículo andando. Isso pode reiniciar solenoides do câmbio CVT e controle de estabilidade (ABS/ESP)."
            )
        }
        if rpm > 50 {
            return (
                false,
                "BLOQUEADO: Motor ligado (\(Int(rpm)) RPM)",
                "Desligue o motor e mantenha apenas a ignição ligada (painel aceso, 0 RPM) antes de limpar as falhas."
            )
        }
        return (
            true,
            "Pronto para Limpeza Segura (KOEO: 0 RPM • 0 km/h)",
            "Ignição ligada com motor desligado e veículo parado. O CarSensei fará uma checagem em tempo real no CAN antes de apagar."
        )
    }

    public func runFullDiagnosticScan() async {
        guard connectionState == .connectedReady else {
            statusBannerText = "Conecte ao Scanner BLE no carro para escanear os módulos"
            return
        }

        pausePollingCounter += 1
        isScanningDTCs = true
        var discovered: [DiagnosticFault] = []
        /// Quantos módulos responderam de verdade. Sem isso, "0 falhas" seria indistinguível de "barramento mudo".
        var respondedModules = 0

        defer {
            pausePollingCounter = max(0, pausePollingCounter - 1)
            isScanningDTCs = false
            dtcScanProgressText = ""
        }

        // 1. OBD-II padrão em broadcast (modos 03 e 07)
        dtcScanProgressText = "Lendo falhas de Injeção OBD-II (Modos 03 / 07)..."
        if let (r03, ms03) = try? await protocolEngine.execute("03", target: .broadcast, timeout: 2.5) {
            logTrace(command: "03", response: r03, durationMs: ms03)
            if Self.isPositiveCANResponse(r03, service: 0x03) { respondedModules += 1 }
            discovered.append(contentsOf: OBDUDSParser.parseStandardOBDDTCs(r03, modeResponseByte: 0x43, isActiveMode: true))
        }
        if let (r07, ms07) = try? await protocolEngine.execute("07", target: .broadcast, timeout: 2.5) {
            logTrace(command: "07", response: r07, durationMs: ms07)
            if Self.isPositiveCANResponse(r07, service: 0x07) { respondedModules += 1 }
            discovered.append(contentsOf: OBDUDSParser.parseStandardOBDDTCs(r07, modeResponseByte: 0x47, isActiveMode: false))
        }

        // 2. UDS $19 em cada módulo (endereços comuns), com endereços alternativos
        for module in ECUTargetModule.multiBrandModules {
            dtcScanProgressText = "Escaneando \(module.code) (\(module.name))..."
            let candidates = [CANTarget(tx: module.txHeader, rx: module.rxHeader)]
                + module.fallbackHeaders.map { CANTarget(tx: $0.tx, rx: $0.rx) }

            for target in candidates {
                guard let (udsResp, ms) = try? await protocolEngine.execute("19 02 FF", target: target, timeout: 2.2) else { continue }
                logTrace(command: "[\(module.code) \(target.tx)] 19 02 FF", response: udsResp, durationMs: ms)
                if Self.isPositiveCANResponse(udsResp, service: 0x19) { respondedModules += 1 }
                var moduleFaults = OBDUDSParser.parseUDS1902DTCs(udsResp, module: module)

                for idx in moduleFaults.indices {
                    let rawDTC = moduleFaults[idx].rawDTCBytesHex
                    if rawDTC.count == 6 {
                        let d0 = rawDTC.prefix(2)
                        let d1 = rawDTC.dropFirst(2).prefix(2)
                        let d2 = rawDTC.suffix(2)
                        let snapCmd = "19 04 \(d0) \(d1) \(d2) FF"
                        if let (snapResp, snapMs) = try? await protocolEngine.execute(snapCmd, target: target, timeout: 2.2),
                           !snapResp.uppercased().contains("NO DATA"),
                           !snapResp.uppercased().contains("7F") {
                            logTrace(command: "[\(module.code)] \(snapCmd)", response: snapResp, durationMs: snapMs)
                            let occurrences = OBDUDSParser.parseUDSSnapshotOccurrences(snapResp)
                            moduleFaults[idx].freezeFrame = FreezeFrameSnapshot(
                                dtcCode: moduleFaults[idx].displayCode,
                                rpm: liveTelemetry.rpm,
                                speedKmh: occurrences.last?.vehicleSpeedKmh ?? liveTelemetry.speedKmh,
                                coolantTempC: occurrences.last?.coolantTempC ?? liveTelemetry.coolantTempC,
                                engineLoadPct: liveTelemetry.engineLoadPct,
                                snapshotOdometerKm: occurrences.compactMap(\.odometerKm).max(),
                                rawUDSHex: snapResp,
                                occurrences: occurrences.isEmpty ? nil : occurrences
                            )
                        }
                    }

                    if !discovered.contains(where: { $0.id == moduleFaults[idx].id }) {
                        discovered.append(moduleFaults[idx])
                    }
                }

                if !moduleFaults.isEmpty || udsResp.contains("59 02") {
                    break
                }
            }
        }

        let currentVIN = OBDUDSParser.normalizedVIN(vehicleIdentity.vin)
        let currentModel = vehicleIdentity.cleanModelTitle
        for idx in discovered.indices {
            discovered[idx].vehicleVIN = currentVIN
            discovered[idx].vehicleModel = currentModel
        }

        activeFaults = discovered
        lastDTCScanDate = Date()
        dtcScanNoResponse = respondedModules == 0
        archiveDiscoveredFaults(discovered)

        TissotFeedback.log("DTC_SCAN_COMPLETED", ["count": discovered.count, "respondedModules": respondedModules])
        if respondedModules == 0 {
            statusBannerText = "Nenhum módulo respondeu. Confira a ignição ligada e o adaptador no conector OBD."
        } else {
            statusBannerText = discovered.isEmpty
                ? "Varredura concluída: 0 falhas nos módulos!"
                : "Varredura concluída: \(discovered.count) aviso(s) identificado(s)."
        }
    }

    /// Resposta positiva = o módulo confirmou o serviço (`$40 + serviço`) e não é mensagem de erro do adaptador.
    static func isPositiveCANResponse(_ raw: String, service: UInt8) -> Bool {
        let upper = raw.uppercased()
        guard !upper.isEmpty else { return false }
        for marker in ["NO DATA", "ERROR", "UNABLE", "STOPPED", "SEARCHING", "BUS INIT", "<DATA ERROR"] where upper.contains(marker) {
            return false
        }
        let expected = String(format: "%02X", Int(service) + 0x40)
        return upper.contains(expected)
    }

    /// Limpa os códigos de falha em todos os módulos SOMENTE após validar em tempo real no barramento CAN
    /// que o veículo está no estado KOEO (Key On, Engine Off: Ignição Ligada, Motor Desligado 0 RPM e Velocidade 0 km/h).
    public func clearAllFaults() async {
        guard connectionState == .connectedReady else {
            statusBannerText = "Conecte ao Scanner BLE para apagar os avisos"
            clearFaultsSafetyError = "Conecte ao vLinker MC+ com a ignição ligada e o motor desligado antes de limpar as falhas."
            return
        }

        pausePollingCounter += 1
        isScanningDTCs = true
        defer {
            pausePollingCounter = max(0, pausePollingCounter - 1)
            isScanningDTCs = false
            dtcScanProgressText = ""
        }

        // VERIFICAÇÃO CRÍTICA DE SEGURANÇA EM TEMPO REAL (KOEO: Ignição Ligada + Motor Desligado + Veículo Parado)
        dtcScanProgressText = "Verificando segurança KOEO (Ignição Ligada, 0 RPM e 0 km/h)..."
        var verifiedRPM: Double? = nil
        var verifiedSpeed: Double? = nil
        var ecuAwake = false

        if let (koeoResp, msKoeo) = try? await protocolEngine.execute("01 0C 0D", target: .broadcast, timeout: 1.8) {
            logTrace(command: "01 0C 0D (KOEO Check)", response: koeoResp, durationMs: msKoeo)
            var checkSnapshot = TelemetrySnapshot()
            OBDUDSParser.parseMode01Response(koeoResp, into: &checkSnapshot)
            if let r = checkSnapshot.rpm {
                verifiedRPM = r
                liveTelemetry.rpm = r
                ecuAwake = true
            }
            if let s = checkSnapshot.speedKmh {
                verifiedSpeed = s
                liveTelemetry.speedKmh = s
                ecuAwake = true
            }
        }

        // Fallback individual caso o veículo não responda multi-PID em broadcast
        if verifiedRPM == nil {
            if let (rpmResp, msRpm) = try? await protocolEngine.execute("01 0C", target: .ecm, timeout: 1.5) {
                logTrace(command: "01 0C (KOEO RPM)", response: rpmResp, durationMs: msRpm)
                var checkSnapshot = TelemetrySnapshot()
                OBDUDSParser.parseMode01Response(rpmResp, into: &checkSnapshot)
                if let r = checkSnapshot.rpm {
                    verifiedRPM = r
                    liveTelemetry.rpm = r
                    ecuAwake = true
                }
            }
        }
        if verifiedSpeed == nil {
            if let (spdResp, msSpd) = try? await protocolEngine.execute("01 0D", target: .ecm, timeout: 1.5) {
                logTrace(command: "01 0D (KOEO Speed)", response: spdResp, durationMs: msSpd)
                var checkSnapshot = TelemetrySnapshot()
                OBDUDSParser.parseMode01Response(spdResp, into: &checkSnapshot)
                if let s = checkSnapshot.speedKmh {
                    verifiedSpeed = s
                    liveTelemetry.speedKmh = s
                    ecuAwake = true
                }
            }
        }

        if let (voltResp, _) = try? await protocolEngine.execute("AT RV", timeout: 1.2),
           let volts = OBDUDSParser.parseBatteryVoltage(voltResp) {
            liveTelemetry.batteryVoltage = volts
        }

        // 0. Trava fechada: só prossegue com as duas leituras frescas do barramento.
        // Sem RPM e velocidade confirmados no CAN agora, a limpeza não é enviada de jeito nenhum.
        guard let currentRPM = verifiedRPM, let currentSpeed = verifiedSpeed else {
            let missing = [
                verifiedRPM == nil ? "rotação (01 0C)" : nil,
                verifiedSpeed == nil ? "velocidade (01 0D)" : nil
            ].compactMap { $0 }.joined(separator: " e ")
            let msg = "Limpeza NÃO enviada: não foi possível ler \(missing) do veículo agora. A trava KOEO exige confirmar 0 RPM e 0 km/h no barramento antes de apagar falhas. Mantenha a ignição ligada e tente de novo."
            statusBannerText = "Limpeza cancelada: sem leitura de RPM/velocidade"
            clearFaultsSafetyError = msg
            TissotFeedback.log("DTC_CLEAR_BLOCKED_NO_KOEO_READING")
            return
        }

        // 1. Bloqueio absoluto se o veículo estiver em movimento
        if currentSpeed > 0.5 {
            let msg = String(
                format: "Operação Bloqueada por Segurança: O veículo está em movimento (%.0f km/h). Apagar falhas (UDS 14 / OBD 04) com o carro andando pode causar tranco no câmbio CVT e desativar momentaneamente o ABS/ESP. Estacione o veículo e desligue o motor.",
                currentSpeed
            )
            statusBannerText = "Limpeza bloqueada: veículo em movimento (\(Int(currentSpeed)) km/h)"
            clearFaultsSafetyError = msg
            TissotFeedback.log("DTC_CLEAR_BLOCKED_MOVING", ["speedKmh": currentSpeed])
            return
        }

        // 2. Bloqueio absoluto se o motor estiver ligado (RPM > 50)
        if currentRPM > 50 {
            let msg = String(
                format: "Trava de Segurança KOEO Ativa: O motor está funcionando (%.0f RPM). Para proteger os solenoides do câmbio CVT e evitar perda momentânea de calibração da injeção, desligue o motor e deixe APENAS a ignição ligada (painel aceso, 0 RPM) antes de limpar as falhas.",
                currentRPM
            )
            statusBannerText = "Limpeza bloqueada: desligue o motor (\(Int(currentRPM)) RPM)"
            clearFaultsSafetyError = msg
            TissotFeedback.log("DTC_CLEAR_BLOCKED_ENGINE_RUNNING", ["rpm": currentRPM])
            return
        }

        // 3. Bloqueio se a ignição estiver totalmente desligada (ECM não responde nem 01 00)
        if !ecuAwake {
            if let (probeResp, _) = try? await protocolEngine.execute("01 00", target: .ecm, timeout: 1.5),
               probeResp.contains("41 00") {
                ecuAwake = true
            }
        }
        if !ecuAwake {
            let msg = "Ignição Desligada: Os módulos eletrônicos (ECM/TCU) não responderam no barramento CAN. Ligue a ignição do veículo (painel aceso, sem dar partida no motor) e tente novamente."
            statusBannerText = "Limpeza cancelada: ligue a ignição (painel aceso, motor desligado)"
            clearFaultsSafetyError = msg
            TissotFeedback.log("DTC_CLEAR_BLOCKED_IGNITION_OFF")
            return
        }

        // Condição KOEO (Ignição Ligada + 0 RPM + 0 km/h) confirmada! Prossegue com segurança.
        archiveDiscoveredFaults(activeFaults)

        for module in ECUTargetModule.multiBrandModules {
            dtcScanProgressText = "KOEO Seguro • Limpando memória UDS de \(module.code)..."
            let candidates = [CANTarget(tx: module.txHeader, rx: module.rxHeader)]
                + module.fallbackHeaders.map { CANTarget(tx: $0.tx, rx: $0.rx) }
            for target in candidates {
                if let (resp, ms) = try? await protocolEngine.execute("14 FF FF FF", target: target, timeout: 2.0) {
                    logTrace(command: "[\(module.code) \(target.tx)] 14 FF FF FF", response: resp, durationMs: ms)
                    if resp.contains("54") { break }
                }
            }
        }

        dtcScanProgressText = "KOEO Seguro • Enviando limpeza global OBD-II (Modo 04)..."
        if let (r04, ms04) = try? await protocolEngine.execute("04", target: .broadcast, timeout: 2.5) {
            logTrace(command: "04 (Clear OBD-II)", response: r04, durationMs: ms04)
        }

        TissotFeedback.log("DTC_CLEAR_COMPLETED_KOEO")
        try? await Task.sleep(nanoseconds: 600_000_000)
        await runFullDiagnosticScan()
    }
}
