import Foundation

// MARK: - Connection & Adapter Tier Status

public enum BLEConnectionState: String, Codable, Sendable {
    case disconnected = "Desconectado"
    case scanning = "Procurando Scanner BLE..."
    case connecting = "Conectando ao Scanner..."
    case initializingProtocol = "Detectando Protocolo e Veículo..."
    case connectedReady = "Conectado ao Veículo"
    case bluetoothOff = "Bluetooth Desativado"
    case error = "Erro de Comunicação"
}

public enum AdapterCapabilityTier: String, Codable, Sendable {
    case vLinkerPro = "Vgate vLinker MC+ PRO (Chip STN2120)"
    case genericELM327 = "Scanner OBD-II Básico (ELM327)"
    case unknown = "Aguardando Identificação do Scanner"

    /// Tolerante a mudança de texto: valor desconhecido cai no padrão em vez de derrubar o histórico salvo.
    public init(from decoder: Decoder) throws {
        let bruto = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = Self(rawValue: bruto) ?? .unknown
    }

    public var isAdvancedVLinker: Bool {
        self == .vLinkerPro
    }
}

public enum HealthLevel: String, Codable, Sendable, CaseIterable {
    case healthy = "Saudável"
    case attention = "Atenção"
    case critical = "Crítico"
    case unknown = "Aguardando Leitura"

    public init(from decoder: Decoder) throws {
        let bruto = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = Self(rawValue: bruto) ?? .unknown
    }
}

public enum DiagnosticViewMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case customerSimple = "Visão Cliente (Simples)"
    case mechanicTechnical = "Visão Mecânico (Técnica)"

    public var id: String { rawValue }
}

public struct DiscoveredBLEDevice: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let rssi: Int
    public let isPreferredVLinker: Bool

    public init(id: UUID, name: String, rssi: Int, isPreferredVLinker: Bool) {
        self.id = id
        self.name = name
        self.rssi = rssi
        self.isPreferredVLinker = isPreferredVLinker
    }
}

// MARK: - Perfil do veículo (genérico: tudo vem do que o carro informa pelo vLinker)

public enum VehicleBrandProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case autoDetect = "Auto-Detectar pelo Scanner"
    case universalOBD = "Veículo OBD-II / UDS"

    /// Perfis antigos (ex.: de uma versão que tinha modelos específicos) viram detecção automática.
    public init(from decoder: Decoder) throws {
        let bruto = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = Self(rawValue: bruto) ?? .autoDetect
    }

    public var id: String { rawValue }

    /// Limites gerais, válidos para motores e transmissões automáticas modernas (Aisin 4AT, CVT e automáticos epicíclicos).
    /// Não causam pânico desnecessário: no trânsito urbano com conversor de torque deslizando e trocador
    /// acoplado ao radiador de 95-105°C, o fluido do câmbio opera normalmente até 115°C.
    private static let generalThermalThresholds = VehicleThermalThresholds(
            transmission: TransmissionThermalThresholds(
                transmissionName: "Câmbio CVT25",
                warmUpThresholdC: 60.0,
                nominalMaxC: 105.0,
                heavyLoadNormalMaxC: 115.0,
                thermalInterventionC: 120.0,
                criticalDTCThresholdC: 125.0,
                officialEngineeringReference: "Wanliyang CVT25 / Chery Arrizo 6 (normal até 115°C sob tráfego urbano/carga; alerta TCU 120°C; DTC P0218 a 125°C)"
            ),
            coolant: CoolantThermalThresholds(
                engineDesc: "Motor a combustão",
                warmUpThresholdC: 75.0,
                nominalMaxC: 102.0,
                fanHighNormalMaxC: 108.0,
                warningThresholdC: 110.0,
                criticalDTCThresholdC: 115.0,
                officialEngineeringReference: "Faixa geral de arrefecimento pressurizado (normal entre 85°C e 105°C)"
            )
        )

    public var thermalThresholds: VehicleThermalThresholds { Self.generalThermalThresholds }

    /// Decodificação oficial do veículo a partir do VIN (ISO 3779 / WMI / VDS) e identificadores lidos da ECU.
    public static func detect(fromVIN vin: String, ecuName: String, calibrationId: String) -> (profile: VehicleBrandProfile, modelName: String, engineDesc: String, transmissionDesc: String) {
        let cleanVIN = vin.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let ecu = ecuName.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasECU = !ecu.isEmpty && !ecu.contains("Aguardando")

        // CAOA Chery Arrizo 6 (WMI 98R = Chery Brasil; VDS DC21 = Arrizo 6 1.5 Turbo Flex)
        if cleanVIN.hasPrefix("98RDC21") {
            let engine = hasECU ? "1.5 Turbo Flex SQRE4T15C • \(ecu)" : "1.5 Turbo Flex SQRE4T15C"
            return (.universalOBD, "CAOA Chery Arrizo 6 1.5 Turbo", engine, "Câmbio Wanliyang CVT25 (Fluido CVT)")
        } else if cleanVIN.hasPrefix("98R") {
            let engine = hasECU ? "Motor Chery Flex • \(ecu)" : "Motor Chery Flex"
            return (.universalOBD, "CAOA Chery (\(cleanVIN.prefix(8)))", engine, "Câmbio CVT25 / Automático")
        }

        let engine = hasECU ? "ECU \(ecu)" : "Motor monitorado via OBD-II"
        if cleanVIN.count == 17 {
            return (.universalOBD, "Veículo \(cleanVIN)", engine, "Câmbio (lido via CAN quando disponível)")
        }
        return (.autoDetect, "Veículo conectado via OBD-II", engine, "Câmbio (lido via CAN quando disponível)")
    }
}

// MARK: - Configurable Cockpit & CarPlay Gauge Identifiers (42 Real CAN/UDS Sensors)

public enum CockpitGaugeID: String, Codable, CaseIterable, Identifiable, Sendable {
    // 1. Consumo & Viagem
    case instantFuel = "instantFuel"
    case averageFuel = "averageFuel"
    case fuelFlowRate = "fuelFlowRate"
    case tripDistance = "tripDistance"
    case tripFuelUsed = "tripFuelUsed"
    case ethanolPercent = "ethanolPercent"
    case fuelTrim = "fuelTrim"
    case fuelTankLevel = "fuelTankLevel"

    // 2. Motor, Turbo & Admissão
    case speed = "speed"
    case rpm = "rpm"
    case mapBoost = "mapBoost"
    case engineLoad = "engineLoad"
    case absoluteEngineLoad = "absoluteEngineLoad"
    case mafAirFlow = "mafAirFlow"
    case timingAdvance = "timingAdvance"
    case barometricPressure = "barometricPressure"
    case fuelRailPressure = "fuelRailPressure"
    case commandedEvapPurge = "commandedEvapPurge"
    case estimatedPowerHp = "estimatedPowerHp"
    case estimatedTorqueNm = "estimatedTorqueNm"

    // 3. Pedal, Borboleta & Sondas Lambda
    case throttlePos = "throttlePos"
    case relativeThrottlePos = "relativeThrottlePos"
    case commandedThrottleActuator = "commandedThrottleActuator"
    case acceleratorPedalPosD = "acceleratorPedalPosD"
    case acceleratorPedalPosE = "acceleratorPedalPosE"
    case commandedEquivalenceRatio = "commandedEquivalenceRatio"
    case lambdaO2Voltage = "lambdaO2Voltage"
    case lambdaO2Sensor2 = "lambdaO2Sensor2"

    // 4. Temperaturas & Térmica
    case coolantTemp = "coolantTemp"
    case cvtTemp = "cvtTemp"
    case intakeAirTemp = "intakeAirTemp"
    case ambientTemp = "ambientTemp"
    case catalystTempB1S1 = "catalystTempB1S1"
    case engineOilTemp = "engineOilTemp"

    // 5. Elétrica, Odômetros & Diagnóstico
    case batteryVoltage = "batteryVoltage"
    case ecuModuleVoltage = "ecuModuleVoltage"
    case tcuOdometer = "tcuOdometer"
    case engineRunTime = "engineRunTime"
    case distanceSinceDTCClear = "distanceSinceDTCClear"
    case warmUpsSinceDTCClear = "warmUpsSinceDTCClear"
    case timeSinceDTCClear = "timeSinceDTCClear"
    case distanceWithMILOn = "distanceWithMILOn"

    public var id: String { rawValue }

    /// 22 slots padrão do CarPlay (16 pílulas na grade 4x4 à esquerda + 2 mostradores principais e 4 vitais à direita).
    public static let defaultCarPlaySlots: [CockpitGaugeID] = [
        // 16 pílulas da grade 4x4 (Slots 0..15)
        .tripDistance, .tripFuelUsed, .fuelFlowRate, .fuelTrim,
        .mapBoost, .throttlePos, .intakeAirTemp, .engineLoad,
        .timingAdvance, .lambdaO2Voltage, .barometricPressure, .fuelTankLevel,
        .ethanolPercent, .engineRunTime, .tcuOdometer, .distanceSinceDTCClear,
        // 2 mostradores principais à direita topo (Slots 16..17)
        .speed, .rpm,
        // 4 cartões vitais à direita abaixo (Slots 18..21)
        .cvtTemp, .coolantTemp, .batteryVoltage, .ambientTemp
    ]

    public var title: String {
        switch self {
        case .coolantTemp: return "Arrefecimento do Motor"
        case .cvtTemp: return "Temp. Câmbio CVT"
        case .rpm: return "Rotação do Motor"
        case .speed: return "Velocidade Real CAN"
        case .instantFuel: return "Consumo Instantâneo"
        case .averageFuel: return "Consumo Médio Viagem"
        case .fuelFlowRate: return "Vazão de Injeção (Fluxo)"
        case .tripDistance: return "Distância da Viagem"
        case .tripFuelUsed: return "Combustível Gasto Viagem"
        case .ethanolPercent: return "% Etanol / AFR Tanque"
        case .ambientTemp: return "Temp. Externa (Rua)"
        case .mapBoost: return "Pressão Coletor / Turbo"
        case .batteryVoltage: return "Bateria 12V & Alternador"
        case .ecuModuleVoltage: return "Tensão na Placa da ECU"
        case .fuelTrim: return "Mistura (STFT / LTFT)"
        case .intakeAirTemp: return "Temp. Admissão (IAT)"
        case .engineLoad: return "Carga Calculada Motor"
        case .absoluteEngineLoad: return "Carga Volumétrica Abs."
        case .mafAirFlow: return "Fluxo de Massa de Ar (MAF)"
        case .throttlePos: return "Posição Borboleta (TBI)"
        case .relativeThrottlePos: return "Borboleta Relativa"
        case .commandedThrottleActuator: return "Atuador TBI Comandado"
        case .acceleratorPedalPosD: return "Pedal Acelerador (Pista D)"
        case .acceleratorPedalPosE: return "Pedal Acelerador (Pista E)"
        case .commandedEquivalenceRatio: return "Mistura Lambda Comandada"
        case .tcuOdometer: return "KM Interno do Câmbio"
        case .timingAdvance: return "Avanço Ponto de Ignição"
        case .barometricPressure: return "Pressão Barométrica"
        case .fuelRailPressure: return "Pressão Linha Combustível"
        case .commandedEvapPurge: return "Purga do Canister EVAP"
        case .fuelTankLevel: return "Nível do Tanque (Boia)"
        case .engineRunTime: return "Tempo de Motor Ligado"
        case .lambdaO2Voltage: return "Sonda O2 Pré-Catalisador"
        case .lambdaO2Sensor2: return "Sonda O2 Pós-Catalisador"
        case .catalystTempB1S1: return "Temp. do Catalisador"
        case .engineOilTemp: return "Temp. do Óleo do Motor"
        case .distanceSinceDTCClear: return "KM Pós-Limpeza de Falhas"
        case .warmUpsSinceDTCClear: return "Aquecimentos Pós-Reset"
        case .timeSinceDTCClear: return "Tempo Pós-Limpeza DTC"
        case .distanceWithMILOn: return "KM c/ Luz Injeção Acesa"
        case .estimatedPowerHp: return "Potência Instantânea"
        case .estimatedTorqueNm: return "Torque Instantâneo"
        }
    }

