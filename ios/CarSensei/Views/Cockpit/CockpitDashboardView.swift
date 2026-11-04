import SwiftUI

struct CockpitDashboardView: View {
    @EnvironmentObject var store: CarSenseiStore
    @State private var showScannerSheet = false
    @State var showGaugeCustomizationSheet = false
    @State var gaugeBeingReplaced: CockpitGaugeID?
    @State private var showMultimediaMirror = false
    @State private var showFeedbackSheet = false
    @State private var showVehicleHistorySheet = false
    @State var showFuelFillUpSheet = false

    @AppStorage("cockpit.card.vehicle.expanded.v2") var isVehicleCardExpanded = false
    @AppStorage("cockpit.card.battery.expanded.v2") var isBatteryCardExpanded = false
    @AppStorage("cockpit.card.fuel.expanded.v2") var isFuelCardExpanded = true
    @AppStorage("cockpit.card.fuel.history.expanded.v2") var isFuelHistoryExpanded = false
    @AppStorage("cockpit.card.odometer.expanded.v2") var isOdometerCardExpanded = false
    @AppStorage("cockpit.card.gauges.expanded.v2") var isGaugesCardExpanded = true
    @AppStorage("cockpit.gauges.showAll.v2") var showAllGauges = false

    let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]


    var body: some View {
        NavigationStack {
            ZStack {
                Tema.fundo.ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 14) {
                        unifiedVehicleConnectionCard

                        if let thermalWarning = store.activeThermalGuardianBanner {
                            thermalGuardianAlertBanner(warning: thermalWarning)
                        }

                        customizeGaugesHeader
                        liveGaugesGrid
                        fuelEconomyComputerCard
                        batteryAndVLinkerStandbyCard
                        odometerForensicsHomeBlock
                        senseiHealthBanner
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 28)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("CarSensei")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 10) {
                        Button {
                            showGaugeCustomizationSheet = true
                        } label: {
                            Label("Painel", systemImage: "slider.horizontal.3")
                                .font(.caption.weight(.bold))
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }

                        Button {
                            showMultimediaMirror = true
                        } label: {
                            Label("Multimídia", systemImage: "carplay")
                                .font(.caption.weight(.bold))
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 10) {
                        Button {
                            showFeedbackSheet = true
                        } label: {
                            Image(systemName: "bubble.left.and.exclamationmark.bubble.right.fill")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.purple)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Relatar Feedback")

                        Button {
                            showScannerSheet = true
                        } label: {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(statusColor)
                                    .frame(width: 8, height: 8)
                                Text(store.connectionState == .connectedReady ? "vLinker ON" : "Conectar")
                                    .font(.caption.weight(.bold))
                            }
                            .padding(.horizontal, 10)
                            .frame(minHeight: 44)
                            .background(Color.blue.opacity(0.10), in: Capsule())
                            .contentShape(Capsule())
                        }
                    }
                }
            }
            .sheet(isPresented: $showScannerSheet) {
                BLEScannerSheetView()
                    .environmentObject(store)
            }
            .sheet(isPresented: $showGaugeCustomizationSheet) {
                GaugeCustomizationSheetView()
                    .environmentObject(store)
            }
            .sheet(item: $gaugeBeingReplaced) { targetGauge in
                SensorReplacementSheetView(currentGauge: targetGauge) { replacement in
                    store.replaceCockpitGauge(targetGauge, with: replacement)
                }
                .environmentObject(store)
            }
            .sheet(isPresented: $showFeedbackSheet) {
                TissotFeedbackSheet()
            }
            .sheet(isPresented: $showFuelFillUpSheet) {
                FuelFillUpSheet()
                    .environmentObject(store)
            }
            .sheet(isPresented: $showVehicleHistorySheet) {
                ConnectedVehiclesHistorySheetView()
                    .environmentObject(store)
            }
            .fullScreenCover(isPresented: $showMultimediaMirror) {
                MultimediaMirrorDashboardView()
                    .environmentObject(store)
            }
        }
        .tissotScreen("Cockpit Principal")
    }

    private var statusColor: Color {
        switch store.connectionState {
        case .connectedReady: return .green
        case .scanning, .connecting, .initializingProtocol: return .orange
        case .error, .bluetoothOff: return .red
        case .disconnected: return .gray
        }
    }

    // MARK: - Unified Vehicle & Connection Card
    private var unifiedVehicleConnectionCard: some View {
        let isPro = store.vehicleIdentity.adapterTier.isAdvancedVLinker
        let id = store.vehicleIdentity

        return VStack(alignment: .leading, spacing: 12) {
            // 1. Vehicle Identification Header (top of card)
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(id.cleanModelTitle.uppercased())
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(Tema.texto)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)

                        Text(isPro ? "PRO" : "OBD")
                            .font(.system(size: 10, weight: .black))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(isPro ? Color.blue.opacity(0.15) : Color.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(isPro ? Color.blue : Color.orange)
                    }

                    Text("\(id.engineCode) • \(id.transmissionCode)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Tema.textoSuave)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isVehicleCardExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text("Ficha ECU")
                            .font(.caption2.weight(.bold))
                        Image(systemName: isVehicleCardExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(Tema.texto)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Tema.fundo, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            // 2. Status message row
            Text(store.statusBannerText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Tema.textoSuave)
                .lineLimit(1)

            // 3. Expandable details (ECU identity & vehicle history)
            if isVehicleCardExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    Divider()
                    IdentityRow(label: "Scanner", value: "\(id.adapterFirmware) (\(id.adapterTier.rawValue))")
                    IdentityRow(label: "Protocolo CAN", value: id.obdProtocol)
                    IdentityRow(label: "VIN (Chassi)", value: id.vin)
                    IdentityRow(label: "Módulo ECM", value: id.ecuName)
                    IdentityRow(label: "Calibração", value: id.calibrationId)

                    Button {
                        showVehicleHistorySheet = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.arrow.circlepath")
                            Text("Histórico de Veículos Conectados (\(max(1, store.connectedVehiclesHistory.count)))")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Tema.fundo, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(Color.blue)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
            }

            Divider()

            // 4. Primary Actions
            HStack(spacing: 10) {
                if store.connectionState == .connectedReady {
                    Button {
                        if store.isLivePolling {
                            store.stopTelemetryLoop()
                        } else {
                            store.startTelemetryLoop()
                        }
                    } label: {
                        Label(
                            store.isLivePolling ? "Pausar Telemetria" : "Iniciar Telemetria",
                            systemImage: store.isLivePolling ? "pause.fill" : "play.fill"
                        )
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(store.isLivePolling ? Color.orange : Color.blue, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.white)
                    }

                    Button(role: .destructive) {
                        store.disconnect()
                    } label: {
                        Image(systemName: "power")
                            .font(.subheadline.weight(.bold))
                            .padding(11)
                            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(.red)
                    }
                } else {
                    Button {
                        store.startAutoConnect()
                        showScannerSheet = true
                    } label: {
                        Label("Conectar vLinker MC+ / Scanner BLE", systemImage: "bolt.horizontal.circle.fill")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                LinearGradient(
                                    colors: [Color.blue, Color.indigo],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                in: RoundedRectangle(cornerRadius: 12)
                            )
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .padding(16)
        .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(statusColor.opacity(0.35), lineWidth: 1.2)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 3)
    }

    // MARK: - Thermal Guardian Alert Banner
    private func thermalGuardianAlertBanner(warning: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "thermometer.high")
                .font(.title2.bold())
                .foregroundStyle(.white)
                .padding(10)
                .background(Color.white.opacity(0.2), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text("GUARDIÃO TÉRMICO ATIVO")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.white.opacity(0.9))
                Text(warning)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
            }
            Spacer()
        }
        .padding(14)
        .background(
            LinearGradient(colors: [Color.red, Color.orange], startPoint: .leading, endPoint: .trailing),
            in: RoundedRectangle(cornerRadius: 18)
        )
    }

    // MARK: - Sensei Health Summary Banner
    private var senseiHealthBanner: some View {
        let count = store.activeFaults.count
        let activeCount = store.activeFaults.filter(\.isActiveNow).count

        return HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill((activeCount > 0 ? Color.red : (count > 0 ? Color.orange : Color.green)).opacity(0.14))
                    .frame(width: 48, height: 48)
                Image(systemName: activeCount > 0 ? "exclamationmark.octagon.fill" : (count > 0 ? "clock.badge.exclamationmark.fill" : "checkmark.shield.fill"))
                    .font(.title3.bold())
                    .foregroundStyle(activeCount > 0 ? .red : (count > 0 ? .orange : .green))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(
                    count == 0
                    ? "Sem alertas registrados na última leitura"
                    : "\(count) código(s) detectados (\(activeCount) ativos / \(count - activeCount) histórico)"
                )
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Tema.texto)

                Text(
                    count == 0
                    ? "Conecte ao carro ou abra a aba Diagnóstico para varredura completa."
                    : "Abra a aba Diagnóstico para alternar entre Visão Cliente Simples e Mecânico."
                )
                .font(.caption)
                .foregroundStyle(Tema.textoSuave)
            }
            Spacer()
        }
        .padding(14)
        .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Tema.borda, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.03), radius: 6, x: 0, y: 2)
    }

    // MARK: - ECU Identity Footer
    private var ecuIdentityFooter: some View {
        let id = store.vehicleIdentity
        return VStack(alignment: .leading, spacing: 8) {
            Text("IDENTIFICAÇÃO REAL DO VEÍCULO")
                .font(.caption2.weight(.heavy))
                .foregroundStyle(Tema.textoSuave)
                .tracking(1)

            IdentityRow(label: "Montadora / Modelo", value: id.modelDescription)
            IdentityRow(label: "Scanner Conectado", value: "\(id.adapterFirmware) (\(id.adapterTier.rawValue))")
            IdentityRow(label: "Protocolo CAN", value: id.obdProtocol)
            IdentityRow(label: "VIN (Chassi)", value: id.vin)
            IdentityRow(label: "Módulo ECM", value: id.ecuName)
            IdentityRow(label: "Calibração", value: id.calibrationId)
        }
        .padding(16)
        .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Tema.borda, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.03), radius: 6, x: 0, y: 2)
    }
}

// MARK: - Gauge Customization Sheet
