import SwiftUI
import AppKit
import SceneKit

// MARK: - Elementos de la villa con reporte (helicóptero, cazas, garita, guardias, vehículos)

/// Ventana emergente al hacer clic en un elemento de la villa: quien está ahí da su reporte con datos reales.
struct TarjetaElemento: View {
    @EnvironmentObject var almacen: Almacen
    @ObservedObject var c = ControlVilla.shared
    let e: String

    fileprivate struct Reporte { var icono: String; var color: Color; var titulo: String; var quien: String; var texto: String }

    var body: some View {
        let r = reporte()
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Retrato(tipo: e, agente: nil).frame(width: 96, height: 96)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: r.icono).font(.caption).foregroundStyle(.white).frame(width: 24, height: 24).background(r.color, in: Circle())
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.titulo).font(.headline)
                    Text(r.quien).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { c.elemento = nil } label: { Image(systemName: "xmark.circle.fill").font(.title3) }
                    .buttonStyle(.plain).help("Cerrar el reporte")
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(r.color)
                Text("«\(r.texto)»").font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            .padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 6) { acciones }
            Text("Reporte con datos reales de la villa · \(Date().formatted(date: .omitted, time: .shortened))")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(width: 404)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private var acciones: some View {
        if e.hasPrefix("puerto") || e.hasPrefix("flota") { accionesMar } else { accionesBase }
    }

    /// Botones del puerto (agentes proveedores) y de la flota (agentes protectores y optimizadores).
    @ViewBuilder private var accionesMar: some View {
        let id = PuertoYFlota.agenteDe(e)
        if e == "flota-portaaviones" {
            Button("Centro de mando") { c.elemento = nil; c.verCentro = true }.help("Salud, recursos, seguridad y alarma de toda la villa")
            Button("Revisor") { c.seleccionar("revisor") }.help("Pizarra del Revisor de agentes")
            Button("Seguridad del Mac") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")!) }
                .help("Abre el antivirus (lo que haga lo decides tú)")
        } else if e.hasPrefix("flota"), let id {
            Button("Pizarra del agente") { c.seleccionar(id) }.help("Abre la pizarra del agente que comanda este buque")
            if id == "seg" { Button("Seguridad del Mac") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")!) } }
            Button("Centro de mando") { c.elemento = nil; c.verCentro = true }
        } else {
            if let id { Button("Pizarra del agente") { c.seleccionar(id) }.help("Abre la pizarra del agente de este barco") }
            if e == "puerto-lancha" { Button("Buzón de SMS") { c.seleccionar("sms") } }
            Button("Agentes del puerto") { c.elemento = nil; c.abrirDirectorio("puerto") }.help("Pizarra de la capitanía con todos los agentes proveedores")
            Button("Ver el puerto") { c.elemento = nil; c.irBarrio("puerto") }
        }
    }

    @ViewBuilder private var accionesBase: some View {
        switch e {
        case "helicoptero", "cazas", "intruso", "garita", "guardiaGarita":
            Button("Vigilante de seguridad") { c.seleccionar("seg") }.help("Abre la pizarra del agente que vigila con el antivirus")
            Button("Seguridad del Mac") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")!) }
                .help("Abre el antivirus para ver sus informes o neutralizar una amenaza (lo haces tú)")
        case "patrulla":
            Button("Revisor de agentes") { c.seleccionar("revisor") }.help("Abre la pizarra del Revisor, que repara lo que puede")
            Button("Revisar ahora") { Task { await almacen.recargar() } }.help("Vuelve a leer el estado de todos los agentes")
        case "bomberos":
            Button("Seguridad") { c.seleccionar("seg") }.help("Pizarra del Vigilante de seguridad (antivirus)")
            Button("Optimizador") { c.seleccionar("opt") }.help("Pizarra del Optimizador del Mac: memoria, inicio, actualizaciones y espacio")
            Button("Almacenamiento") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!) }
                .help("Abre Ajustes → Almacenamiento (lo decides tú)")
            Button("Almacenamiento") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!) }
                .help("Abre Ajustes → Almacenamiento")
        case "camion":
            Button("Cajero") { c.seleccionar("cajero") }.help("Pizarra del Cajero: suscripciones y apps de pago")
            Button("Ver el mall") { c.elemento = nil; c.irBarrio("mall") }
        case "aeropuerto", "avion":
            Button("Ver el aeropuerto") { c.elemento = nil; c.irBarrio("aeropuerto") }.help("Vuela sobre la pista, la terminal y la torre")
        case "bus":
            Button("Aeropuerto") { c.elemento = nil; c.irBarrio("aeropuerto") }
            Button("Trade Center") { c.elemento = nil; c.irBarrio("trade") }
        case _ where e.hasPrefix("museo-"):
            Button("Ver el museo") { c.elemento = nil; c.irBarrio("museo") }
        case "ambulancia":
            Button("Ver Servicio de urgencias") { c.elemento = nil; c.irBarrio("urg") }.help("Vuela al barrio de Urgencias")
        case "guardiaPalacio", "guardiaPlaza", "caravana":
            Button("Abrir la sede") { c.elemento = nil; c.abrirSede() }.help("Despacho del gobierno: llamar agentes a audiencia")
            Button("Audiencia") { c.elemento = nil; c.verAudiencia = true }.help("Conversar con un agente, el Revisor o el gabinete (con IA)")
        default:
            Button("Vista general") { c.elemento = nil; c.general() }.help("Vuelve a la vista de toda la villa")
        }
    }

    private func reporte() -> Reporte {
        if e.hasPrefix("puerto") || e.hasPrefix("flota") { return reporteMar() }
        let ag = almacen.agentes
        let activos = ag.filter { $0.estado != "off" }.count
        let atencion = ag.filter(\.enAtencion)
        let nombres = atencion.map(\.nombre).joined(separator: ", ")
        let seg = almacen.resultados["seg"]
        let alerta = seg?.status == "warn"
        let segTxt = seg?.resumen ?? "sin reporte del Vigilante de seguridad todavía"
        let protecciones = seg?.detalle?.first { $0.hasPrefix("🔒") }.map { String($0.dropFirst(2)) } ?? "sin datos"
        let novedad = atencion.isEmpty ? "Sin novedad: los \(activos) agentes activos están operativos." : "\(atencion.count) agente(s) en atención: \(nombres)."
        let vehiculos = c.coord?.conteoVehiculos ?? 0
        let hora = Date().formatted(date: .omitted, time: .shortened)
        switch e {
        case "helicoptero":
            return Reporte(icono: "airplane.circle.fill", color: Color(red: 0.23, green: 0.29, blue: 0.18), titulo: "Helicóptero Halcón 1",
                           quien: "Piloto · Teniente Rojas, defensa aérea",
                           texto: "Aquí Halcón 1, patrullando a 20 metros sobre la villa, \(hora). \(novedad) Seguridad: \(segTxt) Tránsito: \(vehiculos) vehículos circulando sin incidentes. Cambio.")
        case "cazas":
            return Reporte(icono: "airplane", color: alerta ? .red : .gray, titulo: "Escuadrilla Cóndor",
                           quien: "Líder de escuadrilla · Capitán Fuentes",
                           texto: alerta ? "¡Contacto! Interceptando al intruso. \(segTxt) El antivirus debe neutralizarlo: abra sus informes." :
                                "Espacio aéreo del Mac despejado. \(segTxt) Seguimos en patrulla de rutina.")
        case "intruso":
            return Reporte(icono: "exclamationmark.shield.fill", color: .red, titulo: "Amenaza detectada",
                           quien: "Vigilante de seguridad · antivirus",
                           texto: "\(segTxt) La neutraliza el antivirus (cuarentena o borrado): abre el antivirus → Informes. No cambio ajustes de seguridad.")
        case "garita", "guardiaGarita":
            return Reporte(icono: "shield.lefthalf.filled", color: .green, titulo: "Control de acceso",
                           quien: "Cabo de guardia · garita del puente",
                           texto: "Control de acceso al Mac: \(protecciones). Solo entra lo que el firewall y Gatekeeper autorizan; los visitantes se detienen en la barrera y se registran. \(alerta ? "¡Alerta activa!" : "Sin ingresos sospechosos.")")
        case "guardiaPalacio":
            let aud = c.audiencia.flatMap { id in ag.first { $0.id == id }?.nombre }
            return Reporte(icono: "person.badge.shield.checkmark.fill", color: Color(red: 0.29, green: 0.35, blue: 0.2), titulo: "Guardia de palacio",
                           quien: "Sargento de guardia · Palacio de gobierno",
                           texto: "Sin novedad en el palacio, Alcalde. \(aud.map { "En audiencia: \($0)." } ?? "Nadie en audiencia ahora.") \(novedad)")
        case "guardiaPlaza":
            return Reporte(icono: "person.badge.shield.checkmark.fill", color: Color(red: 0.29, green: 0.35, blue: 0.2), titulo: "Guardia de la plaza",
                           quien: "Soldado de guardia · acceso a la plaza",
                           texto: "Acceso a la plaza de gobierno controlado. Los agentes solo vienen a la sede cuando usted los convoca. \(novedad)")
        case "caravana":
            return Reporte(icono: "car.2.fill", color: .black, titulo: "Escolta presidencial",
                           quien: "Jefe de escolta · caravana del gobierno",
                           texto: "Recorrido de seguridad por el anillo periférico, ruta despejada. Esperamos en la plaza entre vueltas. \(alerta ? "Alerta de seguridad: reforzamos la escolta." : "Sin amenazas en el trayecto.")")
        case "bomberos":
            let inc = c.coord?.incidentes ?? []
            let lugar: (String) -> String = { d in d == "sede" ? "la sede de gobierno" : (almacen.zonas[d]?.name ?? d) }
            let tx = inc.isEmpty
                ? "Cuartel en guardia, sin emergencias, \(hora). Vigilamos con el gobierno, Carabineros, Urgencias y la defensa aérea: el antivirus (\(alerta ? "alerta" : "sin amenazas")), espacio en disco, temperatura del Mac y agentes en falla."
                : "¡Emergencia! \(inc.map { "\($0.titulo) (en \(lugar($0.destino)))" }.joined(separator: "; ")). El carro bomba va a \(lugar(inc[0].destino)); Carabineros despeja el tránsito, Urgencias está alerta y el gobierno fue informado. Lo que requiere su decisión o borrar datos lo resuelve usted."
            return Reporte(icono: "flame.fill", color: inc.isEmpty ? Color(red: 0.7, green: 0.2, blue: 0.17) : .red, titulo: "Cuerpo de Bomberos",
                           quien: "Comandante · 1.ª Compañía, seguridad pública del Mac", texto: tx)
        case "ambulancia":
            let urg = ag.filter { $0.zona == "urg" }
            let mal = urg.filter(\.enAtencion)
            return Reporte(icono: "cross.case.fill", color: .red, titulo: "Ambulancia SAMU",
                           quien: "Paramédico · Servicio de urgencias",
                           texto: "Servicio de urgencias con \(urg.count) agentes: \(mal.isEmpty ? "todos operativos." : "atendiendo a \(mal.map(\.nombre).joined(separator: ", ")).") \(atencion.isEmpty ? "Estamos en el estacionamiento de atrás, listas para salir." : "Salimos a la entrada de Urgencias: hay \(atencion.count) agente(s) en atención en la villa.")")
        case "patrulla":
            let rev = almacen.resultados["revisor"]?.resumen ?? "sin informe"
            return Reporte(icono: "shield.checkered", color: Color(red: 0.29, green: 0.35, blue: 0.2), titulo: "Patrulla militar",
                           quien: "Jefe de patrulla · ronda perimetral",
                           texto: "Ronda perimetral completada. \(novedad) Informe del Revisor: \(rev)")
        case "moto":
            return Reporte(icono: "bicycle", color: Color(red: 0.18, green: 0.36, blue: 0.23), titulo: "Motorista de Carabineros",
                           quien: "Cabo motorista · patrulla del anillo",
                           texto: "Patrullando el anillo: tránsito \(c.coord?.estadoTransito ?? "normal"), \(vehiculos) vehículos circulando. \(novedad)")
        case "carabinero":
            return Reporte(icono: "figure.wave", color: Color(red: 0.18, green: 0.36, blue: 0.23), titulo: "Carabinero de tránsito",
                           quien: "Sargento · cruce de la avenida con el anillo",
                           texto: "Dirigiendo el tránsito en el cruce: \(c.coord?.estadoTransito ?? "normal"). Doy paso a la escolta y a las ambulancias primero.")
        case "camion":
            let caja = almacen.resultados["cajero"]?.resumen ?? "sin rendición del Cajero todavía"
            return Reporte(icono: "truck.box.fill", color: .orange, titulo: "Camión Villa Express",
                           quien: "Repartidor · Centro comercial",
                           texto: "Traigo mercadería al Centro comercial desde tierra firme y desde el puerto, y descargo en el andén. Caja del mall: \(caja).")
        case "aeropuerto":
            return Reporte(icono: "airplane", color: .blue, titulo: "Aeropuerto Internacional Villa",
                           quien: "Torre de control · Controladora Soto",
                           texto: "Pista 09/27 operativa, viento calmo. Un vuelo de Villa Air sale cada tres minutos, da la vuelta mar adentro y aterriza. El bus de enlace une la terminal con la villa por el pedraplén. \(novedad)")
        case "avion":
            return Reporte(icono: "airplane.departure", color: .pink, titulo: "Vuelo Villa Air", quien: "Comandante · Capitán Morales",
                           texto: "Embarque, rodaje, despegue por la 09, vuelta sobre el mar y aterrizaje. Sin agentes a bordo todavía: el aeropuerto queda listo para los agentes que viajen a servicios externos.")
        case "bus":
            return Reporte(icono: "bus.fill", color: .purple, titulo: "Bus de enlace", quien: "Conductor · línea Villa–Islas",
                           texto: "Salgo del paradero junto al anillo, cruzo el pedraplén y doy la vuelta en la isla. Tránsito \(c.coord?.estadoTransito ?? "normal").")
        case "caleta":
            return Reporte(icono: "fish.fill", color: .blue, titulo: "Caleta de pescadores", quien: "Pescador · don Lucho",
                           texto: "Salimos al alba y volvemos con pescado fresco al puesto del muelle. Hoy el mar está tranquilo, \(hora).")
        case "balneario":
            return Reporte(icono: "beach.umbrella.fill", color: .orange, titulo: "Balneario Villa", quien: "Salvavidas de turno",
                           texto: "Bandera verde, bañistas dentro de las boyas. Quitasoles, quiosco de helados y cancha de vóleibol abiertos.")
        case "marina":
            return Reporte(icono: "sailboat.fill", color: .teal, titulo: "Marina Villa", quien: "Jefe de muelle",
                           texto: "Yates, veleros y lanchas amarrados en el muelle flotante; una lancha rápida pasea frente a la costa.")
        case "letrero":
            return Reporte(icono: "sparkles", color: .white, titulo: "SILICON VILLA", quien: "Valle de los agentes",
                           texto: "Bienvenido a Silicon Villa, el valle de los agentes del Alcalde: \(ag.count) agentes, \(activos) activos. \(novedad)")
        case _ where e.hasPrefix("museo-"):
            let id = String(e.dropFirst(6))
            let pz = Villa3D.Coordinador.piezasMuseo().first { $0.id == id }
            return Reporte(icono: "building.columns.fill", color: .brown, titulo: pz?.nombre ?? "Pieza del museo", quien: "Museo de la Villa · agentes históricos",
                           texto: pz?.texto ?? "Pieza en restauración.")
        case "visita":
            return Reporte(icono: "car.fill", color: .yellow, titulo: "Visitante",
                           quien: "Conductor registrado en la garita",
                           texto: "Pasé el control de acceso del puente, me revisaron y me dejaron entrar. Doy una vuelta por la villa y salgo por el mismo puente.")
        default:
            return Reporte(icono: "car.fill", color: .blue, titulo: "Vecino de la villa",
                           quien: "Conductor · anillo periférico",
                           texto: "Tránsito \(c.coord?.estadoTransito ?? "normal") en el anillo: \(vehiculos) vehículos circulando. Todo tranquilo por aquí.")
        }
    }
}

