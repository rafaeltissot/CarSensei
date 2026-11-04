import SwiftUI

// MARK: - Unified Sensor Presentation for All 42 CAN/UDS Gauges (iPhone & CarPlay)

public struct GaugeMetricPresentation {
    public let value: String
    public let unit: String
    public let compactText: String
    public let subtitle: String
    public let tint: Color
    public let progress: Double
    public let isAlerting: Bool
}

extension CarSenseiStore {
    public func presentation(for gauge: CockpitGaugeID) -> GaugeMetricPresentation {
        let t = liveTelemetry
        let th = vehicleIdentity.thermalThresholds

        switch gauge {
        case .instantFuel:
            let moving = (t.speedKmh ?? 0) >= 3.0
            let val = moving
                ? (t.instantKmPerLiter.map { String(format: "%.1f", $0) } ?? "--")
                : (t.fuelRateLitersPerHour.map { String(format: "%.2f", $0) } ?? "--")
            let unit = moving ? "km/L" : "L/h"
            let prog = moving
                ? min((t.instantKmPerLiter ?? 0) / 18.0, 1.0)
                : min((t.fuelRateLitersPerHour ?? 0) / 4.0, 1.0)
            return GaugeMetricPresentation(
                value: val,
                unit: unit,
                compactText: "\(val) \(unit)",
                subtitle: moving ? "Instantâneo" : "Marcha lenta",
                tint: .green,
                progress: prog,
                isAlerting: false
            )

        case .averageFuel:
            let val = t.sessionAverageKmPerLiter.map { String(format: "%.1f", $0) } ?? "--"
            return GaugeMetricPresentation(
                value: val,
                unit: "km/L",
                compactText: "\(val) km/L",
                subtitle: String(format: "Viagem %.1f km", t.sessionDistanceKm),
                tint: .teal,
                progress: min((t.sessionAverageKmPerLiter ?? 0) / 16.0, 1.0),
                isAlerting: false
            )

        case .fuelFlowRate:
            let val = t.fuelRateLitersPerHour.map { String(format: "%.2f", $0) } ?? "--"
            return GaugeMetricPresentation(
                value: val,
                unit: "L/h",
                compactText: "\(val) L/h",
                subtitle: "Vazão bicos",
                tint: .orange,
                progress: min((t.fuelRateLitersPerHour ?? 0) / 12.0, 1.0),
                isAlerting: false
            )

        case .tripDistance:
            let val = String(format: "%.2f", t.sessionDistanceKm)
            return GaugeMetricPresentation(
                value: val,
                unit: "km",
                compactText: "\(val) km",
                subtitle: "Sessão atual",
                tint: .blue,
                progress: min(t.sessionDistanceKm / 100.0, 1.0),
                isAlerting: false
            )

        case .tripFuelUsed:
            let val = String(format: "%.2f", t.sessionFuelLiters)
            return GaugeMetricPresentation(
                value: val,
                unit: "L",
                compactText: "\(val) L",
                subtitle: "Consumido",
                tint: .teal,
                progress: min(t.sessionFuelLiters / 20.0, 1.0),
                isAlerting: false
            )

        case .ethanolPercent:
            if let eth = t.ethanolFuelPct {
                let val = String(format: "%.0f", eth)
                return GaugeMetricPresentation(
                    value: val,
                    unit: "% E",
                    compactText: "\(val)% E",
                    subtitle: gauge.pidBadge,
                    tint: .green,
                    progress: eth / 100.0,
                    isAlerting: false
                )
            } else {
                let afr = selectedFuelProfile.stoichiometricAFR(detectedEthanolPct: nil)
                let val = String(format: "%.1f:1", afr)
                return GaugeMetricPresentation(
                    value: val,
                    unit: "AFR",
                    compactText: val,
                    subtitle: selectedFuelProfile.rawValue,
                    tint: .teal,
                    progress: 0.5,
                    isAlerting: false
                )
            }

        case .fuelTrim:
            let st = t.shortFuelTrimPct.map { String(format: "%+.0f%%", $0) } ?? "--"
            let lt = t.longFuelTrimPct.map { String(format: "%+.0f%%", $0) } ?? "--"
            let val = t.longFuelTrimPct.map { String(format: "%+.1f", $0) }
                ?? (t.shortFuelTrimPct.map { String(format: "%+.1f", $0) } ?? "--")
            return GaugeMetricPresentation(
                value: val,
                unit: "%",
                compactText: "\(st)/\(lt)",
                subtitle: "ST \(st) • LT \(lt)",
                tint: .purple,
                progress: min(max(((t.longFuelTrimPct ?? t.shortFuelTrimPct ?? 0) + 25.0) / 50.0, 0), 1),
                isAlerting: false
            )

        case .fuelTankLevel:
            let val = t.fuelTankLevelPct.map { String(format: "%.0f", $0) } ?? "--"
            return GaugeMetricPresentation(
                value: val,
                unit: "%",
                compactText: "\(val)%",
                subtitle: "Boia (01 2F)",
                tint: .green,
                progress: (t.fuelTankLevelPct ?? 50.0) / 100.0,
                isAlerting: (t.fuelTankLevelPct ?? 50.0) < 12.0
            )

        case .speed:
            let val = t.speedKmh.map { String(format: "%.0f", $0) } ?? "--"
            return GaugeMetricPresentation(
                value: val,
                unit: "km/h",
                compactText: "\(val) km/h",
                subtitle: "ECU (01 0D)",
                tint: .blue,
                progress: (t.speedKmh ?? 0) / 180.0,
                isAlerting: false
            )

        case .rpm:
            let val = t.rpm.map { String(format: "%.0f", $0) } ?? "--"
            return GaugeMetricPresentation(
                value: val,
                unit: "RPM",
                compactText: "\(val) RPM",
                subtitle: "Carga \(t.engineLoadPct.map { "\(Int($0))%" } ?? "--")",
                tint: .indigo,
                progress: (t.rpm ?? 0) / 6200.0,
                isAlerting: false
            )

        case .mapBoost:
            let val = t.mapKpa.map { String(format: "%.0f", $0) } ?? "--"
            let compact: String = {
                if let boost = t.estimatedBoostBar {
                    return String(format: "%+.2f bar", boost)
                }
                if let map = t.mapKpa {
                    return "\(Int(map)) kPa"
                }
                return "-- bar"
            }()
            let sub = t.estimatedBoostBar.map {
                $0 > 0.05 ? String(format: "Boost %+.2f bar", $0) : String(format: "Vácuo %.2f bar", $0)
            } ?? "PID 01 0B"
            return GaugeMetricPresentation(
                value: val,
                unit: "kPa",
                compactText: compact,
                subtitle: sub,
                tint: .orange,
                progress: (t.mapKpa ?? 0) / 220.0,
                isAlerting: false
            )

        case .engineLoad:
            let val = t.engineLoadPct.map { String(format: "%.0f", $0) } ?? "--"
            return GaugeMetricPresentation(
                value: val,
                unit: "%",
                compactText: "\(val)%",
                subtitle: "PID 01 04",
                tint: .mint,
                progress: (t.engineLoadPct ?? 0) / 100.0,
                isAlerting: false
            )

        case .absoluteEngineLoad:
            let val = t.absoluteLoadPct.map { String(format: "%.0f", $0) } ?? "--"
            return GaugeMetricPresentation(
                value: val,
                unit: "%",
                compactText: "\(val)%",
                subtitle: "Carga Abs. (01 43)",
                tint: .purple,
                progress: (t.absoluteLoadPct ?? 0) / 150.0,
                isAlerting: false
            )

        case .mafAirFlow:
            let val = t.effectiveAirFlowGramsPerSec.map { String(format: "%.1f", $0) } ?? "--"
            return GaugeMetricPresentation(
                value: val,
                unit: "g/s",
                compactText: "\(val) g/s",
                subtitle: t.mafGramsPerSec != nil ? "MAF (01 10)" : "Speed-Density",
                tint: .cyan,
                progress: (t.effectiveAirFlowGramsPerSec ?? 0) / 80.0,
                isAlerting: false
            )

        case .timingAdvance:
            let val = t.timingAdvanceDeg.map { String(format: "%+.1f", $0) } ?? "--"
            return GaugeMetricPresentation(
                value: val,
                unit: "°",
                compactText: "\(val)°",
                subtitle: "Avanço PMS",
                tint: .orange,
                progress: ((t.timingAdvanceDeg ?? 0) + 10.0) / 60.0,
                isAlerting: false
            )

        case .barometricPressure:
            let val = t.barometricPressureKpa.map { String(format: "%.0f", $0) } ?? "--"
            return GaugeMetricPresentation(
                value: val,
                unit: "kPa",
                compactText: "\(val) kPa",
                subtitle: "Atmosfera (01 33)",
                tint: .indigo,
                progress: (t.barometricPressureKpa ?? 100.0) / 110.0,
                isAlerting: false
            )

        case .fuelRailPressure:
            let val = t.fuelRailPressureKpa.map { String(format: "%.0f", $0) } ?? "--"
            return GaugeMetricPresentation(
                value: val,
                unit: "kPa",
                compactText: "\(val) kPa",
                subtitle: "Flauta (01 23)",
                tint: .orange,
                progress: (t.fuelRailPressureKpa ?? 0) / 5000.0,
                isAlerting: false
            )

        case .commandedEvapPurge:
            let val = t.commandedEvapPurgePct.map { String(format: "%.0f", $0) } ?? "--"
            return GaugeMetricPresentation(
                value: val,
                unit: "%",
                compactText: "\(val)%",
                subtitle: "Canister (01 2E)",
                tint: .teal,
                progress: (t.commandedEvapPurgePct ?? 0) / 100.0,
                isAlerting: false
            )

        case .estimatedPowerHp:
            let val = t.estimatedPowerHp.map { String(format: "%.0f", $0) } ?? "--"
            return GaugeMetricPresentation(
                value: val,
                unit: "cv",
                compactText: "\(val) cv",
                subtitle: "Potência Est.",
                tint: .orange,
                progress: (t.estimatedPowerHp ?? 0) / 150.0,
                isAlerting: false
            )

        case .estimatedTorqueNm:
            let val = t.estimatedTorqueNm.map { String(format: "%.0f", $0) } ?? "--"
            return GaugeMetricPresentation(
                value: val,
                unit: "Nm",
                compactText: "\(val) Nm",
                subtitle: "Torque Est.",
                tint: .pink,
                progress: (t.estimatedTorqueNm ?? 0) / 230.0,
                isAlerting: false
            )

        case .throttlePos:
            let val = t.throttlePositionPct.map { String(format: "%.0f", $0) } ?? "--"
            return GaugeMetricPresentation(
                value: val,
                unit: "%",
                compactText: "\(val)%",
                subtitle: "TBI (01 11)",
                tint: .pink,
                progress: (t.throttlePositionPct ?? 0) / 100.0,
                isAlerting: false
            )

        case .relativeThrottlePos:
            let val = t.relativeThrottlePct.map { String(format: "%.0f", $0) } ?? "--"
            return GaugeMetricPresentation(
                value: val,
                unit: "%",
                compactText: "\(val)%",
                subtitle: "TBI Rel. (01 45)",
                tint: .pink,
                progress: (t.relativeThrottlePct ?? 0) / 100.0,
                isAlerting: false
            )

        case .commandedThrottleActuator:
            let val = t.commandedThrottleActuatorPct.map { String(format: "%.0f", $0) } ?? "--"
            return GaugeMetricPresentation(
                value: val,
                unit: "%",
                compactText: "\(val)%",
                subtitle: "Atuador (01 4C)",
                tint: .indigo,
                progress: (t.commandedThrottleActuatorPct ?? 0) / 100.0,
                isAlerting: false
            )

        case .acceleratorPedalPosD:
            let val = t.acceleratorPedalDPct.map { String(format: "%.0f", $0) } ?? "--"
            return GaugeMetricPresentation(
                value: val,
                unit: "%",
                compactText: "\(val)%",
                subtitle: "Pedal D (01 49)",
                tint: .blue,
                progress: (t.acceleratorPedalDPct ?? 0) / 100.0,
                isAlerting: false
            )

        case .acceleratorPedalPosE:
            let val = t.acceleratorPedalEPct.map { String(format: "%.0f", $0) } ?? "--"
            return GaugeMetricPresentation(
                value: val,
                unit: "%",
                compactText: "\(val)%",
                subtitle: "Pedal E (01 4A)",
                tint: .cyan,
                progress: (t.acceleratorPedalEPct ?? 0) / 100.0,
                isAlerting: false
            )

        case .commandedEquivalenceRatio:
            let val = t.commandedLambdaRatio.map { String(format: "%.2f", $0) } ?? "--"
            return GaugeMetricPresentation(
                value: val,
                unit: "λ",
                compactText: "λ \(val)",
                subtitle: "Lambda (01 44)",
                tint: .green,
                progress: (t.commandedLambdaRatio ?? 1.0) / 1.5,
                isAlerting: false
            )

        case .lambdaO2Voltage:
            let val = t.lambdaO2VoltageMv.map { String(format: "%.0f", $0) } ?? "--"
            return GaugeMetricPresentation(
                value: val,
                unit: "mV",
                compactText: "\(val) mV",
                subtitle: "Pré-Cat (01 14)",
                tint: .pink,
                progress: (t.lambdaO2VoltageMv ?? 450.0) / 1000.0,
                isAlerting: false
            )

        case .lambdaO2Sensor2:
            let val = t.lambdaO2Sensor2Mv.map { String(format: "%.0f", $0) } ?? "--"
            return GaugeMetricPresentation(
                value: val,
                unit: "mV",
                compactText: "\(val) mV",
                subtitle: "Pós-Cat (01 15)",
                tint: .purple,
                progress: (t.lambdaO2Sensor2Mv ?? 600.0) / 1000.0,
                isAlerting: false
            )

        case .coolantTemp:
            let val = t.coolantTempC.map { String(format: "%.0f", $0) } ?? "--"
            let over = (t.coolantTempC ?? 0) >= th.coolant.warningThresholdC
            let sub = over
                ? "ALERTA ≥\(Int(th.coolant.warningThresholdC))°C"
                : "IAT \(t.intakeAirTempC.map { "\(Int($0))°C" } ?? "--°C")"
            return GaugeMetricPresentation(
                value: val,
                unit: "°C",
                compactText: "\(val)°C",
                subtitle: sub,
                tint: over ? .red : .blue,
                progress: ((t.coolantTempC ?? 40) - 40) / 85.0,
                isAlerting: over
            )

        case .cvtTemp:
            let val = t.transmissionTempC.map { String(format: "%.0f", $0) } ?? "--"
            let over = (t.transmissionTempC ?? 0) >= th.transmission.thermalInterventionC
            let sub: String
            if t.transmissionTempSuspect {
                sub = "Leitura suspeita (validando)"
            } else if over {
                sub = "ALERTA ≥\(Int(th.transmission.thermalInterventionC))°C"
            } else {
                sub = "OK ≤\(Int(th.transmission.heavyLoadNormalMaxC))°C"
            }
            return GaugeMetricPresentation(
                value: val,
                unit: "°C",
                compactText: "\(val)°C",
                subtitle: sub,
                tint: t.transmissionTempSuspect ? Color.secondary : (over ? .red : .teal),
                progress: t.transmissionTempSuspect ? 0 : ((t.transmissionTempC ?? 40) - 40) / 90.0,
                isAlerting: over && !t.transmissionTempSuspect
            )

        case .intakeAirTemp:
            let val = t.intakeAirTempC.map { String(format: "%.0f", $0) } ?? "--"
            return GaugeMetricPresentation(
                value: val,
                unit: "°C",
                compactText: "\(val)°C",
                subtitle: "Pós-Intercooler",
                tint: .cyan,
                progress: ((t.intakeAirTempC ?? 20) - 10) / 65.0,
                isAlerting: false
            )

        case .ambientTemp:
            let val = t.effectiveExternalTempC.map { String(format: "%.0f", $0) } ?? "--"
            return GaugeMetricPresentation(
                value: val,
                unit: "°C",
                compactText: "\(val)°C",
                subtitle: t.ambientTempC != nil ? "Sensor Ext." : "Adm. IAT",
                tint: .cyan,
                progress: ((t.effectiveExternalTempC ?? 15) - 5) / 40.0,
                isAlerting: false
            )

        case .catalystTempB1S1:
            // Catalisador trabalha entre ~400 °C e ~900 °C quando quente: isso é normal, não alerta.
            // Faixas: <300 aquecendo · 300–850 normal · 850–920 alta · >920 proteção.
            let val = t.catalystTempB1S1C.map { String(format: "%.0f", $0) } ?? "--"
            let cat = t.catalystTempB1S1C ?? 0
            let sub: String
            let tint: Color
            if t.catalystTempB1S1C == nil {
                sub = "B1S1 (01 3C)"
                tint = Color.secondary
            } else if cat >= 920 {
                sub = "ACIMA DA FAIXA (≥920°C)"
                tint = .red
            } else if cat >= 850 {
                sub = "Alta (850–920°C)"
                tint = .orange
            } else if cat >= 300 {
                sub = "Normal (400–800°C)"
                tint = .teal
            } else {
                sub = "Aquecendo (<300°C)"
                tint = Color.secondary
            }
            return GaugeMetricPresentation(
                value: val,
                unit: "°C",
                compactText: "\(val)°C",
                subtitle: sub,
                tint: tint,
                progress: min(max(cat / 950.0, 0.0), 1.0),
                isAlerting: cat >= 920
            )

        case .engineOilTemp:
            let val = t.engineOilTempC.map { String(format: "%.0f", $0) } ?? "--"
            let over = (t.engineOilTempC ?? 0) >= 125.0
            return GaugeMetricPresentation(
                value: val,
                unit: "°C",
                compactText: "\(val)°C",
                subtitle: "Óleo (01 5C)",
                tint: over ? .red : .orange,
                progress: ((t.engineOilTempC ?? 40.0) - 40.0) / 90.0,
                isAlerting: over
            )

        case .batteryVoltage:
            let val = t.batteryVoltage.map { String(format: "%.2f", $0) } ?? "--"
            let health = t.batteryHealthAssessment
            let over = health.level == .critical
            return GaugeMetricPresentation(
                value: val,
                unit: "V",
                compactText: "\(val)V",
                subtitle: "Carga \(health.socPercent)%",
                tint: over ? .red : .green,
                progress: ((t.batteryVoltage ?? 11.5) - 11.0) / 4.0,
                isAlerting: over
            )

        case .ecuModuleVoltage:
            let val = t.ecuModuleVoltage.map { String(format: "%.2f", $0) } ?? "--"
            return GaugeMetricPresentation(
                value: val,
                unit: "V",
                compactText: "\(val)V",
                subtitle: "Placa ECU (01 42)",
                tint: .mint,
                progress: ((t.ecuModuleVoltage ?? 11.5) - 11.0) / 4.0,
                isAlerting: false
            )

        case .tcuOdometer:
            let val = t.tcuOdometerKm.map { String(format: "%.0f", $0) } ?? "--"
            return GaugeMetricPresentation(
                value: val,
                unit: "km",
                compactText: "\(val) km",
                subtitle: "UDS 22 0B5B",
                tint: .indigo,
                progress: 0.75,
                isAlerting: false
            )

        case .engineRunTime:
            let sec = t.engineRunTimeSec ?? 0
            let minVal = sec / 60
            let val = t.engineRunTimeSec != nil ? "\(minVal)" : "--"
            return GaugeMetricPresentation(
                value: val,
                unit: "min",
                compactText: "\(val) min",
                subtitle: "Ligado (01 1F)",
                tint: .cyan,
                progress: min(Double(sec) / 3600.0, 1.0),
                isAlerting: false
            )

        case .distanceSinceDTCClear:
            let val = t.distanceSinceDTCClearKm.map { String(format: "%.0f", $0) } ?? "--"
            return GaugeMetricPresentation(
                value: val,
                unit: "km",
                compactText: "\(val) km",
                subtitle: "Pós-Reset (01 31)",
                tint: .blue,
                progress: 0.6,
                isAlerting: false
            )

        case .warmUpsSinceDTCClear:
            let val = t.warmUpsSinceDTCClear.map { "\($0)" } ?? "--"
            return GaugeMetricPresentation(
                value: val,
                unit: "ciclos",
                compactText: "\(val)x",
                subtitle: "Aquec. (01 30)",
                tint: .orange,
                progress: min(Double(t.warmUpsSinceDTCClear ?? 0) / 40.0, 1.0),
                isAlerting: false
            )

        case .timeSinceDTCClear:
            let mins = t.timeSinceDTCClearMin
            let val = mins.map { $0 >= 120 ? "\($0 / 60)" : "\($0)" } ?? "--"
            let unit = (mins ?? 0) >= 120 ? "h" : "min"
            return GaugeMetricPresentation(
                value: val,
                unit: unit,
                compactText: "\(val) \(unit)",
                subtitle: "Tempo (01 4E)",
                tint: .teal,
                progress: 0.5,
                isAlerting: false
            )

        case .distanceWithMILOn:
            let val = t.distanceWithMILOnKm.map { String(format: "%.0f", $0) } ?? "--"
            let milActive = (t.distanceWithMILOnKm ?? 0) > 0
            return GaugeMetricPresentation(
                value: val,
                unit: "km",
                compactText: "\(val) km",
                subtitle: "Luz MIL (01 21)",
                tint: milActive ? .red : .green,
                progress: milActive ? 1.0 : 0.1,
                isAlerting: milActive
            )
        }
    }
}

