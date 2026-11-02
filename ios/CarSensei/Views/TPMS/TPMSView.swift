import SwiftUI

struct TPMSView: View {
    @EnvironmentObject var store: CarSenseiStore
    @State private var showPairingSheet = false
    @State private var showTechnical = false

    private var ready: Bool { store.connectionState == .connectedReady }

    var body: some View {
        NavigationStack {
            ZStack {
                Tema.fundo.ignoresSafeArea()
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 16) {
                        readerCard
                        if let snap = store.tpmsSnapshot {
                            tiresCard(snap)
                            if !snap.systemWarnings.isEmpty { warningsCard(snap.systemWarnings) }
                        } else {
                            emptyCard
                        }
                        pairingCard
                        if showTechnical || !store.tpmsModuleCandidates.isEmpty {
                            technicalCard
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("Pneus (TPMS)")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $showPairingSheet) {
            TPMSPairingSheet().environmentObject(store)
        }
    }

    // MARK: Leitura

    private var readerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Pressão dos pneus", systemImage: "gauge.with.dots.needle.bottom.50percent")
                    .font(.headline).foregroundStyle(Tema.texto)
                Spacer()
                if let m = store.confirmedTPMSModule {
                    Text("Módulo 0x\(m.txHeader)")
                        .font(.caption2.monospaced().weight(.bold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.blue.opacity(0.12), in: Capsule())
                        .foregroundStyle(.blue)
                }
            }

            Button {
                Task { await store.readTPMS() }
            } label: {
                HStack {
                    if store.isReadingTPMS { ProgressView().tint(.white) }
                    else { Image(systemName: "arrow.clockwise") }
                    Text(store.isReadingTPMS ? "Lendo..." : "Ler pneus agora")
                        .font(.subheadline.weight(.bold))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(ready ? Color.blue : Color.gray.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(ready ? .white : Tema.textoSuave)
            }
            .disabled(!ready || store.isReadingTPMS)

            Button {
                Task { await store.readTPMSStoredIDs() }
            } label: {
                Label("Ler IDs gravados no módulo (para clonar)", systemImage: "number.square.fill")
                    .font(.caption.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .background(Color.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.teal)
            }
            .disabled(!ready || store.isReadingTPMS)

            Button {
                Task { await store.deepScanTPMS() }
            } label: {
                Label("Varredura completa (0x700–0x77F)", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .background(Color.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.indigo)
            }
            .disabled(!ready || store.isReadingTPMS)

            if store.confirmedTPMSModule != nil {
                Button("Procurar módulo de novo") {
                    store.forgetTPMSModule()
                    Task { await store.readTPMS() }
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.blue)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .disabled(!ready || store.isReadingTPMS)
            }

            if !store.tpmsStatusText.isEmpty {
                Text(store.tpmsStatusText).font(.caption).foregroundStyle(Tema.textoSuave)
            }
        }
        .padding(16).background(Tema.cartao, in: RoundedRectangle(cornerRadius: 18))
    }

    // MARK: Pneus

    private func tiresCard(_ snap: TPMSSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("ESTADO DOS PNEUS").font(.caption2.weight(.heavy)).foregroundStyle(.blue).tracking(0.8)
                Spacer()
                Text(snap.readAt.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(Tema.textoSuave)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(snap.tires) { tire in tirePill(tire) }
            }
            Text("Fonte: \(snap.source.rawValue). Os sensores transmitem por rádio; o CarSensei lê o que o módulo do carro recebeu deles.")
                .font(.caption2).foregroundStyle(Tema.textoSuave)
        }
        .padding(16).background(Tema.cartao, in: RoundedRectangle(cornerRadius: 18))
    }

    private func tirePill(_ tire: TireReading) -> some View {
        let reporting = tire.isReporting
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(tire.position.label).font(.caption.weight(.bold)).foregroundStyle(Tema.texto)
                Spacer()
                Circle().fill(reporting ? Color.green : Color.gray.opacity(0.5)).frame(width: 8, height: 8)
            }
            if let bar = tire.pressureBar {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(String(format: "%.1f", bar)).font(.system(.title2, design: .rounded, weight: .black)).foregroundStyle(Tema.texto)
                    Text("bar").font(.caption2.weight(.bold)).foregroundStyle(.blue)
                }
                if let psi = tire.pressurePsi {
                    Text(String(format: "%.0f psi", psi)).font(.caption2).foregroundStyle(Tema.textoSuave)
                }
            } else {
                Text(reporting ? "—" : "Sem sensor").font(.subheadline.weight(.semibold)).foregroundStyle(Tema.textoSuave)
            }
            if let t = tire.temperatureC {
                Label(String(format: "%.0f°C", t), systemImage: "thermometer").font(.caption2).foregroundStyle(Tema.textoSuave)
            }
            if let id = tire.sensorIdHex {
                Text("ID \(id)").font(.caption2.monospaced()).foregroundStyle(Tema.textoSuave).lineLimit(1)
            }
            if tire.lowBattery {
                Label("Bateria fraca", systemImage: "battery.25").font(.caption2).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Tema.fundo, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tema.borda, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private func warningsCard(_ warnings: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Avisos do sistema TPMS", systemImage: "exclamationmark.triangle.fill").font(.caption.weight(.bold)).foregroundStyle(.orange)
            ForEach(warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(Tema.textoSuave) }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }

    private var emptyCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "car.rear.and.tire.marks").font(.largeTitle).foregroundStyle(Tema.textoSuave)
            Text("Toque em 'Ler pneus agora' com a ignição ligada.").font(.caption).foregroundStyle(Tema.textoSuave).multilineTextAlignment(.center)
            Button {
                Task { await store.readTPMS() }
            } label: {
                Label("Tentar novamente", systemImage: "arrow.clockwise")
                    .font(.caption.weight(.bold))
                    .frame(minHeight: 44)
                    .padding(.horizontal, 14)
            }
            .disabled(!ready || store.isReadingTPMS)
            .foregroundStyle(.blue)
        }
        .frame(maxWidth: .infinity).padding(28)
        .background(Tema.cartao, in: RoundedRectangle(cornerRadius: 18))
    }

