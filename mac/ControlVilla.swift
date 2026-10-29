import SwiftUI
import AppKit
import SceneKit

/// Mando de la villa 3D (equivale a los botones de la villa web): agentes, sede de gobierno con
/// audiencia, recorrido, vista general, tema, reiniciar, barrios y pizarras.
@MainActor
final class ControlVilla: ObservableObject {
    static let shared = ControlVilla()
    weak var coord: Villa3D.Coordinador?
    /// La villa se construye una sola vez y queda viva: entrar a la villa 3D es instantáneo y Barrios puede mostrar el lugar de un agente.
    var coordVivo: Villa3D.Coordinador?
    func villaViva(_ almacen: Almacen) -> Villa3D.Coordinador {
        if let c = coordVivo { return c }
        let c = Villa3D.Coordinador(almacen: almacen); coordVivo = c; return c
    }
    @Published var audiencia: String?
    @Published var pizarra: String?
    @Published var verAgentes = false
    @Published var verSede = false
    @Published var recorrido = false
    @Published var tema = "auto"
    @Published var revisando = false
    @Published var aviso: String?
    @Published var dentro: String?          // oficina en la que está la cámara
    @Published var elemento: String?        // helicóptero, garita, guardia, vehículo… con su reporte
    @Published var verAudiencia = false     // conversación con IA en el despacho
    @Published var verCentro = false        // Centro de mando: salud, recursos, seguridad y alarma
    /// Plano de la villa: aparece solo abajo a la izquierda y se pliega a una pestaña (se recuerda entre sesiones).
    @Published var verPlano = (UserDefaults.standard.object(forKey: "verPlano") as? Bool) ?? true { didSet { UserDefaults.standard.set(verPlano, forKey: "verPlano") } }
    @Published var planoAbierto = (UserDefaults.standard.object(forKey: "planoAbierto") as? Bool) ?? true { didSet { UserDefaults.standard.set(planoAbierto, forKey: "planoAbierto") } }
    @Published var directorio: String?      // pizarra de un edificio (sus agentes), abierta abajo a la derecha
    @Published var pantallaCompleta = false   // la villa ocupa toda la pantalla, sin barra lateral
    @Published var pausada = false          // «solo panel»: la villa 3D detenida a pedido
    @Published var verMetro = false         // panel Metro: vistas del circuito del tren y de los accesos de las estaciones
    @Published var metroModo = "arriba"
    @Published var metroAng: CGFloat = 0
    @Published var metroVuelta = false
    private var relojMetro: Timer?
    @Published var dormida = false          // pausa automática tras 10 min sin tocar la villa
    private var reloj: Timer?
    private var almacen: Almacen? { coord?.almacen }

    func seleccionar(_ id: String) {
        verSede = false; elemento = nil; directorio = nil
        if dentro == id { pizarra = id; return }          // clic adentro de su propia oficina: se queda adentro
        dentro = nil
        if almacen?.seleccion == id { pizarra = id; coord?.enfocarAgente(id) } else { almacen?.seleccion = id }
    }

    /// Clic en una oficina: la primera vez, su pizarra y vista frontal; otra vez (ya de frente), entra a la oficina.
    func clicOficina(_ id: String) {
        if almacen?.seleccion == id && dentro == nil { pizarra = id; entrar(id) } else { seleccionar(id) }
    }

