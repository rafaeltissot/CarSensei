import Foundation

// MARK: - Auditoria de quilometragem
//
// Regras para o laudo ser verdadeiro:
// - Só conta como prova o que foi lido de verdade. Módulo que não respondeu não aprova nada.
// - Odômetro independente do painel: só o da TCU (22 0B 5B). O PID 01 A6 da ECM costuma repetir o painel.
// - Snapshots (19 04) e distância desde a limpeza (01 31) são limites mínimos: pegam redução abaixo
//   daquele valor, mas não provam que o painel está certo.
// - Módulo com VIN diferente veio de outro carro e não serve para comparar KM.

extension CarSenseiStore {

    public func runOdometerForensicsAudit() async {
        guard let clusterKm = clusterKmValue else {
            statusBannerText = "Digite a quilometragem atual que aparece no painel do veículo"
            return
        }
        UserDefaults.standard.set(clusterKmInputText, forKey: clusterKmSavedKey)

        guard connectionState == .connectedReady else {
            statusBannerText = "Conecte ao vLinker MC+ no carro para auditar a quilometragem"
            return
        }

        pausePollingCounter += 1
        isRunningForensics = true
        defer {
            pausePollingCounter = max(0, pausePollingCounter - 1)
            isRunningForensics = false
            forensicsProgressText = ""
        }

        var evidences: [OdometerEvidenceItem] = []
        var highestKm = clusterKm
        var critical = false
        var attention = false
        var tcuMatchesCluster = false
        var kmProofsRead: [String] = []
        var kmProofsMissing: [String] = []
        let km = { (value: Double) in String(format: "%.0f km", value) }

        // PROVA 1: VIN de cada módulo (decide se a TCU é deste carro)
        forensicsProgressText = "Prova 1/5: Conferindo o chassi (VIN) gravado em cada módulo..."
        var moduleVins: [String: String] = [:]
        for mod in [
            (name: "ECM", target: CANTarget.ecm),
            (name: "TCU", target: CANTarget.tcu),
            (name: "ICM", target: CANTarget(tx: "710", rx: "718")),
            (name: "BDM", target: CANTarget(tx: "740", rx: "748"))
        ] {
            if let (vResp, ms) = try? await protocolEngine.execute("22 F1 90", target: mod.target, timeout: 1.8) {
                logTrace(command: "[\(mod.name)] 22 F1 90", response: vResp, durationMs: ms)
                if let vin = OBDUDSParser.parseVIN(vResp) {
                    moduleVins[mod.name] = vin
                }
            }
        }
        // A referência é a ECM (ou o VIN do 09 02, que também vem dela). A TCU nunca vira referência:
        // ela é justamente o módulo que pode ter vindo de outro carro.
        let referenceVin = moduleVins["ECM"] ?? OBDUDSParser.normalizedVIN(vehicleIdentity.vin)
        if let ecmVin = moduleVins["ECM"], OBDUDSParser.normalizedVIN(vehicleIdentity.vin) == nil {
            vehicleIdentity.vin = ecmVin
            applyDetectedProfile()
        }
        let foreignModules = referenceVin.map { ref in moduleVins.filter { $0.value != ref }.keys.sorted() } ?? []
        let tcuIsForeign = foreignModules.contains("TCU")
        let vinList = moduleVins.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: " | ")

