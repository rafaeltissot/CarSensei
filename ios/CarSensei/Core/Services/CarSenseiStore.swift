import Foundation
import Combine

/// Estado central do app. As operações longas ficam em extensões:
/// `CarSenseiStore+Diagnostico`, `CarSenseiStore+Auditoria` e `CarSenseiStore+Lab`.
@MainActor
public final class CarSenseiStore: ObservableObject {
    public static let shared = CarSenseiStore()

    // MARK: - Published State
    @Published public var connectionState: BLEConnectionState = .disconnected
    @Published public var statusBannerText: String = "Pronto para conectar ao Scanner BLE (Recomendado: vLinker MC+)"
    @Published public var discoveredDevices: [DiscoveredBLEDevice] = []
    @Published public var vehicleIdentity = VehicleIdentity()
    @Published public var liveTelemetry = TelemetrySnapshot()
    @Published public var isLivePolling: Bool = false

    // Detecção automática 100% pelo barramento CAN e histórico de veículos conectados
    @Published public var connectedVehiclesHistory: [ConnectedVehicleRecord] = []

    // Cockpit e CarPlay personalizáveis (substituição por toque longo) e perfil de combustível
    @Published public var enabledGauges: [CockpitGaugeID] = CockpitGaugeID.allCases
    @Published public var carPlaySlotGauges: [CockpitGaugeID] = CockpitGaugeID.defaultCarPlaySlots
    @Published public var selectedFuelProfile: FuelTypeProfile = .autoDetected {
        didSet {
            UserDefaults.standard.set(selectedFuelProfile.rawValue, forKey: fuelProfileKey)
        }
    }
    @Published public var tripHistory: [TripRecord] = []
    @Published public var lastBatterySnapshot: BatteryTripSnapshot?

    // Guardião Térmico (CVT e arrefecimento)
    @Published public var activeThermalGuardianBanner: String?

    // Diagnóstico (visão cliente x mecânico)
    @Published public var diagnosticViewMode: DiagnosticViewMode = .customerSimple
    /// Falhas lidas nesta sessão. Começa vazio: o que foi salvo antes fica em `archivedSnapshots`.
    @Published public var activeFaults: [DiagnosticFault] = []
    @Published public var archivedSnapshots: [DiagnosticFault] = []
    @Published public var isScanningDTCs: Bool = false
    @Published public var dtcScanProgressText: String = ""
    /// `true` quando a última varredura não teve resposta de nenhum módulo. Diferente de "0 falhas".
    @Published public var dtcScanNoResponse: Bool = false
    @Published public var lastDTCScanDate: Date?
    @Published public var clearFaultsSafetyError: String?

    // Auditoria de KM
    @Published public var isRunningForensics: Bool = false
    @Published public var forensicsProgressText: String = ""
    @Published public var clusterKmInputText: String = ""
    @Published public var odometerReport: OdometerAuditReport?

    // Teste de bateria na partida
    @Published public var isRunningCrankingTest: Bool = false
    @Published public var lastCrankingTest: CrankingBatteryTest?

    // Registro em memória dos últimos 80 comandos enviados ao carro (só no aparelho)
    @Published public var commandTraceLog: [CommandTraceEntry] = []

    // Análise de Sensores da Viagem em Tempo Real (Aba Viagem)
    @Published public var autoStartTripAnalysis: Bool = true {
        didSet {
            UserDefaults.standard.set(autoStartTripAnalysis, forKey: autoStartTripAnalysisKey)
        }
    }
    @Published public var isAnalyzingTripSensors: Bool = false
    @Published public var tripAnalysisStartDate: Date?
    @Published public var liveTripSensorStats: [CockpitGaugeID: TripSensorLiveStat] = [:]
    @Published public var latestTripAnalysisReport: TripSensorAnalysisReport?
    @Published public var tripAnalysisReportsHistory: [TripSensorAnalysisReport] = []
    /// Estado interno para detectar quando o motor ligou durante a análise e depois desligou para encerrar automaticamente.
    var tripAnalysisHasSeenEngineRunning: Bool = false
    var tripAnalysisEngineOffSince: Date?
    var tripAnalysisStartDistanceKm: Double = 0.0
    var tripAnalysisStartFuelLiters: Double = 0.0

    public let bleManager: BLEConnectionManager
    public let protocolEngine: STNProtocolEngine

    private var cancellables = Set<AnyCancellable>()
    private var telemetryTask: Task<Void, Never>?
    /// Operações longas (varredura, auditoria, Lab) somam 1 enquanto rodam; o loop de telemetria cede o barramento.
    var pausePollingCounter: Int = 0

    let archivedFaultsKey = "carsensei.archived.faults.v1"
    let odometerReportKey = "carsensei.odometer.report.v2"
    let clusterKmSavedKey = "carsensei.cluster.km.v1"
    let tripHistoryKey = "carsensei.trip.history.v1"
    let batterySnapshotKey = "carsensei.battery.snapshot.v1"
    private let enabledGaugesKey = "carsensei.enabled.gauges.v1"
    private let carPlaySlotsKey = "carsensei.carplay.slots.v1"
    private let fuelProfileKey = "carsensei.fuel.profile.v1"
    private let vehicleIdentityKey = "carsensei.vehicle.identity.v1"
    private let vehiclesHistoryKey = "carsensei.vehicles.history.v1"
    let autoStartTripAnalysisKey = "carsensei.tripAnalysis.autoStart.v1"
    let tripAnalysisReportsKey = "carsensei.tripAnalysis.reports.v1"
    private var didRetryVINInSession: Bool = false
    /// Uma captura do hex cru da temperatura do câmbio por sessão (diagnóstico do relato #109).
    private var didLogRawCVTTempOnce: Bool = false
    /// Uma reconexão por sessão depois de handshake sem resposta (evita laço de reconectar para sempre).
    private var didReconnectAfterHandshakeTimeout: Bool = false
    /// Início e máximos da viagem atual (para o histórico de viagens).
    private var tripStartDate: Date?
    private var tripMaxCoolantC: Double?
    private var tripMaxCvtC: Double?

