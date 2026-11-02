import SwiftUI

struct TPMSPairingSheet: View {
    @EnvironmentObject var store: CarSenseiStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: WheelPosition?

    @State private var ids: [WheelPosition: String] = [:]
    @State private var confirmed = false

    private var ready: Bool { store.connectionState == .connectedReady }
    private var anyID: Bool { WheelPosition.roadWheels.contains { (ids[$0]?.count ?? 0) == 8 } }

    var body: some View {
        NavigationStack {
            ZStack {
                Tema.fundo.ignoresSafeArea()
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        safetyCard
                        idsCard
                        actionCard
                        if !store.pairingLog.isEmpty { logCard }
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Parear sensores")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Fechar") { dismiss() }.frame(minHeight: 44) }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer(); Button("OK") { focused = nil }
                }
            }
        }
    }

    private var safetyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Como funciona", systemImage: "info.circle.fill").font(.subheadline.weight(.bold)).foregroundStyle(.blue)
            Text("1. Ligue a ignição com o motor desligado e o carro parado.\n2. Informe o ID (8 dígitos hex) de cada sensor — vem impresso no corpo do sensor ou na nota.\n3. O app grava os IDs no módulo do carro e tenta a rotina de aprendizado.\n4. Calibre os pneus na pressão correta e rode alguns minutos para o painel confirmar.")
                .font(.caption).foregroundStyle(Tema.textoSuave)
            Text("Experimental: se o módulo exigir chave de segurança do fabricante, o pareamento por OBD não será possível e o app vai avisar no registro abaixo. Nada é gravado sem você confirmar.")
                .font(.caption2).foregroundStyle(.orange)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 16))
    }

    private var idsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("IDS DOS SENSORES (8 DÍGITOS HEX)").font(.caption2.weight(.heavy)).foregroundStyle(.blue).tracking(0.8)
            ForEach(WheelPosition.roadWheels) { pos in
                HStack(spacing: 10) {
                    Text(pos.label).font(.caption.weight(.semibold)).foregroundStyle(Tema.texto).frame(width: 130, alignment: .leading)
                    TextField("Ex: 4A2F10C8", text: Binding(
                        get: { ids[pos] ?? "" },
                        set: { ids[pos] = sanitize($0) }
                    ))
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($focused, equals: pos)
                    .padding(10)
                    .background(Tema.fundo, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke((ids[pos]?.count ?? 0) == 8 ? Color.green : Tema.borda, lineWidth: 1))
                }
            }
            Text("Deixe em branco a roda cujo sensor você não trocou. O app lê os IDs atuais antes e depois, para confirmar a mudança.")
                .font(.caption2).foregroundStyle(Tema.textoSuave)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 16))
    }

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $confirmed) {
                Text("Entendi que é experimental e meu carro está com a ignição ligada, motor desligado e parado.")
                    .font(.caption).foregroundStyle(Tema.texto)
            }
            .tint(.indigo)

            Button {
                focused = nil
                Task { await store.pairTPMSSensors(sensorIDsByWheel: ids.filter { $0.value.count == 8 }) }
            } label: {
                HStack {
                    if store.isPairingTPMS { ProgressView().tint(.white) }
                    else { Image(systemName: "badge.plus.radiowaves.right") }
                    Text(store.isPairingTPMS ? stageText : "Gravar e parear").font(.subheadline.weight(.bold))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(canPair ? Color.indigo : Color.gray.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(canPair ? .white : Tema.textoSuave)
            }
            .disabled(!canPair)

            if store.pairingStage == .done {
                Label("Pareamento enviado. Calibre os pneus e rode para o painel confirmar.", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.green)
            } else if store.pairingStage == .failed {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Não foi possível concluir. Veja o registro abaixo.", systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
                    Button {
                        Task { await store.pairTPMSSensors(sensorIDsByWheel: ids.filter { $0.value.count == 8 }) }
                    } label: {
                        Label("Tentar novamente", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.bold))
                            .frame(minHeight: 44)
                    }
                    .disabled(!ready || store.isPairingTPMS)
                    .foregroundStyle(.indigo)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 16))
    }

    private var canPair: Bool { ready && anyID && confirmed && !store.isPairingTPMS }

    private var stageText: String {
        switch store.pairingStage {
        case .locatingModule: return "Achando o módulo..."
        case .readingCurrentIDs: return "Lendo IDs atuais..."
        case .openingSession: return "Abrindo sessão..."
        case .securityAccess: return "Segurança..."
        case .writingIDs: return "Gravando IDs..."
        case .verifying: return "Verificando..."
        default: return "Pareando..."
        }
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("REGISTRO PASSO A PASSO").font(.caption2.weight(.heavy)).foregroundStyle(.blue).tracking(0.8)
            ForEach(store.pairingLog) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Image(systemName: entry.success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.caption2).foregroundStyle(entry.success ? .green : .orange)
                        Text(entry.command).font(.caption2.monospaced().weight(.bold)).foregroundStyle(Tema.texto)
                    }
                    Text(entry.interpretation).font(.caption2).foregroundStyle(Tema.textoSuave)
                    if entry.response != "-" && !entry.response.isEmpty {
                        Text(entry.response).font(.caption2.monospaced()).foregroundStyle(Tema.textoSuave).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(Tema.fundo, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 16))
    }

    private func sanitize(_ s: String) -> String {
        String(s.uppercased().filter { $0.isHexDigit }.prefix(8))
    }
}
