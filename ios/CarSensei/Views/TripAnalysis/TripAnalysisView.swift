import SwiftUI

struct TripAnalysisView: View {
    @EnvironmentObject var store: CarSenseiStore
    @State private var selectedReportID: UUID?
    @State private var selectedCategoryFilter: String = "Todos"
    @State private var showOnlyAlerts: Bool = false
    @State private var showFeedbackSheet: Bool = false
    @State private var shareFile: ShareFile?
    @State private var isBuildingPDF: Bool = false

    private var activeSelectedReport: TripSensorAnalysisReport? {
        guard let id = selectedReportID else { return nil }
        return store.tripAnalysisReportsHistory.first(where: { $0.id == id })
    }

    private let categories: [String] = [
        "Todos",
        "Temperaturas & Térmica",
        "Consumo & Combustível Flex",
        "Motor, Turbo & Performance",
        "Pedal, Borboleta & Sondas",
        "Elétrica, Odômetros & ECU"
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Tema.fundo.ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 16) {
                        vehicleDynamicParametersCard
                        tripControlAndAutoStartCard

                        if store.isAnalyzingTripSensors {
                            liveRecordingProgressSection
                        }

                        // Histórico de viagens logo no topo
                        if !store.tripAnalysisReportsHistory.isEmpty {
                            savedReportsHistorySection
                        }

                        // Detalhes da viagem aberta (apenas se selecionada pelo usuário)
                        if let report = activeSelectedReport {
                            tripReportHeroCard(report)
                            reportFilterBar(report)
                            reportSensorCardsSection(report)
                        } else if store.tripAnalysisReportsHistory.isEmpty && !store.isAnalyzingTripSensors {
                            emptyReportPlaceholderCard
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("Análise da Viagem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showFeedbackSheet = true
                    } label: {
                        Label("Feedback", systemImage: "bubble.left.and.exclamationmark.bubble.right.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.purple)
                    }
                }
            }
            .sheet(isPresented: $showFeedbackSheet) {
                TissotFeedbackSheet()
            }
            .sheet(item: $shareFile) { file in
                ActivityView(items: [file.url])
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: - 1. Card de Identificação e Parâmetros Dinâmicos do Veículo

    private var vehicleDynamicParametersCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "car.badge.gearshape.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.blue)
                    .frame(width: 38, height: 38)
                    .background(Color.blue.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(store.vehicleIdentity.cleanModelTitle)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Tema.texto)
                        .lineLimit(1)
                    Text("Parâmetros carregados dinamicamente do veículo")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.blue)
                }