        if let referenceVin, moduleVins.count >= 2 || (moduleVins.count == 1 && moduleVins["ECM"] == nil) {
            if foreignModules.isEmpty {
                evidences.append(OdometerEvidenceItem(
                    sourceModule: "Rede CAN",
                    checkTitle: "Chassi (VIN) igual entre os módulos",
                    commandSent: "22 F1 90",
                    rawHexResponse: vinList,
                    measuredValueText: "\(moduleVins.count) módulo(s) com o VIN \(referenceVin)",
                    status: .healthy,
                    forensicAnalysis: "Os módulos que informam VIN pertencem a este carro, então as comparações de KM abaixo são válidas."
                ))
            } else {
                attention = true
                evidences.append(OdometerEvidenceItem(
                    sourceModule: "Rede CAN",
                    checkTitle: "Chassi (VIN) diferente entre os módulos",
                    commandSent: "22 F1 90",
                    rawHexResponse: vinList,
                    measuredValueText: "VIN diferente em: \(foreignModules.joined(separator: ", "))",
                    status: .attention,
                    forensicAnalysis: "Esses módulos vieram de outro carro (troca ou reaproveitamento). A quilometragem gravada neles não serve para comparar com o painel."
                ))
            }
        } else {
            evidences.append(OdometerEvidenceItem(
                sourceModule: "Rede CAN",
                checkTitle: "Chassi (VIN) entre os módulos",
                commandSent: "22 F1 90",
                rawHexResponse: vinList.isEmpty ? "Sem resposta" : vinList,
                measuredValueText: "VIN lido em \(moduleVins.count) módulo(s)",
                status: .unknown,
                forensicAnalysis: "Menos de dois módulos informaram o VIN, então não dá para saber se algum módulo foi trocado."
            ))
        }

        // PROVA 2: Odômetro interno da TCU (independente do painel)
        forensicsProgressText = "Prova 2/5: Lendo o odômetro interno do câmbio (TCU 22 0B 5B)..."
        if let (tcuRaw, ms) = try? await protocolEngine.execute("22 0B 5B", target: .tcu, timeout: 2.0) {
            logTrace(command: "[TCU] 22 0B 5B", response: tcuRaw, durationMs: ms)
            if let tcuKm = OBDUDSParser.parseTCUOdometerKm(tcuRaw) {
                kmProofsRead.append("odômetro da TCU")
                liveTelemetry.tcuOdometerKm = tcuKm
                let diff = tcuKm - clusterKm
                let status: HealthLevel
                let analysis: String
                if tcuIsForeign {
                    status = .attention
                    analysis = "A TCU tem VIN de outro carro: os \(km(tcuKm)) dela não se comparam com o painel."
                } else if diff > 1500 {
                    // O DID do câmbio varia entre fabricantes: sozinho ele não reprova o carro. Só vira Alerta
                    // se outra prova (odômetro SAE, registros de falha, VIN) também reprovar.
                    status = .attention
                    highestKm = max(highestKm, tcuKm)
                    analysis = "O câmbio registra \(km(diff)) a mais que o painel. Pode ser painel com KM reduzido ou trocado, ou este câmbio guardar o dado em outro formato. Só é alerta quando outra prova confirma."
                } else if diff > 600 {
                    status = .attention
                    highestKm = max(highestKm, tcuKm)
                    analysis = "O câmbio registra \(km(diff)) a mais que o painel. Diferença acima do normal; vale conferir histórico de revisões."
                } else if diff < -1500 {
                    status = .attention
                    analysis = "O câmbio registra \(km(-diff)) a menos que o painel. Normalmente significa TCU trocada ou reprogramada; não indica redução do painel, mas impede esta comparação."
                } else if diff < -600 {
                    status = .attention
                    analysis = "O câmbio registra \(km(-diff)) a menos que o painel. Pode ser TCU reparada/trocada em algum momento."
                } else {
                    status = .healthy
                    tcuMatchesCluster = true
                    analysis = "O câmbio e o painel estão a \(km(abs(diff))) um do outro. Esta é a única leitura de KM independente do painel."
                }
                if status == .critical { critical = true } else if status == .attention { attention = true }
                evidences.append(OdometerEvidenceItem(
                    sourceModule: "TCU (Câmbio)",
                    checkTitle: "Odômetro interno do câmbio",
                    commandSent: "22 0B 5B",
                    rawHexResponse: tcuRaw,
                    measuredValueText: "\(km(tcuKm)) na TCU • painel \(km(clusterKm))",
                    numericKmValue: tcuKm,
                    status: status,
                    forensicAnalysis: analysis
                ))
            } else {
                kmProofsMissing.append("odômetro da TCU")
            }
        } else {
            kmProofsMissing.append("odômetro da TCU")
        }

