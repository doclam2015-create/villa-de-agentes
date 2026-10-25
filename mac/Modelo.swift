import Foundation
import SwiftUI
import UserNotifications

// MARK: - Datos

struct Zona: Codable, Hashable {
    var name: String
    var roof: String
    var wall: String
    var kind: String
}

struct AgenteDef: Codable, Identifiable, Hashable {
    var id: String
    var zone: String
    var name: String
    var plist: String?
    var status: String
    var does: String
    var sched: String?
    var last: String?
    var next: String?
    var proc: [String]?
    var files: [String]?
    var log: [[String]]?
    var fails: [String]?
    var fixes: [String]?
    var pend: [String]?
    var unknown: [String]?
    var verify: String?
}

struct Definiciones: Codable {
    var zonas: [String: Zona]
    var agentes: [AgenteDef]
}

struct Vivo: Codable, Hashable {
    var last: String?
    var next: String?
    var status: String?
    var nota: String?
    var solucion: String?
    var resultado: String?
}

struct Resultado: Codable, Hashable {
    var t: Double?
    var status: String?
    var resumen: String?
    var detalle: [String]?
    var serie: [String: Double]?
}

struct EstadoVilla: Codable {
    var generado: Double?
    var texto: String?
    var agentes: [String: Vivo]
}

/// Lo que muestra la app: definición + estado en vivo.
struct Agente: Identifiable, Hashable {
    var def: AgenteDef
    var vivo: Vivo?
    var indice: Int
    var id: String { def.id }
    var nombre: String { def.name }
    var zona: String { def.zone }
    var estado: String { vivo?.status ?? def.status }
    var ultima: String { vivo?.last ?? def.last ?? "—" }
    var proxima: String { vivo?.next ?? def.next ?? "—" }
    var resultado: String { vivo?.resultado ?? vivo?.nota ?? "" }
    var etiquetaEstado: String { Agente.etiqueta(estado) }
    var enAtencion: Bool { estado == "warn" || estado == "crit" }
    var color: Color { Agente.color(estado) }
    var servicio: String? {
        if def.plist?.hasPrefix("Tarea en la nube") == true { return "nube" }      // rutina de Claude: se lanza en la nube
        guard let p = def.plist?.split(separator: " ").first, p.hasPrefix("com.") else { return nil }
        return String(p)
    }
    var registro: String? {
        guard let f = def.files?.first(where: { $0.contains("Registro") }) else { return nil }
        // «Registro: ruta», «Registro real: ruta»…: la ruta es lo que sigue a los dos puntos
        let r = f.range(of: ":").map { String(f[$0.upperBound...]) }?.trimmingCharacters(in: .whitespaces) ?? ""
        let ruta = r.components(separatedBy: " y ").first ?? r
        return (ruta as NSString).expandingTildeInPath
    }

    static func etiqueta(_ s: String) -> String {
        ["ok": "Operativo", "warn": "Atención", "crit": "Crítico", "fixed": "Reparado", "off": "Apagado"][s] ?? s
    }
    static func color(_ s: String) -> Color {
        switch s {
        case "ok": return .green
        case "warn": return .orange
        case "crit": return .red
        case "fixed": return .teal
        default: return .gray
        }
    }
}

// MARK: - Almacén

@MainActor
final class Almacen: ObservableObject {
    nonisolated static let carpetaLocal = (NSHomeDirectory() + "/Library/Application Support/Villa de Agentes")
    @Published var zonas: [String: Zona] = [:]
    @Published var agentes: [Agente] = []
    @Published var resultados: [String: Resultado] = [:]
    @Published var serieTokens: [(fecha: String, total: Double)] = []
    @Published var generado: Date?
    @Published var error: String?
    @Published var seleccion: String?
    @Published var actualizando = false
    @Published var aviso: String?

    @AppStorage("servidor") var servidor = ""
    @AppStorage("notificar") var notificar = true

    var esLocal: Bool { FileManager.default.fileExists(atPath: Almacen.carpetaLocal + "/agentes.json") }
    var fuente: String { esLocal ? "Este Mac" : "Remoto · \(servidor)" }

    private var temporizador: Timer?
    private var vigia: DispatchSourceFileSystemObject?
    private var previos: [String: String] = [:]