    public var shortCarPlayLabel: String {
        switch self {
        case .coolantTemp: return "MOTOR"
        case .cvtTemp: return "CÂMBIO"
        case .rpm: return "ROTAÇÃO"
        case .speed: return "VELOCIDADE"
        case .instantFuel: return "INSTANTÂNEO"
        case .averageFuel: return "MÉDIA VIAGEM"
        case .fuelFlowRate: return "FLUXO"
        case .tripDistance: return "DISTÂNCIA"
        case .tripFuelUsed: return "GASTO"
        case .ethanolPercent: return "ETANOL / AFR"
        case .ambientTemp: return "AR EXTERNO"
        case .mapBoost: return "TURBO / MAP"
        case .batteryVoltage: return "BATERIA"
        case .ecuModuleVoltage: return "TENSÃO ECU"
        case .fuelTrim: return "MISTURA"
        case .intakeAirTemp: return "ADMISSÃO"
        case .engineLoad: return "CARGA MOTOR"
        case .absoluteEngineLoad: return "CARGA ABS."
        case .mafAirFlow: return "FLUXO AR"
        case .throttlePos: return "ACELERADOR"
        case .relativeThrottlePos: return "TBI RELAT."
        case .commandedThrottleActuator: return "ATUADOR TBI"
        case .acceleratorPedalPosD: return "PEDAL PISTA D"
        case .acceleratorPedalPosE: return "PEDAL PISTA E"
        case .commandedEquivalenceRatio: return "LAMBDA CMD"
        case .tcuOdometer: return "KM CÂMBIO"
        case .timingAdvance: return "IGNIÇÃO"
        case .barometricPressure: return "BARÔMETRO"
        case .fuelRailPressure: return "PRESS. FLAUTA"
        case .commandedEvapPurge: return "PURGA EVAP"
        case .fuelTankLevel: return "TANQUE"
        case .engineRunTime: return "TEMPO MOTOR"
        case .lambdaO2Voltage: return "SONDA O2 S1"
        case .lambdaO2Sensor2: return "SONDA PÓS S2"
        case .catalystTempB1S1: return "CATALISADOR"
        case .engineOilTemp: return "TEMP. ÓLEO"
        case .distanceSinceDTCClear: return "KM PÓS-DTC"
        case .warmUpsSinceDTCClear: return "CICLOS AQUEC."
        case .timeSinceDTCClear: return "TEMPO PÓS-DTC"
        case .distanceWithMILOn: return "KM LUZ MIL"
        case .estimatedPowerHp: return "POTÊNCIA"
        case .estimatedTorqueNm: return "TORQUE"
        }
    }

    public var pidBadge: String {
        switch self {
        case .coolantTemp: return "PID 01 05"
        case .cvtTemp: return "UDS 22 0B37"
        case .rpm: return "PID 01 0C"
        case .speed: return "PID 01 0D"
        case .instantFuel: return "CALC MAP/AF"
        case .averageFuel: return "TRIP KM/L"
        case .fuelFlowRate: return "CALC L/H"
        case .tripDistance: return "TRIP KM"
        case .tripFuelUsed: return "TRIP L"
        case .ethanolPercent: return "PID 01 52 / AF"
        case .ambientTemp: return "PID 01 46"
        case .mapBoost: return "PID 01 0B"
        case .batteryVoltage: return "AT RV"
        case .ecuModuleVoltage: return "PID 01 42"
        case .fuelTrim: return "PID 01 06/07"
        case .intakeAirTemp: return "PID 01 0F"
        case .engineLoad: return "PID 01 04"
        case .absoluteEngineLoad: return "PID 01 43"
        case .mafAirFlow: return "PID 01 10"
        case .throttlePos: return "PID 01 11"
        case .relativeThrottlePos: return "PID 01 45"
        case .commandedThrottleActuator: return "PID 01 4C"
        case .acceleratorPedalPosD: return "PID 01 49"
        case .acceleratorPedalPosE: return "PID 01 4A"
        case .commandedEquivalenceRatio: return "PID 01 44"
        case .tcuOdometer: return "UDS 22 0B5B"
        case .timingAdvance: return "PID 01 0E"
        case .barometricPressure: return "PID 01 33"
        case .fuelRailPressure: return "PID 01 23"
        case .commandedEvapPurge: return "PID 01 2E"
        case .fuelTankLevel: return "PID 01 2F"
        case .engineRunTime: return "PID 01 1F"
        case .lambdaO2Voltage: return "PID 01 14"
        case .lambdaO2Sensor2: return "PID 01 15"
        case .catalystTempB1S1: return "PID 01 3C"
        case .engineOilTemp: return "PID 01 5C"
        case .distanceSinceDTCClear: return "PID 01 31"
        case .warmUpsSinceDTCClear: return "PID 01 30"
        case .timeSinceDTCClear: return "PID 01 4E"
        case .distanceWithMILOn: return "PID 01 21"
        case .estimatedPowerHp: return "CALC CV"
        case .estimatedTorqueNm: return "CALC NM"
        }
    }

    /// Código numérico do PID SAE J1979 Mode 01 (para cruzamento dinâmico com os bitmasks `01 00`, `01 20`, `01 40` da ECU do veículo).
    public var mode01PIDNumber: Int? {
        switch self {
        case .engineLoad: return 0x04
        case .coolantTemp: return 0x05
        case .fuelTrim: return 0x06
        case .mapBoost: return 0x0B
        case .rpm: return 0x0C
        case .speed: return 0x0D
        case .timingAdvance: return 0x0E
        case .intakeAirTemp: return 0x0F
        case .mafAirFlow: return 0x10
        case .throttlePos: return 0x11
        case .lambdaO2Voltage: return 0x14
        case .lambdaO2Sensor2: return 0x15
        case .engineRunTime: return 0x1F
        case .distanceWithMILOn: return 0x21
        case .fuelRailPressure: return 0x23
        case .commandedEvapPurge: return 0x2E
        case .fuelTankLevel: return 0x2F
        case .warmUpsSinceDTCClear: return 0x30
        case .distanceSinceDTCClear: return 0x31
        case .barometricPressure: return 0x33
        case .catalystTempB1S1: return 0x3C
        case .ecuModuleVoltage: return 0x42
        case .absoluteEngineLoad: return 0x43
        case .commandedEquivalenceRatio: return 0x44
        case .relativeThrottlePos: return 0x45
        case .ambientTemp: return 0x46
        case .acceleratorPedalPosD: return 0x49
        case .acceleratorPedalPosE: return 0x4A
        case .commandedThrottleActuator: return 0x4C
        case .timeSinceDTCClear: return 0x4E
        case .ethanolPercent: return 0x52
        case .engineOilTemp: return 0x5C
        default: return nil
        }
    }

    public var defaultUnit: String {
        switch self {
        case .coolantTemp, .cvtTemp, .intakeAirTemp, .ambientTemp, .catalystTempB1S1, .engineOilTemp:
            return "°C"
        case .rpm:
            return "RPM"
        case .speed:
            return "km/h"
        case .instantFuel, .averageFuel:
            return "km/L"
        case .fuelFlowRate:
            return "L/h"
        case .tripDistance, .tcuOdometer, .distanceSinceDTCClear, .distanceWithMILOn:
            return "km"
        case .tripFuelUsed:
            return "L"
        case .ethanolPercent, .fuelTrim, .fuelTankLevel, .engineLoad, .absoluteEngineLoad,
             .throttlePos, .relativeThrottlePos, .commandedThrottleActuator,
             .acceleratorPedalPosD, .acceleratorPedalPosE, .commandedEvapPurge:
            return "%"
        case .mapBoost, .barometricPressure, .fuelRailPressure:
            return "kPa"
        case .batteryVoltage, .ecuModuleVoltage:
            return "V"
        case .mafAirFlow:
            return "g/s"
        case .timingAdvance:
            return "°"
        case .commandedEquivalenceRatio:
            return "λ"
        case .lambdaO2Voltage, .lambdaO2Sensor2:
            return "mV"
        case .engineRunTime, .timeSinceDTCClear:
            return "min"
        case .warmUpsSinceDTCClear:
            return "ciclos"
        case .estimatedPowerHp:
            return "cv"
        case .estimatedTorqueNm:
            return "Nm"
        }
    }

    /// Extrai o valor numérico real do `TelemetrySnapshot` para acumulação estatística da viagem.
    public func numericValue(from t: TelemetrySnapshot) -> Double? {
        switch self {
        case .coolantTemp: return t.coolantTempC
        case .cvtTemp: return t.transmissionTempC
        case .rpm: return t.rpm
        case .speed: return t.speedKmh
        case .instantFuel: return t.instantKmPerLiter
        case .averageFuel: return t.sessionAverageKmPerLiter
        case .fuelFlowRate: return t.fuelRateLitersPerHour
        case .tripDistance: return t.sessionDistanceKm > 0.01 ? t.sessionDistanceKm : nil
        case .tripFuelUsed: return t.sessionFuelLiters > 0.005 ? t.sessionFuelLiters : nil
        case .ethanolPercent: return t.ethanolFuelPct
        case .ambientTemp: return t.effectiveExternalTempC
        case .mapBoost: return t.mapKpa
        case .batteryVoltage: return t.batteryVoltage
        case .ecuModuleVoltage: return t.ecuModuleVoltage
        case .fuelTrim: return t.longFuelTrimPct ?? t.shortFuelTrimPct
        case .intakeAirTemp: return t.intakeAirTempC
        case .engineLoad: return t.engineLoadPct
        case .absoluteEngineLoad: return t.absoluteLoadPct
        case .mafAirFlow: return t.effectiveAirFlowGramsPerSec
        case .throttlePos: return t.throttlePositionPct
        case .relativeThrottlePos: return t.relativeThrottlePct
        case .commandedThrottleActuator: return t.commandedThrottleActuatorPct
        case .acceleratorPedalPosD: return t.acceleratorPedalDPct
        case .acceleratorPedalPosE: return t.acceleratorPedalEPct
        case .commandedEquivalenceRatio: return t.commandedLambdaRatio
        case .tcuOdometer: return t.tcuOdometerKm
        case .timingAdvance: return t.timingAdvanceDeg
        case .barometricPressure: return t.barometricPressureKpa
        case .fuelRailPressure: return t.fuelRailPressureKpa
        case .commandedEvapPurge: return t.commandedEvapPurgePct
        case .fuelTankLevel: return t.fuelTankLevelPct
        case .engineRunTime: return t.engineRunTimeSec.map { Double($0) / 60.0 }
        case .lambdaO2Voltage: return t.lambdaO2VoltageMv
        case .lambdaO2Sensor2: return t.lambdaO2Sensor2Mv
        case .catalystTempB1S1: return t.catalystTempB1S1C
        case .engineOilTemp: return t.engineOilTempC
        case .distanceSinceDTCClear: return t.distanceSinceDTCClearKm
        case .warmUpsSinceDTCClear: return t.warmUpsSinceDTCClear.map(Double.init)
        case .timeSinceDTCClear: return t.timeSinceDTCClearMin.map(Double.init)
        case .distanceWithMILOn: return t.distanceWithMILOnKm
        case .estimatedPowerHp: return t.estimatedPowerHp
        case .estimatedTorqueNm: return t.estimatedTorqueNm
        }
    }

