import Foundation

public enum OBDUDSParser {

    // MARK: - Hex Normalization & ISO-TP Reassembly

    /// Strips prompt characters (`>`), echoes, CAN 11-bit headers (`7E8`, `7E9`, `74C`, etc.),
    /// and ISO-TP frame prefixes (`0:`, `1:`, PCI length bytes) to yield contiguous payload bytes.
    public static func extractPayloadBytes(from rawResponse: String) -> [UInt8] {
        let cleanedLines = rawResponse
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: ">", with: "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                guard !line.isEmpty else { return false }
                let upper = line.uppercased()
                if upper.contains("NO DATA") || upper.contains("STOPPED") || upper.contains("ERROR")
                    || upper.contains("UNABLE") || upper.contains("SEARCHING") || upper == "OK" {
                    return false
                }
                if upper.count == 3, Int(upper, radix: 16) != nil,
                   !upper.hasPrefix("4"), !upper.hasPrefix("5"), !upper.hasPrefix("6"), !upper.hasPrefix("7") {
                    return false
                }
                return true
            }

        var allBytes: [UInt8] = []
        var isMultiFrameISOTP = false

        for line in cleanedLines {
            var working = line.uppercased()

            if let colonRange = working.range(of: ":"),
               working.distance(from: working.startIndex, to: colonRange.lowerBound) <= 2 {
                working = String(working[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                isMultiFrameISOTP = true
            }

            let tokens = tokenizeHex(working)
            guard !tokens.isEmpty else { continue }

            var slice = tokens[...]

            // Strip 11-bit CAN RX header if present (e.g. 7E8..7EF, 700..7FF)
            if let first = slice.first, first.count == 3, first.hasPrefix("7") {
                slice = slice.dropFirst()
            }

            let lineBytes = slice.compactMap { UInt8($0, radix: 16) }
            guard !lineBytes.isEmpty else { continue }

            let firstByte = lineBytes[0]
            let pciType = (firstByte & 0xF0) >> 4

            if tokens.first?.count == 3 && tokens.first?.hasPrefix("7") == true {
                if pciType == 0x0 && Int(firstByte) == lineBytes.count - 1 {
                    allBytes.append(contentsOf: lineBytes.dropFirst())
                    continue
                } else if pciType == 0x1 && lineBytes.count >= 3 {
                    isMultiFrameISOTP = true
                    allBytes.append(contentsOf: lineBytes.dropFirst(2))
                    continue
                } else if pciType == 0x2 && isMultiFrameISOTP {
                    allBytes.append(contentsOf: lineBytes.dropFirst(1))
                    continue
                }
            }

            allBytes.append(contentsOf: lineBytes)
        }

        return allBytes
    }

    public static func tokenizeHex(_ input: String) -> [String] {
        let parts = input.split(whereSeparator: { $0.isWhitespace })
        if parts.count > 1 {
            return parts.map(String.init)
        }
        guard let single = parts.first else { return [] }
        let s = String(single)
        var result: [String] = []
        var idx = s.startIndex
        if s.count % 2 == 1 && s.hasPrefix("7") && s.count >= 5 {
            let nextIdx = s.index(idx, offsetBy: 3)
            result.append(String(s[idx..<nextIdx]))
            idx = nextIdx
        }
        while idx < s.endIndex {
            let nextIdx = s.index(idx, offsetBy: 2, limitedBy: s.endIndex) ?? s.endIndex
            let token = String(s[idx..<nextIdx])
            if token.count == 2 {
                result.append(token)
            }
            idx = nextIdx
        }
        return result
    }

    // MARK: - Voltage (`AT RV`)

    public static func parseBatteryVoltage(_ raw: String) -> Double? {
        let pattern = #"([0-9]{1,2}[\.,][0-9]{1,2})\s*[Vv]?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let range = Range(match.range(at: 1), in: raw) else {
            return nil
        }
        let normalized = raw[range].replacingOccurrences(of: ",", with: ".")
        return Double(normalized)
    }

    // MARK: - SAE Mode 01 Single & Multi-PID Decoder

    public static func parseMode01Response(_ raw: String, into snapshot: inout TelemetrySnapshot) {
        let bytes = extractPayloadBytes(from: raw)
        guard !bytes.isEmpty else { return }

        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x41 {
                i += 1
                break
            }
            i += 1
        }

