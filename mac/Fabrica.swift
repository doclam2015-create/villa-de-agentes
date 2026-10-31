import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

// MARK: - Catálogo de la Fábrica de Ensamblaje (Villa Industrial)
//
// Lee el inventario que deja el agente fabrica.py (trabajo/fabrica-catalogo.json): todas las apps propias de Mac e iOS
// con descripción, utilidad, ubicación, versión y su RESUMEN APP. Búsqueda, filtros, tabla ordenable y detalle con
// accesos para abrir la app, mostrarla en el Finder, abrir el proyecto o el resumen, y exportar a CSV. Solo lectura.

struct ProductoFabrica: Identifiable, Hashable {
    var id: String { nombre }
    var nombre, original, plataforma, linea, utilidad, descripcion, app, proyecto, xcode, bundle, version, actualizada, resumen, estado: String
    var t: Double
    var ubicacion: String { app.isEmpty ? (xcode.isEmpty ? proyecto : xcode) : app }

    static func cargar() -> (apps: [ProductoFabrica], lineas: [String], generado: Date?) {
        let ruta = Almacen.carpetaLocal + "/trabajo/fabrica-catalogo.json"
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: ruta)),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return ([], [], nil) }
        let apps = (j["apps"] as? [[String: Any]] ?? []).map { a in
            func s(_ k: String) -> String { a[k] as? String ?? "" }
            return ProductoFabrica(nombre: s("nombre"), original: s("original"), plataforma: s("plataforma"), linea: s("linea"), utilidad: s("utilidad"), descripcion: s("descripcion"),
                                   app: s("app"), proyecto: s("proyecto"), xcode: s("xcode"), bundle: s("bundle"), version: s("version"),
                                   actualizada: s("actualizada"), resumen: s("resumen"), estado: s("estado"), t: a["t"] as? Double ?? 0)
        }
        return (apps, j["lineas"] as? [String] ?? [], (j["t"] as? Double).map { Date(timeIntervalSince1970: $0) })
    }
}

