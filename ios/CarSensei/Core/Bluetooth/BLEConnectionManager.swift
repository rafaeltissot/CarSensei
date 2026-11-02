import Foundation
import CoreBluetooth

@MainActor
public final class BLEConnectionManager: NSObject, ObservableObject {
    @Published public private(set) var connectionState: BLEConnectionState = .disconnected
    @Published public private(set) var discoveredDevices: [DiscoveredBLEDevice] = []
    @Published public private(set) var connectedDeviceName: String?
    @Published public private(set) var statusDetail: String = "Toque em Conectar para buscar o vLinker MC-IOS"

    private var centralManager: CBCentralManager!
    private var activePeripheral: CBPeripheral?
    private var peripheralsById: [UUID: CBPeripheral] = [:]
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?

    private var responseBuffer: String = ""
    private var pendingContinuation: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?
    /// Depois de um timeout, o resto atrasado daquela resposta é descartado até o próximo `>`.
    private var discardUntilPrompt = false

    private var autoConnectOnDiscovery = false
    private var scanTimeoutTask: Task<Void, Never>?
    private var userRequestedDisconnect = false
    private var servicesAwaitingCharacteristics = 0
    private var transportReadyFired = false

    private let savedPeripheralKey = "carsensei.saved.vlinker.uuid"

    // Vgate vLinker MC-IOS / BLE UART known Service & Characteristic UUIDs
    private let knownServiceUUIDs: [CBUUID] = [
        CBUUID(string: "18F0"),
        CBUUID(string: "FFE0"),
        CBUUID(string: "FFF0"),
        CBUUID(string: "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2")
    ]

    public var onAdapterTransportReady: (() -> Void)?

    public override init() {
        super.init()
        self.centralManager = CBCentralManager(delegate: nil, queue: .main)
        self.centralManager.delegate = self
    }