extension TarjetaElemento {
    /// Reportes del puerto y de la flota, con el estado real de cada agente.
    fileprivate func reporteMar() -> Reporte {
        let ag = almacen.agentes
        func est(_ id: String) -> String {
            guard let a = ag.first(where: { $0.id == id }) else { return "" }
            return "\(a.nombre): \(a.etiquetaEstado.lowercased())" + (a.enAtencion ? " (\(a.vivo?.nota ?? a.resultado))" : "")
        }
        func res(_ id: String) -> String { almacen.resultados[id]?.resumen.map { " \($0)" } ?? "" }
        func ultima(_ id: String) -> String { ag.first(where: { $0.id == id })?.ultima ?? "sin registro" }
        let inc = c.coord?.incidentes ?? []
        switch e {
        case "puerto-carguero":
            return Reporte(icono: "shippingbox.fill", color: .blue, titulo: "Carguero «Otro Mac»", quien: "Capitán · Sincronizar apps al otro Mac",
                           texto: "Llevamos tus apps y sus datos a otro Mac cuando cambian. \(est("sincmac")). Último viaje: \(ultima("sincmac")).\(res("sincmac"))")
        case "puerto-tanquero":
            return Reporte(icono: "fuelpump.fill", color: .orange, titulo: "Tanquero «Memoria»", quien: "Capitán · Proveedor de memoria",
                           texto: "Traemos el combustible de la memoria: el proveedor de IA más económico disponible. \(est("mem")).\(res("mem"))")
        case "puerto-lancha":
            return Reporte(icono: "envelope.fill", color: .indigo, titulo: "Lancha correo", quien: "Patrón · Traductor de correos y Buzón de SMS",
                           texto: "Salimos a buscar los correos en otros idiomas y volvemos con su traducción; también llevamos tus avisos al teléfono. \(est("trad")). \(est("sms")).")
        case "puerto-faro":
            return Reporte(icono: "binoculars.fill", color: .teal, titulo: "Faro del puerto", quien: "Farero · Vigía de la App Store",
                           texto: "Desde aquí miro la App Store: si tus apps ya están publicadas y con qué versión. \(est("asc")).\(res("asc"))")
        case "puerto-muelle":
            return Reporte(icono: "plus.circle.fill", color: .yellow, titulo: "Muelle libre", quien: "Práctico del puerto",
                           texto: "Muelle listo para nuevos agentes proveedores que conecten tus apps externas con la villa (calendario, Drive, mensajería u otras). Cuando un agente se asigna al puerto, su oficina aparece junto a la capitanía.")
        case "flota-portaaviones":
            let escolta = ["seg", "opt", "salud", "resp", "red"].map(est).filter { !$0.isEmpty }.joined(separator: "; ")
            return Reporte(icono: "shield.lefthalf.filled", color: inc.isEmpty ? .blue : .red, titulo: "Portaaviones Defensor", quien: "Almirante · grupo de batalla de la villa",
                           texto: (inc.isEmpty ? "Patrulla de rutina alrededor de la isla, sin novedad." : "¡Zafarrancho de combate! \(inc.map(\.titulo).joined(separator: "; ")). La flota acelera y cierra el cerco sobre la isla.")
                                + " Escolta: \(escolta). En la sede: \(est("revisor")). La escuadrilla Cóndor está embarcada y sale si el antivirus detecta un intruso.")
        default:
            let id = PuertoYFlota.agenteDe(e) ?? ""
            let buque = PuertoYFlota.buques.first { $0.id == id }?.nombre ?? "Buque de la escolta"
            if e.hasPrefix("flota") {
                return Reporte(icono: "shield.fill", color: .blue, titulo: buque, quien: "Comandante · \(ag.first { $0.id == id }?.nombre ?? id)",
                               texto: "En formación con el portaaviones Defensor. \(est(id)).\(res(id))")
            }
            let enPuerto = ag.filter { $0.zona == "puerto" }
            let mal = enPuerto.filter(\.enAtencion)
            return Reporte(icono: "ferry.fill", color: .blue, titulo: "Capitanía de puerto", quien: "Capitán de puerto · grúas y muelles",
                           texto: "Puerto de proveedores: \(enPuerto.count) agentes conectan la villa con apps externas (\(enPuerto.map(\.nombre).joined(separator: ", "))). \(mal.isEmpty ? "Todos operativos." : "En atención: \(mal.map(\.nombre).joined(separator: ", ")).")")
        }
    }
}

