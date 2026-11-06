import Foundation

// Estado e preferências do CarPlay no store. Tudo aqui some junto com a flag CARPLAY_ENABLED (ver LEIAME.md).

#if CARPLAY_ENABLED

extension CockpitGaugeID {
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
}

extension CarSenseiStore {
    private static let carPlaySlotsKey = "carsensei.carplay.slots.v1"

    /// Sensores que a tela do CarPlay precisa ver atualizados.
    var carPlayPolledGauges: [CockpitGaugeID] { carPlaySlotGauges }

    /// Substitui um slot específico (0..21) por outro sensor (trocando de lugar caso já esteja em outro slot).
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

    private func saveCarPlaySlotPreferences() {
        let rawValues = carPlaySlotGauges.map(\.rawValue)
        if let data = try? JSONEncoder().encode(rawValues) {
            UserDefaults.standard.set(data, forKey: Self.carPlaySlotsKey)
        }
    }

    func loadCarPlaySlotPreferences() {
        guard let data = UserDefaults.standard.data(forKey: Self.carPlaySlotsKey),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return }
        var valid = decoded.compactMap { CockpitGaugeID(rawValue: $0) }
        while valid.count < CockpitGaugeID.defaultCarPlaySlots.count {
            valid.append(CockpitGaugeID.defaultCarPlaySlots[valid.count])
        }
        carPlaySlotGauges = Array(valid.prefix(CockpitGaugeID.defaultCarPlaySlots.count))
    }
}

#else

extension CarSenseiStore {
    var carPlayPolledGauges: [CockpitGaugeID] { [] }
    func loadCarPlaySlotPreferences() {}
}

#endif
