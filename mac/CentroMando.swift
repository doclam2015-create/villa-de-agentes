import SwiftUI
import AppKit
import Charts

// MARK: - Recursos reales del Mac (lectura, sin cambiar nada)

struct RecursosMac {
    var discoLibreGB: Double = 0, discoLibrePct: Double = 0
    var memoriaLibrePct: Double?, swapGB: Double?, bateriaPct: Double?
    var cargaCPU: Double = 0                 // 0–1: carga del último minuto / núcleos
    var termico = "Normal"

    @MainActor static func leer(_ almacen: Almacen) -> RecursosMac {
        var r = RecursosMac()
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
           let libre = v.volumeAvailableCapacityForImportantUsage, let total = v.volumeTotalCapacity, total > 0 {
            r.discoLibreGB = Double(libre) / 1e9; r.discoLibrePct = Double(libre) / Double(total)
        }
        var carga = [Double](repeating: 0, count: 3)
        if getloadavg(&carga, 3) > 0 { r.cargaCPU = min(1, carga[0] / Double(ProcessInfo.processInfo.activeProcessorCount)) }
        switch ProcessInfo.processInfo.thermalState {
        case .fair: r.termico = "Tibio"
        case .serious: r.termico = "Alta"
        case .critical: r.termico = "Crítica"
        default: r.termico = "Normal"
        }
        // Memoria, swap y batería: los mide el Optimizador del Mac cada hora
        let lineas = almacen.resultados["opt"]?.detalle ?? []
        func numero(_ patron: String) -> Double? {
            for l in lineas {
                if let m = l.range(of: patron, options: .regularExpression) {
                    let t = String(l[m]).replacingOccurrences(of: ",", with: ".")
                    if let n = t.split(whereSeparator: { !("0123456789.".contains($0)) }).first.flatMap({ Double($0) }) { return n }
                }
            }
            return nil
        }
        r.memoriaLibrePct = numero("Memoria libre [0-9]+").map { $0 / 100 }
        r.swapGB = numero("swap [0-9.,]+")
        r.bateriaPct = numero("Batería [0-9]+").map { $0 / 100 }
        return r
    }
}

// MARK: - Alarma visual y auditiva

@MainActor
final class AlarmaVilla: ObservableObject {
    static let shared = AlarmaVilla()
    @Published var problemas: [String] = []
    @Published var nuevos = false               // late hasta que la vez o la silencies
    @AppStorage("alarmaSonido") var sonido = true
    private var conocidos: Set<String> = []
    private var primera = true

    var activa: Bool { !problemas.isEmpty }

    /// Junta los problemas reales (agentes en atención o falla e incidentes del Mac). Suena solo ante uno nuevo.
    func evaluar(_ almacen: Almacen, incidentes: [String]) {
        var lista = almacen.conProblemas.map { "\($0.nombre): \($0.etiquetaEstado.lowercased())" }
        for i in incidentes where !lista.contains(where: { i.hasPrefix($0.components(separatedBy: ":").first ?? "~") }) && !i.contains(" en atención") && !i.contains(" en falla") {
            lista.append(i)
        }
        let actuales = Set(lista)
        let llegaron = actuales.subtracting(conocidos)
        if lista != problemas { problemas = lista }
        if !llegaron.isEmpty && !primera {
            nuevos = true
            if sonido { sonar() }
        }
        if actuales.isEmpty { nuevos = false }
        conocidos = actuales; primera = false
    }

    func sonar() {
        for k in 0..<3 { DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) * 0.9) { NSSound(named: "Sosumi")?.play() } }
    }
    func reconocer() { nuevos = false }
}

// MARK: - Centro de mando (panel y pantalla panorámica de la villa)

struct CentroMando: View {
    @EnvironmentObject var almacen: Almacen
    @ObservedObject var alarma = AlarmaVilla.shared
    var pantalla = false                         // true: versión para el pantallón 3D (sin botones)
    var defensa: [String] = []
    @State private var historial: [PanelOptimizador.PuntoOpt] = []
    @Environment(\.colorScheme) private var esquema