// MARK: - Audiencia en la sede: conversar con el agente convocado, el Revisor o el gabinete (con IA)

@MainActor
final class Audiencia: ObservableObject {
    static let shared = Audiencia()
    struct Mensaje: Identifiable, Hashable { let id = UUID(); let quien: String; let texto: String; let mio: Bool }
    @Published var conversaciones: [String: [Mensaje]] = [:]
    @Published var pensando = false

    private let reglas = """
    Reglas de veracidad, obligatorias:
    1. Tu fuente de verdad es el EXPEDIENTE (datos reales de la villa). En esta audiencia puedes consultar el Mac EN SOLO LECTURA: si la pregunta pide datos actuales, lee los archivos o registros del expediente (por ejemplo con tail o cat) y dilo ("lo verifiqué ahora en <archivo>"). No ejecutes nada que modifique el sistema.
    2. Si algo no consta, dilo ("No tengo registro de eso") y sugiere cómo verificarlo. Nunca inventes horas, cifras, causas ni éxitos.
    3. Separa hechos de hipótesis. Reconoce tus fallas sin minimizarlas.
    4. No prometas ni ejecutes cambios: indica quién lo haría (el Alcalde o Claude Code en el Mac).
    5. Español, texto plano sin markdown; guiones para listas cortas. Máximo unas 170 palabras salvo que pida detalle.
    """