                Spacer()
            }

            Text(store.activeVehicleDynamicParametersSummary)
                .font(.caption2)
                .foregroundStyle(Tema.textoSuave)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Tema.borda, lineWidth: 1)
        )
    }

    // MARK: - 2. Card de Controle da Viagem + Chave de Início Automático

    private var tripControlAndAutoStartCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $store.autoStartTripAnalysis) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.circle.fill")
                            .foregroundStyle(.green)
                        Text("Iniciar e encerrar automaticamente")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Tema.texto)
                    }
                    Text("Quando ativo, inicia a leitura assim que o motor liga e gera o laudo sozinho quando você desliga o carro.")
                        .font(.caption2)
                        .foregroundStyle(Tema.textoSuave)
                }
            }
            .tint(.green)

            Divider()

            if store.isAnalyzingTripSensors {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 10, height: 10)
                        Text("GRAVANDO E ANALISANDO VIAGEM EM TEMPO REAL")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(.green)
                        Spacer()
                        Text("\(store.liveTripSensorStats.count) sensores lidos")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Tema.textoSuave)
                    }

                    Text("Dirija normalmente. O CarSensei está medindo mínimo, média e máximo de todos os sensores do seu carro. Ao desligar o motor (ou tocar abaixo), o relatório completo será gerado.")
                        .font(.caption)
                        .foregroundStyle(Tema.textoSuave)

                    Button {
                        store.stopAndGenerateTripReportManually()
                        selectedReportID = store.latestTripAnalysisReport?.id
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "flag.checkered.2.crossed")
                                .font(.headline)
                            Text("Encerrar Viagem e Gerar Relatório Agora")
                                .font(.subheadline.weight(.bold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.orange, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.white)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if store.connectionState == .connectedReady {
                        Button {
                            store.startTripSensorAnalysis()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "play.circle.fill")
                                    .font(.headline)
                                Text("Iniciar Análise dos Sensores da Viagem")
                                    .font(.subheadline.weight(.bold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Color.blue, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(.white)
                        }
                    } else {
                        Button {
                            store.startAutoConnect()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.headline)
                                Text("Conectar ao vLinker MC+ para Analisar Viagem")
                                    .font(.subheadline.weight(.bold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Color.blue, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(.white)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(store.isAnalyzingTripSensors ? Color.green.opacity(0.45) : Tema.borda, lineWidth: 1.2)
        )
    }

    // MARK: - 3. Painel em Tempo Real Enquanto Dirige

    private var liveRecordingProgressSection: some View {
        let items = store.liveTripEvaluatedItems
        let totalSamples = items.reduce(0) { $0 + $1.sampleCount }

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Leituras Ao Vivo na Viagem Atual", systemImage: "waveform.path.ecg")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Tema.texto)
                Spacer()
                Text("\(totalSamples) amostras CAN")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.12), in: Capsule())
            }

            if items.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Aguardando primeiras respostas dos sensores da ECU...")
                        .font(.caption)
                        .foregroundStyle(Tema.textoSuave)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 14))
            } else {
                ForEach(items) { item in
                    TripSensorReportCard(
                        item: item,
                        isLiveRecording: true
                    )
                }
            }
        }
    }

    // MARK: - 4. Histórico de Viagens Analisadas (Posicionado no topo, fechado por padrão)

    private var savedReportsHistorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Histórico de Viagens", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Tema.texto)
                Spacer()
                Text("\(store.tripAnalysisReportsHistory.count) viagem(ns)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Tema.textoSuave)
            }

            ForEach(store.tripAnalysisReportsHistory) { rep in
                let isCurrent = (selectedReportID == rep.id)
                let color = colorForHealth(rep.overallHealth)

                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        // Toque no card para abrir ou fechar as informações da viagem
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if selectedReportID == rep.id {
                                    selectedReportID = nil
                                } else {
                                    selectedReportID = rep.id
                                }
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Text("\(rep.overallScorePercent)%")
                                    .font(.system(size: 13, weight: .black, design: .rounded))
                                    .foregroundStyle(color)
                                    .frame(width: 42, height: 42)
                                    .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rep.vehicleModel)
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(Tema.texto)
                                        .lineLimit(1)
                                    Text("\(rep.endDate.formatted(date: .abbreviated, time: .shortened)) • \(String(format: "%.1f km", rep.distanceKm))")
                                        .font(.caption2)
                                        .foregroundStyle(Tema.textoSuave)
                                }

                                Spacer()

                                Image(systemName: isCurrent ? "chevron.up.circle.fill" : "chevron.down.circle")
                                    .font(.subheadline)
                                    .foregroundStyle(isCurrent ? Color.blue : Color.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        // Botão de gerar PDF individual ao lado da viagem
                        Button {
                            gerarRelatorioPDF(para: rep)
                        } label: {
                            HStack(spacing: 4) {
                                if isBuildingPDF {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "doc.text.fill")
                                }
                                Text("PDF")
                            }
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(Color.indigo.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.indigo)
                        }
                        .buttonStyle(.plain)
                        .disabled(isBuildingPDF)
                        .accessibilityLabel("Gerar PDF desta viagem para IA")

                        // Botão de excluir viagem
                        Button(role: .destructive) {
                            withAnimation {
                                if selectedReportID == rep.id {
                                    selectedReportID = nil
                                }
                                store.deleteTripAnalysisReport(rep.id)
                            }
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundStyle(.red.opacity(0.8))
                                .padding(6)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Excluir viagem")
                    }
                    .padding(12)
                }
                .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(isCurrent ? Color.blue.opacity(0.6) : Tema.borda, lineWidth: isCurrent ? 1.5 : 1)
                )
            }
        }
    }

    // MARK: - 5. Resumo Geral do Laudo da Viagem Aberta

    private func tripReportHeroCard(_ report: TripSensorAnalysisReport) -> some View {
        let accent = colorForHealth(report.overallHealth)
        let healthyCount = report.items.filter { $0.healthLevel == .healthy }.count
        let alertCount = report.items.filter { $0.healthLevel != .healthy }.count

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(accent.opacity(0.2), lineWidth: 6)
                        .frame(width: 62, height: 62)
                    Circle()
                        .trim(from: 0, to: CGFloat(report.overallScorePercent) / 100.0)
                        .stroke(accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 62, height: 62)
                    VStack(spacing: 0) {
                        Text("\(report.overallScorePercent)%")
                            .font(.system(size: 16, weight: .black, design: .rounded))
                            .foregroundStyle(accent)
                        Text("Saúde")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Tema.textoSuave)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("DETALHES DA VIAGEM SELECIONADA")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(accent)
                        Spacer()
                        Text(report.endDate.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(Tema.textoSuave)
                    }

                    Text(report.laypersonHeadline)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Tema.texto)

                    Text(report.laypersonOverview)
                        .font(.caption)
                        .foregroundStyle(Tema.textoSuave)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                summaryMetricPill(
                    title: "BOM / IDEAL",
                    value: "\(healthyCount) sensores",
                    tint: .green
                )
                summaryMetricPill(
                    title: "ATENÇÃO / ALERTA",
                    value: "\(alertCount) sensores",
                    tint: alertCount > 0 ? .orange : .secondary
                )
                summaryMetricPill(
                    title: "DISTÂNCIA",
                    value: String(format: "%.1f km", report.distanceKm),
                    tint: .blue
                )
                summaryMetricPill(
                    title: "MÉDIA",
                    value: report.avgKmPerLiter.map { String(format: "%.1f km/L", $0) } ?? "--",
                    tint: .teal
                )
            }

            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(Tema.textoSuave)
                Text("\(report.finishReason) • Duração: \(formatDuration(report.durationSeconds)) • \(report.fuelProfileTitle)")
                    .font(.caption2)
                    .foregroundStyle(Tema.textoSuave)
            }
        }
        .padding(16)
        .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(accent.opacity(0.35), lineWidth: 1.2)
        )
    }

    private func summaryMetricPill(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Tema.textoSuave)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Tema.subcartao, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 6. Filtros por Categoria e Status

    private func reportFilterBar(_ report: TripSensorAnalysisReport) -> some View {
        let alertCount = report.items.filter { $0.healthLevel != .healthy }.count

        return VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button {
                        showOnlyAlerts.toggle()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text("Só Alertas (\(alertCount))")
                        }
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(showOnlyAlerts ? Color.orange : Tema.cartao, in: Capsule())
                        .foregroundStyle(showOnlyAlerts ? .white : Tema.texto)
                    }

                    ForEach(categories, id: \.self) { category in
                        let isSelected = (!showOnlyAlerts && selectedCategoryFilter == category)
                        Button {
                            showOnlyAlerts = false
                            selectedCategoryFilter = category
                        } label: {
                            Text(category)
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(isSelected ? Color.blue : Tema.cartao, in: Capsule())
                                .foregroundStyle(isSelected ? .white : Tema.textoSuave)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 7. Lista de Cards de Todos os Sensores Analisados

    private func reportSensorCardsSection(_ report: TripSensorAnalysisReport) -> some View {
        let filtered = report.items.filter { item in
            if showOnlyAlerts {
                return item.healthLevel != .healthy
            }
            if selectedCategoryFilter == "Todos" {
                return true
            }
            return item.gauge.category == selectedCategoryFilter
        }

        return VStack(alignment: .leading, spacing: 12) {
            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.green)
                    Text("Nenhum sensor com alerta neste filtro!")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Tema.texto)
                    Text("Todos os sensores desta categoria trabalharam dentro dos parâmetros normais do veículo.")
                        .font(.caption)
                        .foregroundStyle(Tema.textoSuave)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(20)
                .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 16))
            } else {
                ForEach(filtered) { item in
                    TripSensorReportCard(
                        item: item,
                        isLiveRecording: false
                    )
                }
            }
        }
    }

    // MARK: - 8. Estado Inicial Sem Relatório

    private var emptyReportPlaceholderCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg.rectangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.blue)

            Text("Como funciona a Análise da Viagem?")
                .font(.headline.weight(.bold))
                .foregroundStyle(Tema.texto)

            Text("1. Ao conectar no vLinker MC+ e dar partida no carro, o CarSensei lê em tempo real todos os sensores disponíveis na central eletrônica do seu veículo.\n\n2. Durante o trajeto, ele grava o mínimo, a média e o máximo de temperatura do motor, câmbio, bateria, alternador, qualidade da queima de combustível, sondas, pressão do turbo e borboleta.\n\n3. Quando você desliga o carro ao chegar no destino, ele fecha a análise sozinho e monta um laudo completo em linguagem simples dizendo o que está bom e o que precisa de atenção!")
                .font(.caption)
                .foregroundStyle(Tema.textoSuave)
                .multilineTextAlignment(.leading)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Geração de PDF da Viagem para IA

    @MainActor
    private func gerarRelatorioPDF(para report: TripSensorAnalysisReport) {
        isBuildingPDF = true
        let identity = store.vehicleIdentity
        let trips = store.tripHistory
        let battery = store.lastBatterySnapshot
        let adapter = "\(identity.adapterTier.rawValue) — \(identity.adapterFirmware)"

        DispatchQueue.global(qos: .userInitiated).async {
            let url = TripReportPDF.build(
                identity: identity,
                reports: [report],
                fuelTrips: trips,
                adapterDescription: adapter,
                batterySnapshot: battery
            )
            DispatchQueue.main.async {
                isBuildingPDF = false
                if let url {
                    shareFile = ShareFile(url: url)
                    TissotFeedback.log("TRIP_PDF_GENERATED", [
                        "report_id": report.id.uuidString,
                        "bytes": (try? Data(contentsOf: url).count) ?? 0
                    ])
                } else {
                    TissotFeedback.log("TRIP_PDF_FAILED", [:], level: .error)
                }
            }
        }
    }

    private func colorForHealth(_ level: HealthLevel) -> Color {
        switch level {
        case .healthy: return .green
        case .attention: return .orange
        case .critical: return .red
        case .unknown: return .secondary
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let totalMin = max(1, Int(seconds / 60.0))
        if totalMin >= 60 {
            return "\(totalMin / 60)h \(totalMin % 60)min"
        }
        return "\(totalMin) min"
    }
}