// MARK: - Sheet de Seleção / Substituição de Sensor com Explicação (Toque Longo no App ou CarPlay)

struct SensorReplacementSheetView: View {
    @EnvironmentObject var store: CarSenseiStore
    @Environment(\.dismiss) private var dismiss

    let currentGauge: CockpitGaugeID
    let onSelectReplacement: (CockpitGaugeID) -> Void

    @State private var searchText: String = ""
    @State private var selectedCategory: String = "Todos"

    private let categories = [
        "Todos",
        "Consumo & Combustível Flex",
        "Motor, Turbo & Performance",
        "Pedal, Borboleta & Sondas",
        "Temperaturas & Térmica",
        "Elétrica, Odômetros & ECU"
    ]

    private var filteredGauges: [CockpitGaugeID] {
        CockpitGaugeID.allCases.filter { gauge in
            let matchesCategory = (selectedCategory == "Todos") || (gauge.category == selectedCategory)
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let matchesSearch = q.isEmpty
                || gauge.title.lowercased().contains(q)
                || gauge.shortCarPlayLabel.lowercased().contains(q)
                || gauge.summaryDescription.lowercased().contains(q)
                || gauge.pidBadge.lowercased().contains(q)
            return matchesCategory && matchesSearch
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Cabeçalho destacando o sensor que será substituído + filtro por categoria
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Substituindo: \(currentGauge.title)")
                                .font(.subheadline.weight(.heavy))
                                .foregroundStyle(.primary)
                            Text("Toque em qualquer um dos \(CockpitGaugeID.allCases.count) sensores abaixo para colocar neste lugar.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(categories, id: \.self) { cat in
                                let active = selectedCategory == cat
                                Button {
                                    selectedCategory = cat
                                } label: {
                                    Text(cat == "Todos" ? "Todos (\(CockpitGaugeID.allCases.count))" : cat)
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(active ? Color.blue : Color.secondary.opacity(0.12), in: Capsule())
                                        .foregroundStyle(active ? Color.white : .primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                    }
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground))

                List {
                    ForEach(filteredGauges) { gauge in
                        let pres = store.presentation(for: gauge)
                        let isCurrent = (gauge == currentGauge)

                        Button {
                            onSelectReplacement(gauge)
                            dismiss()
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: gauge.iconName)
                                    .font(.headline)
                                    .foregroundStyle(pres.tint)
                                    .frame(width: 32, height: 32)
                                    .background(pres.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(gauge.title)
                                            .font(.subheadline.weight(.bold))
                                            .foregroundStyle(.primary)

                                        if isCurrent {
                                            Text("ATUAL")
                                                .font(.system(size: 9, weight: .black))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 2)
                                                .background(Color.blue.opacity(0.16), in: Capsule())
                                                .foregroundStyle(.blue)
                                        }
                                    }

                                    Text(gauge.summaryDescription)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)

                                    Text("\(gauge.category) • \(gauge.pidBadge)")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(pres.tint)
                                }

                                Spacer(minLength: 6)

                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(pres.compactText)
                                        .font(.system(.subheadline, design: .rounded).weight(.black))
                                        .foregroundStyle(pres.tint)
                                        .monospacedDigit()
                                    Text("Ao vivo")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .searchable(text: $searchText, prompt: "Buscar entre os \(CockpitGaugeID.allCases.count) sensores...")
            .navigationTitle("Escolher Sensor (\(CockpitGaugeID.allCases.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fechar") { dismiss() }
                }
            }
        }
    }
}

