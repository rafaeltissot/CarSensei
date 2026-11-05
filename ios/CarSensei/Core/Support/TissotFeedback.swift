//
//  TissotFeedback.swift — SDK único (drop-in) da Central de Relatos, Erros, Crashes & Logs Tissot
//  Versão 2.0 · iOS 17+ · zero dependências
//
//  Fonte canônica: GarimpAI/feedback-hub/sdk/TissotFeedback.swift (copie este arquivo sem editar).
//  Compila com e sem SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor.
//
//  O que ele faz sozinho depois de `TissotFeedback.start()`:
//   • Buffer circular dos últimos 300 logs (persistido em disco; sobrevive a crash)
//   • Crash de Objective-C (NSException) gravado na hora e enviado no próximo launch
//   • Crashes de Swift/sinais e travamentos via MetricKit (enviados no próximo launch)
//   • Erros não fatais via `TissotFeedback.error(_:context:)` (1 envio por erro/sessão)
//   • Fila offline: nada se perde sem internet (reenvia no próximo launch/envio)
//   • Dados completos do aparelho em cada envio (modelo, iOS, rede, bateria, memória, disco…)
//   • Tela de relato (TissotFeedbackSheet) com ditado por voz, captura de tela e contato opcional
//   • CarPlay: item "Relatar problema" falado (TissotFeedbackCarPlay.reportListItem)
//   • Siri: TissotReportProblemIntent ("E aí Siri, relatar problema no <App>") — funciona no carro
//
//  Info.plist: NSMicrophoneUsageDescription e NSSpeechRecognitionUsageDescription (ditado / CarPlay).
//

import Foundation
import Combine
import SwiftUI
import UIKit
import MetricKit
import Network
import Speech
import AVFoundation
import AppIntents
#if canImport(CarPlay)
import CarPlay
#endif

// MARK: - Configuração

public enum TissotFeedbackConfig {
    nonisolated public static let endpoint = URL(string: "https://tissot-feedback-hub.rafaeltissot.workers.dev/api/reports")!
    nonisolated public static let dashboardURL = URL(string: "https://tissot-feedback-hub.rafaeltissot.workers.dev/dashboard")!
    /// Chave de ingestão compartilhada por todos os apps (barra spam; não é segredo forte).
    nonisolated public static let ingestKey = "197c8e5e53a2d9d55fa8fef21dbedf31265c350b59ca0e78"
    nonisolated public static let sdkVersion = "2.0"
    nonisolated static let maxLogs = 300
}

// MARK: - Tipos

nonisolated public enum TissotKind: String, Sendable { case report, error, crash, hang }
nonisolated public enum TissotCategory: String, Sendable, CaseIterable, Identifiable {
    case bug, sugestao, critica
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .bug: return "Problema"
        case .sugestao: return "Sugestão"
        case .critica: return "Opinião"
        }
    }
}
nonisolated public enum TissotSource: String, Sendable { case app, carplay, siri, auto }
nonisolated public enum TissotLogLevel: String, Sendable { case debug, info, warning, error }
nonisolated public enum TissotSendResult: Sendable { case sent, queued }

// MARK: - API pública

public enum TissotFeedback {
    nonisolated public static var dashboardURL: URL { TissotFeedbackConfig.dashboardURL }

