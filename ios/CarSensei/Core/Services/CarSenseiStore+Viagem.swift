import Foundation

// MARK: - Análise em Tempo Real dos Sensores da Viagem & Motor de Parâmetros Dinâmicos do Veículo

extension CarSenseiStore {

    /// Lista dinâmica de sensores suportados pelo veículo selecionado/conectado.
    /// Cruza os bitmasks reais reportados pela ECU (`01 00`, `01 20`, `01 40`) com leituras ativas da sessão.
    public var dynamicallySupportedGaugesForCurrentVehicle: [CockpitGaugeID] {
        let supportedPIDs = Set(vehicleIdentity.supportedMode01PIDs)
        guard !supportedPIDs.isEmpty else {
            return CockpitGaugeID.allCases
        }
        return CockpitGaugeID.allCases.filter { gauge in
            if liveTripSensorStats[gauge] != nil || gauge.numericValue(from: liveTelemetry) != nil {
                return true
            }
            if let pid = gauge.mode01PIDNumber {
                if gauge == .fuelTrim {
                    return supportedPIDs.contains(0x06) || supportedPIDs.contains(0x07)
                }
                if gauge == .fuelRailPressure {
                    return supportedPIDs.contains(0x22) || supportedPIDs.contains(0x23)
                }
                if gauge == .ambientTemp {
                    return supportedPIDs.contains(0x46) || supportedPIDs.contains(0x0F)
                }
                return supportedPIDs.contains(pid)
            }
            // Sensores UDS / AT RV / Calculados por Speed-Density
            return true
        }
    }

    /// Resumo textual dos parâmetros dinâmicos carregados do veículo conectado para exibir na interface.
    public var activeVehicleDynamicParametersSummary: String {
        let th = vehicleIdentity.thermalThresholds
        let turboLabel = vehicleIdentity.isTurbochargedEngine ? "Turbo / Sobrealimentado" : "Aspirado Ciclo Otto"
        let pidsLabel = vehicleIdentity.supportedMode01PIDs.isEmpty
            ? "Mapeamento Dinâmico CAN/UDS"
            : "\(vehicleIdentity.supportedMode01PIDs.count) PIDs nativos da ECU"
        let fuelLabel = vehicleIdentity.ecuReportedFuelType ?? selectedFuelProfile.rawValue
        return String(
            format: "%@ • %.1fL %@ • Arref. máx %.0f°C • Câmbio máx %.0f°C • %@ • %@",
            vehicleIdentity.cleanModelTitle,
            vehicleIdentity.displacementLiters,
            turboLabel,
            th.coolant.fanHighNormalMaxC,
            th.transmission.heavyLoadNormalMaxC,
            fuelLabel,
            pidsLabel
        )
    }

    // MARK: - Controle de Ciclo de Vida da Análise da Viagem

    public func startTripSensorAnalysis() {
        liveTripSensorStats.removeAll()
        tripAnalysisStartDate = Date()
        tripAnalysisStartDistanceKm = liveTelemetry.sessionDistanceKm
        tripAnalysisStartFuelLiters = liveTelemetry.sessionFuelLiters
        tripAnalysisHasSeenEngineRunning = (liveTelemetry.rpm ?? 0) > 350
        tripAnalysisEngineOffSince = nil
        isAnalyzingTripSensors = true

        // Registra imediatamente a primeira amostra disponível
        recordCurrentTelemetryIntoTripAnalysis()
    }

    public func stopAndGenerateTripReportManually() {
        guard isAnalyzingTripSensors else { return }
        finalizeTripSensorAnalysis(reason: "Análise finalizada manualmente pelo motorista")
    }

    public func deleteTripAnalysisReport(_ reportID: UUID) {
        tripAnalysisReportsHistory.removeAll { $0.id == reportID }
        if latestTripAnalysisReport?.id == reportID {
            latestTripAnalysisReport = tripAnalysisReportsHistory.first
        }
        saveTripAnalysisReportsHistory()
    }

    public func clearAllTripAnalysisReports() {
        tripAnalysisReportsHistory.removeAll()
        latestTripAnalysisReport = nil
        UserDefaults.standard.removeObject(forKey: tripAnalysisReportsKey)
    }

    /// Executado a cada ciclo do `startTelemetryLoop()` no `CarSenseiStore`.
    func processTripSensorAnalysisTick(now: Date) {
        let currentRPM = liveTelemetry.rpm ?? 0

        // 1. Auto-início opcional quando o motor entra em funcionamento
        if !isAnalyzingTripSensors {
            if autoStartTripAnalysis && currentRPM > 350 {
                startTripSensorAnalysis()
            }
            return
        }

        // 2. Acumula amostras reais de todos os sensores disponíveis no barramento
        recordCurrentTelemetryIntoTripAnalysis()

        // 3. Detecta funcionamento do motor e desligamento automático ao final da viagem
        if currentRPM > 400 {
            tripAnalysisHasSeenEngineRunning = true
            tripAnalysisEngineOffSince = nil
        } else if tripAnalysisHasSeenEngineRunning && currentRPM <= 50 {
            if let offStart = tripAnalysisEngineOffSince {
                if now.timeIntervalSince(offStart) >= 6.0 && !liveTripSensorStats.isEmpty {
                    finalizeTripSensorAnalysis(reason: "Motor desligado ao concluir a viagem (0 RPM)")
                }
            } else {
                tripAnalysisEngineOffSince = now
            }
        }
    }

