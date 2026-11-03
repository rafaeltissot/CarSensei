import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: CarSenseiStore
    @EnvironmentObject var loja: Loja
    @State private var showScannerSheet = false
    @State private var gerenciandoAssinatura = false
    @AppStorage("carsensei.auto_connect_engine_start") private var autoConnectOnLaunch = true
    @AppStorage("carsensei.auto_open_dash_on_connect") private var openDashboardOnConnect = true

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "2"
        return "v\(version) (\(build))"
    }

    private var planoTitulo: String {
        switch loja.estado {
        case .vitalicio:
            return "Plano Vitalício Ativo"
        case .anual(let expira):
            let ren = expira.map { " · renova \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
            return "Plano Anual Ativo\(ren)"
        case .teste(let d):
            return "Teste Grátis: \(d) dia\(d == 1 ? "" : "s") restante\(d == 1 ? "" : "s")"
        case .expirado:
            return "Teste Grátis Terminou"
        }
    }

    private var planoSubtitulo: String {
        switch loja.estado {
        case .vitalicio, .anual:
            return "Acesso irrestrito a leituras CAN/UDS, diagnósticos e perícia de KM."
        case .teste:
            return "Aproveite todas as funções Pro do CarSensei durante o período de avaliação."
        case .expirado:
            return "Escolha um plano para continuar lendo novos dados do veículo pelo scanner."
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Plano e Compras
                Section("Plano e Assinatura") {
                    HStack(spacing: 12) {
                        Image(systemName: loja.pago ? "checkmark.seal.fill" : "gift.fill")
                            .font(.title2)
                            .foregroundStyle(loja.pago ? Color.green : Color.blue)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(planoTitulo)
                                .font(.headline.weight(.bold))
                            Text(planoSubtitulo)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button(loja.pago ? "Gerenciar" : "Ver Planos") {
                            if loja.pago {
                                gerenciandoAssinatura = true
                            } else {
                                loja.pedirPlanos = true
                            }
                        }
                        .font(.subheadline.bold())
                        .buttonStyle(.borderedProminent)
                        .tint(loja.pago ? Color.gray.opacity(0.3) : Color.blue)
                    }
                    .padding(.vertical, 4)

                    Button("Restaurar Compras Anteriores") {
                        Task {
                            await loja.restaurar()
                            if !loja.pago { loja.pedirPlanos = true }
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Color.blue)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }

                // MARK: - Adaptador OBDII ELM327 / vLinker MC
                Section("Adaptador OBDII ELM327 / vLinker") {
                    HStack {
                        Label("Tipo de Conexão", systemImage: "antenna.radiowaves.left.and.right")
                        Spacer()
                        Text("Bluetooth LE (4.0+)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        showScannerSheet = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Nome do Dispositivo")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.primary)
                                Text(store.bleManager.connectedDeviceName ?? "vLinker MC-IOS")
                                    .font(.caption.bold())
                                    .foregroundStyle(Color.blue)
                            }
                            Spacer()
                            Text(store.connectionState == .connectedReady ? "Conectado" : "Toque para selecionar...")
                                .font(.caption.bold())
                                .foregroundStyle(store.connectionState == .connectedReady ? Color.green : Color.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle("Conectar ao dar partida / iniciar", isOn: $autoConnectOnLaunch)
                    Toggle("Abrir o painel depois de conectar", isOn: $openDashboardOnConnect)

                    Text("Os adaptadores recomendados vLinker MC-IOS / MC+ utilizam comandos STN e taxas de até 50 PIDs/s com barramento CAN e UDS 2F/22 ativos.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // MARK: - Informações do App & Hardware
                Section("Sobre o CarSensei") {
                    LabeledContent("Versão do Aplicativo", value: appVersion)
                    LabeledContent("Scanner BLE Compatível", value: store.vehicleIdentity.adapterTier.rawValue)
                    LabeledContent("Protocolo de Comunicação", value: store.vehicleIdentity.obdProtocol)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Diretriz de Segurança Automotiva")
                            .font(.caption.bold())
                        Text("O CarSensei opera estritamente dentro das normas ISO 15765-4 (CAN) e ISO 14229 (UDS). Limpezas de memória DTC são bloqueadas com motor ligado ou em movimento (segurança veicular KOEO).")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Ajustes & Sobre")
            .sheet(isPresented: $showScannerSheet) {
                BLEScannerSheetView()
                    .environmentObject(store)
            }
            .manageSubscriptionsSheet(isPresented: $gerenciandoAssinatura)
        }
        .tissotScreen("Ajustes")
    }
}
