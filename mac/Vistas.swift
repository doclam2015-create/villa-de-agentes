import SwiftUI
import Charts
import AppKit
import SceneKit

enum Seccion: String, CaseIterable, Identifiable {
    case villa = "Villa 3D", resumen = "Resumen", agentes = "Agentes", barrios = "Barrios", tokens = "Tokens", respaldos = "Respaldos"
    var id: String { rawValue }
    var icono: String {
        switch self {
        case .villa: return "building.2.crop.circle"
        case .resumen: return "gauge.with.dots.needle.67percent"
        case .agentes: return "person.3.sequence"
        case .barrios: return "map"
        case .tokens: return "chart.line.uptrend.xyaxis"
        case .respaldos: return "externaldrive.badge.timemachine"
        }
    }
}

struct VistaPrincipal: View {
    @EnvironmentObject var almacen: Almacen
    @AppStorage("seccion") private var seccionGuardada = Seccion.villa.rawValue
    @AppStorage("barrio") private var barrioGuardado = ""      // "" = toda la villa
    @State private var ayuda = false
    @State private var informe: URL?
    @State private var altaAgentes = false
    @State private var columnas = NavigationSplitViewVisibility.automatic
    @ObservedObject private var cv = ControlVilla.shared

    private var seccion: Binding<Seccion?> {
        Binding(get: { Seccion(rawValue: seccionGuardada) }, set: { seccionGuardada = ($0 ?? .villa).rawValue })
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnas) {
            List {
                Section("Villa") {
                    // Clic directo (List(selection:) con AppStorage no respondía en macOS).
                    ForEach(Seccion.allCases) { s in
                        let activa = seccionGuardada == s.rawValue
                        Label(s.rawValue, systemImage: s.icono)
                            .badge(s == .agentes ? almacen.conProblemas.count : 0)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            .onTapGesture { seccionGuardada = s.rawValue }
                            .listRowBackground(RoundedRectangle(cornerRadius: 6).fill(activa ? Color.accentColor.opacity(0.28) : .clear).padding(.horizontal, 8))
                            .help("Abrir \(s.rawValue)")
                    }
                    Label("Metro · Línea Circular", systemImage: "tram.fill")
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        .onTapGesture { seccionGuardada = Seccion.villa.rawValue; cv.verMetro = true; cv.vistaMetro("arriba") }
                        .listRowBackground(RoundedRectangle(cornerRadius: 6).fill(cv.verMetro && seccionGuardada == Seccion.villa.rawValue ? Color.accentColor.opacity(0.28) : .clear).padding(.horizontal, 8))
                        .help("Visión completa del circuito del tren: exterior, interior, desde arriba y cada entrada o salida de las estaciones")
                }
                Section("Barrios") {
                    let enBarrios = seccionGuardada == Seccion.barrios.rawValue
                    Label("Toda la villa (\(almacen.agentes.count))", systemImage: "map")
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        .onTapGesture { barrioGuardado = ""; seccionGuardada = Seccion.barrios.rawValue }
                        .listRowBackground(RoundedRectangle(cornerRadius: 6).fill(enBarrios && barrioGuardado.isEmpty ? Color.accentColor.opacity(0.28) : .clear).padding(.horizontal, 8))
                        .help("Todos los barrios con sus agentes")
                    ForEach(almacen.zonas.sorted(by: { $0.value.name < $1.value.name }), id: \.key) { zid, z in
                        let n = almacen.agentes.filter { $0.zona == zid }
                        Label { HStack { Text("\(z.name) (\(n.count))"); if n.contains(where: \.enAtencion) { Image(systemName: "exclamationmark.triangle.fill").parpadeo(true).help("Hay agentes en atención en este barrio") } } } icon: { Image(systemName: iconoBarrio[zid] ?? "circle.fill").foregroundStyle(Color(hex: z.roof)) }
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            .onTapGesture { barrioGuardado = zid; seccionGuardada = Seccion.barrios.rawValue }
                            .listRowBackground(RoundedRectangle(cornerRadius: 6).fill(enBarrios && barrioGuardado == zid ? Color.accentColor.opacity(0.28) : .clear).padding(.horizontal, 8))
                            .help("Ver solo \(z.name), ampliado")
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
            .safeAreaInset(edge: .bottom) { PieLateral() }
        } detail: {
            HSplitView {
                Group {
                    switch Seccion(rawValue: seccionGuardada) ?? .villa {
                    case .villa:
                        Villa3D(almacen: almacen).ignoresSafeArea()
                            .overlay { MandoVilla() }
                            .overlay(alignment: .topTrailing) { ControlesCamara() }
                            .overlay(alignment: .bottomLeading) {
                                Text("Arrastrar: girar · ⇧ o clic derecho: desplazar · rueda/pellizco: zoom al cursor · doble clic: acercar · W A S D / Q E · clic: \(ControlVilla.shared.dentro == nil ? "pizarra o barrio" : "salir de la oficina")")
                                    .font(.caption).padding(8).background(.regularMaterial, in: Capsule()).padding(14)
                            }
                    case .resumen: VistaResumen()
                    case .agentes: VistaTabla()
                    case .barrios: VistaBarrios(barrio: $barrioGuardado, seccion: $seccionGuardada)
                    case .tokens: VistaTokens()
                    case .respaldos: VistaRespaldos()
                    }
                }
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                if almacen.seleccionado != nil {
                    DetalleAgente().frame(minWidth: 320, idealWidth: 380, maxWidth: 520)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await almacen.revisar() } } label: { Label("Revisar ahora", systemImage: "arrow.clockwise") }
                    .help("Revisa ya el estado real de todos los agentes (⌘R)")
                    .keyboardShortcut("r")
                Button { if let a = almacen.seleccionado { Task { await almacen.ejecutar(a) } } } label: { Label("Ejecutar", systemImage: "play.fill") }
                    .help("Ejecuta ahora el agente seleccionado (⌘E)")
                    .keyboardShortcut("e")
                    .disabled(almacen.seleccionado?.servicio == nil)
                Menu {
                    Button("Informe PDF con vista previa…") { informe = Exportador.pdf(almacen) }.keyboardShortcut("p")
                    Button("Exportar tabla CSV…") { Exportador.guardarCSV(almacen) }
                    Button("Compartir informe…") { if let u = Exportador.pdf(almacen) { Exportador.compartir(u) } }
                } label: { Label("Exportar", systemImage: "square.and.arrow.up") }
                    .help("Informe PDF (con vista previa), tabla CSV o compartir")
                Button { altaAgentes = true } label: { Label("Agentes", systemImage: "person.badge.plus") }
                    .help("Agregar o quitar agentes de la villa")
                Button { ayuda = true } label: { Label("Ayuda", systemImage: "questionmark.circle") }
                    .help("Explica cada botón y sección (⌘?)")
                    .keyboardShortcut("?", modifiers: .command)
            }
        }
        .navigationTitle("Villa de Agentes")
        .onChange(of: cv.pantallaCompleta) { _, v in withAnimation { columnas = v ? .detailOnly : .all } }
        .navigationSubtitle(almacen.fuente)
        .sheet(isPresented: $ayuda) { VistaAyuda() }
        .sheet(isPresented: $altaAgentes) { VistaAgregarAgente().environmentObject(almacen) }
        .sheet(item: $informe) { VistaPreviaPDF(url: $0) }
        .overlay(alignment: .bottom) {
            if let a = almacen.aviso {
                Text(a).padding(10).background(.regularMaterial, in: Capsule()).padding(.bottom, 16)
                    .task { try? await Task.sleep(nanoseconds: 4_000_000_000); almacen.aviso = nil }
            }
        }
        .overlay(alignment: .top) {
            if let e = almacen.error { Text(e).font(.callout).padding(8).background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(.white).padding() }
        }
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

struct PieLateral: View {
    @EnvironmentObject var almacen: Almacen
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Circle().fill(almacen.conProblemas.isEmpty ? .green : .orange).frame(width: 8, height: 8).parpadeo(!almacen.conProblemas.isEmpty)
                Text(almacen.conProblemas.isEmpty ? "Todo operativo" : "\(almacen.conProblemas.count) en atención").font(.callout.weight(.medium)).parpadeo(!almacen.conProblemas.isEmpty) }
            if let g = almacen.generado { Text("Revisado \(g.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
            if almacen.actualizando { ProgressView().controlSize(.small) }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
    }
}

// MARK: - Resumen

struct VistaResumen: View {
    @EnvironmentObject var almacen: Almacen
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Tarjeta(titulo: "Agentes", valor: "\(almacen.agentes.count)", icono: "person.3", color: .blue)
                    Tarjeta(titulo: "Operativos", valor: "\(almacen.agentes.filter { ["ok", "fixed"].contains($0.estado) }.count)", icono: "checkmark.circle", color: .green)
                    Tarjeta(titulo: "En atención", valor: "\(almacen.conProblemas.count)", icono: "exclamationmark.triangle", color: .orange)
                    Tarjeta(titulo: "Apagados", valor: "\(almacen.agentes.filter { $0.estado == "off" }.count)", icono: "moon.zzz", color: .gray)
                }
                GroupBox("Agentes por barrio y estado") {
                    Chart(almacen.agentes) { a in
                        BarMark(x: .value("Barrio", almacen.zonas[a.zona]?.name ?? a.zona), y: .value("Agentes", 1))
                            .foregroundStyle(by: .value("Estado", a.etiquetaEstado))
                    }
                    .chartForegroundStyleScale(["Operativo": .green, "Atención": .orange, "Crítico": .red, "Reparado": .teal, "Apagado": .gray])
                    .frame(height: 220)
                }
                if !almacen.conProblemas.isEmpty {
                    GroupBox("Necesitan atención") {
                        ForEach(almacen.conProblemas) { a in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(a.nombre).font(.headline)
                                Text(a.vivo?.nota ?? a.resultado).font(.callout)
                                if let s = a.vivo?.solucion { Text("Solución: \(s)").font(.callout).foregroundStyle(.secondary) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                            .contentShape(Rectangle()).onTapGesture { almacen.seleccion = a.id }
                        }
                    }
                }
                GroupBox("Lo que hicieron los agentes") {
                    ForEach(almacen.agentes.filter { !$0.resultado.isEmpty }) { a in
                        HStack(alignment: .top) {
                            Circle().fill(a.color).frame(width: 8, height: 8).parpadeo(a.enAtencion).padding(.top, 5)
                            Text(a.nombre).bold().frame(width: 170, alignment: .leading)
                            Text(a.resultado).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .contentShape(Rectangle()).onTapGesture { almacen.seleccion = a.id }
                    }
                }
            }
            .padding(20)
        }
    }
}

struct Tarjeta: View {
    var titulo: String, valor: String, icono: String, color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(titulo, systemImage: icono).font(.callout).foregroundStyle(color)
            Text(valor).font(.system(size: 30, weight: .semibold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Tabla

struct VistaTabla: View {
    @EnvironmentObject var almacen: Almacen
    @State private var busqueda = ""
    @State private var filtroEstado = "todos"
    @State private var orden = [KeyPathComparator(\Agente.nombre)]

    var filas: [Agente] {
        almacen.agentes
            .filter { filtroEstado == "todos" || $0.estado == filtroEstado }
            .filter { busqueda.isEmpty || $0.nombre.localizedCaseInsensitiveContains(busqueda) || $0.def.does.localizedCaseInsensitiveContains(busqueda) }
            .sorted(using: orden)
    }

    var body: some View {
        Table(filas, selection: $almacen.seleccion, sortOrder: $orden) {
            TableColumn("Agente", value: \.nombre) { a in
                HStack { Circle().fill(a.color).frame(width: 8, height: 8).parpadeo(a.enAtencion); Text(a.nombre) }
            }
            TableColumn("Barrio", value: \.zona) { a in Text(almacen.zonas[a.zona]?.name ?? a.zona) }
            TableColumn("Estado", value: \.etiquetaEstado) { a in Text(a.etiquetaEstado).foregroundStyle(a.color).parpadeo(a.enAtencion) }
            TableColumn("Última", value: \.ultima)
            TableColumn("Próxima", value: \.proxima)
            TableColumn("Resultado", value: \.resultado) { a in Text(a.resultado).lineLimit(2).foregroundStyle(.secondary) }
        }
        .searchable(text: $busqueda, prompt: "Buscar agente o tarea")
        .toolbar {
            Picker("Estado", selection: $filtroEstado) {
                Text("Todos").tag("todos")
                Text("Operativos").tag("ok")
                Text("En atención").tag("warn")
                Text("Reparados").tag("fixed")
                Text("Apagados").tag("off")
            }
            .help("Filtra la tabla por estado")
        }
    }
}

// MARK: - Barrios

struct VistaBarrios: View {
    @EnvironmentObject var almacen: Almacen
    @Binding var barrio: String          // "" = toda la villa
    @Binding var seccion: String

    var body: some View {
        if let z = almacen.zonas[barrio] { ampliado(barrio, z) } else { todos }
    }

    private var todos: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                ForEach(almacen.zonas.sorted(by: { $0.value.name < $1.value.name }), id: \.key) { zid, z in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(almacen.agentes.filter { $0.zona == zid }) { a in
                                HStack {
                                    Circle().fill(a.color).frame(width: 8, height: 8).parpadeo(a.enAtencion)
                                    Text(a.nombre)
                                    Spacer()
                                    Text(a.etiquetaEstado).font(.caption).foregroundStyle(a.color).parpadeo(a.enAtencion)
                                }
                                .contentShape(Rectangle()).onTapGesture { almacen.seleccion = a.id }
                            }
                        }
                    } label: {
                        Button { barrio = zid } label: {
                            HStack(spacing: 12) {
                                Image(systemName: iconoBarrio[zid] ?? "building.2").font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
                                    .frame(width: 52, height: 52).background(Circle().fill(Color(hex: z.roof)))
                                    .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 2))
                                Text(z.name).font(.title2.weight(.bold)).foregroundStyle(Color(hex: z.roof))
                            }
                            .padding(.bottom, 4)
                        }
                        .buttonStyle(.plain).help("Ver solo \(z.name), ampliado")
                    }
                }
            }
            .padding(20)
            lugarSeleccionado.padding([.horizontal, .bottom], 20)
        }
    }

    /// Lugar del agente elegido en la villa 3D, en vivo (se puede girar, acercar y desplazar con el mouse).
    @ViewBuilder private var lugarSeleccionado: some View {
        if let a = almacen.seleccionado {
            VStack(alignment: .leading, spacing: 6) {
                Label("Dónde está \(a.nombre) en la villa", systemImage: "scope").font(.headline)
                VistaLugar(almacen: almacen, agente: a.id)
                    .frame(maxWidth: .infinity).frame(height: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(a.color.opacity(0.5), lineWidth: 1))
                    .help("Vista en vivo del lugar de \(a.nombre): arrastra para girar, rueda para acercar")
                HStack {
                    Text("Arrastrar: girar · rueda: acercar · ⌥ arrastrar: desplazar").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        seccion = Seccion.villa.rawValue
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { ControlVilla.shared.coord?.enfocarAgente(a.id) }
                    } label: { Label("Abrir en la villa 3D", systemImage: "building.2.crop.circle") }
                        .help("Abre la villa 3D enfocada en la oficina de \(a.nombre)")
                }
            }
        }
    }

    /// Un solo barrio, en grande: totales por estado y una tarjeta por agente.
    private func ampliado(_ zid: String, _ z: Zona) -> some View {
        let lista = almacen.agentes.filter { $0.zona == zid }
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: iconoBarrio[zid] ?? "building.2.fill").font(.system(size: 40, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 76, height: 76).background(Circle().fill(Color(hex: z.roof)))
                    VStack(alignment: .leading) {
                        Text(z.name).font(.largeTitle.weight(.semibold))
                        Text("\(lista.count) agentes · \(lista.filter { ["warn", "crit"].contains($0.estado) }.count) en atención").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { barrio = "" } label: { Label("Toda la villa", systemImage: "map") }.help("Volver a todos los barrios")
                    Button {
                        seccion = Seccion.villa.rawValue
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { ControlVilla.shared.irBarrio(zid) }
                    } label: { Label("Ver en la villa 3D", systemImage: "building.2.crop.circle") }.help("Abre la villa 3D enfocada en este barrio")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
                    ForEach(lista) { a in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Circle().fill(a.color).frame(width: 12, height: 12).parpadeo(a.enAtencion)
                                Text(a.nombre).font(.title3.weight(.semibold))
                                Spacer()
                                Text(a.etiquetaEstado).font(.callout.weight(.medium)).foregroundStyle(a.color)
                            }
                            Text(a.def.does).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                            if !a.resultado.isEmpty { Text(a.resultado).font(.callout).lineLimit(2) }
                            HStack { Text("Última: \(a.ultima)"); Spacer(); Text("Próxima: \(a.proxima)") }.font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(a.color.opacity(0.5), lineWidth: 1))
                        .contentShape(Rectangle()).onTapGesture { almacen.seleccion = a.id }
                        .help("Ver el detalle de \(a.nombre)")
                    }
                }
                lugarSeleccionado
            }
            .padding(24)
        }
    }
}

