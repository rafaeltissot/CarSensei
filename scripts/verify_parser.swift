import Foundation

@main
struct VerifyParser {
    static func main() {
        let tcuModule = ECUTargetModule.multiBrandModules.first { $0.id == "TCU" }!
        let ecmModule = ECUTargetModule.multiBrandModules.first { $0.id == "ECM" }!

        // 1. Verify status 0x40 (testNotCompleted) is ignored while status 0x28 / 0x08 is parsed
        let ecmRaw40 = "7E8 07 59 02 FF 05 01 00 40 >"
        let ecmFaults = OBDUDSParser.parseUDS1902DTCs(ecmRaw40, module: ecmModule)
        assert(ecmFaults.isEmpty, "Expected status 0x40 non-fault to be filtered out")

        let tcuRaw = "7E9 07 59 02 FF 02 18 98 28 >"
        let tcuFaults = OBDUDSParser.parseUDS1902DTCs(tcuRaw, module: tcuModule)
        assert(tcuFaults.count == 1 && tcuFaults[0].displayCode == "P0218(98)")
        assert(!tcuFaults[0].interpretation.resolvedCustomerBanner.isEmpty)
        assert(!tcuFaults[0].interpretation.resolvedCustomerStory.isEmpty)
        assert(!tcuFaults[0].interpretation.resolvedWorkshopTip.isEmpty)

        // 2. Verify decoding of the actual multi-frame 7E9 UDS 19 04 Snapshot captured from a real CVT TCU
        let realCarTCUSnapshot = """
        7E9 11 10 59 04 02 18 98 28
        7E9 21 01 21 0B 59 00 00 32
        7E9 22 56 0B 5A 00 00 1D 81
        7E9 23 0B 5B 00 00 E7 33 0B
        7E9 24 5C 00 03 86 EF 0B 5D
        7E9 25 01 0B 5E 4A 0B 2F 89
        7E9 26 0B 33 00 0B 37 9E 0B
        7E9 27 38 01 0B 26 20 19 0B
        7E9 28 34 41 8C 0B 36 05 40
        7E9 29 0B 41 3E 80 0B 44 08
        7E9 2A 17 0B 45 08 30 0B 42
        7E9 2B 06 C6 0B 43 06 6D 0B
        7E9 2C 47 10 33 0B 48 10 35
        7E9 2D 0B 49 1B 98 0B 4A 12
        7E9 2E E9 0B 4B 12 CC 0B 4C
        7E9 2F 0E 92 0B 4D 15 72 0B
        7E9 20 3E 98 0B 53 03 41 0B
        7E9 21 51 03 29 0B 52 03 4D
        7E9 22 0B 55 02 EF 0B 54 00
        7E9 23 00 0B 5F 00 0B 31 0B
        7E9 24 02 21 0B 59 00 00 32
        7E9 25 56 0B 5A 00 00 1E 1A
        7E9 26 0B 5B 00 00 E7 38 0B
        7E9 27 5C 00 03 86 F2 0B 5D
        7E9 28 01 0B 5E 4A 0B 2F 8A
        7E9 29 0B 33 24 0B 37 97 0B
        7E9 2A 38 00 0B 26 1D 67 0B
        """
        let occs = OBDUDSParser.parseUDSSnapshotOccurrences(realCarTCUSnapshot)
        assert(occs.count == 2, "Expected 2 occurrences, got \(occs.count)")
        assert(occs[0].odometerKm == 59187.0, "Expected 59187 km")
        assert(occs[0].transmissionTempC == 118.0, "Expected 118C CVT temp")
        assert(occs[1].odometerKm == 59192.0, "Expected 59192 km")
        assert(occs[1].transmissionTempC == 111.0, "Expected 111C CVT temp")

        // 3. Identificação genérica: só o que o carro informa, sem tabela de marcas
        let comVin = VehicleBrandProfile.detect(fromVIN: "ABCDE12345FGH6789", ecuName: "ECU-TESTE", calibrationId: "CAL123")
        assert(comVin.profile == .universalOBD && comVin.modelName.contains("ABCDE12345FGH6789") && comVin.engineDesc.contains("ECU-TESTE"))
        let semVin = VehicleBrandProfile.detect(fromVIN: "Aguardando Leitura Automática", ecuName: "Aguardando ECU", calibrationId: "")
        assert(semVin.profile == .autoDetect && !semVin.engineDesc.contains("Aguardando"))

        // 4. Verify Speed-Density Fuel Consumption & Ethanol Blend calculation
        var snap = TelemetrySnapshot()
        snap.rpm = 2000
        snap.mapKpa = 65
        snap.intakeAirTempC = 35
        snap.speedKmh = 80
        snap.shortFuelTrimPct = 0
        snap.longFuelTrimPct = 0
        snap.ethanolFuelPct = 30.0
        OBDUDSParser.updateFuelConsumption(in: &snap, fuelProfile: .autoDetected, displacementLiters: 1.498, elapsedSeconds: 1.0)
        assert((snap.instantKmPerLiter ?? 0) > 8.0 && (snap.instantKmPerLiter ?? 0) < 22.0, "Expected realistic highway km/L, got \(String(describing: snap.instantKmPerLiter))")
        assert(snap.ethanolFuelPct == 30.0)

        // 5. Sem PID 01 52 o etanol fica vazio (nada de estimativa pelo fuel trim)
        var noEthanol = snap
        noEthanol.ethanolFuelPct = nil
        noEthanol.longFuelTrimPct = 12
        OBDUDSParser.updateFuelConsumption(in: &noEthanol, fuelProfile: .autoDetected, elapsedSeconds: 1.0)
        assert(noEthanol.ethanolFuelPct == nil, "Ethanol must not be guessed from fuel trim")

        // 6. Auditoria de KM: lista 19 03, VIN e veredito
        let dtcs1903 = OBDUDSParser.parseUDS1903SnapshotDTCs("7E9 0B 59 03 02 18 98 01 02 18 98 02 >")
        assert(dtcs1903 == [[0x02, 0x18, 0x98]], "Expected one unique DTC from 19 03, got \(dtcs1903)")
        assert(OBDUDSParser.normalizedVIN("ABCDE12345FGH6789") == "ABCDE12345FGH6789")
        assert(OBDUDSParser.normalizedVIN("ABC123") == nil)
        assert(OdometerIntegrityVerdict.decide(critical: false, attention: false, tcuMatchesCluster: false, proofsRead: 0) == .inconclusive,
               "No proofs read must never approve the odometer")
        assert(OdometerIntegrityVerdict.decide(critical: false, attention: false, tcuMatchesCluster: false, proofsRead: 2) == .noEvidenceFound)
        assert(OdometerIntegrityVerdict.decide(critical: false, attention: false, tcuMatchesCluster: true, proofsRead: 1) == .verifiedIntact)
        assert(OdometerIntegrityVerdict.decide(critical: true, attention: false, tcuMatchesCluster: true, proofsRead: 3) == .tamperingConfirmed)

        // 7. TPMS: pressão por byte (kPa direto, 0xDC = 220 kPa) e descarte de 00/FF
        assert(OBDUDSParser.tpmsPressureKpa(fromByte: 0xDC) == 220.0, "0xDC deve virar 220 kPa")
        assert(OBDUDSParser.tpmsPressureKpa(fromByte: 0x00) == nil && OBDUDSParser.tpmsPressureKpa(fromByte: 0xFF) == nil)
        assert(OBDUDSParser.tpmsTemperatureC(fromByte: 0x3C) == 20.0, "0x3C deve virar 20 °C (A-40)")

        // Bloco de 4 pressões num DID (62 F4 05 + 4 bytes)
        let block = OBDUDSParser.tpmsPressureBlock(fromUDS: "7A8 07 62 F4 05 DC DA D8 E0 >", wheelCount: 4)
        assert(block == [220.0, 218.0, 216.0, 224.0], "Esperado bloco de 4 pressões, veio \(block)")

        // Escala de 2.5 kPa/bit (0x5C = 92 * 2.5 = 230 kPa) e struct intercalado [Press, Temp, Status] * 4
        let stridedBlock = OBDUDSParser.tpmsPressureBlock(
            fromUDS: "750 10 0F 62 D0 01 5C 41 00 5B 42 00 5A 41 00 5D 40 00 >",
            wheelCount: 4
        )
        assert(stridedBlock == [230.0, 227.5, 225.0, 232.5], "Esperado bloco 2.5 kPa/bit intercalado, veio \(stridedBlock)")
        let stridedTemps = OBDUDSParser.tpmsTemperatureBlock(
            fromUDS: "750 10 0F 62 D0 01 5C 41 00 5B 42 00 5A 41 00 5D 40 00 >",
            wheelCount: 4
        )
        assert(stridedTemps == [25.0, 26.0, 25.0, 24.0], "Esperado 4 temperaturas intercaladas, veio \(stridedTemps)")

        // IDs de sensor (4 bytes), ignorando quadros 00000000 e FFFFFFFF
        let tpmsIDs = OBDUDSParser.tpmsSensorIDs(fromUDS: "7A8 10 14 62 C1 00 4A 2F 10 C8 5B 3E 22 91 00 00 00 00 FF FF FF FF >")
        assert(tpmsIDs == ["4A2F10C8", "5B3E2291"], "Esperado 2 IDs válidos, veio \(tpmsIDs)")

        // 9. TPMS no barramento: o painel mostra a pressão mas o módulo não responde UDS.
        //    Primeiro quebra a saída do monitor em [ID: bytes].
        let monitor = """
        7E8 06 41 00 BE 3F A8 13
        500 00 00 00 00 02 1C 10 00
        501 00 20 51 00 00 00 24 00
        """
        let frames = OBDUDSParser.parseCANFrames(monitor)
        assert(frames.count == 3, "esperado 3 IDs, veio \(frames.keys.sorted())")
        assert(frames["500"]?.count == 8, "0x500 deve ter 8 bytes")
        assert(frames["501"] == [0x00, 0x20, 0x51, 0x00, 0x00, 0x00, 0x24, 0x00])

        // 4 pressões em kPa direto dentro de um quadro (0xDC = 220 kPa)
        let canBlock = OBDUDSParser.tpmsPressureBlock(fromCANBytes: [0x00, 0xDC, 0xDA, 0xD8, 0xE0, 0x00])
        assert(canBlock == [220.0, 218.0, 216.0, 224.0], "esperado as 4 pressões, veio \(canBlock)")

        // Struct intercalada por roda: pressão, temperatura, status...
        let interleaved = OBDUDSParser.tpmsPressureBlock(fromCANBytes: [0xDC, 0x40, 0xDA, 0x41, 0xD8, 0x42, 0xE0, 0x43])
        assert(interleaved == [220.0, 218.0, 216.0, 224.0], "esperado intercalado, veio \(interleaved)")

        // Não pode inventar pneu: zeros, FF e bytes baixos demais são "sem sensor"
        assert(OBDUDSParser.tpmsPressureBlock(fromCANBytes: [0, 0, 0, 0, 0, 0, 0, 0]).isEmpty)
        assert(OBDUDSParser.tpmsPressureBlock(fromCANBytes: [0xFF, 0xFF, 0xFF, 0xFF]).isEmpty)
        assert(OBDUDSParser.tpmsPressureBlock(fromCANBytes: [0x01, 0x02, 0x03, 0x04, 0x05, 0x06]).isEmpty)

        // 8. NRC (resposta negativa UDS): a tela precisa dizer POR QUE o módulo recusou a escrita
        let negSecurity = UDSDiagnostic.negativeResponse(in: "7E8 03 7F 2E 33 >")
        assert(negSecurity?.service == 0x2E && negSecurity?.nrc == 0x33, "esperado 7F 2E 33, veio \(String(describing: negSecurity))")
        assert(negSecurity?.title.localizedCaseInsensitiveContains("segurança") == true, "NRC 33 deve ser traduzido como segurança")
        assert(negSecurity?.summary.contains("7F 2E 33") == true)

        let negRange = UDSDiagnostic.negativeResponse(in: "7E8 03 7F 2F 31 >")
        assert(negRange?.nrc == 0x31 && negRange?.title.localizedCaseInsensitiveContains("faixa") == true)

        // Resposta positiva (6E = WriteDataByIdentifier aceito) nunca pode ser lida como recusa
        assert(UDSDiagnostic.negativeResponse(in: "7E8 06 6E F4 05 00 00 00 >") == nil, "6E é resposta positiva")
        // Timeout/erro do adaptador também não é NRC
        assert(UDSDiagnostic.negativeResponse(in: "NO DATA") == nil)
        assert(UDSDiagnostic.negativeResponse(in: "TIMEOUT") == nil)

        print("✅ Todas as verificações do parser passaram!")
    }
}
