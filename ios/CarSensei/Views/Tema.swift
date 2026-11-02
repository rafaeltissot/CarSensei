import SwiftUI

/// Cores do app. Semânticas do sistema: seguem o modo claro/escuro sozinhas.
enum Tema {
    static let fundo = Color(uiColor: .systemGroupedBackground)
    static let cartao = Color(uiColor: .secondarySystemGroupedBackground)
    static let subcartao = Color(uiColor: .tertiarySystemGroupedBackground)
    static let texto = Color(uiColor: .label)
    static let textoSuave = Color(uiColor: .secondaryLabel)
    static let borda = Color(uiColor: .separator).opacity(0.5)
    static let trilho = Color(uiColor: .systemFill)
}
