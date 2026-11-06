import SwiftUI

/// Indicador discreto de conexão com o scanner, para o título das abas que não têm cartão de conexão.
struct ConexaoPilula: View {
    @EnvironmentObject var store: CarSenseiStore

    private var conectado: Bool { store.connectionState == .connectedReady }

    private var cor: Color {
        switch store.connectionState {
        case .connectedReady: return .green
        case .scanning, .connecting, .initializingProtocol: return .orange
        case .error, .bluetoothOff: return .red
        case .disconnected: return .gray
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(cor).frame(width: 8, height: 8)
            Text(conectado ? "Conectado" : "Desconectado")
                .font(.caption.weight(.bold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(cor.opacity(0.12), in: Capsule())
        .foregroundStyle(conectado ? Color.green : Color.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(conectado ? "Scanner conectado" : "Scanner desconectado")
    }
}