    public var singlePIDCommand: String? {
        switch self {
        case .coolantTemp: return "01 05"
        case .rpm: return "01 0C"
        case .speed: return "01 0D"
        case .ethanolPercent: return "01 52"
        case .ambientTemp: return "01 46"
        case .mapBoost: return "01 0B"
        case .ecuModuleVoltage: return "01 42"
        case .fuelTrim: return "01 06"
        case .intakeAirTemp: return "01 0F"
        case .engineLoad: return "01 04"
        case .absoluteEngineLoad: return "01 43"
        case .mafAirFlow: return "01 10"
        case .throttlePos: return "01 11"
        case .relativeThrottlePos: return "01 45"
        case .commandedThrottleActuator: return "01 4C"
        case .acceleratorPedalPosD: return "01 49"
        case .acceleratorPedalPosE: return "01 4A"
        case .commandedEquivalenceRatio: return "01 44"
        case .timingAdvance: return "01 0E"
        case .barometricPressure: return "01 33"
        case .fuelRailPressure: return "01 23"
        case .commandedEvapPurge: return "01 2E"
        case .fuelTankLevel: return "01 2F"
        case .engineRunTime: return "01 1F"
        case .lambdaO2Voltage: return "01 14"
        case .lambdaO2Sensor2: return "01 15"
        case .catalystTempB1S1: return "01 3C"
        case .engineOilTemp: return "01 5C"
        case .distanceSinceDTCClear: return "01 31"
        case .warmUpsSinceDTCClear: return "01 30"
        case .timeSinceDTCClear: return "01 4E"
        case .distanceWithMILOn: return "01 21"
        default: return nil
        }
    }

    public var iconName: String {
        switch self {
        case .coolantTemp: return "thermometer.medium"
        case .cvtTemp: return "gearshape.2.fill"
        case .rpm: return "gauge.with.dots.needle.67percent"
        case .speed: return "speedometer"
        case .instantFuel: return "drop.fill"
        case .averageFuel: return "chart.line.uptrend.xyaxis"
        case .fuelFlowRate: return "spigot.fill"
        case .tripDistance: return "road.lanes"
        case .tripFuelUsed: return "fuelpump.circle.fill"
        case .ethanolPercent: return "leaf.fill"
        case .ambientTemp: return "cloud.sun.fill"
        case .mapBoost: return "tornado"
        case .batteryVoltage: return "bolt.car.fill"
        case .ecuModuleVoltage: return "cpu.fill"
        case .fuelTrim: return "fuelpump.fill"
        case .intakeAirTemp: return "wind"
        case .engineLoad: return "scalemass.fill"
        case .absoluteEngineLoad: return "dial.high.fill"
        case .mafAirFlow: return "aqi.medium"
        case .throttlePos: return "pedal.accelerator.fill"
        case .relativeThrottlePos: return "angle"
        case .commandedThrottleActuator: return "gear.badge.checkmark"
        case .acceleratorPedalPosD: return "shoe.fill"
        case .acceleratorPedalPosE: return "shoe.2.fill"
        case .commandedEquivalenceRatio: return "function"
        case .tcuOdometer: return "point.3.connected.trianglepath.dotted"
        case .timingAdvance: return "flame.fill"
        case .barometricPressure: return "barometer"
        case .fuelRailPressure: return "gauge.with.needle.fill"
        case .commandedEvapPurge: return "arrow.triangle.2.circlepath.circle.fill"
        case .fuelTankLevel: return "fuelpump"
        case .engineRunTime: return "clock.arrow.circlepath"
        case .lambdaO2Voltage: return "waveform.path"
        case .lambdaO2Sensor2: return "waveform.path.ecg"
        case .catalystTempB1S1: return "flame.circle.fill"
        case .engineOilTemp: return "drop.degreesign.fill"
        case .distanceSinceDTCClear: return "arrow.clockwise.square"
        case .warmUpsSinceDTCClear: return "thermometer.sun.fill"
        case .timeSinceDTCClear: return "timer"
        case .distanceWithMILOn: return "exclamationmark.triangle.fill"
        case .estimatedPowerHp: return "bolt.circle.fill"
        case .estimatedTorqueNm: return "arrow.clockwise.circle.fill"
        }
    }

    public var category: String {
        switch self {
        case .instantFuel, .averageFuel, .fuelFlowRate, .tripDistance, .tripFuelUsed, .ethanolPercent, .fuelTrim, .fuelTankLevel:
            return "Consumo & Combustível Flex"
        case .rpm, .speed, .mapBoost, .engineLoad, .absoluteEngineLoad, .mafAirFlow, .timingAdvance, .barometricPressure, .fuelRailPressure, .commandedEvapPurge, .estimatedPowerHp, .estimatedTorqueNm:
            return "Motor, Turbo & Performance"
        case .throttlePos, .relativeThrottlePos, .commandedThrottleActuator, .acceleratorPedalPosD, .acceleratorPedalPosE, .commandedEquivalenceRatio, .lambdaO2Voltage, .lambdaO2Sensor2:
            return "Pedal, Borboleta & Sondas"
        case .coolantTemp, .cvtTemp, .intakeAirTemp, .ambientTemp, .catalystTempB1S1, .engineOilTemp:
            return "Temperaturas & Térmica"
        case .batteryVoltage, .ecuModuleVoltage, .tcuOdometer, .engineRunTime, .distanceSinceDTCClear, .warmUpsSinceDTCClear, .timeSinceDTCClear, .distanceWithMILOn:
            return "Elétrica, Odômetros & ECU"
        }
    }

    /// Breve explicação / resumo em linguagem clara do que é cada sensor e como interpretar sua leitura.
    public var summaryDescription: String {
        switch self {
        case .instantFuel:
            return "Mostra quantos km/L o carro está fazendo neste exato segundo (ou o gasto em L/h quando parado em marcha lenta)."
        case .averageFuel:
            return "Média acumulada de km/L desde o início da viagem atual, ideal para comparar com o computador de bordo do painel."
        case .fuelFlowRate:
            return "Volume real de combustível injetado pelos bicos em litros por hora (em marcha lenta costuma ficar entre 0,7 e 1,3 L/h)."
        case .tripDistance:
            return "Quilometragem percorrida na sessão atual integrada diretamente da velocidade real da ECU."
        case .tripFuelUsed:
            return "Quantidade exata de combustível (em litros) consumida desde o início da viagem ou último reset."
        case .ethanolPercent:
            return "Percentual de etanol detectado no tanque (PID 01 52) ou relação ar/combustível estequiométrica (AFR) ativa na injeção."
        case .fuelTrim:
            return "Correção da injeção a curto (STFT) e longo prazo (LTFT). Valores entre -10% e +10% indicam bicos e sonda saudáveis."
        case .fuelTankLevel:
            return "Percentual real de combustível lido diretamente pelo sensor de boia do tanque na rede CAN."
        case .speed:
            return "Velocidade exata lida dos sensores de roda ABS/ECU (sem os 3% a 5% de margem que o velocímetro do painel adiciona)."
        case .rpm:
            return "Giros exatos do virabrequim por minuto lidos pelo sensor de rotação da injeção eletrônica."
        case .mapBoost:
            return "Pressão absoluta no coletor de admissão: negativa em vácuo (economia) e positiva quando a turbina enche (Boost)."
        case .engineLoad:
            return "Percentual de esforço atual do motor calculado pela ECU em relação ao torque máximo disponível naquela rotação."
        case .absoluteEngineLoad:
            return "Massa de ar admitida nos cilindros (em motores turbo como o 1.5T ultrapassa 100% quando a turbina pressuriza)."
        case .mafAirFlow:
            return "Gramas de ar por segundo (g/s) entrando no motor, base para o cálculo de injeção, consumo e potência."
        case .timingAdvance:
            return "Graus de avanço da centelha das velas antes do Ponto Morto Superior (PMS); indica eficiência da queima e octanagem."
        case .barometricPressure:
            return "Pressão atmosférica local medida pela ECU (ao nível do mar ~101 kPa; em serra/altitude cai para ~90–93 kPa)."
        case .fuelRailPressure:
            return "Pressão do combustível na linha/flauta dos bicos injetores monitorada pela injeção eletrônica."
        case .commandedEvapPurge:
            return "Abertura da válvula do canister (EVAP) que reaproveita os vapores de combustível do tanque na admissão."
        case .estimatedPowerHp:
            return "Potência instantânea estimada (em cavalos/cv) sendo entregue pelo motor 1.5T a partir do fluxo de massa de ar."
        case .estimatedTorqueNm:
            return "Torque instantâneo estimado (em Nm) entregue pelo conjunto motor/turbo na rotação atual."
        case .throttlePos:
            return "Percentual de abertura física da borboleta motorizada (TBI) que controla a entrada de ar no motor."
        case .relativeThrottlePos:
            return "Abertura relativa da borboleta descontando a posição mínima de marcha lenta aprendida pela ECU."
        case .commandedThrottleActuator:
            return "Comando elétrico enviado pela ECU ao motor de passo do corpo de borboleta eletrônico."
        case .acceleratorPedalPosD:
            return "Quanto você está pisando fisicamente no pedal do acelerador (sensor principal pista D)."
        case .acceleratorPedalPosE:
            return "Leitura da segunda pista redundante de segurança (pista E) do pedal eletrônico do acelerador."
        case .commandedEquivalenceRatio:
            return "Fator Lambda comandado pela ECU (1.00 = mistura ideal econômica; <0.90 = mistura enriquecida para potência)."
        case .lambdaO2Voltage:
            return "Tensão da sonda lambda antes do catalisador (oscila entre 100 e 850 mV ajustando a mistura em tempo real)."
        case .lambdaO2Sensor2:
            return "Tensão da segunda sonda lambda após o catalisador; leitura estável (~600–750 mV) confirma catalisador eficiente."
        case .coolantTemp:
            return "Temperatura do líquido de arrefecimento do motor (faixa ideal de trabalho entre 85°C e 102°C)."
        case .cvtTemp:
            return "Temperatura do óleo do câmbio automático/CVT, quando o módulo do câmbio informa (UDS 22 0B 37). Normal até ~110°C sob carga."
        case .intakeAirTemp:
            return "Temperatura do ar admitido após passar pelo filtro e intercooler antes de entrar nos cilindros."
        case .ambientTemp:
            return "Temperatura externa da rua medida pelo sensor frontal ou estimada pela admissão térmica."
        case .catalystTempB1S1:
            return "Temperatura interna do conversor catalítico no escapamento (opera normalmente entre 400°C e 800°C)."
        case .engineOilTemp:
            return "Temperatura do óleo lubrificante do motor quando disponibilizada pelo barramento CAN (PID 01 5C)."
        case .batteryVoltage:
            return "Tensão elétrica no conector OBD-II: avalia saúde da bateria em repouso (~12,4V+) e carga do alternador (~13,8V–14,5V)."
        case .ecuModuleVoltage:
            return "Tensão que chega internamente na placa da injeção eletrônica (útil para detectar perda em cabos ou aterramento)."
        case .tcuOdometer:
            return "Quilometragem gravada no módulo do câmbio, quando ele informa (UDS 22 0B 5B)."
        case .engineRunTime:
            return "Tempo total (em minutos) desde que o motor foi dado partida nesta viagem."
        case .distanceSinceDTCClear:
            return "Quilômetros percorridos desde a última vez que alguém apagou erros da injeção com scanner."
        case .warmUpsSinceDTCClear:
            return "Quantidade de vezes que o motor aqueceu completamente desde a última limpeza de códigos de falha."
        case .timeSinceDTCClear:
            return "Tempo acumulado de motor funcionando desde o último reset de falhas na memória da ECU."
        case .distanceWithMILOn:
            return "Quilômetros rodados com a luz de anomalia da injeção (Check Engine) acesa no painel (ideal: 0 km)."
        }
    }
}

