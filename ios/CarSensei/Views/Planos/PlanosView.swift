import StoreKit
import SwiftUI

/// Tela de planos (aberta como folha). Mostra a situação do teste grátis e os dois planos pagos.
struct PlanosView: View {
    @EnvironmentObject private var loja: Loja
    @Environment(\.dismiss) private var fechar
    @State private var escolhido = Loja.idAnual

    private var produtoEscolhido: Product? { loja.produto(escolhido) }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 18) {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.largeTitle.bold())
                        .foregroundStyle(.blue)
                        .padding(.top, 12)
                        .accessibilityHidden(true)
                    Text("CarSensei Premium").font(.title2.bold()).foregroundStyle(Tema.texto)
                    Text(situacao).font(.headline).foregroundStyle(Tema.texto).multilineTextAlignment(.center)
                    beneficios
                    if loja.produtos.isEmpty {
                        VStack(spacing: 10) {
                            if let erro = loja.erro {
                                Text(erro).font(.footnote).foregroundStyle(Tema.textoSuave).multilineTextAlignment(.center)
                            } else {
                                ProgressView()
                            }
                            Button("Tentar novamente") { Task { await loja.carregarProdutos() } }
                        }
                    } else {
                        VStack(spacing: 10) {
                            ForEach(loja.produtos) { cartaoPlano($0) }
                        }
                        botaoPrincipal
                    }
                    Button("Restaurar compras") { Task { await loja.restaurar() } }
                        .font(.subheadline.bold()).disabled(loja.ocupado)
                        .frame(minHeight: 44)
                    legal
                }
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
            .background(Tema.fundo.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fechar") { fechar() }
                }
            }
            .overlay { if loja.ocupado { ProgressView().padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
            .alert("Aviso", isPresented: Binding(get: { loja.erro != nil && !loja.produtos.isEmpty }, set: { if !$0 { loja.erro = nil } })) {
                Button("OK") { loja.erro = nil }
            } message: { Text(loja.erro ?? "") }
        }
        .tissotScreen("Planos")
    }

    private var situacao: String {
        switch loja.estado {
        case .teste(let d): "Teste grátis: \(d) dia\(d == 1 ? "" : "s") restante\(d == 1 ? "" : "s")"
        case .expirado: "Seu teste grátis de \(TesteGratis.dias) dias terminou. Escolha um plano para continuar lendo o carro. Suas falhas e laudos salvos continuam disponíveis."
        case .anual: "Plano anual ativo."
        case .vitalicio: "Plano vitalício ativo."
        }
    }

    private var beneficios: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(["Telemetria ao vivo e Guardião Térmico do CVT", "Diagnóstico de todos os módulos em linguagem simples",
                     "Auditoria de quilometragem com provas dos módulos", "Computador de bordo, consumo e histórico de viagens"], id: \.self) { texto in
                Label { Text(texto).foregroundStyle(Tema.textoSuave) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) }
                    .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 16))
    }

    private func cartaoPlano(_ p: Product) -> some View {
        let anual = p.id == Loja.idAnual
        let ativo = escolhido == p.id
        return Button { escolhido = p.id } label: {
            HStack(spacing: 12) {
                Image(systemName: ativo ? "largecircle.fill.circle" : "circle").font(.title3).foregroundStyle(ativo ? Color.blue : Tema.textoSuave)
                VStack(alignment: .leading, spacing: 3) {
                    Text(anual ? "Anual" : "Vitalício").font(.headline).foregroundStyle(Tema.texto)
                    Text(anual ? "Renova todo ano até cancelar" : "Pagamento único, para sempre")
                        .font(.caption).foregroundStyle(Tema.textoSuave)
                }
                Spacer()
                Text(anual ? "\(p.displayPrice)/ano" : p.displayPrice).font(.headline).foregroundStyle(Tema.texto)
            }
            .padding(14)
            .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(ativo ? Color.blue : Tema.borda, lineWidth: ativo ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(ativo ? .isSelected : [])
    }

    private var botaoPrincipal: some View {
        Button {
            if let p = produtoEscolhido { Task { await loja.comprar(p) } }
        } label: {
            Text(textoDoBotao).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent).controlSize(.large)
        .disabled(produtoEscolhido == nil || loja.ocupado)
    }

    private var textoDoBotao: String {
        guard let p = produtoEscolhido else { return "Continuar" }
        return p.id == Loja.idVitalicio ? "Comprar por \(p.displayPrice)" : "Assinar por \(p.displayPrice)/ano"
    }

    private var legal: some View {
        VStack(spacing: 8) {
            Text("A assinatura anual é renovada automaticamente a cada ano, pelo mesmo valor, até ser cancelada pelo menos 24 horas antes do fim do período. O pagamento é cobrado na sua conta Apple e você gerencia ou cancela em Ajustes > seu nome > Assinaturas. O plano vitalício é uma compra única, sem renovação.")
            HStack(spacing: 16) {
                Link("Termos de Uso", destination: Legal.termos)
                if let politica = Legal.politica { Link("Política de Privacidade", destination: politica) }
            }
            .font(.caption.bold())
        }
        .font(.caption2).foregroundStyle(Tema.textoSuave).multilineTextAlignment(.center)
    }
}

/// Cartão do plano no fim do Cockpit: situação, ver planos, gerenciar assinatura e restaurar compras.
struct PlanoResumoCard: View {
    @EnvironmentObject private var loja: Loja
    @State private var gerenciandoAssinatura = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch loja.estado {
            case .vitalicio:
                Label("Plano vitalício ativo", systemImage: "infinity").foregroundStyle(.blue)
            case .anual(let expira):
                Label("Plano anual ativo" + (expira.map { " · renova em \($0.formatted(date: .numeric, time: .omitted))" } ?? ""), systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.blue)
                Button("Gerenciar assinatura", systemImage: "creditcard") { gerenciandoAssinatura = true }
            case .teste(let d):
                Label("Teste grátis: \(d) dia\(d == 1 ? "" : "s") restante\(d == 1 ? "" : "s")", systemImage: "gift").foregroundStyle(.blue)
                Button("Ver planos", systemImage: "star.circle") { loja.pedirPlanos = true }
            case .expirado:
                Label("Teste grátis terminou", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                Button("Ver planos", systemImage: "star.circle") { loja.pedirPlanos = true }
            }
            Button("Restaurar compras", systemImage: "arrow.clockwise.circle") {
                Task {
                    await loja.restaurar()
                    if !loja.pago { loja.pedirPlanos = true } // a tela de planos mostra o motivo
                }
            }
        }
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 18))
        .manageSubscriptionsSheet(isPresented: $gerenciandoAssinatura)
    }
}
