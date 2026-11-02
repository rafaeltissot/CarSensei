import Foundation

public enum SenseiKnowledgeBase {

    // MARK: - UDS ISO 14229 Failure Type Byte (FTB) Decoder

    public static func decodeFailureTypeByte(_ hexByte: String?) -> String? {
        guard let hex = hexByte?.uppercased(), !hex.isEmpty else { return nil }
        switch hex {
        case "00": return "Sem subtipo adicional (Padrão ISO)"
        case "01": return "Falha elétrica geral"
        case "11": return "Circuito em curto com o terra (GND)"
        case "12": return "Circuito em curto com positivo da bateria (+12V)"
        case "13": return "Circuito aberto (fio rompido ou conector desconectado)"
        case "16": return "Tensão do circuito abaixo do limite mínimo"
        case "17": return "Tensão do circuito acima do limite máximo"
        case "1C": return "Tensão do circuito fora de faixa"
        case "21": return "Amplitude de sinal abaixo do mínimo"
        case "22": return "Amplitude de sinal acima do máximo"
        case "29": return "Sinal inválido / implausível"
        case "31": return "Ausência de sinal do sensor (No Signal)"
        case "4B": return "Superaquecimento de calibração / memória"
        case "62": return "Falha na comparação de sinal entre sensores"
        case "71": return "Atuador travado fechado / engripado"
        case "72": return "Atuador travado aberto"
        case "77": return "Posição comandada do atuador não alcançada"
        case "86": return "Sinal inválido recebido na rede CAN"
        case "87": return "Mensagem ausente na rede CAN (Timeout)"
        case "92": return "Desempenho ou operação incorreta do componente"
        case "98": return "Temperatura excessiva do componente ou sistema (Over Temperature)"
        default: return "Subtipo técnico UDS (\(hex))"
        }
    }

    // MARK: - Contextual Dual-View Interpretation (Visão Cliente + Visão Mecânico)

