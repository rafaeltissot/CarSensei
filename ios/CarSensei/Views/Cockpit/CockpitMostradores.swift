import SwiftUI

// MARK: - Cartões de Bateria, Consumo com Histórico, Auditoria de KM e Grade de Mostradores

extension CockpitDashboardView {


    func tripCounterPill(label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Tema.textoSuave)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Bloco 2: Saúde da Bateria 12V, Teste de Partida & Métricas da Última Viagem
    var batteryAndVLinkerStandbyCard: some View {
        let t = store.liveTelemetry
        let health = t.batteryHealthAssessment
        let statusTint: Color = {
            switch health.level {
            case .healthy: return .green
            case .attention: return .orange
            case .critical: return .red
            case .unknown: return .blue
            }
        }()

        return VStack(alignment: .leading, spacing: 12) {
            // Cabeçalho Expansível
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isBatteryCardExpanded.toggle()
                }
            } label: {
                HStack {
                    Label("SAÚDE DA BATERIA 12V & SCANNER 24H", systemImage: "bolt.car.circle.fill")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(statusTint)
                        .tracking(0.7)

                    Spacer()

                    Text("\(t.batteryVoltage.map { String(format: "%.2fV", $0) } ?? "--V") • \(health.socPercent)%")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(statusTint)

                    Image(systemName: isBatteryCardExpanded ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(statusTint)
                }
            }
            .buttonStyle(.plain)

            if isBatteryCardExpanded {
                HStack(spacing: 10) {
                    infoSubBox(
                        title: "Tensão Atual",
                        value: t.batteryVoltage.map { String(format: "%.2f V", $0) } ?? "-- V",
                        subtitle: (t.rpm ?? 0) > 400 ? "Alternador Ativo" : "Bateria Pino 16",
                        icon: "bolt.fill",
                        tint: statusTint
                    )

                    infoSubBox(
                        title: "Saúde / Carga",
                        value: t.batteryVoltage != nil ? "\(health.socPercent)%" : "--%",
                        subtitle: health.level.rawValue,
                        icon: "battery.100percent.bolt",
                        tint: statusTint
                    )

                    infoSubBox(
                        title: "Autonomia Parado",
                        value: "~\(health.standbySafeDays) dias",
                        subtitle: "Com vLinker 24h",
                        icon: "moon.zzz.fill",
                        tint: .indigo
                    )
                }

                Text(health.detailText)
                    .font(.caption)
                    .foregroundStyle(Tema.textoSuave)

                // Histórico / Métricas da Última Viagem
                if let snap = store.lastBatterySnapshot {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(Color.green)
                            Text("Métricas da Última Viagem / Uso")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Tema.texto)
                            Spacer()
                            Text(snap.recordedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(Tema.textoSuave)
                        }

                        HStack(spacing: 8) {
                            tripCounterPill(label: "TENSÃO INICIAL", value: String(format: "%.2f V", snap.initialRestVoltage), tint: .blue)
                            if let crank = snap.minCrankingVoltage {
                                tripCounterPill(label: "ARRANQUE PARTIDA", value: String(format: "%.2f V", crank), tint: crank >= 9.6 ? .green : .red)
                            }
                            tripCounterPill(label: "TENSÃO FINAL", value: String(format: "%.2f V", snap.finalVoltage), tint: .teal)
                            tripCounterPill(label: "CARGA ESTIMADA", value: "\(snap.socPercent)%", tint: .green)
                        }
                    }
                    .padding(10)
                    .background(Tema.fundo, in: RoundedRectangle(cornerRadius: 12))
                }