struct GaugeCustomizationSheetView: View {
    @EnvironmentObject var store: CarSenseiStore
    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""

    private var filteredGauges: [CockpitGaugeID] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return CockpitGaugeID.allCases }
        return CockpitGaugeID.allCases.filter {
            $0.title.lowercased().contains(q)
                || $0.summaryDescription.lowercased().contains(q)
                || $0.category.lowercased().contains(q)
                || $0.pidBadge.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(filteredGauges) { gauge in
                        let pres = store.presentation(for: gauge)
                        Button {
                            store.toggleGauge(gauge)
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: gauge.iconName)
                                    .font(.headline)
                                    .foregroundStyle(store.isGaugeEnabled(gauge) ? pres.tint : .secondary)
                                    .frame(width: 28, height: 28)
                                    .background(pres.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(gauge.title)
                                            .font(.subheadline.weight(.bold))
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        Text(pres.compactText)
                                            .font(.caption.weight(.black).monospacedDigit())
                                            .foregroundStyle(pres.tint)
                                    }
                                    Text(gauge.summaryDescription)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text("\(gauge.category) • \(gauge.pidBadge)")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(pres.tint)
                                }

                                Image(systemName: store.isGaugeEnabled(gauge) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(store.isGaugeEnabled(gauge) ? .green : .secondary)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                } header: {
                    Text("Catálogo Completo (\(CockpitGaugeID.allCases.count) Sensores • Segure um card na Home ou CarPlay para substituir)")
                } footer: {
                    Text("Dica: Você também pode manter pressionado qualquer sensor na tela inicial do iPhone ou na tela do CarPlay para substituí-lo por outro na hora.")
                }

                Section {
                    Button("Exibir Todos os \(CockpitGaugeID.allCases.count) Sensores no App") {
                        store.enableAllGauges()
                    }
                    Button("Restaurar Layout Padrão do CarPlay (22 Slots)") {
                        store.resetCarPlaySlotsToDefault()
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Buscar sensor ou explicação...")
            .navigationTitle("Sensores (\(CockpitGaugeID.allCases.count) Disponíveis)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Concluir") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Gauge Card Component (Light Automotive Style)
struct GaugeCard: View {
    let title: String
    let value: String
    let unit: String
    let subtitle: String
    let icon: String
    let accent: Color
    let progress: Double

    /// Progresso saneado: telemetria sem leitura pode chegar como NaN/infinito e o `frame(width:)` não aceita isso.
    private var safeProgress: Double {
        guard progress.isFinite else { return 0.04 }
        return min(max(progress, 0.04), 1.0)
    }


    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .font(.subheadline.bold())
                    .foregroundStyle(accent)
                    .frame(width: 28, height: 28)
                    .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Tema.textoSuave)
                    .lineLimit(1)
                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(.title, design: .rounded, weight: .black))
                    .foregroundStyle(Tema.texto)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(unit)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(accent)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Tema.trilho)
                    Capsule()
                        .fill(accent)
                        .frame(width: geo.size.width * safeProgress)
                        .animation(.easeOut(duration: 0.25), value: progress)
                }
            }
            .frame(height: 6)

            Text(subtitle)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Tema.textoSuave)
                .lineLimit(1)
        }
        .padding(14)
        .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Tema.borda, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.03), radius: 5, x: 0, y: 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(value) \(unit), \(subtitle)")
    }
}