        // PROVA 3: Odômetro SAE da ECM (PID 01 A6), normalmente cópia do painel
        forensicsProgressText = "Prova 3/5: Lendo o odômetro SAE da injeção (ECM 01 A6)..."
        if let (rA6, ms) = try? await protocolEngine.execute("01 A6", target: .ecm, timeout: 2.0),
           let ecmKm = OBDUDSParser.parseMode01OdometerKm(rA6) {
            logTrace(command: "[ECM] 01 A6", response: rA6, durationMs: ms)
            kmProofsRead.append("odômetro da ECM")
            let diff = ecmKm - clusterKm
            let status: HealthLevel = diff > 1500 ? .critical : (abs(diff) > 600 ? .attention : .healthy)
            if status == .critical { critical = true; highestKm = max(highestKm, ecmKm) } else if status == .attention { attention = true }
            evidences.append(OdometerEvidenceItem(
                sourceModule: "ECM (Motor)",
                checkTitle: "Odômetro SAE da injeção (PID 01 A6)",
                commandSent: "01 A6",
                rawHexResponse: rA6,
                measuredValueText: String(format: "%.1f km na ECM", ecmKm),
                numericKmValue: ecmKm,
                status: status,
                forensicAnalysis: status == .healthy
                    ? "Confere com o painel. Esse valor costuma vir do próprio painel, por isso confirma a leitura mas não é prova independente."
                    : "A ECM registra \(km(abs(diff))) \(diff > 0 ? "a mais" : "a menos") que o painel digitado. Confira se o KM digitado está certo."
            ))
        } else {
            kmProofsMissing.append("odômetro da ECM")
        }

        // PROVA 4: Distância desde a última limpeza de falhas (PID 01 31), limite mínimo
        forensicsProgressText = "Prova 4/5: Distância percorrida desde a última limpeza de falhas (01 31)..."
        var kmSinceClear: Int?
        if let (r31, ms) = try? await protocolEngine.execute("01 31", target: .ecm, timeout: 2.0),
           let value = OBDUDSParser.parseMode01TwoByteUInt(r31, pid: 0x31) {
            logTrace(command: "[ECM] 01 31", response: r31, durationMs: ms)
            kmSinceClear = value
            kmProofsRead.append("distância desde a limpeza")
            let impossible = Double(value) > clusterKm + 50
            if impossible { critical = true; highestKm = max(highestKm, Double(value)) }
            evidences.append(OdometerEvidenceItem(
                sourceModule: "ECM (Motor)",
                checkTitle: "Distância desde a última limpeza de falhas (PID 01 31)",
                commandSent: "01 31",
                rawHexResponse: r31,
                measuredValueText: "\(value) km desde a última limpeza",
                numericKmValue: Double(value),
                status: impossible ? .critical : .healthy,
                forensicAnalysis: impossible
                    ? "O motor rodou \(value) km desde a última limpeza, mais do que os \(km(clusterKm)) do painel. Isso é impossível com o painel original e correto."
                    : "Compatível: o painel tem pelo menos esses \(value) km. Esta prova só pega reduções abaixo desse valor\(value >= 65_535 ? " (contador no limite de 65.535 km)" : "")."
            ))
        } else {
            kmProofsMissing.append("distância desde a limpeza")
        }

