import SwiftUI
import CarPlay
import UIKit
import Combine

// MARK: - Native CarPlay Scene Delegate (Supports Both Full-Screen CPWindow & Live CPTabBarTemplate)
@objc(CarPlaySceneDelegate)
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    var interfaceController: CPInterfaceController?
    var carWindow: CPWindow?
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?
    private var lastTemplateReload: Date = .distantPast

    // 1. Chamado quando o entitlement inclui carplay-maps / carplay-video (entrega o CPWindow gráfico tela cheia 592x333)
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        self.interfaceController = interfaceController
        self.carWindow = window
        TissotFeedback.log("SCREEN", ["name": "CarPlay FullScreen Window"])

        Task { @MainActor in
            let rootView = MultimediaMirrorDashboardView(isEmbeddedInExternalScreen: true)
                .environmentObject(CarSenseiStore.shared)
            let hosting = UIHostingController(rootView: rootView)
            hosting.view.backgroundColor = .clear
            window.rootViewController = hosting
            window.isHidden = false

            let baseTemplate = CPMapTemplate()
            interfaceController.setRootTemplate(baseTemplate, animated: false, completion: nil)

            if CarSenseiStore.shared.connectionState == .disconnected {
                CarSenseiStore.shared.startAutoConnect()
            }
        }
    }

    // 2. Chamado quando o CarPlay conecta no modo Template (carplay-audio / informações em tempo real)
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        TissotFeedback.log("SCREEN", ["name": "CarPlay Live Templates"])

        Task { @MainActor in
            if CarSenseiStore.shared.connectionState == .disconnected {
                CarSenseiStore.shared.startAutoConnect()
            }
            self.buildAndSetRootTemplates()
            self.startLiveCarPlayUpdates()
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        stopLiveCarPlayUpdates()
        self.interfaceController = nil
        self.carWindow = nil
    }

    @MainActor
    private func startLiveCarPlayUpdates() {
        stopLiveCarPlayUpdates()

        CarSenseiStore.shared.$liveTelemetry
            .throttle(for: .milliseconds(1200), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                self?.refreshLiveTemplatesInPlace()
            }
            .store(in: &cancellables)

        CarSenseiStore.shared.$connectionState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .disconnected, .error, .bluetoothOff:
                        // Sem scanner não há dado novo: o timer para em vez de reconstruir a tela a cada 1,5 s.
                        self.refreshTimer?.invalidate()
                        self.refreshTimer = nil
                    default:
                        self.startRefreshTimerIfNeeded()
                    }
                    self.refreshLiveTemplatesInPlace()
                }
            }
            .store(in: &cancellables)

        startRefreshTimerIfNeeded()
    }

    @MainActor
    private func startRefreshTimerIfNeeded() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshLiveTemplatesInPlace()
            }
        }
    }

    private func stopLiveCarPlayUpdates() {
        cancellables.removeAll()
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Live Updating CarPlay Templates (Tela Única Unificada)

    private var allSensorsListTemplate: CPListTemplate?

    @MainActor
    func buildAndSetRootTemplates() {
        guard let interfaceController else { return }

        let sensorsList = CPListTemplate(
            title: consumptionHeaderTitle(),
            sections: buildAllSensorsSections()
        )
        self.allSensorsListTemplate = sensorsList
        interfaceController.setRootTemplate(sensorsList, animated: false, completion: nil)
    }

    @MainActor
    func refreshLiveTemplatesInPlace() {
        guard carWindow == nil else { return }
        let now = Date()
        guard now.timeIntervalSince(lastTemplateReload) >= 1.0 else { return }
        lastTemplateReload = now

        if allSensorsListTemplate == nil {
            buildAndSetRootTemplates()
            return
        }

        allSensorsListTemplate?.updateSections(buildAllSensorsSections())
    }

    @MainActor
    private func consumptionHeaderTitle() -> String {
        let store = CarSenseiStore.shared
        let connected = store.connectionState == .connectedReady
        let hz = store.liveTelemetry.pollRateHz > 0 ? String(format: " • %.1f Hz", store.liveTelemetry.pollRateHz) : ""
        return connected
            ? "CarSensei • Aferição de Consumo Real\(hz)"
            : "CarSensei • \(store.connectionState.rawValue)"
    }

    @MainActor
    private func buildConsumptionItems() -> [CPInformationItem] {
        let store = CarSenseiStore.shared
        let t = store.liveTelemetry

        let instantStr: String = {
            if let kml = t.instantKmPerLiter {
                return String(format: "%.1f km/L (Andando)", kml)
            } else if let lh = t.fuelRateLitersPerHour {
                return String(format: "%.2f L/h (Parado / Marcha Lenta)", lh)
            }
            return "Aguardando motor funcionar"
        }()

        let avgStr = t.sessionAverageKmPerLiter.map { String(format: "%.1f km/L", $0) } ?? "Ande >50m p/ média"
        let tripStr = String(format: "Distância: %.2f km  |  Gasto: %.3f L", t.sessionDistanceKm, t.sessionFuelLiters)
        let flowStr = t.fuelRateLitersPerHour.map { String(format: "%.2f L/h", $0) } ?? "-- L/h"
        let fuelTypeStr = "\(store.selectedFuelProfile.rawValue) • Etanol: \(t.ethanolFuelPct.map { "\(Int($0))%" } ?? "Auto")"
        let speedRpmStr = "Vel: \(t.speedKmh.map { "\(Int($0)) km/h" } ?? "-- km/h")  |  Rotação: \(t.rpm.map { "\(Int($0)) RPM" } ?? "-- RPM")"
        let tempsStr = "Motor: \(t.coolantTempC.map { "\(Int($0))°C" } ?? "--°C")  |  Câmbio CVT: \(t.transmissionTempC.map { "\(Int($0))°C" } ?? "--°C")  |  Bat: \(t.batteryVoltage.map { String(format: "%.2fV", $0) } ?? "--V")"

        return [
            CPInformationItem(
                title: "CONSUMO INSTANTÂNEO vs. MÉDIA DA VIAGEM",
                detail: "Inst: \(instantStr)   |   MÉDIA: \(avgStr)"
            ),
            CPInformationItem(
                title: "CONTADORES DA VIAGEM (Compare com o Painel)",
                detail: "\(tripStr)   |   Fluxo: \(flowStr)"
            ),
            CPInformationItem(
                title: "VELOCIDADE REAL CAN & ROTAÇÃO",
                detail: speedRpmStr
            ),
            CPInformationItem(
                title: "MOTOR, CÂMBIO CVT & BATERIA 12V",
                detail: tempsStr
            ),
            CPInformationItem(
                title: "PERFIL DE COMBUSTÍVEL & MISTURA FLEX",
                detail: "\(fuelTypeStr)  |  STFT: \(t.shortFuelTrimPct.map { String(format: "%+.1f%%", $0) } ?? "--")  LTFT: \(t.longFuelTrimPct.map { String(format: "%+.1f%%", $0) } ?? "--")"
            )
        ]
    }

    @MainActor
    private func buildConsumptionActions() -> [CPTextButton] {
        let resetTripBtn = CPTextButton(title: "Zerar Viagem", textStyle: .confirm) { [weak self] _ in
            Task { @MainActor in
                CarSenseiStore.shared.resetTripFuelCounters()
                self?.refreshLiveTemplatesInPlace()
            }
        }

        return [resetTripBtn]
    }

    @MainActor
    private func buildAllSensorsSections() -> [CPListSection] {
        let store = CarSenseiStore.shared
        let categories = [
            "Consumo & Combustível Flex",
            "Motor, Turbo & Performance",
            "Pedal, Borboleta & Sondas",
            "Temperaturas & Térmica",
            "Elétrica, Odômetros & ECU"
        ]

        return categories.enumerated().map { secIdx, category in
            let gauges = CockpitGaugeID.allCases.filter { $0.category == category }
            let items: [CPListItem] = gauges.map { gauge in
                let idx = (CockpitGaugeID.allCases.firstIndex(of: gauge) ?? 0) + 1
                let pres = store.presentation(for: gauge)
                return sensorListItem(
                    icon: gauge.iconName,
                    title: "\(idx). \(gauge.title)",
                    value: pres.compactText,
                    subtitle: "\(gauge.pidBadge) • \(gauge.summaryDescription)"
                )
            }
            return CPListSection(items: items, header: "\(secIdx + 1). \(category)", sectionIndexTitle: nil)
        }
    }

    @MainActor
    private func sensorListItem(
        icon: String,
        title: String,
        value: String,
        subtitle: String,
        onSelect: (() -> Void)? = nil
    ) -> CPListItem {
        let item = CPListItem(
            text: "\(title):  \(value)",
            detailText: subtitle,
            image: UIImage(systemName: icon)
        )
        item.handler = { [weak self] _, completion in
            Task { @MainActor in
                if let onSelect {
                    onSelect()
                    self?.refreshLiveTemplatesInPlace()
                }
                completion()
            }
        }
        return item
    }

    private func shortFuelName(_ profile: FuelTypeProfile) -> String {
        switch profile {
        case .autoDetected: return "Auto"
        case .gasolineE27: return "Gasolina E27"
        case .flexBlend50: return "Misto 50/50"
        case .ethanolE100: return "Etanol E100"
        }
    }
}

