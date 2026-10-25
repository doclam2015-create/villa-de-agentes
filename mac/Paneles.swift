import SwiftUI
import Charts

// MARK: - Paneles con gráficos: gastos del Cajero (lo que rinde a Hacienda) y consumo de tokens del Contador.
// Se ven en la pizarra de cada agente y, en grande, en las pantallas del atrio del mall (pantalla: true).

private func leerJSON(_ ruta: String) -> [String: Any] {
    (FileManager.default.contents(atPath: Almacen.carpetaLocal + "/" + ruta).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
}
private func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
func pesosCL(_ n: Double) -> String {
    let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "es_CL"); f.maximumFractionDigits = 0
    return "$" + (f.string(from: NSNumber(value: n)) ?? "\(Int(n))")
}
func tokensTxt(_ n: Double) -> String {
    n >= 1_000_000 ? String(format: "%.1f M", n / 1_000_000) : n >= 1000 ? String(format: "%.0f mil", n / 1000) : String(format: "%.0f", n)
}
private let mesesCortos = ["", "Ene", "Feb", "Mar", "Abr", "May", "Jun", "Jul", "Ago", "Sep", "Oct", "Nov", "Dic"]
private func mesCorto(_ ym: String) -> String { let m = Int(ym.suffix(2)) ?? 0; return (0...12).contains(m) ? mesesCortos[m] : ym }

/// Tarjeta de un indicador: valor grande, rótulo y una línea de comparación coloreada.
private struct IndicadorPanel: View {
    let titulo: String, valor: String, nota: String
    var color: Color = .secondary
    let grande: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(titulo).font(grande ? .system(size: 13, weight: .semibold) : .caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(valor).font(grande ? .system(size: 24, weight: .bold, design: .rounded) : .system(size: 15, weight: .bold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(nota).font(grande ? .system(size: 12, weight: .medium) : .system(size: 10, weight: .medium)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(grande ? 10 : 6)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SeccionPanel<C: View>: View {
    let titulo: String, grande: Bool
    @ViewBuilder let contenido: C
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titulo).font(grande ? .system(size: 14, weight: .bold) : .caption.bold())
            contenido
        }
        .padding(grande ? 10 : 6)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: Gastos

struct PanelGastos: View {
    var pantalla = false
    @State private var d = DatosGastos.leer()
    init(pantalla: Bool = false) { self.pantalla = pantalla }

    var body: some View {
        Group {
            if pantalla {
                VStack(alignment: .leading, spacing: 10) {
                    encabezado
                    HStack(spacing: 10) { indicadores }
                    HStack(alignment: .top, spacing: 10) {
                        SeccionPanel(titulo: "Gasto por mes y servicio", grande: true) { porMes.frame(height: 250) }.frame(width: 430)
                        SeccionPanel(titulo: "Por categoría", grande: true) { donut.frame(height: 250) }.frame(width: 230)
                        SeccionPanel(titulo: "Por agente (lo que rinde a Hacienda)", grande: true) { porAgente.frame(height: 250) }
                    }
                    HStack(alignment: .top, spacing: 10) {
                        SeccionPanel(titulo: "Próximos cobros (7 días)", grande: true) { proximos }.frame(maxWidth: .infinity)
                        SeccionPanel(titulo: "Estadísticas", grande: true) { estadisticas }.frame(maxWidth: .infinity)
                    }
                }
                .padding(16)
                .frame(width: 940, height: 530, alignment: .topLeading)
                .background(Color(red: 0.06, green: 0.08, blue: 0.13))
                .environment(\.colorScheme, .dark)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    encabezado
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) { indicadores }
                    SeccionPanel(titulo: "Gasto por mes y servicio", grande: false) { porMes.frame(height: 170) }
                    SeccionPanel(titulo: "Por categoría", grande: false) { donut.frame(height: 150) }
                    SeccionPanel(titulo: "Por agente (lo que rinde a Hacienda)", grande: false) { porAgente.frame(height: 150) }
                    SeccionPanel(titulo: "Próximos cobros (7 días)", grande: false) { proximos }
                    SeccionPanel(titulo: "Estadísticas", grande: false) { estadisticas }
                }
                .onAppear { d = DatosGastos.leer() }
            }
        }
    }

    private var encabezado: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Gastos en apps y suscripciones").font(pantalla ? .system(size: 20, weight: .heavy) : .subheadline.bold())
            Text(d.fuente).font(pantalla ? .system(size: 11) : .caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    @ViewBuilder private var indicadores: some View {
        IndicadorPanel(titulo: "Gasto mensual actual", valor: pesosCL(d.mensual), nota: "\(d.activas.count) suscripciones activas", grande: pantalla)
        IndicadorPanel(titulo: "Proyección anual", valor: pesosCL(d.mensual * 12), nota: "al ritmo de hoy", grande: pantalla)
        let v = d.variacion
        IndicadorPanel(titulo: "Último mes vs anterior", valor: v.map { String(format: "%+.0f %%", $0.pct) } ?? "—",
                  nota: v.map { "\($0.mes): \(pesosCL($0.monto))" } ?? "sin datos", color: (v?.pct ?? 0) > 0 ? .red : .green, grande: pantalla)
        IndicadorPanel(titulo: "Uso del presupuesto", valor: d.presupuesto > 0 ? String(format: "%.0f %%", d.mensual / d.presupuesto * 100) : "Sin aprobar",
                  nota: d.presupuesto > 0 ? "de \(pesosCL(d.presupuesto)) aprobados" : "propuesta: \(pesosCL(d.fijo)) fijo",
                  color: d.presupuesto > 0 && d.mensual > d.presupuesto ? .red : .orange, grande: pantalla)
    }

    private var porMes: some View {
        Chart(d.barras, id: \.id) { b in
            BarMark(x: .value("Mes", b.mes), y: .value("CLP", b.monto))
                .foregroundStyle(by: .value("Servicio", b.servicio))
        }
        .chartForegroundStyleScale(domain: DatosGastos.servicios.map(\.1), range: DatosGastos.servicios.map(\.2))
        .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let n = v.as(Double.self) { Text("\(Int(n / 1000)) mil") } } } }
        .chartLegend(position: .bottom, spacing: 4)
    }