                // Painel de Consumo do Scanner em Sleep (< 3 mA)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                        Text("É 100% seguro deixar o vLinker MC+ conectado 24h")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Tema.texto)
                    }

                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Em Uso (Lendo CAN)")
                                .font(.caption2)
                                .foregroundStyle(Tema.textoSuave)
                            Text("~55 mA (0,66 W)")
                                .font(.caption.weight(.heavy).monospacedDigit())
                                .foregroundStyle(Color.blue)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 8))

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Carro Desligado (Sleep)")
                                .font(.caption2)
                                .foregroundStyle(Tema.textoSuave)
                            Text("< 3 mA (0,06 Ah/dia)")
                                .font(.caption.weight(.heavy).monospacedDigit())
                                .foregroundStyle(Color.green)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 8))
                    }

                    Text("O chip STN entra em Deep Sleep automático quando a ignição é desligada, consumindo menos de 0,1% da bateria de 60 Ah por dia (menos que o próprio alarme original do veículo).")
                        .font(.caption2)
                        .foregroundStyle(Tema.textoSuave)
                }
                .padding(10)
                .background(Tema.fundo, in: RoundedRectangle(cornerRadius: 12))

                // Teste de Partida (10s - CCA)
                Button {
                    Task { await store.runCrankingBatteryTest() }
                } label: {
                    HStack {
                        if store.isRunningCrankingTest {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "waveform.path.ecg")
                        }
                        Text(
                            store.isRunningCrankingTest
                            ? "Medindo Queda de Tensão (10s)... Dê a partida!"
                            : "Testar Saúde da Bateria na Partida (10s - CCA)"
                        )
                        .font(.caption.weight(.bold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        store.connectionState == .connectedReady ? Color.blue : Color.gray.opacity(0.35),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .foregroundStyle(.white)
                }
                .disabled(store.isRunningCrankingTest || store.connectionState != .connectedReady)

                if let crank = store.lastCrankingTest {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Último Teste de Partida: \(crank.healthLevel.rawValue)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(crank.healthLevel == .healthy ? .green : (crank.healthLevel == .attention ? .orange : .red))
                            Spacer()
                            Text(String(format: "Mín: %.2fV • Alternador: %.2fV", crank.minCrankingVoltage, crank.chargingVoltage))
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .foregroundStyle(Tema.texto)
                        }
                        Text(crank.senseiVerdict)
                            .font(.caption2)
                            .foregroundStyle(Tema.textoSuave)
                    }
                    .padding(10)
                    .background(Tema.fundo, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(16)
        .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(statusTint.opacity(0.28), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.03), radius: 6, x: 0, y: 2)
    }

    /// Bloco de informação compacto (bateria, vLinker, viagem) usado nos cartões do Cockpit.
    func infoSubBox(title: String, value: String, subtitle: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption.bold())
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Tema.textoSuave)
                    .lineLimit(1)
            }

            Text(value)
                .font(.system(.headline, design: .rounded).weight(.black))
                .foregroundStyle(Tema.texto)
                .monospacedDigit()

            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(Tema.textoSuave)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Tema.fundo, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Bloco 3: Computador de Consumo & Histórico de Viagens
    var fuelEconomyComputerCard: some View {
        let t = store.liveTelemetry
        let isMoving = (t.speedKmh ?? 0) >= 3.0
        let primaryMetricTitle = isMoving ? "Consumo Instantâneo" : "Fluxo em Marcha Lenta"
        let primaryMetricValue: String = {
            if t.isFuelCut && isMoving {
                return "99.9 km/L (Cut-Off)"
            }
            if isMoving, let kml = t.instantKmPerLiter {
                return String(format: "%.1f km/L", kml)
            } else if let lph = t.fuelRateLitersPerHour {
                let mlMin = lph * 1000.0 / 60.0
                return String(format: "%.2f L/h (%.0f ml/min)", lph, mlMin)
            }
            return "--"
        }()

        let ethanolPct = t.ethanolFuelPct
        let blendLabel: String = {
            guard let pct = ethanolPct else { return "Detectando pelo Fuel Trim / PID 01 52" }
            if pct >= 70 { return String(format: "Etanol Predominante (%.0f%% E)", pct) }
            if pct <= 35 { return String(format: "Gasolina E27 (%.0f%% E)", pct) }
            return String(format: "Mistura Flex (%.0f%% Etanol)", pct)
        }()

        return VStack(alignment: .leading, spacing: 12) {
            // Cabeçalho Expansível
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isFuelCardExpanded.toggle()
                }
            } label: {
                HStack {
                    Label("CONSUMO & HISTÓRICO DE VIAGENS", systemImage: "fuelpump.circle.fill")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(.green)
                        .tracking(0.7)

                    Spacer()

                    Text(t.sessionAverageKmPerLiter.map { String(format: "Média %.1f km/L", $0) } ?? "Viagem em Aberto")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.green)

                    Image(systemName: isFuelCardExpanded ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.green)
                }
            }
            .buttonStyle(.plain)

            if isFuelCardExpanded {
                HStack {
                    Spacer()
                    if t.sessionFuelLiters > 0 || t.sessionDistanceKm > 0 {
                        Button {
                            store.resetTripFuelCounters()
                        } label: {
                            Label("Salvar & Zerar Viagem", systemImage: "arrow.counterclockwise")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.green.opacity(0.12), in: Capsule())
                                .foregroundStyle(.green)
                        }
                    }
                }

                HStack(spacing: 10) {
                    economyMetricBox(
                        title: primaryMetricTitle,
                        value: primaryMetricValue,
                        subtitle: isMoving ? "Em movimento" : "Motor ligado parado",
                        tint: .green
                    )

                    economyMetricBox(
                        title: "Média da Viagem Atual",
                        value: t.sessionAverageKmPerLiter.map { String(format: "%.1f km/L", $0) } ?? "-- km/L",
                        subtitle: String(format: "%.2f km • %.3f L", t.sessionDistanceKm, t.sessionFuelLiters),
                        tint: .teal
                    )
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Detector de Mistura Flex no Tanque", systemImage: "drop.halffull")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Tema.texto)
                        Spacer()
                        Text(blendLabel)
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(Color.green)
                    }

                    GeometryReader { geo in
                        let pct = min(max((ethanolPct ?? 27.0) / 100.0, 0.0), 1.0)
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Tema.trilho)
                            RoundedRectangle(cornerRadius: 6)
                                .fill(
                                    LinearGradient(
                                        colors: [Color.orange, Color.green],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: geo.size.width * pct)
                        }
                    }
                    .frame(height: 8)

                    HStack {
                        Text("Gasolina E27")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Tema.textoSuave)
                        Spacer()
                        Text("Flex 50/50")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Tema.textoSuave)
                        Spacer()
                        Text("Etanol E100")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Tema.textoSuave)
                    }
                }
                .padding(10)
                .background(Tema.fundo, in: RoundedRectangle(cornerRadius: 12))

                // Histórico de Viagens Salvo (recolhido por padrão para tela limpa)
                DisclosureGroup(isExpanded: $isFuelHistoryExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        if store.tripHistory.isEmpty {
                            Text("Conecte ao carro e dirija para registrar viagens. Ao zerar a viagem ou desligar o carro, a média é gravada automaticamente aqui.")
                                .font(.caption2)
                                .foregroundStyle(Tema.textoSuave)
                        } else {
                            ForEach(Array(store.tripHistory.prefix(4))) { trip in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(trip.endDate.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(Tema.texto)
                                        Text(String(format: "%.2f km • %.3f L • %@", trip.distanceKm, trip.fuelLiters, trip.fuelProfile.rawValue))
                                            .font(.caption2)
                                            .foregroundStyle(Tema.textoSuave)
                                    }
                                    Spacer()
                                    Text(String(format: "%.1f km/L", trip.avgKmPerLiter))
                                        .font(.subheadline.weight(.black))
                                        .foregroundStyle(Color.green)
                                        .monospacedDigit()
                                }
                                .padding(8)
                                .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "list.clipboard.fill")
                            .foregroundStyle(Color.green)
                        Text("Histórico de Viagens Gravadas (\(store.tripHistory.count))")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Tema.texto)
                        Spacer()
                    }
                }
                .padding(10)
                .background(Tema.fundo, in: RoundedRectangle(cornerRadius: 12))

                // Calibração com abastecimento real: é o que aproxima a média do app da conta do posto.
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MÉDIA REAL (TANQUE A TANQUE)")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(Tema.textoSuave)
                        Text(realAverageLabel)
                            .font(.system(size: 13, weight: .black, design: .rounded))
                            .foregroundStyle(store.lastFillUp?.realKmPerLiter == nil ? Tema.textoSuave : Color.teal)
                            .monospacedDigit()
                        Text(String(format: "Estimativa corrigida por fator %.2f · %.1f L desde o último abastecimento", store.fuelCalibrationFactor, store.litersSinceFillUp))
                            .font(.system(size: 9))
                            .foregroundStyle(Tema.textoSuave)
                    }
                    Spacer()
                    Button {
                        showFuelFillUpSheet = true
                    } label: {
                        Text("Abasteci")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .background(Color.teal.opacity(0.14), in: Capsule())
                            .foregroundStyle(.teal)
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(Tema.fundo, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(16)
        .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.green.opacity(0.28), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.03), radius: 6, x: 0, y: 2)
    }

    private var realAverageLabel: String {
        if let real = store.lastFillUp?.realKmPerLiter {
            return String(format: "%.1f km/L", real)
        }
        return "Toque em \"Abasteci\" para calibrar"
    }

    func economyMetricBox(title: String, value: String, subtitle: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Tema.textoSuave)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.black))
                .foregroundStyle(Tema.texto)
                .monospacedDigit()
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Tema.fundo, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Bloco 4: Auditoria de Hodômetro (KM Real nas ECUs) na Tela Inicial
    var odometerForensicsHomeBlock: some View {
        OdometerHomeCardView(store: store, isExpanded: $isOdometerCardExpanded)
    }

    // MARK: - Bloco 5: Mostradores em Tempo Real Expansível (22 Sensores)
    var customizeGaugesHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            // Left: Expand / Collapse Trigger
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isGaugesCardExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isGaugesCardExpanded ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.blue)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("MOSTRADORES EM TEMPO REAL (\(store.enabledGauges.count)/\(CockpitGaugeID.allCases.count))")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(Tema.texto)
                            .tracking(0.6)
                        Text("Segure qualquer card para substituir por outro dos \(CockpitGaugeID.allCases.count) sensores")
                            .font(.caption2)
                            .foregroundStyle(Tema.textoSuave)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            // Right: Distinct "Personalizar" button
            Button {
                showGaugeCustomizationSheet = true
            } label: {
                Label("Personalizar", systemImage: "slider.horizontal.3")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Color.blue.opacity(0.12), in: Capsule())
                    .foregroundStyle(Color.blue)
            }
            .buttonStyle(.borderless)
        }
        .padding(.top, 4)
    }

    var liveGaugesGrid: some View {
        Group {
            if isGaugesCardExpanded {
                let activeGauges = store.enabledGauges
                let visibleGauges = showAllGauges ? activeGauges : Array(activeGauges.prefix(6))
                VStack(spacing: 12) {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(visibleGauges) { gauge in
                            gaugeCardView(for: gauge)
                                .contentShape(RoundedRectangle(cornerRadius: 18))
                                .onLongPressGesture(minimumDuration: 0.4) {
                                    gaugeBeingReplaced = gauge
                                }
                        }
                    }

                    if activeGauges.count > 6 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showAllGauges.toggle()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: showAllGauges ? "chevron.up.circle.fill" : "plus.circle.fill")
                                Text(
                                    showAllGauges
                                    ? "Mostrar apenas os 6 mostradores principais"
                                    : "Ver todos os \(activeGauges.count) sensores em tempo real (+\(activeGauges.count - 6))"
                                )
                            }
                            .font(.caption.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(Tema.borda, lineWidth: 1)
                            )
                            .foregroundStyle(Color.blue)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    func gaugeCardView(for gauge: CockpitGaugeID) -> some View {
        let p = store.presentation(for: gauge)
        GaugeCard(
            title: gauge.title,
            value: p.value,
            unit: p.unit,
            subtitle: p.subtitle,
            icon: gauge.iconName,
            accent: p.tint,
            progress: p.progress,
            isAlerting: p.isAlerting
        )
    }

    private var coolantColor: Color {
        guard let temp = store.liveTelemetry.coolantTempC else { return .blue }
        let th = store.vehicleIdentity.thermalThresholds.coolant
        if temp >= th.criticalDTCThresholdC { return .red }
        if temp >= th.warningThresholdC { return .orange }
        return .blue
    }

    private var coolantStatusText: String {
        guard let temp = store.liveTelemetry.coolantTempC else { return "Aguardando leitura" }
        let th = store.vehicleIdentity.thermalThresholds.coolant
        if temp >= th.criticalDTCThresholdC { return "ALERTA: Superaquecimento!" }
        if temp >= th.warningThresholdC { return "Atenção: Térmica Elevada" }
        if temp >= th.fanHighNormalMaxC { return "Ventoinha alta velocidade" }
        if temp >= th.warmUpThresholdC { return "Temperatura ideal" }
        return "Fase de aquecimento"
    }

    private var cvtTempColor: Color {
        let assessment = store.liveTelemetry.transmissionHealthAssessment(with: store.vehicleIdentity.thermalThresholds.transmission)
        switch assessment.level {
        case .critical: return .red
        case .attention: return .orange
        default: return .teal
        }
    }

    private var cvtTempStatusText: String {
        guard let temp = store.liveTelemetry.transmissionTempC else { return "UDS 22 0B 37 (TCU)" }
        let th = store.vehicleIdentity.thermalThresholds.transmission
        if temp >= th.criticalDTCThresholdC {
            return String(format: "CRÍTICO (≥%.0f°C) Risco P0218", th.criticalDTCThresholdC)
        }
        if temp >= th.thermalInterventionC {
            return String(format: "Atenção Térmica TCU (≥%.0f°C)", th.thermalInterventionC)
        }
        if temp >= th.warmUpThresholdC {
            let label = temp > th.nominalMaxC ? "Carga Rodovia" : "Normal"
            return String(format: "%@ (%.0f°C–%.0f°C)", label, th.warmUpThresholdC, th.heavyLoadNormalMaxC)
        }
        return String(format: "Aquecendo (<%.0f°C)", th.warmUpThresholdC)
    }

    private var batteryColor: Color {
        guard let v = store.liveTelemetry.batteryVoltage else { return .green }
        if v < 11.9 { return .red }
        if v < 12.4 { return .orange }
        return .green
    }

    private var batteryStatusText: String {
        guard let v = store.liveTelemetry.batteryVoltage else { return "Pino 16 OBD-II" }
        if v >= 13.5 { return "Alternador carregando" }
        if v >= 12.3 { return "Bateria saudável" }
        return "Bateria baixa (<12.3V)"
    }

    private var boostSubtitleText: String {
        guard let boostBar = store.liveTelemetry.estimatedBoostBar else { return "Coletor / Turbo" }
        if boostBar > 0.05 {
            return String(format: "Boost: +%.2f bar", boostBar)
        } else {
            return String(format: "Vácuo: %.2f bar", boostBar)
        }
    }
}