        // PROVA 5: KM carimbado nos snapshots de falha da TCU (19 03 lista, 19 04 lê cada um), limite mínimo
        forensicsProgressText = "Prova 5/5: Lendo o KM gravado nos registros de falha do câmbio (19 03 / 19 04)..."
        var snapshotDTCs: [[UInt8]] = []
        if let (r1903, ms) = try? await protocolEngine.execute("19 03", target: .tcu, timeout: 2.2) {
            logTrace(command: "[TCU] 19 03", response: r1903, durationMs: ms)
            snapshotDTCs = OBDUDSParser.parseUDS1903SnapshotDTCs(r1903)
        }
        if snapshotDTCs.isEmpty,
           let tcuModule = ECUTargetModule.multiBrandModules.first(where: { $0.id == "TCU" }),
           let (r1902, _) = try? await protocolEngine.execute("19 02 FF", target: .tcu, timeout: 2.2) {
            snapshotDTCs = OBDUDSParser.parseUDS1902DTCs(r1902, module: tcuModule).compactMap { fault in
                let hex = fault.rawDTCBytesHex
                guard hex.count == 6 else { return nil }
                return stride(from: 0, to: 6, by: 2).compactMap { i in
                    UInt8(hex.dropFirst(i).prefix(2), radix: 16)
                }
            }
        }

        var snapshotOccurrences: [(dtc: String, occ: UDSSnapshotOccurrence)] = []
        for dtc in snapshotDTCs.prefix(8) {
            let dtcHex = dtc.map { String(format: "%02X", $0) }.joined(separator: " ")
            let dtcName = (OBDUDSParser.decodeTwoByteDTC(dtc[0], dtc[1]) ?? dtcHex) + String(format: "(%02X)", dtc[2])
            if let (r1904, ms) = try? await protocolEngine.execute("19 04 \(dtcHex) FF", target: .tcu, timeout: 2.4) {
                logTrace(command: "[TCU] 19 04 \(dtcHex) FF", response: r1904, durationMs: ms)
                for occ in OBDUDSParser.parseUDSSnapshotOccurrences(r1904) {
                    snapshotOccurrences.append((dtcName, occ))
                }
            }
        }

        if let maxSnapshotKm = snapshotOccurrences.compactMap(\.occ.odometerKm).max(), !tcuIsForeign {
            kmProofsRead.append("snapshots da TCU")
            let tampered = maxSnapshotKm > clusterKm + 500
            if tampered { critical = true; highestKm = max(highestKm, maxSnapshotKm) }
            let details = snapshotOccurrences.map { item -> String in
                let parts = [
                    item.occ.odometerKm.map(km),
                    item.occ.transmissionTempC.map { String(format: "CVT %.0f°C", $0) },
                    item.occ.vehicleSpeedKmh.map { String(format: "%.0f km/h", $0) }
                ].compactMap { $0 }
                return "\(item.dtc): " + parts.joined(separator: ", ")
            }.joined(separator: " • ")
            evidences.append(OdometerEvidenceItem(
                sourceModule: "TCU (Câmbio)",
                checkTitle: "KM gravado nos registros de falha do câmbio (UDS 19 04)",
                commandSent: "19 03 / 19 04",
                rawHexResponse: snapshotOccurrences.map { "\($0.dtc)#\($0.occ.recordNumber)" }.joined(separator: " "),
                measuredValueText: details,
                numericKmValue: maxSnapshotKm,
                status: tampered ? .critical : .healthy,
                forensicAnalysis: tampered
                    ? "O câmbio gravou uma falha aos \(km(maxSnapshotKm)), acima dos \(km(clusterKm)) do painel hoje. Indica painel com KM reduzido ou painel trocado."
                    : "O registro mais recente é de \(km(maxSnapshotKm)), \(km(clusterKm - maxSnapshotKm)) antes do KM atual. Compatível; esta prova só pega reduções abaixo desse valor."
            ))
        } else {
            kmProofsMissing.append(snapshotDTCs.isEmpty ? "snapshots da TCU (nenhum registro de falha gravado)" : "snapshots da TCU")
        }