    /// Chame uma vez no launch (ex.: `init()` do `App` ou `didFinishLaunching`).
    @MainActor public static func start() {
        guard !TissotStore.shared.markStarted() else { return }
        TissotStore.shared.beginSession()
        NSSetUncaughtExceptionHandler { exception in
            TissotCrashRecorder.record(exception: exception)
        }
        MXMetricManager.shared.add(TissotMetricSubscriber.shared)
        TissotNetwork.shared.start()
        TissotStore.shared.updateDeviceSnapshot(TissotDevice.collect())
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                TissotStore.shared.updateDeviceSnapshot(TissotDevice.collect())
                TissotStore.shared.persistLogs()
            }
        }
        log("APP_LAUNCH", ["version": TissotDevice.appVersion, "build": TissotDevice.appBuild])
        Task.detached(priority: .utility) { await TissotQueue.flush() }
    }

    /// Registra um evento no buffer local (enviado junto com qualquer relato/erro/crash).
    nonisolated public static func log(_ event: String, _ details: [String: Any] = [:], level: TissotLogLevel = .info) {
        TissotStore.shared.append(level: level, event: event, details: details)
    }

    /// Nome da tela atual (vai como contexto nos relatos e erros). Use `.tissotScreen("Nome")` em SwiftUI.
    nonisolated public static func setScreen(_ name: String) {
        TissotStore.shared.setScreen(name)
        log("SCREEN", ["name": name], level: .debug)
    }

    /// Erro não fatal: entra no log e é enviado ao painel automaticamente (no máximo 1x por sessão por assinatura).
    nonisolated public static func error(_ error: Error, context: String, _ details: [String: Any] = [:]) {
        // Cancelamentos normais de tarefas/rede/tradução (usuário voltou de tela, debounce, etc.) não são falhas.
        if error is CancellationError { return }
        if let urlError = error as? URLError, urlError.code == .cancelled { return }
        if let cocoaError = error as? CocoaError, cocoaError.code == .userCancelled { return }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError { return }
        if ns.code == 3072 || ns.code == -999 { return }

        var info = details
        info["domain"] = ns.domain
        info["code"] = ns.code
        info["description"] = ns.localizedDescription
        log("ERROR · \(context)", info, level: .error)
        let signature = "\(context)|\(ns.domain)|\(ns.code)"
        guard TissotStore.shared.shouldReport(signature: signature) else { return }
        let message = "\(context): \(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
        let crashInfo = String(describing: error)
        Task { @MainActor in
            _ = await send(kind: .error, category: nil, message: message, context: context, source: .auto, crashInfo: crashInfo)
        }
    }

    @MainActor private static var lastManualSendTime: Date?
    private static let manualCooldownSeconds: TimeInterval = 8

    /// Envia um relato. Retorna `.queued` se ficou na fila offline (será reenviado automaticamente).
    @discardableResult
    @MainActor public static func send(
        kind: TissotKind = .report,
        category: TissotCategory? = .bug,
        message: String,
        context: String? = nil,
        source: TissotSource = .app,
        contact: String? = nil,
        screenshot: UIImage? = nil,
        includeDiagnostics: Bool = true,
        crashInfo: String? = nil
    ) async -> TissotSendResult {
        if kind == .report {
            if let last = lastManualSendTime, Date().timeIntervalSince(last) < manualCooldownSeconds {
                log("MANUAL_REPORT_COOLDOWN", ["secondsRemaining": manualCooldownSeconds - Date().timeIntervalSince(last)], level: .warning)
                return .sent
            }
            lastManualSendTime = Date()
        }
        let device = TissotDevice.collect()
        TissotStore.shared.updateDeviceSnapshot(device)
        var payload = TissotPayload.base(device: includeDiagnostics ? device : ["model": device["model"] ?? "", "os": device["os"] ?? ""])
        payload["kind"] = kind.rawValue
        payload["category"] = category?.rawValue ?? kind.rawValue
        payload["message"] = message
        payload["source"] = source.rawValue
        payload["screenContext"] = context ?? TissotStore.shared.currentScreen
        if let contact, !contact.isEmpty { payload["contact"] = contact }
        if includeDiagnostics { payload["localLogs"] = TissotStore.shared.snapshot() }
        if let crashInfo { payload["crashInfo"] = crashInfo }
        if let screenshot, let data = TissotFeedback.jpeg(screenshot) { payload["screenshot"] = data.base64EncodedString() }
        log("FEEDBACK_SENT", ["kind": kind.rawValue, "source": source.rawValue], level: .debug)
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return .queued }
        return await TissotQueue.deliver(body)
    }

    /// Captura a janela principal (chame antes de apresentar a tela de relato).
    @MainActor public static func captureScreen() -> UIImage? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        guard let window else { return nil }
        return UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
    }

    @MainActor static func jpeg(_ image: UIImage) -> Data? {
        let maxWidth: CGFloat = 540
        let scale = min(1, maxWidth / max(image.size.width, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.55)
    }
}

public extension View {
    /// Marca a tela atual para contexto dos relatos/erros.
    func tissotScreen(_ name: String) -> some View {
        onAppear { TissotFeedback.setScreen(name) }
    }
}

// MARK: - Armazenamento (thread-safe)

