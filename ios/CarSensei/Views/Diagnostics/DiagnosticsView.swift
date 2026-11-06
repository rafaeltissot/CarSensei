import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject var store: CarSenseiStore
    @State private var selectedFault: DiagnosticFault?
    @State private var showClearConfirmation = false
    @State private var showFeedbackSheet = false
    @State private var showOtherVehiclesHistory = false


    var body: some View {
        NavigationStack {
            ZStack {
                Tema.fundo.ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 16) {
                        scanActionsCard

                        if store.isScanningDTCs {
                            HStack(spacing: 12) {
                                ProgressView()
                                    .tint(.blue)
                                Text(store.dtcScanProgressText.isEmpty ? "Consultando módulos via UDS / OBD-II..." : store.dtcScanProgressText)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Tema.textoSuave)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(16)
                            .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 16))
                        }

                        if store.activeFaults.isEmpty && store.lastDTCScanDate == nil && !store.archivedFaultsForCurrentVehicle.isEmpty {
                            // Antes da primeira varredura desta sessão: mostra somente o histórico salvo deste veículo (VIN).
                            Label("Histórico salvo de \(store.vehicleIdentity.cleanModelTitle). Escaneie novamente para confirmar o que segue ativo.", systemImage: "clock.arrow.circlepath")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Tema.textoSuave)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            ForEach(store.archivedFaultsForCurrentVehicle) { fault in
                                FaultInterpreterCard(fault: fault) {
                                    selectedFault = fault
                                }
                                .opacity(0.75)
                            }
                        } else if store.activeFaults.isEmpty && store.dtcScanNoResponse {
                            noResponseCard
                        } else if store.activeFaults.isEmpty {
                            emptyFaultsCard
                        } else {
                            ForEach(store.activeFaults) { fault in
                                FaultInterpreterCard(fault: fault) {
                                    selectedFault = fault
                                }
                            }
                        }

                        if !store.archivedFaultsForOtherVehicles.isEmpty {
                            otherVehiclesArchivedSection
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("Diagnóstico Inteligente")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ConexaoPilula() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showFeedbackSheet = true
                    } label: {
                        Label("Feedback", systemImage: "bubble.left.and.exclamationmark.bubble.right.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.purple)
                    }
                }
            }
            .sheet(item: $selectedFault) { fault in
                FaultDetailSheetView(fault: fault)
                    .environmentObject(store)
            }
            .sheet(isPresented: $showFeedbackSheet) {
                TissotFeedbackSheet()
            }
            .confirmationDialog(
                "Limpar códigos de falha (Exige Ignição Ligada e Motor Desligado)?",
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Validar KOEO (0 RPM) e Limpar Falhas", role: .destructive) {
                    Task {
                        await store.clearAllFaults()
                    }
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("SEGURANÇA VEICULAR (KOEO): O motor DEVE estar desligado (0 RPM) com a ignição ligada (painel aceso) e o carro parado. Além disso, apagar os códigos zera os contadores desde a última limpeza (PID 01 30 e 01 31).")
            }
            .alert(
                "Trava de Segurança Veicular (KOEO)",
                isPresented: Binding(
                    get: { store.clearFaultsSafetyError != nil },
                    set: { if !$0 { store.clearFaultsSafetyError = nil } }
                )
            ) {
                Button("Entendi", role: .cancel) {
                    store.clearFaultsSafetyError = nil
                }
            } message: {
                Text(store.clearFaultsSafetyError ?? "")
            }
        }
        .tissotScreen("Diagnóstico Inteligente")
    }

    private var scanActionsCard: some View {
        let ready = store.connectionState == .connectedReady
        let koeo = store.koeoClearSafetyAssessment
        return VStack(alignment: .leading, spacing: 12) {
            Text("Varredura inteligente nos módulos de injeção, câmbio, ar-condicionado, carroceria e freios com tradução em linguagem simples e dados técnicos de engenharia.")
            .font(.caption)
            .foregroundStyle(Tema.textoSuave)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: koeo.canClear ? "lock.open.shield.fill" : "lock.shield.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(koeo.canClear ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("PROTEÇÃO DE LIMPEZA (NORMA KOEO): \(koeo.badgeText)")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(koeo.canClear ? Color.green : Color.orange)
                    Text(koeo.detailText)
                        .font(.caption2)
                        .foregroundStyle(Tema.textoSuave)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((koeo.canClear ? Color.green : Color.orange).opacity(0.10), in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 10) {
                Button {
                    Task { await store.runFullDiagnosticScan() }
                } label: {
                    Label("Escanear Veículo", systemImage: "magnifyingglass.circle.fill")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            ready ? Color.blue : Color.gray.opacity(0.25),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .foregroundStyle(ready ? .white : Tema.textoSuave)
                }
                .disabled(!ready || store.isScanningDTCs)

                Button(role: .destructive) {
                    if koeo.canClear {
                        showClearConfirmation = true
                    } else {
                        store.clearFaultsSafetyError = koeo.detailText
                    }
                } label: {
                    Label("Limpar", systemImage: koeo.canClear ? "trash.fill" : "lock.fill")
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.red)
                }
                .disabled(!ready || store.isScanningDTCs)
            }
        }
        .padding(16)
        .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Tema.borda, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.03), radius: 6, x: 0, y: 2)
    }

    private var emptyFaultsCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)

            Text(store.lastDTCScanDate == nil ? "Veículo ainda não escaneado" : "Nenhuma falha encontrada na última varredura")
                .font(.headline.weight(.bold))
                .foregroundStyle(Tema.texto)

            Text("Conecte ao vLinker MC+ e toque em 'Escanear Veículo' para verificar todos os módulos eletrônicos.")
                .font(.caption)
                .foregroundStyle(Tema.textoSuave)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Tema.borda, lineWidth: 1)
        )
    }

    /// Nenhum módulo respondeu: isto NÃO é "carro sem falhas".
    private var noResponseCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.slash.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)

            Text("Nenhum módulo respondeu")
                .font(.headline.weight(.bold))
                .foregroundStyle(Tema.texto)

            Text("A varredura não recebeu resposta do carro, então não é possível afirmar que está tudo bem. Confira a ignição ligada (painel aceso), o adaptador no conector OBD e tente de novo.")
                .font(.caption)
                .foregroundStyle(Tema.textoSuave)
                .multilineTextAlignment(.center)

            Button {
                Task { await store.runFullDiagnosticScan() }
            } label: {
                Label("Escanear novamente", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.bold))
                    .frame(minHeight: 44)
                    .padding(.horizontal, 16)
                    .background(Color.orange.opacity(0.15), in: Capsule())
            }
            .disabled(store.connectionState != .connectedReady || store.isScanningDTCs)
            .foregroundStyle(.orange)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
        )
    }

    private var otherVehiclesArchivedSection: some View {
        let otherFaults = store.archivedFaultsForOtherVehicles
        return VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup(isExpanded: $showOtherVehiclesHistory) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Estes registros foram salvos em leituras de outro veículo ou antes da separação por chassi (VIN) e não pertencem à leitura atual de \(store.vehicleIdentity.cleanModelTitle).")
                        .font(.caption)
                        .foregroundStyle(Tema.textoSuave)
                        .padding(.top, 6)

                    Button(role: .destructive) {
                        store.clearOtherVehiclesArchivedFaults()
                    } label: {
                        Label("Limpar histórico de outros veículos (\(otherFaults.count))", systemImage: "trash")
                            .font(.caption.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(.red)
                    }

                    ForEach(otherFaults) { fault in
                        FaultInterpreterCard(fault: fault) {
                            selectedFault = fault
                        }
                        .opacity(0.65)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "tray.full.fill")
                        .foregroundStyle(Tema.textoSuave)
                    Text("Histórico de Outros Veículos (\(otherFaults.count))")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Tema.textoSuave)
                    Spacer()
                }
            }
        }
        .padding(14)
        .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Tema.borda, lineWidth: 1)
        )
    }
}