    private func recordCurrentTelemetryIntoTripAnalysis() {
        for gauge in CockpitGaugeID.allCases {
            guard let rawValue = gauge.numericValue(from: liveTelemetry), rawValue.isFinite else {
                continue
            }
            // Para distância e combustível da viagem, armazena o delta desde o início da análise
            let adjustedValue: Double
            if gauge == .tripDistance {
                adjustedValue = max(0.0, liveTelemetry.sessionDistanceKm - tripAnalysisStartDistanceKm)
            } else if gauge == .tripFuelUsed {
                adjustedValue = max(0.0, liveTelemetry.sessionFuelLiters - tripAnalysisStartFuelLiters)
            } else {
                adjustedValue = rawValue
            }

            if var existing = liveTripSensorStats[gauge] {
                existing.record(adjustedValue)
                liveTripSensorStats[gauge] = existing
            } else {
                liveTripSensorStats[gauge] = TripSensorLiveStat(
                    gauge: gauge,
                    minValue: adjustedValue,
                    maxValue: adjustedValue,
                    sumValue: adjustedValue,
                    lastValue: adjustedValue,
                    sampleCount: 1
                )
            }
        }
    }

    /// Avalia em tempo real as estatísticas acumuladas até o momento (para exibir na tela enquanto dirige).
    public var liveTripEvaluatedItems: [TripSensorEvaluationItem] {
        let durationSec = Date().timeIntervalSince(tripAnalysisStartDate ?? Date())
        return liveTripSensorStats.values
            .map { evaluateTripSensorStat($0, tripDurationSeconds: durationSec) }
            .sorted { lhs, rhs in
                let p1 = healthPriority(lhs.healthLevel)
                let p2 = healthPriority(rhs.healthLevel)
                if p1 != p2 { return p1 < p2 }
                return lhs.gauge.title < rhs.gauge.title
            }
    }

    func finalizeTripSensorAnalysis(reason: String) {
        guard isAnalyzingTripSensors else { return }
        isAnalyzingTripSensors = false
        let end = Date()
        let start = tripAnalysisStartDate ?? end.addingTimeInterval(-60)
        let duration = max(1.0, end.timeIntervalSince(start))

        let evaluatedItems = liveTripSensorStats.values
            .map { evaluateTripSensorStat($0, tripDurationSeconds: duration) }
            .sorted { lhs, rhs in
                let p1 = healthPriority(lhs.healthLevel)
                let p2 = healthPriority(rhs.healthLevel)
                if p1 != p2 { return p1 < p2 }
                return lhs.gauge.title < rhs.gauge.title
            }

        guard !evaluatedItems.isEmpty else {
            tripAnalysisStartDate = nil
            return
        }

        let criticalCount = evaluatedItems.filter { $0.healthLevel == .critical }.count
        let attentionCount = evaluatedItems.filter { $0.healthLevel == .attention }.count
        let healthyCount = evaluatedItems.filter { $0.healthLevel == .healthy }.count

        let overallHealth: HealthLevel
        if criticalCount > 0 {
            overallHealth = .critical
        } else if attentionCount > 0 {
            overallHealth = .attention
        } else {
            overallHealth = .healthy
        }

        let total = max(1, evaluatedItems.count)
        let penalty = (criticalCount * 22) + (attentionCount * 8)
        let score = max(15, min(100, 100 - penalty))

        let distKm = max(0.0, liveTelemetry.sessionDistanceKm - tripAnalysisStartDistanceKm)
        let fuelL = max(0.0, liveTelemetry.sessionFuelLiters - tripAnalysisStartFuelLiters)
        let avgKml = (distKm > 0.05 && fuelL > 0.005) ? (distKm / fuelL) : liveTelemetry.sessionAverageKmPerLiter
        let maxSpeed = liveTripSensorStats[.speed]?.maxValue

        let headline: String
        let overview: String
        if criticalCount > 0 {
            headline = "Alerta: \(criticalCount) sensor(es) fora do padrão seguro na viagem"
            overview = "Durante o trajeto de \(String(format: "%.1f km", distKm)), o CarSensei monitorou \(total) sensores reais do seu \(vehicleIdentity.cleanModelTitle). Encontramos \(criticalCount) leitura(s) crítica(s) e \(attentionCount) em atenção que merecem revisão mecânica. Veja abaixo a explicação simples de cada item."
        } else if attentionCount > 0 {
            headline = "Viagem concluída com \(attentionCount) ponto(s) de atenção leve"
            overview = "Analisamos \(total) sensores do seu \(vehicleIdentity.cleanModelTitle) ao longo da viagem. \(healthyCount) sensores trabalharam com perfeição e \(attentionCount) apresentaram leve variação que vale acompanhar. Nenhum defeito grave foi detectado."
        } else {
            headline = "Parabéns! Todos os \(total) sensores trabalharam 100% saudáveis"
            overview = "Seu \(vehicleIdentity.cleanModelTitle) rodou com temperaturas, mistura de combustível, parte elétrica e câmbio dentro dos parâmetros ideais da engenharia durante toda a viagem."
        }

        let report = TripSensorAnalysisReport(
            startDate: start,
            endDate: end,
            durationSeconds: duration,
            finishReason: reason,
            vehicleModel: vehicleIdentity.cleanModelTitle,
            vehicleVIN: OBDUDSParser.normalizedVIN(vehicleIdentity.vin) ?? vehicleIdentity.vin,
            engineDescription: vehicleIdentity.engineCode,
            transmissionDescription: vehicleIdentity.transmissionCode,
            fuelProfileTitle: vehicleIdentity.ecuReportedFuelType ?? selectedFuelProfile.rawValue,
            supportedPIDsCount: max(evaluatedItems.count, vehicleIdentity.supportedMode01PIDs.count),
            distanceKm: distKm,
            fuelUsedLiters: fuelL,
            avgKmPerLiter: avgKml,
            maxSpeedKmh: maxSpeed,
            overallHealth: overallHealth,
            overallScorePercent: score,
            laypersonHeadline: headline,
            laypersonOverview: overview,
            items: evaluatedItems
        )

        latestTripAnalysisReport = report
        tripAnalysisReportsHistory.insert(report, at: 0)
        if tripAnalysisReportsHistory.count > 25 {
            tripAnalysisReportsHistory.removeLast(tripAnalysisReportsHistory.count - 25)
        }
        saveTripAnalysisReportsHistory()
        tripAnalysisStartDate = nil
    }