public enum FuelTypeProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case autoDetected = "Automático (Sonda/ECU)"
    case gasolineE27 = "Gasolina (E27)"
    case flexBlend50 = "Misto (50/50)"
    case ethanolE100 = "Etanol (E100)"

    public init(from decoder: Decoder) throws {
        let bruto = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = Self(rawValue: bruto) ?? .autoDetected
    }

    public var id: String { rawValue }

    public func stoichiometricAFR(detectedEthanolPct: Double?) -> Double {
        switch self {
        case .gasolineE27: return 13.2
        case .flexBlend50: return 11.1
        case .ethanolE100: return 9.0
        case .autoDetected:
            let pct = min(100.0, max(27.0, detectedEthanolPct ?? 27.0))
            // Linear interpolation between E27 (13.2) and E100 (9.0)
            let ratio = (pct - 27.0) / 73.0
            return 13.2 - (ratio * 4.2)
        }
    }

    public func densityGramsPerLiter(detectedEthanolPct: Double?) -> Double {
        switch self {
        case .gasolineE27: return 735.0
        case .flexBlend50: return 772.0
        case .ethanolE100: return 809.0
        case .autoDetected:
            let pct = min(100.0, max(27.0, detectedEthanolPct ?? 27.0))
            let ratio = (pct - 27.0) / 73.0
            return 735.0 + (ratio * 74.0)
        }
    }
}

// MARK: - Vehicle Thermal Thresholds & Engineering References

public struct TransmissionThermalThresholds: Sendable, Equatable, Codable {
    public let transmissionName: String
    public let warmUpThresholdC: Double
    public let nominalMaxC: Double
    public let heavyLoadNormalMaxC: Double
    public let thermalInterventionC: Double
    public let criticalDTCThresholdC: Double
    public let officialEngineeringReference: String

    public init(
        transmissionName: String,
        warmUpThresholdC: Double,
        nominalMaxC: Double,
        heavyLoadNormalMaxC: Double,
        thermalInterventionC: Double,
        criticalDTCThresholdC: Double,
        officialEngineeringReference: String
    ) {
        self.transmissionName = transmissionName
        self.warmUpThresholdC = warmUpThresholdC
        self.nominalMaxC = nominalMaxC
        self.heavyLoadNormalMaxC = heavyLoadNormalMaxC
        self.thermalInterventionC = thermalInterventionC
        self.criticalDTCThresholdC = criticalDTCThresholdC
        self.officialEngineeringReference = officialEngineeringReference
    }
}

public struct CoolantThermalThresholds: Sendable, Equatable, Codable {
    public let engineDesc: String
    public let warmUpThresholdC: Double
    public let nominalMaxC: Double
    public let fanHighNormalMaxC: Double
    public let warningThresholdC: Double
    public let criticalDTCThresholdC: Double
    public let officialEngineeringReference: String

    public init(
        engineDesc: String,
        warmUpThresholdC: Double,
        nominalMaxC: Double,
        fanHighNormalMaxC: Double,
        warningThresholdC: Double,
        criticalDTCThresholdC: Double,
        officialEngineeringReference: String
    ) {
        self.engineDesc = engineDesc
        self.warmUpThresholdC = warmUpThresholdC
        self.nominalMaxC = nominalMaxC
        self.fanHighNormalMaxC = fanHighNormalMaxC
        self.warningThresholdC = warningThresholdC
        self.criticalDTCThresholdC = criticalDTCThresholdC
        self.officialEngineeringReference = officialEngineeringReference
    }
}

public struct VehicleThermalThresholds: Sendable, Equatable, Codable {
    public let transmission: TransmissionThermalThresholds
    public let coolant: CoolantThermalThresholds

    public init(transmission: TransmissionThermalThresholds, coolant: CoolantThermalThresholds) {
        self.transmission = transmission
        self.coolant = coolant
    }
}

// MARK: - Vehicle Identity

public struct VehicleIdentity: Codable, Equatable, Sendable {
    public var vin: String
    public var ecuName: String
    public var calibrationId: String
    public var obdProtocol: String
    public var adapterFirmware: String
    public var adapterTier: AdapterCapabilityTier
    public var detectedBrandProfile: VehicleBrandProfile
    public var modelDescription: String
    public var engineCode: String
    public var transmissionCode: String
    public var displacementLiters: Double
    /// PIDs Mode 01 suportados fisicamente pela ECU do veículo conectado (descobertos via bitmasks 01 00, 01 20, 01 40).
    public var supportedMode01PIDs: [Int]
    /// Tipo de combustível reportado diretamente pela ECU via PID 01 51 (quando suportado).
    public var ecuReportedFuelType: String?
    /// `true` depois que o coletor passou da pressão atmosférica (só acontece com turbo/compressor).
    public var boostObserved: Bool

    public var thermalThresholds: VehicleThermalThresholds {
        detectedBrandProfile.thermalThresholds
    }

    /// Turbo detectado pela física: pressão no coletor acima da atmosférica em algum momento.
    public var isTurbochargedEngine: Bool { boostObserved }

    public var cleanModelTitle: String {
        modelDescription
            .replacingOccurrences(of: " (Auto-Detectado via VIN)", with: "")
            .replacingOccurrences(of: " (Auto-Detectado)", with: "")
    }

    public init(
        vin: String = "Aguardando Leitura",
        ecuName: String = "Aguardando ECU",
        calibrationId: String = "Aguardando Calibração",
        obdProtocol: String = "Auto-Negociação ISO 15765-4 CAN",
        adapterFirmware: String = "Aguardando Scanner BLE",
        adapterTier: AdapterCapabilityTier = .unknown,
        detectedBrandProfile: VehicleBrandProfile = .autoDetect,
        modelDescription: String = "Nenhum Veículo Conectado",
        engineCode: String = "Aguardando Conexão com Scanner",
        transmissionCode: String = "Aguardando Conexão com Scanner",
        displacementLiters: Double = 1.500,
        supportedMode01PIDs: [Int] = [],
        ecuReportedFuelType: String? = nil,
        boostObserved: Bool = false
    ) {
        self.vin = vin
        self.ecuName = ecuName
        self.calibrationId = calibrationId
        self.obdProtocol = obdProtocol
        self.adapterFirmware = adapterFirmware
        self.adapterTier = adapterTier
        self.detectedBrandProfile = detectedBrandProfile
        self.modelDescription = modelDescription
        self.engineCode = engineCode
        self.transmissionCode = transmissionCode
        self.displacementLiters = displacementLiters
        self.supportedMode01PIDs = supportedMode01PIDs
        self.ecuReportedFuelType = ecuReportedFuelType
        self.boostObserved = boostObserved
    }

    /// Decode tolerante: identidade salva por uma versão anterior (sem algum campo) continua válida.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let padrao = VehicleIdentity()
        vin = c.valor(.vin, padrao.vin)
        ecuName = c.valor(.ecuName, padrao.ecuName)
        calibrationId = c.valor(.calibrationId, padrao.calibrationId)
        obdProtocol = c.valor(.obdProtocol, padrao.obdProtocol)
        adapterFirmware = c.valor(.adapterFirmware, padrao.adapterFirmware)
        adapterTier = c.valor(.adapterTier, padrao.adapterTier)
        detectedBrandProfile = c.valor(.detectedBrandProfile, padrao.detectedBrandProfile)
        modelDescription = c.valor(.modelDescription, padrao.modelDescription)
        engineCode = c.valor(.engineCode, padrao.engineCode)
        transmissionCode = c.valor(.transmissionCode, padrao.transmissionCode)
        displacementLiters = c.valor(.displacementLiters, padrao.displacementLiters)
        supportedMode01PIDs = c.valor(.supportedMode01PIDs, [])
        ecuReportedFuelType = c.valorOpcional(.ecuReportedFuelType)
        boostObserved = c.valor(.boostObserved, false)
    }
}

public struct ConnectedVehicleRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var vin: String
    public var modelDescription: String
    public var engineCode: String
    public var transmissionCode: String
    public var ecuName: String
    public var calibrationId: String
    public var lastConnectedAt: Date
    public var lastKnownOdometerKm: Double?

    public init(
        id: String,
        vin: String,
        modelDescription: String,
        engineCode: String,
        transmissionCode: String,
        ecuName: String,
        calibrationId: String,
        lastConnectedAt: Date = Date(),
        lastKnownOdometerKm: Double? = nil
    ) {
        self.id = id
        self.vin = vin
        self.modelDescription = modelDescription
        self.engineCode = engineCode
        self.transmissionCode = transmissionCode
        self.ecuName = ecuName
        self.calibrationId = calibrationId
        self.lastConnectedAt = lastConnectedAt
        self.lastKnownOdometerKm = lastKnownOdometerKm
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let vinLido = c.valor(.vin, "")
        vin = vinLido
        id = c.valor(.id, vinLido)
        modelDescription = c.valor(.modelDescription, "Veículo conectado via OBD-II")
        engineCode = c.valor(.engineCode, "Identificação Automática via VIN / ECU")
        transmissionCode = c.valor(.transmissionCode, "Mapeamento Automático CAN/UDS")
        ecuName = c.valor(.ecuName, "Aguardando ECU")
        calibrationId = c.valor(.calibrationId, "Aguardando Calibração")
        lastConnectedAt = c.valor(.lastConnectedAt, Date())
        lastKnownOdometerKm = c.valorOpcional(.lastKnownOdometerKm)
    }
}

// MARK: - Módulos ECU no barramento CAN (11 bits, 500 kbps — endereços OBD/UDS comuns)

