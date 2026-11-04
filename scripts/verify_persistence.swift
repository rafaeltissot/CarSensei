import Foundation

/// Regressão da camada de persistência: o histórico do usuário (viagens, falhas, laudo de KM, garagem e
/// TPMS) é gravado em `UserDefaults` e relido com `try?`. Um decode que lança apaga o histórico inteiro sem
/// aviso, então estes testes garantem que campo novo/ausente e texto de enum desconhecido não derrubam nada.
///
///   swiftc -parse-as-library \
///     ios/CarSensei/Core/Models/VehicleModels.swift \
///     ios/CarSensei/Core/Models/TPMSModels.swift \
///     ios/CarSensei/Core/Services/SenseiKnowledgeBase.swift \
///     scripts/verify_persistence.swift -o /tmp/verify_persist && /tmp/verify_persist
@main
struct VerifyPersistence {
    static func main() throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        func dados(_ json: String) -> Data { Data(json.utf8) }

        // 1. Round-trip: o que o app grava hoje volta idêntico.
        let identidade = VehicleIdentity(
            vin: "ABCDE12345FGH6789",
            adapterTier: .vLinkerPro,
            detectedBrandProfile: .universalOBD,
            displacementLiters: 1.5,
            boostObserved: true
        )
        let voltou = try decoder.decode(VehicleIdentity.self, from: try encoder.encode(identidade))
        assert(voltou == identidade, "round-trip da identidade alterou o conteúdo")

        // 2. Payload de uma versão anterior, sem 8 dos 11 campos: completa com o padrão e mantém o VIN.
        let identidadeAntiga = dados(#"{"vin":"ABCDE12345FGH6789","ecuName":"ECM X","modelDescription":"Veículo antigo"}"#)
        let recuperada = try decoder.decode(VehicleIdentity.self, from: identidadeAntiga)
        assert(recuperada.vin == "ABCDE12345FGH6789")
        assert(recuperada.ecuName == "ECM X")
        assert(recuperada.calibrationId == "Aguardando Calibração", "campo ausente deve cair no padrão")
        assert(recuperada.adapterTier == .unknown)

        // 3. Texto de enum que não existe mais (ou foi renomeado) não pode derrubar o decode.
        let tierDesconhecido = dados(#"{"vin":"ABCDE12345FGH6789","adapterTier":"Scanner do futuro (v9)"}"#)
        let comTierDesconhecido = try decoder.decode(VehicleIdentity.self, from: tierDesconhecido)
        assert(comTierDesconhecido.adapterTier == .unknown, "enum desconhecido deve cair no padrão")

        // 4. Viagem antiga sem os campos novos: distância e combustível preservados, média recalculada.
        let viagemAntiga = dados(#"{"id":"0B5B6E1A-2E7E-4C0B-9C0E-1D2F3A4B5C6D","startDate":0,"distanceKm":52.4,"fuelLiters":4.1}"#)
        let viagem = try decoder.decode(TripRecord.self, from: viagemAntiga)
        assert(abs(viagem.distanceKm - 52.4) < 0.0001)
        assert(abs(viagem.avgKmPerLiter - 52.4 / 4.1) < 0.0001, "média ausente deve ser recalculada")
        assert(viagem.fuelProfile == .autoDetected)
        assert(viagem.endDate == viagem.startDate)

        // 5. Falha sem explicação gravada: o código sobrevive e a explicação cai num texto neutro.
        let falhaAntiga = dados(#"{"baseCode":"P0218","moduleCode":"TCU","moduleName":"Câmbio CVT","isActiveNow":true,"isConfirmed":true,"rawDTCBytesHex":"021898"}"#)
        let falha = try decoder.decode(DiagnosticFault.self, from: falhaAntiga)
        assert(falha.baseCode == "P0218")
        assert(falha.id == "TCU-P0218-00", "id ausente deve ser reconstruído")
        assert(falha.vehicleVIN == nil)
        assert(falha.interpretation.urgency == .historicalObservation)
        assert(falha.isActiveNow)

        // 5b. Falha associada a um veículo específico (VIN) gera ID isolado por chassi.
        let falhaComVin = DiagnosticFault(
            baseCode: "P0218",
            failureTypeByteHex: "98",
            moduleCode: "TCU",
            moduleName: "Câmbio CVT",
            isActiveNow: false,
            isConfirmed: true,
            rawDTCBytesHex: "021898",
            interpretation: falha.interpretation,
            vehicleVIN: "ABCDE12345FGH6789",
            vehicleModel: "Veículo de teste"
        )
        assert(falhaComVin.id == "ABCDE12345FGH6789-TCU-P0218-98", "id deve incluir o VIN quando presente")
        let falhaComVinDecodificada = try decoder.decode(DiagnosticFault.self, from: try encoder.encode(falhaComVin))
        assert(falhaComVinDecodificada.vehicleVIN == "ABCDE12345FGH6789")
        assert(falhaComVinDecodificada.vehicleModel == "Veículo de teste")

        // 6. Um item corrompido no meio do array sai sozinho, sem levar os válidos.
        let listaMista = dados("""
        [{"baseCode":"P0218","moduleCode":"TCU","moduleName":"Câmbio","isActiveNow":true,"isConfirmed":true,"rawDTCBytesHex":"021898"},
         {"isto":"não é um DTC"},
         {"baseCode":"B1408","moduleCode":"BDM","moduleName":"BDM","isActiveNow":false,"isConfirmed":true,"rawDTCBytesHex":"140831"}]
        """)
        let itens = try decoder.decode([DecodificavelTolerante<DiagnosticFault>].self, from: listaMista)
        let falhas = itens.compactMap { $0.valor }
        assert(falhas.count == 2, "esperado 2 falhas válidas, vieram \(falhas.count)")
        assert(falhas.map(\.baseCode) == ["P0218", "B1408"])

        // 7. Laudo de KM com uma prova corrompida mantém as outras e o veredito.
        let laudoAntigo = dados("""
        {"clusterEnteredKm":60327,"verdict":"KM consistente com os módulos","summaryExplanation":"ok","vinConsistencyPassed":true,
         "evidences":[{"checkTitle":"Chassi (VIN) igual entre os módulos","status":"Saudável","measuredValueText":"4 módulos"},
                      {"isto":"não é prova"},
                      {"checkTitle":"Odômetro interno do câmbio","status":"Atenção"}]}
        """)
        let laudo = try decoder.decode(OdometerAuditReport.self, from: laudoAntigo)
        assert(laudo.evidences.count == 2, "esperado 2 provas válidas, vieram \(laudo.evidences.count)")
        assert(laudo.verdict == .verifiedIntact)
        assert(laudo.evidences[1].status == .attention)
        assert(laudo.clusterEnteredKm == 60327)

        // 8. Veredito desconhecido cai em `.inconclusive` (nunca em aprovação).
        let vereditoNovo = dados(#"{"clusterEnteredKm":1,"verdict":"Veredito do futuro"}"#)
        let laudoFuturo = try decoder.decode(OdometerAuditReport.self, from: vereditoNovo)
        assert(laudoFuturo.verdict == .inconclusive, "veredito desconhecido não pode aprovar o KM")

        // 9. Regressão: dados bons continuam decodificando inteiros (o invólucro tolerante não descarta nada).
        let boas = try decoder.decode([DecodificavelTolerante<DiagnosticFault>].self, from: try encoder.encode([falha]))
        assert(boas.compactMap { $0.valor }.count == 1)

        print("✅ Persistência: 9 verificações de decode tolerante passaram (dados antigos preservados).")
    }
}