        while i < bytes.count {
            let pid = bytes[i]
            i += 1
            switch pid {
            case 0x04: // Engine Load (1 byte)
                guard i < bytes.count else { return }
                snapshot.engineLoadPct = Double(bytes[i]) * 100.0 / 255.0
                i += 1
            case 0x05: // Coolant Temp (1 byte)
                guard i < bytes.count else { return }
                snapshot.coolantTempC = Double(bytes[i]) - 40.0
                i += 1
            case 0x06: // Short Term Fuel Trim Bank 1 (1 byte)
                guard i < bytes.count else { return }
                snapshot.shortFuelTrimPct = (Double(bytes[i]) - 128.0) * 100.0 / 128.0
                i += 1
            case 0x07: // Long Term Fuel Trim Bank 1 (1 byte)
                guard i < bytes.count else { return }
                snapshot.longFuelTrimPct = (Double(bytes[i]) - 128.0) * 100.0 / 128.0
                i += 1
            case 0x0B: // Intake Manifold Absolute Pressure (1 byte, kPa)
                guard i < bytes.count else { return }
                snapshot.mapKpa = Double(bytes[i])
                i += 1
            case 0x0C: // Engine RPM (2 bytes)
                guard i + 1 < bytes.count else { return }
                let a = Double(bytes[i])
                let b = Double(bytes[i + 1])
                snapshot.rpm = (256.0 * a + b) / 4.0
                i += 2
            case 0x0D: // Vehicle Speed (1 byte, km/h)
                guard i < bytes.count else { return }
                snapshot.speedKmh = Double(bytes[i])
                i += 1
            case 0x0E: // Timing Advance (1 byte: A/2 - 64 in degrees)
                guard i < bytes.count else { return }
                snapshot.timingAdvanceDeg = (Double(bytes[i]) / 2.0) - 64.0
                i += 1
            case 0x0F: // Intake Air Temperature (1 byte)
                guard i < bytes.count else { return }
                snapshot.intakeAirTempC = Double(bytes[i]) - 40.0
                i += 1
            case 0x10: // MAF Air Flow Rate (2 bytes, 0.01 g/s)
                guard i + 1 < bytes.count else { return }
                let rawMaf = Double(UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]))
                snapshot.mafGramsPerSec = rawMaf / 100.0
                i += 2
            case 0x11: // Throttle Position (1 byte)
                guard i < bytes.count else { return }
                snapshot.throttlePositionPct = Double(bytes[i]) * 100.0 / 255.0
                i += 1
            case 0x14: // Oxygen Sensor 1 Bank 1 (2 bytes: A/200 V, (B*100/128)-100 %)
                guard i + 1 < bytes.count else { return }
                let volts = Double(bytes[i]) / 200.0
                snapshot.lambdaO2VoltageMv = volts * 1000.0
                i += 2
            case 0x15: // Oxygen Sensor 2 Bank 1 Post-Catalyst (2 bytes: A/200 V)
                guard i + 1 < bytes.count else { return }
                let volts = Double(bytes[i]) / 200.0
                snapshot.lambdaO2Sensor2Mv = volts * 1000.0
                i += 2
            case 0x1F: // Run Time Since Engine Start (2 bytes: seconds)
                guard i + 1 < bytes.count else { return }
                snapshot.engineRunTimeSec = Int(UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]))
                i += 2
            case 0x21: // Distance Traveled with MIL On (2 bytes: km)
                guard i + 1 < bytes.count else { return }
                snapshot.distanceWithMILOnKm = Double(UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]))
                i += 2
            case 0x22: // Fuel Rail Pressure relative to manifold vacuum (2 bytes: 0.079 kPa)
                guard i + 1 < bytes.count else { return }
                snapshot.fuelRailPressureKpa = Double(UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])) * 0.079
                i += 2
            case 0x23: // Fuel Rail Gauge Pressure GDI/Turbo (2 bytes: 10 kPa)
                guard i + 1 < bytes.count else { return }
                snapshot.fuelRailPressureKpa = Double(UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])) * 10.0
                i += 2
            case 0x2E: // Commanded Evaporative Purge (1 byte: A*100/255 %)
                guard i < bytes.count else { return }
                snapshot.commandedEvapPurgePct = Double(bytes[i]) * 100.0 / 255.0
                i += 1
            case 0x2F: // Fuel Tank Level Input (1 byte: A*100/255 %)
                guard i < bytes.count else { return }
                snapshot.fuelTankLevelPct = Double(bytes[i]) * 100.0 / 255.0
                i += 1
            case 0x30: // Warm-ups Since Codes Cleared (1 byte)
                guard i < bytes.count else { return }
                snapshot.warmUpsSinceDTCClear = Int(bytes[i])
                i += 1
            case 0x31: // Distance Traveled Since Codes Cleared (2 bytes: km)
                guard i + 1 < bytes.count else { return }
                snapshot.distanceSinceDTCClearKm = Double(UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]))
                i += 2
            case 0x33: // Absolute Barometric Pressure (1 byte: kPa)
                guard i < bytes.count else { return }
                snapshot.barometricPressureKpa = Double(bytes[i])
                i += 1
            case 0x3C: // Catalyst Temperature Bank 1 Sensor 1 (2 bytes: (256*A+B)/10 - 40 °C)
                guard i + 1 < bytes.count else { return }
                let rawCat = Double(UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]))
                snapshot.catalystTempB1S1C = (rawCat / 10.0) - 40.0
                i += 2
            case 0x42: // Control Module Voltage (2 bytes: mV)
                guard i + 1 < bytes.count else { return }
                let mv = Double(UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]))
                let volts = mv / 1000.0
                if volts > 5.0 && volts < 20.0 {
                    snapshot.ecuModuleVoltage = volts
                    if snapshot.batteryVoltage == nil {
                        snapshot.batteryVoltage = volts
                    }
                }
                i += 2
            case 0x43: // Absolute Load Value (2 bytes: (256*A+B)*100/255 %)
                guard i + 1 < bytes.count else { return }
                let rawLoad = Double(UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]))
                snapshot.absoluteLoadPct = rawLoad * 100.0 / 255.0
                i += 2
            case 0x44: // Commanded Equivalence Ratio Lambda (2 bytes: (256*A+B)*2/65536)
                guard i + 1 < bytes.count else { return }
                let rawLambda = Double(UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]))
                snapshot.commandedLambdaRatio = (rawLambda * 2.0) / 65536.0
                i += 2
            case 0x45: // Relative Throttle Position (1 byte: A*100/255 %)
                guard i < bytes.count else { return }
                snapshot.relativeThrottlePct = Double(bytes[i]) * 100.0 / 255.0
                i += 1
            case 0x46: // Ambient Air Temperature (1 byte)
                guard i < bytes.count else { return }
                snapshot.ambientTempC = Double(bytes[i]) - 40.0
                i += 1
            case 0x49: // Accelerator Pedal Position D (1 byte: A*100/255 %)
                guard i < bytes.count else { return }
                snapshot.acceleratorPedalDPct = Double(bytes[i]) * 100.0 / 255.0
                i += 1
            case 0x4A: // Accelerator Pedal Position E (1 byte: A*100/255 %)
                guard i < bytes.count else { return }
                snapshot.acceleratorPedalEPct = Double(bytes[i]) * 100.0 / 255.0
                i += 1
            case 0x4C: // Commanded Throttle Actuator (1 byte: A*100/255 %)
                guard i < bytes.count else { return }
                snapshot.commandedThrottleActuatorPct = Double(bytes[i]) * 100.0 / 255.0
                i += 1
            case 0x4D: // Time Run with MIL On (2 bytes: minutes)
                guard i + 1 < bytes.count else { return }
                snapshot.timeWithMILOnMin = Int(UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]))
                i += 2
            case 0x4E: // Time Since Trouble Codes Cleared (2 bytes: minutes)
                guard i + 1 < bytes.count else { return }
                snapshot.timeSinceDTCClearMin = Int(UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]))
                i += 2
            case 0x52: // Ethanol Fuel % (1 byte)
                guard i < bytes.count else { return }
                snapshot.ethanolFuelPct = Double(bytes[i]) * 100.0 / 255.0
                i += 1
            case 0x5C: // Engine Oil Temperature (1 byte: A - 40 °C)
                guard i < bytes.count else { return }
                snapshot.engineOilTempC = Double(bytes[i]) - 40.0
                i += 1
            case 0x5E: // Engine Fuel Rate (2 bytes: (256*A+B)/20 L/h)
                guard i + 1 < bytes.count else { return }
                let rawRate = Double(UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]))
                snapshot.fuelRateLitersPerHour = rawRate / 20.0
                i += 2
            default:
                return
            }
        }
    }

    /// Decodifica a máscara de 32 bits SAE J1979 Mode 01 (`01 00`, `01 20`, `01 40`, `01 60`)
    /// para descobrir dinamicamente quais sensores (PIDs) a ECU do veículo conectado realmente possui.
    public static func parseSupportedPIDsBitmask(_ raw: String, basePID: Int) -> [Int] {
        let bytes = extractPayloadBytes(from: raw)
        let targetHeader: [UInt8] = [0x41, UInt8(basePID & 0xFF)]
        guard let idx = findSequence(targetHeader, in: bytes), idx + 5 < bytes.count else {
            return []
        }
        let maskBytes = Array(bytes[(idx + 2)..<(idx + 6)])
        var supported: [Int] = []
        for byteIndex in 0..<4 {
            let b = maskBytes[byteIndex]
            for bit in 0..<8 {
                if (b & (1 << (7 - bit))) != 0 {
                    let pidNumber = basePID + (byteIndex * 8) + bit + 1
                    supported.append(pidNumber)
                }
            }
        }
        return supported
    }

    /// Decodifica o tipo de combustível reportado pela ECU no PID `01 51` (`41 51 XX`).
    public static func parseECUFuelType(_ raw: String) -> String? {
        let bytes = extractPayloadBytes(from: raw)
        guard let idx = findSequence([0x41, 0x51], in: bytes), idx + 2 < bytes.count else {
            return nil
        }
        switch bytes[idx + 2] {
        case 0x01: return "Gasolina"
        case 0x02: return "Metanol"
        case 0x03: return "Etanol (E100)"
        case 0x04: return "Diesel"
        case 0x05: return "GLP / Gás"
        case 0x06: return "GNV"
        case 0x08: return "Elétrico / Híbrido"
        case 0x09, 0x0B: return "Flex (Gasolina / Etanol)"
        case 0x11, 0x12, 0x13: return "Híbrido Regen."
        default: return nil
        }
    }

    // MARK: - Real-Time Speed-Density / MAF Fuel Consumption Calculator (Multi-Vehicle)

    /// Computes instantaneous fuel flow (`L/h`), instantaneous fuel economy (`km/L`),
    /// and integrates session distance & fuel.
    public static func updateFuelConsumption(
        in snapshot: inout TelemetrySnapshot,
        fuelProfile: FuelTypeProfile,
        displacementLiters: Double = 1.498,
        elapsedSeconds: Double,
        calibrationFactor: Double = 1.0
    ) {
        guard let rpm = snapshot.rpm, rpm > 250 else {
            snapshot.fuelRateLitersPerHour = 0.0
            snapshot.instantKmPerLiter = nil
            snapshot.isFuelCut = false
            return
        }

        // Etanol só vem da ECU (PID 01 52). Sem ele, o perfil de combustível escolhido define a mistura:
        // estimar pelo fuel trim não funciona porque a ECU adapta o trim e ele volta para perto de zero.

        // Determine mass air flow (g/s): either direct MAF (01 10) or Speed-Density from MAP (01 0B) + IAT (01 0F) + RPM (01 0C)
        let airFlowGramsPerSec: Double
        if let maf = snapshot.mafGramsPerSec, maf > 0.2 {
            airFlowGramsPerSec = maf
        } else if let mapKpa = snapshot.mapKpa {
            let iatC = snapshot.intakeAirTempC ?? 35.0
            let tempKelvin = max(220.0, iatC + 273.15)
            let volumetricEfficiency = 0.82
            let imap = (rpm * mapKpa) / (tempKelvin * 2.0)
            airFlowGramsPerSec = (imap / 60.0) * volumetricEfficiency * max(0.8, displacementLiters) * 3.484
        } else {
            return
        }

        let stft = snapshot.shortFuelTrimPct ?? 0.0
        let ltft = snapshot.longFuelTrimPct ?? 0.0
        let trimMultiplier = max(0.75, min(1.35, 1.0 + (stft + ltft) / 100.0))

        let afr = fuelProfile.stoichiometricAFR(detectedEthanolPct: snapshot.ethanolFuelPct)
        let density = fuelProfile.densityGramsPerLiter(detectedEthanolPct: snapshot.ethanolFuelPct)

        let gramsFuelPerSec = (airFlowGramsPerSec / afr) * trimMultiplier
        let brutoLitersPerHour = (gramsFuelPerSec * 3600.0) / density
        // Fator aprendido com os abastecimentos reais do usuário (1.0 = sem calibração).
        let fator = min(max(calibrationFactor, 0.6), 1.6)
        var litersPerHour = max(0.0, brutoLitersPerHour * fator)

        let speed = snapshot.speedKmh ?? 0.0
        let throttle = snapshot.throttlePositionPct ?? 100.0

        // Corte de injeção: pé fora do acelerador, motor acima da marcha lenta e carro andando.
        // Nessa condição a ECU zera o combustível; a vazão calculada por MAP/MAF não vale.
        let fuelCut = speed > 15.0 && rpm > 1300.0 && throttle < 3.0
        snapshot.isFuelCut = fuelCut
        if fuelCut {
            litersPerHour = 0.0
            snapshot.fuelRateLitersPerHour = 0.0
            snapshot.instantKmPerLiter = nil
        } else {
            snapshot.fuelRateLitersPerHour = litersPerHour
            // Sem teto artificial de 50 km/L: o painel do carro chega a ~90 em descida.
            if speed > 2.0 && litersPerHour > 0.02 {
                snapshot.instantKmPerLiter = min(99.9, speed / litersPerHour)
            } else {
                snapshot.instantKmPerLiter = nil
            }
        }

        if elapsedSeconds > 0 && elapsedSeconds < 10.0 {
            let hours = elapsedSeconds / 3600.0
            snapshot.sessionDistanceKm += speed * hours
            snapshot.sessionFuelLiters += max(0.0, litersPerHour) * hours
        }
    }

    // MARK: - UDS 22 do câmbio e do HVAC (DIDs comuns; carro que não tem não responde)

    /// Parses `22 0B 37` (`62 0B 37 XX`) -> temperatura do fluido do câmbio em °C (`A - 40`)
    public static func parseTCUFluidTempC(_ raw: String) -> Double? {
        let bytes = extractPayloadBytes(from: raw)
        guard let idx = findSequence([0x62, 0x0B, 0x37], in: bytes),
              idx + 3 < bytes.count else { return nil }
        return Double(bytes[idx + 3]) - 40.0
    }

    /// Parses `22 0B 5B` (`62 0B 5B A B C D`) -> odômetro interno do câmbio em km
    public static func parseTCUOdometerKm(_ raw: String) -> Double? {
        let bytes = extractPayloadBytes(from: raw)
        guard let idx = findSequence([0x62, 0x0B, 0x5B], in: bytes),
              idx + 6 < bytes.count else { return nil }
        let b0 = UInt32(bytes[idx + 3])
        let b1 = UInt32(bytes[idx + 4])
        let b2 = UInt32(bytes[idx + 5])
        let b3 = UInt32(bytes[idx + 6])
        let km = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        guard km > 0 && km < 1_000_000 else { return nil }
        return Double(km)
    }

    /// Parses UDS temperature DID response (`62 HI LO XX`) where temperature is `A - 40` or `A / 2 - 40`
    public static func parseUDSTemperatureC(_ raw: String, didHigh: UInt8, didLow: UInt8) -> Double? {
        let bytes = extractPayloadBytes(from: raw)
        guard let idx = findSequence([0x62, didHigh, didLow], in: bytes),
              idx + 3 < bytes.count else { return nil }
        let rawByte = bytes[idx + 3]
        guard rawByte > 0 && rawByte < 0xFE else { return nil }
        let candidate1 = Double(rawByte) - 40.0
        if candidate1 >= -20.0 && candidate1 <= 75.0 {
            return candidate1
        }
        let candidate2 = (Double(rawByte) * 0.5) - 40.0
        if candidate2 >= -20.0 && candidate2 <= 75.0 {
            return candidate2
        }
        return nil
    }

    /// Parses single-byte UDS DID payload (`62 HI LO XX`)
    public static func parseUDSSingleByte(_ raw: String, didHigh: UInt8, didLow: UInt8) -> UInt8? {
        let bytes = extractPayloadBytes(from: raw)
        guard let idx = findSequence([0x62, didHigh, didLow], in: bytes),
              idx + 3 < bytes.count else { return nil }
        return bytes[idx + 3]
    }

    // MARK: - SAE Mode 01 Odometer & Distance Forensics PIDs

    public static func parseMode01OdometerKm(_ raw: String) -> Double? {
        let bytes = extractPayloadBytes(from: raw)
        guard let idx = findSequence([0x41, 0xA6], in: bytes),
              idx + 5 < bytes.count else { return nil }
        let b0 = UInt32(bytes[idx + 2])
        let b1 = UInt32(bytes[idx + 3])
        let b2 = UInt32(bytes[idx + 4])
        let b3 = UInt32(bytes[idx + 5])
        let rawVal = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        guard rawVal > 0 && rawVal < 0xFFFFFFFF else { return nil }
        return Double(rawVal) / 10.0
    }

    public static func parseMode01TwoByteUInt(_ raw: String, pid: UInt8) -> Int? {
        let bytes = extractPayloadBytes(from: raw)
        guard let idx = findSequence([0x41, pid], in: bytes),
              idx + 3 < bytes.count else { return nil }
        return (Int(bytes[idx + 2]) << 8) | Int(bytes[idx + 3])
    }

    public static func parseMode01OneByteUInt(_ raw: String, pid: UInt8) -> Int? {
        let bytes = extractPayloadBytes(from: raw)
        guard let idx = findSequence([0x41, pid], in: bytes),
              idx + 2 < bytes.count else { return nil }
        return Int(bytes[idx + 2])
    }

    // MARK: - VIN & ECU ASCII Strings (`09 02`, `09 04`, `09 0A`, `22 F1 90`, `22 F1 89`)

    public static func parseASCIIIdentifier(_ raw: String) -> String? {
        let bytes = extractPayloadBytes(from: raw)
        guard !bytes.isEmpty else { return nil }

        var payload = bytes
        if let idx = findSequence([0x49, 0x02], in: bytes) {
            payload = Array(bytes.dropFirst(idx + 3))
        } else if let idx = findSequence([0x49, 0x04], in: bytes) {
            payload = Array(bytes.dropFirst(idx + 3))
        } else if let idx = findSequence([0x49, 0x0A], in: bytes) {
            payload = Array(bytes.dropFirst(idx + 3))
        } else if let idx = findSequence([0x62, 0xF1], in: bytes), idx + 3 <= bytes.count {
            payload = Array(bytes.dropFirst(idx + 3))
        }

        let chars = payload.compactMap { byte -> Character? in
            guard byte >= 0x20 && byte <= 0x7E else { return nil }
            return Character(UnicodeScalar(byte))
        }
        let text = String(chars).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count >= 4 ? text : nil
    }

    // MARK: - DTC Decoding (SAE 2-Byte & UDS Service $19 3-Byte + Status Mask)

    public static func decodeTwoByteDTC(_ b0: UInt8, _ b1: UInt8) -> String? {
        if b0 == 0 && b1 == 0 { return nil }
        let prefixIndex = (b0 & 0xC0) >> 6
        let prefix: String
        switch prefixIndex {
        case 0: prefix = "P"
        case 1: prefix = "C"
        case 2: prefix = "B"
        default: prefix = "U"
        }
        let digit1 = (b0 & 0x30) >> 4
        let digit2 = b0 & 0x0F
        let digit3 = (b1 & 0xF0) >> 4
        let digit4 = b1 & 0x0F
        return String(format: "%@%1X%1X%1X%1X", prefix, digit1, digit2, digit3, digit4)
    }

    /// Parses UDS `19 02` response (`59 02 <AvailMask> [DTC_Hi DTC_Mid DTC_FTB Status]...`).
    /// Filters strictly for real fault states (`status & 0x0D != 0`: Active `0x01`, Pending `0x04`, or Confirmed/Archived `0x08`),
    /// ignoring `0x40`/`0x50` (`testNotCompleted`) monitor placeholders.
    public static func parseUDS1902DTCs(
        _ raw: String,
        module: ECUTargetModule
    ) -> [DiagnosticFault] {
        let bytes = extractPayloadBytes(from: raw)
        guard let idx = findSequence([0x59, 0x02], in: bytes),
              idx + 3 <= bytes.count else {
            return []
        }

        var cursor = idx + 3
        var faults: [DiagnosticFault] = []

        while cursor + 3 < bytes.count {
            let hi = bytes[cursor]
            let mid = bytes[cursor + 1]
            let ftb = bytes[cursor + 2]
            let status = bytes[cursor + 3]
            cursor += 4

            // Require at least one real fault bit: testFailed (0x01), pendingDTC (0x04), or confirmedDTC (0x08)
            guard (status & 0x0D) != 0 else { continue }

            guard let baseCode = decodeTwoByteDTC(hi, mid) else { continue }
            let ftbHex = String(format: "%02X", ftb)
            let statusHex = String(format: "%02X", status)
            let rawDTC = String(format: "%02X%02X%02X", hi, mid, ftb)

            let isActiveNow = (status & 0x01) != 0
            let isConfirmed = (status & 0x08) != 0
            let failedSinceClear = (status & 0x20) != 0
            let notCompletedCycle = (status & 0x40) != 0

            let interpretation = SenseiKnowledgeBase.interpretFault(
                baseCode: baseCode,
                ftbHex: ftbHex,
                moduleCode: module.code,
                isActiveNow: isActiveNow
            )

            let fault = DiagnosticFault(
                baseCode: baseCode,
                failureTypeByteHex: ftbHex,
                failureTypeDescription: SenseiKnowledgeBase.decodeFailureTypeByte(ftbHex),
                moduleCode: module.code,
                moduleName: module.name,
                statusMaskHex: statusHex,
                isActiveNow: isActiveNow,
                isConfirmed: isConfirmed,
                failedSinceLastClear: failedSinceClear,
                notCompletedThisCycle: notCompletedCycle,
                rawDTCBytesHex: rawDTC,
                interpretation: interpretation
            )

            if !faults.contains(where: { $0.id == fault.id }) {
                faults.append(fault)
            }
        }

        return faults
    }

    public static func parseStandardOBDDTCs(
        _ raw: String,
        modeResponseByte: UInt8,
        isActiveMode: Bool
    ) -> [DiagnosticFault] {
        let bytes = extractPayloadBytes(from: raw)
        guard let idx = bytes.firstIndex(of: modeResponseByte) else { return [] }

        var cursor = idx + 1
        if cursor < bytes.count && bytes[cursor] <= 0x20 && (bytes.count - cursor - 1) % 2 == 0 {
            cursor += 1
        }

        var faults: [DiagnosticFault] = []
        while cursor + 1 < bytes.count {
            let b0 = bytes[cursor]
            let b1 = bytes[cursor + 1]
            cursor += 2
            guard let baseCode = decodeTwoByteDTC(b0, b1) else { continue }

            let interpretation = SenseiKnowledgeBase.interpretFault(
                baseCode: baseCode,
                ftbHex: nil,
                moduleCode: "ECM",
                isActiveNow: isActiveMode
            )

            let fault = DiagnosticFault(
                baseCode: baseCode,
                failureTypeByteHex: nil,
                failureTypeDescription: nil,
                moduleCode: "ECM",
                moduleName: "Injeção Eletrônica 1.5T (OBD-II)",
                statusMaskHex: nil,
                isActiveNow: isActiveMode,
                isConfirmed: true,
                failedSinceLastClear: true,
                notCompletedThisCycle: false,
                rawDTCBytesHex: String(format: "%02X%02X00", b0, b1),
                interpretation: interpretation
            )
            if !faults.contains(where: { $0.baseCode == fault.baseCode }) {
                faults.append(fault)
            }
        }

        return faults
    }

    // MARK: - UDS `19 04` Multi-Occurrence Snapshot Decoder (UDS genérico)

    /// Parses UDS `19 04` (`59 04 <DTC_3B> <Status> [RecordNum NumDIDs [DID Data]...]`)
    /// extracting odometer (`0B 5B` / `01 A6` / `D1 01`), CVT temp (`0B 37`), coolant temp (`0B 2F`),
    /// vehicle speed (`0B 33`), and cycle count (`0B 5A`) for each recorded occurrence.
    public static func parseUDSSnapshotOccurrences(_ raw: String) -> [UDSSnapshotOccurrence] {
        let bytes = extractPayloadBytes(from: raw)
        guard let idx = findSequence([0x59, 0x04], in: bytes),
              idx + 6 < bytes.count else {
            return []
        }

        let payload = Array(bytes[(idx + 6)...])
        var occurrences: [UDSSnapshotOccurrence] = []

        // Procura o DID 0B 5B (odômetro de 4 bytes em km, usado por alguns câmbios)
        var i = 0
        var recordCounter = 1
        while i + 5 < payload.count {
            if payload[i] == 0x0B && payload[i + 1] == 0x5B {
                let b0 = UInt32(payload[i + 2])
                let b1 = UInt32(payload[i + 3])
                let b2 = UInt32(payload[i + 4])
                let b3 = UInt32(payload[i + 5])
                let odoKm = Double((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)

                if odoKm > 0 && odoKm < 900_000 {
                    // Look around this window (+40 bytes, -10 bytes) for 0B 5A (cycles), 0B 2F (coolant), 0B 33 (speed), 0B 37 (CVT temp)
                    let windowStart = max(0, i - 10)
                    let windowEnd = min(payload.count, i + 40)
                    let window = Array(payload[windowStart..<windowEnd])

                    var cycles: Int?
                    if let cIdx = findSequence([0x0B, 0x5A], in: window), cIdx + 5 < window.count {
                        let cVal = (Int(window[cIdx + 2]) << 24) | (Int(window[cIdx + 3]) << 16) | (Int(window[cIdx + 4]) << 8) | Int(window[cIdx + 5])
                        cycles = cVal
                    }

                    var coolantC: Double?
                    if let clIdx = findSequence([0x0B, 0x2F], in: window), clIdx + 2 < window.count {
                        coolantC = Double(window[clIdx + 2]) - 40.0
                    }

                    var speedKmh: Double?
                    if let spIdx = findSequence([0x0B, 0x33], in: window), spIdx + 2 < window.count {
                        speedKmh = Double(window[spIdx + 2])
                    }

                    var cvtTempC: Double?
                    if let cvtIdx = findSequence([0x0B, 0x37], in: window), cvtIdx + 2 < window.count {
                        cvtTempC = Double(window[cvtIdx + 2]) - 40.0
                    }

                    occurrences.append(UDSSnapshotOccurrence(
                        recordNumber: recordCounter,
                        odometerKm: odoKm,
                        transmissionTempC: cvtTempC,
                        coolantTempC: coolantC,
                        vehicleSpeedKmh: speedKmh,
                        operatingCycles: cycles
                    ))
                    recordCounter += 1
                    i += 6
                    continue
                }
            }
            i += 1
        }

        return occurrences
    }

    // MARK: - UDS `19 03` (lista de DTCs com snapshot gravado)

    /// Parses `19 03` (`59 03 [DTC_Hi DTC_Mid DTC_FTB RecordNum]...`) -> DTCs (3 bytes) que têm snapshot, sem repetição.
    public static func parseUDS1903SnapshotDTCs(_ raw: String) -> [[UInt8]] {
        let bytes = extractPayloadBytes(from: raw)
        guard let idx = findSequence([0x59, 0x03], in: bytes) else { return [] }
        var dtcs: [[UInt8]] = []
        var cursor = idx + 2
        while cursor + 3 < bytes.count {
            let dtc = Array(bytes[cursor..<(cursor + 3)])
            if dtc != [0, 0, 0], !dtcs.contains(dtc) {
                dtcs.append(dtc)
            }
            cursor += 4
        }
        return dtcs
    }

    /// VIN válido de 17 caracteres (sem I, O, Q) dentro de uma resposta `09 02` / `22 F1 90`, ou `nil`.
    public static func parseVIN(_ raw: String) -> String? {
        guard let text = parseASCIIIdentifier(raw) else { return nil }
        return normalizedVIN(text)
    }

    public static func normalizedVIN(_ text: String) -> String? {
        let cleaned = text.uppercased().filter { $0.isLetter || $0.isNumber }
        guard cleaned.count >= 17 else { return nil }
        let vin = String(cleaned.suffix(17))
        return vin.contains(where: { "IOQ".contains($0) }) ? nil : vin
    }

    public static func findSequence(_ seq: [UInt8], in bytes: [UInt8]) -> Int? {
        guard !seq.isEmpty, bytes.count >= seq.count else { return nil }
        for i in 0...(bytes.count - seq.count) {
            if Array(bytes[i..<(i + seq.count)]) == seq {
                return i
            }
        }
        return nil
    }
}

