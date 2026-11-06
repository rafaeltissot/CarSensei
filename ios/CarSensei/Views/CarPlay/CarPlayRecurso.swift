import SwiftUI

/// Único ponto de contato do app do iPhone com o CarPlay. Com a flag CARPLAY_ENABLED desligada
/// (ver LEIAME.md) os três pontos abaixo viram "nada" e o resto do app compila sem o CarPlay.
enum CarPlayRecurso {
    static let ativo: Bool = {
        #if CARPLAY_ENABLED
        true
        #else
        false
        #endif
    }()
}

/// Botão "Multimídia" da barra do painel.
struct CarPlayBotaoMultimidia: View {
    let action: () -> Void

    var body: some View {
        #if CARPLAY_ENABLED
        Button(action: action) {
            Label("Multimídia", systemImage: "carplay")
                .font(.caption.weight(.bold))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        #endif
    }
}

/// Botão "Restaurar layout padrão" do catálogo de sensores.
struct CarPlayBotaoRestaurarLayout: View {
    @EnvironmentObject var store: CarSenseiStore

    var body: some View {
        #if CARPLAY_ENABLED
        Button("Restaurar Layout Padrão do CarPlay (22 Slots)") {
            store.resetCarPlaySlotsToDefault()
        }
        #endif
    }
}

extension View {
    /// Tela cheia da central multimídia (espelho do CarPlay) aberta pelo iPhone.
    @ViewBuilder
    func carPlayTelaCheia(isPresented: Binding<Bool>, store: CarSenseiStore) -> some View {
        #if CARPLAY_ENABLED
        fullScreenCover(isPresented: isPresented) {
            MultimediaMirrorDashboardView().environmentObject(store)
        }
        #else
        self
        #endif
    }
}
