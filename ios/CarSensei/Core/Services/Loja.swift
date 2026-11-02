import Foundation
import Security
import StoreKit

/// Endereços exigidos na tela de planos. Termos: contrato padrão da Apple.
/// ponytail: a política de privacidade precisa ser hospedada antes de publicar; preencher `politica` (a tela já mostra o link quando houver).
enum Legal {
    static let termos = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/") ?? URL(fileURLWithPath: "/")
    /// Página oficial já publicada no GitHub Pages do projeto (docs/privacidade).
    static let politica: URL? = URL(string: "https://rafaeltissot.github.io/CarSensei/privacidade/")
}

/// Teste grátis de 30 dias, contado a partir do primeiro uso (mesmo modelo do RoadTV e do RoadCopilot).
enum TesteGratis {
    static let dias = 30

    static func restantes(inicio: Date, agora: Date = Date()) -> Int {
        let usados = Calendar.current.dateComponents([.day], from: inicio, to: agora).day ?? 0
        return min(dias, max(0, dias - usados))   // relógio atrasado não alonga o teste
    }
}

/// Modelo de cobrança: 30 dias grátis, depois plano anual (assinatura) ou vitalício (compra única).
/// Os preços ficam no App Store Connect; o app só mostra o `displayPrice`. Terminado o teste sem plano, só o uso
/// novo (ler o carro pelo scanner) é bloqueado; falhas, laudos de KM e histórico salvos continuam visíveis.
@MainActor
final class Loja: ObservableObject {
    static let compartilhada = Loja()

    static let idAnual = "com.tissot.CarSensei.anual"
    static let idVitalicio = "com.tissot.CarSensei.vitalicio"

    enum Estado: Equatable {
        case teste(diasRestantes: Int)
        case anual(expira: Date?)
        case vitalicio
        case expirado
    }

    enum Plano: Equatable {
        case anual(expira: Date?)
        case vitalicio
    }

    @Published private(set) var produtos: [Product] = []
    @Published private(set) var plano: Plano?
    @Published private(set) var ocupado = false
    @Published var erro: String?
    /// Quando verdadeiro, a tela principal abre a tela de planos.
    @Published var pedirPlanos = false

    private let inicioDoTeste: Date

    var estado: Estado {
        switch plano {
        case .vitalicio: return .vitalicio
        case .anual(let expira): return .anual(expira: expira)
        case nil:
            let dias = TesteGratis.restantes(inicio: inicioDoTeste)
            return dias > 0 ? .teste(diasRestantes: dias) : .expirado
        }
    }

    var podeUsar: Bool { estado != .expirado }
    var pago: Bool { plano != nil }
    func produto(_ id: String) -> Product? { produtos.first { $0.id == id } }

    private init() {
        // O início do teste fica no Keychain, que sobrevive à reinstalação do app.
        if let texto = Self.lerChaveiro("inicioTeste"), let t = Double(texto) {
            inicioDoTeste = Date(timeIntervalSince1970: t)
        } else {
            inicioDoTeste = Date()
            Self.gravarChaveiro("inicioTeste", String(inicioDoTeste.timeIntervalSince1970))
        }
        // Compras feitas fora do app (Pedir para Comprar, renovações, reembolsos) chegam por aqui.
        Task {
            for await resultado in Transaction.updates {
                if case .verified(let t) = resultado { await t.finish() }
                await atualizar()
            }
        }
        Task {
            await atualizar()
            await carregarProdutos()
        }
    }

    func carregarProdutos() async {
        do {
            let lidos = try await Product.products(for: [Self.idAnual, Self.idVitalicio])
            produtos = lidos.sorted { $0.id == Self.idAnual && $1.id != Self.idAnual }
            if produtos.isEmpty { erro = "Os planos não estão disponíveis no momento." }
        } catch {
            TissotFeedback.error(error, context: "Loja.carregarProdutos")
            erro = "Não foi possível carregar os planos. Verifique sua conexão."
        }
    }

    /// Lê as compras guardadas no aparelho (funciona sem internet).
    func atualizar() async {
        var vitalicio = false
        var anual: Date??
        for await resultado in Transaction.currentEntitlements {
            guard case .verified(let t) = resultado, t.revocationDate == nil else { continue }
            if t.productID == Self.idVitalicio { vitalicio = true }
            if t.productID == Self.idAnual, (t.expirationDate ?? .distantFuture) > Date() { anual = .some(t.expirationDate) }
        }
        plano = vitalicio ? .vitalicio : anual.map { .anual(expira: $0) }
    }

    func comprar(_ produto: Product) async {
        ocupado = true
        defer { ocupado = false }
        do {
            switch try await produto.purchase() {
            case .success(let resultado):
                if case .verified(let t) = resultado {
                    await t.finish()
                    await atualizar()
                    pedirPlanos = false
                } else {
                    erro = "Não foi possível verificar a compra."
                }
            case .pending:
                erro = "Compra aguardando aprovação. Ela será liberada assim que for aprovada."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            TissotFeedback.error(error, context: "Loja.comprar")
            erro = error.localizedDescription
        }
    }

    func restaurar() async {
        ocupado = true
        defer { ocupado = false }
        do {
            try await AppStore.sync()
            await atualizar()
            if !pago { erro = "Nenhuma compra encontrada para restaurar." }
        } catch {
            TissotFeedback.error(error, context: "Loja.restaurar")
            erro = error.localizedDescription
        }
    }

    // MARK: Keychain

    private static func lerChaveiro(_ chave: String) -> String? {
        let consulta: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: chave,
            kSecReturnData as String: true,
        ]
        var resultado: CFTypeRef?
        guard SecItemCopyMatching(consulta as CFDictionary, &resultado) == errSecSuccess,
              let dados = resultado as? Data else { return nil }
        return String(data: dados, encoding: .utf8)
    }

    private static func gravarChaveiro(_ chave: String, _ valor: String) {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: chave,
            kSecValueData as String: Data(valor.utf8),
            // Legível com o iPhone bloqueado (CarPlay e telemetria em segundo plano).
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }
}