    private var r: RecursosMac { RecursosMac.leer(almacen) }
    private var activos: [Agente] { almacen.agentes.filter { $0.estado != "off" } }
    private var salud: Double {
        guard !activos.isEmpty else { return 1 }
        let puntos = activos.map { $0.estado == "ok" || $0.estado == "fixed" ? 1.0 : $0.estado == "warn" ? 0.5 : 0 }
        return puntos.reduce(0, +) / Double(activos.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if alarma.activa { bandaAlarma }
            HStack(alignment: .top, spacing: 12) {
                tarjeta("Salud de la villa", "heart.text.square") { saludGeneral }
                tarjeta("Recursos del Mac", "cpu") { recursos }
                tarjeta("Seguridad y defensa", "shield.lefthalf.filled") { seguridad }
                tarjeta("Barrios", "map") { barrios }
            }
            tarjeta("Agentes (\(almacen.agentes.count))", "person.3") { mosaico }
        }
        .padding(pantalla ? 18 : 12)
        .frame(width: pantalla ? 1600 : nil)
        .background(pantalla ? Color(red: 0.05, green: 0.08, blue: 0.14) : Color.clear)
        .environment(\.colorScheme, pantalla ? .dark : esquema)
        .task {
            let ruta = Almacen.carpetaLocal + "/trabajo/optimizador-historial.json"
            if let d = FileManager.default.contents(atPath: ruta), let h = try? JSONDecoder().decode([PanelOptimizador.PuntoOpt].self, from: d) {
                historial = h.filter { $0.t > Date().timeIntervalSince1970 - 7 * 86400 }
            }
        }
    }