    // MARK: Pareamento

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Parear sensores novos (avançado)", systemImage: "badge.plus.radiowaves.right").font(.subheadline.weight(.bold)).foregroundStyle(Tema.texto)
            Text("Para quem instalou ou trocou sensores e o painel não reconheceu. Grava o ID de cada sensor no módulo do carro. É experimental e depende do fabricante: alguns módulos exigem chave de segurança que só a concessionária tem.")
                .font(.caption).foregroundStyle(Tema.textoSuave)
            Button {
                showPairingSheet = true
            } label: {
                Text("Abrir assistente de pareamento").font(.caption.weight(.bold))
                    .frame(maxWidth: .infinity).frame(minHeight: 44)
                    .background(ready ? Color.indigo : Color.gray.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(ready ? .white : Tema.textoSuave)
            }
            .disabled(!ready)
        }
        .padding(16).background(Tema.cartao, in: RoundedRectangle(cornerRadius: 18))
    }

    // MARK: Técnico

    private var technicalCard: some View {
        DisclosureGroup(isExpanded: $showTechnical) {
            VStack(alignment: .leading, spacing: 8) {
                if store.tpmsModuleCandidates.isEmpty {
                    Text("Rode a leitura para descobrir módulos.").font(.caption2).foregroundStyle(Tema.textoSuave)
                }
                ForEach(store.tpmsModuleCandidates) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("0x\(c.txHeader) → 0x\(c.rxHeader)").font(.caption.monospaced().weight(.bold)).foregroundStyle(Tema.texto)
                            if c.looksLikeTPMS {
                                Text("TPMS?").font(.caption2.weight(.heavy)).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.green.opacity(0.18), in: Capsule()).foregroundStyle(.green)
                            }
                        }
                        if let id = c.identifier { Text(id).font(.caption2).foregroundStyle(Tema.textoSuave) }
                        if !c.respondingDIDs.isEmpty {
                            Text("DIDs: \(c.respondingDIDs.joined(separator: ", "))").font(.caption2.monospaced()).foregroundStyle(Tema.textoSuave)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(Tema.fundo, in: RoundedRectangle(cornerRadius: 10))
                }
                Text("O hex completo de cada resposta vai junto nos relatos técnicos enviados pela Central de Relatos.").font(.caption2).foregroundStyle(Tema.textoSuave)
            }
            .padding(.top, 8)
        } label: {
            Label("Detalhes técnicos (módulos no barramento)", systemImage: "chevron.left.forwardslash.chevron.right")
                .font(.caption.weight(.bold)).foregroundStyle(Tema.texto)
        }
        .padding(16).background(Tema.cartao, in: RoundedRectangle(cornerRadius: 18))
    }
}