struct PanelFabrica: View {
    @ObservedObject var c = ControlVilla.shared
    @State private var apps: [ProductoFabrica] = []
    @State private var lineas: [String] = []
    @State private var generado: Date?
    @State private var buscar = ""
    @State private var plataforma = "Todas"
    @State private var linea = "Todas"
    @State private var orden = [KeyPathComparator(\ProductoFabrica.nombre)]
    @State private var seleccion: ProductoFabrica.ID?
    @State private var ayuda = false
    private let reloj = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var filtradas: [ProductoFabrica] {
        apps.filter { a in
            (plataforma == "Todas" || a.plataforma.contains(plataforma)) && (linea == "Todas" || a.linea == linea) &&
            (buscar.isEmpty || [a.nombre, a.original, a.utilidad, a.descripcion, a.linea, a.ubicacion].contains { $0.localizedCaseInsensitiveContains(buscar) })
        }.sorted(using: orden)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Catálogo de la Fábrica · Villa Industrial", systemImage: "shippingbox.fill").font(.headline)
                Spacer()
                Button { ayuda.toggle() } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.plain).help("Ayuda: qué hace cada botón de este panel")
                    .popover(isPresented: $ayuda) { textoAyuda.padding(14).frame(width: 360) }
                Button { cargar() } label: { Label("Actualizar", systemImage: "arrow.clockwise") }
                    .help("Vuelve a leer el catálogo que deja el agente Fábrica de Ensamblaje")
                Button { exportarCSV() } label: { Label("CSV", systemImage: "square.and.arrow.up") }
                    .help("Exporta las apps que se ven (con sus filtros) a un archivo CSV para Excel")
                Button { c.elemento = nil; c.verFabrica = false; c.irBarrio("industrial") } label: { Label("Ver la isla", systemImage: "scope") }
                    .help("Vuela a la Villa Industrial")
                Button { c.verFabrica = false } label: {
                    Label("Cerrar", systemImage: "xmark.circle.fill").font(.callout.bold())
                }
                .keyboardShortcut(.cancelAction).help("Cerrar el catálogo (Esc)")
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
            HStack(spacing: 8) {
                TextField("Buscar app, utilidad o ubicación", text: $buscar).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                    .help("Filtra por nombre, app original, utilidad, descripción, línea o ubicación")
                Picker("Plataforma", selection: $plataforma) { ForEach(["Todas", "Mac", "iOS"], id: \.self) { Text($0) } }
                    .pickerStyle(.segmented).frame(width: 210).help("Muestra solo las apps de Mac, solo las de iOS o todas")
                Picker("Línea", selection: $linea) { ForEach(["Todas"] + lineas, id: \.self) { Text($0) } }
                    .frame(width: 280).help("Línea de ensamblaje (familia de apps)")
                Spacer()
                Text("\(filtradas.count) de \(apps.count) · \(apps.filter { $0.plataforma.contains("Mac") }.count) Mac · \(apps.filter { $0.plataforma.contains("iOS") }.count) iOS")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.bottom, 8)
            if apps.isEmpty {
                ContentUnavailableView("Sin catálogo todavía", systemImage: "shippingbox",
                                       description: Text("El agente Fábrica de Ensamblaje aún no corre. Instálalo con instalar-villa-industrial.command."))
                    .frame(maxHeight: .infinity)
            } else {
                HSplitView {
                    Table(filtradas, selection: $seleccion, sortOrder: $orden) {
                        TableColumn("App", value: \.nombre) { a in
                            Label(a.nombre, systemImage: a.plataforma == "iOS" ? "iphone" : a.plataforma.contains("iOS") ? "laptopcomputer.and.iphone" : "desktopcomputer")
                        }.width(min: 150, ideal: 190)
                        TableColumn("App original", value: \.original) { a in Text(a.original.isEmpty ? "—" : a.original).foregroundStyle(a.original.isEmpty ? .secondary : .primary) }.width(min: 90, ideal: 130)
                        TableColumn("Plataforma", value: \.plataforma).width(80)
                        TableColumn("Línea", value: \.linea).width(min: 120, ideal: 170)
                        TableColumn("Utilidad", value: \.utilidad).width(min: 180, ideal: 300)
                        TableColumn("Versión", value: \.version).width(55)
                        TableColumn("Actualizada", value: \.t) { a in Text(a.actualizada) }.width(110)
                        TableColumn("Estado", value: \.estado).width(95)
                    }
                    .frame(minWidth: 560)
                    detalle.frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
                }
                .frame(minHeight: 360)
                lineasChart.padding(.horizontal, 14).padding(.vertical, 8)
            }
            if let g = generado {
                Text("Inventario del agente: \(g.formatted(date: .abbreviated, time: .shortened)) · se actualiza solo al instalar apps y cada hora")
                    .font(.caption2).foregroundStyle(.tertiary).padding(.bottom, 8)
            }
        }
        .onAppear { cargar() }
        .onReceive(reloj) { _ in cargar() }
    }

    /// Productos por línea de ensamblaje: clic en una barra filtra por esa línea.
    private var lineasChart: some View {
        let cuentas = lineas.map { l in (l, apps.filter { $0.linea == l }.count) }.filter { $0.1 > 0 }
        let maximo = max(1, cuentas.map(\.1).max() ?? 1)
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(cuentas, id: \.0) { l, n in
                Button { linea = linea == l ? "Todas" : l } label: {
                    VStack(spacing: 2) {
                        Text("\(n)").font(.caption2.bold())
                        RoundedRectangle(cornerRadius: 3).fill(linea == l ? Color.orange : Color.orange.opacity(0.45))
                            .frame(height: CGFloat(n) / CGFloat(maximo) * 46 + 4)
                        Text(l).font(.system(size: 9)).lineLimit(2).multilineTextAlignment(.center).frame(height: 24)
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain).help("Filtrar por la línea «\(l)» (otro clic quita el filtro)")
            }
        }
        .frame(height: 90)
    }

    @ViewBuilder private var detalle: some View {
        if let id = seleccion, let a = apps.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        if !a.app.isEmpty { Image(nsImage: NSWorkspace.shared.icon(forFile: a.app)).resizable().frame(width: 52, height: 52) }
                        else { Image(systemName: "iphone").font(.system(size: 34)).frame(width: 52, height: 52) }
                        VStack(alignment: .leading) {
                            Text(a.nombre).font(.title3.bold())
                            Text("\(a.plataforma) · \(a.linea)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !a.original.isEmpty { campo("App original (clon o inspiración)", a.original) }
                    campo("Descripción", a.descripcion)
                    campo("Utilidad", a.utilidad)
                    campo("Ubicación", a.ubicacion.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    if !a.proyecto.isEmpty && a.proyecto != a.ubicacion { campo("Proyecto", a.proyecto.replacingOccurrences(of: NSHomeDirectory(), with: "~")) }
                    campo("Estado", a.estado + (a.version.isEmpty ? "" : " · versión \(a.version)") + (a.actualizada.isEmpty ? "" : " · \(a.actualizada)"))
                    if !a.bundle.isEmpty { campo("Identificador", a.bundle) }
                    HStack {
                        Button("Abrir") { NSWorkspace.shared.open(URL(fileURLWithPath: a.app)) }.disabled(a.app.isEmpty)
                            .help("Abre la app en este Mac")
                        Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: a.ubicacion)]) }
                            .disabled(a.ubicacion.isEmpty).help("Muestra la app o su proyecto en el Finder")
                    }
                    HStack {
                        Button("Proyecto") { NSWorkspace.shared.open(URL(fileURLWithPath: a.xcode.isEmpty ? a.proyecto : a.xcode)) }
                            .disabled(a.proyecto.isEmpty && a.xcode.isEmpty).help("Abre el proyecto (Xcode para las apps iOS, carpeta para las de Mac)")
                        Button("Resumen") { NSWorkspace.shared.open(URL(fileURLWithPath: a.resumen)) }
                            .disabled(a.resumen.isEmpty).help("Abre su RESUMEN APP con la ficha técnica completa")
                    }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Elige una app", systemImage: "hand.tap", description: Text("Clic en una fila para ver su descripción, ubicación y utilidad."))
        }
    }

    private func campo(_ t: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.caption.bold()).foregroundStyle(.secondary)
            Text(v.isEmpty ? "—" : v).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var textoAyuda: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Catálogo de la Fábrica").font(.headline)
            Text("• Buscar: filtra por nombre, app original, utilidad, descripción, línea o ubicación.")
            Text("• Plataforma: Mac, iOS o todas. Línea: familia de apps.")
            Text("• Tabla: clic en un encabezado para ordenar; clic en una fila para ver el detalle.")
            Text("• Abrir / Mostrar en Finder / Proyecto / Resumen: accesos de la app elegida.")
            Text("• Barras de abajo: apps por línea; clic para filtrar.")
            Text("• Actualizar relee el catálogo; CSV exporta lo que ves; Ver la isla vuela a la Villa Industrial.")
            Text("El agente Fábrica de Ensamblaje actualiza el catálogo solo, al instalar una app y cada hora. Nunca mueve ni borra nada.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private func cargar() {
        let r = ProductoFabrica.cargar()
        apps = r.apps; lineas = r.lineas; generado = r.generado
    }

    private func exportarCSV() {
        let p = NSSavePanel(); p.allowedContentTypes = [.commaSeparatedText]; p.nameFieldStringValue = "Catálogo de apps.csv"
        guard p.runModal() == .OK, let url = p.url else { return }
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var t = "App;App original;Plataforma;Línea;Utilidad;Descripción;Ubicación;Versión;Actualizada;Estado\n"
        for a in filtradas { t += [a.nombre, a.original, a.plataforma, a.linea, a.utilidad, a.descripcion, a.ubicacion, a.version, a.actualizada, a.estado].map(q).joined(separator: ";") + "\n" }
        try? ("\u{FEFF}" + t).write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