    public static func interpretFault(
        baseCode: String,
        ftbHex: String?,
        moduleCode: String,
        isActiveNow: Bool,
        brandProfile: VehicleBrandProfile = .autoDetect
    ) -> SenseiMechanicalInterpretation {
        let code = baseCode.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let ftbNote = decodeFailureTypeByte(ftbHex)

        switch code {
        case "P0218":
            return SenseiMechanicalInterpretation(
                headline: "Aviso de Temperatura Alta no Câmbio Automático / CVT",
                plainExplanation: isActiveNow
                    ? "O óleo da transmissão está muito quente neste exato momento."
                    : "Em algum passeio anterior, o óleo do câmbio esquentou além do normal e deixou este lembrete salvo na memória. Agora já esfriou e está INATIVO.",
                vehicleContext: "Em câmbios automáticos e CVT, a faixa normal do fluido em trânsito ou estrada costuma ser de 70°C a 110°C. O módulo do câmbio só grava este código quando a temperatura passa do limite dele sob esforço severo sustentado (subidas longas de serra, reboque, trânsito no calor).",
                probableCauses: [
                    "Subida de serra íngreme ou trânsito severo em dia muito quente no passado",
                    "Fluido do câmbio CVT com mais de 45.000 km precisando de troca preventiva",
                    "Eficiência reduzida no trocador de calor água-óleo da transmissão"
                ],
                falsePositiveWarning: isActiveNow
                    ? nil
                    : "Como o aviso está INATIVO (Memória Histórica), o seu câmbio NÃO está com defeito agora.",
                recommendedAction: "1) Confira na Perícia de KM a quilometragem exata em que esquentou. 2) Verifique quando foi feita a última troca do óleo do câmbio CVT (recomendada a cada 40.000–50.000 km). 3) Apague o aviso antigo e acompanhe pelo Guardião Térmico.",
                urgency: isActiveNow ? .stopImmediately : .historicalObservation,
                customerCanDriveBanner: isActiveNow
                    ? "🛑 Pare em um local seguro por 15 minutos com o motor ligado em P/N para o câmbio esfriar!"
                    : "✅ Pode dirigir tranquilo! Isso é apenas uma lembrança antiga salva na memória.",
                customerSimpleStory: isActiveNow
                    ? "O óleo do seu câmbio automático está muito quente agora (comum em subidas fortes ou engarrafamento pesado no calor). Pare um pouquinho para ele esfriar."
                    : "Em uma viagem passada (provavelmente numa subida longa ou dia muito quente), o óleo do câmbio esquentou e o carro anotou isso no caderno de memórias dele. Hoje o câmbio está frio e funcionando 100% normal!",
                customerWorkshopProtectionTip: "🛡️ Proteção na Oficina: Não deixe ninguém condenar ou abrir o seu câmbio por causa desse aviso antigo! Tudo o que você precisa fazer é checar se já deu a quilometragem de trocar o óleo do câmbio (a cada 40 a 50 mil km) e limpar essa memória antiga."
            )

        case "P0171":
            return SenseiMechanicalInterpretation(
                headline: "Mistura Pobre (Pouco Combustível ou Ar Entrando Fora de Hora)",
                plainExplanation: "O motor percebeu ar demais ou combustível de menos na queima e precisou injetar combustível extra para compensar.",
                vehicleContext: "Em carros flex, isso acontece muito quando você troca de gasolina para etanol e anda pouco tempo, ou quando alguma mangueira de ar do motor está com a abraçadeira frouxa.",
                probableCauses: [
                    "Abastecimento recente trocando combustível (Etanol/Gasolina) sem tempo de adaptação",
                    "Mangueira de ar com abraçadeira frouxa (entrada falsa de ar)",
                    "Bicos injetores ou filtro de combustível precisando de limpeza"
                ],
                falsePositiveWarning: nil,
                recommendedAction: "Se você acabou de abastecer outro combustível, rode 15 minutos em velocidade constante. Se persistir, peça para revisar mangueiras de ar e limpeza de bicos.",
                urgency: .attentionSoon,
                customerCanDriveBanner: "⚠️ Você pode dirigir até em casa ou à oficina, mas evite forçar o motor em subidas.",
                customerSimpleStory: "O motor sentiu falta de combustível ou excesso de ar na mistura. Muitas vezes isso acontece só porque você trocou de Gasolina para Etanol (ou vice-versa) no posto e o carro ainda está aprendendo qual combustível está no tanque.",
                customerWorkshopProtectionTip: "🛡️ Proteção na Oficina: Antes de autorizar troca cara de bomba ou sonda lambda, peça primeiro para olharem se não tem nenhuma mangueirinha de ar solta ou se foi só troca de combustível no posto!"
            )

        case "P0172":
            return SenseiMechanicalInterpretation(
                headline: "Mistura Rica (Excesso de Combustível na Queima)",
                plainExplanation: "O computador do motor percebeu combustível sobrando na queima e está reduzindo a injeção para economizar.",
                vehicleContext: "Muito comum em carros flex logo após colocar gasolina em um tanque que estava com etanol, ou quando a válvula de respiro do tanque (canister) fica aberta.",
                probableCauses: [
                    "Troca recente de Etanol para Gasolina em trajeto curto",
                    "Válvula de purga do canister (respiro do tanque) travada aberta",
                    "Bico injetor sujo"
                ],
                falsePositiveWarning: nil,
                recommendedAction: "Rode por 15 a 20 minutos para a injeção reconhecer a Gasolina. Se continuar acendendo, verifique a válvula do canister.",
                urgency: .attentionSoon,
                customerCanDriveBanner: "⚠️ Pode rodar normalmente, mas o carro pode gastar um pouco mais de combustível até ajustar.",
                customerSimpleStory: "O motor percebeu que está entrando um pouquinho mais de combustível do que o necessário. Isso quase sempre acontece quando você rodava no Álcool, colocou Gasolina e andou poucos quarteirões.",
                customerWorkshopProtectionTip: "🛡️ Proteção na Oficina: Dê uma volta de 15 minutos na avenida antes de levar na oficina — na maioria das vezes o próprio computador Flex se ajusta sozinho sem gastar 1 real!"
            )

        case "P0300", "P0301", "P0302", "P0303", "P0304":
            let cylinder = code == "P0300" ? "vários cilindros" : "cilindro \(code.last ?? "1")"
            return SenseiMechanicalInterpretation(
                headline: "Falha na Faísca do Motor (\(cylinder.capitalized))",
                plainExplanation: "A vela ou bobina do \(cylinder) falhou ao soltar a faísca que queima o combustível.",
                vehicleContext: "Causado por velas de ignição desgastadas, bobina com fuga de corrente ou gasolina/etanol de má qualidade.",
                probableCauses: [
                    "Velas de ignição precisando de troca",
                    "Bobina de ignição ressecada no \(cylinder)",
                    "Combustível batizado no último abastecimento"
                ],
                falsePositiveWarning: nil,
                recommendedAction: "Se o carro estiver tremendo/engasgando, evite acelerar forte e leve para revisar as velas e bobinas.",
                urgency: isActiveNow ? .stopImmediately : .attentionSoon,
                customerCanDriveBanner: isActiveNow
                    ? "🛑 Se o motor estiver tremendo ou a luz piscando, não acelere forte! Vá devagar até a oficina."
                    : "⚠️ Foi uma engasgada passageira. Se o motor está liso agora, pode dirigir tranquilo.",
                customerSimpleStory: "Sabe a vela do motor que solta a faísca para queimar o combustível? Ela deu uma falhadinha no \(cylinder) (pode ser vela gasta ou combustível ruim do posto).",
                customerWorkshopProtectionTip: "🛡️ Proteção na Oficina: O defeito está indicado exatamente no \(cylinder). Peça para olharem primeiro a vela e a bobina desse cilindro antes de mexerem no resto do motor!"
            )

        default:
            let categoryTitle: String
            let systemHint: String
            let simpleArea: String
            if code.hasPrefix("P07") || code.hasPrefix("P08") || code.hasPrefix("P021") || moduleCode.contains("TCU") {
                categoryTitle = "Aviso no Câmbio (\(code))"
                systemHint = "Registrado no módulo da transmissão (TCU)."
                simpleArea = "do câmbio automático"
            } else if moduleCode.contains("HVAC") {
                categoryTitle = "Aviso no Ar-Condicionado (\(code))"
                systemHint = "Registrado no controlador de climatização (HVAC)."
                simpleArea = "do ar-condicionado"
            } else if code.hasPrefix("B") || moduleCode.contains("BDM") {
                categoryTitle = "Aviso Elétrico / Conforto (\(code))"
                systemHint = "Registrado no módulo de carroceria (BDM/BCM)."
                simpleArea = "da parte elétrica interna (luzes/portas)"
            } else if code.hasPrefix("C") || moduleCode.contains("ABS") {
                categoryTitle = "Aviso nos Freios / Estabilidade (\(code))"
                systemHint = "Registrado no módulo ABS/ESP."
                simpleArea = "do sistema de freios ABS"
            } else if code.hasPrefix("U") {
                categoryTitle = "Aviso de Comunicação Interna (\(code))"
                systemHint = "Atraso momentâneo de mensagem na rede CAN."
                simpleArea = "da conversa entre os computadores do carro"
            } else {
                categoryTitle = "Aviso no Motor / Injeção (\(code))"
                systemHint = "Registrado na injeção eletrônica do motor (ECM)."
                simpleArea = "do motor"
            }

            let ftbSuffix = ftbNote.map { " Detalhe técnico: \($0)." } ?? ""
            return SenseiMechanicalInterpretation(
                headline: categoryTitle,
                plainExplanation: "\(systemHint)\(ftbSuffix)",
                vehicleContext: isActiveNow
                    ? "Este código está ATIVO agora no módulo \(moduleCode). Vale inspecionar o sensor ou conector correspondente."
                    : "Este código está INATIVO (guardado apenas no histórico do módulo \(moduleCode)). O carro está funcionando normalmente neste momento.",
                probableCauses: [
                    ftbNote ?? "Oscilação momentânea de leitura de sensor",
                    "Queda rápida de tensão da bateria na partida",
                    "Evento antigo que já se resolveu sozinho"
                ],
                falsePositiveWarning: isActiveNow ? nil : "Por estar INATIVO (histórico), não há falha acontecendo agora.",
                recommendedAction: "Limpe o histórico após verificar a Perícia de KM e veja se o aviso volta a aparecer nos próximos dias.",
                urgency: isActiveNow ? .attentionSoon : .historicalObservation,
                customerCanDriveBanner: isActiveNow
                    ? "⚠️ Você pode dirigir com calma, mas vale fazer um check-up em breve."
                    : "✅ Pode dirigir tranquilo! É apenas uma anotação antiga que já passou.",
                customerSimpleStory: isActiveNow
                    ? "O computador \(simpleArea) notou um sensor fora do padrão agora (\(code)). O carro continua andando, mas convém revisar quando puder."
                    : "O computador \(simpleArea) guardou uma anotação antiga (\(code)) de algo que aconteceu no passado, mas que já voltou ao normal sozinho.",
                customerWorkshopProtectionTip: isActiveNow
                    ? "🛡️ Proteção na Oficina: Mostre a aba 'Visão Mecânico' para o seu reparador ir direto ao ponto sem cobrar diagnósticos extras."
                    : "🛡️ Proteção na Oficina: Como este aviso está INATIVO, apague-o aqui pelo app primeiro. Só leve à oficina se ele voltar a aparecer nos próximos dias!"
            )
        }
    }