// MARK: - Tokens

struct VistaTokens: View {
    @EnvironmentObject var almacen: Almacen
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let r = almacen.resultados["tok"] {
                    Text(r.resumen ?? "").font(.title3.weight(.medium))
                    GroupBox("Tokens por día (millones, entrada nueva + salida)") {
                        Chart(almacen.serieTokens, id: \.fecha) { p in
                            BarMark(x: .value("Día", p.fecha), y: .value("Millones", p.total)).foregroundStyle(.blue.gradient)
                        }
                        .frame(height: 240)
                    }
                    GroupBox("Mayores consumidores (24 h)") {
                        ForEach(r.detalle ?? [], id: \.self) { Text($0).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                    Text("La lectura de caché se informa aparte porque cuesta mucho menos. Los datos los escribe tu propio contador de tokens en resultados/tok.json.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView("Sin datos de tokens", systemImage: "chart.bar", description: Text("El Contador de tokens corre a las 12:00 y 23:50."))
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Respaldos

struct VistaRespaldos: View {
    @EnvironmentObject var almacen: Almacen
    let carpeta = ("~/Respaldos Villa" as NSString).expandingTildeInPath
    var versiones: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: carpeta)) ?? []).filter { $0.hasPrefix("20") }.sorted(by: >)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let r = almacen.resultados["resp"] { Text(r.resumen ?? "").font(.title3.weight(.medium)) }
            if almacen.esLocal {
                List(versiones, id: \.self) { v in
                    HStack {
                        Image(systemName: "archivebox")
                        Text(v.replacingOccurrences(of: "_", with: " · "))
                        Spacer()
                        Button("Abrir en Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: carpeta + "/" + v)) }
                            .help("Abre esta versión del respaldo en el Finder para recuperar un archivo")
                    }
                }
            } else {
                Text("Los respaldos están en el Mac principal (~/Respaldos Villa).").foregroundStyle(.secondary)
            }
            Text("Los respaldos nunca reemplazan tus archivos: para recuperar uno, ábrelo en el Finder y cópialo. Se guardan 30 versiones; lo que no cambió no ocupa espacio extra.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

// MARK: - Detalle

struct DetalleAgente: View {
    @EnvironmentObject var almacen: Almacen
    @State private var registro = ""
    var body: some View {
        if let a = almacen.seleccionado {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(a.nombre).font(.title2.bold())
                        Spacer()
                        Button { almacen.seleccion = nil } label: {
                            Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary).frame(width: 34, height: 34).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).keyboardShortcut(.cancelAction).help("Cerrar el detalle (Esc)")
                    }
                    Label(a.etiquetaEstado, systemImage: "circle.fill").foregroundStyle(a.color)
                    Text(a.def.does)
                    Grid(alignment: .leading, verticalSpacing: 4) {
                        GridRow { Text("Barrio").foregroundStyle(.secondary); Text(almacen.zonas[a.zona]?.name ?? a.zona) }
                        GridRow { Text("Horario").foregroundStyle(.secondary); Text(a.def.sched ?? "—") }
                        GridRow { Text("Última").foregroundStyle(.secondary); Text(a.ultima) }
                        GridRow { Text("Próxima").foregroundStyle(.secondary); Text(a.proxima) }
                        if let s = a.servicio { GridRow { Text("Servicio").foregroundStyle(.secondary); Text(s).font(.caption.monospaced()).textSelection(.enabled) } }
                    }
                    if !a.resultado.isEmpty { GroupBox("Resultado") { Text(a.resultado).frame(maxWidth: .infinity, alignment: .leading) } }
                    if let s = a.vivo?.solucion { GroupBox("Solución propuesta") { Text(s).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) } }
                    if a.id == "opt" { PanelOptimizador(lineas: almacen.resultados["opt"]?.detalle ?? [], local: almacen.esLocal) }
                    HStack {
                        Button { Task { await almacen.ejecutar(a) } } label: { Label("Ejecutar ahora", systemImage: "play.fill") }
                            .disabled(a.servicio == nil).help("Lanza el agente ya, sin esperar su horario")
                        if almacen.esLocal, let r = a.registro {
                            Button { NSWorkspace.shared.open(URL(fileURLWithPath: r)) } label: { Label("Abrir registro", systemImage: "doc.text") }
                                .help("Abre el registro completo en la app Consola o tu editor")
                        }
                    }
                    Lista(titulo: "Qué hace, paso a paso", items: a.def.proc)
                    Lista(titulo: "Pendiente", items: a.def.pend)
                    Lista(titulo: "Archivos", items: a.def.files)
                    GroupBox("Registro reciente") {
                        Text(registro.isEmpty ? "Cargando…" : String(registro.suffix(3000)))
                            .font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let log = a.def.log, !log.isEmpty {
                        GroupBox("Historial") {
                            ForEach(Array(log.enumerated()), id: \.offset) { _, l in
                                HStack(alignment: .top) { Text(l.first ?? "").font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .leading); Text(l.last ?? "").font(.callout) }
                            }
                        }
                    }
                }
                .padding(16)
                .padding(.top, 10)          // la ✕ no queda bajo la barra de título (ahí el clic lo tomaba la ventana)
            }
            .task(id: a.id) { registro = await almacen.registro(a) }
        }
    }
}