// MARK: - Card Individual de Diagnóstico do Sensor na Viagem (Unificado: Leigo & Técnico Juntos)

struct TripSensorReportCard: View {
    let item: TripSensorEvaluationItem
    let isLiveRecording: Bool

    private var statusColor: Color {
        switch item.healthLevel {
        case .healthy: return .green
        case .attention: return .orange
        case .critical: return .red
        case .unknown: return .secondary
        }
    }

    private var statusIcon: String {
        switch item.healthLevel {
        case .healthy: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Cabeçalho do Sensor + Badge Bom / Atenção / Crítico
            HStack(spacing: 10) {
                Image(systemName: item.gauge.iconName)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(statusColor)
                    .frame(width: 34, height: 34)
                    .background(statusColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.gauge.title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Tema.texto)
                    Text(item.gauge.category)
                        .font(.caption2)
                        .foregroundStyle(Tema.textoSuave)
                }

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: statusIcon)
                        .font(.caption2.weight(.bold))
                    Text(item.statusBadgeTitle)
                        .font(.caption2.weight(.heavy))
                }
                .foregroundStyle(statusColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(statusColor.opacity(0.14), in: Capsule())
            }

            // Grade de Valores Medidos na Viagem vs Faixa Ideal do Veículo
            HStack(spacing: 6) {
                if isLiveRecording {
                    metricBox(title: "AGORA", value: formatNumber(item.lastValue, unit: item.unit), highlight: statusColor)
                } else {
                    metricBox(title: "MÍNIMO", value: formatNumber(item.minValue, unit: item.unit), highlight: Tema.texto)
                }
                metricBox(title: "MÉDIA", value: formatNumber(item.avgValue, unit: item.unit), highlight: Tema.texto)
                metricBox(title: "MÁXIMO", value: formatNumber(item.maxValue, unit: item.unit), highlight: statusColor)
                metricBox(title: "PARÂMETRO DO CARRO", value: item.expectedRangeText, highlight: .blue)
            }