nonisolated final class TissotStore: @unchecked Sendable {
    static let shared = TissotStore()

    private let lock = NSLock()
    private var entries: [[String: String]] = []
    private var previousSession: [[String: String]] = []
    private var reportedSignatures = Set<String>()
    private var started = false
    private var saveScheduled = false
    private var screen = ""
    private var device: [String: String] = [:]
    let sessionId = UUID().uuidString
    let sessionStart = Date()

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("TissotFeedback", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private var logsURL: URL { Self.directory.appendingPathComponent("logs.json") }

    let installId: String = {
        let key = "tissot_feedback_install_id"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func markStarted() -> Bool { locked { defer { started = true }; return started } }

    func beginSession() {
        let old = (try? Data(contentsOf: logsURL)).flatMap { try? JSONDecoder().decode([[String: String]].self, from: $0) } ?? []
        locked { previousSession = old }
    }

    var previousSessionLogs: [[String: String]] { locked { previousSession } }
    var currentScreen: String { locked { screen } }
    var deviceSnapshot: [String: String] { locked { device } }

    func setScreen(_ name: String) { locked { screen = name } }
    func updateDeviceSnapshot(_ snapshot: [String: String]) { locked { device = snapshot } }
    func shouldReport(signature: String) -> Bool { locked { reportedSignatures.insert(signature).inserted } }
    func snapshot() -> [[String: String]] { locked { entries } }

    func append(level: TissotLogLevel, event: String, details: [String: Any]) {
        var detailText = ""
        if !details.isEmpty {
            let safe = details.mapValues { JSONSerialization.isValidJSONObject(["v": $0]) ? $0 : String(describing: $0) }
            detailText = (try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? String(describing: details)
        }
        let entry = [
            "timestamp": Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)),
            "level": level.rawValue,
            "event": event,
            "details": String(detailText.prefix(2000))
        ]
        let shouldSchedule: Bool = locked {
            entries.append(entry)
            if entries.count > TissotFeedbackConfig.maxLogs { entries.removeFirst(entries.count - TissotFeedbackConfig.maxLogs) }
            defer { saveScheduled = true }
            return !saveScheduled
        }
        #if DEBUG
        print("[Tissot] \(level.rawValue.uppercased()) \(event) \(detailText)")
        #endif
        if level == .error {
            persistLogs()
        } else if shouldSchedule {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { TissotStore.shared.persistLogs() }
        }
    }

    func persistLogs() {
        let data: Data? = locked {
            saveScheduled = false
            return try? JSONEncoder().encode(entries)
        }
        try? data?.write(to: logsURL, options: .atomic)
    }
}

// MARK: - Payload, fila offline e envio

nonisolated enum TissotPayload {
    static func base(device: [String: String]) -> [String: Any] {
        [
            "appName": TissotDevice.appName,
            "appVersion": TissotDevice.appVersion,
            "appBuild": TissotDevice.appBuild,
            "bundleId": Bundle.main.bundleIdentifier ?? "",
            "environment": TissotDevice.environment,
            "installId": TissotStore.shared.installId,
            "sessionId": TissotStore.shared.sessionId,
            "deviceModel": device["model"] ?? "",
            "osVersion": device["os"] ?? "",
            "device": device
        ]
    }
}

nonisolated enum TissotQueue {
    private static var pendingDir: URL {
        let dir = TissotStore.directory.appendingPathComponent("pending", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Escrita síncrona (usada também dentro do handler de crash).
    static func enqueue(_ body: Data) {
        let url = pendingDir.appendingPathComponent("\(Date().timeIntervalSince1970)-\(UUID().uuidString.prefix(8)).json")
        try? body.write(to: url, options: .atomic)
        // ponytail: fila limitada a 30 itens (descarta os mais antigos); suficiente para apps pessoais.
        let files = (try? FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil))?.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        files.dropLast(30).forEach { try? FileManager.default.removeItem(at: $0) }
    }

    static func deliver(_ body: Data) async -> TissotSendResult {
        if await post(body) {
            Task.detached(priority: .utility) { await flush() }
            return .sent
        }
        enqueue(body)
        return .queued
    }

    static func flush() async {
        let files = (try? FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil))?.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        for file in files {
            guard let body = try? Data(contentsOf: file) else { try? FileManager.default.removeItem(at: file); continue }
            guard await post(body) else { return }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func post(_ body: Data) async -> Bool {
        var request = URLRequest(url: TissotFeedbackConfig.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(TissotFeedbackConfig.ingestKey, forHTTPHeaderField: "X-Tissot-Key")
        request.httpBody = body
        request.timeoutInterval = 15
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        // 4xx (exceto 408/429) = payload rejeitado; não adianta reenviar.
        if (400...499).contains(http.statusCode) && ![408, 429].contains(http.statusCode) { return true }
        return (200...299).contains(http.statusCode)
    }
}

// MARK: - Crashes (NSException + MetricKit)

nonisolated enum TissotCrashRecorder {
    static func record(exception: NSException) {
        TissotStore.shared.append(level: .error, event: "UNCAUGHT_EXCEPTION", details: ["name": exception.name.rawValue, "reason": exception.reason ?? ""])
        var payload = TissotPayload.base(device: TissotStore.shared.deviceSnapshot)
        payload["kind"] = TissotKind.crash.rawValue
        payload["category"] = TissotKind.crash.rawValue
        payload["source"] = TissotSource.auto.rawValue
        payload["message"] = "Crash: \(exception.name.rawValue) — \(exception.reason ?? "sem motivo")"
        payload["screenContext"] = TissotStore.shared.currentScreen
        payload["localLogs"] = TissotStore.shared.snapshot()
        payload["crashInfo"] = (["\(exception.name.rawValue): \(exception.reason ?? "")", ""] + exception.callStackSymbols).joined(separator: "\n")
        if let body = try? JSONSerialization.data(withJSONObject: payload) { TissotQueue.enqueue(body) }
    }
}

nonisolated final class TissotMetricSubscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = TissotMetricSubscriber()

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let previousLogs = TissotStore.shared.previousSessionLogs
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                var parts = ["Crash"]
                if let reason = crash.exceptionReason?.composedMessage { parts.append(reason) }
                if let signal = crash.signal { parts.append("sinal \(signal)") }
                if let type = crash.exceptionType { parts.append("exceção \(type)") }
                if let term = crash.terminationReason { parts.append(term) }
                enqueue(kind: .crash, message: parts.joined(separator: " · "), json: crash.jsonRepresentation(), version: crash.metaData.applicationBuildVersion, logs: previousLogs)
            }
            for hang in payload.hangDiagnostics ?? [] {
                enqueue(kind: .hang, message: "Travamento de \(hang.hangDuration.formatted()) na thread principal", json: hang.jsonRepresentation(), version: hang.metaData.applicationBuildVersion, logs: previousLogs)
            }
        }
        Task.detached(priority: .utility) { await TissotQueue.flush() }
    }

    private func enqueue(kind: TissotKind, message: String, json: Data, version: String, logs: [[String: String]]) {
        var payload = TissotPayload.base(device: TissotStore.shared.deviceSnapshot)
        payload["kind"] = kind.rawValue
        payload["category"] = kind.rawValue
        payload["source"] = TissotSource.auto.rawValue
        payload["message"] = message
        payload["appBuild"] = version
        payload["screenContext"] = "Sessão anterior (MetricKit)"
        payload["localLogs"] = logs
        payload["crashInfo"] = String(data: json, encoding: .utf8) ?? ""
        if let body = try? JSONSerialization.data(withJSONObject: payload) { TissotQueue.enqueue(body) }
    }
}