public struct ECUTargetModule: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let code: String
    public let name: String
    public let txHeader: String
    public let rxHeader: String
    public let fallbackHeaders: [(tx: String, rx: String)]
    public let systemCategory: String

    public init(
        id: String,
        code: String,
        name: String,
        txHeader: String,
        rxHeader: String,
        fallbackHeaders: [(tx: String, rx: String)] = [],
        systemCategory: String
    ) {
        self.id = id
        self.code = code
        self.name = name
        self.txHeader = txHeader
        self.rxHeader = rxHeader
        self.fallbackHeaders = fallbackHeaders
        self.systemCategory = systemCategory
    }

    enum CodingKeys: String, CodingKey {
        case id, code, name, txHeader, rxHeader, systemCategory
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.code = try c.decode(String.self, forKey: .code)
        self.name = try c.decode(String.self, forKey: .name)
        self.txHeader = try c.decode(String.self, forKey: .txHeader)
        self.rxHeader = try c.decode(String.self, forKey: .rxHeader)
        self.systemCategory = try c.decode(String.self, forKey: .systemCategory)
        self.fallbackHeaders = []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(code, forKey: .code)
        try c.encode(name, forKey: .name)
        try c.encode(txHeader, forKey: .txHeader)
        try c.encode(rxHeader, forKey: .rxHeader)
        try c.encode(systemCategory, forKey: .systemCategory)
    }

    public static func == (lhs: ECUTargetModule, rhs: ECUTargetModule) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// Endereços UDS mais comuns por função (com alternativos). Módulo que não responde é ignorado.
    public static let multiBrandModules: [ECUTargetModule] = [
        ECUTargetModule(
            id: "ECM",
            code: "ECM",
            name: "Módulo de Injeção Eletrônica (Motor)",
            txHeader: "7E0",
            rxHeader: "7E8",
            systemCategory: "Motor & Injeção"
        ),
        ECUTargetModule(
            id: "TCU",
            code: "TCU",
            name: "Módulo de Transmissão Automática / CVT",
            txHeader: "7E1",
            rxHeader: "7E9",
            fallbackHeaders: [("7E2", "7EA"), ("718", "798"), ("738", "730")],
            systemCategory: "Câmbio / Transmissão"
        ),
        ECUTargetModule(
            id: "HVAC",
            code: "HVAC",
            name: "Módulo de Climatização / Ar-Condicionado",
            txHeader: "744",
            rxHeader: "74C",
            fallbackHeaders: [("750", "758"), ("7A0", "7A8"), ("733", "73B"), ("764", "76C")],
            systemCategory: "Ar-Condicionado"
        ),
        ECUTargetModule(
            id: "BDM",
            code: "BDM/BCM",
            name: "Módulo de Carroceria e Conforto (BCM)",
            txHeader: "740",
            rxHeader: "748",
            fallbackHeaders: [("740", "750"), ("760", "770"), ("765", "775"), ("760", "768"), ("726", "72E"), ("765", "76D")],
            systemCategory: "Carroceria & Elétrica"
        ),
        ECUTargetModule(
            id: "ABS",
            code: "ABS/ESP",
            name: "Freios ABS & Controle de Estabilidade ESP",
            txHeader: "720",
            rxHeader: "728",
            fallbackHeaders: [("720", "730"), ("730", "738"), ("730", "740"), ("7E2", "7EA"), ("780", "788")],
            systemCategory: "Freios & Estabilidade"
        ),
        ECUTargetModule(
            id: "ICM",
            code: "ICM",
            name: "Painel de Instrumentos (Cluster)",
            txHeader: "710",
            rxHeader: "718",
            fallbackHeaders: [("710", "720"), ("7C0", "7C8"), ("714", "71C")],
            systemCategory: "Painel & Hodômetro"
        )
    ]
}

// MARK: - Live Telemetry Snapshot

public struct TripRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let startDate: Date
    public let endDate: Date
    public let distanceKm: Double
    public let fuelLiters: Double
    public let avgKmPerLiter: Double
    public let fuelProfile: FuelTypeProfile
    public let durationSeconds: Double
    public let avgSpeedKmh: Double?
    public let maxCoolantTempC: Double?
    public let maxCvtTempC: Double?

    public init(
        id: UUID = UUID(),
        startDate: Date,
        endDate: Date = Date(),
        distanceKm: Double,
        fuelLiters: Double,
        avgKmPerLiter: Double,
        fuelProfile: FuelTypeProfile,
        durationSeconds: Double,
        avgSpeedKmh: Double? = nil,
        maxCoolantTempC: Double? = nil,
        maxCvtTempC: Double? = nil
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.distanceKm = distanceKm
        self.fuelLiters = fuelLiters
        self.avgKmPerLiter = avgKmPerLiter
        self.fuelProfile = fuelProfile
        self.durationSeconds = durationSeconds
        self.avgSpeedKmh = avgSpeedKmh
        self.maxCoolantTempC = maxCoolantTempC
        self.maxCvtTempC = maxCvtTempC
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let inicio = c.valor(.startDate, Date())
        id = c.valor(.id, UUID())
        startDate = inicio
        endDate = c.valor(.endDate, inicio)
        distanceKm = c.valor(.distanceKm, 0)
        fuelLiters = c.valor(.fuelLiters, 0)
        durationSeconds = c.valor(.durationSeconds, 0)
        avgKmPerLiter = c.valor(.avgKmPerLiter, fuelLiters > 0 ? distanceKm / fuelLiters : 0)
        fuelProfile = c.valor(.fuelProfile, .autoDetected)
        avgSpeedKmh = c.valorOpcional(.avgSpeedKmh)
        maxCoolantTempC = c.valorOpcional(.maxCoolantTempC)
        maxCvtTempC = c.valorOpcional(.maxCvtTempC)
    }
}

/// Abastecimento detectado pela subida do nível do tanque (PID 01 2F), esperando confirmação do usuário.
public struct FuelFillUpDraft: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var detectedAt: Date
    public var odometerKm: Double?
    /// Variação do nível em pontos percentuais (ex.: 38 = subiu 38% do tanque).
    public var deltaPct: Double
    /// Litros estimados por `deltaPct × capacidade`, para o usuário só corrigir com o valor da bomba.
    public var estimatedLiters: Double

    public init(detectedAt: Date = Date(), odometerKm: Double?, deltaPct: Double, estimatedLiters: Double) {
        self.detectedAt = detectedAt
        self.odometerKm = odometerKm
        self.deltaPct = deltaPct
        self.estimatedLiters = estimatedLiters
    }
}

/// Abastecimento registrado pelo usuário: base da média real (tanque a tanque) e do fator de calibração
/// aplicado sobre a estimativa do OBD.
public struct FuelFillUp: Codable, Equatable, Sendable {
    public var recordedAt: Date
    public var odometerKm: Double
    public var liters: Double
    /// Média real entre o abastecimento anterior e este, quando havia anterior.
    public var realKmPerLiter: Double?

    public init(recordedAt: Date = Date(), odometerKm: Double, liters: Double, realKmPerLiter: Double? = nil) {
        self.recordedAt = recordedAt
        self.odometerKm = odometerKm
        self.liters = liters
        self.realKmPerLiter = realKmPerLiter
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recordedAt = c.valor(.recordedAt, Date())
        odometerKm = c.valor(.odometerKm, 0)
        liters = c.valor(.liters, 0)
        realKmPerLiter = c.valorOpcional(.realKmPerLiter)
    }
}

public struct BatteryTripSnapshot: Codable, Equatable, Sendable {
    public let recordedAt: Date
    public let initialRestVoltage: Double
    public let finalVoltage: Double
    public let minCrankingVoltage: Double?
    public let socPercent: Int
    public let healthTitle: String

    public init(
        recordedAt: Date = Date(),
        initialRestVoltage: Double,
        finalVoltage: Double,
        minCrankingVoltage: Double? = nil,
        socPercent: Int,
        healthTitle: String
    ) {
        self.recordedAt = recordedAt
        self.initialRestVoltage = initialRestVoltage
        self.finalVoltage = finalVoltage
        self.minCrankingVoltage = minCrankingVoltage
        self.socPercent = socPercent
        self.healthTitle = healthTitle
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recordedAt = c.valor(.recordedAt, Date())
        initialRestVoltage = c.valor(.initialRestVoltage, 0)
        finalVoltage = c.valor(.finalVoltage, 0)
        minCrankingVoltage = c.valorOpcional(.minCrankingVoltage)
        socPercent = c.valor(.socPercent, 0)
        healthTitle = c.valor(.healthTitle, "")
    }
}

public struct TelemetrySnapshot: Codable, Equatable, Sendable {
    public var timestamp: Date = Date()
    public var coolantTempC: Double?              // PID 01 05
    public var rpm: Double?                       // PID 01 0C
    public var speedKmh: Double?                  // PID 01 0D
    public var mapKpa: Double?                    // PID 01 0B
    public var intakeAirTempC: Double?            // PID 01 0F
    public var shortFuelTrimPct: Double?          // PID 01 06
    public var longFuelTrimPct: Double?           // PID 01 07
    public var engineLoadPct: Double?             // PID 01 04
    public var throttlePositionPct: Double?       // PID 01 11
    public var mafGramsPerSec: Double?            // PID 01 10
    public var ethanolFuelPct: Double?            // PID 01 52 (só quando a ECU informa)
    public var batteryVoltage: Double?            // AT RV / PID 01 42
    public var transmissionTempC: Double?         // TCU UDS 22 0B 37 / TCM
    /// `true` quando a leitura do câmbio é fisicamente impossível para o estado do motor (ex.: motor frio
    /// e câmbio muito mais quente). Nesse caso o valor é descartado em vez de virar alarme falso.
    public var transmissionTempSuspect: Bool = false
    public var tcuOdometerKm: Double?             // TCU UDS 22 0B 5B
    public var ambientTempC: Double?              // PID 01 46 / HVAC UDS
    public var fuelRateLitersPerHour: Double?     // Real-time fuel flow (L/h)
    public var instantKmPerLiter: Double?         // Real-time efficiency (km/L)
    /// `true` quando o motor está em corte de injeção (pé fora do acelerador em movimento):
    /// o consumo real é zero e o km/L não tem valor numérico honesto para mostrar.
    public var isFuelCut: Bool = false
    public var timingAdvanceDeg: Double?          // PID 01 0E
    public var barometricPressureKpa: Double?     // PID 01 33
    public var fuelTankLevelPct: Double?          // PID 01 2F
    public var engineRunTimeSec: Int?             // PID 01 1F
    public var lambdaO2VoltageMv: Double?         // PID 01 14
    public var lambdaO2Sensor2Mv: Double?         // PID 01 15 (Pós-Catalisador)
    public var distanceSinceDTCClearKm: Double?   // PID 01 31
    public var distanceWithMILOnKm: Double?       // PID 01 21
    public var fuelRailPressureKpa: Double?       // PID 01 22 / 23
    public var commandedEvapPurgePct: Double?     // PID 01 2E
    public var warmUpsSinceDTCClear: Int?         // PID 01 30
    public var catalystTempB1S1C: Double?         // PID 01 3C
    public var ecuModuleVoltage: Double?          // PID 01 42
    public var absoluteLoadPct: Double?           // PID 01 43
    public var commandedLambdaRatio: Double?      // PID 01 44
    public var relativeThrottlePct: Double?       // PID 01 45
    public var acceleratorPedalDPct: Double?      // PID 01 49
    public var acceleratorPedalEPct: Double?      // PID 01 4A
    public var commandedThrottleActuatorPct: Double? // PID 01 4C
    public var timeWithMILOnMin: Int?             // PID 01 4D
    public var timeSinceDTCClearMin: Int?         // PID 01 4E
    public var engineOilTempC: Double?            // PID 01 5C
    public var sessionDistanceKm: Double = 0.0
    public var sessionFuelLiters: Double = 0.0
    public var pollRateHz: Double = 0.0

    public init() {}

    /// Fluxo de massa de ar efetivo em g/s (usa MAF direto PID 01 10 ou cálculo Speed-Density via MAP + IAT + RPM).
    public var effectiveAirFlowGramsPerSec: Double? {
        if let maf = mafGramsPerSec, maf > 0.1 {
            return maf
        }
        guard let rpm = rpm, rpm > 250, let map = mapKpa else { return nil }
        let iatC = intakeAirTempC ?? 35.0
        let tempKelvin = max(220.0, iatC + 273.15)
        let volumetricEfficiency = 0.82
        let imap = (rpm * map) / (tempKelvin * 2.0)
        return (imap / 60.0) * volumetricEfficiency * 1.498 * 3.484
    }