            // Explicação Unificada (Linguagem Simples + Referência Técnica juntas)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lightbulb.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .padding(.top, 2)
                    Text("**O que é:** \(item.laypersonWhatItIs)")
                        .font(.caption)
                        .foregroundStyle(Tema.textoSuave)
                }

                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.caption2)
                        .foregroundStyle(statusColor)
                        .padding(.top, 2)
                    Text("**Na sua viagem:** \(item.laypersonTripVerdict)")
                        .font(.caption)
                        .foregroundStyle(Tema.texto)
                }

                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: item.healthLevel == .healthy ? "hand.thumbsup.fill" : "wrench.and.screwdriver.fill")
                        .font(.caption2)
                        .foregroundStyle(statusColor)
                        .padding(.top, 2)
                    Text("**Conclusão:** \(item.laypersonPracticalAdvice)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(item.healthLevel == .healthy ? Tema.textoSuave : statusColor)
                }

                Divider()
                    .padding(.vertical, 2)

                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "cpu.fill")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                        .padding(.top, 2)
                    Text(item.technicalSummary)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.blue)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tema.subcartao, in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(14)
        .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(item.healthLevel == .healthy ? Tema.borda : statusColor.opacity(0.45), lineWidth: 1)
        )
    }

    private func metricBox(title: String, value: String, highlight: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Tema.textoSuave)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(highlight)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(Tema.subcartao, in: RoundedRectangle(cornerRadius: 8))
    }

    private func formatNumber(_ val: Double, unit: String) -> String {
        if unit == "V" || unit == "L/h" || unit == "λ" || unit == "L" {
            return String(format: "%.2f %@", val, unit)
        } else if unit == "km/L" || unit == "g/s" || unit == "km" {
            return String(format: "%.1f %@", val, unit)
        } else {
            return String(format: "%.0f %@", val, unit)
        }
    }
}