    private var donut: some View {
        Chart(d.categorias, id: \.0) { c in
            SectorMark(angle: .value("CLP", c.1), innerRadius: .ratio(0.55), angularInset: 1.2)
                .foregroundStyle(by: .value("Categoría", c.0))
        }
        .chartLegend(position: .bottom, spacing: 4)
    }

    private var porAgente: some View {
        Chart(d.agentes, id: \.0) { a in
            BarMark(x: .value("CLP", a.1), y: .value("Agente", a.0))
                .foregroundStyle(a.0 == "Sin agente" ? Color.gray : Color(hex: "#b0306a"))
                .annotation(position: .trailing) { Text("\(Int(a.1 / 1000)) mil").font(.system(size: pantalla ? 10 : 8)).foregroundStyle(.secondary) }
        }
        .chartXAxis(.hidden)
    }

    private var proximos: some View {
        VStack(alignment: .leading, spacing: 2) {
            if d.proximos.isEmpty { Text("Ningún cobro en los próximos 7 días.").font(.caption).foregroundStyle(.secondary) }
            ForEach(d.proximos.prefix(pantalla ? 5 : 6), id: \.nombre) { p in
                HStack {
                    Text(p.dias == 0 ? "Hoy" : p.dias == 1 ? "Mañana" : "En \(p.dias) días").frame(width: pantalla ? 70 : 58, alignment: .leading).foregroundStyle(p.dias <= 1 ? .orange : .secondary)
                    Text(p.nombre).lineLimit(1)
                    Spacer()
                    Text(pesosCL(p.monto)).monospacedDigit()
                }
                .font(pantalla ? .system(size: 12) : .caption2)
            }
            ForEach(d.vencidas, id: \.self) { n in
                Text("⚠️ \(n): vencida").font(pantalla ? .system(size: 12, weight: .semibold) : .caption2.bold()).foregroundStyle(.red)
            }
        }
    }

