import Foundation
import UIKit
import SwiftUI

/// Gera um relatório em PDF das viagens e dos laudos de sensores, pensado para ser enviado a uma IA
/// (ou a um mecânico) analisar: dados brutos com unidade, faixa de referência e contexto do veículo,
/// sem opinião embutida do app.
enum TripReportPDF {

    // MARK: - API

    static func build(
        identity: VehicleIdentity,
        reports: [TripSensorAnalysisReport],
        fuelTrips: [TripRecord],
        adapterDescription: String,
        batterySnapshot: BatteryTripSnapshot? = nil,
        generatedAt: Date = Date()
    ) -> URL? {
        let page = CGRect(x: 0, y: 0, width: 595.2, height: 841.8) // A4 em pontos
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: "CarSensei — Relatório de Viagens",
            kCGPDFContextCreator as String: "CarSensei"
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: page, format: format)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CarSensei-Viagens-\(fileStamp(generatedAt)).pdf")

        let data = renderer.pdfData { ctx in
            var writer = Writer(context: ctx, pageRect: page)
            writer.beginPage()

            writer.title("CarSensei — Relatório de Viagens e Sensores")
            writer.subtitle("Documento gerado em \(stamp(generatedAt)) · versão \(appVersion()) · para análise externa (IA ou mecânico)")

            writer.section("1. Veículo e equipamento")
            writer.keyValue([
                ("Veículo", identity.modelDescription),
                ("VIN (chassi)", identity.vin),
                ("Motor", identity.engineCode),
                ("Transmissão", identity.transmissionCode),
                ("Scanner", adapterDescription),
                ("Firmware", identity.adapterFirmware),
                ("Protocolo", identity.obdProtocol),
                ("Cilindrada usada no cálculo", String(format: "%.3f L", identity.displacementLiters))
            ])

            writer.section("2. Como ler este documento")
            writer.paragraph("""
            Cada viagem é um laudo independente, com amostras reais lidas pelo conector OBD-II/UDS (ISO 15765-4 e \
            ISO 14229). Para cada sensor são registrados mínimo, média, máximo e último valor, além da faixa de \
            referência usada pelo app para aquele veículo. Unidades: km/L (consumo), °C (temperatura), kPa (pressão), \
            %, V (tensão), RPM, km/h e ms (avanço de ignição). Onde houver "aguardando leitura", o sensor não \
            respondeu naquela viagem — não significa defeito.
            """)

            // 3. Resumo consolidado
            writer.section("3. Resumo consolidado")
            if reports.isEmpty {
                writer.paragraph("Nenhum laudo de viagem salvo até o momento.")
            } else {
                let totalKm = reports.reduce(0) { $0 + $1.distanceKm }
                let totalL = reports.reduce(0) { $0 + $1.fuelUsedLiters }
                let avg = totalL > 0 ? totalKm / totalL : nil
                let worst = reports.min { $0.overallScorePercent < $1.overallScorePercent }
                writer.keyValue([
                    ("Laudos salvos", "\(reports.count)"),
                    ("Período", "\(stamp(reports.map(\.startDate).min() ?? generatedAt)) a \(stamp(reports.map(\.endDate).max() ?? generatedAt))"),
                    ("Distância somada", String(format: "%.1f km", totalKm)),
                    ("Combustível somado", String(format: "%.2f L", totalL)),
                    ("Consumo médio ponderado", avg.map { String(format: "%.1f km/L", $0) } ?? "sem dado"),
                    ("Pior laudo", worst.map { "\($0.overallScorePercent)% — \($0.laypersonHeadline)" } ?? "-")
                ])
            }

            // 4. Histórico de laudos
            if !reports.isEmpty {
                writer.section("4. Laudos de viagem")
                for (index, rep) in reports.prefix(30).enumerated() {
                    writer.ensureSpace(120)
                    writer.subheading("4.\(index + 1) \(stamp(rep.endDate)) — \(rep.vehicleModel) — \(rep.overallScorePercent)% (\(rep.overallHealth.rawValue))")
                    writer.paragraph(rep.laypersonHeadline, font: .italicSystemFont(ofSize: 9))
                    writer.keyValue([
                        ("Início / fim", "\(stamp(rep.startDate)) → \(stamp(rep.endDate))"),
                        ("Duração", duration(rep.durationSeconds)),
                        ("Encerrada por", rep.finishReason),
                        ("Distância", String(format: "%.1f km", rep.distanceKm)),
                        ("Combustível", String(format: "%.2f L", rep.fuelUsedLiters)),
                        ("Consumo médio", rep.avgKmPerLiter.map { String(format: "%.1f km/L", $0) } ?? "sem dado"),
                        ("Velocidade máxima", rep.maxSpeedKmh.map { String(format: "%.0f km/h", $0) } ?? "sem dado"),
                        ("PIDs suportados", "\(rep.supportedPIDsCount)")
                    ])

                    if !rep.items.isEmpty {
                        writer.tableHeader(["Sensor", "Mín", "Méd", "Máx", "Un", "Referência", "Status"])
                        for item in rep.items {
                            writer.tableRow([
                                item.gauge.title,
                                num(item.minValue),
                                num(item.avgValue),
                                num(item.maxValue),
                                item.unit,
                                item.expectedRangeText,
                                item.healthLevel.rawValue
                            ])
                        }
                        let attention = rep.items.filter { $0.healthLevel == .attention || $0.healthLevel == .critical }
                        if !attention.isEmpty {
                            writer.paragraph("Sensores fora do ideal nesta viagem:", font: .boldSystemFont(ofSize: 9))
                            for item in attention {
                                writer.bullet("\(item.gauge.title): \(item.statusBadgeTitle) — \(item.laypersonTripVerdict)")
                            }
                        }
                    }
                    writer.spacer(6)
                }
                if reports.count > 30 {
                    writer.paragraph("(mostrando os 30 laudos mais recentes de \(reports.count))", font: .italicSystemFont(ofSize: 8))
                }
            }

            // 5. Consumo por viagem (TripRecord)
            if !fuelTrips.isEmpty {
                writer.section("5. Histórico de consumo (computador de bordo)")
                writer.tableHeader(["Data", "km", "L", "km/L", "Duração", "Vel. média", "Máx. motor", "Máx. câmbio"])
                for trip in fuelTrips.prefix(40) {
                    writer.tableRow([
                        stamp(trip.startDate),
                        String(format: "%.1f", trip.distanceKm),
                        String(format: "%.2f", trip.fuelLiters),
                        String(format: "%.1f", trip.avgKmPerLiter),
                        duration(trip.durationSeconds),
                        trip.avgSpeedKmh.map { String(format: "%.0f", $0) } ?? "-",
                        trip.maxCoolantTempC.map { String(format: "%.0f°C", $0) } ?? "-",
                        trip.maxCvtTempC.map { String(format: "%.0f°C", $0) } ?? "-"
                    ])
                }
                if fuelTrips.count > 40 {
                    writer.paragraph("(mostrando as 40 viagens mais recentes de \(fuelTrips.count))", font: .italicSystemFont(ofSize: 8))
                }
            }

            if let bat = batterySnapshot {
                writer.section("6. Bateria na última viagem registrada")
                writer.keyValue([
                    ("Registro", stamp(bat.recordedAt)),
                    ("Tensão em repouso", String(format: "%.2f V", bat.initialRestVoltage)),
                    ("Tensão ao final", String(format: "%.2f V", bat.finalVoltage)),
                    ("Mínima na partida", bat.minCrankingVoltage.map { String(format: "%.2f V", $0) } ?? "sem teste de partida"),
                    ("Carga estimada", "\(bat.socPercent)% (\(bat.healthTitle))")
                ])
            }

            // Perguntas sugeridas para quem for analisar
            writer.section("\(questionsSectionNumber(hasBattery: batterySnapshot != nil)). Perguntas sugeridas para a análise")
            writer.bullet("O consumo médio é compatível com o motor/câmbio informados e com o combustível declarado?")
            writer.bullet("Algum sensor mostra tendência de piora entre as viagens (máximos subindo, médias caindo)?")
            writer.bullet("As temperaturas de motor e câmbio ficaram dentro da faixa de referência em todas as viagens?")
            writer.bullet("Há sinais de bateria fraca ou de alternador fora da faixa nas tensões registradas?")
            writer.bullet("Quais verificações o proprietário deveria pedir na próxima revisão, em ordem de prioridade?")

            writer.finish()
        }

        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            TissotFeedback.error(error, context: "TripReportPDF.write")
            return nil
        }
    }

    // MARK: - Formatação

    private static func appVersion() -> String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "dd/MM/yyyy HH:mm"
        return f.string(from: date)
    }

    private static func fileStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f.string(from: date)
    }

    private static func duration(_ seconds: Double) -> String {
        guard seconds > 0 else { return "-" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%dh%02d", h, m) : String(format: "%dmin%02ds", m, s)
    }

    private static func num(_ value: Double) -> String {
        guard value.isFinite else { return "-" }
        let absValue = abs(value)
        if absValue >= 100 { return String(format: "%.0f", value) }
        if absValue >= 10 { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }

    /// Número da última seção: 1..5 fixas + bateria (opcional) → perguntas vem depois.
    private static func questionsSectionNumber(hasBattery: Bool) -> Int {
        hasBattery ? 7 : 6
    }

    // MARK: - Escritor de páginas

    private struct Writer {
        let context: UIGraphicsPDFRendererContext
        let pageRect: CGRect
        let margin: CGFloat = 40
        var y: CGFloat = 0
        let contentWidth: CGFloat

        init(context: UIGraphicsPDFRendererContext, pageRect: CGRect) {
            self.context = context
            self.pageRect = pageRect
            self.contentWidth = pageRect.width - 80
            self.y = pageRect.height - 40 // força abrir a primeira página
        }

        private var bottom: CGFloat { pageRect.height - margin - 18 }

        mutating func beginPage() {
            context.beginPage()
            y = margin
            drawFooterPlaceholder()
        }

        private mutating func ensurePage() {
            if y > bottom - 12 {
                beginPage()
            }
        }

        mutating func ensureSpace(_ height: CGFloat) {
            if y + height > bottom { beginPage() }
        }

        mutating func spacer(_ h: CGFloat) {
            y += h
        }

        private mutating func drawFooterPlaceholder() {}

        private func draw(_ text: String, font: UIFont, color: UIColor, in rect: CGRect, alignment: NSTextAlignment = .left) {
            let style = NSMutableParagraphStyle()
            style.alignment = alignment
            style.lineBreakMode = .byWordWrapping
            (text as NSString).draw(
                with: rect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style],
                context: nil
            )
        }

        private func height(of text: String, font: UIFont, width: CGFloat) -> CGFloat {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byWordWrapping
            let rect = (text as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin],
                attributes: [.font: font, .paragraphStyle: style],
                context: nil
            )
            return ceil(rect.height)
        }

        mutating func title(_ text: String) {
            let font = UIFont.systemFont(ofSize: 17, weight: .bold)
            let h = height(of: text, font: font, width: contentWidth)
            ensureSpace(h + 6)
            draw(text, font: font, color: .black, in: CGRect(x: margin, y: y, width: contentWidth, height: h))
            y += h + 2
        }

        mutating func subtitle(_ text: String) {
            let font = UIFont.systemFont(ofSize: 8.5)
            let h = height(of: text, font: font, width: contentWidth)
            ensureSpace(h + 8)
            draw(text, font: font, color: .darkGray, in: CGRect(x: margin, y: y, width: contentWidth, height: h))
            y += h + 10
        }

        mutating func section(_ text: String) {
            let font = UIFont.systemFont(ofSize: 12, weight: .bold)
            let h = height(of: text, font: font, width: contentWidth)
            ensureSpace(h + 12)
            y += 6
            draw(text, font: font, color: UIColor(red: 0.05, green: 0.32, blue: 0.72, alpha: 1), in: CGRect(x: margin, y: y, width: contentWidth, height: h))
            y += h + 4
            let line = UIBezierPath()
            line.move(to: CGPoint(x: margin, y: y))
            line.addLine(to: CGPoint(x: pageRect.width - margin, y: y))
            UIColor(red: 0.80, green: 0.84, blue: 0.90, alpha: 1).setStroke()
            line.lineWidth = 0.7
            line.stroke()
            y += 6
        }

        mutating func subheading(_ text: String) {
            let font = UIFont.systemFont(ofSize: 10, weight: .semibold)
            let h = height(of: text, font: font, width: contentWidth)
            ensureSpace(h + 16)
            y += 4
            draw(text, font: font, color: .black, in: CGRect(x: margin, y: y, width: contentWidth, height: h))
            y += h + 3
        }

        mutating func paragraph(_ text: String, font: UIFont = UIFont.systemFont(ofSize: 9)) {
            let h = height(of: text, font: font, width: contentWidth)
            ensureSpace(min(h, bottom - margin))
            draw(text, font: font, color: UIColor(white: 0.15, alpha: 1), in: CGRect(x: margin, y: y, width: contentWidth, height: h))
            y += h + 4
        }

        mutating func bullet(_ text: String) {
            let font = UIFont.systemFont(ofSize: 9)
            let bulletWidth: CGFloat = 10
            let h = height(of: text, font: font, width: contentWidth - bulletWidth)
            ensureSpace(min(h, bottom - margin))
            draw("•", font: font, color: .darkGray, in: CGRect(x: margin, y: y, width: bulletWidth, height: h))
            draw(text, font: font, color: UIColor(white: 0.15, alpha: 1), in: CGRect(x: margin + bulletWidth, y: y, width: contentWidth - bulletWidth, height: h))
            y += h + 2
        }

        mutating func keyValue(_ pairs: [(String, String)]) {
            let labelFont = UIFont.systemFont(ofSize: 9, weight: .semibold)
            let valueFont = UIFont.systemFont(ofSize: 9)
            let labelWidth: CGFloat = 150
            for (label, value) in pairs {
                let valueWidth = contentWidth - labelWidth
                let h = max(
                    height(of: label, font: labelFont, width: labelWidth),
                    height(of: value, font: valueFont, width: valueWidth)
                )
                ensureSpace(min(h + 2, bottom - margin))
                draw(label, font: labelFont, color: .darkGray, in: CGRect(x: margin, y: y, width: labelWidth, height: h))
                draw(value, font: valueFont, color: .black, in: CGRect(x: margin + labelWidth, y: y, width: valueWidth, height: h))
                y += h + 2
            }
            y += 4
        }

        /// Larguras por tabela: 7 colunas (sensores) e 8 colunas (consumo por viagem).
        /// A soma precisa caber em `contentWidth` (515 pt), senão a última coluna sai da página.
        private func columnWidths(for count: Int) -> [CGFloat] {
            switch count {
            case 8: return [78, 55, 55, 50, 62, 60, 70, 75]   // 505 pt
            default: return [148, 42, 42, 42, 30, 145, 60]    // 509 pt
            }
        }

        mutating func tableHeader(_ titles: [String]) {
            let font = UIFont.systemFont(ofSize: 8, weight: .bold)
            let h: CGFloat = 13
            ensureSpace(h * 2)
            UIColor(white: 0.93, alpha: 1).setFill()
            UIBezierPath(rect: CGRect(x: margin, y: y, width: contentWidth, height: h)).fill()
            let widths = columnWidths(for: titles.count)
            var x = margin
            for (i, title) in titles.enumerated() {
                let w = i < widths.count ? widths[i] : 50
                draw(title, font: font, color: .black, in: CGRect(x: x + 2, y: y + 2.5, width: w - 4, height: h))
                x += w
            }
            y += h
        }

        mutating func tableRow(_ values: [String]) {
            let font = UIFont.systemFont(ofSize: 8)
            let widths = columnWidths(for: values.count)
            var tallest: CGFloat = 13
            for (i, value) in values.enumerated() {
                let w: CGFloat = i < widths.count ? widths[i] : 50
                tallest = max(tallest, height(of: value, font: font, width: w - 4))
            }
            let rowHeight: CGFloat = tallest + 2
            ensureSpace(rowHeight)
            var x = margin
            for (i, value) in values.enumerated() {
                let w = i < widths.count ? widths[i] : 50
                let color: UIColor = i == values.count - 1
                    ? statusColor(value)
                    : UIColor(white: 0.1, alpha: 1)
                draw(value, font: font, color: color, in: CGRect(x: x + 2, y: y + 1.5, width: w - 4, height: rowHeight))
                x += w
            }
            y += rowHeight
            let line = UIBezierPath()
            line.move(to: CGPoint(x: margin, y: y))
            line.addLine(to: CGPoint(x: pageRect.width - margin, y: y))
            UIColor(white: 0.88, alpha: 1).setStroke()
            line.lineWidth = 0.4
            line.stroke()
        }

        private func statusColor(_ status: String) -> UIColor {
            switch status {
            case "Crítico": return UIColor(red: 0.75, green: 0.10, blue: 0.10, alpha: 1)
            case "Atenção": return UIColor(red: 0.72, green: 0.45, blue: 0.02, alpha: 1)
            case "Saudável": return UIColor(red: 0.06, green: 0.48, blue: 0.20, alpha: 1)
            default: return .darkGray
            }
        }

        mutating func finish() {
            let font = UIFont.systemFont(ofSize: 7.5)
            draw("CarSensei · relatório gerado automaticamente a partir dos dados do OBD-II — sem opinião automática embutida",
                 font: font, color: UIColor(white: 0.55, alpha: 1),
                 in: CGRect(x: margin, y: pageRect.height - 30, width: contentWidth, height: 12))
        }
    }
}

/// Wrapper `Identifiable` para apresentar o arquivo em `.sheet(item:)`.
struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - Compartilhamento do arquivo (UIActivityViewController)

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