    private func expediente(_ a: Agente) -> [String: Any] {
        var d: [String: Any] = ["nombre": a.nombre, "identificador": a.def.plist ?? "", "estado": a.etiquetaEstado,
                                "horario": a.def.sched ?? "", "ultima_actividad": a.ultima, "proxima": a.proxima, "que_hago": a.def.does]
        if let x = a.def.proc { d["procedimiento"] = x }
        if let x = a.def.files { d["archivos_y_registros"] = x }
        if let x = a.def.log { d["historial"] = x.map { $0.joined(separator: ": ") } }
        if let x = a.def.fails { d["fallas"] = x }
        if let x = a.def.fixes { d["reparaciones"] = x }
        if let x = a.def.pend { d["pendientes_y_riesgos"] = x }
        if let v = a.vivo {
            d["estado_en_vivo"] = ["nota": v.nota ?? "", "solucion": v.solucion ?? "", "resultado": v.resultado ?? ""]
        }
        return d
    }

    private func json(_ x: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: x, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// interlocutor: id del agente, "revisor" (con el expediente del convocado como contexto) o "gabinete".
    func preguntar(_ texto: String, interlocutor: String, convocado: Agente?, almacen: Almacen) async {
        let clave = interlocutor
        var conv = conversaciones[clave] ?? []
        conv.append(Mensaje(quien: "Alcalde", texto: texto, mio: true))
        conversaciones[clave] = conv
        let rol: String
        if interlocutor == "gabinete" {
            rol = "Eres el gabinete de la Villa de agentes, el conjunto de agentes automáticos del Mac del Alcalde (líder, gobierno y CEO de la villa). Responde como gabinete, nombrando qué agente dice o hizo qué.\n\n\(reglas)\n\nEXPEDIENTES (JSON):\n\(json(almacen.agentes.map(expediente)))"
        } else if let a = almacen.agentes.first(where: { $0.id == interlocutor }), interlocutor == "revisor" {
            let caso = convocado.map { "\n\nAgente convocado a la audiencia (JSON):\n\(json(expediente($0)))" } ?? ""
            rol = "Eres el \"Revisor de agentes\", asesor directo del gobierno de la villa: revisas los agentes en atención, reparas lo seguro y planteas alternativas. El Alcalde te consulta en su despacho. Responde en primera persona, como asesor técnico, franco y concreto.\n\n\(reglas)\n\nTu expediente (JSON):\n\(json(expediente(a)))\(caso)"
        } else if let a = almacen.agentes.first(where: { $0.id == interlocutor }) {
            rol = "Eres \"\(a.nombre)\", un agente automático del Mac del Alcalde, líder, gobierno y CEO de la Villa de agentes. Te llamó a su despacho y te interroga sobre tus procedimientos y fallas. Responde en primera persona, con respeto y franqueza, como un funcionario que rinde cuentas.\n\n\(reglas)\n\nEXPEDIENTE (JSON):\n\(json(expediente(a)))"
        } else { return }
        let previa = conv.dropLast().map { ($0.mio ? "Alcalde: " : "Tú: ") + $0.texto }.joined(separator: "\n\n")
        let entrada = rol + (previa.isEmpty ? "" : "\n\nConversación previa:\n\(previa)") + "\n\nPregunta actual del Alcalde: \(texto)\n\nResponde solo con tu respuesta al Alcalde."
        pensando = true
        defer { pensando = false }
        let nombre = interlocutor == "gabinete" ? "Gabinete" : (almacen.agentes.first { $0.id == interlocutor }?.nombre ?? interlocutor)
        let respuesta: String
        do { respuesta = try await enviar(entrada, almacen: almacen) } catch { respuesta = "⚠️ No pude responder: \(error.localizedDescription)" }
        conversaciones[clave, default: []].append(Mensaje(quien: nombre, texto: respuesta, mio: false))
    }

    /// Usa el servidor de la villa (/preguntar): el proveedor de IA que configure el servidor local.
    private func enviar(_ entrada: String, almacen: Almacen) async throws -> String {
        let origen = almacen.esLocal ? "http://127.0.0.1:8790" : almacen.servidor
        guard let url = URL(string: origen + "/preguntar") else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 300)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(origen, forHTTPHeaderField: "Origin")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["input": String(entrada.prefix(68_000))])
        let (d, r) = try await URLSession.shared.data(for: req)
        let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        if let t = j?["text"] as? String, (r as? HTTPURLResponse)?.statusCode == 200 { return t }
        throw NSError(domain: "Villa", code: 1, userInfo: [NSLocalizedDescriptionKey: (j?["error"] as? String) ?? "el servidor de la villa no respondió"])
    }
}

