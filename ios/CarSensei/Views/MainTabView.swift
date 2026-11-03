import SwiftUI

/// Navegação principal com barra inferior própria.
///
/// O `TabView` do sistema (iOS 26/27) desenha a barra flutuante compacta — só ícone, fonte pequena —
/// e não aceita ajuste de tamanho por API pública. No carro, com o celular no suporte e às vezes com
/// luva, a barra do sistema ficou ilegível. Aqui a barra é desenhada pelo app: ícone + rótulo, alvo de
/// toque de 52 pt e rótulo em 11,5 pt (antes o sistema usava ~10 pt e escondia o texto).
struct MainTabView: View {
    @EnvironmentObject var store: CarSenseiStore
    @EnvironmentObject var loja: Loja

    @State private var selecionada: Aba = .cockpit

    enum Aba: String, CaseIterable, Identifiable {
        case cockpit, viagem, diagnostico, ajustes

        var id: String { rawValue }

        var titulo: String {
            switch self {
            case .cockpit: return "Cockpit"
            case .viagem: return "Viagem"
            case .diagnostico: return "Diagnóstico"
            case .ajustes: return "Ajustes"
            }
        }

        var icone: String {
            switch self {
            case .cockpit: return "gauge.with.dots.needle.67percent"
            case .viagem: return "waveform.path.ecg.rectangle"
            case .diagnostico: return "stethoscope"
            case .ajustes: return "gearshape.fill"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch selecionada {
                case .cockpit:
                    CockpitDashboardView()
                case .viagem:
                    TripAnalysisView()
                case .diagnostico:
                    DiagnosticsView()
                case .ajustes:
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            barraInferior
        }
        .sheet(isPresented: $loja.pedirPlanos) { PlanosView() }
    }

    private var barraInferior: some View {
        HStack(spacing: 0) {
            ForEach(Aba.allCases) { aba in
                Button {
                    guard selecionada != aba else { return }
                    selecionada = aba
                } label: {
                    VStack(spacing: 3) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: aba.icone)
                                .font(.system(size: 21, weight: selecionada == aba ? .bold : .regular))
                                .frame(width: 30, height: 24)

                            if aba == .diagnostico, store.activeFaults.count > 0 {
                                Text("\(min(store.activeFaults.count, 99))")
                                    .font(.system(size: 9, weight: .black))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.red, in: Capsule())
                                    .offset(x: 8, y: -4)
                            }
                        }

                        Text(aba.titulo)
                            .font(.system(size: 11.5, weight: selecionada == aba ? .bold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(selecionada == aba ? Color.blue : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(aba.titulo)
                .accessibilityAddTraits(selecionada == aba ? .isSelected : [])
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Tema.borda)
                .frame(height: 0.5)
        }
    }
}