// MARK: - Dados do aparelho

nonisolated final class TissotNetwork: @unchecked Sendable {
    static let shared = TissotNetwork()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var status = "desconhecida"

    var current: String { lock.lock(); defer { lock.unlock() }; return status }

    func start() {
        monitor.pathUpdateHandler = { path in
            var text: String
            if path.status != .satisfied { text = "offline" }
            else if path.usesInterfaceType(.wifi) { text = "Wi-Fi" }
            else if path.usesInterfaceType(.cellular) { text = "celular" }
            else if path.usesInterfaceType(.wiredEthernet) { text = "cabo" }
            else { text = "outra" }
            if path.isConstrained { text += " (dados limitados)" }
            if path.isExpensive { text += " (cara)" }
            TissotNetwork.shared.set(text)
        }
        monitor.start(queue: DispatchQueue(label: "tissot.network"))
    }

    private func set(_ value: String) { lock.lock(); status = value; lock.unlock() }
}

nonisolated enum TissotDevice {
    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "App"
    }
    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    static var appBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }
    static var environment: String {
        #if DEBUG
        return "debug"
        #else
        return Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil ? "development" : "testflight/appstore"
        #endif
    }

    static var modelIdentifier: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .memory) }

    static var appMemory: String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? bytes(Int64(info.phys_footprint)) : "?"
    }

    static var diskFree: String {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map { bytes($0) } ?? "?"
    }

    @MainActor static func collect() -> [String: String] {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        defer { device.isBatteryMonitoringEnabled = false }
        let battery: String = {
            guard device.batteryLevel >= 0 else { return "?" }
            let state: String
            switch device.batteryState {
            case .charging: state = "carregando"
            case .full: state = "cheia"
            case .unplugged: state = "na bateria"
            default: state = "?"
            }
            return "\(Int(device.batteryLevel * 100))% · \(state)"
        }()
        let thermal: String = {
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: return "normal"
            case .fair: return "morno"
            case .serious: return "quente"
            case .critical: return "crítico"
            @unknown default: return "?"
            }
        }()
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            ?? scenes.compactMap { $0 as? UIWindowScene }.first
        let screen = windowScene.map { "\(Int($0.screen.bounds.width))×\(Int($0.screen.bounds.height)) @\(Int($0.screen.scale))x" } ?? "?"
        let style = windowScene?.traitCollection.userInterfaceStyle == .dark ? "escuro" : "claro"
        let carPlay = scenes.contains { $0.session.role.rawValue.contains("CarTemplate") || $0.session.role.rawValue.contains("CarPlay") }
        let elapsed = Int(Date().timeIntervalSince(TissotStore.shared.sessionStart))

        return [
            "model": modelIdentifier,
            "deviceFamily": device.model,
            "os": "\(device.systemName) \(device.systemVersion)",
            "appVersion": appVersion,
            "appBuild": appBuild,
            "environment": environment,
            "locale": Locale.current.identifier,
            "language": Locale.preferredLanguages.first ?? "?",
            "timezone": TimeZone.current.identifier,
            "network": TissotNetwork.shared.current,
            "battery": battery,
            "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled ? "sim" : "não",
            "thermalState": thermal,
            "diskFree": diskFree,
            "ramTotal": bytes(Int64(ProcessInfo.processInfo.physicalMemory)),
            "appMemory": appMemory,
            "screen": screen,
            "appearance": style,
            "textSize": UIApplication.shared.preferredContentSizeCategory.rawValue.replacingOccurrences(of: "UICTContentSizeCategory", with: ""),
            "voiceOver": UIAccessibility.isVoiceOverRunning ? "sim" : "não",
            "carPlay": carPlay ? "sim" : "não",
            "sessionDuration": "\(elapsed / 60)m \(elapsed % 60)s",
            "installId": TissotStore.shared.installId,
            "sessionId": TissotStore.shared.sessionId,
            "sdkVersion": TissotFeedbackConfig.sdkVersion
        ]
    }
}