struct IdentityRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(Tema.textoSuave)
            Spacer()
            Text(value)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(Tema.texto)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - BLE Scanner Sheet
struct BLEScannerSheetView: View {
    @EnvironmentObject var store: CarSenseiStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if store.discoveredDevices.isEmpty {
                        HStack(spacing: 12) {
                            if store.connectionState == .scanning { ProgressView() }
                            Text(store.connectionState == .scanning ? "Procurando vLinker MC-IOS ou scanner BLE..." : store.statusBannerText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    } else {
                        ForEach(store.discoveredDevices) { adapter in
                            Button {
                                store.connectToDevice(adapter.id)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 6) {
                                            Text(adapter.name)
                                                .font(.headline)
                                                .foregroundStyle(.primary)
                                            if adapter.isPreferredVLinker {
                                                Text("RECOMENDADO • PRO")
                                                    .font(.caption2.weight(.heavy))
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.blue.opacity(0.14), in: Capsule())
                                                    .foregroundStyle(.blue)
                                            }
                                        }
                                        Text(adapter.id.uuidString)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("\(adapter.rssi) dBm")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Scanners Bluetooth LE (4.0+) Encontrados")
                } footer: {
                    Text("Para recursos avançados (auditoria de KM, câmbio CVT, ar-condicionado e multimódulos), recomendamos o Vgate vLinker MC+ (BLE).")
                }
            }
            .navigationTitle("Conectar Scanner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fechar") { dismiss() }
                        .frame(minHeight: 44)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Atualizar") { store.startManualScan() }
                        .frame(minHeight: 44)
                }
            }
            .onAppear {
                store.startManualScan()
            }
        }
    }
}