    private var estadisticas: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(d.estadisticas, id: \.0) { e in
                HStack { Text(e.0).foregroundStyle(.secondary); Spacer(); Text(e.1).monospacedDigit().bold() }
                    .font(pantalla ? .system(size: 12) : .caption2)
            }
        }
    }
}

struct DatosGastos {
    struct Barra { let id: String, mes: String, servicio: String, monto: Double }
    struct Cobro { let nombre: String, dias: Int, monto: Double }
    static let servicios: [(String, String, Color)] = [
        ("claude", "Claude", Color(hex: "#d97757")), ("chatgpt", "ChatGPT", Color(hex: "#10a37f")), ("apple", "Apple", Color(hex: "#8e8e93")),
        ("google_one", "Google One", Color(hex: "#4285f4")), ("workspace", "Workspace", Color(hex: "#fbbc05")), ("netflix", "Netflix", Color(hex: "#e50914")),
        ("accuweather", "AccuWeather", Color(hex: "#f57c00")), ("otros", "Otros", Color(hex: "#7e57c2"))]
    var fuente = "", mensual = 0.0, presupuesto = 0.0, fijo = 0.0
    var activas: [[String: Any]] = [], barras: [Barra] = [], categorias: [(String, Double)] = [], agentes: [(String, Double)] = []
    var proximos: [Cobro] = [], vencidas: [String] = [], estadisticas: [(String, String)] = []
    var variacion: (pct: Double, mes: String, monto: Double)?

    static func leer() -> DatosGastos {
        var d = DatosGastos()
        let hist = leerJSON("trabajo/tienda/historial.json"), subs = leerJSON("trabajo/tienda/suscripciones.json"), inf = leerJSON("trabajo/hacienda/informe.json")
        let lista = (subs["suscripciones"] as? [[String: Any]]) ?? []
        d.activas = lista.filter { ($0["estado"] as? String) == "activa" }
        d.vencidas = lista.filter { ($0["estado"] as? String) == "vencida" }.compactMap { $0["nombre"] as? String }
        d.mensual = d.activas.reduce(0) { $0 + num($1["monto"]) }
        d.fijo = num(inf["fijo"])
        d.presupuesto = num((inf["aprobado"] as? [String: Any])?["monto"])
        // Barras por mes y servicio (historial real de comprobantes)
        let meses = (hist["meses"] as? [String: Any]) ?? [:], parciales = Set((hist["parcial"] as? [String]) ?? [])
        let orden = meses.keys.sorted()
        for ym in orden {
            let m = (meses[ym] as? [String: Any]) ?? [:], ps = (m["por_servicio"] as? [String: Any]) ?? [:]
            let rot = mesCorto(ym) + (parciales.contains(ym) ? "*" : "")
            for (k, nombre, _) in servicios where num(ps[k]) > 0 { d.barras.append(Barra(id: ym + k, mes: rot, servicio: nombre, monto: num(ps[k]))) }
        }
        let completos = orden.filter { !parciales.contains($0) }.map { (ym: $0, total: num((meses[$0] as? [String: Any])?["total"])) }
        if completos.count >= 2 {
            let a = completos[completos.count - 1], b = completos[completos.count - 2]
            d.variacion = ((a.total - b.total) / max(1, b.total) * 100, mesCorto(a.ym), a.total)
        }
        // Categorías (suscripciones activas)
        var cat: [String: Double] = [:]
        for s in d.activas { cat[(s["categoria"] as? String) ?? "Otras", default: 0] += num(s["monto"]) }
        d.categorias = cat.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        // Por agente (reparto que el Cajero rinde a Hacienda)
        var nombres: [String: String] = [:]
        for a in (leerJSON("agentes.json")["agentes"] as? [[String: Any]]) ?? [] { if let i = a["id"] as? String { nombres[i] = a["name"] as? String } }
        var ag = ((inf["por_agente"] as? [String: Any]) ?? [:]).map { (nombres[$0.key] ?? $0.key, num($0.value)) }.sorted { $0.1 > $1.1 }
        if num(inf["sin_agente"]) > 0 { ag.append(("Sin agente", num(inf["sin_agente"]))) }
        d.agentes = ag
        // Próximos cobros
        let hoy = Calendar.current.component(.day, from: Date())
        let diasMes = Calendar.current.range(of: .day, in: .month, for: Date())?.count ?? 30
        d.proximos = d.activas.compactMap { s in
            guard let dia = (s["dia"] as? NSNumber)?.intValue else { return nil }
            let falta = (dia - hoy + diasMes) % diasMes
            return falta <= 7 ? Cobro(nombre: (s["nombre"] as? String) ?? "", dias: falta, monto: num(s["monto"])) : nil
        }.sorted { $0.dias < $1.dias }
        // Estadísticas
        let tot = completos.map(\.total)
        if !tot.isEmpty {
            let prom = tot.reduce(0, +) / Double(tot.count)
            d.estadisticas.append(("Promedio mensual (\(tot.count) meses completos)", pesosCL(prom)))
            if let mx = completos.max(by: { $0.total < $1.total }) { d.estadisticas.append(("Mes más alto", "\(mesCorto(mx.ym)) · \(pesosCL(mx.total))")) }
            if let mn = completos.min(by: { $0.total < $1.total }) { d.estadisticas.append(("Mes más bajo", "\(mesCorto(mn.ym)) · \(pesosCL(mn.total))")) }
            d.estadisticas.append(("Hoy vs promedio", String(format: "%+.0f %%", (d.mensual - prom) / max(1, prom) * 100)))
        }
        if let top = d.activas.max(by: { num($0["monto"]) < num($1["monto"]) }) {
            d.estadisticas.append(("Mayor suscripción", "\((top["nombre"] as? String) ?? "") · \(String(format: "%.0f %%", num(top["monto"]) / max(1, d.mensual) * 100))"))
        }
        d.fuente = (hist["fuente"] as? String).map { "Fuente: " + $0 } ?? "Sin historial todavía"
        return d
    }
}