// MARK: - Ditado por voz (usado na tela de relato e no CarPlay)

@MainActor
public final class TissotVoiceRecorder: ObservableObject {
    @Published public private(set) var transcript = ""
    @Published public private(set) var isRecording = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "pt-BR"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    public init() {}

    public static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    public func start() throws {
        stopEngine()
        transcript = ""
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "TissotVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: "Reconhecimento de voz indisponível"])
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.request = request

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0), block: Self.tapBlock(request))
        engine.prepare()
        try engine.start()
        task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler { [weak self] text in
            self?.transcript = text
        })
        isRecording = true
        TissotFeedback.log("VOICE_REPORT_STARTED", level: .debug)
    }

    /// Encerra a captação, aguarda o resultado final e devolve o texto.
    public func finish() async -> String {
        request?.endAudio()
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        try? await Task.sleep(nanoseconds: 700_000_000)
        stopEngine()
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func cancel() { stopEngine() }

    private func stopEngine() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // Closures criadas fora do MainActor: são chamadas em threads de áudio/fala.
    nonisolated private static func tapBlock(_ request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in request.append(buffer) }
    }

    nonisolated private static func resultHandler(_ onText: @escaping @MainActor (String) -> Void) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, _ in
            guard let text = result?.bestTranscription.formattedString else { return }
            Task { @MainActor in onText(text) }
        }
    }
}

// MARK: - Tela de relato (SwiftUI)