    init() {
        VillaDemo.sembrar()          // primera vez: crea la carpeta de datos con una villa de ejemplo
        Task { await recargar() }
        temporizador = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.recargar() }
        }
        vigilarArchivo()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    var seleccionado: Agente? { agentes.first { $0.id == seleccion } }
    var conProblemas: [Agente] { agentes.filter { $0.estado == "warn" || $0.estado == "crit" } }

    /// Recarga si cambia estado.json (lo escribe estado.py cada 15 min o al pulsar «Revisar ahora»).
    private func vigilarArchivo() {
        guard esLocal else { return }
        let fd = open(Almacen.carpetaLocal + "/estado.json", O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            Task { @MainActor in
                await self?.recargar()
                if src.data.contains(.rename) || src.data.contains(.delete) { self?.vigia?.cancel(); self?.vigilarArchivo() }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        vigia = src
    }

    func recargar() async {
        actualizando = true
        defer { actualizando = false }
        do {
            let (defs, estado, res) = esLocal ? try leerLocal() : try await leerRemoto()
            zonas = defs.zonas
            agentes = defs.agentes.enumerated().map { Agente(def: $1, vivo: estado.agentes[$1.id], indice: $0) }
            resultados = res
            generado = estado.generado.map { Date(timeIntervalSince1970: $0) }
            error = nil
            avisarCambios()
            leerSerieTokens()
        } catch {
            self.error = "No se pudo leer la villa (\(fuente)): \(error.localizedDescription)"
        }
    }

    private func leerLocal() throws -> (Definiciones, EstadoVilla, [String: Resultado]) {
        let c = URL(fileURLWithPath: Almacen.carpetaLocal)
        let d = try JSONDecoder().decode(Definiciones.self, from: Data(contentsOf: c.appendingPathComponent("agentes.json")))
        let e = (try? JSONDecoder().decode(EstadoVilla.self, from: Data(contentsOf: c.appendingPathComponent("estado.json")))) ?? EstadoVilla(generado: nil, texto: nil, agentes: [:])
        var r: [String: Resultado] = [:]
        let rc = c.appendingPathComponent("resultados")
        for f in (try? FileManager.default.contentsOfDirectory(atPath: rc.path)) ?? [] where f.hasSuffix(".json") {
            if let x = try? JSONDecoder().decode(Resultado.self, from: Data(contentsOf: rc.appendingPathComponent(f))) {
                r[String(f.dropLast(5))] = x
            }
        }
        return (d, e, r)
    }

    private struct EstadoRemoto: Codable {
        var generado: Double?
        var texto: String?
        var agentes: [String: Vivo]
        var resultados: [String: Resultado]?
    }

    private func leerRemoto() async throws -> (Definiciones, EstadoVilla, [String: Resultado]) {
        guard let base = URL(string: servidor) else { throw URLError(.badURL) }
        let (d, _) = try await URLSession.shared.data(from: base.appendingPathComponent("agentes.json"))
        let (e, _) = try await URLSession.shared.data(from: base.appendingPathComponent("estado.json"))
        let er = try JSONDecoder().decode(EstadoRemoto.self, from: e)
        return (try JSONDecoder().decode(Definiciones.self, from: d),
                EstadoVilla(generado: er.generado, texto: er.texto, agentes: er.agentes), er.resultados ?? [:])
    }

    private func leerSerieTokens() {
        let serie = resultados["tok"]?.serie ?? [:]
        serieTokens = serie.sorted { $0.key < $1.key }.map { (String($0.key.suffix(5)), $0.value / 1_000_000) }
    }

    private func avisarCambios() {
        defer { previos = Dictionary(uniqueKeysWithValues: agentes.map { ($0.id, $0.estado) }) }
        guard !previos.isEmpty, notificar else { return }
        for a in agentes where previos[a.id] != a.estado && (a.estado == "warn" || a.estado == "crit" || previos[a.id] == "warn") {
            let c = UNMutableNotificationContent()
            c.title = "\(a.nombre): \(a.etiquetaEstado)"
            c.body = a.resultado.isEmpty ? "Cambió de estado en la villa." : a.resultado
            c.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: a.id + "\(Date().timeIntervalSince1970)", content: c, trigger: nil))
        }
    }

    // MARK: Acciones

    func ejecutar(_ a: Agente) async {
        guard let s = a.servicio else { aviso = "\(a.nombre) no tiene un servicio que se pueda ejecutar."; return }
        if s == "nube" && esLocal {          // rutina en la nube: la lanza ahora (o abre «Run now» si falta su token)
            let id = a.id
            let r = await Task.detached { Proceso.correr("/bin/zsh", [Almacen.carpetaLocal + "/agentes/ejecutar_nube.sh", id]) }.value
            aviso = r.salida.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? "Listo."
        } else if esLocal {
            var r = Proceso.correr("/bin/launchctl", ["kickstart", "gui/\(getuid())/\(s)"])
            var instalado = false
            if r.codigo != 0 {      // no estaba cargado: lo instala (si la villa trae su plist) y lo carga, luego lo ejecuta
                let destino = NSHomeDirectory() + "/Library/LaunchAgents/\(s).plist", propio = Almacen.carpetaLocal + "/agentes/\(s).plist"
                let fm = FileManager.default
                if !fm.fileExists(atPath: destino) && fm.fileExists(atPath: propio) {
                    try? fm.createDirectory(atPath: NSHomeDirectory() + "/Library/Logs/agentes", withIntermediateDirectories: true)
                    try? fm.copyItem(atPath: propio, toPath: destino)
                }
                _ = Proceso.correr("/bin/launchctl", ["bootout", "gui/\(getuid())/\(s)"])
                if Proceso.correr("/bin/launchctl", ["bootstrap", "gui/\(getuid())", destino]).codigo == 0 {
                    instalado = true
                    r = Proceso.correr("/bin/launchctl", ["kickstart", "gui/\(getuid())/\(s)"])
                }
            }
            aviso = r.codigo == 0 ? "\(a.nombre) se está ejecutando" + (instalado ? " (no estaba cargado: lo cargué)." : ".") : "No se pudo ejecutar \(a.nombre): \(r.salida)"
        } else {
            guard let base = URL(string: servidor) else { return }
            var req = URLRequest(url: base.appendingPathComponent("ejecutar"))
            req.httpMethod = "POST"
            req.setValue("1", forHTTPHeaderField: "X-Villa-App")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["id": a.id])
            let ok = ((try? await URLSession.shared.data(for: req))?.1 as? HTTPURLResponse)?.statusCode == 200
            aviso = ok ? "\(a.nombre) se está ejecutando en el Mac principal." : "No se pudo ejecutar \(a.nombre) en el Mac principal."
        }
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        await revisar()
    }

    func revisar() async {
        if esLocal {
            _ = await Task.detached { Proceso.correr("/usr/local/bin/python3", [Almacen.carpetaLocal + "/estado.py"]) }.value
        } else if let base = URL(string: servidor) {
            var req = URLRequest(url: base.appendingPathComponent("revisar"))
            req.httpMethod = "POST"
            req.setValue(servidor, forHTTPHeaderField: "Origin")
            _ = try? await URLSession.shared.data(for: req)
        }
        await recargar()
    }

    func registro(_ a: Agente) async -> String {
        if esLocal {
            guard let r = a.registro, let h = FileHandle(forReadingAtPath: r) else { return "Este agente no tiene un registro legible." }
            let tam = (try? h.seekToEnd()) ?? 0
            try? h.seek(toOffset: tam > 8000 ? tam - 8000 : 0)
            return String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        }
        guard let base = URL(string: servidor), var c = URLComponents(url: base.appendingPathComponent("registro"), resolvingAgainstBaseURL: false) else { return "" }
        c.queryItems = [URLQueryItem(name: "id", value: a.id)]
        guard let u = c.url, let (d, _) = try? await URLSession.shared.data(from: u),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return "No se pudo leer el registro remoto." }
        return j["texto"] as? String ?? ""
    }
}

enum Proceso {
    @discardableResult
    nonisolated static func correr(_ exe: String, _ args: [String]) -> (codigo: Int32, salida: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let tubo = Pipe()
        p.standardOutput = tubo
        p.standardError = tubo
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let d = tubo.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

extension Color {
    init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}