// MARK: - Unified Fault Card (Leigo + Técnico Integrados no Mesmo Card)
struct FaultInterpreterCard: View {
    let fault: DiagnosticFault
    let onTap: () -> Void

    private var severityColor: Color {
        switch fault.interpretation.urgency {
        case .stopImmediately: return .red
        case .attentionSoon: return .orange
        case .historicalObservation: return .blue
        case .safeToDrive: return .green
        }
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 12) {
                // 1. Cabeçalho Técnico: Módulo + Código DTC + Status + Máscara
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(fault.moduleCode) • \(fault.moduleName)".uppercased())
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(severityColor)
                            .tracking(0.7)

                        HStack(spacing: 8) {
                            Text(fault.displayCode)
                                .font(.system(.title3, design: .monospaced).weight(.black))
                                .foregroundStyle(Tema.texto)

                            Text(fault.statusSummaryPt)
                                .font(.caption2.monospaced().weight(.bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(severityColor.opacity(0.14), in: Capsule())
                                .foregroundStyle(severityColor)
                        }
                    }

                    Spacer()

                    if let mask = fault.statusMaskHex {
                        Text("Mask 0x\(mask)")
                            .font(.caption2.monospaced().weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Tema.subcartao, in: Capsule())
                            .foregroundStyle(Tema.textoSuave)
                    }
                }

                // 2. Título Amigável e Explicação em Linguagem Simples
                VStack(alignment: .leading, spacing: 4) {
                    Text(fault.interpretation.headline)
                        .font(.headline.weight(.black))
                        .foregroundStyle(Tema.texto)

                    Text(fault.interpretation.resolvedCustomerStory)
                        .font(.subheadline)
                        .foregroundStyle(Tema.texto.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                }

                // 3. Orientação de Segurança: Posso Continuar Dirigindo?
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "steeringwheel")
                        .font(.headline)
                        .foregroundStyle(severityColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("POSSO CONTINUAR DIRIGINDO?")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(severityColor)
                        Text(fault.interpretation.resolvedCustomerBanner)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Tema.texto)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(severityColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))