    /// Pantalla completa del sistema; al entrar o salir (botón, ⌃⌘F, Esc o botón verde) se oculta o vuelve la barra lateral.
    func alternarPantallaCompleta() {
        (NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain })?.toggleFullScreen(nil)
    }
    private var observadores: [Any] = []
    private init() {
        for (n, v) in [(NSWindow.didEnterFullScreenNotification, true), (NSWindow.didExitFullScreenNotification, false)] {
            observadores.append(NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ControlVilla.shared.pantallaCompleta = v }
            })
        }
    }

    func alternarPausa() { pausada.toggle(); dormida = false; coord?.tocado(); coord?.ajustarRitmo() }
    func despertar() { guard dormida else { return }; dormida = false; coord?.ajustarRitmo() }

    func mostrarElemento(_ e: String) { pizarra = nil; directorio = nil; almacen?.seleccion = nil; elemento = e }

    /// Clic en la pizarra de un edificio: la muestra legible abajo a la derecha, con acceso a cada agente.
    func abrirDirectorio(_ zid: String) { pizarra = nil; elemento = nil; almacen?.seleccion = nil; directorio = zid }
    func irAgente(_ id: String) { directorio = nil; seleccionar(id) }

    func cerrarPizarra() { pizarra = nil; almacen?.seleccion = nil; dentro = nil }

    var entradaEn = Date.distantPast        // evita que el mismo clic (o su eco) que entra, saque de inmediato
    func entrar(_ id: String) { detenerRecorrido(); dentro = id; entradaEn = Date(); coord?.entrarOficina(id) }

    func salir() {
        guard let id = dentro else { return }
        dentro = nil; coord?.enfocarAgente(id)
    }

    func llamar(_ id: String) {
        guard let a = almacen?.agentes.first(where: { $0.id == id }), a.estado != "off" else { return }
        detenerRecorrido()
        if let otro = audiencia, otro != id { coord?.despedir(otro) }
        audiencia = id
        verAudiencia = true
        coord?.llamar(id)
        coord?.enfocarSede()
    }

    func despedir() {
        guard let id = audiencia else { return }
        coord?.despedir(id)
        audiencia = nil
    }

    func irBarrio(_ zid: String) {
        if zid == "sede" { abrirSede(); return }
        detenerRecorrido(); verSede = false; dentro = nil
        // La tarjeta abierta corresponde al lugar al que se va (antes quedaba la del último elemento, p. ej. el portaaviones)
        let tarjeta: [String: String] = ["fach": "fach", "armada": "armada", "ejercito": "ejercito", "comisaria": "comisaria", "gobmar": "gobmar",
                                         "defensa": "ministerio", "aeropuerto": "aeropuerto", "energia": "energia"]
        if let t = tarjeta[zid] { mostrarElemento(t) } else { elemento = nil }
        coord?.irBarrio(zid)
    }

    func abrirSede() { detenerRecorrido(); dentro = nil; elemento = nil; verSede = true; verAgentes = false; coord?.enfocarSede() }

    func general() {
        detenerRecorrido(); verSede = false; pizarra = nil; dentro = nil; elemento = nil
        almacen?.seleccion = nil
        coord?.vistaGeneral()
    }

    /// Vista del metro: exterior/interior en el rumbo actual, desde arriba, o la torre de acceso `k`.
    func vistaMetro(_ modo: String, k: Int = 0) {
        detenerRecorrido(); verSede = false; dentro = nil; metroModo = modo
        if modo == "estacion" { mostrarElemento("metro-" + MetroVilla.estaciones[k].id) } else { elemento = nil }
        coord?.vistaMetro(modo, a: metroAng, k: k)
    }
    /// Gira la vista exterior o interior alrededor del circuito (paso en grados).
    func girarMetro(_ grados: CGFloat) {
        metroAng += grados * .pi / 180
        if metroModo != "exterior" && metroModo != "interior" { metroModo = "exterior" }
        coord?.vistaMetro(metroModo, a: metroAng, k: 0)
    }
    /// Vuelta completa automática: avanza 15° cada 2,5 s por fuera o por dentro del circuito.
    func alternarVueltaMetro() {
        relojMetro?.invalidate(); relojMetro = nil
        metroVuelta.toggle()
        guard metroVuelta else { return }
        girarMetro(0)
        relojMetro = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { guard let s = self, s.verMetro else { self?.relojMetro?.invalidate(); self?.metroVuelta = false; return }; s.girarMetro(15) }
        }
    }

    func alternarRecorrido() { recorrido ? detenerRecorrido() : iniciarRecorrido() }

    private func iniciarRecorrido() {
        guard let al = almacen else { return }
        let orden = ["crit": 0, "warn": 1, "fixed": 2, "ok": 3, "off": 4]
        let ids = al.agentes.sorted { (orden[$0.estado] ?? 5, $0.nombre) < (orden[$1.estado] ?? 5, $1.nombre) }.map(\.id)
        guard !ids.isEmpty else { return }
        recorrido = true; verSede = false
        var i = 0
        let paso = { [weak self] in self?.seleccionar(ids[i % ids.count]); i += 1 }
        paso()
        reloj = Timer.scheduledTimer(withTimeInterval: 5.5, repeats: true) { _ in MainActor.assumeIsolated { paso() } }
    }

    func detenerRecorrido() { reloj?.invalidate(); reloj = nil; recorrido = false }

    func cambiarTema() {
        tema = ["auto": "claro", "claro": "oscuro", "oscuro": "auto"][tema] ?? "auto"
        coord?.tema = tema
        coord?.refrescarCielo()
    }

    var nombreTema: String { ["auto": "Automático", "claro": "Claro", "oscuro": "Oscuro"][tema] ?? tema }

    func reiniciar() {
        guard let al = almacen else { return }
        detenerRecorrido(); revisando = true
        Task {
            await al.revisar()
            coord?.reiniciar()
            audiencia = nil; revisando = false
        }
    }

    /// Informe opcional que puede servir un servidor local de la villa (http://127.0.0.1:8790/reporte).
    func informe(dias: Int?) {
        aviso = "Preparando el informe…"
        let base = "http://127.0.0.1:8790"
        var req = URLRequest(url: URL(string: base + "/reporte")!)
        req.httpMethod = "POST"
        req.setValue(base, forHTTPHeaderField: "Origin")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["dias": dias as Any])
        req.timeoutInterval = 90
        Task {
            do {
                let (d, _) = try await URLSession.shared.data(for: req)
                let j = try JSONSerialization.jsonObject(with: d) as? [String: Any]
                if let u = j?["url"] as? String, let url = URL(string: base + u) {
                    NSWorkspace.shared.open(url); aviso = "Informe listo ✓ (se abrió en el navegador)."
                } else { aviso = "No se pudo preparar el informe." }
            } catch { aviso = "No se pudo preparar el informe: la villa local no responde." }
        }
    }
}