public struct TissotFeedbackSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var voice = TissotVoiceRecorder()
    @AppStorage("tissot_feedback_contact") private var contact = ""

    private let context: String?
    private let category: TissotCategory
    @State private var message = ""
    @State private var screenshot: UIImage?
    @State private var phase: Phase = .editing
    @FocusState private var focused: Bool

    private enum Phase: Equatable { case editing, sending, sent, queued }

    /// - Parameters:
    ///   - context: tela/situação (padrão: última tela marcada com `.tissotScreen`)
    ///   - category: mantido para compatibilidade (padrão: `.bug`)
    public init(context: String? = nil, category: TissotCategory = .bug) {
        self.context = context
        self.category = category
        _screenshot = State(initialValue: TissotFeedback.captureScreen())
    }

    private var trimmed: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    ZStack(alignment: .topLeading) {
                        if message.isEmpty && !voice.isRecording {
                            Text("Descreva o que aconteceu ou a sua sugestão...")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $message)
                            .frame(minHeight: 150)
                            .focused($focused)
                    }
                    Button(action: toggleVoice) {
                        Label(voice.isRecording ? "Parar ditado" : "Ditar por voz",
                              systemImage: voice.isRecording ? "stop.circle.fill" : "mic.fill")
                            .foregroundStyle(voice.isRecording ? .red : .accentColor)
                    }
                    .frame(minHeight: 44)
                } header: {
                    Text("Como podemos ajudar?")
                }

                Section {
                    Button(action: submit) {
                        HStack {
                            Spacer()
                            switch phase {
                            case .sending: ProgressView()
                            case .sent: Label("Enviado. Obrigado!", systemImage: "checkmark.circle.fill")
                            case .queued: Label("Sem conexão — enviaremos depois", systemImage: "tray.and.arrow.up.fill")
                            case .editing: Text("Enviar relato").bold()
                            }
                            Spacer()
                        }
                        .frame(minHeight: 44)
                    }
                    .disabled(trimmed.isEmpty || phase != .editing)
                }
            }
            .navigationTitle("Relatar ao desenvolvedor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar") { voice.cancel(); dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("OK") { focused = false }
                }
            }
            .onChange(of: voice.transcript) { _, text in
                if voice.isRecording, !text.isEmpty { message = text }
            }
            .onDisappear { voice.cancel() }
        }
    }

    private func toggleVoice() {
        if voice.isRecording {
            Task { let text = await voice.finish(); if !text.isEmpty { message = text } }
            return
        }
        focused = false
        Task {
            guard await TissotVoiceRecorder.requestPermissions() else {
                message += message.isEmpty ? "" : "\n"
                TissotFeedback.log("VOICE_PERMISSION_DENIED", level: .warning)
                return
            }
            try? voice.start()
        }
    }

    private func submit() {
        focused = false
        phase = .sending
        Task {
            if voice.isRecording { _ = await voice.finish() }
            let result = await TissotFeedback.send(
                kind: .report,
                category: category,
                message: trimmed,
                context: context,
                source: .app,
                contact: contact.trimmingCharacters(in: .whitespaces),
                screenshot: screenshot,
                includeDiagnostics: true
            )
            UINotificationFeedbackGenerator().notificationOccurred(result == .sent ? .success : .warning)
            phase = result == .sent ? .sent : .queued
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            dismiss()
        }
    }
}

// MARK: - Siri / Atalhos (funciona no CarPlay, mãos livres)

/// Adicione ao AppShortcutsProvider do app:
/// `AppShortcut(intent: TissotReportProblemIntent(), phrases: ["Relatar problema no \(.applicationName)"], shortTitle: "Relatar problema", systemImageName: "exclamationmark.bubble")`
public struct TissotReportProblemIntent: AppIntent {
    public static let title: LocalizedStringResource = "Relatar problema"
    public static let description = IntentDescription("Envia ao desenvolvedor um relato falado, com os logs técnicos do app.")
    public static let openAppWhenRun: Bool = false

    @Parameter(title: "Problema", requestValueDialog: IntentDialog("Qual é o problema?"))
    public var mensagem: String

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await TissotFeedback.send(kind: .report, category: .bug, message: mensagem, context: "Siri", source: .siri)
        return .result(dialog: IntentDialog(stringLiteral: result == .sent
            ? "Relato enviado. Obrigado!"
            : "Sem conexão agora. Guardei o relato e envio assim que possível."))
    }
}

// MARK: - CarPlay