struct PanelAudiencia: View {
    @EnvironmentObject var almacen: Almacen
    @ObservedObject var c = ControlVilla.shared
    @ObservedObject var au = Audiencia.shared
    @State private var con = ""
    @State private var texto = ""

    private var convocado: Agente? { c.audiencia.flatMap { id in almacen.agentes.first { $0.id == id } } }
    private var opciones: [(String, String)] {
        var o: [(String, String)] = []
        if let a = convocado, a.id != "revisor" { o.append((a.id, a.nombre)) }
        o.append(("revisor", "Revisor (asesor)"))
        o.append(("gabinete", "Gabinete"))
        return o
    }
    private var sugerencias: [String] {
        switch con {
        case "gabinete": return ["¿Quién falló hoy y por qué?", "¿Qué riesgos quedan abiertos?", "¿Qué depende de internet?"]
        case "revisor": return ["¿Qué revisaste y qué reparaste hoy?", "¿Qué necesita mi decisión?", convocado.map { "¿Qué opinas de \($0.nombre)?" } ?? "¿Cómo está la villa?"]
        default: return ["¿Qué haces, paso a paso?", "¿Cuáles han sido tus fallas?", "¿Qué podría volver a fallar?"]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "building.columns.fill").foregroundStyle(Color(red: 0.72, green: 0.54, blue: 0.17))
                Text("Audiencia en el despacho").font(.headline)
                Spacer()
                if convocado != nil { Button("Despedir") { c.despedir() }.help("El agente vuelve caminando a su oficina") }
                Button { c.verAudiencia = false } label: { Image(systemName: "xmark.circle.fill").font(.title3) }
                    .buttonStyle(.plain).help("Cerrar la audiencia (la conversación se conserva)")
            }
            Picker("Hablar con", selection: $con) {
                ForEach(opciones, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .help("Con quién conversa Alcalde: el agente convocado, el Revisor de agentes o el gabinete completo")
            ScrollViewReader { sv in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if (au.conversaciones[con] ?? []).isEmpty {
                            Text("Pregunte lo que quiera. Responde con IA (si tienes un servidor local en http://127.0.0.1:8790 con /preguntar), con los datos reales de la villa y leyendo el Mac solo en modo lectura.")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(sugerencias, id: \.self) { s in
                                Button(s) { enviar(s) }.buttonStyle(.bordered).controlSize(.small).help("Hacer esta pregunta")
                            }
                        }
                        ForEach(au.conversaciones[con] ?? []) { m in
                            VStack(alignment: m.mio ? .trailing : .leading, spacing: 2) {
                                Text(m.quien).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                Text(m.texto).textSelection(.enabled).font(.callout)
                                    .padding(8)
                                    .background(m.mio ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                            }
                            .frame(maxWidth: .infinity, alignment: m.mio ? .trailing : .leading)
                            .id(m.id)
                        }
                        if au.pensando { HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Pensando…").font(.caption) }.id("pensando") }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: au.conversaciones[con]?.count) {
                    if let u = au.conversaciones[con]?.last { withAnimation { sv.scrollTo(u.id, anchor: .bottom) } }
                }
            }
            HStack {
                TextField("Pregunta del Alcalde…", text: $texto).textFieldStyle(.roundedBorder)
                    .onSubmit { enviar(texto) }.help("Escriba su pregunta y presione Retorno")
                Button { enviar(texto) } label: { Image(systemName: "paperplane.fill") }
                    .disabled(texto.trimmingCharacters(in: .whitespaces).isEmpty || au.pensando).help("Enviar la pregunta")
            }
        }
        .padding(12)
        .frame(width: 430, height: 400)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onAppear { if con.isEmpty || !opciones.contains(where: { $0.0 == con }) { con = opciones.first?.0 ?? "gabinete" } }
        .onChange(of: c.audiencia) { con = opciones.first?.0 ?? "gabinete" }
    }

    private func enviar(_ t: String) {
        let q = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !au.pensando else { return }
        texto = ""
        let quien = con, conv = convocado
        Task { await au.preguntar(q, interlocutor: quien, convocado: conv, almacen: almacen) }
    }
}


/// Busto 3D animado del personaje que habla en la ventana emergente.
struct Retrato: View {
    let tipo: String
    let agente: Agente?
    @State private var escena: (SCNScene, SCNNode)?

    var body: some View {
        ZStack {
            if let (s, cam) = escena {
                SceneView(scene: s, pointOfView: cam, options: [], preferredFramesPerSecond: 30, antialiasingMode: .multisampling4X)
            } else { Color.secondary.opacity(0.15) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.6), lineWidth: 1))
        .help("Personaje que da el reporte")
        .onAppear { escena = Persona.retrato(tipo, agente: agente) }
        .onChange(of: tipo) { _, t in escena = Persona.retrato(t, agente: agente) }
        .onChange(of: agente?.id) { escena = Persona.retrato(tipo, agente: agente) }
    }
}