                // 4. Orientação Técnica / Dica para Oficina
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                        .font(.headline)
                        .foregroundStyle(Color.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PROTEÇÃO NA OFICINA (DICA DO SENSEI)")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(Color.green)
                        Text(fault.interpretation.resolvedWorkshopTip)
                            .font(.caption)
                            .foregroundStyle(Tema.texto)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))

                // 5. Ação Recomendada Técnica
                HStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.caption)
                        .foregroundStyle(severityColor)
                    Text("Ação recomendada: \(fault.interpretation.recommendedAction)")
                        .font(.caption)
                        .foregroundStyle(Tema.textoSuave)
                        .lineLimit(2)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tema.subcartao, in: RoundedRectangle(cornerRadius: 10))

                // 6. Rodapé do Card
                HStack {
                    Spacer()
                    Label(
                        "Toque para inspecionar Snapshot UDS 19 04 e causas",
                        systemImage: "chevron.right.circle.fill"
                    )
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.blue)
                }
            }
            .padding(16)
            .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(severityColor.opacity(0.35), lineWidth: 1.2)
            )
            .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Detailed Fault Sheet (Unificado)
struct FaultDetailSheetView: View {
    let fault: DiagnosticFault
    @EnvironmentObject var store: CarSenseiStore
    @Environment(\.dismiss) private var dismiss