// MARK: - Componente Isolado: Auditoria de Hodômetro na Home
struct OdometerHomeCardView: View {
    @ObservedObject var store: CarSenseiStore
    @Binding var isExpanded: Bool
    @FocusState private var kmFocused: Bool

    private var verdictColor: Color {
        guard let rep = store.odometerReport else { return .blue }
        switch rep.verdict {
        case .verifiedIntact: return .green
        case .noEvidenceFound: return .teal
        case .suspiciousDiscrepancy: return .orange
        case .tamperingConfirmed: return .red
        case .inconclusive, .awaitingScan: return .blue
        }
    }

    var body: some View {
        let ready = store.connectionState == .connectedReady
        let report = store.odometerReport

        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Label("AUDITORIA DE KM (HODÔMETRO ORIGINAL)", systemImage: "shield.lefthalf.filled.badge.checkmark")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(verdictColor)
                        .tracking(0.7)

                    Spacer()

                    Text(report?.verdict.rawValue ?? "Pronto para Auditar")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(verdictColor)

                    Image(systemName: isExpanded ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(verdictColor)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                HStack(spacing: 10) {
                    TextField("KM do Painel (Ex: 60327)", text: $store.clusterKmInputText)
                        .keyboardType(.numberPad)
                        .focused($kmFocused)
                        .font(.subheadline.weight(.bold))
                        .padding(10)
                        .background(Tema.fundo, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(Tema.texto)

                    Button {
                        kmFocused = false
                        Task { await store.runOdometerForensicsAudit() }
                    } label: {
                        HStack(spacing: 4) {
                            if store.isRunningForensics {
                                ProgressView().tint(.white).controlSize(.small)
                            } else {
                                Image(systemName: "magnifyingglass")
                            }
                            Text(store.isRunningForensics ? "Auditando..." : "Auditar KM")
                        }
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(ready ? Color.blue : Color.gray.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white)
                    }
                    .disabled(!ready || store.isRunningForensics)
                }
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("OK") { kmFocused = false }
                    }
                }

                if let rep = report {
                    forensicsResultView(rep: rep)
                } else if !store.isRunningForensics {
                    Text("Informe o KM do painel e toque em Auditar KM para comparar com os módulos.")
                        .font(.caption2)
                        .foregroundStyle(Tema.textoSuave)
                }
            }
        }
        .padding(16)
        .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(verdictColor.opacity(0.28), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.03), radius: 6, x: 0, y: 2)
    }

    @ViewBuilder
    private func forensicsResultView(rep: OdometerAuditReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Veredito: \(rep.verdict.rawValue)")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(verdictColor)
                Spacer()
                if let km = rep.highestRecordedKmAcrossECUs {
                    Text(String(format: "Maior KM: %.0f km", km))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Tema.texto)
                }
            }

            Text(rep.summaryExplanation)
                .font(.caption2)
                .foregroundStyle(Tema.textoSuave)

            ForEach(rep.evidences) { ev in
                HStack {
                    Text(ev.sourceModule)
                        .font(.caption2.weight(.heavy))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.blue)

                    Text(ev.checkTitle)
                        .font(.caption2)
                        .foregroundStyle(Tema.texto)
                        .lineLimit(1)

                    Spacer()

                    Text(ev.measuredValueText)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Tema.texto)
                }
            }
        }
        .padding(10)
        .background(Tema.fundo, in: RoundedRectangle(cornerRadius: 12))
    }
}