// MARK: - CarPlay External Window Scene Delegate (UIWindowSceneSessionRoleCarPlay — 592x333 Canvas)
@objc(CarPlayWindowSceneDelegate)
final class CarPlayWindowSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let hostWindow = UIWindow(windowScene: windowScene)
        let contentView = MultimediaMirrorDashboardView(isEmbeddedInExternalScreen: true)
            .environmentObject(CarSenseiStore.shared)
        hostWindow.rootViewController = UIHostingController(rootView: contentView)
        self.window = hostWindow
        hostWindow.makeKeyAndVisible()

        Task { @MainActor in
            if CarSenseiStore.shared.connectionState == .disconnected {
                CarSenseiStore.shared.startAutoConnect()
            }
        }
    }
}

// MARK: - Full-Screen Unified CarPlay & Multimedia Cockpit Dashboard (Sem Abas e Sem Rolagem + Substituição de Sensores)
struct MultimediaMirrorDashboardView: View {
    @EnvironmentObject var store: CarSenseiStore
    @Environment(\.dismiss) private var dismiss
    var isEmbeddedInExternalScreen: Bool = false

    @State private var showFeedbackSheet = false
    @State private var editingCarPlaySlotIndex: Int?
    @State private var selectedPickerCategory: String = "Todos"
    /// Sensor marcado esperando o segundo toque (evita troca acidental com o carro em movimento).
    @State private var pendingGauge: CockpitGaugeID?
    /// Instante em que a tela de troca abriu: toques nos primeiros 0,45 s são ignorados.
    @State private var pickerArmedAt: Date = .distantPast