    /// Potência instantânea estimada em cv a partir do fluxo de massa de ar admitido.
    public var estimatedPowerHp: Double? {
        guard let airFlow = effectiveAirFlowGramsPerSec, (rpm ?? 0) > 400 else { return nil }
        let loadFactor = max(0.35, min(1.15, (engineLoadPct ?? 50.0) / 85.0))
        return max(1.0, airFlow * 1.28 * loadFactor)
    }

    /// Torque instantâneo estimado em Nm a partir da potência instantânea e RPM.
    public var estimatedTorqueNm: Double? {
        guard let hp = estimatedPowerHp, let r = rpm, r > 500 else { return nil }
        let kw = hp * 0.7355
        return (kw * 9549.0) / r
    }

    public var estimatedBoostBar: Double? {
        guard let map = mapKpa else { return nil }
        return (map - 98.0) / 100.0
    }

    public var sessionAverageKmPerLiter: Double? {
        guard sessionFuelLiters > 0.005, sessionDistanceKm > 0.05 else { return nil }
        return sessionDistanceKm / sessionFuelLiters
    }

    /// Temperatura externa real disponível: prioriza `PID 01 46` / HVAC e usa `PID 01 0F` (Admissão IAT) quando a ECU não expõe `01 46` (comum em várias ECUs).
    public var effectiveExternalTempC: Double? {
        if let amb = ambientTempC { return amb }
        if let iat = intakeAirTempC {
            // Com o carro em movimento ou motor recém-ligado, o IAT reflete o ar aspirado; desconta o aquecimento radiante do cofre quando parado.
            let isMoving = (speedKmh ?? 0) >= 15.0
            let coolant = coolantTempC ?? 40.0
            if coolant < 65.0 {
                return iat
            }
            return isMoving ? max(5.0, iat - 4.0) : max(5.0, iat - 8.0)
        }
        return nil
    }

    public var externalTempSourceLabel: String {
        if ambientTempC != nil { return "Sensor 01 46" }
        if intakeAirTempC != nil { return "Via Admissão (01 0F)" }
        return "Aguardando leitura"
    }

    /// Avaliação precisa da temperatura do fluido do câmbio CVT com base nas especificações oficiais da montadora.
    public func transmissionHealthAssessment(with customThresholds: TransmissionThermalThresholds? = nil) -> (statusTitle: String, detailText: String, level: HealthLevel) {
        guard let cvtC = transmissionTempC else {
            if transmissionTempSuspect {
                return ("Leitura suspeita do câmbio",
                        "O módulo devolveu uma temperatura incompatível com o motor (frio × câmbio quente). O valor foi descartado para não dar alarme falso; a decodificação está em validação.",
                        .unknown)
            }
            return ("Lendo TCU...", "Monitorando fluido do câmbio via UDS 22 0B 37.", .unknown)
        }
        let t = customThresholds ?? VehicleBrandProfile.autoDetect.thermalThresholds.transmission

        if cvtC >= t.criticalDTCThresholdC {
            return (
                "Alerta Térmico Crítico",
                String(format: "Fluido %@ em %.0f°C! Acima do limite crítico (≥%.0f°C). Risco de DTC P0218 e proteção do câmbio.", t.transmissionName, cvtC, t.criticalDTCThresholdC),
                .critical
            )
        } else if cvtC >= max(t.thermalInterventionC + 5.0, 120.0) {
            return (
                "Atenção: Temperatura Alta no Câmbio",
                String(format: "Fluido %@ em %.0f°C (aviso a partir de %.0f°C; DTC a %.0f°C). Se persistir em uso leve, mande conferir nível e estado do fluido.", t.transmissionName, cvtC, max(t.thermalInterventionC + 5.0, 120.0), t.criticalDTCThresholdC),
                .attention
            )
        } else if cvtC >= t.warmUpThresholdC {
            let loadSuffix = cvtC > t.nominalMaxC ? " sob carga de rodovia" : " ideal"
            return (
                "Temperatura Normal de Operação",
                String(format: "Fluido %@ em %.0f°C. Faixa nominal e de trabalho%@ (%.0f°C a %.0f°C). Ref: %@", t.transmissionName, cvtC, loadSuffix, t.warmUpThresholdC, t.heavyLoadNormalMaxC, t.officialEngineeringReference),
                .healthy
            )
        } else {
            return (
                "Fase de Aquecimento Normal",
                String(format: "Fluido %@ em %.0f°C (<%.0f°C). O trocador de calor aquece o óleo intencionalmente para viscosidade ideal.", t.transmissionName, cvtC, t.warmUpThresholdC),
                .healthy
            )
        }
    }

    public var transmissionHealthAssessment: (statusTitle: String, detailText: String, level: HealthLevel) {
        transmissionHealthAssessment(with: nil)
    }

    /// Estado de carga estimado da bateria 12V e saúde elétrica em tempo real (via Pino 16 `AT RV`).
    public var batteryHealthAssessment: (stateTitle: String, socPercent: Int, level: HealthLevel, standbySafeDays: Int, detailText: String) {
        guard let v = batteryVoltage, v.isFinite else {
            return (
                "Aguardando Leitura 12V",
                85,
                .unknown,
                45,
                "Conecte ao vLinker MC+ para medir a tensão da bateria e do alternador em tempo real."
            )
        }
        let engineRunning = (rpm ?? 0) > 400
        if engineRunning {
            if v >= 13.5 && v <= 14.8 {
                return (
                    "Alternador Carregando Normal",
                    100,
                    .healthy,
                    50,
                    String(format: "Tensão em %.2fV com motor ligado: regulador de tensão e alternador operando em faixa ideal (13,5V–14,8V).", v)
                )
            } else if v > 14.8 {
                return (
                    "Alerta: Sobretensão no Alternador",
                    100,
                    .critical,
                    30,
                    String(format: "Tensão elevada (%.2fV > 14,8V). Verifique o regulador de tensão do alternador.", v)
                )
            } else if v < 13.2 {
                return (
                    "Atenção: Alternador Abaixo do Ideal",
                    65,
                    .attention,
                    25,
                    String(format: "Motor ligado mas tensão em %.2fV (< 13,2V). Verifique se o alternador está carregando adequadamente.", v)
                )
            } else {
                // 13,2–13,5 V: faixa comum logo após a partida ou com carga elétrica alta. Não é sobretensão.
                return (
                    "Alternador Carregando (Tensão de Transição)",
                    90,
                    .attention,
                    40,
                    String(format: "Tensão em %.2fV com motor ligado: logo acima do mínimo de 13,2V. Normal após a partida ou com faróis/ventoinha ligados; se permanecer assim, confira a correia e o alternador.", v)
                )
            }
        } else {
            // Motor desligado (KOEO / Repouso) — estima SoC de bateria chumbo-ácido/EFB 12V
            let clamped = min(max(v, 11.5), 12.75)
            let soc = Int(((clamped - 11.5) / 1.25) * 100.0)
            // vLinker MC+ em sleep mode (< 3 mA = ~0,065 Ah/dia). Reserva segura de 25 Ah em bateria de 60 Ah:
            let availableAh = max(5.0, 30.0 * (Double(soc) / 100.0))
            let safeDays = max(3, Int(availableAh / 0.068))
            if v >= 12.4 {
                return (
                    "Bateria 12V Saudável (Cheia)",
                    max(80, soc),
                    .healthy,
                    min(60, safeDays),
                    String(format: "Tensão em repouso de %.2fV (~%d%% de carga). Excelente reserva de energia.", v, max(80, soc))
                )
            } else if v >= 12.0 {
                return (
                    "Bateria 12V em Meia-Vida / Carga Média",
                    max(45, soc),
                    .attention,
                    min(30, safeDays),
                    String(format: "Tensão em repouso de %.2fV (~%d%% de carga). Recomendado fazer o Teste de Partida de 10s abaixo.", v, max(45, soc))
                )
            } else {
                return (
                    "Alerta: Bateria 12V Fraca (< 12,0V)",
                    max(15, soc),
                    .critical,
                    min(7, safeDays),
                    String(format: "Tensão baixa em repouso (%.2fV). Dê partida para carregar pelo alternador e teste a queda de tensão.", v)
                )
            }
        }
    }
}

// MARK: - Cranking Battery Health Test

public struct CrankingBatteryTest: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var restingVoltage: Double
    public var minCrankingVoltage: Double
    public var chargingVoltage: Double
    public var healthLevel: HealthLevel
    public var senseiVerdict: String

    public init(
        timestamp: Date = Date(),
        restingVoltage: Double,
        minCrankingVoltage: Double,
        chargingVoltage: Double,
        healthLevel: HealthLevel,
        senseiVerdict: String
    ) {
        self.timestamp = timestamp
        self.restingVoltage = restingVoltage
        self.minCrankingVoltage = minCrankingVoltage
        self.chargingVoltage = chargingVoltage
        self.healthLevel = healthLevel
        self.senseiVerdict = senseiVerdict
    }
}

// MARK: - Decoded UDS Snapshot Occurrence

public struct UDSSnapshotOccurrence: Identifiable, Codable, Equatable, Sendable {
    public var id: Int { recordNumber }
    public let recordNumber: Int
    public let odometerKm: Double?            // DID 0B 5B
    public let transmissionTempC: Double?     // DID 0B 37
    public let coolantTempC: Double?          // DID 0B 2F
    public let vehicleSpeedKmh: Double?       // DID 0B 33
    public let operatingCycles: Int?          // DID 0B 5A

    public init(
        recordNumber: Int,
        odometerKm: Double?,
        transmissionTempC: Double?,
        coolantTempC: Double?,
        vehicleSpeedKmh: Double?,
        operatingCycles: Int? = nil
    ) {
        self.recordNumber = recordNumber
        self.odometerKm = odometerKm
        self.transmissionTempC = transmissionTempC
        self.coolantTempC = coolantTempC
        self.vehicleSpeedKmh = vehicleSpeedKmh
        self.operatingCycles = operatingCycles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recordNumber = c.valor(.recordNumber, 0)
        odometerKm = c.valorOpcional(.odometerKm)
        transmissionTempC = c.valorOpcional(.transmissionTempC)
        coolantTempC = c.valorOpcional(.coolantTempC)
        vehicleSpeedKmh = c.valorOpcional(.vehicleSpeedKmh)
        operatingCycles = c.valorOpcional(.operatingCycles)
    }
}

// MARK: - Diagnostic Fault (Customer Simple View + Mechanic Technical View)

public enum FaultUrgency: String, Codable, Sendable {
    case safeToDrive = "Pode Continuar Rodando"
    case attentionSoon = "Revisar em Breve"
    case stopImmediately = "Pare Imediatamente"
    case historicalObservation = "Aviso Antigo (Inativo)"

    public init(from decoder: Decoder) throws {
        let bruto = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = Self(rawValue: bruto) ?? .historicalObservation
    }
}

public struct FreezeFrameSnapshot: Codable, Equatable, Sendable {
    public var capturedAt: Date
    public var dtcCode: String
    public var rpm: Double?
    public var speedKmh: Double?
    public var coolantTempC: Double?
    public var engineLoadPct: Double?
    public var snapshotOdometerKm: Double?
    public var rawUDSHex: String?
    public var occurrences: [UDSSnapshotOccurrence]?