// MARK: Tokens

struct PanelTokens: View {
    var pantalla = false
    @State private var d = DatosTokens.leer()
    init(pantalla: Bool = false) { self.pantalla = pantalla }

    var body: some View {
        Group {
            if pantalla {
                VStack(alignment: .leading, spacing: 10) {
                    encabezado
                    HStack(spacing: 10) { indicadores }
                    HStack(alignment: .top, spacing: 10) {
                        SeccionPanel(titulo: "Tokens por día (30 días) y promedio de 7 días", grande: true) { serie.frame(height: 250) }.frame(width: 520)
                        SeccionPanel(titulo: "Por modelo", grande: true) { porModelo.frame(height: 250) }
                    }
                    HStack(alignment: .top, spacing: 10) {
                        SeccionPanel(titulo: "Proyectos que más consumen", grande: true) { proyectos }.frame(maxWidth: .infinity)
                        SeccionPanel(titulo: "Estadísticas", grande: true) { estadisticas }.frame(maxWidth: .infinity)
                    }
                }
                .padding(16)
                .frame(width: 940, height: 530, alignment: .topLeading)
                .background(Color(red: 0.06, green: 0.08, blue: 0.13))
                .environment(\.colorScheme, .dark)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    encabezado
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) { indicadores }
                    SeccionPanel(titulo: "Tokens por día y promedio de 7 días", grande: false) { serie.frame(height: 170) }
                    SeccionPanel(titulo: "Por modelo", grande: false) { porModelo.frame(height: 130) }
                    SeccionPanel(titulo: "Proyectos que más consumen", grande: false) { proyectos }
                    SeccionPanel(titulo: "Estadísticas", grande: false) { estadisticas }
                }
                .onAppear { d = DatosTokens.leer() }
            }
        }
    }

    private var encabezado: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Consumo de tokens").font(pantalla ? .system(size: 20, weight: .heavy) : .subheadline.bold())
            Text(d.detallado ? "Claude Code y Codex en este Mac · últimos 30 días" : "Total diario (el desglose por modelo y proyecto aparece tras la próxima corrida del Contador)")
                .font(pantalla ? .system(size: 11) : .caption2).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    @ViewBuilder private var indicadores: some View {
        IndicadorPanel(titulo: "Hoy", valor: tokensTxt(d.hoy), nota: "Codex: \(tokensTxt(d.codexHoy))", grande: pantalla)
        IndicadorPanel(titulo: "Promedio 7 días", valor: tokensTxt(d.prom7), nota: "por día", grande: pantalla)
        IndicadorPanel(titulo: "Semana vs anterior", valor: d.semAnt > 0 ? String(format: "%+.0f %%", (d.sem - d.semAnt) / d.semAnt * 100) : "—",
                  nota: "\(tokensTxt(d.sem)) vs \(tokensTxt(d.semAnt))", color: d.sem > d.semAnt ? .orange : .green, grande: pantalla)
        IndicadorPanel(titulo: "Eficiencia de caché", valor: d.detallado ? String(format: "%.0f %%", d.cacheRatio * 100) : "—",
                  nota: "de la entrada se lee desde caché", color: .green, grande: pantalla)
    }

    private var serie: some View {
        Chart {
            ForEach(d.barras, id: \.id) { b in
                BarMark(x: .value("Día", b.dia, unit: .day), y: .value("Tokens", b.valor))
                    .foregroundStyle(by: .value("Fuente", b.fuente))
            }
            ForEach(d.media, id: \.0) { m in
                LineMark(x: .value("Día", m.0, unit: .day), y: .value("Promedio 7 días", m.1))
                    .foregroundStyle(.white.opacity(0.85)).lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3])).interpolationMethod(.monotone)
            }
        }
        .chartForegroundStyleScale(["Claude": Color(hex: "#d97757"), "Codex": Color(hex: "#10a37f")])
        .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let n = v.as(Double.self) { Text(tokensTxt(n)) } } } }
        .chartXAxis { AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
        .chartLegend(position: .bottom, spacing: 4)
    }

    private var porModelo: some View {
        Chart(d.modelos, id: \.0) { m in
            BarMark(x: .value("Tokens", m.1), y: .value("Modelo", m.0))
                .foregroundStyle(Color(hex: "#d97757"))
                .annotation(position: .trailing) { Text(tokensTxt(m.1)).font(.system(size: pantalla ? 10 : 8)).foregroundStyle(.secondary) }
        }
        .chartXAxis(.hidden)
        .overlay { if d.modelos.isEmpty { Text("Disponible tras la próxima corrida").font(.caption).foregroundStyle(.secondary) } }
    }

    private var proyectos: some View {
        VStack(alignment: .leading, spacing: 3) {
            if d.proyectos.isEmpty { Text("Disponible tras la próxima corrida del Contador.").font(.caption).foregroundStyle(.secondary) }
            let mx = d.proyectos.first?.1 ?? 1
            ForEach(d.proyectos.prefix(pantalla ? 5 : 6), id: \.0) { p in
                HStack(spacing: 6) {
                    Text(p.0).lineLimit(1).truncationMode(.head).frame(width: pantalla ? 200 : 150, alignment: .leading)
                    GeometryReader { g in RoundedRectangle(cornerRadius: 3).fill(Color(hex: "#d97757")).frame(width: g.size.width * p.1 / max(1, mx)) }.frame(height: 8)
                    Text(tokensTxt(p.1)).monospacedDigit().frame(width: 60, alignment: .trailing)
                }
                .font(pantalla ? .system(size: 12) : .caption2)
            }
        }
    }

    private var estadisticas: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(d.estadisticas, id: \.0) { e in
                HStack { Text(e.0).foregroundStyle(.secondary); Spacer(); Text(e.1).monospacedDigit().bold() }
                    .font(pantalla ? .system(size: 12) : .caption2)
            }
        }
    }
}