    public init() {
        let ble = BLEConnectionManager()
        self.bleManager = ble
        self.protocolEngine = STNProtocolEngine(bleManager: ble)

        loadPersistedState()
        bindBLECallbacks()
    }

    /// KM digitado pelo usuário ("60.327", "60327", "60327,5"), ou `nil` se inválido.
    public var clusterKmValue: Double? {
        let sanitized = clusterKmInputText
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let km = Double(sanitized), km > 0 else { return nil }
        return km
    }

    func applyDetectedProfile() {
        let detected = VehicleBrandProfile.detect(
            fromVIN: vehicleIdentity.vin,
            ecuName: vehicleIdentity.ecuName,
            calibrationId: vehicleIdentity.calibrationId
        )
        vehicleIdentity.detectedBrandProfile = detected.profile
        vehicleIdentity.modelDescription = detected.modelName
        vehicleIdentity.engineCode = detected.engineDesc
        vehicleIdentity.transmissionCode = detected.transmissionDesc
        vehicleIdentity.displacementLiters = savedDisplacement(for: vehicleIdentity.vin) ?? 1.5
        vehicleIdentity.boostObserved = savedBoostObserved(for: vehicleIdentity.vin)
    }

    // MARK: - Ajustes por carro (guardados pelo VIN)

    /// Cilindrada usada só no cálculo de consumo quando o carro não tem sensor MAF. O usuário informa nos Ajustes.
    public func setDisplacementLiters(_ liters: Double) {
        let clamped = min(8.0, max(0.6, (liters * 10).rounded() / 10))
        vehicleIdentity.displacementLiters = clamped
        perVehicleValues(displacementKey, set: clamped)
        saveVehicleIdentity()
    }

    private let displacementKey = "carsensei.displacement.by.vin.v1"
    private let boostKey = "carsensei.boost.by.vin.v1"

    private func vehicleKey(_ vin: String) -> String {
        OBDUDSParser.normalizedVIN(vin) ?? "sem-vin"
    }

    private func savedDisplacement(for vin: String) -> Double? {
        (UserDefaults.standard.dictionary(forKey: displacementKey) as? [String: Double])?[vehicleKey(vin)]
    }

    private func savedBoostObserved(for vin: String) -> Bool {
        (UserDefaults.standard.dictionary(forKey: boostKey) as? [String: Bool])?[vehicleKey(vin)] ?? false
    }

    private func perVehicleValues<T>(_ key: String, set value: T) {
        var dict = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        dict[vehicleKey(vehicleIdentity.vin)] = value
        UserDefaults.standard.set(dict, forKey: key)
    }

    /// Turbo: o coletor só passa da pressão atmosférica com sobrealimentação.
    private func updateBoostObservation() {
        guard !vehicleIdentity.boostObserved, let map = liveTelemetry.mapKpa else { return }
        let baro = liveTelemetry.barometricPressureKpa ?? 101.0
        if map > baro + 10 {
            vehicleIdentity.boostObserved = true
            perVehicleValues(boostKey, set: true)
            saveVehicleIdentity()
        }
    }

    /// Registra ou atualiza automaticamente o veículo detectado no histórico de veículos conectados.
    func recordConnectedVehicleInHistory(odometerKm: Double? = nil) {
        let cleanVIN = OBDUDSParser.normalizedVIN(vehicleIdentity.vin) ?? vehicleIdentity.vin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanVIN.count == 17 || (!vehicleIdentity.calibrationId.contains("Aguardando") && !vehicleIdentity.calibrationId.isEmpty) else {
            return
        }
        let recordID = cleanVIN.count == 17 ? cleanVIN : vehicleIdentity.calibrationId
        let knownKm = odometerKm ?? liveTelemetry.tcuOdometerKm ?? odometerReport?.highestRecordedKmAcrossECUs ?? clusterKmValue

        let record = ConnectedVehicleRecord(
            id: recordID,
            vin: cleanVIN,
            modelDescription: vehicleIdentity.modelDescription,
            engineCode: vehicleIdentity.engineCode,
            transmissionCode: vehicleIdentity.transmissionCode,
            ecuName: vehicleIdentity.ecuName,
            calibrationId: vehicleIdentity.calibrationId,
            lastConnectedAt: Date(),
            lastKnownOdometerKm: knownKm
        )

        if let idx = connectedVehiclesHistory.firstIndex(where: { $0.id == recordID }) {
            var existing = connectedVehiclesHistory[idx]
            existing.vin = record.vin
            existing.modelDescription = record.modelDescription
            existing.engineCode = record.engineCode
            existing.transmissionCode = record.transmissionCode
            if !record.ecuName.contains("Aguardando") { existing.ecuName = record.ecuName }
            if !record.calibrationId.contains("Aguardando") { existing.calibrationId = record.calibrationId }
            existing.lastConnectedAt = Date()
            if let km = knownKm { existing.lastKnownOdometerKm = km }
            connectedVehiclesHistory.remove(at: idx)
            connectedVehiclesHistory.insert(existing, at: 0)
        } else {
            connectedVehiclesHistory.insert(record, at: 0)
        }

        if let data = try? JSONEncoder().encode(connectedVehiclesHistory) {
            UserDefaults.standard.set(data, forKey: vehiclesHistoryKey)
        }
    }

    /// Exclui veículos selecionados do histórico e suas falhas arquivadas associadas.
    public func deleteConnectedVehicles(at offsets: IndexSet) {
        let removedVINs = offsets.compactMap { idx -> String? in
            guard connectedVehiclesHistory.indices.contains(idx) else { return nil }
            return connectedVehiclesHistory[idx].vin
        }
        connectedVehiclesHistory.remove(atOffsets: offsets)
        if let data = try? JSONEncoder().encode(connectedVehiclesHistory) {
            UserDefaults.standard.set(data, forKey: vehiclesHistoryKey)
        }
        if !removedVINs.isEmpty {
            archivedSnapshots.removeAll { fault in
                guard let fVin = fault.vehicleVIN else { return false }
                return removedVINs.contains(fVin)
            }
            if let data = try? JSONEncoder().encode(archivedSnapshots) {
                UserDefaults.standard.set(data, forKey: archivedFaultsKey)
            }
        }
    }