#if canImport(CarPlay)
@MainActor
public enum TissotFeedbackCarPlay {
    private static let recorder = TissotVoiceRecorder()

    /// Item de lista "Relatar problema" (ex.: última seção da aba principal do CarPlay).
    public static func reportListItem(context: String = "CarPlay", interfaceController: @escaping () -> CPInterfaceController?) -> CPListItem {
        let item = CPListItem(text: "Relatar problema", detailText: "Fale o problema; enviamos com os logs", image: UIImage(systemName: "exclamationmark.bubble.fill"))
        item.handler = { _, completion in
            MainActor.assumeIsolated {
                if let controller = interfaceController() { startVoiceReport(on: controller, context: context) }
            }
            completion()
        }
        return item
    }

    /// Inicia a captação por voz no carro e envia ao tocar em "Enviar".
    public static func startVoiceReport(on controller: CPInterfaceController, context: String = "CarPlay") {
        Task {
            guard await TissotVoiceRecorder.requestPermissions() else {
                alert(controller, "Permita Microfone e Reconhecimento de Fala no iPhone, ou diga: \"E aí Siri, relatar problema no \(TissotDevice.appName)\".")
                return
            }
            do { try recorder.start() } catch {
                alert(controller, "Não foi possível usar o microfone agora. Diga: \"E aí Siri, relatar problema no \(TissotDevice.appName)\".")
                return
            }
            let send = CPAlertAction(title: "Enviar", style: .default) { _ in
                MainActor.assumeIsolated { finish(controller, context: context, send: true) }
            }
            let cancel = CPAlertAction(title: "Cancelar", style: .cancel) { _ in
                MainActor.assumeIsolated { finish(controller, context: context, send: false) }
            }
            present(controller, CPAlertTemplate(titleVariants: ["🎙️ Ouvindo… fale o problema e toque em Enviar", "🎙️ Fale o problema"], actions: [send, cancel]))
        }
    }

    private static func finish(_ controller: CPInterfaceController, context: String, send: Bool) {
        Task {
            guard send else { recorder.cancel(); controller.dismissTemplate(animated: true, completion: nil); return }
            let text = await recorder.finish()
            guard !text.isEmpty else { alert(controller, "Não consegui entender. Tente de novo."); return }
            let result = await TissotFeedback.send(kind: .report, category: .bug, message: text, context: context, source: .carplay)
            alert(controller, result == .sent ? "✅ Relato enviado. Obrigado!" : "📥 Sem conexão: relato guardado, enviaremos depois.")
        }
    }

    private static func alert(_ controller: CPInterfaceController, _ text: String) {
        let ok = CPAlertAction(title: "OK", style: .default) { _ in
            MainActor.assumeIsolated { controller.dismissTemplate(animated: true, completion: nil) }
        }
        present(controller, CPAlertTemplate(titleVariants: [text], actions: [ok]))
    }

    private static func present(_ controller: CPInterfaceController, _ template: CPTemplate) {
        if controller.presentedTemplate != nil {
            controller.dismissTemplate(animated: false) { _, _ in
                MainActor.assumeIsolated { controller.presentTemplate(template, animated: true, completion: nil) }
            }
        } else {
            controller.presentTemplate(template, animated: true, completion: nil)
        }
    }
}
#endif

// MARK: - Retrocompatibilidade com v1 (GarimpAI)
public typealias TissotFeedbackCategory = TissotCategory

@MainActor
public final class TissotFeedbackSDK: ObservableObject {
    public static let shared = TissotFeedbackSDK()
    public static var dashboardURL: URL { TissotFeedback.dashboardURL }
    public var appName: String { TissotDevice.appName }

    public func recordLog(event: String, details: [String: Any] = [:]) {
        TissotFeedback.log(event, details)
    }

    public func sendReport(
        category: TissotFeedbackCategory,
        message: String,
        screenContext: String = "",
        includeLocalLogs: Bool = true
    ) async -> Bool {
        let res = await TissotFeedback.send(
            kind: .report,
            category: category,
            message: message,
            context: screenContext,
            source: .app,
            includeDiagnostics: includeLocalLogs
        )
        return res == .sent || res == .queued
    }
}

public extension TissotFeedbackSheet {
    init(initialContext: String = "", initialCategory: TissotCategory = .bug) {
        self.init(context: initialContext.isEmpty ? nil : initialContext, category: initialCategory)
    }
}