    // MARK: - Telemetry Real-Time Mechanical Evaluators

    public static func evaluateCoolant(_ tempC: Double?, thresholds: CoolantThermalThresholds? = nil) -> (HealthLevel, String) {
        guard let t = tempC else { return (.unknown, "Aguardando leitura da temperatura do motor") }
        let crit = thresholds?.criticalDTCThresholdC ?? 115.0
        let normMax = thresholds?.fanHighNormalMaxC ?? 108.0

        if t < 75 {
            return (.attention, String(format: "Motor ainda aquecendo (%.0f°C). Dirija suave até atingir a temperatura ideal.", t))
        } else if t <= normMax {
            return (.healthy, String(format: "Temperatura de trabalho perfeita (%.0f°C). Circuito de arrefecimento 100%% saudável.", t))
        } else if t < crit {
            return (.attention, String(format: "Motor em carga térmica alta (%.0f°C). Ventoinha trabalhando no estágio máximo.", t))
        } else {
            return (.critical, String(format: "PERIGO DE SUPERAQUECIMENTO (%.0f°C ≥ %.0f°C)! Pare o carro em local seguro agora!", t, crit))
        }
    }

    public static func evaluateCVTTemp(_ tempC: Double?, thresholds: TransmissionThermalThresholds? = nil) -> (HealthLevel, String) {
        guard let t = tempC else { return (.unknown, "Aguardando leitura térmica do câmbio") }
        let crit = thresholds?.criticalDTCThresholdC ?? 125.0
        let warn = thresholds?.thermalInterventionC ?? 118.0
        let warm = thresholds?.warmUpThresholdC ?? 60.0
        let norm = thresholds?.heavyLoadNormalMaxC ?? 117.0

        if t < warm {
            return (.healthy, String(format: "Óleo do câmbio em aquecimento intencional (%.0f°C). Normal.", t))
        } else if t <= norm {
            let desc = t > 100 ? String(format: " (sob carga/rodovia — normal até %.0f°C)", norm) : " (faixa nominal ideal)"
            return (.healthy, String(format: "Óleo do câmbio em temperatura normal (%.0f°C)%@.", t, desc))
        } else if t < crit {
            return (.attention, String(format: "Guardião CVT: Óleo aquecendo (%.0f°C ≥ %.0f°C). A TCU atua no conversor de torque para resfriar.", t, warn))
        } else {
            return (.critical, String(format: "ALERTA CRÍTICO CVT (%.0f°C ≥ %.0f°C)! Risco de DTC P0218. Pare com motor ligado em P/N para resfriar!", t, crit))
        }
    }