    /// Limpa completamente o histórico de veículos conectados e falhas de outros veículos.
    public func clearConnectedVehiclesHistory() {
        connectedVehiclesHistory.removeAll()
        UserDefaults.standard.removeObject(forKey: vehiclesHistoryKey)
        clearOtherVehiclesArchivedFaults()
    }

    // MARK: - Gauge Customization

    public func isGaugeEnabled(_ id: CockpitGaugeID) -> Bool {
        enabledGauges.contains(id)
    }

    public func toggleGauge(_ id: CockpitGaugeID) {
        if let idx = enabledGauges.firstIndex(of: id) {
            guard enabledGauges.count > 2 else { return }
            enabledGauges.remove(at: idx)
        } else {
            let all = CockpitGaugeID.allCases
            enabledGauges = all.filter { $0 == id || enabledGauges.contains($0) }
        }
        saveGaugePreferences()
    }

    public func enableAllGauges() {
        enabledGauges = CockpitGaugeID.allCases
        saveGaugePreferences()
    }

    /// Substitui um mostrador do Cockpit do iPhone por outro mantendo a posição exata no grid.
    public func replaceCockpitGauge(_ oldGauge: CockpitGaugeID, with newGauge: CockpitGaugeID) {
        guard oldGauge != newGauge else { return }
        if let oldIdx = enabledGauges.firstIndex(of: oldGauge) {
            if let existingNewIdx = enabledGauges.firstIndex(of: newGauge) {
                enabledGauges.swapAt(oldIdx, existingNewIdx)
            } else {
                enabledGauges[oldIdx] = newGauge
            }
        } else if !enabledGauges.contains(newGauge) {
            enabledGauges.insert(newGauge, at: 0)
        }
        saveGaugePreferences()
    }

    /// Substitui um slot específico (0..21) da tela do CarPlay por outro sensor (trocando de lugar caso já esteja em outro slot).
    public func replaceCarPlaySlot(at index: Int, with newGauge: CockpitGaugeID) {
        while carPlaySlotGauges.count < CockpitGaugeID.defaultCarPlaySlots.count {
            carPlaySlotGauges.append(CockpitGaugeID.defaultCarPlaySlots[carPlaySlotGauges.count])
        }
        guard carPlaySlotGauges.indices.contains(index) else { return }
        if let otherIdx = carPlaySlotGauges.firstIndex(of: newGauge), otherIdx != index {
            carPlaySlotGauges.swapAt(index, otherIdx)
        } else {
            carPlaySlotGauges[index] = newGauge
        }
        saveCarPlaySlotPreferences()
    }

    public func resetCarPlaySlotsToDefault() {
        carPlaySlotGauges = CockpitGaugeID.defaultCarPlaySlots
        saveCarPlaySlotPreferences()
    }

    public func resetTripFuelCounters() {
        recordCurrentTripToHistory()
        liveTelemetry.sessionDistanceKm = 0.0
        liveTelemetry.sessionFuelLiters = 0.0
    }

    public func recordCurrentTripToHistory() {
        let dist = liveTelemetry.sessionDistanceKm
        let fuel = liveTelemetry.sessionFuelLiters
        defer {
            tripStartDate = nil
            tripMaxCoolantC = nil
            tripMaxCvtC = nil
        }
        guard dist >= 0.05 && fuel > 0.005 else { return }
        let avgKml = dist / fuel
        let start = tripStartDate ?? Date()
        let duration = Date().timeIntervalSince(start)
        let record = TripRecord(
            startDate: start,
            endDate: Date(),
            distanceKm: dist,
            fuelLiters: fuel,
            avgKmPerLiter: avgKml,
            fuelProfile: selectedFuelProfile,
            durationSeconds: duration,
            avgSpeedKmh: duration > 60 ? dist / (duration / 3600) : nil,
            maxCoolantTempC: tripMaxCoolantC,
            maxCvtTempC: tripMaxCvtC
        )
        tripHistory.insert(record, at: 0)
        if tripHistory.count > 30 { tripHistory.removeLast(tripHistory.count - 30) }
        if let data = try? JSONEncoder().encode(tripHistory) {
            UserDefaults.standard.set(data, forKey: tripHistoryKey)
        }

        if let v = liveTelemetry.batteryVoltage {
            let snap = BatteryTripSnapshot(
                recordedAt: Date(),
                initialRestVoltage: lastBatterySnapshot?.initialRestVoltage ?? v,
                finalVoltage: v,
                minCrankingVoltage: lastCrankingTest?.minCrankingVoltage,
                socPercent: liveTelemetry.batteryHealthAssessment.socPercent,
                healthTitle: liveTelemetry.batteryHealthAssessment.stateTitle
            )
            lastBatterySnapshot = snap
            if let data = try? JSONEncoder().encode(snap) {
                UserDefaults.standard.set(data, forKey: batterySnapshotKey)
            }
        }
    }

    private func saveGaugePreferences() {
        if let data = try? JSONEncoder().encode(enabledGauges) {
            UserDefaults.standard.set(data, forKey: enabledGaugesKey)
        }
    }

    private func saveCarPlaySlotPreferences() {
        let rawValues = carPlaySlotGauges.map(\.rawValue)
        if let data = try? JSONEncoder().encode(rawValues) {
            UserDefaults.standard.set(data, forKey: carPlaySlotsKey)
        }
    }

    private func bindBLECallbacks() {
        bleManager.$connectionState
            .receive(on: RunLoop.main)
            .sink { [weak self] newState in
                guard let self = self else { return }
                if newState != .initializingProtocol {
                    self.connectionState = newState
                }
                if newState != .initializingProtocol && newState != .connectedReady {
                    self.stopTelemetryLoop()
                }
            }
            .store(in: &cancellables)

        bleManager.$statusDetail
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                self?.statusBannerText = text
            }
            .store(in: &cancellables)