// MARK: - Resposta negativa UDS (7F): traduz o motivo da recusa do módulo

/// `ISO 14229` — quando o módulo recusa um serviço ele responde `7F <serviço> <NRC>`.
/// Sem traduzir isso, o app não distingue "aceitou" de "recusou" e o usuário fica sem saber o porquê.
nonisolated enum UDSDiagnostic {
    struct Negative: Equatable {
        let service: UInt8
        let nrc: UInt8
        let title: String
        let hint: String

        var summary: String {
            String(format: "%@ (7F %02X %02X) — %@", title, service, nrc, hint)
        }
    }

    static func negativeResponse(in raw: String) -> Negative? {
        let bytes = OBDUDSParser.extractPayloadBytes(from: raw)
        guard let idx = bytes.firstIndex(of: 0x7F), idx + 2 < bytes.count else { return nil }
        let service = bytes[idx + 1]
        let nrc = bytes[idx + 2]
        let info = describe(nrc)
        return Negative(service: service, nrc: nrc, title: info.title, hint: info.hint)
    }

    static func describe(_ nrc: UInt8) -> (title: String, hint: String) {
        switch nrc {
        case 0x10: return ("Rejeição genérica", "o módulo recusou o comando sem detalhar.")
        case 0x11: return ("Serviço não suportado", "este módulo não aceita este serviço UDS por OBD.")
        case 0x12: return ("Sub-função não suportada", "o serviço existe, mas não com este parâmetro (ex.: opção 03).")
        case 0x13: return ("Tamanho de mensagem incorreto", "o payload enviado não tem o tamanho que o módulo espera para este DID.")
        case 0x21: return ("Módulo ocupado", "o módulo pediu para repetir o pedido.")
        case 0x22: return ("Condição não atendida", "falta uma condição (ignição ligada, motor desligado, sessão estendida).")
        case 0x24: return ("Erro de sequência", "falta um passo antes deste (sessão ou desbloqueio).")
        case 0x31: return ("Valor fora de faixa", "o DID aceita escrita, mas não com esse valor ou nessa posição de byte.")
        case 0x33: return ("Acesso de segurança negado", "o módulo exige desbloqueio Seed/Key (27) com a chave do fabricante; sem ela o comando não passa por OBD.")
        case 0x35: return ("Chave inválida", "a chave de segurança enviada não confere.")
        case 0x36: return ("Tentativas excedidas", "muitas tentativas de desbloqueio; o módulo entrou em espera.")
        case 0x37: return ("Tempo de espera não vencido", "aguarde antes de tentar desbloquear de novo.")
        case 0x78: return ("Resposta pendente", "o módulo está processando e responde depois.")
        case 0x7E: return ("Sub-função não suportada nesta sessão", "a sessão atual não permite este comando.")
        case 0x7F: return ("Serviço não suportado nesta sessão", "precisa de sessão estendida (10 03) ou de outro endereço diagnóstico.")
        default: return ("Resposta negativa não catalogada", "código 0x\(String(format: "%02X", nrc)).")
        }
    }
}
