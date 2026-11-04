<div align="center">

# 🥋 CarSensei

**Diagnóstico, telemetria e auditoria de quilometragem para iPhone e Apple CarPlay, com o scanner Vgate vLinker MC+**
*Funciona em qualquer carro com OBD-II / CAN: o app identifica o veículo pelo que ele informa e mostra só o que o carro responde.*

<br/>

[![iOS 17+](https://img.shields.io/badge/iOS-17.0%2B-000000?style=for-the-badge&logo=apple&logoColor=white)](https://developer.apple.com/ios/)
[![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-007AFF?style=for-the-badge&logo=swift&logoColor=white)](https://developer.apple.com/xcode/swiftui/)
[![Apple CarPlay](https://img.shields.io/badge/CarPlay-Painel-5856D6?style=for-the-badge&logo=apple&logoColor=white)](https://developer.apple.com/carplay/)
[![CoreBluetooth](https://img.shields.io/badge/BLE-vLinker_MC%2B-34C759?style=for-the-badge)](https://developer.apple.com/documentation/corebluetooth)
[![ISO 14229 UDS](https://img.shields.io/badge/Protocolo-OBD--II_%2B_UDS_CAN-F05138?style=for-the-badge)](https://en.wikipedia.org/wiki/Unified_Diagnostic_Services)
[![StoreKit 2](https://img.shields.io/badge/Assinaturas-StoreKit_2-FF9500?style=for-the-badge)](https://developer.apple.com/storekit/)

</div>

---

## 🚘 Visão Geral

* **Genérico de verdade:** nenhum carro é fixo no código. O app lê o chassi (`09 02` / `22 F1 90`), o nome da ECU (`09 0A`) e a calibração (`09 04`), descobre quais sensores o carro suporta (`01 00`, `01 20`, ...) e quais módulos respondem no barramento. O que o carro não informa simplesmente não aparece.
* **Feito para o Vgate vLinker MC+ (STN2120):** com ele o app lê os outros módulos além do motor (câmbio, carroceria, freios, painel, pneus). Com um ELM327 Bluetooth LE comum, funciona no modo básico (motor e consumo).
* **Ajustes por carro:** a cilindrada (usada no consumo quando o carro não tem sensor MAF) e o endereço do módulo de pneus ficam salvos para cada carro, pelo chassi.

## ✨ Recursos

| Recurso | Como funciona |
| :--- | :--- |
| 🌡️ **Guardião Térmico** | Acompanha o arrefecimento (`PID 01 05`) e, quando o câmbio informa, o óleo do câmbio automático/CVT, com alerta na tela. Os limites são gerais, não de um modelo. |
| ⛽ **Consumo e viagens** | Fluxo (`L/h`), consumo (`km/L`) e média da viagem por `MAF` ou Speed-Density (`MAP` + `IAT` + `RPM` + ajustes de mistura), com o etanol do tanque (`PID 01 52`) quando a ECU informa. Histórico e relatório em PDF. |
| 🩺 **Diagnóstico em dupla visão** | Falhas OBD-II (`03` / `07`) e UDS (`19 02`) de todos os módulos que respondem. **Visão Cliente:** explicação simples e "Posso continuar dirigindo?". **Visão Mecânico:** código + Failure Type Byte, máscara de status, endereços CAN e snapshot `19 04`. |
| 🛡️ **Auditoria de KM** | Compara o painel com o que os módulos guardam: VIN de cada módulo (`22 F1 90`), odômetro do câmbio quando existe, distância desde a última limpeza (`01 31`) e KM nos registros de falha (`19 03` + `19 04`). Sem provas lidas, o laudo diz "Inconclusivo". |
| 🔒 **Trava KOEO** | Apagar falhas (`14 FF FF FF` / `04`) só com ignição ligada, motor desligado (0 RPM) e carro parado, conferido na hora pelo CAN. |

## 💰 Planos (StoreKit 2)

* **Teste grátis:** 30 dias, contados pelo próprio app (guardado no Keychain).
* **Anual** (`com.tissot.CarSensei.anual`, assinatura) ou **Vitalício** (`com.tissot.CarSensei.vitalicio`, compra única). Os preços vêm do App Store Connect.
* Terminado o teste sem plano, só a leitura do carro é bloqueada; falhas, viagens e laudos salvos continuam visíveis.

## 📂 Estrutura

```text
CarSensei/
├── docs/                   # Site (index.html), política de privacidade e SPEC.md
├── ios/
│   ├── CarSensei.storekit  # Produtos para teste local de compras
│   └── CarSensei/
│       ├── Core/Bluetooth/ # BLE e motor de protocolo (endereçamento CAN atômico)
│       ├── Core/Parser/    # OBD-II modo 01/03/07/09 e UDS $19/$22, TPMS
│       ├── Core/Services/  # CarSenseiStore (+Diagnóstico, +Auditoria, +TPMS, +Viagem), Loja
│       └── Views/          # Cockpit, Viagem, Diagnóstico, Ajustes, CarPlay, Planos
└── scripts/                # Verificações do parser e da persistência
```

## 🚀 Como executar

1. Verificação do parser:
   ```bash
   swiftc -parse-as-library ios/CarSensei/Core/Models/VehicleModels.swift ios/CarSensei/Core/Models/TPMSModels.swift ios/CarSensei/Core/Services/SenseiKnowledgeBase.swift ios/CarSensei/Core/Parser/OBDUDSParser.swift scripts/verify_parser.swift -o /tmp/verify_carsensei && /tmp/verify_carsensei
   ```
2. Verificação da persistência:
   ```bash
   swiftc -parse-as-library ios/CarSensei/Core/Models/VehicleModels.swift ios/CarSensei/Core/Models/TPMSModels.swift ios/CarSensei/Core/Services/SenseiKnowledgeBase.swift scripts/verify_persistence.swift -o /tmp/verify_persist && /tmp/verify_persist
   ```
3. Compilar:
   ```bash
   xcodebuild -project ios/CarSensei.xcodeproj -scheme CarSensei -destination "generic/platform=iOS" -allowProvisioningUpdates build
   ```
4. Para habilitar o **CarPlay** na distribuição App Store / Ad-Hoc:
   * Acesse o [Apple Developer Portal](https://developer.apple.com/account/resources/identifiers/list), selecione o App ID `com.tissot.CarSensei`, ative a capability **CarPlay Audio** (já liberada na equipe `W548XAP3P5`) e vincule `CarSensei/CarSensei.entitlements` em *Build Settings > Code Signing Entitlements*.

## 🔒 Privacidade

Os dados do carro ficam no iPhone. O app envia ao desenvolvedor, automaticamente, relatórios técnicos de falhas do próprio app (sem dados pessoais e sem o VIN completo), e os relatos que o usuário mandar pela tela de feedback. Detalhes na [Política de Privacidade](docs/privacidade/index.html).