    public static func evaluateBattery(_ volts: Double?) -> (HealthLevel, String) {
        guard let v = volts else { return (.unknown, "Aguardando leitura de tensão da bateria") }
        if v < 11.9 {
            return (.critical, String(format: "Bateria fraca ou alternador sem carregar (%.2fV)!", v))
        } else if v < 13.2 {
            return (.attention, String(format: "Tensão de bateria parada (%.2fV). Com motor ligado deve ficar entre 13,5V e 14,5V.", v))
        } else if v <= 14.6 {
            return (.healthy, String(format: "Bateria e alternador perfeitos (%.2fV).", v))
        } else {
            return (.critical, String(format: "Tensão alta demais no alternador (%.2fV)!", v))
        }
    }

    public static func evaluateFuelTrim(_ stft: Double?, ltft: Double?) -> (HealthLevel, String) {
        guard let s = stft else { return (.unknown, "Aguardando leitura da injeção eletrônica") }
        let combined = s + (ltft ?? 0.0)
        if abs(combined) <= 10.0 {
            return (.healthy, String(format: "Queima de combustível perfeita e econômica (%+.1f%%).", s))
        } else if abs(combined) <= 18.0 {
            return (.attention, String(format: "Injeção se adaptando ao combustível (%+.1f%%).", s))
        } else {
            return (.critical, String(format: "Injeção corrigindo muito (%+.1f%%). Verifique qualidade do combustível ou mangueiras de ar.", s))
        }
    }

    public static func evaluateMAP(_ kpa: Double?, rpm: Double?) -> (HealthLevel, String) {
        guard let p = kpa else { return (.unknown, "Aguardando pressão do coletor (MAP)") }
        let isIdle = (rpm ?? 800) < 950
        if isIdle {
            if p >= 25 && p <= 46 {
                return (.healthy, String(format: "Vácuo do motor saudável em marcha lenta (%.0f kPa).", p))
            } else {
                return (.attention, String(format: "Pressão em lenta (%.0f kPa — normal subir com Ar-Condicionado ligado).", p))
            }
        } else if p > 105 {
            let boostBar = (p - 98.0) / 100.0
            return (.healthy, String(format: "Pressão positiva de turbo (+%.2f bar / %.0f kPa).", boostBar, p))
        } else {
            return (.healthy, String(format: "Pressão de cruzeiro normal (%.0f kPa).", p))
        }
    }
}