// MARK: - Histórico de Veículos Detectados Automaticamente
struct ConnectedVehiclesHistorySheetView: View {
    @EnvironmentObject var store: CarSenseiStore
    @Environment(\.dismiss) private var dismiss
    @State private var showConfirmClearAll = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if store.connectedVehiclesHistory.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(store.vehicleIdentity.modelDescription)
                                .font(.headline)
                            Text("VIN: \(store.vehicleIdentity.vin)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text("Assim que você conectar o scanner em qualquer veículo, o CarSensei lê o chassi (VIN) automaticamente pelo barramento CAN e salva no histórico.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    } else {
                        ForEach(store.connectedVehiclesHistory) { car in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: "car.fill")
                                        .foregroundStyle(Color.blue)
                                    Text(car.modelDescription)
                                        .font(.headline)
                                    Spacer()
                                    if let km = car.lastKnownOdometerKm {
                                        Text(String(format: "%.0f km", km))
                                            .font(.caption.weight(.bold).monospacedDigit())
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(Color.blue.opacity(0.12), in: Capsule())
                                            .foregroundStyle(Color.blue)
                                    }
                                }

                                Text("\(car.engineCode) • \(car.transmissionCode)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                HStack {
                                    Text("VIN: \(car.vin)")
                                        .font(.caption2.monospaced().weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text(car.lastConnectedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .onDelete { offsets in
                            store.deleteConnectedVehicles(at: offsets)
                        }
                    }
                } header: {
                    HStack {
                        Text("Veículos Reconhecidos (\(store.connectedVehiclesHistory.count))")
                        Spacer()
                        if !store.connectedVehiclesHistory.isEmpty {
                            Text("Deslize para apagar")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("O CarSensei detecta automaticamente o modelo, motor e câmbio pela leitura do chassi (VIN 22 F1 90 / 09 02) e da calibração da injeção ao conectar no carro.")
                }
            }
            .navigationTitle("Histórico de Veículos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !store.connectedVehiclesHistory.isEmpty {
                        Button(role: .destructive) {
                            showConfirmClearAll = true
                        } label: {
                            Text("Limpar Tudo")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.red)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fechar") { dismiss() }
                }
            }
            .confirmationDialog(
                "Limpar Histórico de Veículos?",
                isPresented: $showConfirmClearAll,
                titleVisibility: .visible
            ) {
                Button("Limpar Todo o Histórico", role: .destructive) {
                    store.clearConnectedVehiclesHistory()
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Esta ação remove todos os veículos salvos e registros de falhas antigas de outros veículos.")
            }
        }
    }
}


