import SwiftUI

// MARK: - Villa de ejemplo y alta de agentes
//
// La primera vez que se abre, la app crea su carpeta de datos con una villa de ejemplo (agentes ficticios).
// Desde «Agentes de la villa» (barra de herramientas) se agregan o quitan agentes propios; se guardan en
// ~/Library/Application Support/Villa de Agentes/agentes.json.

enum VillaDemo {
    /// Crea la carpeta de datos con la villa de ejemplo si todavía no existe.
    static func sembrar() {
        let fm = FileManager.default, base = Almacen.carpetaLocal
        for sub in ["", "/resultados", "/trabajo", "/agentes"] { try? fm.createDirectory(atPath: base + sub, withIntermediateDirectories: true) }
        if !fm.fileExists(atPath: base + "/agentes.json") { try? agentes.write(toFile: base + "/agentes.json", atomically: true, encoding: .utf8) }
        if !fm.fileExists(atPath: base + "/estado.json") { try? #"{"generado": null, "agentes": {}}"#.write(toFile: base + "/estado.json", atomically: true, encoding: .utf8) }
        if !fm.fileExists(atPath: base + "/trabajo/museo.json") { try? museo.write(toFile: base + "/trabajo/museo.json", atomically: true, encoding: .utf8) }
    }

    static let museo = #"""
    {"piezas": [
     {"id": "viejo1", "nombre": "Agente de ejemplo retirado", "fecha": "Retirado el 1 de enero.", "que_hacia": "Revisaba una carpeta cada hora.", "por_que": "Se reemplazó por uno que vigila cambios al instante.", "reemplazo": "Lo reemplaza el Archivador."},
     {"id": "viejo2", "nombre": "Proceso antiguo de ejemplo", "fecha": "Apagado el 15 de marzo.", "que_hacia": "Sincronizaba notas con un servicio que ya no existe.", "por_que": "El servicio cerró.", "reemplazo": "Lo reemplaza el Indexador de notas."}
    ]}
    """#

    /// Barrios (los ids son fijos: cada uno tiene su lugar y su edificio en la villa) y agentes de ejemplo.
    static let agentes = #"""
    {
     "zonas": {
      "urg": {"name": "Hospital", "roof": "#8c2f33", "wall": "#e9e2da", "kind": "hospital"},
      "cer": {"name": "Biblioteca del conocimiento", "roof": "#3d3f7a", "wall": "#d9d4c4", "kind": "library"},
      "nube": {"name": "La nube", "roof": "#5b7fb8", "wall": "#f4f7fb", "kind": "dome"},
      "ios": {"name": "Taller de apps", "roof": "#2e6b66", "wall": "#cfd8d6", "kind": "workshop"},
      "mac": {"name": "Bodega del Mac", "roof": "#7a5a2c", "wall": "#d8c9a8", "kind": "barn"},
      "sede": {"name": "Sede de gobierno", "roof": "#b8892b", "wall": "#efe5cf", "kind": "sede"},
      "mall": {"name": "Centro comercial", "roof": "#b0306a", "wall": "#f3ece6", "kind": "mall"},
      "puerto": {"name": "Puerto", "roof": "#1f5f8b", "wall": "#e8eef2", "kind": "port"},
      "aeropuerto": {"name": "Aeropuerto", "roof": "#1f6fb2", "wall": "#e9edf1", "kind": "airport"},
      "trade": {"name": "Villa Trade Center", "roof": "#1a5276", "wall": "#e3e8ec", "kind": "trade"},
      "banco": {"name": "Banco Central", "roof": "#7d6608", "wall": "#efe6d2", "kind": "bank"},
      "casino": {"name": "Gran Casino", "roof": "#c0392b", "wall": "#3b1f4a", "kind": "casino"},
      "museo": {"name": "Museo de la Villa", "roof": "#8c6239", "wall": "#f1ead9", "kind": "museum"},
      "uni": {"name": "Universidad", "roof": "#5b3a29", "wall": "#b5654a", "kind": "university"},
      "ciencia": {"name": "Centro científico", "roof": "#117a65", "wall": "#e3e8ec", "kind": "science"},
      "fach": {"name": "Base Aérea", "roof": "#1a5276", "wall": "#dfe4e8", "kind": "airbase"},
      "armada": {"name": "Base Naval", "roof": "#1a3d5c", "wall": "#e8eef2", "kind": "navalbase"},
      "ejercito": {"name": "Regimiento", "roof": "#4b5a33", "wall": "#7d8a5c", "kind": "army"},
      "defensa": {"name": "Ministerio de Defensa", "roof": "#3d4630", "wall": "#e9e4d6", "kind": "defense"},
      "comisaria": {"name": "Comisaría", "roof": "#1e5631", "wall": "#f3f1ea", "kind": "police"},
      "gobmar": {"name": "Gobernación Marítima", "roof": "#1a3d5c", "wall": "#f2f4f6", "kind": "maritime"}
     },
     "agentes": [
      {"id": "monitor", "zone": "urg", "name": "Monitor de servicios", "status": "ok", "does": "Ejemplo: comprueba cada 15 minutos que tus servicios web respondan.", "sched": "Cada 15 min"},
      {"id": "agenda", "zone": "urg", "name": "Vigilante de agenda", "status": "ok", "does": "Ejemplo: avisa de los eventos del día siguiente.", "sched": "Cada mañana"},
      {"id": "notas", "zone": "cer", "name": "Indexador de notas", "status": "ok", "does": "Ejemplo: mantiene un índice de búsqueda de tus notas.", "sched": "Cada hora"},
      {"id": "bitacora", "zone": "cer", "name": "Bitácora de proyectos", "status": "ok", "does": "Ejemplo: resume cada día lo que cambió en tus proyectos.", "sched": "Cada noche"},
      {"id": "tarea", "zone": "nube", "name": "Tarea en la nube", "status": "ok", "does": "Ejemplo: una tarea programada que corre en un servidor remoto.", "sched": "3 veces al día"},
      {"id": "compilador", "zone": "ios", "name": "Compilador nocturno", "status": "ok", "does": "Ejemplo: compila tus apps cada noche y avisa si algo falla.", "sched": "Cada noche"},
      {"id": "actualizador", "zone": "ios", "name": "Actualizador de apps", "status": "ok", "does": "Ejemplo: reinstala tus apps cuando cambia su código.", "sched": "Al cambiar"},
      {"id": "resp", "zone": "mac", "name": "Respaldos", "status": "ok", "does": "Ejemplo: respalda tus carpetas importantes cada noche.", "sched": "Cada noche"},
      {"id": "opt", "zone": "mac", "name": "Optimizador del Mac", "status": "ok", "does": "Ejemplo: revisa memoria, disco y servicios de inicio.", "sched": "Cada hora"},
      {"id": "salud", "zone": "mac", "name": "Salud del Mac", "status": "ok", "does": "Ejemplo: vigila espacio libre, batería y temperatura.", "sched": "2 veces al día"},
      {"id": "red", "zone": "mac", "name": "Vigilante de red", "status": "ok", "does": "Ejemplo: relanza lo que depende de internet cuando vuelve la conexión.", "sched": "Al volver la red"},
      {"id": "revisor", "zone": "sede", "name": "Revisor de agentes", "status": "ok", "does": "Ejemplo: revisa a todos los agentes y repara lo seguro.", "sched": "Cada 30 min"},
      {"id": "seg", "zone": "sede", "name": "Vigilante de seguridad", "status": "ok", "does": "Ejemplo: comprueba, solo lectura, que las protecciones del Mac estén activas.", "sched": "Cada 15 min"},
      {"id": "mem", "zone": "puerto", "name": "Proveedor de memoria", "status": "ok", "does": "Ejemplo: mantiene viva la memoria de tus asistentes.", "sched": "Cada hora"},
      {"id": "asc", "zone": "puerto", "name": "Vigía de la App Store", "status": "ok", "does": "Ejemplo: mira si tus apps ya están publicadas.", "sched": "Cada 3 h"},
      {"id": "tok", "zone": "mall", "name": "Contador de tokens", "status": "ok", "does": "Ejemplo: cuenta los tokens que gastan tus asistentes de IA.", "sched": "2 veces al día"},
      {"id": "cajero", "zone": "mall", "name": "Cajero", "status": "ok", "does": "Ejemplo: lleva la cuenta de tus suscripciones de pago.", "sched": "Cada mañana"}
     ]
    }
    """#
}

extension Almacen {
    private var rutaDefiniciones: URL { URL(fileURLWithPath: Almacen.carpetaLocal).appendingPathComponent("agentes.json") }

    private func leerDefiniciones() -> Definiciones? {
        (try? Data(contentsOf: rutaDefiniciones)).flatMap { try? JSONDecoder().decode(Definiciones.self, from: $0) }
    }

    private func guardar(_ d: Definiciones) throws {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(d).write(to: rutaDefiniciones, options: .atomic)
    }

    /// Agrega un agente nuevo a la villa (su oficina aparece en el barrio elegido).
    func agregarAgente(nombre: String, zona: String, hace: String, horario: String, servicio: String) async -> String? {
        guard var d = leerDefiniciones() else { return "No se pudo leer agentes.json." }
        let limpio = nombre.trimmingCharacters(in: .whitespaces)
        guard !limpio.isEmpty else { return "Falta el nombre." }
        var base = limpio.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        while base.contains("--") { base = base.replacingOccurrences(of: "--", with: "-") }
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if base.isEmpty { base = "agente" }
        var id = base, k = 2
        while d.agentes.contains(where: { $0.id == id }) { id = "\(base)-\(k)"; k += 1 }
        let srv = servicio.trimmingCharacters(in: .whitespaces)
        d.agentes.append(AgenteDef(id: id, zone: zona, name: limpio, plist: srv.isEmpty ? nil : srv, status: "ok",
                                   does: hace.isEmpty ? "Agente nuevo." : hace, sched: horario.isEmpty ? nil : horario))
        do { try guardar(d) } catch { return "No se pudo guardar: \(error.localizedDescription)" }
        await recargar()
        return nil
    }

    func quitarAgente(_ id: String) async {
        guard var d = leerDefiniciones() else { return }
        d.agentes.removeAll { $0.id == id }
        try? guardar(d)
        if seleccion == id { seleccion = nil }
        await recargar()
    }
}

/// Hoja «Agentes de la villa»: alta de un agente nuevo y lista para quitar los existentes.
struct VistaAgregarAgente: View {
    @EnvironmentObject var almacen: Almacen
    @Environment(\.dismiss) private var cerrar
    @State private var nombre = ""
    @State private var zona = "mac"
    @State private var hace = ""
    @State private var horario = ""
    @State private var servicio = ""
    @State private var aviso: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agentes de la villa").font(.title2.bold())
            Form {
                Section("Agregar un agente") {
                    TextField("Nombre", text: $nombre)
                    Picker("Barrio", selection: $zona) {
                        ForEach(almacen.zonas.filter { $0.key != "sede" }.sorted { $0.value.name < $1.value.name }, id: \.key) { Text($0.value.name).tag($0.key) }
                        Text("Sede de gobierno").tag("sede")
                    }
                    TextField("Qué hace", text: $hace, axis: .vertical).lineLimit(2...4)
                    TextField("Horario (opcional, ej. «Cada hora»)", text: $horario)
                    TextField("Servicio de launchd (opcional, ej. com.tu.agente)", text: $servicio)
                        .help("Si lo indicas, «Ejecutar ahora» lo lanza con launchctl. Su estado puede escribirse en estado.json o en resultados/<id>.json.")
                    HStack {
                        Spacer()
                        Button("Agregar a la villa") {
                            Task {
                                aviso = await almacen.agregarAgente(nombre: nombre, zona: zona, hace: hace, horario: horario, servicio: servicio)
                                    ?? "Listo: \(nombre) ya tiene su oficina en la villa."
                                if aviso?.hasPrefix("Listo") == true { nombre = ""; hace = ""; horario = ""; servicio = "" }
                            }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(nombre.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section("Agentes actuales (\(almacen.agentes.count))") {
                    ForEach(almacen.agentes) { a in
                        HStack {
                            Text(a.nombre)
                            Text(almacen.zonas[a.zona]?.name ?? a.zona).foregroundStyle(.secondary).font(.caption)
                            Spacer()
                            Button(role: .destructive) { Task { await almacen.quitarAgente(a.id) } } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help("Quitar \(a.nombre) de la villa (no toca su programa)")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                if let a = aviso { Text(a).font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("Abrir carpeta de datos") { NSWorkspace.shared.open(URL(fileURLWithPath: Almacen.carpetaLocal)) }
                Button("Cerrar") { cerrar() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 560, height: 620)
    }
}
