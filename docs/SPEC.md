# CarSensei — Especificação Técnica

O **CarSensei** é um app iOS (iPhone e CarPlay) de diagnóstico, telemetria, pneus (TPMS) e auditoria de quilometragem para **qualquer carro com OBD-II / CAN**, usando o scanner **Vgate vLinker MC+** por Bluetooth LE.

**Regra de projeto:** nenhum carro é fixo no código. Tudo o que o app mostra vem do que o veículo responde. Endereços e DIDs que variam entre fabricantes são tratados como candidatos: o app tenta, aceita só respostas plausíveis e esconde o que não respondeu.

---

## 1. Arquitetura

```
┌──────────────────────────────────────────────┐
│ Veículo: rede CAN (ECM, câmbio, BCM, ABS...) │
└──────────────────────┬───────────────────────┘
                       │ tomada OBD-II
┌──────────────────────▼───────────────────────┐
│ Vgate vLinker MC+ (STN2120, Bluetooth LE)    │
└──────────────────────┬───────────────────────┘
                       │ CoreBluetooth
┌──────────────────────▼───────────────────────┐
│ App CarSensei                                │
│ 1. BLEConnectionManager (conexão, reconexão) │
│ 2. STNProtocolEngine (fila serial; AT SH +   │
│    AT CRA + controle de fluxo por comando)   │
│ 3. OBDUDSParser (modo 01/03/07/09, UDS)      │
│ 4. CarSenseiStore (+Diagnóstico, +Auditoria, │
│    +TPMS, +Viagem) e Loja (StoreKit 2)       │
│ 5. SwiftUI e CarPlay                         │
└──────────────────────────────────────────────┘
```

## 2. Identificação do veículo

| Dado | Comando | Uso |
| :--- | :--- | :--- |
| Chassi (VIN) | `09 02` ou `22 F1 90` | Chave dos ajustes por carro e do histórico |
| Nome da ECU | `09 0A` | Descrição do motor |
| Calibração | `09 04` | Exibição técnica |
| Sensores suportados | `01 00`, `01 20`, `01 40` ... | Só os mostradores suportados aparecem |
| Turbo | `01 0B` acima de `01 33` + 10 kPa | Detectado pela pressão, não pelo nome |

A **cilindrada** só entra no consumo quando o carro não tem sensor MAF (`01 10`). Padrão 1,5 L, ajustável nos Ajustes e salva por VIN.

## 3. Limites térmicos (gerais)

| Item | Atenção | Crítico |
| :--- | :--- | :--- |
| Arrefecimento (`01 05`) | 110°C | 115°C |
| Óleo do câmbio automático/CVT, quando informado | 115°C | 125°C |

São faixas gerais e preventivas; o módulo de cada carro tem as próprias proteções.

## 4. Auditoria de quilometragem

| Prova | Comando | Tipo | Reprova quando |
| :--- | :--- | :--- | :--- |
| VIN entre módulos | `22 F1 90` (motor, câmbio, painel, carroceria) | Identidade | Algum módulo tem VIN diferente (módulo de outro carro) |
| Odômetro do câmbio | `22 0B 5B` (câmbio `7E1`), quando existe | Absoluta e independente do painel | Câmbio marca mais de 1.500 km acima do painel |
| Odômetro SAE | `01 A6` (motor) | Confirmação (costuma copiar o painel) | Mais de 1.500 km acima |
| Distância desde a limpeza | `01 31` (motor) | Limite mínimo | Maior que o KM do painel |
| KM nos registros de falha | `19 03` + `19 04` (câmbio) | Limite mínimo | Registro com KM acima do painel |

Veredito: **Alerta** se alguma prova reprova; **Atenção** se há divergência sem prova de redução; **KM consistente** só quando o odômetro do câmbio bate com o painel; **Sem indícios (parcial)** quando só limites mínimos passaram; **Inconclusivo** quando nada respondeu. A regra está em `OdometerIntegrityVerdict.decide` e é testada em `scripts/verify_parser.swift`.

## 5. Pneus (TPMS)

O vLinker não recebe o rádio dos sensores; quem recebe é o módulo de TPMS do carro. O app procura esse módulo (lista de endereços comuns e varredura `7XX`), lê pressão, temperatura e IDs por DIDs candidatos e decodifica as escalas mais comuns (kPa direto, 2,5 kPa/bit, 1,375 kPa/bit, PSI×4). O endereço achado fica salvo por carro.

O pareamento de sensores novos é experimental: tenta a rotina de aprendizado (`31 01`) e a gravação dos IDs (`2E`) com sessão estendida (`10 03`), só depois da confirmação do usuário, e registra cada passo. Se o módulo exigir chave de segurança do fabricante (`27`), o app avisa que não é possível pelo OBD.

## 6. Climatização

Fora de escopo. Testes no carro mostraram que, pela tomada OBD, o módulo de clima não aceita comando. O app não envia comandos ao ar-condicionado.

## 7. Limpeza de falhas (trava KOEO)

`14 FF FF FF` (UDS) e `04` (OBD-II) só com ignição ligada, motor desligado (0 RPM) e carro parado, conferidos na hora (`01 0C`, `01 0D`).