struct DatosTokens {
    struct Barra { let id: String, dia: Date, fuente: String, valor: Double }
    var detallado = false
    var barras: [Barra] = [], media: [(Date, Double)] = [], modelos: [(String, Double)] = [], proyectos: [(String, Double)] = []
    var hoy = 0.0, codexHoy = 0.0, prom7 = 0.0, sem = 0.0, semAnt = 0.0, cacheRatio = 0.0
    var estadisticas: [(String, String)] = []

    static func leer() -> DatosTokens {
        var d = DatosTokens()
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        let des = (leerJSON("resultados/tok-desglose.json")["dias"] as? [String: Any]) ?? [:]
        var porDia: [(Date, claude: Double, codex: Double)] = []
        var ent = 0.0, cache = 0.0, mods: [String: Double] = [:], proys: [String: Double] = [:]
        if !des.isEmpty {
            d.detallado = true
            for k in des.keys.sorted() {
                guard let fecha = f.date(from: k), let x = des[k] as? [String: Any] else { continue }
                let cl = num(x["entrada"]) + num(x["salida"])
                porDia.append((fecha, cl, num(x["codex"])))
                ent += num(x["entrada"]); cache += num(x["cache"])
                for (m, v) in (x["modelos"] as? [String: Any]) ?? [:] { mods[m, default: 0] += num(v) }
                for (p, v) in (x["proyectos"] as? [String: Any]) ?? [:] { proys[p, default: 0] += num(v) }
            }
        } else {
            let h = leerJSON("resultados/tok-historial.json")
            for k in h.keys.sorted() { if let fecha = f.date(from: k) { porDia.append((fecha, num(h[k]), 0)) } }
        }
        porDia = Array(porDia.suffix(30))
        for p in porDia {
            let k = f.string(from: p.0)
            d.barras.append(Barra(id: k + "c", dia: p.0, fuente: "Claude", valor: p.claude))
            if p.codex > 0 { d.barras.append(Barra(id: k + "x", dia: p.0, fuente: "Codex", valor: p.codex)) }
        }
        let tot = porDia.map { $0.claude + $0.codex }
        for i in tot.indices { let v = tot[max(0, i - 6)...i]; d.media.append((porDia[i].0, v.reduce(0, +) / Double(v.count))) }
        if let u = porDia.last { d.hoy = u.claude + u.codex; d.codexHoy = u.codex }
        d.prom7 = tot.suffix(7).reduce(0, +) / Double(max(1, min(7, tot.count)))
        d.sem = tot.suffix(7).reduce(0, +)
        d.semAnt = tot.dropLast(7).suffix(7).reduce(0, +)
        d.cacheRatio = cache / max(1, cache + ent)
        d.modelos = mods.sorted { $0.value > $1.value }.prefix(5).map { ($0.key, $0.value) }
        d.proyectos = proys.sorted { $0.value > $1.value }.prefix(6).map { ($0.key, $0.value) }
        if !tot.isEmpty {
            let total = tot.reduce(0, +)
            d.estadisticas.append(("Total del período (\(tot.count) días)", tokensTxt(total)))
            if let i = tot.indices.max(by: { tot[$0] < tot[$1] }) {
                let g = DateFormatter(); g.dateFormat = "d MMM"; g.locale = Locale(identifier: "es_CL")
                d.estadisticas.append(("Día de mayor consumo", "\(g.string(from: porDia[i].0)) · \(tokensTxt(tot[i]))"))
            }
            let codex = porDia.reduce(0) { $0 + $1.codex }
            d.estadisticas.append(("Participación de Codex", String(format: "%.0f %%", codex / max(1, total) * 100)))
            if d.detallado { d.estadisticas.append(("Tokens leídos desde caché", tokensTxt(cache))) }
            d.estadisticas.append(("Proyección a 30 días", tokensTxt(d.prom7 * 30)))
        }
        return d
    }
}