// MARK: - Registro de Abastecimento (calibra a média do OBD com a bomba)

struct FuelFillUpSheet: View {
    @EnvironmentObject var store: CarSenseiStore
    @Environment(\.dismiss) private var dismiss

    @State private var odometro: String = ""
    @State private var litros: String = ""
    @State private var capacidade: String = ""
    @State private var erro: String?

    init(initialOdometerKm: Double? = nil, initialLiters: Double? = nil) {
        _odometro = State(initialValue: initialOdometerKm.map { String(format: "%.0f", $0) } ?? "")
        _litros = State(initialValue: initialLiters.map { String(format: "%.1f", $0) } ?? "")
        _capacidade = State(initialValue: "")
    }

    private var odometroKm: Double? {
        Double(odometro.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: "."))
    }
    private var litrosL: Double? {
        Double(litros.replacingOccurrences(of: ",", with: "."))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Odômetro do painel (km)", text: $odometro)
                        .keyboardType(.numberPad)
                    TextField("Litros abastecidos", text: $litros)
                        .keyboardType(.decimalPad)
                    TextField("Capacidade do tanque (L)", text: $capacidade)
                        .keyboardType(.decimalPad)
                } header: {
                    Text("Abastecimento")
                } footer: {
                    Text("Serve para duas coisas: calcular a média real entre tanques e corrigir a estimativa do app (fator atual \(String(format: "%.2f", store.fuelCalibrationFactor))). Registre sempre com o tanque cheio para o cálculo valer.")
                }

                if let real = store.lastFillUp?.realKmPerLiter {
                    Section("Último abastecimento") {
                        LabeledContent("Média real", value: String(format: "%.1f km/L", real))
                        LabeledContent("Fator aplicado", value: String(format: "%.2f", store.fuelCalibrationFactor))
                    }
                }

                Section {
                    LabeledContent("Estimado pelo app", value: String(format: "%.1f km", store.kmSinceFillUp))
                    LabeledContent("Combustível estimado", value: String(format: "%.2f L", store.litersSinceFillUp))
                } footer: {
                    Text("Trecho acumulado desde o último abastecimento registrado.")
                }

                if let erro {
                    Section { Text(erro).font(.caption).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Registrar Abastecimento")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        guard let km = odometroKm, let l = litrosL, km > 0, l > 5 else {
                            erro = "Informe o odômetro e os litros (mais de 5 L)."
                            return
                        }
                        if let cap = Double(capacidade.replacingOccurrences(of: ",", with: ".")), cap > 20, cap < 150 {
                            store.tankCapacityLiters = cap
                        } else if !capacidade.isEmpty {
                            erro = "Capacidade do tanque inválida."
                            return
                        }
                        store.confirmPendingFillUp(odometerKm: km, liters: l)
                        dismiss()
                    }
                    .disabled(odometroKm == nil || litrosL == nil)
                }
            }
        }
    }
}