    public func startScanning(autoConnectPreferred: Bool = true) {
        guard centralManager.state == .poweredOn else {
            connectionState = .bluetoothOff
            statusDetail = "Ative o Bluetooth do iPhone para conectar ao vLinker MC-IOS"
            return
        }

        discoveredDevices.removeAll()
        autoConnectOnDiscovery = autoConnectPreferred
        userRequestedDisconnect = false
        connectionState = .scanning
        statusDetail = "Buscando adaptador vLinker MC-IOS via Bluetooth LE..."

        // 1. Check already-connected peripherals exposing Vgate services
        let connected = centralManager.retrieveConnectedPeripherals(withServices: knownServiceUUIDs)
        for peripheral in connected {
            registerDiscovered(peripheral: peripheral, localName: peripheral.name, rssi: -45, autoConnect: autoConnectPreferred)
        }

        // 2. Check previously paired peripheral UUID
        if autoConnectPreferred,
           let savedString = UserDefaults.standard.string(forKey: savedPeripheralKey),
           let savedUUID = UUID(uuidString: savedString),
           let known = centralManager.retrievePeripherals(withIdentifiers: [savedUUID]).first {
            registerDiscovered(peripheral: known, localName: known.name ?? "vLinker MC-IOS", rssi: -50, autoConnect: true)
        }

        // 3. Scan all BLE peripherals (vLinker MC-IOS sometimes omits service UUIDs from advertisement packet)
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        // Scan sem filtro gasta bateria: encerra em 20 s se nada conectou.
        scanTimeoutTask?.cancel()
        scanTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, let self, self.connectionState == .scanning else { return }
            self.stopScanning()
            self.connectionState = .disconnected
            self.statusDetail = self.discoveredDevices.isEmpty
                ? "Nenhum adaptador encontrado. Confira se o vLinker está no conector OBD e a ignição ligada."
                : "Busca encerrada. Toque em um adaptador da lista para conectar."
        }
    }

    public func stopScanning() {
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        if centralManager.isScanning {
            centralManager.stopScan()
        }
    }

    public func connect(to deviceId: UUID) {
        guard let peripheral = peripheralsById[deviceId] else { return }
        stopScanning()
        userRequestedDisconnect = false
        activePeripheral = peripheral
        peripheral.delegate = self
        connectionState = .connecting
        statusDetail = "Conectando a \(peripheral.name ?? "vLinker MC-IOS")..."
        centralManager.connect(peripheral, options: nil)
    }

    public func disconnect() {
        stopScanning()
        userRequestedDisconnect = true
        failPendingCommand(message: "Desconectado")
        if let peripheral = activePeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        activePeripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        connectedDeviceName = nil
        connectionState = .disconnected
        statusDetail = "Desconectado do vLinker MC-IOS"
    }

    /// Sends an ASCII command terminated with `\r` and awaits the `>` prompt from vLinker MC+.
    public func sendRawCommand(_ command: String, timeoutSeconds: Double = 3.5) async throws -> String {
        guard let peripheral = activePeripheral,
              let writeChar = writeCharacteristic else {
            throw NSError(domain: "CarSensei.BLE", code: -1, userInfo: [NSLocalizedDescriptionKey: "vLinker MC-IOS não está conectado"])
        }

        // Cancel any stale continuation before issuing a new command
        if let stale = pendingContinuation {
            pendingContinuation = nil
            stale.resume(throwing: CancellationError())
        }
        timeoutTask?.cancel()
        // Resto atrasado de um comando que estourou o tempo: dá até 300 ms para o `>` chegar e ser descartado.
        if discardUntilPrompt {
            for _ in 0..<12 where discardUntilPrompt {
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            discardUntilPrompt = false
        }
        responseBuffer = ""

        let payloadString = command.hasSuffix("\r") ? command : "\(command)\r"
        guard let data = payloadString.data(using: .utf8) else {
            throw NSError(domain: "CarSensei.BLE", code: -2, userInfo: [NSLocalizedDescriptionKey: "Comando inválido"])
        }

        let writeType: CBCharacteristicWriteType = writeChar.properties.contains(.writeWithoutResponse)
            ? .withoutResponse
            : .withResponse

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            self.pendingContinuation = continuation

            self.timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                guard !Task.isCancelled, let self = self, let pending = self.pendingContinuation else { return }
                self.pendingContinuation = nil
                // Resposta sem o `>` final está incompleta: decodificar meio quadro gera valores errados.
                self.responseBuffer = ""
                self.discardUntilPrompt = true
                pending.resume(throwing: NSError(
                    domain: "CarSensei.BLE",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "Timeout aguardando resposta para \(command)"]
                ))
            }

            // Chunk write in 20-byte or MTU-safe slices if needed
            let mtu = max(20, peripheral.maximumWriteValueLength(for: writeType))
            var offset = 0
            while offset < data.count {
                let end = min(offset + mtu, data.count)
                let chunk = data.subdata(in: offset..<end)
                peripheral.writeValue(chunk, for: writeChar, type: writeType)
                offset = end
            }
        }
    }

    /// Executa um comando de escuta passiva (`STM` ou `AT MA`) por `durationSeconds`, envia `\r` para encerrar
    /// a escuta no chip STN/ELM e devolve todos os quadros capturados na janela (mesmo sem `>` antes do tempo).
    public func captureMonitorWindow(_ command: String, durationSeconds: Double = 1.0) async throws -> String {
        guard let peripheral = activePeripheral,
              let writeChar = writeCharacteristic else {
            throw NSError(domain: "CarSensei.BLE", code: -1, userInfo: [NSLocalizedDescriptionKey: "vLinker MC-IOS não está conectado"])
        }

        if let stale = pendingContinuation {
            pendingContinuation = nil
            stale.resume(throwing: CancellationError())
        }
        timeoutTask?.cancel()
        if discardUntilPrompt {
            for _ in 0..<12 where discardUntilPrompt {
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            discardUntilPrompt = false
        }
        responseBuffer = ""

        let payloadString = command.hasSuffix("\r") ? command : "\(command)\r"
        guard let data = payloadString.data(using: .utf8) else {
            throw NSError(domain: "CarSensei.BLE", code: -2, userInfo: [NSLocalizedDescriptionKey: "Comando inválido"])
        }

        let writeType: CBCharacteristicWriteType = writeChar.properties.contains(.writeWithoutResponse)
            ? .withoutResponse
            : .withResponse

        let captured: String = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            self.pendingContinuation = continuation

            self.timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(durationSeconds * 1_000_000_000))
                guard !Task.isCancelled, let self = self, let pending = self.pendingContinuation else { return }
                self.pendingContinuation = nil
                let snapshot = self.responseBuffer
                self.responseBuffer = ""
                self.discardUntilPrompt = true
                // Envia CR para interromper o modo monitor (AT MA / STM) no vLinker
                if let stopData = "\r".data(using: .utf8) {
                    peripheral.writeValue(stopData, for: writeChar, type: writeType)
                }
                pending.resume(returning: snapshot)
            }

            let mtu = max(20, peripheral.maximumWriteValueLength(for: writeType))
            var offset = 0
            while offset < data.count {
                let end = min(offset + mtu, data.count)
                let chunk = data.subdata(in: offset..<end)
                peripheral.writeValue(chunk, for: writeChar, type: writeType)
                offset = end
            }
        }

        // Drena o "STOPPED >" residual antes do próximo comando normal
        for _ in 0..<14 where discardUntilPrompt {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        discardUntilPrompt = false
        return captured
    }

    private func failPendingCommand(message: String) {
        timeoutTask?.cancel()
        responseBuffer = ""
        if let pending = pendingContinuation {
            pendingContinuation = nil
            pending.resume(throwing: NSError(domain: "CarSensei.BLE", code: -4, userInfo: [NSLocalizedDescriptionKey: message]))
        }
    }

    private func registerDiscovered(
        peripheral: CBPeripheral,
        localName: String?,
        rssi: Int,
        autoConnect: Bool
    ) {
        let name = (localName ?? peripheral.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let upper = name.uppercased()
        let isVLinker = upper.contains("VLINKER") || upper.contains("MC-IOS") || upper.contains("VLINK") || upper.contains("VGATE") || upper.contains("OBD")

        peripheralsById[peripheral.identifier] = peripheral
        let item = DiscoveredBLEDevice(
            id: peripheral.identifier,
            name: name,
            rssi: rssi,
            isPreferredVLinker: isVLinker
        )

        if let idx = discoveredDevices.firstIndex(where: { $0.id == item.id }) {
            discoveredDevices[idx] = item
        } else {
            discoveredDevices.append(item)
            discoveredDevices.sort { lhs, rhs in
                if lhs.isPreferredVLinker != rhs.isPreferredVLinker {
                    return lhs.isPreferredVLinker
                }
                return lhs.rssi > rhs.rssi
            }
        }

        // Conecta sozinho ao ver "vLinker MC-IOS" / "vLinker" (só quando a busca foi automática)
        if autoConnect && (upper.contains("VLINKER MC-IOS") || upper.contains("VLINKER")) && activePeripheral == nil {
            connect(to: peripheral.identifier)
        }
    }
}