struct Lista: View {
    var titulo: String
    var items: [String]?
    var body: some View {
        if let items, !items.isEmpty {
            GroupBox(titulo) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items, id: \.self) { Text("• " + $0).font(.callout).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Ayuda

struct VistaAyuda: View {
    @Environment(\.dismiss) var cerrar
    let temas: [(String, String, String)] = [
        ("building.2.crop.circle", "Villa 3D", "La villa en 3D: cada agente es un personaje distinto (ropa, pelo, estatura y accesorio de su barrio) con su nombre sobre la cabeza. Arrastra para girar, rueda para acercar y haz clic en un personaje para ver su detalle. Los que tienen un problema saludan con los brazos y muestran «!»."),
        ("gauge.with.dots.needle.67percent", "Resumen", "Totales, gráfico por barrio y estado, los agentes que necesitan atención con su solución y lo último que hizo cada uno."),
        ("person.3.sequence", "Agentes", "Tabla ordenable (clic en el título de una columna), con búsqueda y filtro por estado. Clic en una fila para ver el detalle."),
        ("map", "Barrios", "«Toda la villa» muestra todos los barrios; cada barrio de la barra lateral (o su título) lo muestra solo y ampliado, con una tarjeta por agente y el botón «Ver en la villa 3D». Al elegir un agente, abajo aparece en vivo su lugar en la villa (arrastra para girar, rueda para acercar) y «Abrir en la villa 3D» vuela hasta su oficina."),
        ("chart.line.uptrend.xyaxis", "Tokens", "Consumo diario de tokens de Claude y Codex, medido sin IA por el Contador de tokens."),
        ("externaldrive.badge.timemachine", "Respaldos", "Las 30 versiones de tus respaldos nocturnos; ábrelas en el Finder para recuperar un archivo."),
        ("arrow.clockwise", "Revisar ahora (⌘R)", "Revisa ya el estado real de todos los agentes."),
        ("play.fill", "Ejecutar (⌘E)", "Lanza ahora el agente seleccionado, sin esperar su horario. En el otro Mac lo lanza en el Mac principal."),
        ("square.and.arrow.up", "Exportar (⌘P)", "Informe PDF con vista previa antes de guardar, tabla CSV para Excel o compartir el informe."),
        ("gearshape", "Ajustes (⌘,)", "Dirección del Mac principal (para usar la app en el otro Mac) y avisos del sistema."),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ayuda · Villa de Agentes").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(temas, id: \.1) { i, t, d in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: i).frame(width: 24).foregroundStyle(.blue)
                            VStack(alignment: .leading) { Text(t).bold(); Text(d).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            HStack { Spacer(); Button("Cerrar") { cerrar() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(width: 560, height: 560)
    }
}

// MARK: - Ajustes

struct VistaAjustes: View {
    @EnvironmentObject var almacen: Almacen
    var body: some View {
        Form {
            Section("Origen de los datos") {
                LabeledContent("Ahora", value: almacen.fuente)
                TextField("Servidor remoto (opcional)", text: almacen.$servidor)
                    .help("Opcional: dirección de otro Mac que sirve agentes.json y estado.json; vacío = datos de este Mac")
            }
            Section("Avisos") {
                Toggle("Notificar cuando un agente pase a «Atención»", isOn: almacen.$notificar)
                    .help("Aviso del sistema cuando algún agente cambia a Atención o se recupera")
            }
        }
        .formStyle(.grouped).frame(width: 480).padding()
    }
}

// MARK: - Parpadeo: lo que requiere revisión late cambiando de color (naranja ↔ rojo) y de tamaño.

struct Parpadeo: ViewModifier {
    let activo: Bool
    // Pulso calculado por reloj (no con withAnimation…repeatForever): esa animación infinita contagiaba a la villa y
    // a la barra de botones, que titilaban mientras hubiera agentes con advertencia.
    func body(content: Content) -> some View {
        if activo {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { ctx in
                let f = 0.5 + 0.5 * sin(ctx.date.timeIntervalSinceReferenceDate * .pi / 0.55)
                content
                    .foregroundStyle(f > 0.5 ? Color.red : Color.orange)
                    .scaleEffect(0.92 + 0.30 * f)
                    .opacity(0.65 + 0.35 * f)
            }
        } else {
            content
        }
    }
}

extension View {
    func parpadeo(_ activo: Bool) -> some View { modifier(Parpadeo(activo: activo)) }
}

// MARK: - Optimizador del Mac: cada recomendación con su botón «Resolver» y gráfico del historial

struct PanelOptimizador: View {
    var lineas: [String]
    var local: Bool
    @State private var historial: [PuntoOpt] = []
    @State private var medida = "Disco libre"
    @State private var aviso: String?
    private let medidas = ["Disco libre", "Swap", "Memoria libre", "Recuperable"]

    struct PuntoOpt: Decodable, Identifiable {
        var t: Double; var libre: Double?; var swap: Double?; var disco: Double?; var recuperable: Double?
        var id: Double { t }
        var fecha: Date { Date(timeIntervalSince1970: t) }
    }

    /// Acción concreta para cada recomendación. Nada se borra desde aquí: solo abre la herramienta adecuada.
    private func accion(_ l: String) -> (titulo: String, ayuda: String, hacer: () -> Void)? {
        func app(_ ruta: String) { NSWorkspace.shared.open(URL(fileURLWithPath: ruta)) }
        func ajustes(_ id: String) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:" + id)!) }
        if l.contains("swap") || l.contains("Procesos pesados") || l.contains("Memoria") {
            return ("Ver procesos", "Abre el Monitor de Actividad para ver qué consume memoria y CPU", {
                app("/System/Applications/Utilities/Activity Monitor.app")
            })
        }
        if l.contains("Homebrew") {
            return ("Copiar «brew upgrade»", "Copia el comando para que lo pegues en Terminal cuando quieras (no se ejecuta solo)", {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString("brew upgrade", forType: .string)
                aviso = "Copiado: pégalo en Terminal cuando decidas actualizar."
            })
        }
        if l.contains("recuperables") || l.contains("cachés") {
            return ("Almacenamiento", "Abre Ajustes → Almacenamiento para revisar qué ocupa espacio", { ajustes("com.apple.settings.Storage") })
        }
        if l.contains("simuladores") {
            return ("Abrir Xcode", "En Xcode: Window → Devices and Simulators, borra los simuladores que no uses", { app("/Applications/Xcode.app") })
        }
        if l.contains("Descargas") {
            return ("Abrir Descargas", "Muestra la carpeta Descargas en Finder", { app(NSHomeDirectory() + "/Downloads") })
        }
        if l.contains("macOS") || l.contains("actualizaci") {
            return ("Actualización de software", "Abre Ajustes → General → Actualización de software", { ajustes("com.apple.Software-Update-Settings.extension") })
        }
        if l.contains("inicio") {
            return ("Ítems de inicio", "Abre Ajustes → General → Ítems de inicio", { ajustes("com.apple.LoginItems-Settings.extension") })
        }
        if l.contains("Batería") || l.contains("batería") {
            return ("Ajustes de batería", "Abre Ajustes → Batería", { ajustes("com.apple.Battery-Settings.extension") })
        }
        return nil
    }

    private func valor(_ p: PuntoOpt) -> Double? {
        switch medida {
        case "Swap": return p.swap
        case "Memoria libre": return p.libre
        case "Recuperable": return p.recuperable
        default: return p.disco
        }
    }
    private var unidad: String { medida == "Memoria libre" ? "%" : "GB" }

    var body: some View {
        let recomendaciones = lineas.filter { $0.hasPrefix("💡") || $0.hasPrefix("⚠️") }
        GroupBox("Recomendaciones del Optimizador") {
            VStack(alignment: .leading, spacing: 8) {
                if recomendaciones.isEmpty { Text("Sin recomendaciones: el Mac está optimizado.").foregroundStyle(.secondary) }
                ForEach(recomendaciones, id: \.self) { l in
                    HStack(alignment: .top) {
                        Text(l).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                        if let ac = accion(l) {
                            Button(ac.titulo) { ac.hacer() }.controlSize(.small).help(ac.ayuda)
                        }
                    }
                }
                if let aviso { Text(aviso).font(.caption).foregroundStyle(.green) }
            }
        }
        if local {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Gráfico", selection: $medida) { ForEach(medidas, id: \.self) { Text($0) } }
                        .pickerStyle(.segmented).labelsHidden().help("Elige qué mostrar en el gráfico")
                    let datos = historial.filter { valor($0) != nil }
                    if datos.count < 2 {
                        Text("El historial se arma con cada revisión (cada hora); vuelve más tarde.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Chart(datos) { p in
                            LineMark(x: .value("Fecha", p.fecha), y: .value(medida, valor(p) ?? 0)).interpolationMethod(.monotone)
                        }
                        .chartYAxisLabel(unidad)
                        .frame(height: 140)
                    }
                }
            } label: { Text("Historial (\(medida.lowercased()))") }
            .task {
                let ruta = Almacen.carpetaLocal + "/trabajo/optimizador-historial.json"
                if let d = FileManager.default.contents(atPath: ruta), let h = try? JSONDecoder().decode([PuntoOpt].self, from: d) {
                    historial = h.filter { $0.t > Date().timeIntervalSince1970 - 30 * 86400 }
                }
            }
        }
    }
}

// MARK: - Vista del lugar (Barrios)

/// Segunda ventana a la misma villa viva, con su propia cámara apuntando a la oficina del agente elegido.
struct VistaLugar: NSViewRepresentable {
    @ObservedObject var almacen: Almacen
    let agente: String

    final class Enlace: NSObject {
        var link: CADisplayLink?
        var camara = SCNNode()
        var agente = ""
        weak var villa: Villa3D.Coordinador?
        @objc func paso(_ e: CADisplayLink) { MainActor.assumeIsolated { villa?.tick(e) } }   // la villa sigue andando
    }

    func makeCoordinator() -> Enlace { Enlace() }

    func makeNSView(context: Context) -> SCNView {
        let villa = ControlVilla.shared.villaViva(almacen)
        villa.sincronizar()
        let e = context.coordinator
        e.villa = villa
        let c = SCNCamera(); c.zNear = 0.3; c.zFar = 700; c.fieldOfView = 50
        e.camara.camera = c; e.camara.name = "camara-lugar"
        villa.escena.rootNode.addChildNode(e.camara)
        let v = SCNView()
        v.scene = villa.escena
        v.pointOfView = e.camara
        v.allowsCameraControl = true
        v.antialiasingMode = .multisampling2X
        v.preferredFramesPerSecond = 30
        v.isPlaying = true
        let l = v.displayLink(target: e, selector: #selector(Enlace.paso(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        l.add(to: .main, forMode: .common); e.link = l
        apuntar(v, e)
        return v
    }

    func updateNSView(_ v: SCNView, context: Context) {
        if context.coordinator.agente != agente { apuntar(v, context.coordinator) }
    }

    private func apuntar(_ v: SCNView, _ e: Enlace) {
        e.agente = agente
        guard let villa = e.villa, let (ojo, mira) = villa.vistaLugar(agente) else { return }
        v.defaultCameraController.stopInertia()
        v.pointOfView = e.camara
        e.camara.position = ojo
        e.camara.look(at: mira, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))   // horizonte siempre derecho
        v.defaultCameraController.worldUp = SCNVector3(0, 1, 0)
        v.defaultCameraController.target = mira
    }

    static func dismantleNSView(_ v: SCNView, coordinator e: Enlace) {
        e.link?.invalidate(); e.link = nil
        e.camara.removeFromParentNode()
    }
}
