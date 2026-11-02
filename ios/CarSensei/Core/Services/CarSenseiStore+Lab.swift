import Foundation

// MARK: - Teste de bateria na partida

extension CarSenseiStore {

    public func runCrankingBatteryTest() async {
        guard connectionState == .connectedReady else {
            statusBannerText = "Conecte ao Scanner BLE antes de iniciar o teste de partida"
            return
        }

        pausePollingCounter += 1
        isRunningCrankingTest = true
        defer {
            pausePollingCounter = max(0, pausePollingCounter - 1)
            isRunningCrankingTest = false
        }

        statusBannerText = "TESTE DE PARTIDA ATIVO (10s): Dê a partida no veículo agora!"
        var samples: [Double] = []
        let startTime = Date()

        // ponytail: amostra o mais rápido que o BLE deixa (~40–80 ms por AT RV); a queda da partida dura ~100 ms
        // e pode ser subestimada. Se precisar do pico exato, usar o monitoramento contínuo de tensão do STN.
        while Date().timeIntervalSince(startTime) < 10.0 {
            if let (resp, _) = try? await protocolEngine.execute("AT RV", timeout: 0.6),
               let v = OBDUDSParser.parseBatteryVoltage(resp) {
                samples.append(v)
                liveTelemetry.batteryVoltage = v
            }
        }

        guard let resting = samples.first,
              let minV = samples.min(),
              let endV = samples.last else {
            statusBannerText = "Não foi possível capturar amostras de tensão suficientes"
            return
        }

        let level: HealthLevel
        let verdict: String
        if minV < 9.6 {
            level = .critical
            verdict = String(format: "Queda acentuada para %.2fV na partida! A bateria está com baixa força de arranque (CCA) e pode gerar códigos elétricos nos módulos.", minV)
        } else if minV < 10.2 {
            level = .attention
            verdict = String(format: "Tensão mínima de %.2fV na partida (meia-vida). Carregamento do alternador em %.2fV.", minV, endV)
        } else {
            level = .healthy
            verdict = String(format: "Excelente saúde elétrica! Tensão mínima de %.2fV na partida e alternador estabilizado em %.2fV.", minV, endV)
        }

        lastCrankingTest = CrankingBatteryTest(
            restingVoltage: resting,
            minCrankingVoltage: minV,
            chargingVoltage: endV,
            healthLevel: level,
            senseiVerdict: verdict
        )
        statusBannerText = "Teste de partida concluído: Mínima \(String(format: "%.2fV", minV)) (\(samples.count) amostras)"
    }
}
