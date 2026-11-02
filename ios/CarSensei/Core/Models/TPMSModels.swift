import Foundation

/// Posição da roda. A ordem de `allCases` é a de aprendizado usada pela maioria das ferramentas TPMS
/// (dianteira esquerda, dianteira direita, traseira direita, traseira esquerda) mais o estepe.
public enum WheelPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case frontLeft, frontRight, rearRight, rearLeft, spare

    public init(from decoder: Decoder) throws {
        let bruto = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = Self(rawValue: bruto) ?? .frontLeft
    }

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .frontLeft: return "Dianteiro Esquerdo"
        case .frontRight: return "Dianteiro Direito"
        case .rearRight: return "Traseiro Direito"
        case .rearLeft: return "Traseiro Esquerdo"
        case .spare: return "Estepe"
        }
    }

    public var shortLabel: String {
        switch self {
        case .frontLeft: return "DE"
        case .frontRight: return "DD"
        case .rearRight: return "TD"
        case .rearLeft: return "TE"
        case .spare: return "ESTP"
        }
    }

    /// As quatro rodas de rodagem (sem estepe), na ordem de aprendizado.
    public static let roadWheels: [WheelPosition] = [.frontLeft, .frontRight, .rearRight, .rearLeft]
}

/// Leitura de um pneu: o que o módulo TPMS do carro informa sobre aquela roda.
public struct TireReading: Identifiable, Codable, Equatable, Sendable {
    public var id: String { position.rawValue }
    public let position: WheelPosition
    public var pressureKpa: Double?
    public var temperatureC: Double?
    /// ID do sensor gravado no módulo para esta roda (hex), quando o carro o expõe.
    public var sensorIdHex: String?
    /// `true` quando o módulo marca o sensor como ausente / sem comunicação nesta roda.
    public var sensorMissing: Bool
    public var lowBattery: Bool

    public init(
        position: WheelPosition,
        pressureKpa: Double? = nil,
        temperatureC: Double? = nil,
        sensorIdHex: String? = nil,
        sensorMissing: Bool = false,
        lowBattery: Bool = false
    ) {
        self.position = position
        self.pressureKpa = pressureKpa
        self.temperatureC = temperatureC
        self.sensorIdHex = sensorIdHex
        self.sensorMissing = sensorMissing
        self.lowBattery = lowBattery
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        position = c.valor(.position, .frontLeft)
        pressureKpa = c.valorOpcional(.pressureKpa)
        temperatureC = c.valorOpcional(.temperatureC)
        sensorIdHex = c.valorOpcional(.sensorIdHex)
        sensorMissing = c.valor(.sensorMissing, false)
        lowBattery = c.valor(.lowBattery, false)
    }

    public var pressureBar: Double? { pressureKpa.map { $0 / 100.0 } }
    public var pressurePsi: Double? { pressureKpa.map { $0 / 6.89476 } }

    /// Responde se o sensor está reportando algo plausível (pressão ou temperatura).
    public var isReporting: Bool {
        !sensorMissing && (pressureKpa != nil || temperatureC != nil || sensorIdHex != nil)
    }
}

/// Como o CarSensei conversou com o módulo TPMS desta vez.
public enum TPMSReadSource: String, Codable, Sendable {
    case standardOBD = "PID OBD-II padrão (01 2D)"
    case udsModule = "Módulo TPMS via UDS"
    case canBroadcast = "Quadro CAN do carro (barramento)"
    case none = "Sem leitura"

    public init(from decoder: Decoder) throws {
        let bruto = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = Self(rawValue: bruto) ?? .none
    }
}

/// Resultado de uma leitura de TPMS, montado a partir do que o carro realmente respondeu.
public struct TPMSSnapshot: Codable, Equatable, Sendable {
    public var tires: [TireReading]
    public var readAt: Date
    public var source: TPMSReadSource
    /// Endereço do módulo TPMS que respondeu (ex.: "7A8"), quando lido via UDS.
    public var moduleHeaderTx: String?
    public var moduleHeaderRx: String?
    /// Avisos/erros do sistema TPMS lidos como DTC (ex.: sensor com bateria fraca).
    public var systemWarnings: [String]

    public init(
        tires: [TireReading] = [],
        readAt: Date = Date(),
        source: TPMSReadSource = .none,
        moduleHeaderTx: String? = nil,
        moduleHeaderRx: String? = nil,
        systemWarnings: [String] = []
    ) {
        self.tires = tires
        self.readAt = readAt
        self.source = source
        self.moduleHeaderTx = moduleHeaderTx
        self.moduleHeaderRx = moduleHeaderRx
        self.systemWarnings = systemWarnings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tires = c.lista(.tires)
        readAt = c.valor(.readAt, Date())
        source = c.valor(.source, .none)
        moduleHeaderTx = c.valorOpcional(.moduleHeaderTx)
        moduleHeaderRx = c.valorOpcional(.moduleHeaderRx)
        systemWarnings = c.valor(.systemWarnings, [])
    }

    public var hasAnyReading: Bool { tires.contains { $0.isReporting } || !systemWarnings.isEmpty }
    public var reportingCount: Int { tires.filter { $0.isReporting }.count }
}

/// Um módulo candidato a ser o controlador de TPMS, descoberto no barramento.
public struct TPMSModuleCandidate: Identifiable, Codable, Equatable, Sendable {
    public var id: String { txHeader }
    public let txHeader: String
    public let rxHeader: String
    /// Nome/ID que o módulo retornou (22 F1 97 / F1 90), quando houver.
    public var identifier: String?
    /// DIDs (22 ...) que responderam com dados, para a tela técnica.
    public var respondingDIDs: [String]
    /// `true` quando algum DID deste módulo trouxe valores plausíveis de pressão.
    public var looksLikeTPMS: Bool

    public init(txHeader: String, rxHeader: String, identifier: String? = nil, respondingDIDs: [String] = [], looksLikeTPMS: Bool = false) {
        self.txHeader = txHeader
        self.rxHeader = rxHeader
        self.identifier = identifier
        self.respondingDIDs = respondingDIDs
        self.looksLikeTPMS = looksLikeTPMS
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Módulo sem endereço não serve para nada: o registro inválido é descartado.
        txHeader = try c.decode(String.self, forKey: .txHeader)
        rxHeader = c.valor(.rxHeader, "")
        identifier = c.valorOpcional(.identifier)
        respondingDIDs = c.valor(.respondingDIDs, [])
        looksLikeTPMS = c.valor(.looksLikeTPMS, false)
    }
}

/// Etapas do assistente de pareamento de sensores (gravar IDs novos no módulo do carro).
public enum TPMSPairingStage: String, Codable, Sendable {
    case idle
    case locatingModule          // achar o módulo TPMS no barramento
    case readingCurrentIDs       // ler os IDs atualmente gravados
    case openingSession          // sessão diagnóstica estendida (10 03)
    case securityAccess          // destravar (27), quando o módulo exige
    case writingIDs              // gravar os IDs novos (2E) ou rodar relearn (31)
    case verifying               // reler para confirmar
    case done
    case failed
}

/// Registro passo a passo do assistente de pareamento (tudo que foi enviado e recebido).
public struct TPMSPairingLogEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let command: String
    public let response: String
    public let interpretation: String
    public let success: Bool

    public init(command: String, response: String, interpretation: String, success: Bool) {
        self.id = UUID()
        self.timestamp = Date()
        self.command = command
        self.response = response
        self.interpretation = interpretation
        self.success = success
    }
}