        bleManager.$discoveredDevices
            .receive(on: RunLoop.main)
            .sink { [weak self] list in
                self?.discoveredDevices = list
            }
            .store(in: &cancellables)

        bleManager.onAdapterTransportReady = { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                await self.initializeVehicleSession()
            }
        }
    }

    // MARK: - Connection & Universal Auto-Detection Handshake

    /// Ler o carro é a ação principal: depois do teste grátis sem plano, abre a tela de planos.
    /// Falhas, laudos e histórico salvos continuam visíveis.
    private func requireAccess() -> Bool {
        guard Loja.compartilhada.podeUsar else {
            Loja.compartilhada.pedirPlanos = true
            statusBannerText = "Seu teste grátis terminou. Escolha um plano para continuar lendo o carro."
            return false
        }
        return true
    }

    public func startAutoConnect() {
        guard requireAccess() else { return }
        TissotFeedback.log("BLE_SCAN_START")
        bleManager.startScanning(autoConnectPreferred: true)
    }

    /// Busca para o usuário escolher o adaptador na lista (sem conectar sozinho).
    public func startManualScan() {
        guard requireAccess() else { return }
        bleManager.startScanning(autoConnectPreferred: false)
    }

    public func connectToDevice(_ id: UUID) {
        guard requireAccess() else { return }
        bleManager.connect(to: id)
    }

    public func disconnect() {
        stopTelemetryLoop()
        bleManager.disconnect()
    }

    private func initializeVehicleSession() async {
        guard requireAccess() else {
            bleManager.disconnect()
            return
        }
        connectionState = .initializingProtocol
        statusBannerText = "Detectando scanner (vLinker MC+ / OBD-II) e veículo conectado..."

        do {
            let handshake: (firmware: String, tier: AdapterCapabilityTier, protocolName: String)
            do {
                handshake = try await protocolEngine.initializeMultiVehicleCANProfile(
                    connectedBLEDeviceName: bleManager.connectedDeviceName
                )
            } catch let firstError as NSError where firstError.domain == "CarSensei.BLE" && firstError.code == -3 && bleManager.connectionState == .initializingProtocol {
                // Se o chip STN2120 estava em BatterySaver profundo e demorou no primeiro comando, aguarda 400ms e tenta uma segunda vez antes de desistir
                try? await Task.sleep(nanoseconds: 400_000_000)
                handshake = try await protocolEngine.initializeMultiVehicleCANProfile(
                    connectedBLEDeviceName: bleManager.connectedDeviceName
                )
            }

            vehicleIdentity.adapterFirmware = handshake.firmware
            vehicleIdentity.adapterTier = handshake.tier
            vehicleIdentity.obdProtocol = handshake.protocolName
            didRetryVINInSession = false

            await readVehicleIdentifiersFromCAN()

            TissotFeedback.log("VEHICLE_CONNECTED", [
                "model": vehicleIdentity.modelDescription,
                "adapterTier": vehicleIdentity.adapterTier.rawValue,
                "protocol": vehicleIdentity.obdProtocol
            ])

            didReconnectAfterHandshakeTimeout = false
            connectionState = .connectedReady
            statusBannerText = "Conectado: \(vehicleIdentity.cleanModelTitle) • \(vehicleIdentity.adapterTier.isAdvancedVLinker ? "vLinker MC+ PRO" : "Modo Básico OBD")"
            startTelemetryLoop()
        } catch is CancellationError {
            return
        } catch {
            let nsError = error as NSError
            let isTransientDisconnect = (nsError.domain == "CarSensei.BLE" && (nsError.code == -1 || nsError.code == -3 || nsError.code == -4))
                || bleManager.connectionState != .initializingProtocol
            if isTransientDisconnect {
                TissotFeedback.log("BLE_SESSION_ABORTED", [
                    "code": nsError.code,
                    "reason": error.localizedDescription
                ])
                // Estourou tempo com o adaptador ainda conectado: ele saiu do sono fundo e ficou mudo.
                // Em vez de parar em erro, derruba e refaz o link — o transporte volta e o handshake roda de novo.
                if nsError.code == -3,
                   bleManager.connectionState == .initializingProtocol,
                   !didReconnectAfterHandshakeTimeout {
                    didReconnectAfterHandshakeTimeout = true
                    statusBannerText = "Adaptador sem resposta. Reconectando para concluir a inicialização..."
                    bleManager.reconnectActivePeripheral()
                    return
                }
                if bleManager.connectionState != .connectedReady && bleManager.connectionState != .initializingProtocol {
                    connectionState = .disconnected
                    statusBannerText = "Scanner desconectado. Aproxime-se do veículo com a ignição ligada."
                } else {
                    connectionState = .error
                    statusBannerText = "Scanner em espera ou fora de alcance: reconecte com a ignição ligada."
                }
            } else {
                TissotFeedback.error(error, context: "initializeVehicleSession")
                connectionState = .error
                statusBannerText = "Erro na inicialização CAN: \(error.localizedDescription)"
            }
        }
    }

    /// Lê VIN (22 F1 90 / 09 02), calibração (09 04) e nome da ECU (09 0A) automaticamente e salva no histórico.
    func readVehicleIdentifiersFromCAN() async {
        let previousVIN = OBDUDSParser.normalizedVIN(vehicleIdentity.vin)

        if let (udsVin, msUds) = try? await protocolEngine.execute("22 F1 90", target: .ecm, timeout: 2.0),
           let parsedVin = OBDUDSParser.parseVIN(udsVin) {
            vehicleIdentity.vin = parsedVin
            logTrace(command: "22 F1 90 (VIN ECM)", response: udsVin, durationMs: msUds)
        } else if let (vinResp, ms1) = try? await protocolEngine.execute("09 02", target: .ecm, timeout: 2.2),
                  let parsedVin = OBDUDSParser.parseVIN(vinResp) ?? OBDUDSParser.parseASCIIIdentifier(vinResp) {
            vehicleIdentity.vin = parsedVin
            logTrace(command: "09 02 (VIN)", response: vinResp, durationMs: ms1)
        } else if let (tcuVin, msTcu) = try? await protocolEngine.execute("22 F1 90", target: .tcu, timeout: 1.8),
                  let parsedVin = OBDUDSParser.parseVIN(tcuVin) {
            vehicleIdentity.vin = parsedVin
            logTrace(command: "22 F1 90 (VIN TCU)", response: tcuVin, durationMs: msTcu)
        }

        if let (calResp, ms2) = try? await protocolEngine.execute("09 04", target: .ecm, timeout: 1.8),
           let parsedCal = OBDUDSParser.parseASCIIIdentifier(calResp) {
            vehicleIdentity.calibrationId = parsedCal
            logTrace(command: "09 04 (Calib)", response: calResp, durationMs: ms2)
        }
        if let (nameResp, ms3) = try? await protocolEngine.execute("09 0A", target: .ecm, timeout: 1.8),
           let parsedName = OBDUDSParser.parseASCIIIdentifier(nameResp) {
            vehicleIdentity.ecuName = parsedName
            logTrace(command: "09 0A (ECU)", response: nameResp, durationMs: ms3)
        }

        // Descoberta dinâmica dos PIDs suportados fisicamente pela ECU do carro (bitmasks SAE J1979 01 00, 01 20, 01 40) e tipo de combustível (01 51)
        var discoveredPIDs = Set<Int>()
        for (cmd, basePID) in [("01 00", 0x00), ("01 20", 0x20), ("01 40", 0x40)] {
            if let (maskResp, msMask) = try? await protocolEngine.execute(cmd, target: .broadcast, timeout: 1.4) {
                let pids = OBDUDSParser.parseSupportedPIDsBitmask(maskResp, basePID: basePID)
                if !pids.isEmpty {
                    discoveredPIDs.formUnion(pids)
                    logTrace(command: "\(cmd) (PIDs Suportados)", response: maskResp, durationMs: msMask)
                }
            }
        }
        if !discoveredPIDs.isEmpty {
            vehicleIdentity.supportedMode01PIDs = discoveredPIDs.sorted()
        }
        if let (fuelTypeResp, _) = try? await protocolEngine.execute("01 51", target: .broadcast, timeout: 1.2),
           let fuelTypeStr = OBDUDSParser.parseECUFuelType(fuelTypeResp) {
            vehicleIdentity.ecuReportedFuelType = fuelTypeStr
        }

        let currentVIN = OBDUDSParser.normalizedVIN(vehicleIdentity.vin)
        if let prev = previousVIN, let curr = currentVIN, prev != curr {
            // Trocou de veículo: limpa leituras de sessão do carro anterior para nunca misturar dados entre veículos
            activeFaults = []
            lastDTCScanDate = nil
        }

        applyDetectedProfile()
        saveVehicleIdentity()
        recordConnectedVehicleInHistory()
    }

    // MARK: - Telemetria ao vivo + Guardião Térmico

    public func startTelemetryLoop() {
        guard telemetryTask == nil, connectionState == .connectedReady else { return }
        isLivePolling = true

        telemetryTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            var cycleCounter = 0
            var lastSampleDate = Date()

            while !Task.isCancelled && self.connectionState == .connectedReady {
                if self.pausePollingCounter > 0 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    lastSampleDate = Date()
                    continue
                }

                let cycleStart = Date()
                do {
                    // 1. Pedido multi-PID do modo 01 (até 6 PIDs por quadro CAN)
                    let (fastResp, _) = try await self.protocolEngine.execute("01 05 0C 0D 0B 0F 06", target: .broadcast, timeout: 1.8)
                    OBDUDSParser.parseMode01Response(fastResp, into: &self.liveTelemetry)

                    // Se algum sensor crítico não veio no multi-PID (comum em ECUs que só retornam 1 PID por quadro), consulta individualmente:
                    if self.liveTelemetry.intakeAirTempC == nil || self.liveTelemetry.rpm == nil || self.liveTelemetry.coolantTempC == nil {
                        for pidCmd in ["01 0C", "01 0D", "01 05", "01 0B", "01 0F", "01 06"] {
                            if let (r, _) = try? await self.protocolEngine.execute(pidCmd, target: .broadcast, timeout: 0.9) {
                                OBDUDSParser.parseMode01Response(r, into: &self.liveTelemetry)
                            }
                        }
                    }

                    // 2. Tensão, trims, carga, temperatura externa e etanol (PID 01 52) a cada 3 ciclos
                    if cycleCounter % 3 == 0 {
                        if let (voltResp, _) = try? await self.protocolEngine.execute("AT RV", timeout: 1.1),
                           let volts = OBDUDSParser.parseBatteryVoltage(voltResp) {
                            self.liveTelemetry.batteryVoltage = volts
                        }
                        if let (secResp, _) = try? await self.protocolEngine.execute("01 07 04 11 46 52", target: .broadcast, timeout: 1.5) {
                            OBDUDSParser.parseMode01Response(secResp, into: &self.liveTelemetry)
                        }
                        if self.liveTelemetry.ambientTempC == nil,
                           let (ambResp, _) = try? await self.protocolEngine.execute("01 46", target: .broadcast, timeout: 1.1) {
                            OBDUDSParser.parseMode01Response(ambResp, into: &self.liveTelemetry)
                        }
                        if self.liveTelemetry.intakeAirTempC == nil,
                           let (iatResp, _) = try? await self.protocolEngine.execute("01 0F", target: .broadcast, timeout: 1.0) {
                            OBDUDSParser.parseMode01Response(iatResp, into: &self.liveTelemetry)
                        }
                    }

                    // 2.1 Sensores estendidos rotativos (varre todos os 42 sensores CAN/OBD-II sem pesar na taxa de quadros)
                    switch cycleCounter % 4 {
                    case 0:
                        if let (auxResp, _) = try? await self.protocolEngine.execute("01 0E 1F 2F 31 33 14", target: .broadcast, timeout: 1.4) {
                            OBDUDSParser.parseMode01Response(auxResp, into: &self.liveTelemetry)
                        }
                    case 1:
                        if let (ext1Resp, _) = try? await self.protocolEngine.execute("01 10 15 3C 42 43 44", target: .broadcast, timeout: 1.4) {
                            OBDUDSParser.parseMode01Response(ext1Resp, into: &self.liveTelemetry)
                        }
                    case 2:
                        if let (ext2Resp, _) = try? await self.protocolEngine.execute("01 45 49 4A 4C 5C 2E", target: .broadcast, timeout: 1.4) {
                            OBDUDSParser.parseMode01Response(ext2Resp, into: &self.liveTelemetry)
                        }
                    default:
                        if let (ext3Resp, _) = try? await self.protocolEngine.execute("01 21 22 23 30 4D 4E", target: .broadcast, timeout: 1.4) {
                            OBDUDSParser.parseMode01Response(ext3Resp, into: &self.liveTelemetry)
                        }
                    }

                    // 2.2 Fallback individual rotativo para sensores visíveis ou em análise da viagem (caso a ECU rejeite quadros multi-PID estendidos)
                    let baseGauges: [CockpitGaugeID] = self.isAnalyzingTripSensors
                        ? self.dynamicallySupportedGaugesForCurrentVehicle
                        : Array(Set(self.carPlaySlotGauges + self.enabledGauges.prefix(8)))
                    let activeGaugesToPoll = baseGauges.compactMap(\.singlePIDCommand)
                    if !activeGaugesToPoll.isEmpty {
                        let singleCmd = activeGaugesToPoll[cycleCounter % activeGaugesToPoll.count]
                        if let (singleResp, _) = try? await self.protocolEngine.execute(singleCmd, target: .broadcast, timeout: 0.9) {
                            OBDUDSParser.parseMode01Response(singleResp, into: &self.liveTelemetry)
                        }
                    }

                    // Se conectou com a ignição desligada e agora o motor/ignição acordou, lê o VIN automaticamente
                    if !self.didRetryVINInSession,
                       (self.liveTelemetry.rpm != nil || self.liveTelemetry.coolantTempC != nil),
                       OBDUDSParser.normalizedVIN(self.vehicleIdentity.vin) == nil {
                        self.didRetryVINInSession = true
                        await self.readVehicleIdentifiersFromCAN()
                        self.statusBannerText = "Conectado: \(self.vehicleIdentity.modelDescription) • vLinker MC+ PRO"
                    }

                    // 3. vLinker MC+: TCU (temperatura e odômetro do CVT) a cada 5 ciclos
                    if cycleCounter % 5 == 0 && self.vehicleIdentity.adapterTier.isAdvancedVLinker {
                        if let (cvtResp, _) = try? await self.protocolEngine.execute("22 0B 37", target: .tcu, timeout: 1.2) {
                            // Uma captura por sessão: sem o hex cru não dá para provar se o byte é o do fluido
                            // e se o offset é -40 (relato #109). Vai no próximo relato enviado.
                            if !self.didLogRawCVTTempOnce {
                                self.didLogRawCVTTempOnce = true
                                let hex = OBDUDSParser.extractPayloadBytes(from: cvtResp).map { String(format: "%02X", $0) }.joined(separator: " ")
                                TissotFeedback.log("TCU_TEMP_RAW", [
                                    "hex": hex,
                                    "parsed_c": OBDUDSParser.parseTCUFluidTempC(cvtResp).map { String(format: "%.0f", $0) } ?? "nil",
                                    "coolant_c": self.liveTelemetry.coolantTempC.map { String(format: "%.0f", $0) } ?? "nil"
                                ])
                            }
                            if let cvtC = OBDUDSParser.parseTCUFluidTempC(cvtResp) {
                                // Sanidade física: com o motor frio o fluido do câmbio não pode estar muito acima
                                // do arrefecimento — se estiver, a decodificação está errada e não pode virar alarme.
                                if let coolant = self.liveTelemetry.coolantTempC, coolant < 45, cvtC > coolant + 25 {
                                    self.liveTelemetry.transmissionTempC = nil
                                    self.liveTelemetry.transmissionTempSuspect = true
                                } else {
                                    self.liveTelemetry.transmissionTempC = cvtC
                                    self.liveTelemetry.transmissionTempSuspect = false
                                }
                            }
                        }
                        if let (tcuOdoResp, _) = try? await self.protocolEngine.execute("22 0B 5B", target: .tcu, timeout: 1.2),
                           let tcuKm = OBDUDSParser.parseTCUOdometerKm(tcuOdoResp) {
                            self.liveTelemetry.tcuOdometerKm = tcuKm
                            self.recordConnectedVehicleInHistory(odometerKm: tcuKm)
                        }
                    }

                    // 4. Fluxo de combustível (L/h) e consumo instantâneo/da sessão (km/L)
                    let now = Date()
                    let dt = now.timeIntervalSince(lastSampleDate)
                    lastSampleDate = now
                    OBDUDSParser.updateFuelConsumption(
                        in: &self.liveTelemetry,
                        fuelProfile: self.selectedFuelProfile,
                        displacementLiters: self.vehicleIdentity.displacementLiters,
                        elapsedSeconds: dt
                    )

                    // Viagem: começa no primeiro movimento e guarda as temperaturas máximas
                    if self.tripStartDate == nil, (self.liveTelemetry.speedKmh ?? 0) > 0 {
                        self.tripStartDate = now
                    }
                    if let c = self.liveTelemetry.coolantTempC { self.tripMaxCoolantC = max(self.tripMaxCoolantC ?? c, c) }
                    if let c = self.liveTelemetry.transmissionTempC { self.tripMaxCvtC = max(self.tripMaxCvtC ?? c, c) }

                    self.updateBoostObservation()

                    // 5. Guardião Térmico (CVT e arrefecimento) + Análise em Tempo Real da Viagem
                    self.evaluateThermalGuardian()
                    self.processTripSensorAnalysisTick(now: now)

                    cycleCounter += 1
                    let elapsed = now.timeIntervalSince(cycleStart)
                    self.liveTelemetry.pollRateHz = elapsed > 0 ? (1.0 / elapsed) : 1.0
                    self.liveTelemetry.timestamp = now
                } catch {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                // Sem pausa entre ciclos: com o iPhone bloqueado, o app só continua acordado
                // enquanto houver resposta BLE pendente (modo de fundo bluetooth-central).
            }
            self.isLivePolling = false
        }
    }

    public func stopTelemetryLoop() {
        if isAnalyzingTripSensors && !liveTripSensorStats.isEmpty {
            finalizeTripSensorAnalysis(reason: "Carro desligado / Scanner desconectado ao final do trajeto")
        }
        recordCurrentTripToHistory()
        telemetryTask?.cancel()
        telemetryTask = nil
        isLivePolling = false
    }

    private func evaluateThermalGuardian() {
        let cvtC = liveTelemetry.transmissionTempC ?? 0
        let coolantC = liveTelemetry.coolantTempC ?? 0
        let thresholds = vehicleIdentity.thermalThresholds

        if cvtC >= thresholds.transmission.criticalDTCThresholdC {
            activeThermalGuardianBanner = String(format: "Alerta Crítico: Fluido %@ em %.0f°C (≥%.0f°C). Risco de DTC P0218. Reduza o esforço do veículo.", thresholds.transmission.transmissionName, cvtC, thresholds.transmission.criticalDTCThresholdC)
        } else if cvtC >= thresholds.transmission.thermalInterventionC {
            activeThermalGuardianBanner = String(format: "Atenção Térmica: Fluido %@ em %.0f°C (≥%.0f°C). A TCU atua no conversor de torque. Alivie acelerações.", thresholds.transmission.transmissionName, cvtC, thresholds.transmission.thermalInterventionC)
        } else if coolantC >= thresholds.coolant.criticalDTCThresholdC {
            activeThermalGuardianBanner = String(format: "Perigo de Superaquecimento: Arrefecimento do motor em %.0f°C (≥%.0f°C). Pare o carro em local seguro.", coolantC, thresholds.coolant.criticalDTCThresholdC)
        } else if coolantC >= thresholds.coolant.warningThresholdC {
            activeThermalGuardianBanner = String(format: "Atenção: Arrefecimento em %.0f°C (≥%.0f°C). Ventoinha trabalhando no máximo.", coolantC, thresholds.coolant.warningThresholdC)
        } else {
            activeThermalGuardianBanner = nil
        }
    }

    // MARK: - Persistência

    func logTrace(command: String, response: String, durationMs: Int) {
        let entry = CommandTraceEntry(command: command, response: response, durationMs: durationMs)
        commandTraceLog.insert(entry, at: 0)
        if commandTraceLog.count > 80 {
            commandTraceLog.removeLast(commandTraceLog.count - 80)
        }
    }

    private func saveVehicleIdentity() {
        if let data = try? JSONEncoder().encode(vehicleIdentity) {
            UserDefaults.standard.set(data, forKey: vehicleIdentityKey)
        }
    }

    /// Histórico de falhas pertencentes exclusivamente ao veículo atual (filtrado por VIN quando identificado).
    public var archivedFaultsForCurrentVehicle: [DiagnosticFault] {
        guard let currentVIN = OBDUDSParser.normalizedVIN(vehicleIdentity.vin) else {
            return archivedSnapshots
        }
        return archivedSnapshots.filter { fault in
            guard let fVin = fault.vehicleVIN, !fVin.isEmpty else {
                return false
            }
            return fVin == currentVIN
        }
    }

    /// Falhas salvas de outros veículos ou de leituras antigas sem identificação de VIN.
    public var archivedFaultsForOtherVehicles: [DiagnosticFault] {
        guard let currentVIN = OBDUDSParser.normalizedVIN(vehicleIdentity.vin) else {
            return []
        }
        return archivedSnapshots.filter { fault in
            guard let fVin = fault.vehicleVIN, !fVin.isEmpty else {
                return true
            }
            return fVin != currentVIN
        }
    }

    /// Remove do arquivo apenas as falhas de outros veículos / leituras antigas sem VIN, preservando o carro atual,
    /// e sincroniza o histórico de veículos para que nada de outros veículos permaneça.
    public func clearOtherVehiclesArchivedFaults() {
        let currentVIN = OBDUDSParser.normalizedVIN(vehicleIdentity.vin)
        archivedSnapshots = archivedFaultsForCurrentVehicle
        if let data = try? JSONEncoder().encode(archivedSnapshots) {
            UserDefaults.standard.set(data, forKey: archivedFaultsKey)
        }
        if let currentVIN {
            connectedVehiclesHistory.removeAll(where: { $0.vin != currentVIN })
        } else {
            connectedVehiclesHistory.removeAll()
        }
        if let data = try? JSONEncoder().encode(connectedVehiclesHistory) {
            UserDefaults.standard.set(data, forKey: vehiclesHistoryKey)
        }
    }

    func archiveDiscoveredFaults(_ faults: [DiagnosticFault]) {
        guard !faults.isEmpty else { return }
        let currentVIN = OBDUDSParser.normalizedVIN(vehicleIdentity.vin)
        let currentModel = vehicleIdentity.cleanModelTitle
        for var f in faults {
            if f.vehicleVIN == nil { f.vehicleVIN = currentVIN }
            if f.vehicleModel == nil { f.vehicleModel = currentModel }
            if let existingIdx = archivedSnapshots.firstIndex(where: { $0.id == f.id }) {
                archivedSnapshots[existingIdx] = f
            } else {
                archivedSnapshots.insert(f, at: 0)
            }
        }
        if let data = try? JSONEncoder().encode(archivedSnapshots) {
            UserDefaults.standard.set(data, forKey: archivedFaultsKey)
        }
    }

    func saveOdometerReport(_ report: OdometerAuditReport) {
        if let data = try? JSONEncoder().encode(report) {
            UserDefaults.standard.set(data, forKey: odometerReportKey)
        }
    }

    private func loadPersistedState() {
        // Preferências de mostradores: lê como texto e descarta só os gauges que não existem mais,
        // em vez de voltar para "todos" quando um caso é renomeado.
        if let savedGaugesData = UserDefaults.standard.data(forKey: enabledGaugesKey),
           let decodedGauges = try? JSONDecoder().decode([String].self, from: savedGaugesData) {
            var validos = decodedGauges.compactMap { CockpitGaugeID(rawValue: $0) }
            if validos.count >= 18 {
                for g in CockpitGaugeID.allCases where !validos.contains(g) {
                    validos.append(g)
                }
            }
            if !validos.isEmpty { enabledGauges = validos }
        }

        if let savedCarPlayData = UserDefaults.standard.data(forKey: carPlaySlotsKey),
           let decodedCarPlay = try? JSONDecoder().decode([String].self, from: savedCarPlayData) {
            var validSlots = decodedCarPlay.compactMap { CockpitGaugeID(rawValue: $0) }
            while validSlots.count < CockpitGaugeID.defaultCarPlaySlots.count {
                let fallback = CockpitGaugeID.defaultCarPlaySlots[validSlots.count]
                validSlots.append(fallback)
            }
            carPlaySlotGauges = Array(validSlots.prefix(CockpitGaugeID.defaultCarPlaySlots.count))
        }

        if let savedFuelRaw = UserDefaults.standard.string(forKey: fuelProfileKey),
           let profile = FuelTypeProfile(rawValue: savedFuelRaw) {
            selectedFuelProfile = profile
        }



        if let savedIdentityData = UserDefaults.standard.data(forKey: vehicleIdentityKey),
           let decodedIdentity = try? JSONDecoder().decode(VehicleIdentity.self, from: savedIdentityData) {
            vehicleIdentity = decodedIdentity
        }

        if let savedKm = UserDefaults.standard.string(forKey: clusterKmSavedKey) {
            clusterKmInputText = savedKm
        }

        if let savedTrips = UserDefaults.standard.data(forKey: tripHistoryKey),
           let decodedTrips = try? JSONDecoder().decode([DecodificavelTolerante<TripRecord>].self, from: savedTrips) {
            tripHistory = decodedTrips.compactMap { $0.valor }
        }

        if let savedBatSnap = UserDefaults.standard.data(forKey: batterySnapshotKey),
           let decodedSnap = try? JSONDecoder().decode(BatteryTripSnapshot.self, from: savedBatSnap) {
            lastBatterySnapshot = decodedSnap
        }

        // Histórico de falhas: reinterpreta com a base de conhecimento atual (visão cliente + mecânico).
        if let data = UserDefaults.standard.data(forKey: archivedFaultsKey),
           let decoded = try? JSONDecoder().decode([DecodificavelTolerante<DiagnosticFault>].self, from: data) {
            archivedSnapshots = decoded.compactMap { $0.valor }.compactMap { fault -> DiagnosticFault? in
                if let maskHex = fault.statusMaskHex,
                   let statusByte = UInt8(maskHex, radix: 16),
                   (statusByte & 0x0D) == 0 {
                    return nil
                }
                let refreshedInterp = SenseiKnowledgeBase.interpretFault(
                    baseCode: fault.baseCode,
                    ftbHex: fault.failureTypeByteHex,
                    moduleCode: fault.moduleCode,
                    isActiveNow: fault.isActiveNow,
                    brandProfile: vehicleIdentity.detectedBrandProfile
                )
                var updated = DiagnosticFault(
                    baseCode: fault.baseCode,
                    failureTypeByteHex: fault.failureTypeByteHex,
                    failureTypeDescription: fault.failureTypeDescription,
                    moduleCode: fault.moduleCode,
                    moduleName: fault.moduleName,
                    statusMaskHex: fault.statusMaskHex,
                    isActiveNow: fault.isActiveNow,
                    isConfirmed: fault.isConfirmed,
                    failedSinceLastClear: fault.failedSinceLastClear,
                    notCompletedThisCycle: fault.notCompletedThisCycle,
                    rawDTCBytesHex: fault.rawDTCBytesHex,
                    interpretation: refreshedInterp,
                    freezeFrame: fault.freezeFrame,
                    vehicleVIN: fault.vehicleVIN,
                    vehicleModel: fault.vehicleModel
                )
                if let rawHex = updated.freezeFrame?.rawUDSHex {
                    let occurrences = OBDUDSParser.parseUDSSnapshotOccurrences(rawHex)
                    if !occurrences.isEmpty {
                        updated.freezeFrame?.occurrences = occurrences
                        updated.freezeFrame?.snapshotOdometerKm = occurrences.compactMap(\.odometerKm).max()
                        if let lastOcc = occurrences.last {
                            updated.freezeFrame?.coolantTempC = lastOcc.coolantTempC
                            updated.freezeFrame?.speedKmh = lastOcc.vehicleSpeedKmh
                        }
                    }
                }
                return updated
            }
        }

        if let data = UserDefaults.standard.data(forKey: odometerReportKey),
           let decodedReport = try? JSONDecoder().decode(OdometerAuditReport.self, from: data) {
            odometerReport = decodedReport
        }

        if let historyData = UserDefaults.standard.data(forKey: vehiclesHistoryKey),
           let decodedHistory = try? JSONDecoder().decode([DecodificavelTolerante<ConnectedVehicleRecord>].self, from: historyData) {
            connectedVehiclesHistory = decodedHistory.compactMap { $0.valor }
        }

        if UserDefaults.standard.object(forKey: autoStartTripAnalysisKey) != nil {
            autoStartTripAnalysis = UserDefaults.standard.bool(forKey: autoStartTripAnalysisKey)
        }

        if let reportsData = UserDefaults.standard.data(forKey: tripAnalysisReportsKey),
           let decodedReports = try? JSONDecoder().decode([DecodificavelTolerante<TripSensorAnalysisReport>].self, from: reportsData) {
            tripAnalysisReportsHistory = decodedReports.compactMap { $0.valor }
            latestTripAnalysisReport = tripAnalysisReportsHistory.first
        }

        if OBDUDSParser.normalizedVIN(vehicleIdentity.vin) != nil {
            applyDetectedProfile()
            recordConnectedVehicleInHistory(odometerKm: odometerReport?.highestRecordedKmAcrossECUs)
        }
    }
}