// MARK: - Vistas del mando

struct MandoVilla: View {
    @EnvironmentObject var almacen: Almacen
    @ObservedObject var c = ControlVilla.shared
    @ObservedObject var alarma = AlarmaVilla.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            if c.verPlano {         // plano siempre a mano, abajo a la izquierda (sobre la línea de ayuda)
                VStack { Spacer(); HStack { VistaPlano(); Spacer() } }.padding(.bottom, 34)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            VStack(alignment: .leading, spacing: 10) {
                barra
                HStack(alignment: .top, spacing: 10) {
                    if c.verAgentes { PanelAgentes().transition(.move(edge: .leading).combined(with: .opacity)) }
                    if c.verSede { PanelSede().transition(.move(edge: .leading).combined(with: .opacity)) }
                    if c.verMetro { PanelMetro().transition(.move(edge: .leading).combined(with: .opacity)) }
                }
                if c.verCentro {
                    VStack(spacing: 0) {
                        // Barra propia con botón Cerrar, siempre visible (no queda bajo los controles de cámara ni la alarma)
                        HStack {
                            Label("Centro de mando", systemImage: "gauge.with.dots.needle.bottom.50percent").font(.headline)
                            Spacer()
                            Button { c.verCentro = false } label: {
                                Label("Cerrar", systemImage: "xmark.circle.fill").font(.callout.bold())
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(.quaternary, in: Capsule()).contentShape(Capsule())
                            }
                            .buttonStyle(.plain).keyboardShortcut(.cancelAction).help("Cerrar el centro de mando (Esc)")
                        }
                        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 2)
                        ScrollView { CentroMando(defensa: c.coord?.defensaTexto ?? []) }
                    }
                        .frame(maxHeight: 600)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .padding(.trailing, 40)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottomTrailing) {
            if let e = c.elemento { TarjetaElemento(e: e).padding(14) }
            else if let z = c.directorio { TarjetaDirectorio(zid: z).padding(14) }
            else if let id = c.pizarra, let a = almacen.agentes.first(where: { $0.id == id }) { TarjetaPizarra(a: a).padding(14) }
        }
        // Elegir un agente (barra lateral, centro de mando, tablas) cierra la tarjeta del buque o vehículo anterior
        .onChange(of: almacen.seleccion) { _, s in if s != nil { c.elemento = nil; c.directorio = nil } }
        .overlay(alignment: .bottomLeading) {
            if c.verAudiencia { PanelAudiencia().padding(.horizontal, 14).padding(.bottom, 34).transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .overlay {
            if c.pausada || c.dormida {
                Button { c.pausada ? c.alternarPausa() : c.coord?.tocado() } label: {
                    Label(c.pausada ? "Villa en pausa · clic para reanudar" : "En reposo para ahorrar energía · clic para continuar", systemImage: "pause.circle.fill")
                        .font(.headline).padding(.horizontal, 18).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                }
                .buttonStyle(.plain).help("La villa 3D está detenida; los datos de los agentes y los avisos siguen actualizándose")
            }
        }
        // Alarma visual: borde rojo sobre la villa (late si hay un problema nuevo) y aviso con acceso al centro de mando
        .overlay {
            if alarma.activa {
                // Pulso por reloj, aislado: no anima nada más de la pantalla
                TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !alarma.nuevos)) { ctx in
                    let f = 0.5 + 0.5 * sin(ctx.date.timeIntervalSinceReferenceDate * .pi / 0.55)
                    RoundedRectangle(cornerRadius: 4).stroke(Color.red.opacity(alarma.nuevos ? 0.25 + 0.7 * f : 0.45), lineWidth: alarma.nuevos ? 7 : 3)
                }
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            if alarma.activa && !c.verCentro {
                Button { c.verCentro = true; alarma.reconocer() } label: {
                    Label("Alarma: \(alarma.problemas.first ?? "")\(alarma.problemas.count > 1 ? " y \(alarma.problemas.count - 1) más" : "") · ver centro de mando",
                          systemImage: "light.beacon.max.fill")
                        .font(.callout.bold()).foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Color.red.opacity(alarma.nuevos ? 0.9 : 0.7), in: Capsule())
                }
                .buttonStyle(.plain).padding(.top, 56).help("Abre el centro de mando con el detalle y los recursos para resolverlo")
            }
        }
        .animation(.easeOut(duration: 0.2), value: c.elemento)
        .animation(.easeOut(duration: 0.2), value: c.verCentro)
        .animation(.easeOut(duration: 0.2), value: c.verAudiencia)
        .animation(.easeOut(duration: 0.2), value: c.verAgentes)
        .animation(.easeOut(duration: 0.2), value: c.verSede)
        .animation(.easeOut(duration: 0.2), value: c.pizarra)
        .animation(.easeOut(duration: 0.2), value: c.directorio)
    }