    private let pickerCategories: [(label: String, key: String)] = [
        ("Todos (42)", "Todos"),
        ("Consumo", "Consumo & Combustível Flex"),
        ("Motor & Turbo", "Motor, Turbo & Performance"),
        ("Pedal & Sondas", "Pedal, Borboleta & Sondas"),
        ("Térmica", "Temperaturas & Térmica"),
        ("Elétrica & ECU", "Elétrica, Odômetros & ECU")
    ]

    private func slotGauge(at index: Int) -> CockpitGaugeID {
        let slots = store.carPlaySlotGauges
        if slots.indices.contains(index) {
            return slots[index]
        }
        let defaults = CockpitGaugeID.defaultCarPlaySlots
        return defaults.indices.contains(index) ? defaults[index] : .speed
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Tema.fundo.ignoresSafeArea()

            consumptionAndLiveCockpitView
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

            if !isEmbeddedInExternalScreen && editingCarPlaySlotIndex == nil {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 30, height: 30)
                        .background(Tema.trilho.opacity(0.9), in: Circle())
                        .foregroundStyle(Tema.texto)
                }
                .buttonStyle(.plain)
                .padding(12)
            }

            if let slotIndex = editingCarPlaySlotIndex {
                carPlaySensorPickerOverlay(forSlotIndex: slotIndex)
                    .transition(.opacity)
                    .onAppear {
                        pendingGauge = nil
                        pickerArmedAt = Date()
                    }
            }
        }
        .tissotScreen("Central Multimídia / CarPlay")
        .sheet(isPresented: $showFeedbackSheet) {
            TissotFeedbackSheet()
        }
    }

    // MARK: - Tela Única Full-Screen (Todos os 22 Slots Personalizáveis simultâneos sem rolagem no CarPlay)
    private var consumptionAndLiveCockpitView: some View {
        let t = store.liveTelemetry

        return GeometryReader { geo in
            let isLandscape = geo.size.width >= 480

            if isLandscape {
                HStack(spacing: 8) {
                    // ESQUERDA (54% da tela): Consumo Instantâneo + Média + 16 Sensores Personalizáveis em Grade 4x4 (Slots 0..15)
                    fuelComparisonHeroCard(t: t)
                        .frame(width: geo.size.width * 0.54)

                    // DIREITA (46% da tela): 2 Mostradores Principais (Slots 16..17) + 4 Vitais (Slots 18..21)
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            configurablePrimaryGaugeSlot(slotIndex: 16)
                            configurablePrimaryGaugeSlot(slotIndex: 17)
                        }

                        HStack(spacing: 6) {
                            configurableVitalCardSlot(slotIndex: 18)
                            configurableVitalCardSlot(slotIndex: 19)
                        }

                        HStack(spacing: 6) {
                            configurableVitalCardSlot(slotIndex: 20)
                            configurableVitalCardSlot(slotIndex: 21)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        fuelComparisonHeroCard(t: t)
                        HStack(spacing: 8) {
                            configurablePrimaryGaugeSlot(slotIndex: 16)
                            configurablePrimaryGaugeSlot(slotIndex: 17)
                        }
                        HStack(spacing: 8) {
                            configurableVitalCardSlot(slotIndex: 18)
                            configurableVitalCardSlot(slotIndex: 19)
                        }
                        HStack(spacing: 8) {
                            configurableVitalCardSlot(slotIndex: 20)
                            configurableVitalCardSlot(slotIndex: 21)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Coluna Esquerda Full-Screen: Consumo + 16 Sensores Personalizáveis em Grade 4x4 (Slots 0..15)
    private func fuelComparisonHeroCard(t: TelemetrySnapshot) -> some View {
        let connected = store.connectionState == .connectedReady
        let isMoving = (t.speedKmh ?? 0) >= 3.0
        let instantValueText: String = {
            if let kml = t.instantKmPerLiter {
                return String(format: "%.1f", kml)
            } else if let lh = t.fuelRateLitersPerHour {
                return String(format: "%.2f", lh)
            }
            return "--"
        }()
        let instantUnitText: String = {
            if t.instantKmPerLiter != nil { return "km/L" }
            if t.fuelRateLitersPerHour != nil { return "L/h" }
            return "km/L"
        }()
        let idleHelperText: String = {
            if isMoving {
                return "Consumo agora (\(instantUnitText))"
            }
            if let lh = t.fuelRateLitersPerHour {
                let mlPerMin = Int((lh * 1000.0 / 60.0).rounded())
                return "Parado • ~\(mlPerMin) ml/min"
            }
            return "Aguardando motor"
        }()
        let avgValueText = t.sessionAverageKmPerLiter.map { String(format: "%.1f", $0) } ?? "--"
        let barProgress = min(max((t.instantKmPerLiter ?? 0) / 30.0, 0.04), 1.0)

        return VStack(alignment: .leading, spacing: 5) {
            // Dois Mostradores Lado a Lado no Topo: INSTANTÂNEO vs. MÉDIA DA VIAGEM
            HStack(spacing: 6) {
                // 1. Consumo Instantâneo
                VStack(alignment: .leading, spacing: 2) {
                    Text(isMoving ? "INSTANTÂNEO" : "PARADO")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Tema.textoSuave)
                        .lineLimit(1)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(instantValueText)
                            .font(.system(size: 19, weight: .black, design: .rounded))
                            .foregroundStyle(Color.green)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text(instantUnitText)
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Tema.textoSuave)
                            .lineLimit(1)
                    }
                    if isMoving {
                        GeometryReader { barGeo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.green.opacity(0.14))
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [.orange, .yellow, .green],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: barGeo.size.width * barProgress)
                                    .animation(.easeOut(duration: 0.25), value: barProgress)
                            }
                        }
                        .frame(height: 5)
                    } else {
                        Text(idleHelperText)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Tema.textoSuave)
                            .lineLimit(1)
                    }
                }
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tema.fundo, in: RoundedRectangle(cornerRadius: 10))

                // 2. Média da Viagem + Indicador Compacto de Conexão/Hz
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("MÉDIA")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Tema.textoSuave)
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Button {
                            if !connected {
                                store.startAutoConnect()
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(connected ? Color.green : Color.orange)
                                    .frame(width: 6, height: 6)
                                Text(connected && t.pollRateHz > 0 ? String(format: "%.1fHz", t.pollRateHz) : (connected ? "ON" : "Conectar"))
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundStyle(connected ? Color.green : Color.orange)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(avgValueText)
                            .font(.system(size: 19, weight: .black, design: .rounded))
                            .foregroundStyle(Color.blue)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text("km/L")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Color.blue)
                    }
                    Text(t.sessionDistanceKm >= 0.05 ? "Segure um sensor p/ trocar" : "Ande 50 m p/ média")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Tema.textoSuave)
                        .lineLimit(1)
                }
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tema.fundo, in: RoundedRectangle(cornerRadius: 10))
            }

            // 4 Linhas x 4 Colunas = 16 Slots Personalizáveis (Slots 0..15)
            ForEach(0..<4, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<4, id: \.self) { col in
                        let slotIdx = row * 4 + col
                        configurablePillSlot(slotIndex: slotIdx)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tema.borda, lineWidth: 1))
    }

    private func configurablePillSlot(slotIndex: Int) -> some View {
        let gauge = slotGauge(at: slotIndex)
        let pres = store.presentation(for: gauge)
        return tripCounterPill(
            label: gauge.shortCarPlayLabel,
            value: pres.compactText,
            tint: pres.tint
        )
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) {
                editingCarPlaySlotIndex = slotIndex
            }
        }
        .onLongPressGesture(minimumDuration: 0.35) {
            withAnimation(.easeInOut(duration: 0.18)) {
                editingCarPlaySlotIndex = slotIndex
            }
        }
    }

    private func configurablePrimaryGaugeSlot(slotIndex: Int) -> some View {
        let gauge = slotGauge(at: slotIndex)
        let pres = store.presentation(for: gauge)
        return livePrimaryGaugeTile(
            title: gauge.shortCarPlayLabel,
            value: pres.value,
            unit: pres.unit,
            subtitle: pres.subtitle,
            accent: pres.tint,
            progress: min(max(pres.progress, 0.04), 1.0)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) {
                editingCarPlaySlotIndex = slotIndex
            }
        }
        .onLongPressGesture(minimumDuration: 0.35) {
            withAnimation(.easeInOut(duration: 0.18)) {
                editingCarPlaySlotIndex = slotIndex
            }
        }
    }

    private func configurableVitalCardSlot(slotIndex: Int) -> some View {
        let gauge = slotGauge(at: slotIndex)
        let pres = store.presentation(for: gauge)
        return miniVitalCard(
            icon: gauge.iconName,
            title: gauge.shortCarPlayLabel,
            value: pres.compactText,
            detail: pres.subtitle,
            tint: pres.tint,
            isAlerting: pres.isAlerting
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) {
                editingCarPlaySlotIndex = slotIndex
            }
        }
        .onLongPressGesture(minimumDuration: 0.35) {
            withAnimation(.easeInOut(duration: 0.18)) {
                editingCarPlaySlotIndex = slotIndex
            }
        }
    }

    // MARK: - Overlay de Seleção e Explicação dos 42 Sensores no CarPlay
    private func carPlaySensorPickerOverlay(forSlotIndex slotIndex: Int) -> some View {
        let currentGauge = slotGauge(at: slotIndex)
        let filteredGauges = CockpitGaugeID.allCases.filter {
            selectedPickerCategory == "Todos" || $0.category == selectedPickerCategory
        }
        let columns = [
            GridItem(.flexible(), spacing: 6),
            GridItem(.flexible(), spacing: 6)
        ]

        return ZStack {
            Tema.fundo.opacity(0.98).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 6) {
                // Topo: Título do sensor sendo substituído + Botões Restaurar e Fechar
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.blue)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Substituir: \(currentGauge.title) (Slot #\(slotIndex + 1))")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(Tema.texto)
                            .lineLimit(1)
                        Text("Toque para marcar e toque de novo para aplicar — assim não troca sem querer")
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(Tema.textoSuave)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button {
                        store.resetCarPlaySlotsToDefault()
                        withAnimation(.easeInOut(duration: 0.18)) {
                            editingCarPlaySlotIndex = nil
                        }
                    } label: {
                        Text("Padrão")
                            .font(.system(size: 9.5, weight: .bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Tema.cartao, in: Capsule())
                            .overlay(Capsule().stroke(Tema.borda, lineWidth: 1))
                            .foregroundStyle(Tema.textoSuave)
                    }
                    .buttonStyle(.plain)

                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            editingCarPlaySlotIndex = nil
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "xmark")
                            Text("Fechar")
                        }
                        .font(.system(size: 10, weight: .heavy))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.blue, in: Capsule())
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }

                // Filtro rápido de categorias
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(pickerCategories, id: \.key) { item in
                            let isSelected = selectedPickerCategory == item.key
                            Button {
                                selectedPickerCategory = item.key
                            } label: {
                                Text(item.label)
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(isSelected ? Color.blue : Tema.cartao, in: Capsule())
                                    .overlay(Capsule().stroke(Tema.borda, lineWidth: isSelected ? 0 : 1))
                                    .foregroundStyle(isSelected ? .white : Tema.texto)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Lista em 2 colunas com todos os sensores, valor em tempo real e resumo explicativo
                ScrollView(showsIndicators: true) {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(filteredGauges) { gauge in
                            let pres = store.presentation(for: gauge)
                            let isCurrent = (gauge == currentGauge)
                            let isPending = (pendingGauge == gauge)
                            let isOnScreen = store.carPlaySlotGauges.contains(gauge)

                            Button {
                                // Carro em movimento balança a tela: um toque só marca, o segundo aplica.
                                guard Date().timeIntervalSince(pickerArmedAt) > 0.45 else { return }
                                guard pendingGauge == gauge else {
                                    withAnimation(.easeInOut(duration: 0.15)) { pendingGauge = gauge }
                                    return
                                }
                                store.replaceCarPlaySlot(at: slotIndex, with: gauge)
                                pendingGauge = nil
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    editingCarPlaySlotIndex = nil
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 5) {
                                        Image(systemName: gauge.iconName)
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(pres.tint)
                                            .frame(width: 20, height: 20)
                                            .background(pres.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))

                                        Text(gauge.title)
                                            .font(.system(size: 10, weight: .heavy))
                                            .foregroundStyle(Tema.texto)
                                            .lineLimit(2)
                                            .minimumScaleFactor(0.85)

                                        Spacer(minLength: 2)

                                        if isPending {
                                            Text("APLICAR")
                                                .font(.system(size: 7.5, weight: .black))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 2)
                                                .background(Color.blue, in: Capsule())
                                                .foregroundStyle(.white)
                                        } else if isCurrent {
                                            Text("ATUAL")
                                                .font(.system(size: 7.5, weight: .black))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 2)
                                                .background(Color.blue, in: Capsule())
                                                .foregroundStyle(.white)
                                        } else if isOnScreen {
                                            Text("NA TELA")
                                                .font(.system(size: 7, weight: .bold))
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1.5)
                                                .background(Tema.trilho, in: Capsule())
                                                .foregroundStyle(Tema.textoSuave)
                                        }

                                        Text(pres.compactText)
                                            .font(.system(size: 10.5, weight: .black, design: .rounded))
                                            .foregroundStyle(pres.tint)
                                            .monospacedDigit()
                                            .lineLimit(1)
                                    }

                                    Text(gauge.summaryDescription)
                                        .font(.system(size: 8.5, weight: .medium))
                                        .foregroundStyle(Tema.textoSuave)
                                        .lineLimit(nil)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .multilineTextAlignment(.leading)

                                    Text("\(gauge.pidBadge) • \(gauge.category)")
                                        .font(.system(size: 7.5, weight: .bold))
                                        .foregroundStyle(pres.tint.opacity(0.9))
                                        .lineLimit(1)
                                }
                                .padding(7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    isPending ? Color.blue.opacity(0.24) : (isCurrent ? Color.blue.opacity(0.16) : Tema.cartao),
                                    in: RoundedRectangle(cornerRadius: 9)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9)
                                        .stroke(isPending ? Color.blue : (isCurrent ? Color.blue.opacity(0.6) : Tema.borda),
                                                lineWidth: isPending ? 2 : (isCurrent ? 1.5 : 1))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func tripCounterPill(label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(Tema.textoSuave)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    private func livePrimaryGaugeTile(
        title: String,
        value: String,
        unit: String,
        subtitle: String,
        accent: Color,
        progress: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 9.5, weight: .heavy))
                    .foregroundStyle(Tema.textoSuave)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(unit)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(accent)
                    .lineLimit(1)
            }

            Text(value)
                .font(.system(size: 24, weight: .black, design: .rounded))
                .foregroundStyle(Tema.texto)
                .monospacedDigit()
                .lineLimit(1)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(accent.opacity(0.14))
                    Capsule()
                        .fill(accent)
                        .frame(width: geo.size.width * progress)
                        .animation(.easeOut(duration: 0.2), value: progress)
                }
            }
            .frame(height: 4)

            Text(subtitle)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(Tema.textoSuave)
                .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tema.borda, lineWidth: 1))
    }

    private func miniVitalCard(
        icon: String,
        title: String,
        value: String,
        detail: String,
        tint: Color,
        isAlerting: Bool = false
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isAlerting ? .white : tint)
                .frame(width: 22, height: 22)
                .background((isAlerting ? Color.red : tint.opacity(0.12)), in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(isAlerting ? Color.red : Tema.textoSuave)
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 14, weight: .black, design: .rounded))
                    .foregroundStyle(isAlerting ? Color.red : Tema.texto)
                    .monospacedDigit()
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(isAlerting ? Color.red : tint)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isAlerting ? Color.red.opacity(0.18) : Tema.cartao, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isAlerting ? Color.red : Tema.borda, lineWidth: isAlerting ? 1.6 : 1)
        )
    }
}