    public init(
        capturedAt: Date = Date(),
        dtcCode: String,
        rpm: Double? = nil,
        speedKmh: Double? = nil,
        coolantTempC: Double? = nil,
        engineLoadPct: Double? = nil,
        snapshotOdometerKm: Double? = nil,
        rawUDSHex: String? = nil,
        occurrences: [UDSSnapshotOccurrence]? = nil
    ) {
        self.capturedAt = capturedAt
        self.dtcCode = dtcCode
        self.rpm = rpm
        self.speedKmh = speedKmh
        self.coolantTempC = coolantTempC
        self.engineLoadPct = engineLoadPct
        self.snapshotOdometerKm = snapshotOdometerKm
        self.rawUDSHex = rawUDSHex
        self.occurrences = occurrences
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        capturedAt = c.valor(.capturedAt, Date())
        dtcCode = c.valor(.dtcCode, "")
        rpm = c.valorOpcional(.rpm)
        speedKmh = c.valorOpcional(.speedKmh)
        coolantTempC = c.valorOpcional(.coolantTempC)
        engineLoadPct = c.valorOpcional(.engineLoadPct)
        snapshotOdometerKm = c.valorOpcional(.snapshotOdometerKm)
        rawUDSHex = c.valorOpcional(.rawUDSHex)
        occurrences = c.valorOpcional(.occurrences)
    }
}

public struct SenseiMechanicalInterpretation: Codable, Equatable, Sendable {
    // Mechanic / Technical View Fields
    public let headline: String
    public let plainExplanation: String
    public let vehicleContext: String
    public let probableCauses: [String]
    public let falsePositiveWarning: String?
    public let recommendedAction: String
    public let urgency: FaultUrgency

    // Customer / Simple View Fields (Optional with automatic human-friendly fallback for backwards compatibility)
    public let customerCanDriveBanner: String?
    public let customerSimpleStory: String?
    public let customerWorkshopProtectionTip: String?

    public var resolvedCustomerBanner: String {
        if let customerCanDriveBanner { return customerCanDriveBanner }
        switch urgency {
        case .safeToDrive, .historicalObservation:
            return "✅ Pode dirigir tranquilo! Não há defeito ativo agora."
        case .attentionSoon:
            return "⚠️ Você pode rodar com cautela, mas agende uma revisão em breve."
        case .stopImmediately:
            return "🛑 Pare o carro em local seguro assim que possível!"
        }
    }

    public var resolvedCustomerStory: String {
        customerSimpleStory ?? plainExplanation
    }

    public var resolvedWorkshopTip: String {
        customerWorkshopProtectionTip ?? (falsePositiveWarning ?? recommendedAction)
    }

    public init(
        headline: String,
        plainExplanation: String,
        vehicleContext: String,
        probableCauses: [String],
        falsePositiveWarning: String? = nil,
        recommendedAction: String,
        urgency: FaultUrgency,
        customerCanDriveBanner: String? = nil,
        customerSimpleStory: String? = nil,
        customerWorkshopProtectionTip: String? = nil
    ) {
        self.headline = headline
        self.plainExplanation = plainExplanation
        self.vehicleContext = vehicleContext
        self.probableCauses = probableCauses
        self.falsePositiveWarning = falsePositiveWarning
        self.recommendedAction = recommendedAction
        self.urgency = urgency
        self.customerCanDriveBanner = customerCanDriveBanner
        self.customerSimpleStory = customerSimpleStory
        self.customerWorkshopProtectionTip = customerWorkshopProtectionTip
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        headline = c.valor(.headline, "Código registrado")
        plainExplanation = c.valor(.plainExplanation, "Explicação não gravada para este código.")
        vehicleContext = c.valor(.vehicleContext, "")
        probableCauses = c.valor(.probableCauses, [])
        falsePositiveWarning = c.valorOpcional(.falsePositiveWarning)
        recommendedAction = c.valor(.recommendedAction, "Refaça a varredura para atualizar a explicação.")
        urgency = c.valor(.urgency, .historicalObservation)
        customerCanDriveBanner = c.valorOpcional(.customerCanDriveBanner)
        customerSimpleStory = c.valorOpcional(.customerSimpleStory)
        customerWorkshopProtectionTip = c.valorOpcional(.customerWorkshopProtectionTip)
    }
}

public struct DiagnosticFault: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public let baseCode: String
    public let failureTypeByteHex: String?
    public let failureTypeDescription: String?
    public let moduleCode: String
    public let moduleName: String
    public let statusMaskHex: String?
    public let isActiveNow: Bool
    public let isConfirmed: Bool
    public let failedSinceLastClear: Bool
    public let notCompletedThisCycle: Bool
    public let rawDTCBytesHex: String
    public let interpretation: SenseiMechanicalInterpretation
    public var freezeFrame: FreezeFrameSnapshot?
    public var vehicleVIN: String?
    public var vehicleModel: String?

    public var displayCode: String {
        if let ftb = failureTypeByteHex {
            return "\(baseCode)(\(ftb))"
        }
        return baseCode
    }

    public var statusSummaryPt: String {
        if isActiveNow {
            return "ATIVO AGORA"
        }
        var parts: [String] = ["Memória Histórica (Inativo)"]
        if isConfirmed { parts.append("Confirmado") }
        if failedSinceLastClear { parts.append("Ocorreu desde a última limpeza") }
        return parts.joined(separator: " • ")
    }

    public init(
        baseCode: String,
        failureTypeByteHex: String? = nil,
        failureTypeDescription: String? = nil,
        moduleCode: String,
        moduleName: String,
        statusMaskHex: String? = nil,
        isActiveNow: Bool,
        isConfirmed: Bool,
        failedSinceLastClear: Bool = false,
        notCompletedThisCycle: Bool = false,
        rawDTCBytesHex: String,
        interpretation: SenseiMechanicalInterpretation,
        freezeFrame: FreezeFrameSnapshot? = nil,
        vehicleVIN: String? = nil,
        vehicleModel: String? = nil
    ) {
        let vinPrefix = (vehicleVIN?.count == 17) ? "\(vehicleVIN!)-" : ""
        self.id = "\(vinPrefix)\(moduleCode)-\(baseCode)-\(failureTypeByteHex ?? "00")"
        self.baseCode = baseCode
        self.failureTypeByteHex = failureTypeByteHex
        self.failureTypeDescription = failureTypeDescription
        self.moduleCode = moduleCode
        self.moduleName = moduleName
        self.statusMaskHex = statusMaskHex
        self.isActiveNow = isActiveNow
        self.isConfirmed = isConfirmed
        self.failedSinceLastClear = failedSinceLastClear
        self.notCompletedThisCycle = notCompletedThisCycle
        self.rawDTCBytesHex = rawDTCBytesHex
        self.interpretation = interpretation
        self.freezeFrame = freezeFrame
        self.vehicleVIN = vehicleVIN
        self.vehicleModel = vehicleModel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let modulo = c.valor(.moduleCode, "ECM")
        // Sem código-base não é uma falha: lançar aqui faz o registro inválido ser descartado
        // (o invólucro tolerante descarta só o item), em vez de virar um DTC P0000 fantasma.
        let base = try c.decode(String.self, forKey: .baseCode)
        let ftb: String? = c.valorOpcional(.failureTypeByteHex)
        let vVin: String? = c.valorOpcional(.vehicleVIN)
        let vModel: String? = c.valorOpcional(.vehicleModel)
        baseCode = base
        failureTypeByteHex = ftb
        moduleCode = modulo
        vehicleVIN = vVin
        vehicleModel = vModel
        let vinPrefix = (vVin?.count == 17) ? "\(vVin!)-" : ""
        id = c.valor(.id, "\(vinPrefix)\(modulo)-\(base)-\(ftb ?? "00")")
        failureTypeDescription = c.valorOpcional(.failureTypeDescription)
        moduleName = c.valor(.moduleName, "Injeção Eletrônica")
        statusMaskHex = c.valorOpcional(.statusMaskHex)
        isActiveNow = c.valor(.isActiveNow, false)
        isConfirmed = c.valor(.isConfirmed, false)
        failedSinceLastClear = c.valor(.failedSinceLastClear, false)
        notCompletedThisCycle = c.valor(.notCompletedThisCycle, false)
        rawDTCBytesHex = c.valor(.rawDTCBytesHex, "")
        freezeFrame = c.valorOpcional(.freezeFrame)
        // A explicação é regravada pela base de conhecimento ao carregar; aqui só não pode derrubar o histórico.
        interpretation = c.valor(.interpretation, SenseiMechanicalInterpretation(
            headline: "Falha \(base)",
            plainExplanation: "Este código foi salvo por uma versão anterior do app. Toque em Escanear Veículo para atualizar a explicação.",
            vehicleContext: "",
            probableCauses: [],
            recommendedAction: "Refaça a varredura para atualizar a explicação.",
            urgency: .historicalObservation
        ))
    }
}

// MARK: - Odometer Tampering Forensics Models

public enum OdometerIntegrityVerdict: String, Codable, Sendable {
    /// Odômetro independente (TCU) bate com o painel e nenhuma outra prova reprovou.
    case verifiedIntact = "KM consistente com os módulos"
    /// Só provas de limite mínimo passaram (snapshot, distância desde a limpeza): sem indício, mas sem odômetro independente.
    case noEvidenceFound = "Sem indícios de adulteração (verificação parcial)"
    case suspiciousDiscrepancy = "Atenção: divergência entre módulos"
    /// Algum módulo registrou mais KM do que o painel mostra: painel reduzido ou módulo trocado.
    case tamperingConfirmed = "Alerta: módulo registra mais KM que o painel"
    /// Nenhuma prova de quilometragem respondeu.
    case inconclusive = "Inconclusivo: módulos não responderam"
    case awaitingScan = "Pronto para auditar"

    public init(from decoder: Decoder) throws {
        let bruto = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = Self(rawValue: bruto) ?? .inconclusive
    }

    /// Só aprova com odômetro independente; sem nenhuma prova lida, nunca aprova.
    public static func decide(critical: Bool, attention: Bool, tcuMatchesCluster: Bool, proofsRead: Int) -> Self {
        if critical { return .tamperingConfirmed }
        if attention { return .suspiciousDiscrepancy }
        if tcuMatchesCluster { return .verifiedIntact }
        return proofsRead > 0 ? .noEvidenceFound : .inconclusive
    }
}

public struct OdometerEvidenceItem: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let sourceModule: String
    public let checkTitle: String
    public let commandSent: String
    public let rawHexResponse: String
    public let measuredValueText: String
    public let numericKmValue: Double?
    public let status: HealthLevel
    public let forensicAnalysis: String

    public init(
        id: String = UUID().uuidString,
        sourceModule: String,
        checkTitle: String,
        commandSent: String,
        rawHexResponse: String,
        measuredValueText: String,
        numericKmValue: Double? = nil,
        status: HealthLevel,
        forensicAnalysis: String
    ) {
        self.id = id
        self.sourceModule = sourceModule
        self.checkTitle = checkTitle
        self.commandSent = commandSent
        self.rawHexResponse = rawHexResponse
        self.measuredValueText = measuredValueText
        self.numericKmValue = numericKmValue
        self.status = status
        self.forensicAnalysis = forensicAnalysis
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.valor(.id, UUID().uuidString)
        sourceModule = c.valor(.sourceModule, "")
        // Prova sem título não é prova: o item é descartado em vez de poluir o laudo.
        checkTitle = try c.decode(String.self, forKey: .checkTitle)
        commandSent = c.valor(.commandSent, "")
        rawHexResponse = c.valor(.rawHexResponse, "")
        measuredValueText = c.valor(.measuredValueText, "")
        numericKmValue = c.valorOpcional(.numericKmValue)
        status = c.valor(.status, .unknown)
        forensicAnalysis = c.valor(.forensicAnalysis, "")
    }
}