    private var liveFault: DiagnosticFault {
        store.activeFaults.first(where: { $0.id == fault.id }) ?? fault
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Tema.fundo.ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        customerDetailSections
                        mechanicDetailSections
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Detalhes do Alerta")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fechar") { dismiss() }
                }
            }
        }
    }

    // MARK: Customer Detail Sections
    private var customerDetailSections: some View {
        VStack(alignment: .leading, spacing: 14) {
            detailCard(title: "RESUMO EM LINGUAGEM SIMPLES", icon: "person.crop.circle.badge.checkmark", tint: .blue) {
                Text(liveFault.interpretation.headline)
                    .font(.title3.weight(.black))
                    .foregroundStyle(Tema.texto)

                Text(liveFault.interpretation.resolvedCustomerStory)
                    .font(.subheadline)
                    .foregroundStyle(Tema.texto.opacity(0.88))
            }

            detailCard(title: "POSSO CONTINUAR DIRIGINDO?", icon: "steeringwheel", tint: .orange) {
                Text(liveFault.interpretation.resolvedCustomerBanner)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Tema.texto)
            }

            detailCard(title: "PROTEÇÃO NA OFICINA (EVITE GASTOS INDEVIDOS)", icon: "shield.checkered", tint: .green) {
                Text(liveFault.interpretation.resolvedWorkshopTip)
                    .font(.subheadline)
                    .foregroundStyle(Tema.texto)
            }

            if let occurrences = liveFault.freezeFrame?.occurrences, !occurrences.isEmpty {
                detailCard(title: "QUANDO ISSO ACONTECEU NO CARRO?", icon: "clock.arrow.circlepath", tint: .indigo) {
                    ForEach(occurrences) { occ in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Ocorrência #\(occ.recordNumber) — Aos \(occ.odometerKm.map { String(format: "%.0f km", $0) } ?? "--")")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Tema.texto)
                            Text("Temp. Câmbio: \(occ.transmissionTempC.map { "\(Int($0))°C" } ?? "--") • Motor: \(occ.coolantTempC.map { "\(Int($0))°C" } ?? "--") • Velocidade: \(occ.vehicleSpeedKmh.map { "\(Int($0)) km/h" } ?? "--")")
                                .font(.caption)
                                .foregroundStyle(Tema.textoSuave)
                        }
                        Divider()
                    }
                }
            }
        }
    }

    // MARK: Mechanic Technical Detail Sections
    private var mechanicDetailSections: some View {
        VStack(alignment: .leading, spacing: 14) {
            detailCard(title: "IDENTIFICAÇÃO TÉCNICA UDS / ISO 14229", icon: "cpu.fill", tint: .blue) {
                Text("\(liveFault.displayCode) — \(liveFault.failureTypeDescription ?? "UDS DTC")")
                    .font(.headline.monospaced())
                    .foregroundStyle(Tema.texto)

                Text("Módulo: \(liveFault.moduleCode) (\(liveFault.moduleName)) • Status: \(liveFault.statusSummaryPt)")
                    .font(.caption.monospaced())
                    .foregroundStyle(Tema.textoSuave)
            }

            detailCard(title: "ANÁLISE DE ENGENHARIA MECÂNICA", icon: "waveform.path.ecg", tint: .indigo) {
                Text(liveFault.interpretation.headline)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Tema.texto)
                Text(liveFault.interpretation.plainExplanation)
                    .font(.subheadline)
                    .foregroundStyle(Tema.texto.opacity(0.88))
                Text(liveFault.interpretation.vehicleContext)
                    .font(.caption)
                    .foregroundStyle(Tema.textoSuave)
            }

            detailCard(title: "CAUSAS RAIZ MAIS PROVÁVEIS", icon: "list.number", tint: .orange) {
                ForEach(Array(liveFault.interpretation.probableCauses.enumerated()), id: \.offset) { index, cause in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.orange)
                        Text(cause)
                            .font(.subheadline)
                            .foregroundStyle(Tema.texto)
                    }
                }
            }

            detailCard(title: "PROCEDIMENTO TÉCNICO RECOMENDADO", icon: "wrench.and.screwdriver.fill", tint: .green) {
                Text(liveFault.interpretation.recommendedAction)
                    .font(.subheadline)
                    .foregroundStyle(Tema.texto)
            }

            if let occurrences = liveFault.freezeFrame?.occurrences, !occurrences.isEmpty {
                detailCard(title: "FREEZE FRAME / SNAPSHOT UDS (SERVIÇO 19 04)", icon: "camera.metering.matrix", tint: .purple) {
                    ForEach(occurrences) { occ in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Record #\(occ.recordNumber) • DID 0B5B = \(occ.odometerKm.map { String(format: "%.0f km", $0) } ?? "--")")
                                .font(.caption.monospaced().weight(.bold))
                                .foregroundStyle(Tema.texto)
                            Text("DID 0B37 (CVT): \(occ.transmissionTempC.map { "\(Int($0))°C" } ?? "--") | DID 0B2F (ECT): \(occ.coolantTempC.map { "\(Int($0))°C" } ?? "--") | DID 0B33 (VSS): \(occ.vehicleSpeedKmh.map { "\(Int($0)) km/h" } ?? "--")")
                                .font(.caption2.monospaced())
                                .foregroundStyle(Tema.textoSuave)
                        }
                        Divider()
                    }
                }
            }
        }
    }

    private func detailCard<Content: View>(
        title: String,
        icon: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.caption2.weight(.heavy))
                .foregroundStyle(tint)
                .tracking(0.7)

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Tema.borda, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.03), radius: 5, x: 0, y: 2)
    }
}