        // Informativo: ciclos de aquecimento e tempo desde a limpeza (não entram no veredito)
        let warmups = (try? await protocolEngine.execute("01 30", target: .ecm, timeout: 1.8))
            .flatMap { OBDUDSParser.parseMode01OneByteUInt($0.response, pid: 0x30) }
        let minutesSinceClear = (try? await protocolEngine.execute("01 4E", target: .ecm, timeout: 1.8))
            .flatMap { OBDUDSParser.parseMode01TwoByteUInt($0.response, pid: 0x4E) }
        if warmups != nil || minutesSinceClear != nil {
            let parts = [
                warmups.map { "\($0) ciclos de aquecimento" },
                minutesSinceClear.map { "\($0 / 60)h \($0 % 60)min de motor ligado" }
            ].compactMap { $0 }
            let recentClear = (kmSinceClear ?? Int.max) < 200
            evidences.append(OdometerEvidenceItem(
                sourceModule: "ECM (Motor)",
                checkTitle: "Uso desde a última limpeza de falhas (PID 01 30 / 01 4E)",
                commandSent: "01 30 / 01 4E",
                rawHexResponse: parts.joined(separator: " • "),
                measuredValueText: parts.joined(separator: " • "),
                status: .unknown,
                forensicAnalysis: recentClear
                    ? "As falhas foram apagadas há pouco. Isso também zera a prova 4 e pode esconder registros; pergunte ao vendedor o motivo."
                    : "Dado de contexto: mostra há quanto tempo as falhas foram apagadas. Não entra no veredito."
            ))
        }

        let verdict = OdometerIntegrityVerdict.decide(
            critical: critical, attention: attention, tcuMatchesCluster: tcuMatchesCluster, proofsRead: kmProofsRead.count
        )
        let summary: String
        let readText = kmProofsRead.isEmpty ? "nenhuma" : kmProofsRead.joined(separator: ", ")
        let missingText = kmProofsMissing.isEmpty ? "" : " Sem resposta: \(kmProofsMissing.joined(separator: ", "))."
        switch verdict {
        case .tamperingConfirmed:
            summary = "Um módulo registra \(km(highestKm)), mais que os \(km(clusterKm)) do painel. Isso acontece quando o painel tem KM reduzido ou foi trocado; confirme com o histórico de revisões. Provas lidas: \(readText).\(missingText)"
        case .suspiciousDiscrepancy:
            summary = "Há divergências entre os módulos que não provam redução, mas merecem explicação do vendedor (troca de câmbio, painel ou módulo). Provas lidas: \(readText).\(missingText)"
        case .verifiedIntact:
            summary = "O odômetro do câmbio, que é independente do painel, bate com os \(km(clusterKm)) e nenhuma outra prova reprovou. Provas lidas: \(readText).\(missingText)"
        case .noEvidenceFound:
            summary = "Nenhuma prova reprovou, mas não foi possível ler um odômetro independente do painel, então reduções pequenas não seriam detectadas. Provas lidas: \(readText).\(missingText)"
        case .inconclusive, .awaitingScan:
            summary = "Nenhum módulo respondeu às provas de quilometragem. Isso não indica adulteração nem aprova o KM. Confira a ignição ligada e o adaptador vLinker MC+ (o ELM327 básico não acessa a TCU).\(missingText)"
        }

        let report = OdometerAuditReport(
            clusterEnteredKm: clusterKm,
            verdict: verdict,
            summaryExplanation: summary,
            evidences: evidences,
            vinConsistencyPassed: foreignModules.isEmpty,
            highestRecordedKmAcrossECUs: highestKm
        )
        odometerReport = report
        saveOdometerReport(report)
        recordConnectedVehicleInHistory(odometerKm: highestKm)
        TissotFeedback.log("FORENSICS_AUDIT_COMPLETED", ["verdict": verdict.rawValue, "proofs": kmProofsRead.count])
        statusBannerText = "Auditoria de KM concluída: \(verdict.rawValue)"
    }
}