extension BLEConnectionManager: CBCentralManagerDelegate {
    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in
            switch state {
            case .poweredOn:
                if self.connectionState == .bluetoothOff || self.connectionState == .disconnected {
                    self.startScanning(autoConnectPreferred: true)
                }
            case .poweredOff:
                self.connectionState = .bluetoothOff
                self.statusDetail = "Bluetooth do iPhone está desligado"
            case .unauthorized:
                self.connectionState = .error
                self.statusDetail = "Permissão de Bluetooth negada nos Ajustes do iOS"
            default:
                break
            }
        }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let rssiInt = RSSI.intValue
        Task { @MainActor in
            self.registerDiscovered(
                peripheral: peripheral,
                localName: advertisedName,
                rssi: rssiInt,
                autoConnect: self.autoConnectOnDiscovery
            )
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.connectedDeviceName = peripheral.name ?? "vLinker MC-IOS"
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: self.savedPeripheralKey)
            self.connectionState = .initializingProtocol
            self.statusDetail = "Descobrindo canal serial GATT do \(self.connectedDeviceName ?? "vLinker")..."
            self.writeCharacteristic = nil
            self.notifyCharacteristic = nil
            self.transportReadyFired = false
            self.servicesAwaitingCharacteristics = 0
            peripheral.discoverServices(nil)
        }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let desc = error?.localizedDescription ?? "Falha ao conectar via BLE"
        Task { @MainActor in
            self.connectionState = .error
            self.statusDetail = desc
        }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            self.writeCharacteristic = nil
            self.notifyCharacteristic = nil
            self.failPendingCommand(message: "vLinker desconectado")

            // Queda inesperada (motor desligado, carro longe): pedido de conexão pendente,
            // o iOS reconecta sozinho quando o adaptador voltar a anunciar, sem prazo.
            if !self.userRequestedDisconnect, self.centralManager.state == .poweredOn {
                self.activePeripheral = peripheral
                self.connectionState = .connecting
                self.statusDetail = "Conexão com o vLinker perdida. Reconectando automaticamente..."
                self.centralManager.connect(peripheral, options: nil)
                return
            }
            self.activePeripheral = nil
            self.connectionState = .disconnected
            self.statusDetail = "vLinker MC-IOS desconectado"
        }
    }
}