    private func tarjeta<C: View>(_ titulo: String, _ icono: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(titulo, systemImage: icono).font(.headline)
            c()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(pantalla ? Color.white.opacity(0.06) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private var bandaAlarma: some View {
        HStack(spacing: 10) {
            Image(systemName: "light.beacon.max.fill").foregroundStyle(.red).symbolEffect(.pulse, isActive: alarma.nuevos)
            Text("ALARMA · \(alarma.problemas.count) problema(s): " + alarma.problemas.prefix(3).joined(separator: " · "))
                .font(.callout.bold()).lineLimit(2)
            Spacer()
            if !pantalla {
                Button(alarma.sonido ? "Silenciar" : "Activar sonido") { alarma.sonido.toggle() }.help("Enciende o apaga el aviso sonoro de la alarma")
                if alarma.nuevos { Button("Visto") { alarma.reconocer() }.help("Deja de parpadear; la alarma sigue mientras haya problemas") }
            }
        }
        .padding(10)
        .background(Color.red.opacity(alarma.nuevos ? 0.35 : 0.18), in: RoundedRectangle(cornerRadius: 10))
    }

    private var saludGeneral: some View {
        let cuenta = Dictionary(grouping: almacen.agentes, by: \.estado).mapValues(\.count)
        return HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 10)
                Circle().trim(from: 0, to: salud).stroke(salud > 0.9 ? Color.green : salud > 0.7 ? .orange : .red, style: StrokeStyle(lineWidth: 10, lineCap: .round)).rotationEffect(.degrees(-90))
                Text("\(Int(salud * 100)) %").font(.title2.bold())
            }
            .frame(width: 86, height: 86)
            VStack(alignment: .leading, spacing: 4) {
                fila("Operativos", cuenta["ok", default: 0] + cuenta["fixed", default: 0], .green)
                fila("En atención", cuenta["warn", default: 0], .orange)
                fila("Con falla", cuenta["crit", default: 0], .red)
                fila("Apagados", cuenta["off", default: 0], .gray)
                Text("Revisado \(almacen.generado.map { $0.formatted(date: .omitted, time: .shortened) } ?? "—")").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func fila(_ t: String, _ n: Int, _ c: Color) -> some View {
        HStack { Circle().fill(c).frame(width: 9, height: 9); Text(t).font(.callout); Spacer(); Text("\(n)").font(.callout.monospacedDigit().bold()) }
    }

    private var recursos: some View {
        let r = self.r
        return VStack(alignment: .leading, spacing: 6) {
            barra("Disco libre", r.discoLibrePct, String(format: "%.0f GB", r.discoLibreGB), alerta: r.discoLibrePct < 0.1)
            if let m = r.memoriaLibrePct { barra("Memoria libre", m, "\(Int(m * 100)) %", alerta: m < 0.1) }
            barra("Carga de CPU", r.cargaCPU, "\(Int(r.cargaCPU * 100)) %", alerta: r.cargaCPU > 0.9, invertida: true)
            if let s = r.swapGB { barra("Swap", min(1, s / 16), String(format: "%.1f GB", s), alerta: s > 8, invertida: true) }
            if let b = r.bateriaPct { barra("Batería", b, "\(Int(b * 100)) %", alerta: b < 0.15) }
            HStack { Text("Temperatura").font(.caption); Spacer(); Text(r.termico).font(.caption.bold()).foregroundStyle(r.termico == "Normal" ? .green : r.termico == "Tibio" ? .orange : .red) }
            if historial.count > 1 {
                Chart(historial) { p in
                    AreaMark(x: .value("Fecha", p.fecha), y: .value("Disco libre", p.disco ?? 0)).foregroundStyle(.blue.opacity(0.25))
                    LineMark(x: .value("Fecha", p.fecha), y: .value("Disco libre", p.disco ?? 0))
                }
                .chartYAxisLabel("GB libres").frame(height: 60)
            }
        }
    }
    private func barra(_ t: String, _ v: Double, _ texto: String, alerta: Bool, invertida: Bool = false) -> some View {
        let color: Color = alerta ? .red : invertida ? (v > 0.7 ? .orange : .green) : (v < 0.25 ? .orange : .green)
        return VStack(alignment: .leading, spacing: 2) {
            HStack { Text(t).font(.caption); Spacer(); Text(texto).font(.caption.monospacedDigit().bold()) }
            Medidor(valor: v, color: color)
        }
    }

    private var seguridad: some View {
        let seg = almacen.resultados["seg"]
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: seg?.status == "warn" ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                    .foregroundStyle(seg?.status == "warn" ? .red : .green).font(.title2)
                Text(seg?.resumen ?? "Vigilante de seguridad sin datos").font(.callout).lineLimit(3)
            }
            ForEach(defensa.prefix(4), id: \.self) { d in Text("• " + d).font(.caption).lineLimit(2) }
            if !pantalla {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 6) {
                    recurso("Seguridad", "shield", "Abre Ajustes → Privacidad y seguridad") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")!) }
                    recurso("Optimizador", "speedometer", "Detalle y recomendaciones del Optimizador del Mac") { almacen.seleccion = "opt" }
                    recurso("Almacenamiento", "sparkles", "Abre Ajustes → Almacenamiento") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!) }
                    recurso("Monitor", "gauge.with.dots.needle.67percent", "Procesos, memoria y CPU") { abrir("/System/Applications/Utilities/Activity Monitor.app") }
                    recurso("Flota", "ferry.fill", "Vuela al portaaviones y su escolta: cada buque es un agente protector u optimizador") {
                        ControlVilla.shared.verCentro = false; ControlVilla.shared.mostrarElemento("flota-portaaviones"); ControlVilla.shared.coord?.irFlota()
                    }
                    recurso("Revisar ahora", "arrow.clockwise", "Revisa el estado real de todos los agentes (⌘R)") { Task { await almacen.revisar() } }
                }
            }
        }
    }
    private func recurso(_ t: String, _ i: String, _ ayuda: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) { Label(t, systemImage: i).frame(maxWidth: .infinity) }.controlSize(.small).help(ayuda)
    }
    private func abrir(_ ruta: String) { NSWorkspace.shared.open(URL(fileURLWithPath: ruta)) }

    private var barrios: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(almacen.zonas.keys.sorted(), id: \.self) { zid in
                let lista = almacen.agentes.filter { $0.zona == zid }
                let total = max(1, lista.count)
                VStack(alignment: .leading, spacing: 2) {
                    HStack { Text(almacen.zonas[zid]?.name ?? zid).font(.caption); Spacer(); Text("\(lista.count)").font(.caption.monospacedDigit()) }
                    GeometryReader { g in
                        HStack(spacing: 1) {
                            ForEach(["ok", "fixed", "warn", "crit", "off"], id: \.self) { e in
                                let n = lista.filter { $0.estado == e }.count
                                if n > 0 { Rectangle().fill(Agente.color(e)).frame(width: g.size.width * CGFloat(n) / CGFloat(total)) }
                            }
                        }
                    }
                    .frame(height: 8).clipShape(Capsule())
                }
            }
            if almacen.serieTokens.count > 1 {
                Chart(Array(almacen.serieTokens.suffix(14).enumerated()), id: \.offset) { _, d in
                    BarMark(x: .value("Día", String(d.fecha.suffix(5))), y: .value("Tokens", d.total))
                }
                .chartYAxisLabel("Millones de tokens/día").chartXAxis(.hidden).frame(height: 55)
            }
        }
    }

    private var mosaico: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: pantalla ? 180 : 150), spacing: 6)], spacing: 6) {
            ForEach(almacen.agentes) { a in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Circle().fill(a.color).frame(width: 8, height: 8)
                        Text(a.nombre).font(.caption.bold()).lineLimit(1)
                    }
                    Medidor(valor: a.estado == "ok" || a.estado == "fixed" ? 1 : a.estado == "warn" ? 0.5 : a.estado == "crit" ? 0.15 : 0, color: a.color)
                    Text("Última \(a.ultima) · \(a.proxima)").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(6)
                .background(a.enAtencion ? a.color.opacity(0.18) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture { if !pantalla { almacen.seleccion = a.id } }
                .help(a.resultado.isEmpty ? a.etiquetaEstado : a.resultado)
            }
        }
    }
}

/// Barra de avance dibujada con formas (también sale bien en el pantallón 3D, que se renderiza como imagen).
struct Medidor: View {
    var valor: Double
    var color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.22))
                Capsule().fill(color).frame(width: g.size.width * max(0, min(1, valor)))
            }
        }
        .frame(height: 7)
    }
}