    private var barra: some View {
        HStack(spacing: 6) {
            if c.dentro != nil {
                boton("Salir del edificio", "door.left.hand.open", true, "Sale de la oficina y vuelve a la vista frontal (Esc)") { c.salir() }
            }
            boton(c.verCentro ? "Cerrar centro de mando" : "Centro de mando", "gauge.with.dots.needle.bottom.50percent", c.verCentro,
                  "Salud de todos los agentes, recursos del Mac, seguridad, alarma y accesos a seguridad, Optimizador y almacenamiento") {
                c.verCentro.toggle(); if c.verCentro { c.verAgentes = false; c.verSede = false; alarma.reconocer() }
            }
            boton(c.verAgentes ? "Ocultar agentes" : "Agentes", "person.3", c.verAgentes, "Lista de agentes y barrios: clic para ir a cada uno") {
                c.verAgentes.toggle(); if c.verAgentes { c.verSede = false }
            }
            boton("Sede de gobierno", "building.columns", c.verSede, "Despacho del Alcalde: llamar agentes a la audiencia y despedirlos") {
                c.verSede ? (c.verSede = false) : c.abrirSede()
            }
            boton(c.recorrido ? "Detener" : "Recorrido", c.recorrido ? "stop.fill" : "play.fill", c.recorrido, "Visita uno a uno a los agentes, primero los que necesitan atención") { c.alternarRecorrido() }
            boton("Vista general", "scope", false, "Vuelve a ver toda la villa (⌘0)") { c.general() }
            boton(c.verPlano ? "Ocultar plano" : "Plano", "map", c.verPlano, "Plano de la villa (abajo a la izquierda): clic en un lugar para ir directo") { c.verPlano.toggle(); if c.verPlano { c.planoAbierto = true } }
            boton(c.pantallaCompleta ? "Salir de pantalla completa" : "Pantalla completa", c.pantallaCompleta ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                  c.pantallaCompleta, "Muestra la villa en toda la pantalla, sin barra lateral (⌃⌘F). Esc o este botón para volver") { c.alternarPantallaCompleta() }
            boton(c.pausada ? "Reanudar" : "Pausar", c.pausada ? "play.circle" : "pause.circle", c.pausada,
                  "Pausar detiene la animación 3D para ahorrar batería y CPU (los datos y avisos siguen al día)") { c.alternarPausa() }
            boton("◐ " + c.nombreTema, "circle.lefthalf.filled", false, "Automático sigue la hora del Mac; Claro fuerza el día; Oscuro fuerza la noche") { c.cambiarTema() }
            boton(c.revisando ? "Revisando…" : "Reiniciar", "arrow.clockwise", false, "Revisa el estado real de los agentes y los devuelve a su escritorio") { c.reiniciar() }
                .disabled(c.revisando)
        }
        .padding(5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func boton(_ t: String, _ icono: String, _ activo: Bool, _ ayuda: String, _ accion: @escaping () -> Void) -> some View {
        Button(action: accion) {
            Label(t, systemImage: icono).labelStyle(.titleAndIcon).font(.callout.weight(.medium))
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(activo ? Color.accentColor.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(ayuda)
    }
}

struct PanelAgentes: View {
    @EnvironmentObject var almacen: Almacen
    @ObservedObject var c = ControlVilla.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                fila(color: Color(hex: "#d8ac45"), titulo: "Sede de gobierno", sub: "Alcalde", ayuda: "Ir a la sede de gobierno") { c.abrirSede() }
                ForEach(almacen.zonas.sorted(by: { $0.value.name < $1.value.name }), id: \.key) { zid, z in
                    Button { c.irBarrio(zid) } label: {
                        HStack { Image(systemName: iconoBarrio[zid] ?? "map"); Text(z.name).bold(); Spacer(); Image(systemName: "arrow.right.circle") }
                            .font(.caption).foregroundStyle(Color(hex: z.roof)).padding(.top, 8).padding(.horizontal, 6).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Ir al barrio \(z.name)")
                    ForEach(almacen.agentes.filter { $0.zona == zid }) { a in
                        fila(color: a.color, titulo: a.nombre, sub: a.ultima, ayuda: "Ver la pizarra de \(a.nombre)", activo: almacen.seleccion == a.id) { c.seleccionar(a.id) }
                    }
                }
            }
            .padding(8)
        }
        .frame(width: 250).frame(maxHeight: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func fila(color: Color, titulo: String, sub: String, ayuda: String, activo: Bool = false, _ accion: @escaping () -> Void) -> some View {
        Button(action: accion) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(titulo).lineLimit(1)
                Spacer()
                Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.vertical, 4).padding(.horizontal, 6)
            .background(activo ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(ayuda)
    }
}

struct PanelSede: View {
    @EnvironmentObject var almacen: Almacen
    @ObservedObject var c = ControlVilla.shared

    var body: some View {
        let activos = almacen.agentes.filter { $0.estado != "off" }
        let bien = activos.filter { $0.estado == "ok" || $0.estado == "fixed" }
        let llamado = c.audiencia.flatMap { id in almacen.agentes.first { $0.id == id } }
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("DESPACHO DEL GOBIERNO").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text("Sede de gobierno").font(.title3.bold())
                Text("Alcalde · líder, gobierno y CEO de la villa").font(.caption).foregroundStyle(.secondary)
                Text("\(bien.count) de \(activos.count) agentes activos trabajan con normalidad.").font(.callout)
                if let a = llamado {
                    HStack {
                        Text("En audiencia: ").font(.callout) + Text(a.nombre).font(.callout.bold()).foregroundColor(Color(hex: "#d8ac45"))
                        Spacer()
                        Button("Despedir") { c.despedir() }.help("\(a.nombre) vuelve caminando a su oficina")
                    }
                    Button("Ver su pizarra") { c.seleccionar(a.id) }.buttonStyle(.link)
                } else {
                    Text("Llama a cualquier agente a tu despacho.").font(.callout).foregroundStyle(.secondary)
                }
                Button { c.verAudiencia = true } label: { Label("Conversar en audiencia (IA)", systemImage: "bubble.left.and.bubble.right.fill") }
                    .help("Habla con el agente convocado, el Revisor de agentes o el gabinete; responde la IA con datos reales")
                let atencion = almacen.conProblemas
                if !atencion.isEmpty {
                    Text("Necesitan atención").font(.headline)
                    ForEach(atencion) { a in
                        Button { c.seleccionar(a.id) } label: {
                            HStack(alignment: .top) {
                                Circle().fill(a.color).frame(width: 8, height: 8).parpadeo(a.enAtencion).padding(.top, 5)
                                VStack(alignment: .leading) {
                                    Text(a.nombre).bold()
                                    Text(a.def.pend?.first ?? a.vivo?.solucion ?? a.resultado).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help("Ver la pizarra de \(a.nombre)")
                    }
                }
                Text("Llamar a un agente").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], spacing: 6) {
                    ForEach(activos) { a in
                        Button { c.llamar(a.id) } label: {
                            HStack(spacing: 5) { Circle().fill(a.color).frame(width: 7, height: 7).parpadeo(a.enAtencion); Text(a.nombre).font(.caption).lineLimit(1); Spacer(minLength: 0) }
                                .padding(.horizontal, 7).padding(.vertical, 5)
                                .background(c.audiencia == a.id ? Color(hex: "#d8ac45").opacity(0.35) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help("Llamar a \(a.nombre) a la audiencia: camina hasta la sede")
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 330).frame(maxHeight: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// La pizarra del agente, legible y con sus acciones.
struct TarjetaPizarra: View {
    @EnvironmentObject var almacen: Almacen
    @ObservedObject var c = ControlVilla.shared
    let a: Agente

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(Agente_zona(a)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { c.cerrarPizarra() } label: { Image(systemName: "xmark.circle.fill").font(.title3) }
                    .buttonStyle(.plain).help("Ocultar pizarra")
            }
            HStack(alignment: .top, spacing: 8) {
                Retrato(tipo: "agente", agente: a).frame(width: 96, height: 96)
                VStack(alignment: .leading, spacing: 3) {
                    Text(a.nombre).font(.headline)
                    Text(a.etiquetaEstado).font(.caption.bold()).foregroundStyle(a.color)
                    Text("«\(a.enAtencion ? (a.vivo?.nota ?? a.resultado) : (a.resultado.isEmpty ? "Todo en orden, Alcalde." : a.resultado))»")
                        .font(.caption).lineLimit(4).foregroundStyle(.secondary)
                }
            }
            Image(nsImage: Pizarra.imagen(a)).resizable().aspectRatio(680.0 / 460.0, contentMode: .fit).frame(width: 380)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            if a.id == "hacienda" { PanelHacienda() }
            if a.id == "cajero" || a.id == "tok" {      // desglose con gráficos (también en las pantallas del atrio del mall)
                ScrollView { if a.id == "cajero" { PanelGastos() } else { PanelTokens() } }.frame(width: 380, height: 330)
            }
            // Dos filas de botones con su texto completo
            HStack(spacing: 6) {
                if c.audiencia == a.id {
                    Button("Despedir") { c.despedir() }.help("\(a.nombre) vuelve caminando a su oficina")
                } else {
                    Button("Llamar a la sede") { c.llamar(a.id) }.disabled(a.estado == "off").help("\(a.nombre) camina hasta la audiencia con Alcalde")
                }
                if a.servicio != nil {
                    Button("Ejecutar ahora") { Task { await almacen.ejecutar(a) } }.help("Hace que el agente trabaje ahora mismo")
                }
            }
            .fixedSize()
            HStack(spacing: 6) {
                Button("Ver oficina") { c.dentro = nil; c.coord?.enfocarAgente(a.id) }.help("Vista frontal de su oficina y su pizarra")
                if c.dentro == a.id {
                    Button("Salir del edificio") { c.salir() }.help("Vuelve a la vista frontal (Esc)")
                } else {
                    Button("Entrar") { c.entrar(a.id) }.help("Entra a su oficina: cámara adentro, a la altura de los ojos")
                }
            }
            .fixedSize()
            if let m = c.aviso { Text(m).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(12)
        .frame(width: 404)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func Agente_zona(_ a: Agente) -> String { (almacen.zonas[a.zona]?.name ?? a.zona).uppercased() }
}


/// Pizarra de un edificio, legible e interactiva: un clic en un agente lleva a su oficina y su pizarra.
struct TarjetaDirectorio: View {
    @EnvironmentObject var almacen: Almacen
    @ObservedObject var c = ControlVilla.shared
    let zid: String

    var body: some View {
        let lista = almacen.agentes.filter { $0.zona == zid }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("EN ESTE EDIFICIO TRABAJAN").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(almacen.zonas[zid]?.name ?? zid).font(.headline)
                }
                Spacer()
                Button { c.directorio = nil } label: {
                    Image(systemName: "xmark.circle.fill").font(.title2).frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain).keyboardShortcut(.cancelAction).help("Cerrar la pizarra (Esc)")
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(lista) { a in
                        Button { c.irAgente(a.id) } label: {
                            HStack(spacing: 8) {
                                Circle().fill(a.color).frame(width: 10, height: 10)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(a.nombre).font(.callout.weight(.medium)).lineLimit(1)
                                    Text(a.ultima).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 6)
                                Text(a.etiquetaEstado).font(.caption.bold()).foregroundStyle(a.color)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help("Ir a la oficina de \(a.nombre) y ver su pizarra")
                    }
                }
            }
            .frame(height: min(360, CGFloat(lista.count) * 46))
            Text("Clic en un agente para ir a su oficina").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(width: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}


/// Hacienda: Alcalde aprueba el presupuesto (real o fijo) y decide cada solicitud de los agentes. La decisión queda en
/// trabajo/hacienda (presupuesto.json y solicitudes/*.json); el Ministro la lee al instante.
struct PanelHacienda: View {
    @EnvironmentObject var almacen: Almacen
    @State private var informe: [String: Any] = [:]
    @State private var aviso: String?
    private var dir: String { Almacen.carpetaLocal + "/trabajo/hacienda" }

    private func pesos(_ v: Any?) -> String {
        let n = (v as? NSNumber)?.doubleValue ?? 0
        let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "es_CL"); f.maximumFractionDigits = 0
        return "$" + (f.string(from: NSNumber(value: n)) ?? "\(Int(n))")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let ap = informe["aprobado"] as? [String: Any] {
                Text("Presupuesto aprobado: \(pesos(ap["monto"]))/mes (\(ap["tipo"] as? String ?? ""))").font(.caption.bold())
                Button("Cambiar presupuesto") { guardarPresupuesto(nil) }.font(.caption)
            } else if informe["real"] != nil {
                Text("Presupuesto mensual por aprobar").font(.caption.bold())
                HStack(spacing: 6) {
                    Button("Aprobar real \(pesos(informe["real"]))") { guardarPresupuesto(("real", informe["real"])) }
                        .help("El gasto real de hoy en apps y suscripciones")
                    Button("Aprobar fijo \(pesos(informe["fijo"]))") { guardarPresupuesto(("fijo", informe["fijo"])) }
                        .help("Real + 10 % de holgura, redondeado")
                }
                .fixedSize()
            }
            ForEach(Array(((informe["pendientes"] as? [[String: Any]]) ?? []).enumerated()), id: \.offset) { _, s in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(almacen.agentes.first { $0.id == s["agente"] as? String }?.nombre ?? (s["agente"] as? String ?? "")) pide \(s["que"] as? String ?? "") por \(pesos(s["monto"]))")
                        .font(.caption.bold())
                    Text((s["motivo"] as? String ?? "") + " · " + (s["evaluacion"] as? String ?? "")).font(.caption2).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Button("Aprobar") { decidir(s["archivo"] as? String, "aprobada") }
                        Button("Rechazar") { decidir(s["archivo"] as? String, "rechazada") }
                    }
                }
                .padding(6).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            if let m = aviso { Text(m).font(.caption2).foregroundStyle(.secondary) }
        }
        .onAppear(perform: leer)
    }

    private func leer() {
        if let d = FileManager.default.contents(atPath: dir + "/informe.json"), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { informe = j }
    }

    private func escribir(_ ruta: String, _ j: [String: Any]) {
        if let d = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted]) { try? d.write(to: URL(fileURLWithPath: ruta), options: .atomic) }
    }

    private func refrescar(_ texto: String) {
        aviso = texto
        Task {
            _ = await Task.detached { Proceso.correr("/usr/local/bin/python3", [Almacen.carpetaLocal + "/agentes/hacienda.py"]) }.value
            leer(); await almacen.revisar()
        }
    }

    private func guardarPresupuesto(_ eleccion: (String, Any?)?) {
        let ruta = dir + "/presupuesto.json"
        var j = (FileManager.default.contents(atPath: ruta).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        if let e = eleccion {
            let (tipo, monto) = e
            let ap: [String: Any] = ["tipo": tipo, "monto": monto ?? 0, "t": Date().timeIntervalSince1970]
            j["aprobado"] = ap
            j["historial"] = ((j["historial"] as? [Any]) ?? []) + [ap]
        } else {
            j["aprobado"] = NSNull(); j["avisado"] = Date().timeIntervalSince1970
        }
        escribir(ruta, j)
        refrescar(eleccion == nil ? "Elige de nuevo el presupuesto." : "Presupuesto aprobado.")
    }

    private func decidir(_ archivo: String?, _ estado: String) {
        guard let archivo else { return }
        let ruta = dir + "/solicitudes/" + archivo
        guard var j = FileManager.default.contents(atPath: ruta).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { return }
        j["estado"] = estado; j["decision_t"] = Date().timeIntervalSince1970
        escribir(ruta, j)
        refrescar(estado == "aprobada" ? "Solicitud aprobada." : "Solicitud rechazada.")
    }
}

// MARK: - Panel Metro: visión completa de la Línea Circular

struct PanelMetro: View {
    @ObservedObject var c = ControlVilla.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Metro · Línea Circular", systemImage: "tram.fill").font(.headline)
                Spacer()
                Button { if c.metroVuelta { c.alternarVueltaMetro() }; c.verMetro = false } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).help("Cerrar el panel del metro")
            }
            Text("CIRCUITO").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                boton("Exterior", "arrow.up.left.and.arrow.down.right", "exterior", "Viaducto de frente, visto desde afuera del círculo (desde el mar)")
                boton("Interior", "arrow.down.right.and.arrow.up.left", "interior", "Viaducto visto desde adentro del círculo (desde la villa)")
                boton("Arriba", "square.dashed", "arriba", "Todo el circuito, ramal y cocheras desde arriba")
            }
            HStack(spacing: 6) {
                Button { c.girarMetro(-30) } label: { Image(systemName: "chevron.left") }.help("Avanzar 30° alrededor del circuito, hacia la izquierda")
                Button { c.alternarVueltaMetro() } label: {
                    Label(c.metroVuelta ? "Detener vuelta" : "Vuelta completa", systemImage: c.metroVuelta ? "stop.fill" : "arrow.triangle.2.circlepath")
                }.help("Recorre el circuito completo, 15° cada 2,5 s, por fuera o por dentro según la vista elegida")
                Button { c.girarMetro(30) } label: { Image(systemName: "chevron.right") }.help("Avanzar 30° alrededor del circuito, hacia la derecha")
            }
            Divider()
            Text("ENTRADAS Y SALIDAS DE LAS ESTACIONES").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(MetroVilla.estaciones.enumerated()), id: \.offset) { k, e in
                        Button { c.vistaMetro("estacion", k: k) } label: {
                            Label(e.nombre.capitalized, systemImage: "figure.walk.arrival").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).padding(.vertical, 3)
                        .help("Torre de acceso de \(e.nombre.capitalized): escalera, ascensor y vereda a la calle\(e.estacionamiento ? " y al estacionamiento" : "")")
                    }
                }
            }.frame(maxHeight: 260)
        }
        .padding(14).frame(width: 290)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func boton(_ t: String, _ i: String, _ modo: String, _ ayuda: String) -> some View {
        Button { c.vistaMetro(modo) } label: { Label(t, systemImage: i).frame(maxWidth: .infinity) }
            .buttonStyle(.borderedProminent).tint(c.metroModo == modo ? .accentColor : .gray).help(ayuda)
    }
}