public struct OdometerAuditReport: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var clusterEnteredKm: Double
    public var verdict: OdometerIntegrityVerdict
    public var summaryExplanation: String
    public var evidences: [OdometerEvidenceItem]
    public var vinConsistencyPassed: Bool
    public var highestRecordedKmAcrossECUs: Double?

    public init(
        timestamp: Date = Date(),
        clusterEnteredKm: Double,
        verdict: OdometerIntegrityVerdict,
        summaryExplanation: String,
        evidences: [OdometerEvidenceItem],
        vinConsistencyPassed: Bool,
        highestRecordedKmAcrossECUs: Double? = nil
    ) {
        self.timestamp = timestamp
        self.clusterEnteredKm = clusterEnteredKm
        self.verdict = verdict
        self.summaryExplanation = summaryExplanation
        self.evidences = evidences
        self.vinConsistencyPassed = vinConsistencyPassed
        self.highestRecordedKmAcrossECUs = highestRecordedKmAcrossECUs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = c.valor(.timestamp, Date())
        clusterEnteredKm = c.valor(.clusterEnteredKm, 0)
        verdict = c.valor(.verdict, .awaitingScan)
        summaryExplanation = c.valor(.summaryExplanation, "")
        // Um item de prova corrompido não pode apagar o laudo inteiro: só ele sai da lista.
        evidences = c.lista(.evidences)
        vinConsistencyPassed = c.valor(.vinConsistencyPassed, false)
        highestRecordedKmAcrossECUs = c.valorOpcional(.highestRecordedKmAcrossECUs)
    }
}

// MARK: - CAN Bus Discovery & Command Log

public struct CommandTraceEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let command: String
    public let response: String
    public let durationMs: Int

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        command: String,
        response: String,
        durationMs: Int
    ) {
        self.id = id
        self.timestamp = timestamp
        self.command = command
        self.response = response
        self.durationMs = durationMs
    }
}

// MARK: - Decodificação tolerante dos dados salvos no aparelho
//
// Viagens, falhas, laudo de KM e garagem são gravados com `JSONEncoder` em `UserDefaults` e
// relidos com `try?`. Com o `init(from:)` sintetizado, um campo novo no modelo (ou um texto de enum alterado)
// fazia o decode do array inteiro falhar — e o histórico do usuário desaparecia sem aviso, porque o `try?`
// devolvia `nil` e o app recomeçava vazio. Estes helpers trocam o campo ausente/inválido pelo padrão.

extension KeyedDecodingContainer {
    /// Valor obrigatório com fallback: ausente, com tipo errado ou não decodificável vira `padrao`.
    func valor<T: Decodable>(_ chave: Key, _ padrao: T) -> T {
        (try? decodeIfPresent(T.self, forKey: chave)) ?? padrao
    }

    /// Valor opcional com fallback: ausente vira `nil` em vez de derrubar o registro.
    func valorOpcional<T: Decodable>(_ chave: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: chave)) ?? nil
    }

    /// Lista tolerante: descarta apenas os elementos que não decodificam, preservando o resto.
    func lista<T: Decodable>(_ chave: Key) -> [T] {
        guard let brutos = try? decodeIfPresent([DecodificavelTolerante<T>].self, forKey: chave) ?? [] else { return [] }
        return brutos.compactMap { $0.valor }
    }
}

/// Envelope que transforma falha de decode em `nil` em vez de exceção.
struct DecodificavelTolerante<T: Decodable>: Decodable {
    let valor: T?

    init(from decoder: Decoder) throws {
        valor = try? T(from: decoder)
    }
}

// MARK: - Análise de Sensores da Viagem em Tempo Real & Laudo para Leigos e Mecânicos

public struct TripSensorLiveStat: Identifiable, Codable, Equatable, Sendable {
    public var id: String { gauge.rawValue }
    public let gauge: CockpitGaugeID
    public var minValue: Double
    public var maxValue: Double
    public var sumValue: Double
    public var lastValue: Double
    public var sampleCount: Int

    public var avgValue: Double {
        sampleCount > 0 ? (sumValue / Double(sampleCount)) : lastValue
    }

    public init(
        gauge: CockpitGaugeID,
        minValue: Double,
        maxValue: Double,
        sumValue: Double,
        lastValue: Double,
        sampleCount: Int
    ) {
        self.gauge = gauge
        self.minValue = minValue
        self.maxValue = maxValue
        self.sumValue = sumValue
        self.lastValue = lastValue
        self.sampleCount = sampleCount
    }

    public mutating func record(_ value: Double) {
        guard value.isFinite else { return }
        if sampleCount == 0 {
            minValue = value
            maxValue = value
            sumValue = value
            lastValue = value
            sampleCount = 1
        } else {
            minValue = min(minValue, value)
            maxValue = max(maxValue, value)
            sumValue += value
            lastValue = value
            sampleCount += 1
        }
    }
}

public struct TripSensorEvaluationItem: Identifiable, Codable, Equatable, Sendable {
    public var id: String { gauge.rawValue }
    public let gauge: CockpitGaugeID
    public let minValue: Double
    public let avgValue: Double
    public let maxValue: Double
    public let lastValue: Double
    public let unit: String
    public let sampleCount: Int
    /// Faixa de referência calculada dinamicamente a partir do perfil e sensores base do veículo selecionado.
    public let expectedRangeText: String
    public let healthLevel: HealthLevel
    public let statusBadgeTitle: String
    /// Explicação simples para leigos: o que é este sensor no dia a dia.
    public let laypersonWhatItIs: String
    /// Explicação simples para leigos: como ele se comportou durante esta viagem.
    public let laypersonTripVerdict: String
    /// Orientação prática para o motorista (se está tudo ótimo ou o que observar).
    public let laypersonPracticalAdvice: String
    /// Resumo técnico para mecânicos (PID, amostras, referência de engenharia do veículo).
    public let technicalSummary: String

    public init(
        gauge: CockpitGaugeID,
        minValue: Double,
        avgValue: Double,
        maxValue: Double,
        lastValue: Double,
        unit: String,
        sampleCount: Int,
        expectedRangeText: String,
        healthLevel: HealthLevel,
        statusBadgeTitle: String,
        laypersonWhatItIs: String,
        laypersonTripVerdict: String,
        laypersonPracticalAdvice: String,
        technicalSummary: String
    ) {
        self.gauge = gauge
        self.minValue = minValue
        self.avgValue = avgValue
        self.maxValue = maxValue
        self.lastValue = lastValue
        self.unit = unit
        self.sampleCount = sampleCount
        self.expectedRangeText = expectedRangeText
        self.healthLevel = healthLevel
        self.statusBadgeTitle = statusBadgeTitle
        self.laypersonWhatItIs = laypersonWhatItIs
        self.laypersonTripVerdict = laypersonTripVerdict
        self.laypersonPracticalAdvice = laypersonPracticalAdvice
        self.technicalSummary = technicalSummary
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gauge = c.valor(.gauge, .coolantTemp)
        minValue = c.valor(.minValue, 0)
        avgValue = c.valor(.avgValue, 0)
        maxValue = c.valor(.maxValue, 0)
        lastValue = c.valor(.lastValue, 0)
        unit = c.valor(.unit, "")
        sampleCount = c.valor(.sampleCount, 1)
        expectedRangeText = c.valor(.expectedRangeText, "--")
        healthLevel = c.valor(.healthLevel, .healthy)
        statusBadgeTitle = c.valor(.statusBadgeTitle, "Bom")
        laypersonWhatItIs = c.valor(.laypersonWhatItIs, "")
        laypersonTripVerdict = c.valor(.laypersonTripVerdict, "")
        laypersonPracticalAdvice = c.valor(.laypersonPracticalAdvice, "")
        technicalSummary = c.valor(.technicalSummary, "")
    }
}

public struct TripSensorAnalysisReport: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let startDate: Date
    public let endDate: Date
    public let durationSeconds: Double
    public let finishReason: String
    public let vehicleModel: String
    public let vehicleVIN: String
    public let engineDescription: String
    public let transmissionDescription: String
    public let fuelProfileTitle: String
    public let supportedPIDsCount: Int
    public let distanceKm: Double
    public let fuelUsedLiters: Double
    public let avgKmPerLiter: Double?
    public let maxSpeedKmh: Double?
    public let overallHealth: HealthLevel
    public let overallScorePercent: Int
    public let laypersonHeadline: String
    public let laypersonOverview: String
    public let items: [TripSensorEvaluationItem]

    public init(
        id: UUID = UUID(),
        startDate: Date,
        endDate: Date = Date(),
        durationSeconds: Double,
        finishReason: String,
        vehicleModel: String,
        vehicleVIN: String,
        engineDescription: String,
        transmissionDescription: String,
        fuelProfileTitle: String,
        supportedPIDsCount: Int,
        distanceKm: Double,
        fuelUsedLiters: Double,
        avgKmPerLiter: Double?,
        maxSpeedKmh: Double?,
        overallHealth: HealthLevel,
        overallScorePercent: Int,
        laypersonHeadline: String,
        laypersonOverview: String,
        items: [TripSensorEvaluationItem]
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.durationSeconds = durationSeconds
        self.finishReason = finishReason
        self.vehicleModel = vehicleModel
        self.vehicleVIN = vehicleVIN
        self.engineDescription = engineDescription
        self.transmissionDescription = transmissionDescription
        self.fuelProfileTitle = fuelProfileTitle
        self.supportedPIDsCount = supportedPIDsCount
        self.distanceKm = distanceKm
        self.fuelUsedLiters = fuelUsedLiters
        self.avgKmPerLiter = avgKmPerLiter
        self.maxSpeedKmh = maxSpeedKmh
        self.overallHealth = overallHealth
        self.overallScorePercent = overallScorePercent
        self.laypersonHeadline = laypersonHeadline
        self.laypersonOverview = laypersonOverview
        self.items = items
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let inicio = c.valor(.startDate, Date())
        id = c.valor(.id, UUID())
        startDate = inicio
        endDate = c.valor(.endDate, inicio)
        durationSeconds = c.valor(.durationSeconds, 0)
        finishReason = c.valor(.finishReason, "Viagem finalizada")
        vehicleModel = c.valor(.vehicleModel, "Veículo Conectado")
        vehicleVIN = c.valor(.vehicleVIN, "")
        engineDescription = c.valor(.engineDescription, "")
        transmissionDescription = c.valor(.transmissionDescription, "")
        fuelProfileTitle = c.valor(.fuelProfileTitle, "")
        supportedPIDsCount = c.valor(.supportedPIDsCount, 0)
        distanceKm = c.valor(.distanceKm, 0)
        fuelUsedLiters = c.valor(.fuelUsedLiters, 0)
        avgKmPerLiter = c.valorOpcional(.avgKmPerLiter)
        maxSpeedKmh = c.valorOpcional(.maxSpeedKmh)
        overallHealth = c.valor(.overallHealth, .healthy)
        overallScorePercent = c.valor(.overallScorePercent, 100)
        laypersonHeadline = c.valor(.laypersonHeadline, "")
        laypersonOverview = c.valor(.laypersonOverview, "")
        items = c.lista(.items)
    }
}