extension BLEConnectionManager: CBPeripheralDelegate {
    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        Task { @MainActor in
            self.servicesAwaitingCharacteristics = services.count
            for service in services {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        let characteristics = service.characteristics ?? []
        Task { @MainActor in
            for char in characteristics {
                let uuidStr = char.uuid.uuidString.uppercased()

                // Prefer Vgate vLinker MC-IOS 2AF0 (Notify) & 2AF1 (Write), or fallback to any Notify/Write pair
                if char.properties.contains(.notify) || char.properties.contains(.indicate) {
                    if self.notifyCharacteristic == nil || uuidStr == "2AF0" || uuidStr == "FFE1" || uuidStr == "FFF1" {
                        self.notifyCharacteristic = char
                        peripheral.setNotifyValue(true, for: char)
                    }
                }
                if char.properties.contains(.write) || char.properties.contains(.writeWithoutResponse) {
                    if self.writeCharacteristic == nil || uuidStr == "2AF1" || uuidStr == "FFE1" || uuidStr == "FFF2" {
                        self.writeCharacteristic = char
                    }
                }
            }

            // Espera todos os serviços: um serviço genérico pode aparecer antes do canal serial preferido.
            self.servicesAwaitingCharacteristics = max(0, self.servicesAwaitingCharacteristics - 1)
            guard self.servicesAwaitingCharacteristics == 0, !self.transportReadyFired else { return }
            if self.writeCharacteristic != nil && self.notifyCharacteristic != nil {
                self.transportReadyFired = true
                self.onAdapterTransportReady?()
            } else {
                self.connectionState = .error
                self.statusDetail = "Adaptador sem canal serial BLE compatível"
            }
        }
    }

    nonisolated public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let data = characteristic.value,
              let chunk = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            return
        }
        Task { @MainActor in
            var incoming = Substring(chunk)
            if self.discardUntilPrompt {
                guard let prompt = incoming.firstIndex(of: ">") else { return }
                incoming = incoming[incoming.index(after: prompt)...]
                self.discardUntilPrompt = false
            }
            self.responseBuffer.append(contentsOf: incoming)
            if self.responseBuffer.contains(">") {
                self.timeoutTask?.cancel()
                if let continuation = self.pendingContinuation {
                    self.pendingContinuation = nil
                    let completed = self.responseBuffer
                    self.responseBuffer = ""
                    continuation.resume(returning: completed)
                }
            }
        }
    }
}