    private func saveTripAnalysisReportsHistory() {
        if let data = try? JSONEncoder().encode(tripAnalysisReportsHistory) {
            UserDefaults.standard.set(data, forKey: tripAnalysisReportsKey)
        }
    }

    private func healthPriority(_ level: HealthLevel) -> Int {
        switch level {
        case .critical: return 0
        case .attention: return 1
        case .healthy: return 2
        case .unknown: return 3
        }
    }

    // MARK: - Motor Dinâmico de Avaliação por Sensor (Parâmetros do Veículo + Explicação para Leigos)

    func evaluateTripSensorStat(_ stat: TripSensorLiveStat, tripDurationSeconds: Double) -> TripSensorEvaluationItem {
        let g = stat.gauge
        let minV = stat.minValue
        let avgV = stat.avgValue
        let maxV = stat.maxValue
        let lastV = stat.lastValue
        let samples = stat.sampleCount

        // Parâmetros dinâmicos carregados do veículo conectado + contexto real da viagem
        let th = vehicleIdentity.thermalThresholds
        let isTurbo = vehicleIdentity.isTurbochargedEngine
        let dispL = max(0.8, vehicleIdentity.displacementLiters)
        let baroKpa = liveTripSensorStats[.barometricPressure]?.avgValue
            ?? liveTelemetry.barometricPressureKpa
            ?? 100.0
        let ambientC = liveTripSensorStats[.ambientTemp]?.avgValue
            ?? liveTelemetry.effectiveExternalTempC
            ?? 25.0
        let engineWarmedUp = tripDurationSeconds >= 360 || (liveTripSensorStats[.coolantTemp]?.maxValue ?? 0) >= th.coolant.warmUpThresholdC
        let engineRunningNow = (liveTripSensorStats[.rpm]?.maxValue ?? 0) > 400

        var expectedRange = "--"
        var level: HealthLevel = .healthy
        var badge = "Bom / Ideal"
        var whatItIs = g.summaryDescription
        var verdict = ""
        var advice = ""
        var techRef = "\(g.pidBadge) • \(samples) leituras no trajeto"

        switch g {
        case .coolantTemp:
            let warmMin = th.coolant.warmUpThresholdC
            let normMax = th.coolant.fanHighNormalMaxC
            let warnMax = th.coolant.warningThresholdC
            let critMax = th.coolant.criticalDTCThresholdC
            expectedRange = String(format: "%.0f°C a %.0f°C", warmMin, normMax)
            whatItIs = "É o termômetro da 'água' (líquido de arrefecimento) que impede o motor de fundir por calor excessivo e garante que ele trabalhe aquecido na temperatura certa."
            techRef = "\(g.pidBadge) • Spec \(th.coolant.engineDesc): nominal \(Int(warmMin))–\(Int(normMax))°C, alerta ≥\(Int(warnMax))°C, crítico ≥\(Int(critMax))°C (\(samples) amostras)"

            if maxV >= critMax {
                level = .critical
                badge = "Superaquecimento"
                verdict = String(format: "A temperatura chegou a %.0f°C, ultrapassando o limite seguro de %.0f°C deste motor!", maxV, critMax)
                advice = "Pare de forçar o carro e verifique urgente o nível do líquido no reservatório, a válvula termostática e se a ventoinha do radiador está disparando."
            } else if maxV >= warnMax {
                level = .attention
                badge = "Acima do Ideal"
                verdict = String(format: "Atingiu pico de %.0f°C (média de %.0f°C), ligeiramente acima da faixa normal de %.0f°C.", maxV, avgV, normMax)
                advice = "Confira o nível do aditivo do radiador com o motor frio e observe se a ventoinha liga normalmente no trânsito."
            } else if engineWarmedUp && tripDurationSeconds > 600 && maxV < (warmMin - 5.0) {
                level = .attention
                badge = "Motor Trabalhando Frio"
                verdict = String(format: "Mesmo após dirigir, o motor não passou de %.0f°C (deveria atingir pelo menos %.0f°C).", maxV, warmMin)
                advice = "Isso costuma indicar válvula termostática travada aberta, o que faz o carro gastar mais combustível. Peça ao mecânico para conferir."
            } else {
                level = .healthy
                badge = maxV < warmMin ? "Em Aquecimento" : "Bom / Ideal"
                verdict = String(format: "Trabalhou entre %.0f°C e %.0f°C (média de %.0f°C), exatamente dentro da faixa segura do seu motor.", minV, maxV, avgV)
                advice = "Sistema de arrefecimento, radiador e ventoinha funcionando perfeitamente."
            }

        case .cvtTemp:
            let warmMin = th.transmission.warmUpThresholdC
            let normMax = th.transmission.heavyLoadNormalMaxC
            let warnMax = th.transmission.thermalInterventionC
            let critMax = th.transmission.criticalDTCThresholdC
            expectedRange = String(format: "%.0f°C a %.0f°C", warmMin, normMax)
            whatItIs = "Mede a temperatura interna do óleo do câmbio automático (\(th.transmission.transmissionName)). Se o óleo esquentar demais, ele afina e o câmbio perde proteção."
            techRef = "\(g.pidBadge) • Spec \(th.transmission.transmissionName): normal até \(Int(normMax))°C sob carga, proteção TCU ≥\(Int(warnMax))°C, crítico ≥\(Int(critMax))°C (\(samples) amostras)"

            if maxV >= critMax {
                level = .critical
                badge = "Crítico (Risco P0218)"
                verdict = String(format: "O óleo do câmbio chegou a %.0f°C (limite crítico: %.0f°C)!", maxV, critMax)
                advice = "Reduza o ritmo em serras/subidas e agende a verificação do fluido (ATF/CVT) e do trocador de calor do câmbio."
            } else if maxV >= warnMax {
                level = .attention
                badge = "Atenção Térmica"
                verdict = String(format: "Chegou a %.0f°C no pico (faixa normal até %.0f°C). O módulo do câmbio entrou na faixa de proteção térmica.", maxV, normMax)
                advice = "Normal apenas em subidas de serra muito pesadas no calor. Se aconteceu no plano, verifique a validade do óleo do câmbio e o arrefecimento."
            } else {
                level = .healthy
                badge = "Bom / Protegido"
                verdict = String(format: "Operou entre %.0f°C e %.0f°C (média %.0f°C), bem abaixo do limite de %.0f°C da transmissão.", minV, maxV, avgV, normMax)
                advice = "Câmbio trabalhando frio e saudável, sem estresse térmico no fluido."
            }

        case .batteryVoltage:
            expectedRange = engineRunningNow ? "13,4 V a 14,8 V (Carregando)" : "12,3 V a 12,8 V (Repouso)"
            whatItIs = "Mostra a energia elétrica do carro: quando o motor está ligado, mede se o alternador está recarregando a bateria; quando desligado, mostra a carga da bateria 12V."
            techRef = "\(g.pidBadge) • Regulador do alternador nominal 13,4–14,8V em marcha (\(samples) amostras)"

            if engineRunningNow {
                if maxV > 15.0 {
                    level = .critical
                    badge = "Sobretensão"
                    verdict = String(format: "A voltagem subiu até %.2f V (acima do limite de 14,8 V).", maxV)
                    advice = "Risco de queimar lâmpadas ou módulos. Peça para testar o regulador de tensão do alternador."
                } else if avgV < 13.1 {
                    level = .critical
                    badge = "Alternador Fraco"
                    verdict = String(format: "Com o motor ligado, a média ficou em apenas %.2f V (o alternador deveria manter acima de 13,4 V).", avgV)
                    advice = "O alternador pode não estar recarregando a bateria direito. Verifique correia de acessórios e alternador."
                } else if minV < 13.2 && avgV < 13.5 {
                    level = .attention
                    badge = "Carga no Limite"
                    verdict = String(format: "Oscilou entre %.2f V e %.2f V (média %.2f V).", minV, maxV, avgV)
                    advice = "Funcionando, mas sob alto consumo elétrico (ar-condicionado + faróis). Acompanhe nas próximas partidas."
                } else {
                    level = .healthy
                    badge = "Bom / Carregando"
                    verdict = String(format: "Manteve média de %.2f V (entre %.2f V e %.2f V) durante a viagem.", avgV, minV, maxV)
                    advice = "Alternador e bateria 12V em perfeito estado."
                }
            } else {
                if avgV < 12.0 {
                    level = .critical
                    badge = "Bateria Fraca"
                    verdict = String(format: "Bateria em %.2f V com motor desligado (abaixo de 12,0 V).", avgV)
                    advice = "Bateria descarregada ou no fim da vida útil. Dê carga ou faça o teste de partida."
                } else if avgV < 12.3 {
                    level = .attention
                    badge = "Meia Carga"
                    verdict = String(format: "Tensão em repouso de %.2f V.", avgV)
                    advice = "Rode por 20 minutos para completar a carga pelo alternador."
                } else {
                    level = .healthy
                    badge = "Bateria Cheia"
                    verdict = String(format: "Tensão firme em %.2f V.", avgV)
                    advice = "Bateria com excelente reserva de carga."
                }
            }

        case .ecuModuleVoltage:
            let batAvg = liveTripSensorStats[.batteryVoltage]?.avgValue ?? avgV
            let drop = max(0.0, batAvg - avgV)
            expectedRange = "13,2 V a 14,8 V (Queda ≤ 0,5 V)"
            whatItIs = "É a energia elétrica que chega lá dentro do 'cérebro' do motor (módulo de injeção). Serve para descobrir se há fios oxidados ou mau contato no aterramento."
            techRef = "\(g.pidBadge) • Diferença Bateria vs ECU: \(String(format: "%.2fV", drop)) (\(samples) amostras)"

            if avgV < 12.8 && engineRunningNow {
                level = .critical
                badge = "Tensão Baixa na ECU"
                verdict = String(format: "A central eletrônica recebeu média de %.2f V (perda de %.2f V em relação à bateria).", avgV, drop)
                advice = "Peça a um eletricista automotivo para limpar os cabos de aterramento da bateria e do chassi."
            } else if drop > 0.6 {
                level = .attention
                badge = "Perda no Chicote"
                verdict = String(format: "Média de %.2f V na ECU contra %.2f V no conector (diferença de %.2f V).", avgV, batAvg, drop)
                advice = "Há uma leve perda elétrica nos cabos ou bornes da bateria. Vale revisar o aperto dos polos."
            } else {
                level = .healthy
                badge = "Bom / Estável"
                verdict = String(format: "Manteve %.2f V estáveis na placa da injeção eletrônica.", avgV)
                advice = "Alimentação elétrica dos módulos perfeita, sem mau contato."
            }

        case .fuelTrim:
            expectedRange = "-10,0% a +10,0%"
            whatItIs = "Mostra se o computador do carro está precisando injetar mais combustível (+) ou tirar combustível (-) para compensar gasolina/etanol adulterado, bicos sujos ou entrada falsa de ar."
            techRef = "\(g.pidBadge) • Tolerância malha fechada SAE: ±10% ideal, alerta >±15%, limite DTC P0171/P0172 em ±25% (\(samples) amostras)"

            if abs(avgV) > 18.0 || max(abs(minV), abs(maxV)) > 24.0 {
                level = .critical
                badge = avgV > 0 ? "Mistura Pobre (Excesso Ar)" : "Mistura Rica (Excesso Comb.)"
                verdict = String(format: "A correção chegou a %+.1f%% (média %+.1f%%), muito longe do zero ideal!", max(abs(minV), abs(maxV)) * (avgV >= 0 ? 1 : -1), avgV)
                advice = avgV > 0
                    ? "O motor está pedindo muito mais combustível que o normal. Pode ser combustível ruim, bomba fraca, bicos entupidos ou mangueira de ar furada."
                    : "O motor está tirando muito combustível. Pode ser bico injetor gotejando, filtro de ar muito sujo ou troca recente de combustível ainda não aprendida."
            } else if abs(avgV) > 10.5 {
                level = .attention
                badge = "Compensando Combustível"
                verdict = String(format: "Ficou com média de %+.1f%% (variando de %+.1f%% a %+.1f%%).", avgV, minV, maxV)
                advice = "A injeção está trabalhando um pouco mais para corrigir a qualidade do combustível atual. Abasteça em posto de confiança e acompanhe."
            } else {
                level = .healthy
                badge = "Queima Perfeita"
                verdict = String(format: "Média de %+.1f%% (dentro da faixa ideal de -10%% a +10%%).", avgV)
                advice = "Bicos injetores limpos, combustível de boa qualidade e mistura ar/combustível afinada."
            }

        case .intakeAirTemp:
            let maxHealthyIAT = ambientC + (isTurbo ? 30.0 : 22.0)
            let critIAT = max(72.0, ambientC + 42.0)
            expectedRange = String(format: "%.0f°C a %.0f°C (Clima %.0f°C)", max(5.0, ambientC - 2.0), maxHealthyIAT, ambientC)
            whatItIs = "Mede a temperatura do ar que está entrando nos cilindros depois de passar pelo filtro de ar\(isTurbo ? " e pelo resfriador do turbo (intercooler)" : ""). Ar mais fresco gera melhor rendimento e economia."
            techRef = "\(g.pidBadge) • Delta térmico sobre temp. externa (\(Int(ambientC))°C): máx \(String(format: "%+.0f°C", maxV - ambientC)) (\(samples) amostras)"

            if maxV >= critIAT {
                level = .critical
                badge = "Admissão Muito Quente"
                verdict = String(format: "O ar admitido chegou a %.0f°C (%.0f°C acima do ar da rua)!", maxV, maxV - ambientC)
                advice = "O motor perde força e gasta mais para se proteger do ar quente. Verifique se a tomada de ar ou o intercooler estão obstruídos."
            } else if avgV > maxHealthyIAT {
                level = .attention
                badge = "Cofre Aquecido"
                verdict = String(format: "Média de %.0f°C (pico de %.0f°C), aquecido pelo trânsito lento.", avgV, maxV)
                advice = "Comum em engarrafamento parado com ar-condicionado ligado; deve baixar assim que pegar avenida/estrada."
            } else {
                level = .healthy
                badge = "Bom / Ar Fresco"
                verdict = String(format: "Manteve média de %.0f°C (entre %.0f°C e %.0f°C), compatível com o clima externo de %.0f°C.", avgV, minV, maxV, ambientC)
                advice = "Fluxo de ar da admissão\(isTurbo ? " e eficiência do intercooler" : "") trabalhando muito bem."
            }

        case .mapBoost:
            let maxExpectedKpa = isTurbo ? (baroKpa + 145.0) : (baroKpa + 5.0)
            expectedRange = isTurbo
                ? String(format: "22 a %.0f kPa (Até +%.1f bar)", maxExpectedKpa, (maxExpectedKpa - baroKpa) / 100.0)
                : String(format: "24 a %.0f kPa (Atm. %.0f kPa)", baroKpa + 2.0, baroKpa)
            whatItIs = isTurbo
                ? "Mede o vácuo do motor quando você tira o pé (economia) e a pressão positiva quando a turbina enche nas acelerações."
                : "Mede a pressão do ar dentro do coletor do motor: valores baixos em marcha lenta indicam motor bem vedado e saudável."
            techRef = "\(g.pidBadge) • Ref Barométrica local: \(Int(baroKpa)) kPa • Perfil \(isTurbo ? "Turbo" : "Aspirado") (\(samples) amostras)"

            if isTurbo && maxV > (baroKpa + 165.0) {
                level = .critical
                badge = "Sobrepressão Turbo"
                verdict = String(format: "Atingiu %.0f kPa (+%.2f bar de turbo), acima do limite de segurança!", maxV, (maxV - baroKpa) / 100.0)
                advice = "Verifique a válvula wastegate / solenoide de controle de pressão da turbina."
            } else if minV > 58.0 && (liveTripSensorStats[.rpm]?.minValue ?? 1000) < 950 && tripDurationSeconds > 120 {
                level = .attention
                badge = "Pouco Vácuo na Lenta"
                verdict = String(format: "A pressão mínima não baixou de %.0f kPa mesmo sem acelerar.", minV)
                advice = "Em marcha lenta sem carga, o vácuo costuma descer para 28–48 kPa. Se o carro oscilar na lenta, verifique mangueiras de vácuo."
            } else {
                level = .healthy
                badge = "Bom / Vedado"
                let maxBoostBar = max(0.0, (maxV - baroKpa) / 100.0)
                verdict = isTurbo
                    ? String(format: "Variou de %.0f kPa (vácuo econômico) até %.0f kPa (pico de +%.2f bar na turbina).", minV, maxV, maxBoostBar)
                    : String(format: "Trabalhou entre %.0f kPa e %.0f kPa com pressão atmosférica local de %.0f kPa.", minV, maxV, baroKpa)
                advice = "Estanqueidade da admissão\(isTurbo ? " e resposta da turbina" : "") totalmente normais."
            }

        case .catalystTempB1S1:
            expectedRange = "350°C a 850°C"
            whatItIs = "Mede a temperatura da colmeia interna do catalisador no escapamento, peça responsável por filtrar os gases poluentes."
            techRef = "\(g.pidBadge) • Faixa operacional cerâmica: 350–850°C, limite térmico crítico >930°C (\(samples) amostras)"

            if maxV > 930.0 {
                level = .critical
                badge = "Catalisador Superaquecido"
                verdict = String(format: "Chegou a %.0f°C (acima do limite seguro de 900°C para a colmeia cerâmica)!", maxV)
                advice = "Calor excessivo no catalisador geralmente vem de falha de ignição (velas/bobinas falhando). Revise o sistema de ignição."
            } else if maxV > 860.0 {
                level = .attention
                badge = "Temperatura Alta"
                verdict = String(format: "Pico de %.0f°C durante exigência severa do motor.", maxV)
                advice = "Evite manter aceleração máxima contínua por longos períodos."
            } else {
                level = .healthy
                badge = "Bom / Normal"
                verdict = String(format: "Operou entre %.0f°C e %.0f°C (média %.0f°C), faixa ideal de limpeza dos gases.", minV, maxV, avgV)
                advice = "Catalisador operando em temperatura segura e eficiente."
            }

        case .engineOilTemp:
            let maxOil = th.coolant.warningThresholdC + 15.0
            expectedRange = String(format: "75°C a %.0f°C", maxOil - 8.0)
            whatItIs = "Mede a temperatura do óleo que lubrifica as peças internas do motor."
            techRef = "\(g.pidBadge) • Limite térmico lubrificante sintético: \(Int(maxOil))°C (\(samples) amostras)"

            if maxV > maxOil + 5.0 {
                level = .critical
                badge = "Óleo Muito Quente"
                verdict = String(format: "O óleo atingiu %.0f°C!", maxV)
                advice = "Confira imediatamente o nível e a validade do óleo do motor."
            } else if maxV > maxOil - 5.0 {
                level = .attention
                badge = "Atenção Térmica"
                verdict = String(format: "Chegou a %.0f°C sob esforço.", maxV)
                advice = "Mantenha as trocas de óleo sempre em dia com a viscosidade recomendada no manual."
            } else {
                level = .healthy
                badge = "Lubrificação Ideal"
                verdict = String(format: "Manteve média de %.0f°C (máx %.0f°C).", avgV, maxV)
                advice = "Temperatura do óleo perfeita para proteger o motor contra desgaste."
            }

        case .lambdaO2Voltage:
            expectedRange = "100 mV a 880 mV (Oscilante)"
            whatItIs = "É o 'nariz' do motor antes do catalisador: ela cheira o escapamento várias vezes por segundo e avisa se falta ou sobra combustível."
            techRef = "\(g.pidBadge) • Sonda S1B1 deve ciclar entre <250 mV (pobre) e >650 mV (rica) (\(samples) amostras)"

            let amplitude = maxV - minV
            if samples >= 12 && amplitude < 80.0 {
                level = .attention
                badge = "Sonda Pouco Ativa"
                verdict = String(format: "A leitura quase não variou (de %.0f mV a %.0f mV). Uma sonda saudável oscila bastante entre 150 e 800 mV.", minV, maxV)
                advice = "Em trajetos muito curtos é normal; se continuar travada em viagens longas, peça para testar a velocidade de resposta da sonda lambda."
            } else {
                level = .healthy
                badge = "Sonda Rápida e Boa"
                verdict = String(format: "Oscilou ativamente entre %.0f mV e %.0f mV (média %.0f mV), ajustando a mistura em tempo real.", minV, maxV, avgV)
                advice = "Sonda lambda pré-catalisador trabalhando com excelente resposta."
            }

        case .lambdaO2Sensor2:
            expectedRange = "450 mV a 800 mV (Estável)"
            whatItIs = "É o fiscal que fica depois do catalisador para confirmar se os gases saíram limpos."
            techRef = "\(g.pidBadge) • Sonda S2B1 pós-catalisador (\(samples) amostras)"
            level = .healthy
            badge = "Catalisador Eficiente"
            verdict = String(format: "Trabalhou com média de %.0f mV (entre %.0f e %.0f mV).", avgV, minV, maxV)
            advice = "Leitura compatível com filtragem normal do catalisador."

        case .commandedEquivalenceRatio:
            expectedRange = "0,85 λ a 1,05 λ"
            whatItIs = "Mostra a receita de ar e combustível que o computador do motor escolheu: 1,00 é o equilíbrio perfeito para economia; abaixo de 0,95 é quando o motor injeta mais para dar força em subidas."
            techRef = "\(g.pidBadge) • Fator Lambda comandado pela ECU (\(samples) amostras)"

            if minV < 0.72 || maxV > 1.25 {
                level = .attention
                badge = "Variação Ampla"
                verdict = String(format: "Variou de %.2f λ a %.2f λ (média %.2f λ).", minV, maxV, avgV)
                advice = "Houve momentos de forte enriquecimento em aceleração ou corte em desaceleração."
            } else {
                level = .healthy
                badge = "Mistura Ideal"
                verdict = String(format: "Manteve média de %.2f λ (muito próxima de 1,00 λ ideal).", avgV)
                advice = "Gerenciamento eletrônico de combustível trabalhando com precisão."
            }

        case .timingAdvance:
            expectedRange = "-5° a +42° APMS"
            whatItIs = "É o momento exato em que a vela solta a faísca no cilindro. Se o combustível for ruim e der 'batida de pino', o motor atrasa esse número para se defender."
            techRef = "\(g.pidBadge) • Avanço de ignição cilindro 1 (\(samples) amostras)"

            if minV < -12.0 {
                level = .attention
                badge = "Atraso de Ponto"
                verdict = String(format: "O ponto recuou até %.1f° (média %.1f°), indicando que a central precisou proteger o motor contra detonação.", minV, avgV)
                advice = "Pode ser causado por combustível de baixa octanagem ou velas desgastadas. Experimente abastecer em outro posto."
            } else {
                level = .healthy
                badge = "Ignição Saudável"
                verdict = String(format: "Trabalhou entre %.1f° e %.1f° (média %.1f°), mostrando queima eficiente.", minV, maxV, avgV)
                advice = "Velas, bobinas e octanagem do combustível operando bem."
            }

        case .rpm:
            expectedRange = "650 a 5.500 RPM"
            whatItIs = "Quantas voltas completas o motor dá por minuto. Na marcha lenta fica perto de 700–850 RPM e sobe conforme você acelera."
            techRef = "\(g.pidBadge) • Rotação do virabrequim (\(samples) amostras)"

            if maxV > 6300 {
                level = .attention
                badge = "Giro Muito Alto"
                verdict = String(format: "O motor chegou a %.0f RPM (próximo da faixa de corte).", maxV)
                advice = "Evite manter rotações próximas ao limite para preservar o motor e economizar combustível."
            } else {
                level = .healthy
                badge = "Rotação Normal"
                verdict = String(format: "Rodou com média de %.0f RPM (mínimo %.0f RPM e máximo %.0f RPM).", avgV, minV, maxV)
                advice = "Regime de rotações tranquilo e saudável durante o trajeto."
            }

        case .speed:
            expectedRange = "0 a 130 km/h"
            whatItIs = "Velocidade real medida nos sensores das rodas (sem a margem de 3% a 5% a mais que o painel mostra)."
            techRef = "\(g.pidBadge) • Velocidade VSS/ABS (\(samples) amostras)"
            level = .healthy
            badge = "Registrado"
            verdict = String(format: "Velocidade média de %.0f km/h e máxima de %.0f km/h na viagem.", avgV, maxV)
            advice = "Sensores de velocidade das rodas enviando sinal limpo na rede CAN."

        case .engineLoad, .absoluteEngineLoad:
            let maxNorm = (g == .absoluteEngineLoad && isTurbo) ? 185.0 : 100.0
            expectedRange = String(format: "12%% a %.0f%%", maxNorm)
            whatItIs = "Mostra a porcentagem de força que você exigiu do motor durante a viagem."
            techRef = "\(g.pidBadge) • Cilindrada base \(String(format: "%.1fL", dispL)) (\(samples) amostras)"
            level = .healthy
            badge = avgV > 75 ? "Uso Intenso" : "Esforço Normal"
            verdict = String(format: "O motor trabalhou com esforço médio de %.0f%% e pico de %.0f%% nas subidas/ultrapassagens.", avgV, maxV)
            advice = "Entrega de carga compatível com a condução."

        case .mafAirFlow:
            let idleExpectedMin = dispL * 1.1
            let maxExpected = dispL * (isTurbo ? 95.0 : 62.0)
            expectedRange = String(format: "%.1f a %.0f g/s", idleExpectedMin, maxExpected)
            whatItIs = "Quantidade de ar (em gramas por segundo) que o motor 'respirou' durante a viagem."
            techRef = "\(g.pidBadge) • Escalonado para motor \(String(format: "%.1fL", dispL)) (\(samples) amostras)"
            level = .healthy
            badge = "Respiração Normal"
            verdict = String(format: "Fluxo médio de %.1f g/s e pico de %.1f g/s nas acelerações.", avgV, maxV)
            advice = "Admissão de ar limpa e proporcional à cilindrada do veículo."

        case .fuelFlowRate:
            let idleMax = dispL * 1.05
            expectedRange = String(format: "0,6 a %.1f L/h na lenta", idleMax)
            whatItIs = "Mostra quantos litros de combustível por hora passaram pelos bicos injetores."
            techRef = "Cálculo integrado de vazão para motor \(String(format: "%.1fL", dispL)) (\(samples) amostras)"
            level = .healthy
            badge = "Vazão Normal"
            verdict = String(format: "Vazão média de %.2f L/h (mínima de %.2f L/h e pico de %.1f L/h ao acelerar).", avgV, minV, maxV)
            advice = "Injeção dosando combustível normalmente conforme a carga do pedal."

        case .instantFuel, .averageFuel:
            expectedRange = "5,5 a 16,5 km/L"
            whatItIs = "Rendimento do combustível medido diretamente pelos sensores da injeção eletrônica."
            techRef = "Combustível ativo: \(vehicleIdentity.ecuReportedFuelType ?? selectedFuelProfile.rawValue) (\(samples) amostras)"
            level = avgV < 4.5 ? .attention : .healthy
            badge = avgV < 4.5 ? "Consumo Elevado" : "Bom Rendimento"
            verdict = String(format: "Média registrada de %.1f km/L durante o percurso.", avgV)
            advice = avgV < 4.5
                ? "Consumo alto é comum em trajetos muito curtos com motor frio ou trânsito pesado. Em trajetos longos, confira calibragem dos pneus."
                : "Consumo coerente com o trânsito e perfil de combustível do veículo."

        case .throttlePos, .relativeThrottlePos, .commandedThrottleActuator, .acceleratorPedalPosD, .acceleratorPedalPosE:
            expectedRange = "0% a 100% (Resposta Linear)"
            whatItIs = "Mede a sincronia entre o seu pé no pedal do acelerador e a válvula eletrônica (borboleta) que abre a passagem de ar no motor."
            techRef = "\(g.pidBadge) • Sistema Drive-by-Wire (\(samples) amostras)"
            level = .healthy
            badge = "Resposta Precisa"
            verdict = String(format: "Operou entre %.0f%% e %.0f%% (média de %.0f%%) sem falhas de pista elétrica.", minV, maxV, avgV)
            advice = "Corpo de borboleta eletrônico e pedal respondendo sem engasgos."

        case .distanceWithMILOn:
            expectedRange = "0 km (Luz Apagada)"
            whatItIs = "Conta quantos quilômetros o carro rodou com a luz amarela da injeção ('Check Engine') acesa no painel."
            techRef = "\(g.pidBadge) • Contador MIL SAE J1979 (\(samples) amostras)"

            if maxV > 0.5 {
                level = .critical
                badge = "Luz de Injeção Acesa"
                verdict = String(format: "A ECU registra %.0f km rodados com a luz de anomalia da injeção acesa!", maxV)
                advice = "Vá até a aba 'Diagnóstico' ao lado e toque em 'Escanear Todos os Módulos' para descobrir exatamente qual é o código de falha."
            } else {
                level = .healthy
                badge = "0 km (Sem Luz Acesa)"
                verdict = "Zero quilômetros com luz de falha acesa no painel."
                advice = "Injeção sem alerta ativo no painel."
            }

        case .fuelTankLevel:
            expectedRange = "15% a 100%"
            whatItIs = "Nível real de combustível lido pela boia dentro do tanque."
            techRef = "\(g.pidBadge) • Sensor de nível do tanque (\(samples) amostras)"

            if lastV < 12.0 {
                level = .attention
                badge = "Reserva / Tanque Baixo"
                verdict = String(format: "O tanque terminou a viagem com apenas %.0f%%.", lastV)
                advice = "Evite rodar na reserva: o próprio combustível do tanque ajuda a resfriar a bomba elétrica de combustível."
            } else {
                level = .healthy
                badge = "Nível Adequado"
                verdict = String(format: "Nível do tanque em %.0f%% ao final da leitura.", lastV)
                advice = "Volume suficiente para resfriamento ideal da bomba de combustível."
            }

        case .barometricPressure:
            expectedRange = "88 a 103 kPa (Conforme Altitude)"
            whatItIs = "Mede a pressão do ar da sua cidade/estrada (altitude). Serve para o carro ajustar a injeção quando você sobe ou desce a serra."
            techRef = "\(g.pidBadge) • Barômetro interno da ECU (\(samples) amostras)"
            level = .healthy
            badge = "Calibrado"
            verdict = String(format: "Pressão atmosférica local medida em %.0f kPa.", avgV)
            advice = "Sensor barométrico calibrado corretamente para a altitude onde você está rodando."

        case .ambientTemp:
            expectedRange = "-5°C a 45°C (Clima Externo)"
            whatItIs = "Temperatura do ar lá fora na rua durante a sua viagem."
            techRef = "\(g.pidBadge) • Referência climática externa (\(samples) amostras)"
            level = .healthy
            badge = "Lido"
            verdict = String(format: "Clima externo médio de %.0f°C durante o percurso.", avgV)
            advice = "Usado pela central para calibrar a partida, ar-condicionado e temperatura de admissão."

        case .fuelRailPressure:
            expectedRange = isTurbo ? "3.000 a 20.000 kPa (Alta Pressão)" : "280 a 450 kPa"
            whatItIs = "Pressão com que a bomba empurra o combustível para os bicos injetores."
            techRef = "\(g.pidBadge) • Linha de combustível (\(samples) amostras)"
            level = .healthy
            badge = "Pressão Estável"
            verdict = String(format: "Média de %.0f kPa (entre %.0f e %.0f kPa).", avgV, minV, maxV)
            advice = "Bomba de combustível mantendo a linha pressurizada corretamente."

        case .commandedEvapPurge:
            expectedRange = "0% a 100%"
            whatItIs = "Válvula ecológica (Canister) que reaproveita os vapores de combustível do tanque para não desperdiçar nem cheirar gasolina."
            techRef = "\(g.pidBadge) • Válvula solenoide EVAP (\(samples) amostras)"
            level = .healthy
            badge = "Operando Normal"
            verdict = String(format: "Atuou entre %.0f%% e %.0f%% (média %.0f%%) reaproveitando vapores do tanque.", minV, maxV, avgV)
            advice = "Sistema anti-poluição do tanque funcionando normalmente."

        case .ethanolPercent:
            expectedRange = "22% a 100% Etanol"
            whatItIs = "Porcentagem de etanol que o carro identificou no combustível do tanque."
            techRef = "\(g.pidBadge) • Aprendizado Flex da ECU (\(samples) amostras)"
            level = .healthy
            badge = "Identificado"
            verdict = String(format: "Mistura identificada em %.0f%% de etanol.", avgV)
            advice = "Proporção Flex reconhecida pela injeção eletrônica."

        case .estimatedPowerHp, .estimatedTorqueNm:
            let isHp = (g == .estimatedPowerHp)
            expectedRange = isHp ? "Demanda sob pedal (cv)" : "Força nas rodas (Nm)"
            whatItIs = isHp
                ? "Cavalos de potência que você realmente usou do motor durante o trajeto."
                : "Força de empurrão (torque) que o motor entregou nas arrancadas e subidas."
            techRef = "Calculado via fluxo de massa de ar real e RPM (\(samples) amostras)"
            level = .healthy
            badge = "Desempenho Normal"
            verdict = String(format: "Média utilizada de %.0f %@ e pico máximo exigido de %.0f %@.", avgV, g.defaultUnit, maxV, g.defaultUnit)
            advice = "Entrega de força limpa e proporcional ao acelerador."

        default:
            expectedRange = "Informativo da ECU"
            level = .healthy
            badge = "Normal"
            verdict = String(format: "Registrado: mín %.1f %@, média %.1f %@, máx %.1f %@.", minV, g.defaultUnit, avgV, g.defaultUnit, maxV, g.defaultUnit)
            advice = "Parâmetro monitorado normalmente pela rede CAN do veículo."
        }

        return TripSensorEvaluationItem(
            gauge: g,
            minValue: minV,
            avgValue: avgV,
            maxValue: maxV,
            lastValue: lastV,
            unit: g.defaultUnit,
            sampleCount: samples,
            expectedRangeText: expectedRange,
            healthLevel: level,
            statusBadgeTitle: badge,
            laypersonWhatItIs: whatItIs,
            laypersonTripVerdict: verdict,
            laypersonPracticalAdvice: advice,
            technicalSummary: techRef
        )
    }
}
