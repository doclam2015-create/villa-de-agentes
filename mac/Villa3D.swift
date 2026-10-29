import SwiftUI
import SceneKit
import AppKit

/// Villa 3D nativa (SceneKit), emulando la villa web: isla, sede de gobierno, cinco barrios con un
/// edificio emblemático, una oficina por agente (muros con puerta, escritorio con pantalla del color
/// de su estado, silla y pizarra), escalera a La nube, ambulancia, faroles y árboles.
/// Física: todos caminan por una grilla A* que respeta muros, puertas, muebles y barandas; no se
/// atraviesan entre ellos y sus pies siguen el piso (placas, escalera y nube).
struct Villa3D: NSViewRepresentable {
    @ObservedObject var almacen: Almacen

    func makeCoordinator() -> Coordinador { Coordinador(almacen: almacen) }

    func makeNSView(context: Context) -> SCNView {
        let v = VistaVilla()
        v.coord = context.coordinator
        v.scene = context.coordinator.escena
        v.allowsCameraControl = false          // cámara propia, como la villa web
        v.antialiasingMode = .multisampling2X   // 2×: en pantalla Retina casi no se nota y alivia la GPU
        v.preferredFramesPerSecond = 30   // caminar se ve fluido a 30 fps y gasta la mitad
        v.pointOfView = context.coordinator.camara
        v.isPlaying = true
        context.coordinator.conectar(v)
        return v
    }

    func updateNSView(_ v: SCNView, context: Context) { context.coordinator.sincronizar() }

    static func dismantleNSView(_ v: SCNView, coordinator: Coordinador) { coordinator.desconectar() }

    @MainActor
    final class Coordinador: NSObject {
        let almacen: Almacen
        let escena = SCNScene()
        let camara = SCNNode()
        let nav = Navegacion()
        weak var vista: SCNView?
        private var enlace: CADisplayLink?
        private var ultimo: CFTimeInterval = 0
        private var personas: [String: Persona] = [:]
        private var oficinas: [String: Oficina] = [:]
        var oficinasNube: [String: Oficina] = [:]      // segunda oficina en La nube (agentes cuyo trabajo corre en la nube)
        var ultimaNube: CFTimeInterval = 0
        private var zonasHechas = false
        private var emblemas: [String: SCNNode] = [:]
        private var seleccionPrevia: String?
        private var ventanas: [SCNMaterial] = []
        private var vehiculos: [Vehiculo] = []
        var conteoVehiculos: Int { vehiculos.filter { !$0.raiz.isHidden }.count }
        private(set) var estadoTransito = "normal"
        private var ambHosp: [(nodo: SCNNode, ruta: [CGPoint])] = [], salidaAmb: CGFloat = 0
        // Cuerpo de bomberos: carro bomba que sale del cuartel hacia el incidente (el antivirus, disco, temperatura, agentes)
        private var bomba: SCNNode!, balizasBomba: [SCNNode] = [], bomberosCuartel: [Persona] = []
        private var rutaBomba: [CGPoint] = [], sBomba: CGFloat = 0, destinoBomba: String?, ultimoChequeo: CFTimeInterval = 0
        private var bombaDeFrente = false
        private var directorios: [String: SCNMaterial] = [:], firmaDirectorio: [String: String] = [:]
        private let pantallon = SCNMaterial()
        private var refrescoPantalla: CFTimeInterval = 0
        private var helicopteroMeta: SCNVector3?

        /// Qué está haciendo la defensa de la villa ahora (para el centro de mando y el pantallón).
        var defensaTexto: [String] {
            var l: [String] = []
            if let d = destinoBomba, sBomba > 0.5 { l.append("Carro bomba en camino a \(almacen.zonas[d]?.name ?? (d == "sede" ? "la sede de gobierno" : d))") }
            else { l.append("Bomberos de guardia en el cuartel") }
            l.append(salidaAmb > 0.5 ? "Ambulancias en la entrada de Urgencias" : "Ambulancias estacionadas, listas para salir")
            if almacen.resultados["seg"]?.status == "warn" { l.append("Cazas interceptando un intruso (alerta de seguridad)") }
            if let d = incidentes.first?.destino { l.append("Helicóptero Halcón 1 sobrevolando \(almacen.zonas[d]?.name ?? "la sede de gobierno")") }
            else { l.append("Helicóptero Halcón 1 en ronda de vigilancia") }
            return l
        }          // quedó estacionado mirando al fondo del cuartel (entró de frente)
        private var centroCuartel = CGPoint.zero
        private(set) var incidentes: [(titulo: String, destino: String)] = []
        /// Radio del arco de oficinas (ala) alrededor de cada edificio principal: pegado a él, sin tocar sus anexos.
        static let radioAla: [String: CGFloat] = ["urg": 11.4, "cer": 6.7, "ios": 7.5, "mac": 8.2, "nube": 7.2, "puerto": 5.6, "mall": 5.0, "energia": 6.4]
        static let corteNube: CGFloat = 0.13          // medio ángulo del corte de la circunvalación bajo la escalera de La nube
        static let cuartelAng: CGFloat = -0.785      // entre Urgencias y la Bodega del Mac, mirando al palacio
        private var carabinero: Persona?
        private var barrera = SCNNode(), aberturaBarrera: CGFloat = 0
        private var guardiaRonda: Persona?
        private var helicoptero = SCNNode(), aviones: [SCNNode] = [], intruso = SCNNode()
        private var refuerzos: [SCNNode] = [], alertaDesde: CGFloat?   // cazas y helicópteros de combate que despegan ante una amenaza
        nonisolated static let acceso: CGFloat = 0.645      // rumbo de la avenida de acceso y el puente (entre Bodega del Mac y Taller iOS)
        private var focos: [SCNMaterial] = []
        private var estrellas = SCNNode()           // cielo estrellado nítido (sigue a la cámara)
        private var puerto: PuertoYFlota?          // puerto de proveedores y grupo del portaaviones
        private var metro: MetroVilla?             // metro elevado: Línea Circular con 9 estaciones, ramal y cocheras
        private var sol = SCNNode(), ambiente = SCNNode()
        private var ultimoCielo = -1
        /// De noche (sin emergencia en los agentes ni en el Mac) se retiran el desfile, el tanque en patrulla, el camión del
        /// convoy y los bañistas; el segundo caza queda en su refugio.
        private var soloDeDia: [SCNNode] = [], soloDeNoche: [SCNNode] = [], cazaReserva: (SCNNode, SCNVector3)?
        private var esNoche = false, nocheQuieta: Bool?
        /// Noche sin emergencia: los agentes «en atención» no cuentan; sí un agente en falla, una alerta de seguridad o el disco o la temperatura del Mac.
        var nocheTranquila: Bool { esNoche && !incidentes.contains { !$0.titulo.hasSuffix("en atención") } }
        private var horaActual = 12, horaLeida: CFTimeInterval = -100
        var tema = "auto"                       // auto (hora del Mac), claro u oscuro
        var nube = Nube()
        // Cámara orbital propia (como OrbitControls de la web): cada valor se acerca suave a su meta.
        private var objetivo = SCNVector3(0, 0, 0), giro: CGFloat = 0, inclinacion: CGFloat = 0.61, distancia: CGFloat = 80
        private var metaObjetivo = SCNVector3(0, 0, 0), metaGiro: CGFloat = 0, metaInclinacion: CGFloat = 0.61, metaDistancia: CGFloat = 80
        private var suavidad: CGFloat = 10      // baja durante un vuelo animado
        private var teclas = Set<UInt16>()

        static let posiciones: [String: CGPoint] = ["urg": CGPoint(x: -37, y: -4), "cer": CGPoint(x: -6.5, y: -39),
                                                    "nube": CGPoint(x: 30, y: -27), "ios": CGPoint(x: 37, y: 12), "mac": CGPoint(x: 1.3, y: 40),
                                                    "puerto": PuertoYFlota.centro, "mall": Mall.centro].merging(Islas.posiciones) { a, _ in a }
        static let radios: [String: CGFloat] = ["urg": 13, "cer": 12, "nube": 9.5, "ios": 13.5, "mac": 16, "puerto": 6, "mall": 5].merging(Islas.radios) { a, _ in a }   // según cuántos agentes tiene cada uno
        static let audiencia = CGPoint(x: 0, y: 9.6)

        init(almacen: Almacen) {
            self.almacen = almacen
            super.init()
            ControlVilla.shared.coord = self
            montarBase()
            NotificationCenter.default.addObserver(forName: .villaCamara, object: nil, queue: .main) { [weak self] n in
                let accion = n.object as? String ?? ""
                MainActor.assumeIsolated { self?.mover(accion) }
            }
        }

        func conectar(_ v: SCNView) {
            vista = v
            let e = v.displayLink(target: self, selector: #selector(tick(_:)))
            e.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
            e.add(to: .main, forMode: .common)
            enlace = e
        }
        func desconectar() { enlace?.invalidate(); enlace = nil }

        private var auditado = false, inicioAuditoria: CFTimeInterval = 0
        /// Recorre la ruta de cada vehículo y comprueba que su silueta no se cruce con muros, pilares, oficinas,
        /// pizarras, árboles ni arbustos (la misma grilla con que caminan los agentes). Deja un informe legible.
        private func auditarFisica() {
            auditado = true
            var lineas: [String] = ["Auditoría física · \(Date())"]
            func choca(_ p: CGPoint, _ rumbo: CGFloat, _ largo: CGFloat, _ ancho: CGFloat) -> CGPoint? {
                let f = CGPoint(x: sin(rumbo), y: cos(rumbo)), l = CGPoint(x: cos(rumbo), y: -sin(rumbo))
                var a = -largo / 2
                while a <= largo / 2 + 0.01 {
                    var b = -ancho / 2
                    while b <= ancho / 2 + 0.01 {
                        let q = CGPoint(x: p.x + f.x * a + l.x * b, y: p.y + f.y * a + l.y * b)
                        if !nav.libre(q) { return q }
                        b += 0.25
                    }
                    a += 0.25
                }
                return nil
            }
            func revisar(_ nombre: String, _ ruta: [CGPoint], _ largo: CGFloat, _ ancho: CGFloat, cerrada: Bool, ignorar: (CGPoint) -> Bool = { _ in false }) {
                var malos = 0, ejemplos: [CGPoint] = []
                let tramos = cerrada ? ruta.count : ruta.count - 1
                for i in 0..<max(0, tramos) {
                    let p = ruta[i], q = ruta[(i + 1) % ruta.count], d = hypot(q.x - p.x, q.y - p.y)
                    guard d > 0.01 else { continue }
                    let rumbo = atan2(q.x - p.x, q.y - p.y)
                    var t: CGFloat = 0
                    while t <= d {
                        let c = CGPoint(x: p.x + (q.x - p.x) * t / d, y: p.y + (q.y - p.y) * t / d)
                        if hypot(c.x, c.y) < 76.55 - largo / 2, !ignorar(c), let x = choca(c, rumbo, largo, ancho) {
                            malos += 1
                            if ejemplos.count < 3 && !ejemplos.contains(where: { hypot($0.x - x.x, $0.y - x.y) < 3 }) { ejemplos.append(x) }
                        }
                        t += 0.5
                    }
                }
                lineas.append(malos == 0 ? "OK      \(nombre)" : "CHOQUE  \(nombre): \(malos) posiciones en " + ejemplos.map { String(format: "(x %.1f, z %.1f)", $0.x, $0.y) }.joined(separator: " "))
            }
            for (k, v) in vehiculos.enumerated() { revisar("vehículo \(k) (tránsito)", v.trazado, v.largo, v.ancho, cerrada: true) }
            // Holgura: a cada costado de un vehículo en marcha debe quedar ≥ 1 m libre de edificios y mobiliario
            var estrechos: [(CGPoint, Int)] = []
            for (k, v) in vehiculos.enumerated() {
                let ruta = v.trazado
                for i in 0..<ruta.count {
                    let p = ruta[i], q = ruta[(i + 1) % ruta.count], d = hypot(q.x - p.x, q.y - p.y)
                    guard d > 0.01 else { continue }
                    let rumbo = atan2(q.x - p.x, q.y - p.y)
                    var t: CGFloat = 0
                    while t <= d {
                        let c = CGPoint(x: p.x + (q.x - p.x) * t / d, y: p.y + (q.y - p.y) * t / d)
                        if choca(c, rumbo, v.largo, v.ancho) == nil,
                           let x = choca(c, rumbo, v.largo, v.ancho + 1.44),
                           !estrechos.contains(where: { hypot($0.0.x - x.x, $0.0.y - x.y) < 2.5 }) { estrechos.append((x, k)) }
                        t += 0.5
                    }
                }
            }
            for (x, k) in estrechos.prefix(80) {
                lineas.append(String(format: "ESTRECHO vehículo %d (%@): obstáculo a < 1 m del costado en (x %.1f, z %.1f) r %.1f rumbo %.0f° · ", k, vehiculos[k].raiz.name ?? "", x.x, x.y, hypot(x.x, x.y), atan2(x.x, x.y) * 180 / .pi) + (nav.quien(x) == "?" ? "agua u orilla (baranda de puente o borde de isla)" : nav.quien(x)))
            }
            if estrechos.isEmpty { lineas.append("OK      holgura ≥ 1 m a ambos costados de todos los vehículos") }
            let cu = centroCuartel
            let enCuartel: (CGPoint) -> Bool = { hypot($0.x - cu.x, $0.y - cu.y) < 6.2 }
            for d in [nil, "sede"] + Coordinador.posiciones.keys.filter({ !Islas.zonas.contains($0) }).sorted() {
                revisar("carro bomba → \(d ?? "cuartel")", rutaBomberos(d), 7.2, 2.4, cerrada: false, ignorar: enCuartel)
            }
            let c = Coordinador.posiciones["urg"]!, hy = atan2(-c.x, -c.y)
            for (k, a) in ambHosp.enumerated() {
                let ruta = a.ruta.map { CGPoint(x: c.x + $0.x * cos(hy) + $0.y * sin(hy), y: c.y - $0.x * sin(hy) + $0.y * cos(hy)) }
                revisar("ambulancia \(k + 1) del hospital", ruta, 5.2, 2.4, cerrada: false)
            }
            // Oficinas: ninguna encimada con otra (prueba de ejes separadores entre rectángulos girados de 3,6 × 3,4 m)
            func esquinas(_ o: Oficina) -> [CGPoint] {
                let p = o.raiz.position, y = CGFloat(o.raiz.eulerAngles.y)
                return [(-1.8, -1.7), (1.8, -1.7), (1.8, 1.7), (-1.8, 1.7)].map { (x, z) in
                    CGPoint(x: p.x + x * cos(y) + z * sin(y), y: p.z - x * sin(y) + z * cos(y)) }
            }
            func solapan(_ a: [CGPoint], _ b: [CGPoint]) -> Bool {
                for poli in [a, b] {
                    for k in 0..<4 {
                        let p1 = poli[k], p2 = poli[(k + 1) % 4], eje = CGPoint(x: -(p2.y - p1.y), y: p2.x - p1.x)
                        let pa = a.map { $0.x * eje.x + $0.y * eje.y }, pb = b.map { $0.x * eje.x + $0.y * eje.y }
                        if pa.max()! <= pb.min()! + 0.01 || pb.max()! <= pa.min()! + 0.01 { return false }
                    }
                }
                return true
            }
            let lista = (Array(oficinas) + oficinasNube.map { (key: $0.key + " (nube)", value: $0.value) }).sorted { $0.key < $1.key }
            var encimadas = 0
            for i in 0..<lista.count { for j in (i + 1)..<lista.count where solapan(esquinas(lista[i].value), esquinas(lista[j].value)) {
                encimadas += 1; lineas.append("CHOQUE  oficinas \(lista[i].key) y \(lista[j].key) encimadas")
            } }
            if encimadas == 0 { lineas.append("OK      oficinas: ninguna encimada (\(lista.count))") }
            var atrapados = 0
            for (id, p) in personas where !nav.libre(p.pos) && hypot(p.pos.x - (oficinas[id]?.silla.x ?? 0), p.pos.y - (oficinas[id]?.silla.y ?? 0)) > 0.6
                && hypot(p.pos.x - (oficinasNube[id]?.silla.x ?? 1e6), p.pos.y - (oficinasNube[id]?.silla.y ?? 1e6)) > 0.6 { atrapados += 1; lineas.append("AVISO   \(id) parado dentro de un obstáculo") }
            lineas.append(atrapados == 0 ? "OK      agentes: ninguno dentro de un obstáculo" : "")
            let ruta = Almacen.carpetaLocal + "/trabajo/auditoria-fisica.txt"
            try? lineas.joined(separator: "\n").write(toFile: ruta, atomically: true, encoding: .utf8)
            // Plano cenital a pedido (para diseñar trazados): crear trabajo/pedir-plano y reabrir la app.
            let pedido = Almacen.carpetaLocal + "/trabajo/pedir-plano"
            if FileManager.default.fileExists(atPath: pedido) {
                try? FileManager.default.removeItem(atPath: pedido)
                let cam = SCNNode(); cam.camera = SCNCamera(); cam.camera?.usesOrthographicProjection = true
                cam.camera?.orthographicScale = 215; cam.camera?.zFar = 1000
                cam.position = SCNVector3(0, 400, 0); cam.eulerAngles.x = -.pi / 2
                escena.rootNode.addChildNode(cam)
                let rnd = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil); rnd.scene = escena; rnd.pointOfView = cam
                let img = rnd.snapshot(atTime: 0, with: CGSize(width: 3000, height: 3000), antialiasingMode: .multisampling4X)
                cam.removeFromParentNode()
                if let t = img.tiffRepresentation, let b = NSBitmapImageRep(data: t), let png = b.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: Almacen.carpetaLocal + "/trabajo/plano-cenital.png"))
                }
            }
        }

        /// Cualquier interacción con la villa reinicia el reloj de reposo (10 min sin tocarla la pone en pausa).
        private var ultimaInteraccion = CACurrentMediaTime()
        func tocado() { ultimaInteraccion = CACurrentMediaTime(); ControlVilla.shared.despertar() }

        /// Ahorro: con la ventana tapada o minimizada la villa se congela (sin dibujar ni simular);
        /// con la app en segundo plano pero visible, baja a 12 fps. Al volver, retoma 30 fps.
        func ajustarRitmo() {
            guard let v = vista else { return }
            let c = ControlVilla.shared
            let visible = (v.window?.occlusionState.contains(.visible) ?? false) && !c.pausada && !c.dormida
            let fps = NSApp.isActive ? 30 : 12
            v.isPlaying = visible
            v.preferredFramesPerSecond = fps
            enlace?.isPaused = !visible
            enlace?.preferredFrameRateRange = CAFrameRateRange(minimum: Float(min(fps, 20)), maximum: Float(fps), preferred: Float(fps))
            if !visible { ultimo = 0 }        // al volver no da un salto de tiempo
        }

        // MARK: Altura del piso (los pies siguen placas, escalera y nube)

        func alturaPiso(_ p: CGPoint) -> CGFloat {
            if let h = nube.altura(p) { return h }
            for (zid, c) in Coordinador.posiciones where zid != "nube" {
                if hypot(p.x - c.x, p.y - c.y) <= Coordinador.radios[zid]! { return 0.12 }
            }
            if hypot(p.x, p.y) <= 14 { return 0.12 }
            var d = atan2(p.x, p.y) - Mall.ang             // piso de mármol del atrio del mall
            while d > .pi { d -= 2 * .pi }; while d < -.pi { d += 2 * .pi }
            let rm = hypot(p.x, p.y)
            if abs(d) <= Mall.atrio && rm >= Mall.rFrente - 1.2 && rm <= Mall.rFondo { return 0.12 }
            return 0.02
        }

        // MARK: Escena base

        private func montarBase() {
            let cam = SCNCamera()
            cam.zNear = 0.3; cam.zFar = 700; cam.fieldOfView = 48
            cam.wantsHDR = true; cam.bloomIntensity = 0.35; cam.bloomThreshold = 0.9
            cam.screenSpaceAmbientOcclusionIntensity = 0      // SSAO apagado: costaba mucho y las sombras ya dan volumen
            cam.wantsExposureAdaptation = false
            camara.camera = cam
            camara.position = SCNVector3(0, 46, 66); camara.look(at: SCNVector3(0, 0, 0))
            escena.rootNode.addChildNode(camara)

            ambiente.light = SCNLight(); ambiente.light!.type = .ambient
            escena.rootNode.addChildNode(ambiente)
            sol.light = SCNLight(); sol.light!.type = .directional
            sol.light!.castsShadow = true; sol.light!.shadowMode = .deferred; sol.light!.shadowSampleCount = 4
            sol.light!.shadowRadius = 2.5; sol.light!.orthographicScale = 95; sol.light!.shadowMapSize = CGSize(width: 2048, height: 2048)
            sol.light!.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.4)
            escena.rootNode.addChildNode(sol)

            // Mar con reflejo e isla con pasto texturizado y playa
            // Sin espejo: el reflejo de SCNFloor volvía a dibujar toda la villa en cada cuadro (el doble de trabajo).
            // El agua PBR igual refleja el cielo por la iluminación de ambiente.
            let piso = SCNFloor(); piso.reflectivity = 0
            let mar = nodo(piso, Mat.pbr(NSColor(calibratedRed: 0.10, green: 0.30, blue: 0.40, alpha: 1), rugosidad: 0.15), y: -0.5)
            escena.rootNode.addChildNode(mar)
            playaNatural(centro: .zero, desde: 79, balneario: Islas.angBalneario)   // playa en pendiente hasta el agua (sin escalón), con oleaje
            escena.rootNode.addChildNode(nodo(SCNCylinder(radius: 76, height: 0.5), Mat.textura(.pasto, repetir: 40), y: -0.24))
            nav.anillo(0, 0, 77.5, hueco: 0, ancho: 0) // no salir de la isla

            let estatico = SCNNode()
            montarSede(estatico)
            montarCaminos(estatico)
            montarBomberos(estatico)
            montarPlazas(estatico)
            let pf = PuertoYFlota(escena: escena, nav: nav)     // antes que los árboles: deja su espacio ocupado
            pf.montar(estatico); focos += pf.luces; puerto = pf
            montarMall(estatico)                           // centro comercial: también antes de los árboles
            montarIslas(estatico)                          // aeropuerto, isla distrito, caleta, balneario, marina y letrero
            let mt = MetroVilla(escena: escena, nav: nav); mt.montar(estatico); focos += mt.luces; metro = mt
            montarArboles(estatico)
            montarAmbulancia(estatico)
            montarAccesos(estatico)
            Coordinador.hornear(estatico)
            escena.rootNode.addChildNode(estatico.flattenedClone())
            montarEstacionados()
            montarPantallon()   // un solo dibujo para todo lo que no se mueve
            montarGuardias()
            montarTrafico()
            montarCamiones()
            vehiculos += Islas.buses                       // buses de enlace a las islas (al final: no alteran el cupo del anillo)
            montarDefensa()
            estrellas = cieloEstrellado(); escena.rootNode.addChildNode(estrellas)
            actualizarCielo()
        }

        /// Palacio de gobierno neoclásico (estilo La Moneda): dos pisos, pórtico de columnas con frontón,
        /// cornisa, balaustrada y bandera. El frente mira a la audiencia (+z).
        private func montarSede(_ r: SCNNode) {
            let crema = Mat.textura(.estuco, repetir: 4, tinte: "#efe5cf")
            let blanco = Mat.pbr(NSColor(Color(hex: "#f7f2e6")), rugosidad: 0.55)
            let marmol = Mat.textura(.marmol, repetir: 3)
            let madera = Mat.pbr(NSColor(Color(hex: "#4a3524")), rugosidad: 0.6)
            let v = ventana()
            r.addChildNode(nodo(SCNCylinder(radius: 14, height: 0.24), Mat.textura(.adoquin, repetir: 14), y: 0.0))
            // Basamento, cuerpo de dos pisos, faja entre pisos, cornisa y parapeto
            r.addChildNode(nodo(SCNBox(width: 15, height: 0.6, length: 9, chamferRadius: 0.03), marmol, y: 0.42))
            r.addChildNode(nodo(SCNBox(width: 14, height: 6, length: 8, chamferRadius: 0.04), crema, y: 3.7))
            r.addChildNode(nodo(SCNBox(width: 14.15, height: 0.22, length: 8.15, chamferRadius: 0), blanco, y: 3.75))
            r.addChildNode(nodo(SCNBox(width: 14.6, height: 0.42, length: 8.6, chamferRadius: 0.02), blanco, y: 6.9))
            r.addChildNode(nodo(SCNBox(width: 14.3, height: 0.18, length: 8.3, chamferRadius: 0), blanco, y: 7.85))
            for k in 0..<4 {   // balaustrada en los cuatro lados
                let largo: CGFloat = k < 2 ? 14.2 : 8.2, n = Int(largo / 0.42)
                for b in 0..<n {
                    let t = -largo / 2 + 0.21 + CGFloat(b) * largo / CGFloat(n)
                    let (x, z): (CGFloat, CGFloat) = k == 0 ? (t, 4.15) : k == 1 ? (t, -4.15) : k == 2 ? (7.15, t) : (-7.15, t)
                    r.addChildNode(nodo(SCNCylinder(radius: 0.07, height: 0.6), blanco, y: 7.4, x: x, z: z))
                }
            }
            // Pórtico central: cuerpo saliente, 4 columnas, entablamento y frontón triangular
            r.addChildNode(nodo(SCNBox(width: 5.2, height: 6, length: 1.0, chamferRadius: 0), crema, y: 3.7, z: 4.5))
            for x: CGFloat in [-1.95, -0.65, 0.65, 1.95] {
                r.addChildNode(nodo(SCNCylinder(radius: 0.3, height: 5.7), marmol, y: 3.55, x: x, z: 5.55))
                r.addChildNode(nodo(SCNBox(width: 0.75, height: 0.25, length: 0.75, chamferRadius: 0), blanco, y: 0.85, x: x, z: 5.55))
                r.addChildNode(nodo(SCNBox(width: 0.75, height: 0.25, length: 0.75, chamferRadius: 0), blanco, y: 6.5, x: x, z: 5.55))
                nav.circulo(x, 5.55, 0.32)
            }
            r.addChildNode(nodo(SCNBox(width: 5.8, height: 0.5, length: 1.7, chamferRadius: 0), blanco, y: 6.85, z: 5.1))
            let tri = NSBezierPath(); tri.move(to: NSPoint(x: -3.0, y: 0)); tri.line(to: NSPoint(x: 3.0, y: 0)); tri.line(to: NSPoint(x: 0, y: 1.5)); tri.close()
            let fronton = SCNShape(path: tri, extrusionDepth: 1.7)
            r.addChildNode(nodo(fronton, blanco, y: 7.1, z: 5.1))
            // Escudo en el frontón y puerta principal
            r.addChildNode(nodo(SCNCylinder(radius: 0.38, height: 0.06), Mat.pbr(NSColor(Color(hex: "#c9a13b")), rugosidad: 0.3, metal: 0.9), y: 7.6, z: 5.97))
            r.childNodes.last?.eulerAngles.x = .pi / 2
            r.addChildNode(nodo(SCNBox(width: 1.7, height: 2.9, length: 0.12, chamferRadius: 0.02), madera, y: 2.17, z: 5.02))
            r.addChildNode(nodo(SCNPlane(width: 1.5, height: 0.6), v, y: 4.6, z: 5.02))
            // Ventanas de dos pisos con dintel, en los cuatro lados
            let dintel = blanco
            func ventanal(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat, _ giro: CGFloat) {
                let g = SCNNode(); g.position = SCNVector3(x, y, z); g.eulerAngles.y = giro
                g.addChildNode(nodo(SCNBox(width: 1.0, height: 1.7, length: 0.06, chamferRadius: 0), blanco, z: 0.0))
                g.addChildNode(nodo(SCNPlane(width: 0.8, height: 1.5), v, z: 0.035))
                g.addChildNode(nodo(SCNBox(width: 1.2, height: 0.16, length: 0.14, chamferRadius: 0), dintel, y: 0.95, z: 0.04))
                r.addChildNode(g)
            }
            for y: CGFloat in [2.25, 5.15] {
                for x: CGFloat in [-6.0, -4.75, -3.5, 3.5, 4.75, 6.0] { ventanal(x, y, 4.02, 0); ventanal(x, y, -4.02, .pi) }
                for x: CGFloat in [-2.0, 0, 2.0] { ventanal(x, y, -4.02, .pi) }
                for z: CGFloat in [-2.6, 0, 2.6] { ventanal(7.02, y, z, .pi / 2); ventanal(-7.02, y, z, -.pi / 2) }
            }
            // Escalinata hacia la audiencia
            for k in 0..<3 {
                let kk = CGFloat(k)
                r.addChildNode(nodo(SCNBox(width: 6.4 - kk * 0.3, height: 0.2, length: 0.45, chamferRadius: 0), marmol, y: 0.22 + kk * 0.2, z: 6.75 - kk * 0.45))
            }
            // Bandera en el techo
            r.addChildNode(nodo(SCNCylinder(radius: 0.06, height: 3.2), Mat.pbr(NSColor(calibratedWhite: 0.9, alpha: 1), metal: 0.8), y: 9.5, z: 1.5))
            let bandera = SCNMaterial(); bandera.diffuse.contents = Pizarra.bandera(); bandera.isDoubleSided = true; bandera.lightingModel = .physicallyBased
            r.addChildNode(nodo(SCNPlane(width: 1.8, height: 1.2), bandera, y: 10.4, x: 0.95, z: 1.5))
            nav.rect(0, 0, 7.5, 4.5, 0)
            nav.rect(0, 4.6, 2.6, 0.6, 0)
            escena.rootNode.addChildNode(etiqueta("Palacio de gobierno", y: 12.6, grande: true, icono: iconoBarrio["sede"], color: NSColor(Color(hex: "#b8892b"))))
            // Alcalde, el CEO, recibe en la audiencia, al pie de la escalinata
            let doc = Persona.ceo()
            doc.raiz.position = SCNVector3(-1.6, 0.12, 7.9); doc.raiz.eulerAngles.y = 0.5
            escena.rootNode.addChildNode(doc.raiz)
            nav.circulo(-1.6, 7.9, 0.35)
        }

        private func montarCaminos(_ r: SCNNode) {
            let poste = Mat.pbr(NSColor(calibratedWhite: 0.15, alpha: 1), rugosidad: 0.4, metal: 0.8)
            let luz = Mat.emisivo(NSColor(calibratedRed: 1, green: 0.85, blue: 0.55, alpha: 1)); focos.append(luz)
            for (zid, p) in Coordinador.posiciones where zid != "mall" && !Islas.zonas.contains(zid) {     // al mall se llega por el anillo
                let d = hypot(p.x, p.y), ang = atan2(p.x, p.y)
                let ini: CGFloat = 13.5, fin = d - Coordinador.radios[zid]! + 0.5
                guard fin > ini else { continue }
                let largo = fin - ini, medio = (ini + fin) / 2
                let c = nodo(SCNBox(width: 3, height: 0.06, length: largo, chamferRadius: 0), Mat.textura(.adoquin, repetir: largo / 3), y: 0.03,
                             x: sin(ang) * medio, z: cos(ang) * medio)
                c.eulerAngles.y = ang
                r.addChildNode(c)
                // Faroles a ambos lados (obstáculos reales)
                var t = ini + 4
                while t < fin - 2 {
                    if t > 54 && t < 64.5 { t += 7; continue }     // sin faroles sobre el anillo periférico (avenida del puerto)
                    for lado: CGFloat in [-1, 1] {
                        let x = sin(ang) * t + cos(ang) * lado * 2.1, z = cos(ang) * t - sin(ang) * lado * 2.1
                        r.addChildNode(nodo(SCNCylinder(radius: 0.07, height: 3.2), poste, y: 1.6, x: x, z: z))
                        r.addChildNode(nodo(SCNSphere(radius: 0.2), luz, y: 3.25, x: x, z: z))
                        nav.circulo(x, z, 0.1)
                    }
                    t += 7
                }
            }
        }

        private func montarArboles(_ r: SCNNode) {
            // Paleta compartida: pocos materiales = pocos dibujos aunque haya muchos árboles (todo se fusiona en un bloque).
            var gen = Azar(semilla: 42)
            var puestos = 0
            let corteza = Mat.textura(.corteza, repetir: 1), abedul = Mat.pbr(NSColor(calibratedWhite: 0.86, alpha: 1), rugosidad: 0.8)
            let verdes = [(0.27, 0.55, 0.30), (0.30, 0.62, 0.36), (0.24, 0.48, 0.42), (0.33, 0.58, 0.33), (0.22, 0.45, 0.26)].map {
                Mat.pbr(NSColor(hue: $0.0, saturation: $0.1, brightness: $0.2, alpha: 1), rugosidad: 0.92) }
            let pino = Mat.pbr(NSColor(hue: 0.38, saturation: 0.55, brightness: 0.24, alpha: 1), rugosidad: 0.95)
            func copa(_ x: CGFloat, _ z: CGFloat, _ alto: CGFloat, _ m: SCNMaterial) {      // frondoso: varias masas irregulares
                for k in 0..<5 {
                    let a = CGFloat(k) * 1.26 + gen.real(), d = k == 0 ? 0 : alto * 0.17
                    let rr = alto * (k == 0 ? 0.3 : 0.2 + gen.real() * 0.06)
                    let b = nodo(SCNSphere(radius: rr), k % 2 == 0 ? m : verdes[(k + 1) % verdes.count], y: alto * (0.62 + (k == 0 ? 0.08 : gen.real() * 0.12)), x: x + cos(a) * d, z: z + sin(a) * d)
                    b.scale = SCNVector3(1, 0.82, 1); r.addChildNode(b)
                }
            }
            for _ in 0..<400 where puestos < 46 {
                let a = gen.real() * .pi * 2, d = 44 + gen.real() * 29
                let p = CGPoint(x: cos(a) * d, y: sin(a) * d)
                if d > 54 && d < 66 { continue }                         // anillo periférico
                let ac = Coordinador.acceso
                if abs(p.x * cos(ac) - p.y * sin(ac)) < 7 && p.x * sin(ac) + p.y * cos(ac) > 0 { continue }   // avenida de acceso
                if Coordinador.posiciones.contains(where: { hypot(p.x - $0.value.x, p.y - $0.value.y) < Coordinador.radios[$0.key]! + 6 }) { continue }
                if !nav.libre(p) || !PuertoYFlota.libre(p) || !Mall.libre(p) || !Islas.libre(p) || !MetroVilla.libre(p) { continue }
                let alto = 6 + gen.real() * 4, especie = gen.real(), m = verdes[Int(gen.real() * 4.99)]
                if especie < 0.55 {             // frondoso con tronco que se abre en dos ramas
                    r.addChildNode(nodo(SCNCylinder(radius: 0.22, height: alto * 0.5), corteza, y: alto * 0.25, x: p.x, z: p.y))
                    for sx: CGFloat in [-1, 1] {
                        let rama = nodo(SCNCylinder(radius: 0.09, height: alto * 0.3), corteza, y: alto * 0.55, x: p.x + sx * 0.2, z: p.y)
                        rama.eulerAngles.z = -sx * 0.45; r.addChildNode(rama)
                    }
                    copa(p.x, p.y, alto, m)
                } else if especie < 0.82 {      // conífera: conos escalonados
                    r.addChildNode(nodo(SCNCylinder(radius: 0.18, height: alto * 0.35), corteza, y: alto * 0.17, x: p.x, z: p.y))
                    for k in 0..<3 {
                        let kk = CGFloat(k)
                        r.addChildNode(nodo(SCNCone(topRadius: 0, bottomRadius: alto * (0.36 - kk * 0.08), height: alto * 0.5), pino, y: alto * (0.42 + kk * 0.22), x: p.x, z: p.y))
                    }
                } else {                        // abedul: tronco claro y copa ovalada alta
                    r.addChildNode(nodo(SCNCylinder(radius: 0.13, height: alto * 0.7), abedul, y: alto * 0.35, x: p.x, z: p.y))
                    let c = nodo(SCNSphere(radius: alto * 0.24), verdes[1], y: alto * 0.78, x: p.x, z: p.y); c.scale = SCNVector3(0.8, 1.5, 0.8)
                    r.addChildNode(c)
                }
                nav.circulo(p.x, p.y, 0.35)
                puestos += 1
            }
            // Arbustos entre la circunvalación y los árboles, fuera de barrios, caminos, plazas y calles
            var arbustos = 0
            for _ in 0..<600 where arbustos < 70 {
                let a = gen.real() * .pi * 2, d = 25 + gen.real() * 18
                let p = CGPoint(x: sin(a) * d, y: cos(a) * d)
                if Coordinador.posiciones.contains(where: { hypot(p.x - $0.value.x, p.y - $0.value.y) < Coordinador.radios[$0.key]! + 1.5 }) { continue }
                if Coordinador.plazas.contains(where: { hypot(p.x - $0.c.x, p.y - $0.c.y) < $0.r + 1.5 }) { continue }
                var enCalle = false
                var rumbos = Coordinador.posiciones.values.map { atan2($0.x, $0.y) }
                rumbos += [Coordinador.acceso, Coordinador.cuartelAng] + Coordinador.plazas.map(\.ang)
                for g in rumbos where abs(p.x * cos(g) - p.y * sin(g)) < 5.5 && p.x * sin(g) + p.y * cos(g) > 0 { enCalle = true }
                if enCalle || !nav.libre(p) { continue }
                if hypot(p.x - centroCuartel.x, p.y - centroCuartel.y) < 11 { continue }
                if (0..<6).contains(where: { k in let a = CGFloat(k) * .pi / 3; return !nav.libre(CGPoint(x: p.x + cos(a) * 1.1, y: p.y + sin(a) * 1.1)) }) { continue }
                let m = verdes[Int(gen.real() * 4.99)]
                for k in 0..<3 {
                    let rr = 0.35 + gen.real() * 0.3, o = CGFloat(k) * 2.1
                    r.addChildNode(nodo(SCNSphere(radius: rr), m, y: rr * 0.6, x: p.x + cos(o) * 0.35, z: p.y + sin(o) * 0.35))
                }
                nav.circulo(p.x, p.y, 0.6)
                arbustos += 1
            }
            // Palmeras en la playa (fuera del puente)
            let hojaPalma = Mat.pbr(NSColor(hue: 0.25, saturation: 0.6, brightness: 0.42, alpha: 1), rugosidad: 0.85)
            for k in 0..<16 {
                let a = CGFloat(k) / 16 * .pi * 2 + 0.2
                if abs(atan2(sin(a - Coordinador.acceso), cos(a - Coordinador.acceso))) < 0.15 { continue }
                let d = 79 + gen.real() * 2.5, x0 = sin(a) * d, z0 = cos(a) * d
                if !PuertoYFlota.libre(CGPoint(x: x0, y: z0)) || !Mall.libre(CGPoint(x: x0, y: z0)) || !Islas.libre(CGPoint(x: x0, y: z0)) || !MetroVilla.libre(CGPoint(x: x0, y: z0)) { continue }        // el puerto ocupa esa playa
                let alto = 4.5 + gen.real() * 2, inclina = 0.15 + gen.real() * 0.15
                for t in 0..<4 {                // tronco en cuatro tramos que se curvan hacia el mar
                    let tt = CGFloat(t), y = alto * (tt + 0.5) / 4, desp = inclina * pow(tt / 4, 2) * alto
                    let tr = nodo(SCNCylinder(radius: 0.17 - tt * 0.02, height: alto / 4 + 0.05), corteza, y: y - 0.25, x: x0 + sin(a) * desp, z: z0 + cos(a) * desp)
                    tr.eulerAngles = SCNVector3(cos(a) * inclina * tt * 0.5, 0, -sin(a) * inclina * tt * 0.5)
                    r.addChildNode(tr)
                }
                let cx = x0 + sin(a) * inclina * alto * 0.56, cz = z0 + cos(a) * inclina * alto * 0.56, cy = alto - 0.3
                for h in 0..<7 {
                    let yaw = CGFloat(h) / 7 * .pi * 2 + gen.real() * 0.3, caida: CGFloat = 0.45
                    let hoja = nodo(SCNBox(width: 0.45, height: 0.03, length: 2.2, chamferRadius: 0.01), hojaPalma,
                                    y: cy - sin(caida) * 1.0, x: cx + sin(yaw) * cos(caida) * 1.0, z: cz + cos(yaw) * cos(caida) * 1.0)
                    hoja.eulerAngles = SCNVector3(caida, yaw, 0)
                    r.addChildNode(hoja)
                }
                r.addChildNode(nodo(SCNSphere(radius: 0.22), corteza, y: cy, x: cx, z: cz))
            }
        }

        /// Huecos entre barrios (rumbo en grados como los caminos: x = sen, z = cos) — los usan las plazas y los arbustos.
        static let plazas: [(c: CGPoint, r: CGFloat, ang: CGFloat, tipo: String)] = [
            (CGPoint(x: sin(-133 * CGFloat.pi / 180) * 34, y: cos(-133 * CGFloat.pi / 180) * 34), 5, -133 * .pi / 180, "pileta"),
            (CGPoint(x: sin(161 * CGFloat.pi / 180) * 34, y: cos(161 * CGFloat.pi / 180) * 34), 4.3, 161 * .pi / 180, "parque"),
            (CGPoint(x: sin(104 * CGFloat.pi / 180) * 33, y: cos(104 * CGFloat.pi / 180) * 33), 5.2, 104 * .pi / 180, "estacionamiento")]

        /// Rellena los espacios vacíos: plaza con pileta (entre Segundo cerebro y Urgencias), parque con bancas y jardín
        /// (entre Segundo cerebro y La nube) y estacionamiento de visitas (entre La nube y el Taller iOS), cada uno con su sendero.
        private func montarPlazas(_ r: SCNNode) {
            let piedra = Mat.textura(.adoquin, repetir: 4, tinte: "#d8cfc0", mezcla: 0.4), marmol = Mat.textura(.marmol, repetir: 1)
            let agua = Mat.pbr(NSColor(calibratedRed: 0.22, green: 0.55, blue: 0.72, alpha: 1), rugosidad: 0.04, metal: 0.25)
            let madera = Mat.textura(.madera, repetir: 1, tinte: "#7a5634")
            let hierro = Mat.pbr(NSColor(calibratedWhite: 0.14, alpha: 1), rugosidad: 0.4, metal: 0.8)
            let seto = Mat.pbr(NSColor(calibratedRed: 0.2, green: 0.42, blue: 0.18, alpha: 1), rugosidad: 0.9)
            let tierra = Mat.pbr(NSColor(calibratedRed: 0.36, green: 0.26, blue: 0.18, alpha: 1), rugosidad: 1)
            let flores = [NSColor.systemPink, .systemYellow, .systemPurple, .systemRed, .white].map { Mat.pbr($0, rugosidad: 0.8) }
            let asfalto = Mat.pbr(NSColor(calibratedWhite: 0.2, alpha: 1), rugosidad: 0.85), blanco = Mat.pbr(.white, rugosidad: 0.6)
            let luz = Mat.emisivo(NSColor(calibratedRed: 1, green: 0.85, blue: 0.55, alpha: 1)); focos.append(luz)
            var g = Azar(semilla: 7)
            func sendero(_ ang: CGFloat, hasta d: CGFloat, ancho: CGFloat = 2, m: SCNMaterial? = nil) {   // une con la circunvalación (r 21)
                let ini: CGFloat = 22.2, largo = d - ini, md = (ini + d) / 2
                let c = nodo(SCNBox(width: ancho, height: 0.06, length: largo, chamferRadius: 0), m ?? Mat.textura(.adoquin, repetir: largo / 3), y: 0.03, x: sin(ang) * md, z: cos(ang) * md)
                c.eulerAngles.y = ang; r.addChildNode(c)
            }
            func banca(_ x: CGFloat, _ z: CGFloat, mira: CGFloat) {    // asiento y respaldo de madera con patas de fierro
                let a = nodo(SCNBox(width: 1.4, height: 0.07, length: 0.42, chamferRadius: 0.02), madera, y: 0.48, x: x, z: z); a.eulerAngles.y = mira; r.addChildNode(a)
                let b = nodo(SCNBox(width: 1.4, height: 0.38, length: 0.05, chamferRadius: 0.02), madera, y: 0.75, x: x - sin(mira) * 0.21, z: z - cos(mira) * 0.21); b.eulerAngles.y = mira; r.addChildNode(b)
                for s: CGFloat in [-0.6, 0.6] { r.addChildNode(nodo(SCNCylinder(radius: 0.035, height: 0.48), hierro, y: 0.24, x: x + cos(mira) * s, z: z - sin(mira) * s)) }
                nav.circulo(x, z, 0.7)
            }
            func farol(_ x: CGFloat, _ z: CGFloat) {
                r.addChildNode(nodo(SCNCylinder(radius: 0.06, height: 3), hierro, y: 1.5, x: x, z: z))
                r.addChildNode(nodo(SCNSphere(radius: 0.2), luz, y: 3.1, x: x, z: z)); nav.circulo(x, z, 0.1)
            }
            func cantero(_ x: CGFloat, _ z: CGFloat, _ rr: CGFloat) {   // jardinera con flores de colores
                r.addChildNode(nodo(SCNCylinder(radius: rr + 0.08, height: 0.35), marmol, y: 0.17, x: x, z: z))
                r.addChildNode(nodo(SCNCylinder(radius: rr, height: 0.37), tierra, y: 0.18, x: x, z: z))
                for _ in 0..<Int(rr * 9) {
                    let a = g.real() * .pi * 2, d = g.real() * (rr - 0.1)
                    r.addChildNode(nodo(SCNSphere(radius: 0.09 + g.real() * 0.05), g.real() < 0.35 ? seto : flores[Int(g.real() * 4.99)], y: 0.42, x: x + cos(a) * d, z: z + sin(a) * d))
                }
                nav.circulo(x, z, rr + 0.1)
            }
            for pl in Coordinador.plazas {
                let c = pl.c
                switch pl.tipo {
                case "pileta":
                    r.addChildNode(nodo(SCNCylinder(radius: pl.r, height: 0.22), piedra, y: 0.01, x: c.x, z: c.y))
                    r.addChildNode(nodo(SCNCylinder(radius: 2.2, height: 0.55), marmol, y: 0.38, x: c.x, z: c.y))
                    r.addChildNode(nodo(SCNCylinder(radius: 1.95, height: 0.05), agua, y: 0.6, x: c.x, z: c.y))
                    r.addChildNode(nodo(SCNCylinder(radius: 0.22, height: 1.3), marmol, y: 1.1, x: c.x, z: c.y))
                    r.addChildNode(nodo(SCNCylinder(radius: 0.85, height: 0.16), marmol, y: 1.75, x: c.x, z: c.y))
                    r.addChildNode(nodo(SCNCylinder(radius: 0.75, height: 0.04), agua, y: 1.84, x: c.x, z: c.y))
                    r.addChildNode(nodo(SCNCone(topRadius: 0.02, bottomRadius: 0.12, height: 0.7), agua, y: 2.2, x: c.x, z: c.y))
                    nav.circulo(c.x, c.y, 2.3)
                    for k in 0..<4 {
                        let a = CGFloat(k) / 4 * .pi * 2 + .pi / 4
                        banca(c.x + sin(a) * 3.7, c.y + cos(a) * 3.7, mira: a + .pi)
                        let a2 = a + .pi / 4
                        if k % 2 == 0 { farol(c.x + sin(a2) * 4.4, c.y + cos(a2) * 4.4) } else { cantero(c.x + sin(a2) * 3.9, c.y + cos(a2) * 3.9, 0.55) }
                    }
                    sendero(pl.ang, hasta: hypot(c.x, c.y) - pl.r + 0.3)
                case "parque":
                    r.addChildNode(nodo(SCNCylinder(radius: pl.r, height: 0.16), piedra, y: 0.0, x: c.x, z: c.y))
                    r.addChildNode(nodo(SCNCylinder(radius: 2.5, height: 0.2), Mat.textura(.pasto, repetir: 3), y: 0.04, x: c.x, z: c.y))
                    // Árbol grande al centro con anillo de flores
                    r.addChildNode(nodo(SCNCylinder(radius: 0.25, height: 2.6), Mat.textura(.corteza, repetir: 1), y: 1.3, x: c.x, z: c.y))
                    for k in 0..<5 {
                        let a = CGFloat(k) * 1.26, d: CGFloat = k == 0 ? 0 : 0.9
                        let b = nodo(SCNSphere(radius: k == 0 ? 1.6 : 1.05), seto, y: k == 0 ? 3.6 : 3.1, x: c.x + cos(a) * d, z: c.y + sin(a) * d); b.scale = SCNVector3(1, 0.8, 1)
                        r.addChildNode(b)
                    }
                    for k in 0..<22 {
                        let a = CGFloat(k) / 22 * .pi * 2
                        r.addChildNode(nodo(SCNSphere(radius: 0.13), flores[k % 5], y: 0.2, x: c.x + cos(a) * 2.2, z: c.y + sin(a) * 2.2))
                    }
                    nav.circulo(c.x, c.y, 2.5)
                    for k in 0..<3 {
                        let a = CGFloat(k) / 3 * .pi * 2 + pl.ang + .pi / 3
                        banca(c.x + sin(a) * 3.3, c.y + cos(a) * 3.3, mira: a + .pi)
                    }
                    farol(c.x + sin(pl.ang + .pi) * 3.6, c.y + cos(pl.ang + .pi) * 3.6)
                    sendero(pl.ang, hasta: hypot(c.x, c.y) - pl.r + 0.3)
                default:    // estacionamiento de visitas: 4 estacionamientos en batería, 3 ocupados
                    let yaw = pl.ang
                    func local(_ lx: CGFloat, _ lz: CGFloat) -> CGPoint { CGPoint(x: c.x + lx * cos(yaw) + lz * sin(yaw), y: c.y - lx * sin(yaw) + lz * cos(yaw)) }
                    let piso = nodo(SCNBox(width: 7.6, height: 0.06, length: 10.8, chamferRadius: 0), asfalto, y: 0.05, x: c.x, z: c.y); piso.eulerAngles.y = yaw
                    r.addChildNode(piso)
                    // Calces en batería: discapacidad (azul, con pasillo achurado), adulto mayor, embarazada y uno normal
                    let fila = SCNNode(), q0 = local(1.4, -5.2)
                    fila.position = SCNVector3(q0.x, 0, q0.y); fila.eulerAngles.y = yaw - .pi / 2
                    filaCalces(fila, [.discapacidad, .adultoMayor, .embarazada, .normal], largo: 5.0, linea: blanco, amarillo: blanco, anchos: [3.0, 2.5, 2.5, 2.4])   // calces reales (autos de 4,3 m)
                    r.addChildNode(fila)
                    let cartel = SCNMaterial(); cartel.diffuse.contents = Pizarra.letrero("VISITAS"); cartel.emission.contents = Pizarra.letrero("VISITAS"); cartel.emission.intensity = 0.4
                    let qc = local(3.5, 5.1)
                    let cart = nodo(SCNBox(width: 1.6, height: 0.4, length: 0.05, chamferRadius: 0), cartel, y: 1.5, x: qc.x, z: qc.y); cart.eulerAngles.y = yaw
                    r.addChildNode(cart); r.addChildNode(nodo(SCNCylinder(radius: 0.05, height: 1.3), hierro, y: 0.65, x: qc.x, z: qc.y))
                    nav.rect(c.x, c.y, 3.8, 5.4, yaw)
                    sendero(pl.ang, hasta: hypot(c.x, c.y) - 5.4, ancho: 3, m: asfalto)
                }
            }
        }

        /// Pantalla panorámica de 14 m detrás del palacio: muestra el centro de mando (se actualiza cada 15 s).
        private func montarPantallon() {
            let g = SCNNode(); g.position = SCNVector3(0, 0, -9.6)
            let acero = Mat.pbr(NSColor(calibratedWhite: 0.16, alpha: 1), rugosidad: 0.35, metal: 0.8)
            let w: CGFloat = 14, h: CGFloat = 14 * 600 / 1600, y: CGFloat = 8.6 + 14 * 600 / 1600 / 2
            for x: CGFloat in [-6.2, 6.2] {
                g.addChildNode(nodo(SCNBox(width: 0.45, height: y + h / 2, length: 0.45, chamferRadius: 0.05), acero, y: (y + h / 2) / 2, x: x, z: -0.5))   // detrás de la pantalla
                nav.rect(x, -10.1, 0.23, 0.23, 0)
            }
            g.addChildNode(nodo(SCNBox(width: w + 0.4, height: h + 0.4, length: 0.35, chamferRadius: 0.06), acero, y: y, z: -0.1))
            pantallon.lightingModel = .constant
            pantallon.diffuse.contents = NSColor(calibratedRed: 0.05, green: 0.08, blue: 0.14, alpha: 1)
            g.addChildNode(nodo(SCNPlane(width: w, height: h), pantallon, y: y, z: 0.09))
            g.enumerateHierarchy { n, _ in n.castsShadow = false }
            g.name = "elem:pantallon"
            escena.rootNode.addChildNode(g)
        }

        private func actualizarPantallon() {
            let r = ImageRenderer(content: CentroMando(pantalla: true, defensa: defensaTexto).environmentObject(almacen))
            r.scale = 1
            if let img = r.nsImage { pantallon.diffuse.contents = img; pantallon.emission.contents = img; pantallon.emission.intensity = 0.5 }
        }

        /// Autos estacionados en el estacionamiento de visitas (fuera del bloque fijo: el auto ya viene fusionado).
        private func montarEstacionados() {
            guard let pl = Coordinador.plazas.first(where: { $0.tipo == "estacionamiento" }) else { return }
            let yaw = pl.ang, c = pl.c
            let faro = Mat.pbr(NSColor(calibratedWhite: 0.9, alpha: 1), rugosidad: 0.2), freno = Mat.pbr(NSColor(calibratedRed: 0.6, green: 0.05, blue: 0.05, alpha: 1))
            for (lz, col) in [(CGFloat(-1.45), NSColor(calibratedWhite: 0.85, alpha: 1)), (3.5, NSColor(Color(hex: "#7a2f2f")))] {
                let lx: CGFloat = -1.1
                let a = auto(col, suv: lz < 0, faro: faro, freno: freno)
                a.scale = SCNVector3(1, 1, 1)
                a.position = SCNVector3(c.x + lx * cos(yaw) + lz * sin(yaw), 0.08, c.y - lx * sin(yaw) + lz * cos(yaw))
                a.eulerAngles.y = yaw + .pi / 2
                escena.rootNode.addChildNode(a)
            }
        }

        private func montarAmbulancia(_ r: SCNNode) {
            // Dos calces a los costados del hospital, fuera del ala de oficinas (atrás quedaban encerradas); si hay un agente
            // en atención, avanzan derecho a la entrada de Urgencias.
            let c = Coordinador.posiciones["urg"]!, hy = atan2(-c.x, -c.y)
            let lote = SCNNode(); lote.position = SCNVector3(c.x, 0, c.y); lote.eulerAngles.y = hy
            for lado: CGFloat in [-1, 1] {
                lote.addChildNode(nodo(SCNBox(width: 3.4, height: 0.05, length: 7.6, chamferRadius: 0), Mat.pbr(NSColor(calibratedWhite: 0.2, alpha: 1), rugosidad: 0.85), y: 0.15, x: lado * 7.6, z: -0.5))
                for dx: CGFloat in [-1.5, 1.5] {
                    lote.addChildNode(nodo(SCNBox(width: 0.08, height: 0.06, length: 5.6, chamferRadius: 0), Mat.pbr(.white), y: 0.16, x: lado * 7.6 + dx, z: -1.2))
                }
            }
            let cartel = SCNMaterial(); cartel.diffuse.contents = Pizarra.letrero("AMBULANCIAS"); cartel.emission.contents = Pizarra.letrero("AMBULANCIAS"); cartel.emission.intensity = 0.4
            // Letrero pintado en el suelo delante de cada calce: legible de frente y sin estorbar la salida
            for lado: CGFloat in [-1, 1] {
                let pintura = nodo(SCNPlane(width: 3.0, height: 0.62), cartel, y: 0.18, x: lado * 7.6, z: 2.6); pintura.eulerAngles.x = -.pi / 2
                lote.addChildNode(pintura)
            }
            Coordinador.hornear(lote)
            escena.rootNode.addChildNode(lote.flattenedClone())
            for o: CGFloat in [-7.6, 7.6] {
                // Física: una por cada costado (antes iban paralelas a 1,2 m y se superponían) y se detienen junto al ala
                // de Urgencias, fuera de los pilares de la marquesina (antes los cruzaban en diagonal).
                let lado: CGFloat = o < 0 ? -1 : 1
                let ruta = [CGPoint(x: o, y: -1.2), CGPoint(x: o, y: 1.8), CGPoint(x: lado * 5.0, y: 4.4)]   // de frente en su calce lateral: avanzan y entran a la marquesina
                let amb = ambulancia(); amb.name = "elem:ambulancia"; amb.scale = SCNVector3(1, 1, 1)
                escena.rootNode.addChildNode(amb)
                ambHosp.append((amb, ruta))
            }
            moverAmbulancias(0)
        }

        /// Ubica las ambulancias del hospital según `salidaAmb` (0 = estacionadas atrás, 1 = en la entrada de Urgencias).
        private func moverAmbulancias(_ dt: CGFloat) {
            let meta: CGFloat = almacen.conProblemas.isEmpty ? 0 : 1
            if salidaAmb == meta && dt > 0 { return }
            salidaAmb += max(-dt * 0.07, min(dt * 0.07, meta - salidaAmb))
            let c = Coordinador.posiciones["urg"]!, hy = atan2(-c.x, -c.y)
            for (n, ruta) in ambHosp {
                var largos: [CGFloat] = []
                for i in 0..<(ruta.count - 1) { largos.append(hypot(ruta[i + 1].x - ruta[i].x, ruta[i + 1].y - ruta[i].y)) }
                var s = salidaAmb * largos.reduce(0, +), i = 0
                while i < largos.count - 1 && s > largos[i] { s -= largos[i]; i += 1 }
                let p = ruta[i], q = ruta[i + 1], t = min(1, s / largos[i])
                let lx = p.x + (q.x - p.x) * t, lz = p.y + (q.y - p.y) * t
                // Estacionadas en batería, perpendiculares al hospital; en la entrada, mirando hacia afuera, listas para partir.
                let rumbo = salidaAmb >= 0.999 ? 0 : salidaAmb <= 0.001 ? 0 : atan2(q.x - p.x, q.y - p.y)
                let y: CGFloat = salidaAmb <= 0.001 ? 0.175 : 0.12        // sobre el estacionamiento o sobre el piso del barrio
                n.position = SCNVector3(c.x + lx * cos(hy) + lz * sin(hy), y, c.y - lx * sin(hy) + lz * cos(hy))
                n.eulerAngles.y = hy + rumbo
            }
        }

        // MARK: Cuerpo de bomberos (seguridad pública)

        private func polar(_ r: CGFloat, _ a: CGFloat) -> CGPoint { CGPoint(x: sin(a) * r, y: cos(a) * r) }

        /// Cuartel con dos portones, torre de mangueras, letrero y carros; calle de servicio hasta el palacio y
        /// circunvalación interior (r 21) que une el cuartel con todos los barrios.
        private func montarBomberos(_ r: SCNNode) {
            let a0 = Coordinador.cuartelAng, yaw = a0 + .pi
            let asfalto = Mat.pbr(NSColor(calibratedWhite: 0.19, alpha: 1), rugosidad: 0.85), linea = Mat.pbr(NSColor(calibratedWhite: 0.92, alpha: 1))
            // Circunvalación en tramos: se corta a ambos lados de la escalera de La nube (antes la atravesaba).
            let aNube = Coordinador.posiciones["nube"].map { atan2($0.x, $0.y) } ?? 0, nSeg = 150
            for k in 0..<nSeg {
                let a = CGFloat(k) / CGFloat(nSeg) * 2 * .pi
                var d = a - aNube; while d > .pi { d -= 2 * .pi }; while d < -.pi { d += 2 * .pi }
                if abs(d) < Coordinador.corteNube { continue }
                let p = polar(21, a), largo = 22.4 * 2 * .pi / CGFloat(nSeg) + 0.04
                let seg = nodo(SCNBox(width: 2.8, height: 0.06, length: largo, chamferRadius: 0), asfalto, y: 0.035, x: p.x, z: p.y); seg.eulerAngles.y = a + .pi / 2
                r.addChildNode(seg)
                if k % 2 == 0 {
                    let l = nodo(SCNBox(width: 0.12, height: 0.065, length: largo * 0.8, chamferRadius: 0), linea, y: 0.037, x: p.x, z: p.y); l.eulerAngles.y = a + .pi / 2
                    r.addChildNode(l)
                }
            }
            let m = polar(23, a0)
            let calle = nodo(SCNBox(width: 3.6, height: 0.06, length: 18, chamferRadius: 0), asfalto, y: 0.036, x: m.x, z: m.y); calle.eulerAngles.y = a0
            r.addChildNode(calle)

            // Edificio (frente +z hacia el palacio); el portón izquierdo (x -2.6) queda sobre el eje de la calle.
            let lat = CGPoint(x: cos(yaw), y: -sin(yaw)), c0 = polar(36, a0)
            let c = CGPoint(x: c0.x + 2.6 * lat.x, y: c0.y + 2.6 * lat.y)
            centroCuartel = c
            let g = SCNNode(); g.position = SCNVector3(c.x, 0, c.y); g.eulerAngles.y = yaw
            let rojo = Mat.textura(.estuco, repetir: 2, tinte: "#b3342b"), blanco = Mat.pbr(NSColor(calibratedWhite: 0.94, alpha: 1), rugosidad: 0.5)
            let gris = Mat.pbr(NSColor(calibratedWhite: 0.55, alpha: 1), rugosidad: 0.6), piso = Mat.pbr(NSColor(calibratedWhite: 0.32, alpha: 1), rugosidad: 0.8)
            let W: CGFloat = 10.6, D: CGFloat = 10, H: CGFloat = 4.4, t: CGFloat = 0.25   // fondo para carros de 7,8 m
            g.addChildNode(nodo(SCNBox(width: W + 0.4, height: 0.1, length: D + 3.4, chamferRadius: 0), piso, y: 0.05, z: 1.5))          // losa y antejardín
            g.addChildNode(nodo(SCNBox(width: W, height: H, length: t, chamferRadius: 0), rojo, y: H / 2, z: -D / 2))                     // muro trasero
            for sx: CGFloat in [-1, 1] { g.addChildNode(nodo(SCNBox(width: t, height: H, length: D, chamferRadius: 0), rojo, y: H / 2, x: sx * W / 2)) }
            for x: CGFloat in [-W / 2 + 0.45, 0, W / 2 - 0.45] {                                                                         // pilares del frente
                g.addChildNode(nodo(SCNBox(width: x == 0 ? 1.4 : 0.9, height: H, length: t, chamferRadius: 0), rojo, y: H / 2, x: x, z: D / 2))
            }
            g.addChildNode(nodo(SCNBox(width: W, height: H - 3.4, length: t, chamferRadius: 0), rojo, y: (H + 3.4) / 2, z: D / 2))           // dintel
            g.addChildNode(nodo(SCNBox(width: W + 0.5, height: 0.3, length: D + 0.5, chamferRadius: 0.04), blanco, y: H + 0.15))           // techo
            for x: CGFloat in [-2.6, 2.6] {                                                                                              // portones enrollados arriba
                g.addChildNode(nodo(SCNBox(width: 3.6, height: 0.5, length: 0.3, chamferRadius: 0.1), blanco, y: 3.2, x: x, z: D / 2 - 0.25))
                for y: CGFloat in [0.05] { g.addChildNode(nodo(SCNBox(width: 3.6, height: 0.04, length: 0.3, chamferRadius: 0), Mat.pbr(.systemYellow), y: y + 0.08, x: x, z: D / 2 + 0.3)) }
            }
            g.addChildNode(nodo(SCNBox(width: W - 0.2, height: 0.12, length: D - 0.2, chamferRadius: 0), piso, y: H - 0.06))              // cielo interior
            // Torre de mangueras y sirena
            g.addChildNode(nodo(SCNBox(width: 2.4, height: 9, length: 2.4, chamferRadius: 0.03), rojo, y: 4.5, x: W / 2 - 1.3, z: -D / 2 - 1.2))
            g.addChildNode(nodo(SCNBox(width: 2.8, height: 0.3, length: 2.8, chamferRadius: 0.03), blanco, y: 9.15, x: W / 2 - 1.3, z: -D / 2 - 1.2))
            for yy: CGFloat in [3.5, 6] { g.addChildNode(nodo(SCNBox(width: 0.8, height: 1.1, length: 0.06, chamferRadius: 0), ventana(), y: yy, x: W / 2 - 1.3, z: -D / 2 - 1.2 + 1.23)) }
            g.addChildNode(nodo(SCNCylinder(radius: 0.35, height: 0.5), gris, y: 9.55, x: W / 2 - 1.3, z: -D / 2 - 1.2))
            // Letrero, ventanas laterales y mástil
            let cartel = SCNMaterial(); cartel.diffuse.contents = Pizarra.letrero("BOMBEROS"); cartel.emission.contents = Pizarra.letrero("BOMBEROS"); cartel.emission.intensity = 0.5
            g.addChildNode(nodo(SCNBox(width: 4.2, height: 0.62, length: 0.06, chamferRadius: 0), cartel, y: 3.9, z: D / 2 + 0.16))
            for sx: CGFloat in [-1, 1] { for z: CGFloat in [-2, 1] {
                g.addChildNode(nodo(SCNBox(width: 0.06, height: 1.1, length: 1.4, chamferRadius: 0), ventana(), y: 2.4, x: sx * (W / 2 + 0.13), z: z))
            } }
            g.addChildNode(nodo(SCNCylinder(radius: 0.05, height: 7), gris, y: 3.5, x: -W / 2 - 1, z: D / 2 + 1.5))
            g.addChildNode(nodo(SCNBox(width: 1.1, height: 0.7, length: 0.02, chamferRadius: 0), Mat.pbr(NSColor(Color(hex: "#d52b1e"))), y: 6.5, x: -W / 2 - 0.45, z: D / 2 + 1.5))
            let cuartel = g.flattenedClone(); cuartel.name = "elem:bomberos"
            escena.rootNode.addChildNode(cuartel)
            func mundoC(_ x: CGFloat, _ z: CGFloat) -> CGPoint { CGPoint(x: c.x + x * cos(yaw) + z * sin(yaw), y: c.y - x * sin(yaw) + z * cos(yaw)) }
            nav.rect(c.x, c.y, W / 2, D / 2, yaw)
            for bx: CGFloat in [-2.55, 2.55] { let b = mundoC(bx, 0.45); nav.rect(b.x, b.y, 1.8, D / 2 + 0.05, yaw, valor: false, margen: 0) }   // portones abiertos
            let tc = mundoC(W / 2 - 1.3, -D / 2 - 1.2); nav.rect(tc.x, tc.y, 1.2, 1.2, yaw)

            // Carro de rescate fijo en el portón derecho y carro bomba (sale a los incidentes) en el izquierdo
            let rescate = carroBomba(rescate: true); rescate.name = "elem:bomberos"; rescate.scale = SCNVector3(1, 1, 1)
            let pr = mundoC(2.6, 0.8); rescate.position = SCNVector3(pr.x, 0.1, pr.y); rescate.eulerAngles.y = yaw
            nav.rect(pr.x, pr.y, 1.3, 3.9, yaw)
            escena.rootNode.addChildNode(rescate)
            bomba = carroBomba(rescate: false); bomba.name = "elem:bomberos"; bomba.scale = SCNVector3(1, 1, 1)
            balizasBomba = bomba.childNodes.filter { $0.name == "baliza" }
            escena.rootNode.addChildNode(bomba)
            // Dos bomberos de guardia frente al cuartel
            for x: CGFloat in [-4.9, 4.9] {
                let b = Persona.bombero(); b.raiz.name = "elem:bomberos"
                let p = mundoC(x, D / 2 + 1.1); b.raiz.position = SCNVector3(p.x, 0.1, p.y); b.raiz.eulerAngles.y = yaw
                escena.rootNode.addChildNode(b.raiz); nav.circulo(p.x, p.y, 0.3); bomberosCuartel.append(b)
            }
            let e = etiqueta("Bomberos · seguridad pública", y: 6, grande: false, icono: "flame.fill", color: NSColor(Color(hex: "#b3342b")))
            e.position = SCNVector3(c.x, 6.2, c.y); escena.rootNode.addChildNode(e)     // sobre el techo (antes quedaba a ras de suelo, atravesando el pilar)
            rutaBomba = rutaBomberos(nil); sBomba = 0
            ubicarBomba(volviendo: false)
        }

        /// Carro bomba rojo (escala, estanque, cortina) o unidad de rescate; balizas rojas que destellan en emergencia.
        private func carroBomba(rescate: Bool) -> SCNNode {
            if let m = Modelos.nodo("bomba", largo: 7.2) {
                for x: CGFloat in [-0.6, 0.6] {   // balizas que moverBomberos enciende en emergencia
                    let b = nodo(SCNBox(width: 0.5, height: 0.16, length: 0.3, chamferRadius: 0.05), Mat.emisivo(.systemRed, fuerza: 2.2), y: 2.35, x: x, z: 2.3)
                    b.name = "baliza"; b.opacity = 0.25; m.addChildNode(b)
                }
                return m
            }
            let n = SCNNode()
            let rojo = Mat.pbr(NSColor(Color(hex: "#c62a1f")), rugosidad: 0.35, metal: 0.25), blanco = Mat.pbr(.white, rugosidad: 0.4)
            let cromo = Mat.pbr(NSColor(calibratedWhite: 0.75, alpha: 1), rugosidad: 0.2, metal: 0.9), goma = Mat.pbr(NSColor(calibratedWhite: 0.08, alpha: 1), rugosidad: 0.8)
            let vidrio = Mat.pbr(NSColor(calibratedWhite: 0.1, alpha: 1), rugosidad: 0.05, metal: 0.6)
            n.addChildNode(nodo(SCNBox(width: 2.3, height: 1.7, length: 1.9, chamferRadius: 0.15), rojo, y: 1.35, z: 2.1))              // cabina
            n.addChildNode(nodo(SCNBox(width: 2.1, height: 0.7, length: 0.05, chamferRadius: 0.05), vidrio, y: 1.75, z: 3.06))
            n.addChildNode(nodo(SCNBox(width: 2.35, height: 1.9, length: 4.4, chamferRadius: 0.1), rojo, y: 1.45, z: -1.1))              // carrocería
            n.addChildNode(nodo(SCNBox(width: 2.37, height: 0.18, length: 6.2, chamferRadius: 0), blanco, y: 1.05, z: 0))                 // franja
            for sx: CGFloat in [-1, 1] { n.addChildNode(nodo(SCNBox(width: 0.04, height: 1.2, length: 3.6, chamferRadius: 0), cromo, y: 1.6, x: sx * 1.19, z: -1.1)) }   // persianas
            if rescate {
                n.addChildNode(nodo(SCNBox(width: 1.8, height: 0.3, length: 3.6, chamferRadius: 0.05), cromo, y: 2.55, z: -1.1))
            } else {
                for sx: CGFloat in [-0.45, 0.45] { n.addChildNode(nodo(SCNBox(width: 0.1, height: 0.1, length: 5.6, chamferRadius: 0), cromo, y: 2.6, x: sx, z: -0.6)) }   // escala
                for k in 0..<10 { n.addChildNode(nodo(SCNBox(width: 0.9, height: 0.06, length: 0.06, chamferRadius: 0), cromo, y: 2.6, z: -3.2 + CGFloat(k) * 0.56)) }
                let carrete = nodo(SCNCylinder(radius: 0.35, height: 0.5), Mat.pbr(NSColor(Color(hex: "#d9c27a"))), y: 1.2, x: 0, z: -3.35); carrete.eulerAngles.z = .pi / 2
                n.addChildNode(carrete)
            }
            for (x, z) in [(-1.0, 2.0), (1.0, 2.0), (-1.0, -1.6), (1.0, -1.6), (-1.0, -2.6), (1.0, -2.6)] as [(CGFloat, CGFloat)] {
                let rueda = nodo(SCNCylinder(radius: 0.45, height: 0.35), goma, y: 0.45, x: x, z: z); rueda.eulerAngles.z = .pi / 2; n.addChildNode(rueda)
            }
            n.addChildNode(nodo(SCNBox(width: 0.4, height: 0.2, length: 0.05, chamferRadius: 0.03), Mat.emisivo(NSColor(calibratedRed: 1, green: 0.95, blue: 0.8, alpha: 1), fuerza: 1.2), y: 0.85, x: -0.8, z: 3.06))
            n.addChildNode(nodo(SCNBox(width: 0.4, height: 0.2, length: 0.05, chamferRadius: 0.03), Mat.emisivo(NSColor(calibratedRed: 1, green: 0.95, blue: 0.8, alpha: 1), fuerza: 1.2), y: 0.85, x: 0.8, z: 3.06))
            let plano = n.flattenedClone()
            for x: CGFloat in [-0.6, 0.6] {
                let b = nodo(SCNBox(width: 0.55, height: 0.18, length: 0.3, chamferRadius: 0.05), Mat.emisivo(.systemRed, fuerza: 2.2), y: 2.3, x: x, z: 2.6)
                b.name = "baliza"; b.opacity = 0.25
                plano.addChildNode(b)
            }
            return plano
        }

        /// Recorrido del carro bomba: cuartel → circunvalación (r 21) → barrio afectado por su camino, o → plaza del palacio.
        private func rutaBomberos(_ destino: String?) -> [CGPoint] {
            let a0 = Coordinador.cuartelAng
            var pts = [polar(35.2, a0), polar(21, a0)]
            guard let d = destino else { return pts }
            if d == "sede" { pts.append(polar(15.3, a0)); return pts }
            if d == "mall" {        // por la avenida del puerto y el anillo periférico hasta la entrada del mall
                let ap = PuertoYFlota.ang
                for k in 1...4 { pts.append(polar(21, a0 + (ap - a0) * CGFloat(k) / 4)) }
                var r: CGFloat = 25
                while r < 61 { pts.append(polar(r, ap)); r += 6 }
                var t = ap
                while t < Mall.ang { pts.append(polar(60.6, t)); t += 0.06 }
                pts += [polar(61, Mall.ang), polar(62.0, Mall.ang)]
                return pts
            }
            guard let c = Coordinador.posiciones[d], let rad = Coordinador.radios[d] else { return pts }
            let at = atan2(c.x, c.y)
            var delta = at - a0
            while delta > .pi { delta -= 2 * .pi }; while delta < -.pi { delta += 2 * .pi }
            if d == "nube" { delta -= (delta > 0 ? 1 : -1) * (Coordinador.corteNube + 0.14) }   // no sube ni atraviesa la escalera
            let pasos = max(1, Int(abs(delta) / 0.12))
            for k in 1...pasos { pts.append(polar(21, a0 + delta * CGFloat(k) / CGFloat(pasos))) }
            if d != "nube" { pts.append(polar(hypot(c.x, c.y) - rad - 0.9, at)) }   // se detiene antes del barrio: el carro mide 7,2 m
            return pts
        }

        /// Revisa (cada 5 s, solo lectura) lo que el Mac necesita resolver y despacha el carro bomba al lugar.
        private func revisarIncidentes() {
            defer { AlarmaVilla.shared.evaluar(almacen, incidentes: incidentes.map(\.titulo)) }
            var lista: [(String, String)] = []
            if let seg = almacen.resultados["seg"], seg.status == "warn" { lista.append(("Alerta de seguridad: \(seg.resumen ?? "el antivirus")", "sede")) }
            if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
               let libre = v.volumeAvailableCapacityForImportantUsage, let total = v.volumeTotalCapacity, total > 0 {
                let gb = Double(libre) / 1e9, pct = Double(libre) / Double(total) * 100
                if pct < 10 || gb < 15 { lista.append((String(format: "Disco casi lleno: quedan %.0f GB (%.0f %%)", gb, pct), "mac")) }
            }
            switch ProcessInfo.processInfo.thermalState {
            case .serious, .critical: lista.append(("Mac sobrecalentado: temperatura \(ProcessInfo.processInfo.thermalState == .critical ? "crítica" : "alta")", "mac"))
            default: break
            }
            for a in almacen.conProblemas.prefix(3) {
                lista.append(("\(a.nombre) en \(a.estado == "crit" ? "falla" : "atención")", a.zona == "sede" ? "sede" : a.zona))
            }
            incidentes = lista.map { (titulo: $0.0, destino: $0.1) }
        }

        private func moverBomberos(_ dt: CGFloat, ahora: CFTimeInterval) {
            guard bomba != nil else { return }
            if ahora - ultimoChequeo > 5 { ultimoChequeo = ahora; revisarIncidentes() }
            let objetivo = incidentes.first.map { Coordinador.posiciones[$0.destino] != nil || $0.destino == "sede" ? $0.destino : "sede" }
            if objetivo != destinoBomba {
                if sBomba <= 0.001 { destinoBomba = objetivo; rutaBomba = rutaBomberos(objetivo) }   // sale desde el cuartel
            }
            var largo: CGFloat = 0
            for i in 0..<(rutaBomba.count - 1) { largo += hypot(rutaBomba[i + 1].x - rutaBomba[i].x, rutaBomba[i + 1].y - rutaBomba[i].y) }
            let meta: CGFloat = (objetivo != nil && objetivo == destinoBomba) ? largo : 0
            let antes = sBomba
            sBomba += max(-dt * 6, min(dt * 6, meta - sBomba))
            let emergencia = objetivo != nil || sBomba > 0.001
            for b in balizasBomba where b.hasActions != emergencia {
                if emergencia { b.runAction(.repeatForever(.sequence([.fadeOpacity(to: 0.15, duration: 0.25), .fadeOpacity(to: 1, duration: 0.25)]))) }
                else { b.removeAllActions(); b.opacity = 0.25 }
            }
            if sBomba != antes || dt == 0 { ubicarBomba(volviendo: sBomba < antes) }
        }

        private func ubicarBomba(volviendo: Bool) {
            var s = sBomba, i = 0
            while i < rutaBomba.count - 2 && s > hypot(rutaBomba[i + 1].x - rutaBomba[i].x, rutaBomba[i + 1].y - rutaBomba[i].y) {
                s -= hypot(rutaBomba[i + 1].x - rutaBomba[i].x, rutaBomba[i + 1].y - rutaBomba[i].y); i += 1
            }
            let p = rutaBomba[i], q = rutaBomba[i + 1], l = max(0.001, hypot(q.x - p.x, q.y - p.y)), t = min(1, s / l)
            let pos = CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t)
            // De vuelta maneja de frente, salvo el último tramo: entra al cuartel en retroceso y queda mirando a la calle.
            let adelante = atan2(q.x - p.x, q.y - p.y)
            // Física: dentro de la calle de servicio y del cuartel el carro va siempre alineado con el eje (no gira
            // atravesando pilares). Vuelve de frente y queda mirando al fondo; al salir retrocede recto hasta la calle.
            var rumbo = volviendo ? adelante + .pi : adelante
            if i == 0 && !volviendo && bombaDeFrente { rumbo = adelante + .pi }
            if i > 0 && !volviendo { bombaDeFrente = false }
            if volviendo && sBomba <= 0.001 { bombaDeFrente = true }
            let enBarrio = Coordinador.posiciones.contains { $0.key != "nube" && hypot(pos.x - $0.value.x, pos.y - $0.value.y) <= Coordinador.radios[$0.key]! }
            let y: CGFloat = hypot(pos.x, pos.y) <= 14.5 || enBarrio ? 0.12 : hypot(pos.x, pos.y) > 32 ? 0.1 : 0.066
            bomba.position = SCNVector3(pos.x, y, pos.y)
            var d = rumbo - CGFloat(bomba.eulerAngles.y)
            while d > .pi { d -= 2 * .pi }; while d < -.pi { d += 2 * .pi }
            let enCalle = i == 0 && hypot(pos.x - rutaBomba[0].x, pos.y - rutaBomba[0].y) < 11   // calle de servicio y cuartel: sin girar
            bomba.eulerAngles.y = CGFloat(bomba.eulerAngles.y) + d * (sBomba <= 0.001 || enCalle ? 1 : 0.2)
        }

        private func ambulancia() -> SCNNode {
            if let m = Modelos.nodo("ambulancia", largo: 5.2) {
                for (x, col) in [(-0.4, NSColor.systemBlue), (0.4, NSColor.systemRed)] as [(CGFloat, NSColor)] {   // balizas que destellan
                    let b = nodo(SCNBox(width: 0.45, height: 0.14, length: 0.28, chamferRadius: 0.05), Mat.emisivo(col, fuerza: 2), y: 2.66, x: x, z: 0.5)
                    b.runAction(.repeatForever(.sequence([.fadeOpacity(to: 0.15, duration: 0.3), .fadeOpacity(to: 1, duration: 0.3)])))
                    m.addChildNode(b)
                }
                return m
            }
            let amb = SCNNode()
            let blanco = Mat.pbr(.white, rugosidad: 0.3, metal: 0.1)
            amb.addChildNode(nodo(SCNBox(width: 2.0, height: 1.9, length: 3.4, chamferRadius: 0.15), blanco, y: 1.35, z: -0.4))
            amb.addChildNode(nodo(SCNBox(width: 1.95, height: 1.2, length: 1.6, chamferRadius: 0.2), blanco, y: 0.95, z: 1.8))
            amb.addChildNode(nodo(SCNBox(width: 1.8, height: 0.55, length: 0.05, chamferRadius: 0.05), Mat.pbr(NSColor(calibratedWhite: 0.1, alpha: 1), rugosidad: 0.05, metal: 0.6), y: 1.3, z: 2.6))
            amb.addChildNode(nodo(SCNBox(width: 2.02, height: 0.25, length: 5.0, chamferRadius: 0), Mat.pbr(NSColor.systemRed), y: 0.9, z: 0.4))
            let goma = Mat.pbr(NSColor(calibratedWhite: 0.08, alpha: 1), rugosidad: 0.8)
            for (x, z) in [(-0.9, 1.6), (0.9, 1.6), (-0.9, -1.4), (0.9, -1.4)] {
                let rueda = nodo(SCNCylinder(radius: 0.38, height: 0.3), goma, y: 0.38, x: x, z: z)
                rueda.eulerAngles.z = .pi / 2; amb.addChildNode(rueda)
            }
            let plano = amb.flattenedClone()
            for (x, col) in [(-0.4, NSColor.systemBlue), (0.4, NSColor.systemRed)] as [(CGFloat, NSColor)] {   // balizas que destellan
                let b = nodo(SCNBox(width: 0.5, height: 0.16, length: 0.3, chamferRadius: 0.05), Mat.emisivo(col, fuerza: 2), y: 2.39, x: x, z: 0.6)
                b.runAction(.repeatForever(.sequence([.fadeOpacity(to: 0.15, duration: 0.3), .fadeOpacity(to: 1, duration: 0.3)])))
                plano.addChildNode(b)
            }
            return plano
        }

        /// Moto de Carabineros con su motorista (casco blanco, uniforme verde) y baliza azul.
        private func moto(faro: SCNMaterial) -> SCNNode {
            let n = SCNNode()
            let blanco = Mat.pbr(.white, rugosidad: 0.3, metal: 0.4), negro = Mat.pbr(NSColor(calibratedWhite: 0.07, alpha: 1), rugosidad: 0.7)
            let verde = Mat.pbr(NSColor(Color(hex: "#2f5d3a")), rugosidad: 0.7)
            if let m = Modelos.nodo("moto", largo: 2.1, pintura: (.white, ["Blue"])) {   // moto blanca de Carabineros con su motorista
                m.addChildNode(nodo(SCNBox(width: 0.36, height: 0.45, length: 0.3, chamferRadius: 0.05), verde, y: 1.05, z: -0.2))
                m.addChildNode(nodo(SCNCapsule(capRadius: 0.19, height: 0.72), verde, y: 1.45, z: -0.12))
                m.addChildNode(nodo(SCNSphere(radius: 0.16), blanco, y: 1.93, z: -0.06))
                for x: CGFloat in [-0.13, 0.13] { let pierna = nodo(SCNCapsule(capRadius: 0.08, height: 0.6), verde, y: 0.8, x: x, z: 0.05); pierna.eulerAngles.x = -0.9; m.addChildNode(pierna) }
                m.addChildNode(nodo(SCNBox(width: 0.22, height: 0.12, length: 0.05, chamferRadius: 0.03), faro, y: 0.85, z: 1.0))
                let b = nodo(SCNSphere(radius: 0.08), Mat.emisivo(.systemBlue, fuerza: 2.5), y: 1.2, z: -0.85)
                b.runAction(.repeatForever(.sequence([.fadeOpacity(to: 0.1, duration: 0.2), .fadeOpacity(to: 1, duration: 0.2)])))
                m.addChildNode(b)
                return m
            }
            for z: CGFloat in [-0.72, 0.72] { let r = nodo(SCNCylinder(radius: 0.33, height: 0.13), negro, y: 0.33, z: z); r.eulerAngles.z = .pi / 2; n.addChildNode(r) }
            n.addChildNode(nodo(SCNBox(width: 0.34, height: 0.4, length: 1.35, chamferRadius: 0.1), blanco, y: 0.62))
            n.addChildNode(nodo(SCNBox(width: 0.6, height: 0.5, length: 0.3, chamferRadius: 0.08), blanco, y: 0.92, z: 0.62))
            n.addChildNode(nodo(SCNBox(width: 0.24, height: 0.14, length: 0.05, chamferRadius: 0.03), faro, y: 0.95, z: 0.78))
            n.addChildNode(nodo(SCNBox(width: 0.36, height: 0.45, length: 0.3, chamferRadius: 0.05), verde, y: 0.95, z: -0.15))
            n.addChildNode(nodo(SCNCapsule(capRadius: 0.2, height: 0.75), verde, y: 1.38, z: -0.12))
            n.addChildNode(nodo(SCNSphere(radius: 0.17), blanco, y: 1.88, z: -0.08))
            let plano = n.flattenedClone()
            let b = nodo(SCNSphere(radius: 0.09), Mat.emisivo(.systemBlue, fuerza: 2.5), y: 1.15, z: -0.65)
            b.runAction(.repeatForever(.sequence([.fadeOpacity(to: 0.1, duration: 0.2), .fadeOpacity(to: 1, duration: 0.2)])))
            plano.addChildNode(b)
            return plano
        }

        /// Patrulla militar: todoterreno verde oliva con techo de lona y antena.
        private func patrulla(faro: SCNMaterial, freno: SCNMaterial) -> SCNNode {
            if let m = Modelos.nodo("humvee", largo: 4.6) {   // Humvee con antena y baliza ámbar
                m.addChildNode(nodo(SCNCylinder(radius: 0.02, height: 1.6), Mat.pbr(.black), y: 2.7, x: 0.7, z: -1.5))
                let b = nodo(SCNBox(width: 0.45, height: 0.22, length: 0.28, chamferRadius: 0.05), Mat.emisivo(.systemYellow, fuerza: 1.5), y: 2.08, z: 0.3)
                b.runAction(.repeatForever(.sequence([.fadeOpacity(to: 0.2, duration: 0.5), .fadeOpacity(to: 1, duration: 0.5)])))
                m.addChildNode(b)
                return m
            }
            let n = auto(NSColor(Color(hex: "#4b5a33")), suv: true, faro: faro, freno: freno)
            let lona = Mat.pbr(NSColor(Color(hex: "#6b6a4a")), rugosidad: 0.9)
            n.addChildNode(nodo(SCNBox(width: 1.7, height: 0.12, length: 2.6, chamferRadius: 0.05), lona, y: 1.95, z: -0.3))
            n.addChildNode(nodo(SCNCylinder(radius: 0.02, height: 1.6), Mat.pbr(.black), y: 2.7, x: 0.7, z: -1.5))
            n.addChildNode(nodo(SCNBox(width: 0.5, height: 0.25, length: 0.3, chamferRadius: 0.05), Mat.emisivo(.systemYellow, fuerza: 1.5), y: 2.1, z: 0.6))
            n.childNodes.last?.runAction(.repeatForever(.sequence([.fadeOpacity(to: 0.2, duration: 0.5), .fadeOpacity(to: 1, duration: 0.5)])))
            return n
        }

        private func ventana() -> SCNMaterial {
            let m = Mat.pbr(NSColor(Color(hex: "#26394d")), rugosidad: 0.12, metal: 0.55)   // vidrio: refleja de día
            m.emission.contents = NSColor(calibratedRed: 1, green: 0.82, blue: 0.5, alpha: 1)      // luz cálida de noche
            ventanas.append(m); return m
        }

        // MARK: Tránsito, guardias y defensa aérea

        /// Punto a distancia r del centro sobre el eje de la avenida, desplazado `lado` metros hacia un costado.
        private func eje(_ r: CGFloat, _ lado: CGFloat = 0) -> CGPoint {
            let a = Coordinador.acceso
            return CGPoint(x: sin(a) * r + cos(a) * lado, y: cos(a) * r - sin(a) * lado)
        }

        /// Anillo periférico de doble vía, avenida de acceso desde la plaza, puente sobre el mar y garita de control.
        private func montarAccesos(_ r: SCNNode) {
            let asfalto = Mat.pbr(NSColor(calibratedWhite: 0.17, alpha: 1), rugosidad: 0.85)
            let linea = Mat.pbr(NSColor(calibratedWhite: 0.92, alpha: 1), rugosidad: 0.6)
            let hormigon = Mat.textura(.estuco, repetir: 2, tinte: "#b9b4aa")
            let a = Coordinador.acceso
            r.addChildNode(nodo(SCNTube(innerRadius: 57, outerRadius: 63, height: 0.06), asfalto, y: 0.04))
            r.addChildNode(nodo(SCNTube(innerRadius: 59.92, outerRadius: 60.08, height: 0.07), linea, y: 0.045))
            func tramo(_ ini: CGFloat, _ fin: CGFloat, ancho: CGFloat, alto: CGFloat, y: CGFloat, _ m: SCNMaterial, lado: CGFloat = 0) {
                let c = eje((ini + fin) / 2, lado)
                let n = nodo(SCNBox(width: ancho, height: alto, length: fin - ini, chamferRadius: 0), m, y: y, x: c.x, z: c.y)
                n.eulerAngles.y = a; r.addChildNode(n)
            }
            tramo(14, 76, ancho: 7, alto: 0.06, y: 0.05, asfalto)          // de 76 a 84 sigue la rampa del puente
            tramo(14, 76, ancho: 0.15, alto: 0.07, y: 0.055, linea)
            // Rampa de la orilla: una sola pieza continua cuyo piso sube en línea recta de la avenida (0,08 m, r 76) al
            // tablero del puente (0,47 m, r 84). Antes eran cajas inclinadas y se veía un escalón en cada extremo.
            let y0: CGFloat = 0.08, y1: CGFloat = 0.47, r0: CGFloat = 76, r1: CGFloat = 84
            let perfil = NSBezierPath()                  // perfil lateral: x = -(r - centro), y = altura
            let rc = (r0 + r1) / 2
            perfil.move(to: NSPoint(x: -(r0 - rc), y: y0)); perfil.line(to: NSPoint(x: -(r1 - rc), y: y1))
            perfil.line(to: NSPoint(x: -(r1 - rc), y: -0.3)); perfil.line(to: NSPoint(x: -(r0 - rc), y: -0.3)); perfil.close()
            let forma = SCNShape(path: perfil, extrusionDepth: 7)
            forma.materials = [hormigon, hormigon, asfalto]          // caras laterales de hormigón; piso de asfalto
            let rampa = SCNNode(); let pr = eje(rc); rampa.position = SCNVector3(pr.x, 0, pr.y); rampa.eulerAngles.y = a
            let cuerpo = SCNNode(geometry: forma); cuerpo.eulerAngles.y = .pi / 2; rampa.addChildNode(cuerpo)
            let inclina = atan2(y1 - y0, r1 - r0), largo = hypot(r1 - r0, y1 - y0), medio = (y0 + y1) / 2
            let eje1 = nodo(SCNBox(width: 0.15, height: 0.012, length: largo, chamferRadius: 0), linea, y: medio + 0.004)
            eje1.eulerAngles.x = -inclina; rampa.addChildNode(eje1)
            for lado: CGFloat in [-3.6, 3.6] {
                let b = nodo(SCNBox(width: 0.18, height: 0.9, length: largo, chamferRadius: 0), hormigon, y: medio + 0.45, x: lado)
                b.eulerAngles.x = -inclina; rampa.addChildNode(b)
            }
            r.addChildNode(rampa)
            // Puente: tablero, barandas y pilares en el mar
            tramo(84, 200, ancho: 7.4, alto: 0.4, y: 0.25, hormigon)
            tramo(84, 200, ancho: 7, alto: 0.42, y: 0.26, asfalto)
            tramo(84, 200, ancho: 0.15, alto: 0.43, y: 0.265, linea)
            for lado: CGFloat in [-3.6, 3.6] { tramo(84, 200, ancho: 0.18, alto: 0.9, y: 0.9, hormigon, lado: lado) }
            var t: CGFloat = 90
            while t < 200 {
                for lado: CGFloat in [-2.6, 2.6] { let c = eje(t, lado); r.addChildNode(nodo(SCNCylinder(radius: 0.45, height: 1.2), hormigon, y: -0.5, x: c.x, z: c.y)) }
                t += 10
            }
            // Tierra firme al otro lado del puente (antes el puente terminaba en medio del mar): costa curva con playa,
            // estribo donde apoya el puente, camino hasta un túnel en el cerro (de ahí salen los visitantes) y árboles.
            let costa = eje(606)
            let playa = SCNCylinder(radius: 408, height: 1); playa.radialSegmentCount = 180
            r.addChildNode(nodo(playa, Mat.textura(.arena, repetir: 200), y: -0.3, x: costa.x, z: costa.y))           // arena: 0,2 m
            let campo = SCNCylinder(radius: 402, height: 1); campo.radialSegmentCount = 180
            r.addChildNode(nodo(campo, Mat.textura(.pasto, repetir: 200), y: -0.06, x: costa.x, z: costa.y))         // pasto: 0,44 m
            tramo(195, 206, ancho: 8.6, alto: 1.0, y: -0.05, hormigon)                                                   // estribo
            tramo(200, 232, ancho: 7, alto: 0.06, y: 0.44, asfalto)                                                      // camino
            tramo(200, 232, ancho: 0.15, alto: 0.07, y: 0.445, linea)
            for lado: CGFloat in [-3.9, 3.9] { tramo(206, 231, ancho: 0.12, alto: 0.5, y: 0.7, Mat.pbr(NSColor(calibratedWhite: 0.75, alpha: 1), rugosidad: 0.3, metal: 0.8), lado: lado) }   // defensas
            let cerro = Mat.textura(.pasto, repetir: 16, tinte: "#8fa67a")
            for (rr, lado, rad, alto) in [(262, 0, 30, 18), (252, -40, 26, 12), (270, 44, 30, 15), (305, 10, 42, 26)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
                let p = eje(rr, lado), s = SCNSphere(radius: rad); s.segmentCount = 48
                let n = nodo(s, cerro, y: -2, x: p.x, z: p.y); n.scale = SCNVector3(1, alto / rad, 1); r.addChildNode(n)
            }
            // Portal del túnel al pie del cerro: muro de hormigón con boca oscura; los autos entran y salen por ella.
            tramo(232, 238, ancho: 12, alto: 7.6, y: 3.8, hormigon)
            tramo(231.7, 232, ancho: 12.6, alto: 0.5, y: 7.4, hormigon)                                                 // cornisa
            tramo(231.85, 232, ancho: 7.4, alto: 5.4, y: 3.15, Mat.pbr(NSColor(calibratedWhite: 0.02, alpha: 1), rugosidad: 1))   // boca
            let luzTunel = Mat.emisivo(NSColor(calibratedRed: 1, green: 0.78, blue: 0.45, alpha: 1), fuerza: 1.1)
            tramo(231.8, 231.85, ancho: 6.8, alto: 0.12, y: 5.6, luzTunel)                                              // luces del túnel
            var azarTF = Azar(semilla: 21)
            let tronco = Mat.textura(.corteza, repetir: 1)
            let copas = ([0.34, 0.39, 0.44] as [CGFloat]).map { Mat.pbr(NSColor(calibratedRed: 0.16, green: $0, blue: 0.2, alpha: 1), rugosidad: 0.9) }
            for k in 0..<60 {
                let rr = 222 + azarTF.real() * 80, lado = (azarTF.real() - 0.5) * 170
                if abs(lado) < 9 { continue }
                let p = eje(rr, lado), h = 3 + azarTF.real() * 3
                r.addChildNode(nodo(SCNCylinder(radius: 0.22, height: h * 0.35), tronco, y: 0.44 + h * 0.17, x: p.x, z: p.y))
                r.addChildNode(nodo(SCNCone(topRadius: 0, bottomRadius: h * 0.32, height: h * 0.8), copas[k % 3], y: 0.44 + h * 0.6, x: p.x, z: p.y))
            }
            // Garita de control de acceso junto a la barrera
            let g = SCNNode(); let pg = eje(68.5, 6.2); g.position = SCNVector3(pg.x, 0, pg.y); g.eulerAngles.y = a
            let blanco = Mat.pbr(NSColor(Color(hex: "#f2efe8")), rugosidad: 0.6)
            g.addChildNode(nodo(SCNBox(width: 2.4, height: 1.1, length: 2.4, chamferRadius: 0.03), blanco, y: 0.6))
            g.addChildNode(nodo(SCNBox(width: 2.3, height: 1.1, length: 2.3, chamferRadius: 0), ventana(), y: 1.7))
            g.addChildNode(nodo(SCNBox(width: 3.0, height: 0.22, length: 3.0, chamferRadius: 0.03), blanco, y: 2.35))
            let texto = Pizarra.letrero("CONTROL DE ACCESO", ancho: 690)
            let cartel = SCNMaterial(); cartel.diffuse.contents = texto; cartel.emission.contents = texto; cartel.emission.intensity = 0.5
            let c = nodo(SCNBox(width: 2.9, height: 0.42, length: 0.06, chamferRadius: 0), cartel, y: 2.7)
            c.eulerAngles.y = -.pi / 2; c.position.x = -1.2; g.addChildNode(c)
            for z: CGFloat in [-1.2, 1.2] { g.addChildNode(nodo(SCNBox(width: 0.05, height: 0.3, length: 0.05, chamferRadius: 0), blanco, y: 2.55, x: -1.2, z: z)) }   // soportes
            let garita = g.flattenedClone(); garita.name = "elem:garita"
            escena.rootNode.addChildNode(garita)
            let poste = eje(66, 3.8)
            r.addChildNode(nodo(SCNBox(width: 0.4, height: 1.1, length: 0.4, chamferRadius: 0.03), Mat.pbr(.systemYellow), y: 0.55, x: poste.x, z: poste.y))
            let ec = etiqueta("Control de acceso", y: 4.2, grande: false, icono: "shield.lefthalf.filled", color: .systemGreen)
            ec.position.x = pg.x; ec.position.z = pg.y
            escena.rootNode.addChildNode(ec)
        }

        /// Guardias: dos en la puerta del palacio, dos en la entrada de la plaza, dos en la garita y uno de ronda.
        private func montarGuardias() {
            let a = Coordinador.acceso
            var puestos: [(CGPoint, CGFloat)] = [(CGPoint(x: -3.7, y: 6.3), 0), (CGPoint(x: 3.7, y: 6.3), 0)]
            for lado: CGFloat in [-4.4, 4.4] { puestos.append((eje(15.5, lado), a)) }
            puestos.append((eje(70.5, 5.0), a - .pi / 2)); puestos.append((eje(64.5, -4.6), a + .pi / 2))
            for (i, (p, rumbo)) in puestos.enumerated() {
                let gu = Persona.guardia()
                gu.raiz.name = ["elem:guardiaPalacio", "elem:guardiaPalacio", "elem:guardiaPlaza", "elem:guardiaPlaza", "elem:guardiaGarita", "elem:guardiaGarita"][i]
                gu.raiz.position = SCNVector3(p.x, alturaPiso(p), p.y); gu.raiz.eulerAngles.y = rumbo
                escena.rootNode.addChildNode(gu.raiz)
                nav.circulo(p.x, p.y, 0.3)
            }
            let ronda = Persona.guardia(); ronda.raiz.name = "elem:guardiaPalacio"
            escena.rootNode.addChildNode(ronda.raiz)
            guardiaRonda = ronda
            // Barrera (se levanta cuando llega un vehículo)
            let pb = eje(66, 3.6)
            barrera.position = SCNVector3(pb.x, 0, pb.y); barrera.eulerAngles.y = a; barrera.name = "elem:garita"
            for k in 0..<7 {
                barrera.addChildNode(nodo(SCNBox(width: 1, height: 0.14, length: 0.1, chamferRadius: 0.02), Mat.pbr(k % 2 == 0 ? .systemRed : .white, rugosidad: 0.4), y: 1.0, x: -0.5 - CGFloat(k)))
            }
            escena.rootNode.addChildNode(barrera)
        }

        private func auto(_ color: NSColor, suv: Bool = false, escolta: Bool = false, faro: SCNMaterial, freno: SCNMaterial) -> SCNNode {
            if let m = Modelos.nodo(suv ? "suv" : "auto2", largo: 4.3, pintura: (color, ["Blue", "White"]), cambios: ["Headlights": faro, "TailLights": freno]) {
                return conBalizas(m, escolta, y: suv ? 1.6 : 1.24)
            }
            let n = SCNNode()
            let pintura = Mat.pbr(color, rugosidad: 0.25, metal: 0.6)
            let vidrio = Mat.pbr(NSColor(calibratedWhite: 0.07, alpha: 1), rugosidad: 0.05, metal: 0.7)
            let goma = Mat.pbr(NSColor(calibratedWhite: 0.06, alpha: 1), rugosidad: 0.85)
            let alto: CGFloat = suv ? 0.85 : 0.6, cab: CGFloat = suv ? 2.9 : 2.1
            n.addChildNode(nodo(SCNBox(width: 1.8, height: alto, length: 4.3, chamferRadius: 0.22), pintura, y: 0.35 + alto / 2))
            n.addChildNode(nodo(SCNBox(width: 1.62, height: 0.55, length: cab, chamferRadius: 0.2), vidrio, y: 0.6 + alto, z: suv ? -0.3 : -0.2))
            n.addChildNode(nodo(SCNBox(width: 1.66, height: 0.06, length: cab - 0.1, chamferRadius: 0.03), pintura, y: 0.88 + alto, z: suv ? -0.3 : -0.2))
            for (x, z) in [(-0.85, 1.35), (0.85, 1.35), (-0.85, -1.35), (0.85, -1.35)] as [(CGFloat, CGFloat)] {
                let rueda = nodo(SCNCylinder(radius: 0.36, height: 0.26), goma, y: 0.36, x: x, z: z)
                rueda.eulerAngles.z = .pi / 2; n.addChildNode(rueda)
            }
            let llanta = Mat.pbr(NSColor(calibratedWhite: 0.75, alpha: 1), rugosidad: 0.25, metal: 0.9), patente = Mat.pbr(NSColor(calibratedWhite: 0.95, alpha: 1), rugosidad: 0.5)
            for (x, z) in [(-0.86, 1.35), (0.86, 1.35), (-0.86, -1.35), (0.86, -1.35)] as [(CGFloat, CGFloat)] {
                let l = nodo(SCNCylinder(radius: 0.2, height: 0.27), llanta, y: 0.36, x: x, z: z); l.eulerAngles.z = .pi / 2; n.addChildNode(l)
            }
            for z: CGFloat in [-2.18, 2.18] {      // parachoques y patente
                n.addChildNode(nodo(SCNBox(width: 1.82, height: 0.18, length: 0.12, chamferRadius: 0.05), goma, y: 0.42, z: z))
                n.addChildNode(nodo(SCNBox(width: 0.5, height: 0.13, length: 0.02, chamferRadius: 0), patente, y: 0.42, z: z + (z > 0 ? 0.07 : -0.07)))
            }
            for x: CGFloat in [-1, 1] {            // espejos laterales
                n.addChildNode(nodo(SCNBox(width: 0.18, height: 0.12, length: 0.08, chamferRadius: 0.03), pintura, y: 0.62 + alto, x: x * 0.95, z: 0.75))
            }
            for x: CGFloat in [-0.6, 0.6] {
                n.addChildNode(nodo(SCNBox(width: 0.38, height: 0.12, length: 0.05, chamferRadius: 0.02), faro, y: 0.35 + alto * 0.65, x: x, z: 2.16))
                n.addChildNode(nodo(SCNBox(width: 0.38, height: 0.12, length: 0.05, chamferRadius: 0.02), freno, y: 0.35 + alto * 0.65, x: x, z: -2.16))
            }
            return conBalizas(n.flattenedClone(), escolta, y: 0.97 + alto)
        }

        private func conBalizas(_ plano: SCNNode, _ escolta: Bool, y: CGFloat) -> SCNNode {
            if escolta {   // balizas azul y roja que destellan
                for (x, col) in [(-0.35, NSColor.systemBlue), (0.35, NSColor.systemRed)] as [(CGFloat, NSColor)] {
                    let b = nodo(SCNBox(width: 0.4, height: 0.12, length: 0.25, chamferRadius: 0.04), Mat.emisivo(col, fuerza: 2), y: y, x: x, z: -0.3)
                    b.runAction(.repeatForever(.sequence([.fadeOpacity(to: 0.15, duration: 0.25), .fadeOpacity(to: 1, duration: 0.25)])))
                    plano.addChildNode(b)
                }
            }
            return plano
        }

        /// Rutas cerradas: anillo (dos sentidos), visitantes que entran por el puente y pasan la garita,
        /// y la caravana de escolta del gobierno que sale de la plaza, da la vuelta a la villa y vuelve.
        private func montarTrafico() {
            let faro = Mat.emisivo(NSColor(calibratedRed: 1, green: 0.97, blue: 0.85, alpha: 1)); focos.append(faro)
            let freno = Mat.emisivo(.systemRed, fuerza: 0.8)
            let a = Coordinador.acceso
            func anillo(_ r: CGFloat, desde: CGFloat, sube: Bool) -> [CGPoint] {
                (0...72).map { k in let t = desde + CGFloat(k) / 72 * 2 * .pi * (sube ? 1 : -1); return CGPoint(x: sin(t) * r, y: cos(t) * r) }
            }
            func recta(_ r0: CGFloat, _ r1: CGFloat, lado: CGFloat) -> [CGPoint] {
                let n = Int(abs(r1 - r0) / 8) + 1
                return (0...n).map { eje(r0 + (r1 - r0) * CGFloat($0) / CGFloat(n), lado) }
            }
            let colores: [NSColor] = [.systemBlue, .white, .systemRed, NSColor(Color(hex: "#9aa3ad")), .systemOrange, NSColor(Color(hex: "#1f3b5c")), .systemGreen, NSColor(Color(hex: "#d8d2c4"))]
            // Anillo: carril interior baja, carril exterior sube
            let interior = anillo(59, desde: 0, sube: false), exterior = anillo(61, desde: 0.3, sube: true)
            for k in 0..<5 {
                vehiculos.append(Vehiculo(auto(colores[k], suv: k == 3, faro: faro, freno: freno), ruta: interior, s: CGFloat(k) * 75, velocidad: 9))
            }
            for k in 0..<3 {
                vehiculos.append(Vehiculo(auto(colores[5 + k], faro: faro, freno: freno), ruta: exterior, s: CGFloat(k) * 125 + 40, velocidad: 8.5))
            }
            // Visitantes: entran por el puente, se detienen en la garita, dan una vuelta y salen
            // Vienen desde tierra firme: salen del túnel del cerro (r 232), cruzan el puente y vuelven a entrar en él.
            let visita = recta(242, 63, lado: 1.7) + anillo(61, desde: a + 0.03, sube: true) + recta(63, 242, lado: -1.7)
            let parada = CGFloat(242 - 69)
            for k in 0..<2 {
                vehiculos.append(Vehiculo(auto(k == 0 ? .systemYellow : NSColor(Color(hex: "#6d2f2f")), suv: k == 1, faro: faro, freno: freno),
                                          ruta: visita, s: CGFloat(k) * 300, velocidad: 9, paradas: [(parada, 3)]))
            }
            // Caravana de escolta: SUV negro con balizas, auto oficial y SUV negro; espera 15 s en la plaza
            let caravana = recta(16.6, 58, lado: -1.7) + anillo(59, desde: a - 0.05, sube: false) + recta(58, 16.6, lado: 1.7)
            let negro = NSColor(calibratedWhite: 0.05, alpha: 1)
            for (k, oficial) in [false, true, false].enumerated() {
                vehiculos.append(Vehiculo(auto(negro, suv: !oficial, escolta: !oficial, faro: faro, freno: freno),
                                          ruta: caravana, s: 30 - CGFloat(k) * 6.5, velocidad: 8, paradas: [(2, 15)]))
            }
            // Ambulancia en servicio y patrullas militares recorriendo el anillo y la avenida
            vehiculos.append(Vehiculo(ambulancia(), ruta: interior, s: 30, velocidad: 10))
            for k in 0..<2 { vehiculos.append(Vehiculo(patrulla(faro: faro, freno: freno), ruta: exterior, s: CGFloat(k) * 190 + 100, velocidad: 7)) }
            vehiculos.append(Vehiculo(patrulla(faro: faro, freno: freno), ruta: visita, s: 150, velocidad: 7))
            // Motoristas de Carabineros patrullando ambos carriles
            vehiculos.append(Vehiculo(moto(faro: faro), ruta: exterior, s: 250, velocidad: 11))
            vehiculos.append(Vehiculo(moto(faro: faro), ruta: interior, s: 200, velocidad: 11))
            for (k, v) in vehiculos.enumerated() {
                v.raiz.name = "elem:" + (k < 8 ? "auto" : k < 10 ? "visita" : k < 13 ? "caravana" : k == 13 ? "ambulancia" : k < 17 ? "patrulla" : "moto")
                v.raiz.scale = SCNVector3(1, 1, 1)       // tamaño real, proporcional a las personas (1,85 m)
                escena.rootNode.addChildNode(v.raiz)
            }
            // Carabinero dirigiendo el tránsito en el cruce de la avenida con el anillo
            let cb = Persona.carabinero(); cb.raiz.name = "elem:carabinero"
            let pc = eje(55.6, 4.4), cruce = eje(60, 0)
            cb.raiz.position = SCNVector3(pc.x, 0.02, pc.y); cb.raiz.eulerAngles.y = atan2(cruce.x - pc.x, cruce.y - pc.y)
            escena.rootNode.addChildNode(cb.raiz)
            carabinero = cb
        }

        private func moverTrafico(_ dt: CGFloat, ahora: CFTimeInterval) {
            // Horas punta (7–9, 13, 18–19 h) con todo el tránsito; de noche casi nadie; el resto, tránsito medio.
            if ahora - horaLeida > 20 { horaLeida = ahora; horaActual = Calendar.current.component(.hour, from: Date()) }
            let h = horaActual
            let punta = [7, 8, 13, 18, 19].contains(h), noche = h >= 23 || h < 6
            estadoTransito = punta ? "hora punta" : noche ? "muy tranquilo (noche)" : "normal"
            let cupo = punta ? 10 : noche ? 2 : 5
            for (k, v) in vehiculos.prefix(10).enumerated() { v.raiz.isHidden = k < 8 ? k >= min(cupo, 8) : cupo < 10 && (k == 9 || noche) }
            carabinero?.raiz.isHidden = noche
            carabinero?.dirigir(ahora)
            moverAmbulancias(dt)
            moverBomberos(dt, ahora: CACurrentMediaTime())
            // Nadie se atraviesa: frena si tiene un vehículo delante en su trayectoria. En un cruce, si ambos se tienen
            // delante, pasa primero el de mayor prioridad (escolta, ambulancia, patrullas) y el otro cede el paso.
            func estorba(_ v: Vehiculo, _ o: Vehiculo) -> Bool {
                // Según el largo y ancho de ambos y hacia donde avanza (en retroceso, hacia atrás)
                let dx = o.pos.x - v.pos.x, dz = o.pos.y - v.pos.y, fx = sin(v.avance), fz = cos(v.avance)
                let adelante = dx * fx + dz * fz
                return adelante > 0 && adelante < (v.largo + o.largo) / 2 + 1.7 && abs(dx * fz - dz * fx) < max(1.5, (v.ancho + o.ancho) / 2 + 0.1)
            }
            let visibles = vehiculos.enumerated().filter { !$0.element.raiz.isHidden }
            for (i, v) in visibles {
                var porPaciente = false                     // un camión no se atraviesa: nadie se «libera» pasando por él
                let bloqueado = visibles.contains { (j, o) in
                    guard o !== v, estorba(v, o) else { return false }
                    if o.paciente || v.paciente { porPaciente = true }
                    return !(estorba(o, v) && i > j)        // bloqueo mutuo: el de índice mayor (más prioridad) sigue
                }
                // Anti-atasco: si lleva 3 s detenido (cadena de esperas en el cruce o la garita), avanza 2 s
                // sin esperar; el que más prioridad tiene se libera antes (umbral algo menor).
                if v.liberado > 0 { v.liberado -= dt; v.detenido = false }
                else if bloqueado {
                    v.esperando += dt; v.detenido = true
                    if !porPaciente && v.esperando > 3.0 - CGFloat(i) * 0.08 { v.liberado = 2; v.esperando = 0 }
                } else { v.esperando = 0; v.detenido = false }
            }
            for (_, v) in visibles { v.paso(dt) }
            let pb = eje(66, 0)
            let cerca = vehiculos.contains { !$0.raiz.isHidden && hypot($0.pos.x - pb.x, $0.pos.y - pb.y) < 9 }
            aberturaBarrera += ((cerca ? 1 : 0) - aberturaBarrera) * min(1, dt * 4)
            barrera.eulerAngles.z = -1.4 * aberturaBarrera
            if let g = guardiaRonda {   // ronda frente al palacio, ida y vuelta
                let u = CGFloat(ahora.truncatingRemainder(dividingBy: 24)) / 24
                let x = u < 0.5 ? -6 + u * 24 : 6 - (u - 0.5) * 24
                g.raiz.position = SCNVector3(x, 0.12, 12.6); g.raiz.eulerAngles.y = u < 0.5 ? .pi / 2 : -.pi / 2
                g.marchar(dt: dt)
            }
        }

        private func montarDefensa() {
            // Helicóptero de vigilancia
            let verde = Mat.pbr(NSColor(Color(hex: "#3b4a2f")), rugosidad: 0.45, metal: 0.4)
            let negro = Mat.pbr(NSColor(calibratedWhite: 0.08, alpha: 1), rugosidad: 0.4, metal: 0.5)
            let vidrio = Mat.pbr(NSColor(calibratedWhite: 0.1, alpha: 1), rugosidad: 0.05, metal: 0.8)
            let h = SCNNode()
            let casco = nodo(SCNCapsule(capRadius: 0.9, height: 4.2), verde); casco.eulerAngles.x = .pi / 2; h.addChildNode(casco)
            h.addChildNode(nodo(SCNSphere(radius: 0.72), vidrio, y: 0.2, z: 1.5))
            let cola = nodo(SCNCylinder(radius: 0.18, height: 4.4), verde, y: 0.3, z: -3.8); cola.eulerAngles.x = .pi / 2; h.addChildNode(cola)
            h.addChildNode(nodo(SCNBox(width: 0.1, height: 1.2, length: 0.8, chamferRadius: 0.05), verde, y: 0.75, z: -5.9))
            for x: CGFloat in [-0.8, 0.8] {
                h.addChildNode(nodo(SCNBox(width: 0.1, height: 0.08, length: 3.6, chamferRadius: 0.03), negro, y: -1.2, x: x))
                for z: CGFloat in [-0.9, 0.9] { h.addChildNode(nodo(SCNBox(width: 0.06, height: 0.5, length: 0.06, chamferRadius: 0), negro, y: -0.95, x: x * 0.85, z: z)) }
            }
            h.addChildNode(nodo(SCNCylinder(radius: 0.1, height: 0.5), negro, y: 1.05))
            // Modelo descargado (sin su rotor fijo) con los patines a la altura de los del dibujado a mano
            let modelo = Modelos.nodo("heli", largo: 9)
            modelo?.childNodes[0].position.y = -1.2
            let cuerpo = modelo ?? h.flattenedClone()
            let rotor = SCNNode(); rotor.position = SCNVector3(0, modelo == nil ? 1.3 : 1.5, 0)
            for g: CGFloat in [0, .pi / 2] { let p = nodo(SCNBox(width: 11, height: 0.05, length: 0.35, chamferRadius: 0), negro); p.eulerAngles.y = g; rotor.addChildNode(p) }
            rotor.runAction(.repeatForever(.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: 0.22)))
            let rotorCola = SCNNode(); rotorCola.position = modelo == nil ? SCNVector3(0.2, 0.8, -5.9) : SCNVector3(0.25, 0.75, -4.3)
            rotorCola.addChildNode(nodo(SCNBox(width: 0.05, height: 1.6, length: 0.18, chamferRadius: 0), negro))
            rotorCola.runAction(.repeatForever(.rotateBy(x: 2 * .pi, y: 0, z: 0, duration: 0.15)))
            let baliza = nodo(SCNSphere(radius: 0.16), Mat.emisivo(.systemRed, fuerza: 2), y: -0.95, z: -0.5)
            baliza.runAction(.repeatForever(.sequence([.fadeOpacity(to: 0.1, duration: 0.5), .fadeOpacity(to: 1, duration: 0.1)])))
            cuerpo.addChildNode(rotor); cuerpo.addChildNode(rotorCola); cuerpo.addChildNode(baliza)
            cuerpo.addChildNode(etiqueta("Defensa aérea", y: 2.4, grande: false, icono: "shield.lefthalf.filled", color: NSColor(Color(hex: "#3b4a2f"))))
            helicoptero = cuerpo; helicoptero.name = "elem:helicoptero"
            escena.rootNode.addChildNode(helicoptero)
            // Dos cazas en formación
            for _ in 0..<2 {
                let plano = caza(NSColor(Color(hex: "#7d8791")), tren: false)
                plano.name = "elem:cazas"; plano.scale = SCNVector3(0.95, 0.95, 0.95)
                aviones.append(plano); escena.rootNode.addChildNode(plano)
            }
            // Intruso (solo con amenaza activa según el antivirus): dron rojo que destella
            let rojo = Mat.emisivo(.systemRed, fuerza: 2)
            intruso.addChildNode(nodo(SCNSphere(radius: 0.8), negro))
            for g: CGFloat in [0, .pi / 2] {
                let brazo = nodo(SCNBox(width: 3.4, height: 0.12, length: 0.2, chamferRadius: 0), negro); brazo.eulerAngles.y = g + .pi / 4; intruso.addChildNode(brazo)
            }
            let ojo = nodo(SCNSphere(radius: 0.45), rojo, y: -0.3)
            ojo.runAction(.repeatForever(.sequence([.scale(to: 1.6, duration: 0.3), .scale(to: 0.8, duration: 0.3)])))
            intruso.addChildNode(ojo)
            intruso.addChildNode(etiqueta("Amenaza detectada", y: 3, grande: false, icono: "exclamationmark.shield.fill", color: .systemRed))
            intruso.isHidden = true; intruso.name = "elem:intruso"
            escena.rootNode.addChildNode(intruso)
            // Refuerzos (solo en alerta): dos cazas más y dos helicópteros de combate que despegan de la base aérea
            for _ in 0..<2 {
                let c = caza(NSColor(Color(hex: "#5f6a73")), tren: false); c.name = "elem:cazas"; c.scale = SCNVector3(0.95, 0.95, 0.95)
                c.isHidden = true; refuerzos.append(c); escena.rootNode.addChildNode(c)
            }
            for _ in 0..<2 {
                let hc = Modelos.nodo("heli", largo: 8, pintura: (NSColor(Color(hex: "#3b4a2f")), ["Body", "body", "Material", "Main"])) ?? h.flattenedClone()
                hc.childNodes.first?.position.y = -1.1
                let r = SCNNode(); r.position = SCNVector3(0, 1.4, 0)
                for g: CGFloat in [0, .pi / 2] { let p = nodo(SCNBox(width: 10, height: 0.05, length: 0.3, chamferRadius: 0), negro); p.eulerAngles.y = g; r.addChildNode(p) }
                r.runAction(.repeatForever(.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: 0.2)))
                hc.addChildNode(r)
                for x: CGFloat in [-1.1, 1.1] { let l = nodo(SCNCylinder(radius: 0.18, height: 1.6), negro, y: -0.6, x: x, z: 0.4); l.eulerAngles.x = .pi / 2; hc.addChildNode(l) }   // lanzacohetes
                hc.addChildNode(etiqueta("Helicóptero de combate", y: 2.4, grande: false, icono: "scope", color: NSColor(Color(hex: "#3b4a2f"))))
                hc.name = "elem:helicoptero"; hc.isHidden = true; refuerzos.append(hc); escena.rootNode.addChildNode(hc)
            }
        }

        /// Ronda del helicóptero y pasadas de los cazas. Si el Vigilante de seguridad está en alerta aparece el intruso:
        /// los cazas no lo rodean, se ponen en posición de combate detrás y a su costado, lo escoltan fuera del espacio
        /// aéreo y piden refuerzos (dos cazas y dos helicópteros de combate de la base aérea).
        private func moverDefensa(_ ahora: CFTimeInterval) {
            let t = CGFloat(ahora)
            let th = t * 2 * .pi / 75
            var meta = SCNVector3(sin(th) * 50, 20 + sin(t * 0.5) * 0.6, cos(th) * 50), rumbo = th + .pi / 2
            if let d = incidentes.first?.destino {         // movilización: órbita cerrada sobre el barrio o la sede afectada
                let c = Coordinador.posiciones[d] ?? .zero, tc = t * 2 * .pi / 24
                meta = SCNVector3(c.x + sin(tc) * 13, 17 + sin(t * 0.5) * 0.4, c.y + cos(tc) * 13); rumbo = tc + .pi / 2
            }
            let p0 = helicoptero.position, k: CGFloat = 0.035   // vuela hacia allá, no aparece de golpe
            helicoptero.position = SCNVector3(p0.x + (meta.x - p0.x) * k, p0.y + (meta.y - p0.y) * k, p0.z + (meta.z - p0.z) * k)
            helicoptero.eulerAngles = SCNVector3(0.08, rumbo, -0.12)
            let alerta = almacen.resultados["seg"]?.status == "warn"
            intruso.isHidden = !alerta
            if alerta {
                // Interceptación real: el intruso entra hacia la villa; el líder se pone en posición de combate detrás
                // de él y el numeral lo acompaña a su costado; lo desvían y lo escoltan fuera del espacio aéreo.
                // A los pocos segundos llegan los refuerzos de la base aérea: dos cazas más y dos helicópteros de combate.
                let s0 = alertaDesde ?? t; if alertaDesde == nil { alertaDesde = t; for r in refuerzos { let b = Islas.fa(4, -4); r.position = SCNVector3(b.x, 0.5, b.y) } }
                let s = t - s0, ciclo: CGFloat = 70, n = floor(s / ciclo), u = s.truncatingRemainder(dividingBy: ciclo)
                let a = n * 2.4 + 0.7
                let E = CGPoint(x: sin(a) * 240, y: cos(a) * 240), I = CGPoint(x: sin(a) * 75, y: cos(a) * 75)
                let X = CGPoint(x: sin(a + 0.9) * 330, y: cos(a + 0.9) * 330)
                let (o, d, f) = u < 20 ? (E, I, u / 20) : (I, X, (u - 20) / 50)
                let p = CGPoint(x: o.x + (d.x - o.x) * f, y: o.y + (d.y - o.y) * f)
                let L = max(1, hypot(d.x - o.x, d.y - o.y)), fx = (d.x - o.x) / L, fz = (d.y - o.y) / L
                let pi = SCNVector3(p.x, 28, p.y)
                intruso.position = pi; intruso.eulerAngles.y = atan2(fx, fz)
                // Posición relativa al intruso: atrás (+) / adelante (−) y a la derecha / izquierda
                func tras(_ atras: CGFloat, _ lado: CGFloat, _ y: CGFloat) -> SCNVector3 {
                    SCNVector3(pi.x - fx * atras + fz * lado, y, pi.z - fz * atras - fx * lado)
                }
                func seguir(_ n: SCNNode, _ meta: SCNVector3, _ k: CGFloat) {
                    let q = n.position, v = SCNVector3((meta.x - q.x) * k, (meta.y - q.y) * k, (meta.z - q.z) * k)
                    n.position = SCNVector3(q.x + v.x, q.y + v.y, q.z + v.z)
                    let rumbo = hypot(v.x, v.z) > 0.04 ? atan2(v.x, v.z) : atan2(fx, fz)
                    var giro = rumbo - CGFloat(n.eulerAngles.y)
                    while giro > .pi { giro -= 2 * .pi }; while giro < -.pi { giro += 2 * .pi }
                    n.eulerAngles = SCNVector3(0, CGFloat(n.eulerAngles.y) + giro * 0.08, -max(-0.5, min(0.5, giro)))
                }
                let metas = [tras(28, 0, 31), tras(4, 16, 28.5)]                       // líder detrás, numeral al costado
                for (i, av) in aviones.enumerated() { av.isHidden = false; seguir(av, metas[i], 0.05) }
                for (i, r) in refuerzos.enumerated() {
                    guard s > 6 + CGFloat(i) * 2 else { continue }                      // despegan uno tras otro
                    r.isHidden = false
                    let heli = i >= 2, lado: CGFloat = i % 2 == 0 ? -1 : 1
                    seguir(r, heli ? tras(40, lado * 12, 17) : tras(55, lado * 22, 36), heli ? 0.012 : 0.03)
                }
            } else {
                alertaDesde = nil
                for r in refuerzos where !r.isHidden {                                  // vuelven a la base y aterrizan
                    let b = Islas.fa(4, -4), q = r.position
                    r.position = SCNVector3(q.x + (b.x - q.x) * 0.02, q.y + (0.5 - q.y) * 0.02, q.z + (b.y - q.z) * 0.02)
                    r.eulerAngles.y = atan2(b.x - q.x, b.y - q.z)
                    if hypot(b.x - q.x, b.y - q.z) < 4 { r.isHidden = true }
                }
                let ciclo: CGFloat = 28, k = floor(t / ciclo), u = t.truncatingRemainder(dividingBy: ciclo)
                let noche = nocheTranquila      // de noche: un solo caza cada tres ciclos, rumbo al portaaviones
                let dir = noche ? PuertoYFlota.flotaAng : k * 2.17, fx = sin(dir), fz = cos(dir)
                let desvio = noche ? 0 : (k.truncatingRemainder(dividingBy: 3) - 1) * 18
                for (i, av) in aviones.enumerated() {
                    av.isHidden = noche && (i > 0 || Int(k) % 3 != 0)
                    let largo = u * 55 - 330 - CGFloat(i) * 7, lado = desvio + CGFloat(i) * 6
                    av.position = SCNVector3(fx * largo + fz * lado, 42, fz * largo - fx * lado)
                    av.eulerAngles = SCNVector3(0, dir, 0)
                }
            }
        }

        /// Noche tranquila: retira lo que solo ocurre de día; ante una emergencia vuelve todo a moverse.
        private func aplicarNoche() {
            let quieta = nocheTranquila
            if quieta != nocheQuieta {
                nocheQuieta = quieta
                for n in soloDeDia { n.isHidden = quieta }
            }
            for n in soloDeNoche where n.isHidden == esNoche { n.isHidden = !esNoche }   // paseantes nocturnos de una ciudad segura
            if let (c, refugio) = cazaReserva {
                c.isPaused = quieta && hypot(c.position.x - refugio.x, c.position.z - refugio.z) < 0.6
            }
        }

        // MARK: Barrios

        private func montarZonas() {
            guard !zonasHechas, !almacen.zonas.isEmpty else { return }
            zonasHechas = true
            for (zid, z) in almacen.zonas {
                guard let c = Coordinador.posiciones[zid], let r = Coordinador.radios[zid] else { continue }
                let n = SCNNode(); n.position = SCNVector3(c.x, 0, c.y)
                let piso: CGFloat = zid == "nube" ? Nube.alto : 0
                if zid == "nube" {
                    nube = Nube(centro: c, radio: r)
                    nube.montar(n, nav: nav)
                } else {
                    if zid != "mall" && !Islas.sinPlaza.contains(zid) {   // el mall tiene su propio piso de mármol (encimados parpadeaban)
                        n.addChildNode(nodo(SCNCylinder(radius: r, height: 0.22), Mat.textura(.adoquin, repetir: r / 1.5, tinte: z.roof, mezcla: 0.25), y: 0.01))
                    }
                }
                escena.rootNode.addChildNode(n.flattenedClone())
                let em = SCNNode(); em.position = n.position      // aparte: se atenúa para no tapar las oficinas
                montarEmblema(em, zid: zid, z: z, piso: piso)
                Coordinador.hornear(em)          // sin esto el edificio quedaba sin girar y su pizarra y ventanas, dentro de los muros
                let plano = em.flattenedClone()
                escena.rootNode.addChildNode(plano)
                emblemas[zid] = plano
                montarDirectorio(zid: zid, kind: z.kind, centro: c, piso: piso)
                let e = etiqueta(z.name, y: piso + (zid == "nube" ? 8 : Islas.alturaEtiqueta[zid] ?? 10.5), grande: true, icono: iconoBarrio[zid], color: NSColor(Color(hex: z.roof)))
                e.position.x = c.x; e.position.z = c.y
                escena.rootNode.addChildNode(e)
            }
        }

        /// Techo común de vidrio sobre cada oficina del ala (une las oficinas sin tapar la vista del interior) y vereda
        /// de adoquín frente a las puertas.
        private static let vidrioAla: SCNMaterial = {
            let m = Mat.pbr(NSColor(Color(hex: "#bfe3f5")), rugosidad: 0.05, metal: 0.2); m.transparency = 0.18; m.writesToDepthBuffer = false; return m
        }()
        private static let marcoAla = Mat.pbr(NSColor(calibratedWhite: 0.9, alpha: 1), rugosidad: 0.4, metal: 0.5)
        private static let veredaAla = Mat.textura(.adoquin, repetir: 2, tinte: "#d8cfc0", mezcla: 0.4)
        private func alaComun(pos: CGPoint, yaw: CGFloat, piso: CGFloat, radio: CGFloat, paso: CGFloat) -> SCNNode {
            let g = SCNNode(); g.position = SCNVector3(pos.x, piso, pos.y); g.eulerAngles.y = yaw
            let t = tan(paso / 2)
            // Sector de anillo (trapecio en coordenadas de la oficina): de z0 a z1, abierto según el arco.
            func sector(_ z0: CGFloat, _ z1: CGFloat, alto: CGFloat, _ m: SCNMaterial, y: CGFloat) {
                let h0 = (radio + z0) * t, h1 = (radio + z1) * t
                let path = NSBezierPath()
                path.move(to: NSPoint(x: -h0, y: -z0)); path.line(to: NSPoint(x: h0, y: -z0))
                path.line(to: NSPoint(x: h1, y: -z1)); path.line(to: NSPoint(x: -h1, y: -z1)); path.close()
                let n = nodo(SCNShape(path: path, extrusionDepth: alto), m, y: y); n.eulerAngles.x = -.pi / 2
                g.addChildNode(n)
            }
            sector(-1.75, 2.8, alto: 0.04, Coordinador.vidrioAla, y: 2.62)          // techo común con alero sobre la vereda
            sector(1.75, 3.0, alto: 0.05, Coordinador.veredaAla, y: 0.03)           // vereda frente a las puertas
            sector(2.7, 2.8, alto: 0.1, Coordinador.marcoAla, y: 2.62)              // canal del alero
            let hf = (radio + 2.75) * t
            for x in [-hf, hf] {
                g.addChildNode(nodo(SCNCylinder(radius: 0.04, height: 2.6), Coordinador.marcoAla, y: 1.3, x: x, z: 2.75))
                let q = CGPoint(x: pos.x + x * cos(yaw) + 2.75 * sin(yaw), y: pos.y - x * sin(yaw) + 2.75 * cos(yaw)); nav.circulo(q.x, q.y, 0.05)
            }
            let plano = g.flattenedClone(); plano.castsShadow = false
            return plano
        }

        /// flattenedClone() ignora la transformación de los nodos intermedios sin geometría (giro del edificio, marcos de
        /// ventana): se la traspasa a sus hijos antes de aplanar.
        static func hornear(_ n: SCNNode) {
            for h in n.childNodes {
                if h.geometry == nil && !SCNMatrix4IsIdentity(h.transform) {
                    for k in h.childNodes { k.transform = SCNMatrix4Mult(k.transform, h.transform) }
                    h.transform = SCNMatrix4Identity
                }
                hornear(h)
            }
        }

        /// Directorio del edificio: pantalla con los agentes que trabajan en él y su estado (se actualiza sola).
        private func montarDirectorio(zid: String, kind: String, centro c: CGPoint, piso: CGFloat) {
            let yaw = atan2(-c.x, -c.y)                                   // frente hacia el palacio
            func mundo(_ x: CGFloat, _ z: CGFloat) -> CGPoint { CGPoint(x: c.x + x * cos(yaw) + z * sin(yaw), y: c.y - x * sin(yaw) + z * cos(yaw)) }
            let pantalla = SCNMaterial(); pantalla.lightingModel = .constant
            pantalla.diffuse.contents = NSColor(calibratedRed: 0.05, green: 0.08, blue: 0.14, alpha: 1)
            directorios[zid] = pantalla
            let marco = Mat.pbr(NSColor(calibratedWhite: 0.12, alpha: 1), rugosidad: 0.4, metal: 0.6)
            let g = SCNNode(); g.eulerAngles.y = yaw
            let enFachada = kind == "hospital" || kind == "library"
            let (lx, lz, y, w, h): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) =
                kind == "hospital" ? (0, 2.78, 4.45, 2.9, 1.8) :
                kind == "library" ? (0, 2.8, 4.6, 3.0, 1.86) :
                kind == "dome" ? (2.4, 5.6, piso + 1.85, 2.0, 1.24) : kind == "bank" ? (-6.2, 1.0, 1.85, 2.0, 1.24) : (3.1, 4.9, 1.85, 2.0, 1.24)
            let p = mundo(lx, lz); g.position = SCNVector3(p.x, 0, p.y)
            g.addChildNode(nodo(SCNBox(width: w + 0.16, height: h + 0.16, length: 0.1, chamferRadius: 0.03), marco, y: y, z: 0.05))
            g.addChildNode(nodo(SCNPlane(width: w, height: h), pantalla, y: y, z: 0.105))
            if !enFachada {                                               // tótem: dos postes anclados al piso
                let base = kind == "dome" ? piso : 0.12
                for sx: CGFloat in [-1, 1] {
                    g.addChildNode(nodo(SCNCylinder(radius: 0.06, height: y + h / 2 - base), marco, y: base + (y + h / 2 - base) / 2, x: sx * (w / 2 - 0.1)))
                    let q = mundo(lx + sx * (w / 2 - 0.1), lz); nav.circulo(q.x, q.y, 0.12)
                }
            }
            g.name = "dir:\(zid)"
            escena.rootNode.addChildNode(g)
            if kind == "hospital" {                                       // edificio opaco: también en la fachada trasera
                let t = SCNNode(); t.eulerAngles.y = yaw + .pi; t.name = "dir:\(zid)"
                let q = mundo(0, -2.78); t.position = SCNVector3(q.x, 0, q.y)
                t.addChildNode(nodo(SCNBox(width: w + 0.16, height: h + 0.16, length: 0.1, chamferRadius: 0.03), marco, y: y, z: 0.05))
                t.addChildNode(nodo(SCNPlane(width: w, height: h), pantalla, y: y, z: 0.105))
                escena.rootNode.addChildNode(t)
            }
        }

        private func actualizarDirectorios() {
            for (zid, m) in directorios {
                let lista = almacen.agentes.filter { $0.zona == zid }
                let firma = lista.map { $0.nombre + $0.estado }.joined(separator: "|")
                guard firma != firmaDirectorio[zid] else { continue }
                firmaDirectorio[zid] = firma
                let img = Pizarra.directorio(almacen.zonas[zid]?.name ?? zid, lista)
                m.diffuse.contents = img; m.emission.contents = img; m.emission.intensity = 0.35
            }
        }

        private func montarEmblema(_ n: SCNNode, zid: String, z: Zona, piso: CGFloat) {
            let c = Coordinador.posiciones[zid]!
            let muro = Mat.textura(.estuco, repetir: 3, tinte: z.wall)
            switch z.kind {
            case "hospital":
                // Hospital de tres pisos con fajas, ventanas enmarcadas, ala de urgencias con marquesina y helipuerto.
                let yaw = atan2(-c.x, -c.y)                      // frente hacia el palacio
                let h = SCNNode(); h.eulerAngles.y = yaw; n.addChildNode(h)
                func mundo(_ x: CGFloat, _ z: CGFloat) -> CGPoint { CGPoint(x: c.x + x * cos(yaw) + z * sin(yaw), y: c.y - x * sin(yaw) + z * cos(yaw)) }
                let blanco = Mat.pbr(NSColor(Color(hex: "#f4f4f2")), rugosidad: 0.5)
                let gris = Mat.pbr(NSColor(Color(hex: "#9aa3ab")), rugosidad: 0.6)
                let rojo = Mat.emisivo(NSColor.systemRed, fuerza: 0.7)
                let v = ventana()
                h.addChildNode(nodo(SCNBox(width: 7.4, height: 0.4, length: 5.9, chamferRadius: 0), gris, y: 0.2))
                h.addChildNode(nodo(SCNBox(width: 7, height: 9.3, length: 5.5, chamferRadius: 0.05), muro, y: 4.95))   // 3 pisos de 3,1 m
                for y: CGFloat in [3.3, 6.4, 9.65] { h.addChildNode(nodo(SCNBox(width: 7.12, height: 0.22, length: 5.62, chamferRadius: 0), blanco, y: y)) }
                h.addChildNode(nodo(SCNBox(width: 7.2, height: 0.5, length: 5.7, chamferRadius: 0), blanco, y: 9.85))
                func vent(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat, _ g: CGFloat) {
                    let w = SCNNode(); w.position = SCNVector3(x, y, z); w.eulerAngles.y = g
                    w.addChildNode(nodo(SCNBox(width: 1.05, height: 1.25, length: 0.05, chamferRadius: 0), blanco))
                    w.addChildNode(nodo(SCNPlane(width: 0.85, height: 1.05), v, z: 0.03))
                    h.addChildNode(w)
                }
                for y: CGFloat in [1.7, 4.8, 7.9] {
                    for x: CGFloat in [-2.6, -1.3, 0, 1.3, 2.6] { if !(y < 2 && abs(x) < 2) { vent(x, y, 2.77, 0) }; vent(x, y, -2.77, .pi) }
                    for z: CGFloat in [-1.6, 0, 1.6] { vent(3.52, y, z, .pi / 2); vent(-3.52, y, z, -.pi / 2) }
                }
                // Ala de urgencias: hall de vidrio, marquesina sobre pilares y letrero
                let cristal = Mat.pbr(NSColor(Color(hex: "#7fb3cf")), rugosidad: 0.05, metal: 0.3); cristal.transparency = 0.55
                h.addChildNode(nodo(SCNBox(width: 4.4, height: 2.6, length: 2.2, chamferRadius: 0.03), cristal, y: 1.5, z: 3.85))
                h.addChildNode(nodo(SCNBox(width: 4.6, height: 0.3, length: 2.4, chamferRadius: 0), blanco, y: 2.95, z: 3.85))
                h.addChildNode(nodo(SCNBox(width: 5.4, height: 0.2, length: 2.0, chamferRadius: 0), gris, y: 3.0, z: 5.9))
                for x: CGFloat in [-2.5, 2.5] { h.addChildNode(nodo(SCNCylinder(radius: 0.1, height: 2.9), gris, y: 1.5, x: x, z: 6.7)) }
                let letrero = SCNMaterial(); letrero.diffuse.contents = Pizarra.letrero("URGENCIAS"); letrero.emission.contents = Pizarra.letrero("URGENCIAS"); letrero.emission.intensity = 0.6
                h.addChildNode(nodo(SCNBox(width: 3.4, height: 0.55, length: 0.08, chamferRadius: 0), letrero, y: 3.45, z: 5.0))
                // Cruz roja en la fachada y helipuerto en la azotea
                for (w, hh) in [(CGFloat(1.6), CGFloat(0.5)), (0.5, 1.6)] { h.addChildNode(nodo(SCNBox(width: w, height: hh, length: 0.1, chamferRadius: 0), rojo, y: 7.9, z: 2.82)) }
                h.addChildNode(nodo(SCNCylinder(radius: 2.1, height: 0.12), gris, y: 10.16))
                let hm = Mat.pbr(.white, rugosidad: 0.4)
                for x: CGFloat in [-0.55, 0.55] { h.addChildNode(nodo(SCNBox(width: 0.22, height: 0.02, length: 1.5, chamferRadius: 0), hm, y: 10.23, x: x)) }
                h.addChildNode(nodo(SCNBox(width: 1.1, height: 0.02, length: 0.22, chamferRadius: 0), hm, y: 10.23))
                let m0 = mundo(0, 0); nav.rect(m0.x, m0.y, 3.7, 2.95, yaw)
                let m1 = mundo(0, 3.85); nav.rect(m1.x, m1.y, 2.2, 1.1, yaw)
                for x: CGFloat in [-2.5, 2.5] { let mp = mundo(x, 6.7); nav.circulo(mp.x, mp.y, 0.15) }
            case "library":
                let yawL = atan2(-c.x, -c.y)
                let g = SCNNode(); g.eulerAngles.y = yawL; n.addChildNode(g)
                let vidrio = Mat.pbr(NSColor(Color(hex: "#9fd8ff")), rugosidad: 0.05, metal: 0.2); vidrio.transparency = 0.5
                g.addChildNode(nodo(SCNBox(width: 7, height: 9.2, length: 5.5, chamferRadius: 0.1), vidrio, y: 4.7))
                let marco = Mat.pbr(NSColor(calibratedWhite: 0.85, alpha: 1), metal: 0.7)
                for x in stride(from: -3.5, through: 3.5, by: 1.75) { g.addChildNode(nodo(SCNBox(width: 0.12, height: 9.2, length: 5.6, chamferRadius: 0), marco, y: 4.7, x: x)) }
                // Losas de piso (tres pisos), puerta doble de vidrio con marco y alero, y escalones
                for y: CGFloat in [0.15, 3.15, 6.15, 9.15] { g.addChildNode(nodo(SCNBox(width: 7.1, height: 0.18, length: 5.6, chamferRadius: 0), marco, y: y)) }   // pisos de 3 m
                let oscuro = Mat.pbr(NSColor(calibratedWhite: 0.18, alpha: 1), rugosidad: 0.3, metal: 0.7)
                g.addChildNode(nodo(SCNBox(width: 2.4, height: 2.3, length: 0.1, chamferRadius: 0), oscuro, y: 1.3, z: 2.8))
                for x: CGFloat in [-0.56, 0.56] {
                    let hoja = Mat.pbr(NSColor(Color(hex: "#bfe6ff")), rugosidad: 0.05, metal: 0.2); hoja.transparency = 0.45
                    g.addChildNode(nodo(SCNBox(width: 1.04, height: 2.1, length: 0.04, chamferRadius: 0), hoja, y: 1.25, x: x, z: 2.86))
                    g.addChildNode(nodo(SCNBox(width: 0.04, height: 0.5, length: 0.06, chamferRadius: 0.02), Mat.pbr(.white, metal: 0.9), y: 1.2, x: x * 0.15, z: 2.9))
                }
                g.addChildNode(nodo(SCNBox(width: 3.4, height: 0.15, length: 1.4, chamferRadius: 0.02), marco, y: 2.65, z: 3.4))
                g.addChildNode(nodo(SCNBox(width: 3.0, height: 0.15, length: 0.9, chamferRadius: 0), Mat.textura(.marmol, repetir: 1), y: 0.2, z: 3.2))
                let cerebro = nodo(SCNSphere(radius: 1.5), Mat.pbr(NSColor(Color(hex: "#f19ab8")), rugosidad: 0.5), y: 11.0, x: c.x, z: c.y)
                cerebro.scale = SCNVector3(1.25, 0.9, 1)
                cerebro.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 14)))
                escena.rootNode.addChildNode(cerebro)   // gira: queda fuera del bloque estático
                nav.rect(c.x, c.y, 3.5, 2.75, yawL)
            case "port":
                PuertoYFlota.capitania(n, c: c, muro: muro, techo: NSColor(Color(hex: z.roof)), nav: nav)
            case "trade", "bank", "casino", "museum", "university", "science", "airport", "airbase", "navalbase", "army", "defense", "police", "maritime", "energy":
                break                 // islas nuevas: sus edificios van en montarIslas
            case "mall":
                break                 // el mall (alas, atrio y tótem) va en el bloque estático: montarMall
            case "dome":
                let blanca = Mat.pbr(.white, rugosidad: 0.95)
                n.addChildNode(nodo(SCNSphere(radius: 3.2), blanca, y: piso + 1.2))
                for i in 0..<7 {
                    let a = CGFloat(i) / 7 * .pi * 2
                    n.addChildNode(nodo(SCNSphere(radius: 1.6 + CGFloat(i % 3) * 0.4), blanca, y: piso + 0.9, x: cos(a) * 2.6, z: sin(a) * 2.6))
                }
                nav.circulo(c.x, c.y, 3.6)
            case "workshop":
                let yawT = atan2(-c.x, -c.y)
                let g = SCNNode(); g.eulerAngles.y = yawT; n.addChildNode(g)
                g.addChildNode(nodo(SCNBox(width: 8.5, height: 4.2, length: 6.5, chamferRadius: 0.1), muro, y: 2.2))
                let techo = Mat.pbr(NSColor(Color(hex: z.roof)), rugosidad: 0.5, metal: 0.4)
                for i in 0..<4 {
                    let d = nodo(SCNBox(width: 2.3, height: 0.15, length: 6.7, chamferRadius: 0), techo, y: 4.95, x: -3.2 + CGFloat(i) * 2.15)
                    d.eulerAngles.z = 0.5; g.addChildNode(d)
                }
                // Portón enrollable con listones, puerta peatonal con alero y ventanas altas a los costados
                let acero = Mat.pbr(NSColor(Color(hex: "#5d6570")), metal: 0.6)
                g.addChildNode(nodo(SCNBox(width: 3, height: 3, length: 0.1, chamferRadius: 0), acero, y: 1.6, x: -1.6, z: 3.27))
                for k in 0..<8 { g.addChildNode(nodo(SCNBox(width: 3.02, height: 0.04, length: 0.12, chamferRadius: 0), Mat.pbr(NSColor(Color(hex: "#7b838d")), metal: 0.6), y: 0.3 + CGFloat(k) * 0.37, x: -1.6, z: 3.28)) }
                g.addChildNode(nodo(SCNBox(width: 1.0, height: 2.1, length: 0.08, chamferRadius: 0), Mat.pbr(NSColor(Color(hex: "#2f6f9f")), rugosidad: 0.4), y: 1.15, x: 1.9, z: 3.28))
                g.addChildNode(nodo(SCNSphere(radius: 0.04), Mat.pbr(.white, metal: 0.9), y: 1.1, x: 2.25, z: 3.34))
                g.addChildNode(nodo(SCNBox(width: 1.6, height: 0.1, length: 0.8, chamferRadius: 0), acero, y: 2.45, x: 1.9, z: 3.6))
                let vT = ventana(), marcoT = Mat.pbr(.white, rugosidad: 0.5)
                for x: CGFloat in [0.9, 2.9] { g.addChildNode(nodo(SCNBox(width: 0.9, height: 0.7, length: 0.04, chamferRadius: 0), marcoT, y: 2.9, x: x - 0.2, z: 3.27)); g.addChildNode(nodo(SCNPlane(width: 0.78, height: 0.58), vT, y: 2.9, x: x - 0.2, z: 3.3)) }
                for sx: CGFloat in [-1, 1] {
                    for z: CGFloat in [-2.2, -0.7, 0.8, 2.3] {
                        let w = SCNNode(); w.position = SCNVector3(sx * 4.27, 3.2, z); w.eulerAngles.y = sx * .pi / 2
                        w.addChildNode(nodo(SCNBox(width: 1.1, height: 0.7, length: 0.04, chamferRadius: 0), marcoT))
                        w.addChildNode(nodo(SCNPlane(width: 0.98, height: 0.58), vT, z: 0.03))
                        g.addChildNode(w)
                    }
                }
                nav.rect(c.x, c.y, 4.25, 3.25, yawT)
            default:
                let yawB = atan2(-c.x, -c.y)
                let g = SCNNode(); g.eulerAngles.y = yawB; n.addChildNode(g)
                g.addChildNode(nodo(SCNBox(width: 9, height: 3.6, length: 6.5, chamferRadius: 0.1), Mat.textura(.madera, repetir: 3, tinte: z.wall), y: 1.9))
                let techo = nodo(SCNCylinder(radius: 4.6, height: 6.8), Mat.pbr(NSColor(Color(hex: z.roof)), rugosidad: 0.6), y: 3.6)
                techo.eulerAngles.x = .pi / 2; techo.scale = SCNVector3(1, 1, 0.45); g.addChildNode(techo)
                // Portón de dos hojas con cruz de refuerzo y marco blanco, ventanas con postigos y ventanuco del altillo
                let puertaM = Mat.textura(.madera, repetir: 1, tinte: "#6b4a2c"), blancoB = Mat.pbr(NSColor(Color(hex: "#f2efe8")), rugosidad: 0.5)
                for sx: CGFloat in [-0.75, 0.75] {
                    g.addChildNode(nodo(SCNBox(width: 1.45, height: 2.8, length: 0.1, chamferRadius: 0), puertaM, y: 1.5, x: sx, z: 3.27))
                    for giro: CGFloat in [0.98, -0.98] { let x = nodo(SCNBox(width: 0.1, height: 3.0, length: 0.03, chamferRadius: 0), blancoB, y: 1.5, x: sx, z: 3.33); x.eulerAngles.z = giro * 0.45; g.addChildNode(x) }
                }
                g.addChildNode(nodo(SCNBox(width: 3.2, height: 0.12, length: 0.14, chamferRadius: 0), blancoB, y: 2.95, z: 3.3))
                for sx: CGFloat in [-1, 1] { g.addChildNode(nodo(SCNBox(width: 0.12, height: 2.9, length: 0.14, chamferRadius: 0), blancoB, y: 1.5, x: sx * 1.55, z: 3.3)) }
                let vB = ventana()
                g.addChildNode(nodo(SCNBox(width: 1.0, height: 0.8, length: 0.05, chamferRadius: 0), blancoB, y: 4.6, z: 2.2)); g.addChildNode(nodo(SCNPlane(width: 0.85, height: 0.65), vB, y: 4.6, z: 2.24))
                for sx: CGFloat in [-1, 1] {
                    for x: CGFloat in [-3.2, 3.2] { g.addChildNode(nodo(SCNBox(width: 1.0, height: 1.0, length: 0.05, chamferRadius: 0), blancoB, y: 1.9, x: x, z: sx * 3.26)); g.addChildNode(nodo(SCNPlane(width: 0.86, height: 0.86), vB, y: 1.9, x: x, z: sx * 3.29)) }
                    for z: CGFloat in [-1.6, 0, 1.6] {
                        let w = SCNNode(); w.position = SCNVector3(sx * 4.52, 1.9, z); w.eulerAngles.y = sx * .pi / 2
                        w.addChildNode(nodo(SCNBox(width: 1.0, height: 1.0, length: 0.05, chamferRadius: 0), blancoB))
                        w.addChildNode(nodo(SCNPlane(width: 0.86, height: 0.86), vB, z: 0.03))
                        for px: CGFloat in [-0.75, 0.75] { w.addChildNode(nodo(SCNBox(width: 0.45, height: 1.0, length: 0.04, chamferRadius: 0), puertaM, x: px, z: 0.02)) }
                        g.addChildNode(w)
                    }
                }
                nav.rect(c.x, c.y, 4.6, 3.4, yawB)
            }
        }

        // MARK: Agentes

        func sincronizar() {
            montarZonas()
            let porZona = Dictionary(grouping: almacen.agentes, by: \.zona)
            // Ayudantes de la sede (p. ej. el Revisor de agentes): oficina en la plaza de gobierno, cerca del Alcalde.
            for (i, a) in (porZona["sede"] ?? []).enumerated() {
                if let p = personas[a.id] { p.actualizar(a); oficinas[a.id]?.actualizar(a); continue }
                // Anexo de Asesoría al costado del palacio: misma orientación y fachada alineada con la del palacio.
                // Cuatro despachos: adelante Seguridad y Revisor; atrás Hacienda y Cancillería (no se encima ninguno).
                let pos = CGPoint(x: 10.4 * (i % 2 == 0 ? 1 : -1), y: i < 2 ? 2.3 : -1.4)
                let of = Oficina(agente: a, pos: pos, yaw: 0, piso: 0.12, zona: almacen.zonas["sede"], nav: nav, asesoria: true)
                escena.rootNode.addChildNode(of.raiz)
                oficinas[a.id] = of
                let p = Persona(agente: a, oficina: of, centroZona: pos, radioZona: 0)            // no pasea: atiende en su oficina
                p.colocar(en: of.silla, piso: alturaPiso(of.silla))
                escena.rootNode.addChildNode(p.raiz)
                personas[a.id] = p
            }
            for (zid, lista) in porZona {
                guard let c = Coordinador.posiciones[zid], let r = Coordinador.radios[zid] else { continue }
                // La entrada del barrio (camino o escalera) mira a la sede: las oficinas la dejan libre.
                let entrada = atan2(-c.y, -c.x)
                // Alas: oficinas contiguas (3,75 m cada una) en arco detrás y a los costados del edificio principal,
                // con la puerta hacia afuera; el frente (hacia el palacio) queda libre. Si no caben, el arco se abre.
                let n = CGFloat(lista.count + (zid == "nube" ? Mall.enLaNube(almacen.agentes).count : 0))
                // Contiguas medidas en el lado interior (el más corto del arco): 3,7 m por oficina, sin montarse.
                let radio = max(Coordinador.radioAla[zid] ?? (r - 2.3), n * 3.7 / (2 * .pi - 1.25) + 1.7)
                let paso = 3.7 / (radio - 1.7)
                for (i, a) in lista.enumerated() {
                    if let p = personas[a.id] { p.actualizar(a); oficinas[a.id]?.actualizar(a); oficinasNube[a.id]?.actualizar(a); continue }
                    if zid == "mall" {     // atrio del mall: en fila frente al muro de las pantallas, puertas hacia la entrada
                        let pos = Mall.marco(73.2, 0, (CGFloat(i) - (n - 1) / 2) * 4.0, 0)
                        let of = Oficina(agente: a, pos: pos, yaw: Mall.ang + .pi, piso: 0.12, zona: almacen.zonas[zid], nav: nav)
                        escena.rootNode.addChildNode(of.raiz)
                        oficinas[a.id] = of
                        let p = Persona(agente: a, oficina: of, centroZona: c, radioZona: r)
                        p.colocar(en: of.silla, piso: alturaPiso(of.silla))
                        escena.rootNode.addChildNode(p.raiz)
                        personas[a.id] = p
                        continue
                    }
                    let nube = zid == "nube"      // plataforma chica con baranda: anillo parejo con puertas hacia el centro
                    let ang = nube ? entrada + (CGFloat(i) + 0.5) / n * .pi * 2 : entrada + .pi + (CGFloat(i) - (n - 1) / 2) * paso
                    let rr = nube ? r - 2.3 : radio
                    let pos = CGPoint(x: c.x + cos(ang) * rr, y: c.y + sin(ang) * rr)
                    let yaw = nube ? atan2(c.x - pos.x, c.y - pos.y) : atan2(pos.x - c.x, pos.y - c.y)   // +z local = puerta
                    let piso = zid == "nube" ? Nube.alto : 0.12
                    let of = Oficina(agente: a, pos: pos, yaw: yaw, piso: piso, zona: almacen.zonas[zid], nav: nav)
                    escena.rootNode.addChildNode(of.raiz)
                    if !nube { escena.rootNode.addChildNode(alaComun(pos: pos, yaw: yaw, piso: piso, radio: radio, paso: paso)) }
                    oficinas[a.id] = of
                    let p = Persona(agente: a, oficina: of, centroZona: c, radioZona: r)
                    p.colocar(en: of.silla, piso: alturaPiso(of.silla))
                    escena.rootNode.addChildNode(p.raiz)
                    personas[a.id] = p
                }
            }
            montarOficinasNube()
            actualizarDirectorios()
            for id in Set(personas.keys).subtracting(almacen.agentes.map(\.id)) {
                personas[id]?.raiz.removeFromParentNode(); oficinas[id]?.raiz.removeFromParentNode()
                oficinasNube[id]?.raiz.removeFromParentNode(); oficinasNube[id] = nil
                personas[id] = nil; oficinas[id] = nil
            }
            if almacen.seleccion != seleccionPrevia {
                tocado()
                seleccionPrevia = almacen.seleccion
                for (id, p) in personas { p.resaltar(id == almacen.seleccion) }
                let sel = almacen.seleccion
                DispatchQueue.main.async { ControlVilla.shared.pizarra = sel }   // fuera de la actualización de vista
                if let id = sel { enfocarAgente(id) } else { atenuarEmblema(de: nil) }
            }
        }

        @objc func tick(_ e: CADisplayLink) {
            let ahora = e.timestamp
            let dt = ultimo == 0 ? 1.0 / 60 : min(0.1, ahora - ultimo)
            ultimo = ahora
            aplicarCamara(CGFloat(dt))
            let lista = Array(personas.values)
            let cam = camara.position
            for p in lista {
                p.paso(dt: CGFloat(dt), ahora: ahora, nav: nav, piso: alturaPiso)
                let dc = hypot(p.pos.x - cam.x, p.pos.y - cam.z)
                p.cartelLejos = dc > 10    // de cerca el cartel tapa la vista
                let lejos = dc > 115 && almacen.seleccion != p.raiz.name?.replacingOccurrences(of: "agente:", with: "")
                if p.raiz.isHidden != lejos { p.raiz.isHidden = lejos }   // de muy lejos no se distinguen: no se dibujan
            }
            // Nadie atraviesa a nadie: separación suave entre personas cercanas (sin entrar a celdas bloqueadas).
            if lista.count > 1 {
                for i in 0..<(lista.count - 1) {
                    for j in (i + 1)..<lista.count {
                        let a = lista[i], b = lista[j]
                        let pa = a.pos, pb = b.pos
                        let d = hypot(pa.x - pb.x, pa.y - pb.y)
                        if d < 0.62 && d > 0.001 && abs(a.alturaActual - b.alturaActual) < 1 {
                            let k = (0.62 - d) / 2 / d
                            let na = CGPoint(x: pa.x + (pa.x - pb.x) * k, y: pa.y + (pa.y - pb.y) * k)
                            let nb = CGPoint(x: pb.x - (pa.x - pb.x) * k, y: pb.y - (pa.y - pb.y) * k)
                            if nav.libre(na) { a.pos = na }
                            if nav.libre(nb) { b.pos = nb }
                        }
                    }
                }
            }
            moverTrafico(CGFloat(dt), ahora: ahora)
            moverDefensa(ahora)
            aplicarNoche()
            puerto?.mover(CGFloat(dt), ahora: ahora, alerta: !incidentes.isEmpty, agentes: almacen.agentes)
            moverAgentesNube(ahora)
            actualizarPantallasMall(ahora)
            moverPuertasMall(CGFloat(dt))
            metro?.mover(CGFloat(dt))
            if ahora - refrescoPantalla > 15 && !almacen.agentes.isEmpty { refrescoPantalla = ahora; actualizarPantallon() }
            if !auditado && !oficinas.isEmpty {
                if inicioAuditoria == 0 { inicioAuditoria = ahora } else if ahora - inicioAuditoria > 6 { auditarFisica() }
            }
            let cv = ControlVilla.shared
            if cv.recorrido || cv.verAudiencia { ultimaInteraccion = ahora }
            else if ahora - ultimaInteraccion > 600 && !cv.dormida { DispatchQueue.main.async { cv.dormida = true; self.ajustarRitmo() } }
            if Int(ahora) % 30 == 0 { actualizarCielo() }
        }

        // MARK: Día y noche con la hora del Mac

        func actualizarCielo() {
            let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
            let h = tema == "claro" ? 13 : tema == "oscuro" ? 23 : Double(c.hour ?? 12) + Double(c.minute ?? 0) / 60
            let clave = Int(h * 4)
            guard clave != ultimoCielo else { return }
            ultimoCielo = clave
            let elev = sin((h - 6.3) / 12.6 * .pi)              // >0 de día
            let dia = max(0, min(1, elev * 2.2 + 0.25))
            let cielo = Cielo.imagen(dia: dia, atardecer: max(0, 1 - abs(elev) * 4))
            escena.background.contents = cielo
            escena.lightingEnvironment.contents = cielo
            escena.lightingEnvironment.intensity = 0.45 + dia * 0.45
            escena.fogStartDistance = 170; escena.fogEndDistance = 480
            escena.fogColor = NSColor(calibratedRed: 0.55 * dia + 0.05, green: 0.68 * dia + 0.07, blue: 0.85 * dia + 0.14, alpha: 1)
            ambiente.light!.intensity = 150 + dia * 150
            ambiente.light!.color = dia > 0.3 ? NSColor.white : NSColor(calibratedRed: 0.55, green: 0.62, blue: 0.9, alpha: 1)
            sol.light!.intensity = 250 + dia * 650
            sol.light!.color = dia > 0.3 ? NSColor(calibratedRed: 1, green: 0.97, blue: 0.9, alpha: 1) : NSColor(calibratedRed: 0.6, green: 0.7, blue: 1, alpha: 1)
            let az = (h - 12) / 12 * .pi
            sol.eulerAngles = SCNVector3(-max(0.35, abs(elev)) * 1.2, az, 0)
            let noche: CGFloat = dia < 0.35 ? 1 : 0
            esNoche = noche > 0
            for m in ventanas { m.emission.intensity = noche * 1.4 }
            for m in focos { m.emission.intensity = noche * 2.2 + 0.1 }
            let o = max(0, min(1, 1 - dia * 2.2)); estrellas.opacity = o; estrellas.isHidden = o < 0.02
        }

        // MARK: Cámara orbital (arrastrar = girar, ⇧/⌥/clic derecho = desplazar, rueda/pellizco = zoom al cursor)

        private func aplicarCamara(_ dt: CGFloat) {
            if !teclas.isEmpty { moverConTeclas(dt) }
            let k = min(1, dt * suavidad)
            giro += (metaGiro - giro) * k
            inclinacion += (metaInclinacion - inclinacion) * k
            distancia += (metaDistancia - distancia) * k
            objetivo = SCNVector3(objetivo.x + (metaObjetivo.x - objetivo.x) * k, objetivo.y + (metaObjetivo.y - objetivo.y) * k,
                                  objetivo.z + (metaObjetivo.z - objetivo.z) * k)
            if suavidad < 10 && abs(metaDistancia - distancia) < 0.3 && abs(metaGiro - giro) < 0.01 { suavidad = 10 }
            let h = cos(inclinacion) * distancia
            camara.position = SCNVector3(objetivo.x + sin(giro) * h, objetivo.y + sin(inclinacion) * distancia, objetivo.z + cos(giro) * h)
            estrellas.position = camara.position
            let fov: CGFloat = ControlVilla.shared.dentro == nil ? 48 : 78   // adentro: gran angular para ver toda la oficina
            if let c = camara.camera, abs(c.fieldOfView - fov) > 0.1 { c.fieldOfView += (fov - c.fieldOfView) * k }
            // Adentro: menos exposición y sin resplandor, para que el sol y la luminaria no quemen muros, piso y muebles.
            let adentro = ControlVilla.shared.dentro != nil
            if let c = camara.camera {
                c.exposureOffset += ((adentro ? -1.6 : 0) - c.exposureOffset) * k
                c.bloomIntensity = adentro ? 0 : 0.35
            }
            camara.look(at: objetivo, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))   // sin rodar: horizonte siempre recto
        }

        /// Vuelo animado (suave, como flyTo de la web). El giro va por el camino corto.
        func volar(_ p: SCNVector3, distancia d: CGFloat, inclinacion i: CGFloat? = nil, giro g: CGFloat? = nil, despejar: Bool = true) {
            metaObjetivo = p; metaDistancia = d
            var ii = i ?? metaInclinacion, gg = g ?? metaGiro
            if despejar { (gg, ii) = vistaDespejada(p, distancia: d, inclinacion: ii, giro: gg) }
            metaInclinacion = ii
            var dd = gg - metaGiro
            while dd > .pi { dd -= 2 * .pi }; while dd < -.pi { dd += 2 * .pi }
            metaGiro += dd
            suavidad = 3.2
        }

        /// Elige desde dónde llegar para que ningún otro edificio tape el destino: prueba primero la vista pedida,
        /// después giros cercanos y, si hace falta, una cámara algo más alta (la más parecida a la pedida que quede libre).
        private func vistaDespejada(_ p: SCNVector3, distancia d: CGFloat, inclinacion i: CGFloat, giro g: CGFloat) -> (CGFloat, CGFloat) {
            guard ControlVilla.shared.dentro == nil, d > 8, d < 140 else { return (g, i) }
            let libre = max(5, d * 0.22), mira = min(8, max(1.5, d * 0.08))
            func tapado(_ gg: CGFloat, _ ii: CGFloat) -> Int {
                let h = cos(ii) * d
                let cam = SCNVector3(p.x + sin(gg) * h, p.y + sin(ii) * d, p.z + cos(gg) * h)
                var n = 0
                for dy in [mira * 0.35, mira] {
                    let hits = escena.rootNode.hitTestWithSegment(from: cam, to: SCNVector3(p.x, p.y + dy, p.z), options: [
                        SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.all.rawValue,
                        SCNHitTestOption.ignoreHiddenNodes.rawValue: true, SCNHitTestOption.backFaceCulling.rawValue: false])
                    if hits.contains(where: { estorba($0, p, libre) }) { n += 1 }
                }
                return n
            }
            var candidatos: [(c: CGFloat, g: CGFloat, i: CGFloat)] = []
            for di: CGFloat in [0, 0.18, 0.36] {
                for dg: CGFloat in [0, 0.35, -0.35, 0.7, -0.7, 1.05, -1.05, 1.4, -1.4, 1.85, -1.85, 2.4, -2.4, .pi] {
                    candidatos.append((abs(dg) + di * 2.5, g + dg, min(1.3, i + di)))
                }
            }
            candidatos.append((99, g, 1.25))                      // último recurso: casi cenital
            candidatos.sort { $0.c < $1.c }
            var mejor = (g, i), menor = Int.max
            for k in candidatos {
                let t = tapado(k.g, k.i)
                if t == 0 { return (k.g, k.i) }
                if t < menor { menor = t; mejor = (k.g, k.i) }
            }
            return mejor
        }

        /// ¿Lo que tocó el rayo tapa de verdad el destino? No cuentan el propio destino, el suelo, el agua, lo transparente,
        /// las etiquetas ni lo pequeño que se mueve (personas, autos).
        private func estorba(_ h: SCNHitTestResult, _ p: SCNVector3, _ libre: CGFloat) -> Bool {
            let w = h.worldCoordinates
            if hypot(w.x - p.x, w.z - p.z) < libre || w.y < 0.6 { return false }
            var x: SCNNode? = h.node
            while let y = x { if y === estrellas || y === camara || y.opacity < 0.3 { return false }; x = y.parent }
            if h.node.renderingOrder >= 10 { return false }
            if let geo = h.node.geometry, !geo.materials.isEmpty {
                let m = geo.materials[h.geometryIndex % geo.materials.count]
                if m.transparency < 0.3 || !m.readsFromDepthBuffer || !m.writesToDepthBuffer { return false }
            }
            let (mn, mx) = h.node.boundingBox, s = h.node.worldTransform
            let escala = hypot(s.m11, hypot(s.m12, s.m13))
            return max(mx.x - mn.x, max(mx.y - mn.y, mx.z - mn.z)) * escala > 2.5
        }

        func orbitar(_ dx: CGFloat, _ dy: CGFloat) {
            suavidad = 10
            metaGiro -= dx * 0.006
            metaInclinacion = min(1.52, max(0.06, metaInclinacion + dy * 0.005))
        }

        func panear(_ dx: CGFloat, _ dy: CGFloat) {
            suavidad = 10
            let e = metaDistancia * 0.0018
            let dxr = cos(giro), dzr = -sin(giro), fx = -sin(giro), fz = -cos(giro)
            metaObjetivo.x += (-dxr * dx + fx * dy) * e
            metaObjetivo.z += (-dzr * dx + fz * dy) * e
            limitarObjetivo()
        }

        func zoom(_ delta: CGFloat, en punto: CGPoint) {
            suavidad = 10
            let nueva = min(150, max(ControlVilla.shared.dentro == nil ? 4 : 1.2, metaDistancia * exp(-delta * 0.012)))
            if nueva < metaDistancia, let g = suelo(punto) {          // acerca hacia lo que apunta el mouse
                let f = 1 - nueva / metaDistancia
                metaObjetivo = SCNVector3(metaObjetivo.x + (g.x - metaObjetivo.x) * f, metaObjetivo.y + (g.y - metaObjetivo.y) * f,
                                          metaObjetivo.z + (g.z - metaObjetivo.z) * f)
            }
            if nueva > metaDistancia { volverAlCentro(nueva) }
            metaDistancia = nueva
        }

        /// Al alejarse, el centro de la vista vuelve de a poco al de la villa: a 80 m ya es la vista general.
        private func volverAlCentro(_ nueva: CGFloat) {
            guard ControlVilla.shared.dentro == nil else { return }
            let lim: CGFloat = 80
            let f = metaDistancia >= lim ? 1 : min(1, (nueva - metaDistancia) / (lim - metaDistancia))
            metaObjetivo = SCNVector3(metaObjetivo.x * (1 - f), metaObjetivo.y * (1 - f), metaObjetivo.z * (1 - f))
            metaInclinacion += (0.61 - metaInclinacion) * f
        }

        func enfocarPunto(_ punto: CGPoint) {
            guard let g = suelo(punto) else { return }
            volar(g, distancia: min(metaDistancia, 22))
        }

        /// Teclas como en la web: W/A/S/D o flechas mueven, Q/E giran, Re Pág/Av Pág acercan.
        func tecla(_ codigo: UInt16, abajo: Bool) -> Bool {
            if codigo == 53 { if abajo, ControlVilla.shared.dentro != nil { ControlVilla.shared.salir() }; return true }   // Esc: salir del edificio
            guard [13, 0, 1, 2, 12, 14, 126, 125, 123, 124, 116, 121].contains(codigo) else { return false }
            if abajo { teclas.insert(codigo) } else { teclas.remove(codigo) }
            return true
        }

        private func moverConTeclas(_ dt: CGFloat) {
            suavidad = 10
            let v = dt * max(10, metaDistancia * 0.9)
            let fx = -sin(giro), fz = -cos(giro), rx = cos(giro), rz = -sin(giro)
            var mx: CGFloat = 0, mz: CGFloat = 0
            if teclas.contains(13) || teclas.contains(126) { mx += fx; mz += fz }
            if teclas.contains(1) || teclas.contains(125) { mx -= fx; mz -= fz }
            if teclas.contains(2) || teclas.contains(124) { mx += rx; mz += rz }
            if teclas.contains(0) || teclas.contains(123) { mx -= rx; mz -= rz }
            metaObjetivo.x += mx * v; metaObjetivo.z += mz * v
            if teclas.contains(12) { metaGiro += dt * 1.6 }
            if teclas.contains(14) { metaGiro -= dt * 1.6 }
            if teclas.contains(116) { metaDistancia = max(4, metaDistancia * (1 - dt * 1.5)) }
            if teclas.contains(121) { metaDistancia = min(150, metaDistancia * (1 + dt * 1.5)) }
            limitarObjetivo()
        }

        private func limitarObjetivo() {
            let d = hypot(metaObjetivo.x, metaObjetivo.z)
            if d > 90 { metaObjetivo.x *= 90 / d; metaObjetivo.z *= 90 / d }
        }

        /// Punto del suelo bajo el cursor (plano y = 0).
        private func suelo(_ p: CGPoint) -> SCNVector3? {
            guard let v = vista else { return nil }
            let a = v.unprojectPoint(SCNVector3(p.x, p.y, 0)), b = v.unprojectPoint(SCNVector3(p.x, p.y, 1))
            guard abs(b.y - a.y) > 1e-6 else { return nil }
            let t = -a.y / (b.y - a.y)
            guard t > 0 else { return nil }
            return SCNVector3(a.x + (b.x - a.x) * t, 0, a.z + (b.z - a.z) * t)
        }

        // MARK: Vuelos y acciones (las llaman los botones del panel)

        func enfocar(_ p: SCNVector3, lejos: CGFloat = 14) { volar(p, distancia: lejos, inclinacion: 0.6) }

        /// Punto de la oficina en coordenadas locales (x lateral, z hacia la puerta) llevado al mundo.
        private func enOficina(_ o: Oficina, _ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> SCNVector3 {
            let c = o.raiz.position, yaw = CGFloat(o.raiz.eulerAngles.y)
            return SCNVector3(c.x + x * cos(yaw) + z * sin(yaw), c.y + y, c.z - x * sin(yaw) + z * cos(yaw))
        }

        /// Hace casi transparente el edificio emblemático del barrio del agente (desde su puerta queda detrás de la cámara).
        func atenuarEmblema(de id: String?) {
            let zona = id.flatMap { i in almacen.agentes.first(where: { $0.id == i })?.zona }
            SCNTransaction.begin(); SCNTransaction.animationDuration = 0.5
            for (zid, n) in emblemas { n.opacity = zid == zona ? 0.12 : 1; n.castsShadow = zid != zona }
            SCNTransaction.commit()
        }

        /// Vista frontal: de cara a la puerta, se ve el interior, el escritorio y la pizarra.
        func enfocarAgente(_ id: String) {
            guard let o = oficinas[id] else { return }
            techos(nil)
            atenuarEmblema(de: id)
            volar(enOficina(o, -1.1, 1.1, 1.6), distancia: 10, inclinacion: 0.4, giro: CGFloat(o.raiz.eulerAngles.y))
        }

        /// Entrar al edificio: cámara adentro a la altura de los ojos, mirando el escritorio.
        func entrarOficina(_ id: String) {
            guard let o = oficinas[id] else { return }
            atenuarEmblema(de: id)
            techos(id)
            // Desde la esquina junto a la puerta (1,3; 1,65; 1,35), mirando en diagonal el escritorio: se ve al agente de perfil.
            volar(enOficina(o, -0.2, 0.9, -0.85), distancia: 2.77, inclinacion: 0.275, giro: CGFloat(o.raiz.eulerAngles.y) + 0.598)
        }

        /// Techo con luminaria solo en la oficina donde está la cámara (afuera se ve abierta desde arriba).
        private func techos(_ id: String?) {
            for (k, o) in oficinas { o.techo.isHidden = k != id }
            // Los rótulos grandes se dibujan sin profundidad: adentro se ocultan para que no atraviesen muros.
            escena.rootNode.enumerateChildNodes { n, _ in
                if n.renderingOrder == 10, n.geometry?.firstMaterial?.readsFromDepthBuffer == false { n.isHidden = id != nil }
            }
        }

        func irBarrio(_ zid: String) {
            guard let c = Coordinador.posiciones[zid], let r = Coordinador.radios[zid] else { return }
            techos(nil)
            atenuarEmblema(de: nil)
            if zid == "mall" {            // el mall completo: alas, atrio con sus oficinas, estacionamiento y andén
                let m = Mall.polar(69, 0)
                volar(SCNVector3(m.x, 0, m.y), distancia: 58, inclinacion: 0.6, giro: Mall.ang + .pi); return
            }
            if zid == "aeropuerto" {      // el aeropuerto entero: pista, terminal, torre y hangares
                let m = Islas.aero(0, -2)
                volar(SCNVector3(m.x, 0, m.y), distancia: 92, inclinacion: 0.62, giro: Islas.angAero + .pi); return
            }
            if zid == "energia" {        // la isla entera: centrales, plantas, observatorio y parque eólico
                let m = Islas.ener(0, 4)
                volar(SCNVector3(m.x, 0, m.y), distancia: 120, inclinacion: 0.7, giro: Islas.angEner + .pi); return
            }
            if Islas.zonas.contains(zid) {  // barrios de la isla distrito: edificios altos, se ven de más lejos
                let frente = zid == "banco" ? Islas.angDist : zid == "fach" ? Islas.angFA : atan2(-c.x, -c.y)   // la base aérea mira a su pista     // de frente a la fachada (miran a la villa)
                volar(SCNVector3(c.x, 0, c.y), distancia: max(r * 3.2, 40), inclinacion: 0.55, giro: frente); return
            }
            if zid == "puerto" {          // el puerto se ve entero: capitanía, muelles, barcos y faro, mirando al mar
                let m = PuertoYFlota.w(0, 88)
                volar(SCNVector3(m.x, 0, m.y), distancia: 72, inclinacion: 0.72, giro: PuertoYFlota.ang + .pi); return
            }
            volar(SCNVector3(c.x, zid == "nube" ? Nube.alto : 0, c.y), distancia: r * 2.6, inclinacion: 0.78, giro: atan2(-c.x, -c.y))   // de frente: miran a la plaza
        }

        func enfocarSede() { techos(nil); atenuarEmblema(de: nil); volar(SCNVector3(2.5, 3.0, 4.0), distancia: 27, inclinacion: 0.36, giro: 0.3) }

        /// Vuela la cámara a un punto del mundo (desde el plano).
        func volarA(_ p: CGPoint, distancia: CGFloat, deFrente: Bool = false) {
            techos(nil); atenuarEmblema(de: nil)
            volar(SCNVector3(p.x, 0, p.y), distancia: distancia, inclinacion: 0.7, giro: deFrente ? atan2(-p.x, -p.y) : nil)
        }

        func vistaGeneral() { techos(nil); atenuarEmblema(de: nil); volar(SCNVector3(0, 0, 0), distancia: 80, inclinacion: 0.61, giro: 0) }

        func llamar(_ id: String) { personas[id]?.llamado = true; personas[id]?.replanear = true }
        func despedir(_ id: String) { personas[id]?.llamado = false; personas[id]?.replanear = true }

        /// Reiniciar: todos vuelven a su escritorio.
        func reiniciar() {
            for (id, p) in personas {
                p.llamado = false
                if let o = oficinas[id] { p.colocar(en: o.silla, piso: alturaPiso(o.silla)) }
            }
        }

        func refrescarCielo() { ultimoCielo = -1; actualizarCielo() }

        func mover(_ accion: String) {
            tocado()
            suavidad = 6
            switch accion {
            case "general": ControlVilla.shared.general()
            case "acercar": metaDistancia = max(4, metaDistancia * 0.7)
            case "alejar": let n = min(150, metaDistancia * 1.4); volverAlCentro(n); metaDistancia = n
            case "izquierda": metaGiro -= .pi / 8
            case "derecha": metaGiro += .pi / 8
            case "subir": metaInclinacion = min(1.52, metaInclinacion + 0.15)
            case "bajar": metaInclinacion = max(0.06, metaInclinacion - 0.15)
            default: break
            }
        }

        /// Elementos fijos o lentos a los que la cámara vuela al hacer clic (no los que van por el aire).
        static let volables = ["garita", "ambulancia", "puerto", "flota", "avion", "bus", "caleta", "balneario", "marina", "letrero", "jet", "metro"]
        /// Vistas del panel Metro: «exterior» o «interior» frente al viaducto en el rumbo `a`, «arriba» todo el circuito,
        /// o «estacion» la puerta de la torre de acceso `k`.
        func vistaMetro(_ modo: String, a: CGFloat, k: Int) {
            techos(nil); atenuarEmblema(de: nil)
            let p = Islas.polar(MetroVilla.radio, a)
            switch modo {
            case "exterior": volar(SCNVector3(p.x, 9, p.y), distancia: 58, inclinacion: 0.2, giro: a, despejar: false)
            case "interior": volar(SCNVector3(p.x, 9, p.y), distancia: 34, inclinacion: 0.18, giro: a + .pi, despejar: false)
            case "arriba": volar(SCNVector3(0, 0, 0), distancia: 235, inclinacion: 1.5, giro: 0, despejar: false)
            default:
                guard let acc = metro?.accesos(), acc.indices.contains(k) else { return }
                let q = acc[k].puerta
                volar(SCNVector3(q.x, 7, q.y), distancia: 38, inclinacion: 0.42, giro: atan2(-q.x, -q.y), despejar: true)
            }
        }
        var accesosMetro: [(nombre: String, puerta: CGPoint)] { metro?.accesos() ?? [] }
        func reporteMetro(_ e: String) -> (titulo: String, quien: String, texto: String)? { metro?.reporte(e) }

        /// Vuela al grupo de batalla del portaaviones, desde la isla.
        func irFlota() {
            guard let p = puerto?.posPortaaviones else { return }
            techos(nil); atenuarEmblema(de: nil)
            volar(SCNVector3(p.x, 2, p.z), distancia: 95, inclinacion: 0.5, giro: PuertoYFlota.flotaAng + .pi)
        }

        /// Vuela al cuartel de bomberos, de frente a sus portones.
        func enfocarCuartel() {
            techos(nil); atenuarEmblema(de: nil)
            volar(SCNVector3(centroCuartel.x, 1.5, centroCuartel.y), distancia: 26, inclinacion: 0.5, giro: Coordinador.cuartelAng + .pi)   // de frente: el cuartel mira al palacio
        }

        /// Vuela a un elemento de la villa según su tamaño.
        func enfocarElemento(_ n: SCNNode) {
            let (c, r) = n.presentation.boundingSphere
            let p = n.presentation.convertPosition(c, to: nil)
            techos(nil); atenuarEmblema(de: nil)
            volar(SCNVector3(p.x, max(0, p.y - CGFloat(r) * 0.3), p.z), distancia: max(14, CGFloat(r) * 3), inclinacion: 0.55)
        }

        /// Diagnóstico: lo que tocó el último clic (para revisar clics que no responden).
        private func registrarClic(_ hits: [SCNHitTestResult]) {
            let l = hits.prefix(6).map { h -> String in
                var x: SCNNode? = h.node, n = "-"
                while let y = x { if let nm = y.name { n = nm; break }; x = y.parent }
                return String(format: "%@ (%.1f, %.1f, %.1f)", n, h.worldCoordinates.x, h.worldCoordinates.y, h.worldCoordinates.z)
            }
            try? (Date().description + "\n" + l.joined(separator: "\n") + "\n").write(toFile: Almacen.carpetaLocal + "/trabajo/ultimo-clic.txt", atomically: true, encoding: .utf8)
        }

        /// Clic: personaje → su pizarra; barrio → volar al barrio; plaza central → sede de gobierno.
        func clic(en punto: CGPoint) {
            guard let v = vista else { return }
            if ControlVilla.shared.dentro != nil {   // adentro: un clic en cualquier parte sale
                if Date().timeIntervalSince(ControlVilla.shared.entradaEn) > 0.8 { ControlVilla.shared.salir() }
                return
            }
            // Todos los impactos, ignorando lo casi transparente (el edificio del barrio atenuado frente a una oficina).
            let hits = v.hitTest(punto, options: [.searchMode: SCNHitTestSearchMode.all.rawValue]).filter { h in
                var x: SCNNode? = h.node
                while let y = x { if y.opacity < 0.5 { return false }; x = y.parent }
                // Vidrio casi transparente (techos de las alas): el clic lo atraviesa.
                if let geo = h.node.geometry, !geo.materials.isEmpty, geo.materials[h.geometryIndex % geo.materials.count].transparency < 0.3 { return false }
                if h.node.geometry is SCNFloor { return false }      // el mar: el clic sigue hasta el casco del barco
                return true
            }
            registrarClic(hits)
            var n: SCNNode? = hits.first?.node
            while let x = n {
                if let nombre = x.name, nombre.hasPrefix("agente:") { ControlVilla.shared.clicOficina(String(nombre.dropFirst(7))); return }
                if let nombre = x.name, nombre.hasPrefix("dir:") { ControlVilla.shared.abrirDirectorio(String(nombre.dropFirst(4))); return }
                if x.name == "elem:pantallon" { ControlVilla.shared.verCentro = true; AlarmaVilla.shared.reconocer(); return }   // clic en el pantallón: centro de mando
                if let nombre = x.name, nombre.hasPrefix("elem:") {
                    let e = String(nombre.dropFirst(5))
                    ControlVilla.shared.mostrarElemento(e)
                    if e == "bomberos" { enfocarCuartel() }
                    else if e == "aeropuerto" { irBarrio("aeropuerto") }
                    else if ["armada", "ejercito", "comisaria", "fach", "gobmar"].contains(e) { irBarrio(e) }
                    else if e == "ministerio" { irBarrio("defensa") }
                    else if e == "energia" { irBarrio("energia") }
                    else if e.hasPrefix("museo-") { irBarrio("museo") }
                    else if Coordinador.volables.contains(where: { e.hasPrefix($0) }) { enfocarElemento(x) }
                    return
                }
                n = x.parent
            }
            guard let g = hits.first?.worldCoordinates ?? suelo(punto) else { return }
            // Barcos (se mueven): basta un clic cerca
            // Metro: un clic en una estación o en las cocheras abre su tarjeta y vuela a ella
            if let m = metro?.elementoEn(g) {
                ControlVilla.shared.mostrarElemento(m.id); volarA(m.p, distancia: m.id == "metro-cocheras" ? 70 : 42, deFrente: true); return
            }
            if let b = puerto?.cercano(g), let nombre = b.name {
                ControlVilla.shared.mostrarElemento(String(nombre.dropFirst(5))); enfocarElemento(b); return
            }
            // Mall y puerto: un clic en cualquier parte de sus edificios (fuera del anillo) vuela a ellos.
            let gp = CGPoint(x: g.x, y: g.z)
            if hypot(g.x, g.z) > 62.5 && !Mall.libre(gp) { ControlVilla.shared.irBarrio("mall"); return }
            if hypot(g.x, g.z) > 62.5 && !PuertoYFlota.libre(gp) { ControlVilla.shared.irBarrio("puerto"); return }
            // Cuartel de bomberos: cualquier clic sobre su terreno abre su reporte.
            if hypot(g.x - centroCuartel.x, g.z - centroCuartel.y) < 6.8 { ControlVilla.shared.mostrarElemento("bomberos"); enfocarCuartel(); return }
            // Tolerancia: cerca de un personaje o dentro de su oficina también abre su pizarra.
            if let (id, d) = personas.map({ ($0.key, hypot($0.value.pos.x - g.x, $0.value.pos.y - g.z)) }).min(by: { $0.1 < $1.1 }), d < 1.4 {
                ControlVilla.shared.clicOficina(id); return
            }
            if let (id, d) = oficinas.map({ ($0.key, hypot($0.value.raiz.position.x - g.x, $0.value.raiz.position.z - g.z)) }).min(by: { $0.1 < $1.1 }), d < 2.1 {
                ControlVilla.shared.clicOficina(id); return
            }
            for (zid, c) in Coordinador.posiciones where hypot(g.x - c.x, g.z - c.y) <= Coordinador.radios[zid]! + 0.5 {
                ControlVilla.shared.irBarrio(zid); return
            }
            if let z = Islas.barrioDe(gp) { ControlVilla.shared.irBarrio(z); return }
            if hypot(g.x, g.z) <= 14 { ControlVilla.shared.abrirSede() }
        }
    }
}

/// Vista 3D que recibe mouse, trackpad y teclado para la cámara propia.
final class VistaVilla: SCNView {
    weak var coord: Villa3D.Coordinador?
    private var inicio = NSPoint.zero, movido = false
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let w = window else { return }
        let nc = NotificationCenter.default
        for n in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            nc.addObserver(self, selector: #selector(ritmo), name: n, object: w)
        }
        for n in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            nc.addObserver(self, selector: #selector(ritmo), name: n, object: nil)
        }
        ritmo()
    }
    @objc private func ritmo() { coord?.ajustarRitmo() }
    private func punto(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func mouseDown(with e: NSEvent) {
        coord?.tocado()
        window?.makeFirstResponder(self)
        inicio = e.locationInWindow; movido = false
        if e.clickCount == 2 { coord?.enfocarPunto(punto(e)) }
    }
    override func mouseDragged(with e: NSEvent) {
        if hypot(e.locationInWindow.x - inicio.x, e.locationInWindow.y - inicio.y) > 4 { movido = true }
        if e.modifierFlags.contains(.shift) || e.modifierFlags.contains(.option) { coord?.panear(e.deltaX, e.deltaY) }
        else { coord?.orbitar(e.deltaX, e.deltaY) }
    }
    override func mouseUp(with e: NSEvent) { if !movido && e.clickCount == 1 { coord?.clic(en: punto(e)) } }
    override func rightMouseDown(with e: NSEvent) { coord?.tocado(); super.rightMouseDown(with: e) }
    override func rightMouseDragged(with e: NSEvent) { coord?.panear(e.deltaX, e.deltaY) }
    override func otherMouseDragged(with e: NSEvent) { coord?.panear(e.deltaX, e.deltaY) }
    override func scrollWheel(with e: NSEvent) {
        coord?.tocado()
        if e.hasPreciseScrollingDeltas {          // trackpad: vertical = zoom, horizontal = girar
            coord?.zoom(e.scrollingDeltaY, en: punto(e))
            if abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) { coord?.orbitar(-e.scrollingDeltaX * 0.8, 0) }
        } else {
            coord?.zoom(e.scrollingDeltaY * 12, en: punto(e))
        }
    }
    override func magnify(with e: NSEvent) { coord?.tocado(); coord?.zoom(e.magnification * 260, en: punto(e)) }
    override func keyDown(with e: NSEvent) {
        coord?.tocado()
        if e.modifierFlags.contains(.command) || coord?.tecla(e.keyCode, abajo: true) != true { super.keyDown(with: e) }
    }
    override func keyUp(with e: NSEvent) { if coord?.tecla(e.keyCode, abajo: false) != true { super.keyUp(with: e) } }
}

// MARK: - La nube: placa elevada sobre un cúmulo sólido, con escalera y barandas

struct Nube {
    static let alto: CGFloat = 4.2
    var centro = CGPoint.zero, radio: CGFloat = 0
    var pie = CGPoint.zero, cima = CGPoint.zero, ancho: CGFloat = 2.4

    init() {}
    init(centro: CGPoint, radio: CGFloat) {
        self.centro = centro; self.radio = radio
        let l = hypot(centro.x, centro.y)
        let u = CGPoint(x: -centro.x / l, y: -centro.y / l)
        cima = CGPoint(x: centro.x + u.x * (radio - 0.2), y: centro.y + u.y * (radio - 0.2))
        pie = CGPoint(x: centro.x + u.x * (radio + 11), y: centro.y + u.y * (radio + 11))
    }

    /// Altura del piso si el punto está sobre la nube o la escalera.
    func altura(_ p: CGPoint) -> CGFloat? {
        guard radio > 0 else { return nil }
        if hypot(p.x - centro.x, p.y - centro.y) <= radio { return Nube.alto }
        let ax = pie.x - cima.x, az = pie.y - cima.y, l2 = ax * ax + az * az
        let t = ((p.x - cima.x) * ax + (p.y - cima.y) * az) / l2
        guard t >= 0, t <= 1 else { return nil }
        guard hypot(p.x - (cima.x + ax * t), p.y - (cima.y + az * t)) <= ancho / 2 + 0.2 else { return nil }
        return Nube.alto * (1 - t) + 0.02 * t
    }

    @MainActor
    func montar(_ n: SCNNode, nav: Navegacion) {
        let blanca = Mat.pbr(.white, rugosidad: 0.95)
        // Cúmulo sólido de suelo a placa: por eso nadie camina por debajo.
        n.addChildNode(nodo(SCNCylinder(radius: radio * 0.92, height: Nube.alto), blanca, y: Nube.alto / 2))
        for i in 0..<16 {
            let a = CGFloat(i) / 16 * .pi * 2, r = radio * 0.95
            n.addChildNode(nodo(SCNSphere(radius: 1.6 + CGFloat(i % 3) * 0.5), blanca, y: Nube.alto * (0.35 + CGFloat(i % 2) * 0.3), x: cos(a) * r, z: sin(a) * r))
        }
        n.addChildNode(nodo(SCNCylinder(radius: radio, height: 0.25), Mat.pbr(NSColor(calibratedRed: 0.92, green: 0.95, blue: 0.99, alpha: 1), rugosidad: 0.8), y: Nube.alto - 0.12))
        // Barandas alrededor, con hueco en la escalera
        let metal = Mat.pbr(NSColor(calibratedWhite: 0.8, alpha: 1), metal: 0.8)
        let hueco = atan2(cima.y - centro.y, cima.x - centro.x)
        let gap = (ancho + 0.6) / radio
        for i in 0..<48 {
            let a = CGFloat(i) / 48 * .pi * 2
            var dd = a - hueco
            while dd > .pi { dd -= 2 * .pi }; while dd < -.pi { dd += 2 * .pi }
            if abs(dd) < gap / 2 { continue }
            n.addChildNode(nodo(SCNCylinder(radius: 0.04, height: 1), metal, y: Nube.alto + 0.5, x: cos(a) * (radio - 0.1), z: sin(a) * (radio - 0.1)))
        }
        let pasamanos = SCNTorus(ringRadius: radio - 0.1, pipeRadius: 0.035)
        n.addChildNode(nodo(pasamanos, metal, y: Nube.alto + 1))
        nav.anillo(centro.x, centro.y, radio - 0.1, hueco: hueco, ancho: gap)
        // Escalera: peldaños sólidos y barandas laterales (obstáculos)
        let ax = pie.x - cima.x, az = pie.y - cima.y, largo = hypot(ax, az), yaw = atan2(ax, az)
        let pasos = 24
        let marmol = Mat.textura(.marmol, repetir: 1)
        for k in 0..<pasos {
            let t = (CGFloat(k) + 0.5) / CGFloat(pasos)
            let h = max(0.1, Nube.alto * (1 - t))
            let p = nodo(SCNBox(width: ancho, height: h, length: largo / CGFloat(pasos) + 0.02, chamferRadius: 0), marmol,
                         y: h / 2, x: cima.x + ax * t - centro.x, z: cima.y + az * t - centro.y)
            p.eulerAngles.y = yaw; n.addChildNode(p)
        }
        for lado: CGFloat in [-1, 1] {
            let ox = cos(yaw) * lado * (ancho / 2 + 0.05), oz = -sin(yaw) * lado * (ancho / 2 + 0.05)
            let mx = (cima.x + pie.x) / 2 + ox, mz = (cima.y + pie.y) / 2 + oz
            let giro = SCNNode(); giro.position = SCNVector3(mx - centro.x, Nube.alto / 2 + 1, mz - centro.y); giro.eulerAngles.y = yaw
            let b = nodo(SCNBox(width: 0.06, height: 0.06, length: largo + 0.3, chamferRadius: 0), metal)
            b.eulerAngles.x = atan2(Nube.alto, largo)        // baja hacia el pie
            giro.addChildNode(b); n.addChildNode(giro)
            nav.rect(mx, mz, 0.05, largo / 2 + 0.2, yaw)
        }
    }
}

// MARK: - Oficina de un agente: muros con puerta, escritorio, pantalla de estado, silla y pizarra

@MainActor
final class Oficina {
    let raiz = SCNNode()
    let silla: CGPoint          // donde trabaja (mundo)
    let puerta: CGPoint         // justo afuera de la puerta (mundo)
    let mirarEscritorio: CGFloat
    private let pantalla = SCNMaterial()
    private let pizarra = SCNMaterial()
    let techo = SCNNode()       // cielo raso con luminaria: solo visible con la cámara adentro

    init(agente a: Agente, pos: CGPoint, yaw: CGFloat, piso: CGFloat, zona: Zona?, nav: Navegacion, asesoria: Bool = false) {
        raiz.name = "agente:\(a.id)"
        raiz.position = SCNVector3(pos.x, piso, pos.y); raiz.eulerAngles.y = yaw
        func mundo(_ x: CGFloat, _ z: CGFloat) -> CGPoint {
            CGPoint(x: pos.x + x * cos(yaw) + z * sin(yaw), y: pos.y - x * sin(yaw) + z * cos(yaw))
        }
        let W: CGFloat = 3.6, D: CGFloat = 3.4, H: CGFloat = 2.8, t: CGFloat = 0.12, puertaW: CGFloat = 1.25
        let tramo = (W - puertaW) / 2
        let muro = Mat.textura(.estuco, repetir: 1.2, tinte: asesoria ? "#efe5cf" : a.estado == "off" ? "#6d747e" : (zona?.wall ?? "#d9d4c4"))
        let e = SCNNode()
        e.addChildNode(nodo(SCNBox(width: W + 0.3, height: 0.06, length: D + 0.3, chamferRadius: 0), Mat.textura(.madera, repetir: 2, tinte: "#8a6a48"), y: -0.02))
        // Muro del fondo con ventana sobre el escritorio (x 0,2 ± 0,5; de 1,2 a 2,0 m)
        e.addChildNode(nodo(SCNBox(width: W / 2 - 0.3 + 0.0, height: H, length: t, chamferRadius: 0), muro, y: H / 2, x: -(W / 2 + 0.3) / 2, z: -D / 2))
        e.addChildNode(nodo(SCNBox(width: W / 2 - 0.7, height: H, length: t, chamferRadius: 0), muro, y: H / 2, x: (0.7 + W / 2) / 2, z: -D / 2))
        e.addChildNode(nodo(SCNBox(width: 1.0, height: 1.2, length: t, chamferRadius: 0), muro, y: 0.6, x: 0.2, z: -D / 2))
        e.addChildNode(nodo(SCNBox(width: 1.0, height: H - 2.0, length: t, chamferRadius: 0), muro, y: (H + 2.0) / 2, x: 0.2, z: -D / 2))
        do {
            let vidrioF = Mat.pbr(NSColor(Color(hex: "#a9cfe3")), rugosidad: 0.05, metal: 0.3); vidrioF.transparency = 0.35; vidrioF.isDoubleSided = true
            let marcoF = Mat.pbr(NSColor(Color(hex: "#f4f1ea")), rugosidad: 0.45)
            e.addChildNode(nodo(SCNPlane(width: 1.0, height: 0.8), vidrioF, y: 1.6, x: 0.2, z: -D / 2))
            for xx: CGFloat in [-0.3, 0.2, 0.7] { e.addChildNode(nodo(SCNBox(width: 0.05, height: 0.8, length: t + 0.04, chamferRadius: 0), marcoF, y: 1.6, x: xx, z: -D / 2)) }
            for yy: CGFloat in [1.2, 2.0] { e.addChildNode(nodo(SCNBox(width: 1.05, height: 0.05, length: t + 0.04, chamferRadius: 0), marcoF, y: yy, x: 0.2, z: -D / 2)) }
        }
        // Muros laterales con vano de ventana (alféizar a 0,95 m, dintel a 1,85 m), vidrio, marco y repisa
        let vz0: CGFloat = -0.75, vz1: CGFloat = 0.45, vy0: CGFloat = 0.95, vy1: CGFloat = 1.85
        let marco = Mat.pbr(NSColor(Color(hex: "#f4f1ea")), rugosidad: 0.45)
        let vidrio = Mat.pbr(NSColor(Color(hex: "#a9cfe3")), rugosidad: 0.05, metal: 0.3); vidrio.transparency = 0.35; vidrio.isDoubleSided = true
        for s: CGFloat in [-1, 1] {
            let x = s * W / 2
            e.addChildNode(nodo(SCNBox(width: t, height: H, length: D / 2 - vz1, chamferRadius: 0), muro, y: H / 2, x: x, z: (vz1 + D / 2) / 2))
            e.addChildNode(nodo(SCNBox(width: t, height: H, length: vz0 + D / 2, chamferRadius: 0), muro, y: H / 2, x: x, z: (vz0 - D / 2) / 2))
            e.addChildNode(nodo(SCNBox(width: t, height: vy0, length: vz1 - vz0, chamferRadius: 0), muro, y: vy0 / 2, x: x, z: (vz0 + vz1) / 2))
            e.addChildNode(nodo(SCNBox(width: t, height: H - vy1, length: vz1 - vz0, chamferRadius: 0), muro, y: (H + vy1) / 2, x: x, z: (vz0 + vz1) / 2))
            let cristal = nodo(SCNPlane(width: vz1 - vz0, height: vy1 - vy0), vidrio, y: (vy0 + vy1) / 2, x: x, z: (vz0 + vz1) / 2); cristal.eulerAngles.y = .pi / 2
            e.addChildNode(cristal)
            for zz in [vz0, (vz0 + vz1) / 2, vz1] { e.addChildNode(nodo(SCNBox(width: t + 0.04, height: vy1 - vy0, length: 0.05, chamferRadius: 0), marco, y: (vy0 + vy1) / 2, x: x, z: zz)) }
            for yy in [vy0, vy1] { e.addChildNode(nodo(SCNBox(width: t + 0.04, height: 0.05, length: vz1 - vz0 + 0.05, chamferRadius: 0), marco, y: yy, x: x, z: (vz0 + vz1) / 2)) }
            e.addChildNode(nodo(SCNBox(width: t + 0.18, height: 0.05, length: vz1 - vz0 + 0.2, chamferRadius: 0.01), marco, y: vy0 - 0.03, x: x, z: (vz0 + vz1) / 2))
            e.addChildNode(nodo(SCNBox(width: tramo, height: H, length: t, chamferRadius: 0), muro, y: H / 2, x: s * (puertaW / 2 + tramo / 2), z: D / 2))
        }
        e.addChildNode(nodo(SCNBox(width: puertaW, height: H - 2.1, length: t, chamferRadius: 0), muro, y: (H + 2.1) / 2, z: D / 2))
        // Marco de la puerta y hoja de madera abierta hacia adentro, con manilla
        for sx: CGFloat in [-1, 1] { e.addChildNode(nodo(SCNBox(width: 0.07, height: 2.1, length: t + 0.04, chamferRadius: 0), marco, y: 1.05, x: sx * (puertaW / 2 - 0.035), z: D / 2)) }
        e.addChildNode(nodo(SCNBox(width: puertaW, height: 0.07, length: t + 0.04, chamferRadius: 0), marco, y: 2.1, z: D / 2))
        // Abierta del todo (180°): la hoja queda apoyada contra la cara interior del muro, a la izquierda del vano.
        // Va directo en «e» (sin nodo bisagra): flattenedClone no respeta la transformación de nodos anidados y la dejaba al centro.
        let hojaX = -puertaW / 2 + 0.07 - (puertaW - 0.14) / 2, hojaZ = D / 2 - t / 2 - 0.03
        e.addChildNode(nodo(SCNBox(width: puertaW - 0.14, height: 2.02, length: 0.045, chamferRadius: 0.01), Mat.textura(.madera, repetir: 1, tinte: "#7a5634"), y: 1.02, x: hojaX, z: hojaZ))
        e.addChildNode(nodo(SCNSphere(radius: 0.035), Mat.pbr(NSColor(Color(hex: "#c9a13b")), rugosidad: 0.3, metal: 0.9), y: 1.0, x: hojaX - (puertaW - 0.14) / 2 + 0.11, z: hojaZ - 0.04))
        let remate = Mat.pbr(NSColor(Color(hex: asesoria ? "#f7f2e6" : (zona?.roof ?? "#555555"))), rugosidad: 0.5)
        if asesoria {   // anexo del palacio: zócalo de mármol, columnas en la puerta, frontón, placa y lucernario de vidrio
            let blanco = Mat.pbr(NSColor(Color(hex: "#f7f2e6")), rugosidad: 0.55)
            e.addChildNode(nodo(SCNBox(width: W + 0.5, height: 0.3, length: D + 0.5, chamferRadius: 0.02), Mat.textura(.marmol, repetir: 2), y: -0.1))
            for sx: CGFloat in [-1, 1] {
                e.addChildNode(nodo(SCNCylinder(radius: 0.14, height: H), Mat.textura(.marmol, repetir: 1), y: H / 2, x: sx * (puertaW / 2 + 0.3), z: D / 2 + 0.35))
            }
            let tri = NSBezierPath(); tri.move(to: NSPoint(x: -1.15, y: 0)); tri.line(to: NSPoint(x: 1.15, y: 0)); tri.line(to: NSPoint(x: 0, y: 0.55)); tri.close()
            e.addChildNode(nodo(SCNShape(path: tri, extrusionDepth: 0.5), blanco, y: H + 0.1, z: D / 2 + 0.2))
            e.addChildNode(nodo(SCNBox(width: puertaW + 1.0, height: 0.2, length: 0.6, chamferRadius: 0), blanco, y: H + 0.02, z: D / 2 + 0.2))
            let placa = SCNMaterial(); placa.diffuse.contents = Pizarra.placa("ASESORÍA DEL GOBIERNO"); placa.lightingModel = .constant
            e.addChildNode(nodo(SCNPlane(width: 0.75, height: 0.32), placa, y: 1.85, x: puertaW / 2 + tramo / 2 + 0.12, z: D / 2 + t / 2 + 0.01))
        }
        for zz in [-D / 2, D / 2] { e.addChildNode(nodo(SCNBox(width: W + 0.16, height: 0.1, length: 0.22, chamferRadius: 0), remate, y: H + 0.05, z: zz)) }
        for s: CGFloat in [-1, 1] { e.addChildNode(nodo(SCNBox(width: 0.22, height: 0.1, length: D, chamferRadius: 0), remate, y: H + 0.05, x: s * W / 2)) }
        // Escritorio, silla, estante y planta
        let madera = Mat.textura(.madera, repetir: 1, tinte: "#6b4f35")
        let negro = Mat.pbr(NSColor(calibratedWhite: 0.15, alpha: 1))
        e.addChildNode(nodo(SCNBox(width: 1.6, height: 0.07, length: 0.75, chamferRadius: 0.02), madera, y: 0.76, z: -0.85))
        for (x, z) in [(-0.74, -1.15), (0.74, -1.15), (-0.74, -0.55), (0.74, -0.55)] {
            e.addChildNode(nodo(SCNBox(width: 0.05, height: 0.74, length: 0.05, chamferRadius: 0), madera, y: 0.37, x: x, z: z))
        }
        e.addChildNode(nodo(SCNBox(width: 0.5, height: 0.06, length: 0.5, chamferRadius: 0.05), negro, y: 0.5, z: 0.15))
        e.addChildNode(nodo(SCNBox(width: 0.5, height: 0.5, length: 0.06, chamferRadius: 0.03), negro, y: 0.78, z: 0.4))
        e.addChildNode(nodo(SCNBox(width: 0.9, height: 1.8, length: 0.35, chamferRadius: 0.02), madera, y: 0.9, x: -1.25, z: -1.45))
        e.addChildNode(nodo(SCNCylinder(radius: 0.18, height: 0.35), Mat.pbr(NSColor(Color(hex: "#a0522d"))), y: 0.18, x: 1.4, z: -1.35))
        e.addChildNode(nodo(SCNSphere(radius: 0.35), Mat.pbr(NSColor(Color(hex: "#3f7f3a")), rugosidad: 0.9), y: 0.65, x: 1.4, z: -1.35))
        e.addChildNode(nodo(SCNCylinder(radius: 0.035, height: 0.75), Mat.pbr(NSColor(calibratedWhite: 0.2, alpha: 1), metal: 0.7), y: 0.37, x: -1.25, z: D / 2 + 0.45))
        // Detalles exteriores: zócalo, escalón de entrada, aplique junto a la puerta y equipo de aire acondicionado
        e.addChildNode(nodo(SCNBox(width: W, height: 0.18, length: 0.03, chamferRadius: 0), remate, y: 0.09, z: -D / 2 - 0.07))
        for sx: CGFloat in [-1, 1] { e.addChildNode(nodo(SCNBox(width: tramo, height: 0.18, length: 0.03, chamferRadius: 0), remate, y: 0.09, x: sx * (puertaW / 2 + tramo / 2), z: D / 2 + 0.07)) }
        for sx: CGFloat in [-1, 1] { e.addChildNode(nodo(SCNBox(width: 0.03, height: 0.18, length: D, chamferRadius: 0), remate, y: 0.09, x: sx * (W / 2 + 0.07))) }
        e.addChildNode(nodo(SCNBox(width: puertaW + 0.3, height: 0.08, length: 0.4, chamferRadius: 0.01), marco, y: 0.04, z: D / 2 + 0.22))
        e.addChildNode(nodo(SCNBox(width: 0.14, height: 0.22, length: 0.1, chamferRadius: 0.03), Mat.emisivo(NSColor(calibratedRed: 1, green: 0.88, blue: 0.6, alpha: 1), fuerza: 0.6), y: 1.95, x: puertaW / 2 + 0.25, z: D / 2 + 0.11))
        e.addChildNode(nodo(SCNBox(width: 0.75, height: 0.5, length: 0.3, chamferRadius: 0.03), marco, y: 1.9, x: 0.2, z: -D / 2 - 0.22))
        e.addChildNode(nodo(SCNCylinder(radius: 0.17, height: 0.02), negro, y: 1.9, x: 0.2, z: -D / 2 - 0.38))
        // Escritorio: teclado, taza y lámpara
        e.addChildNode(nodo(SCNBox(width: 0.45, height: 0.02, length: 0.15, chamferRadius: 0.01), negro, y: 0.805, z: -0.68))
        e.addChildNode(nodo(SCNCylinder(radius: 0.04, height: 0.1), marco, y: 0.85, x: 0.5, z: -0.7))
        e.addChildNode(nodo(SCNCylinder(radius: 0.015, height: 0.4), negro, y: 1.0, x: -0.6, z: -1.05))
        e.addChildNode(nodo(SCNCone(topRadius: 0.05, bottomRadius: 0.12, height: 0.12), negro, y: 1.22, x: -0.6, z: -1.0))
        let plano = e.flattenedClone(); plano.name = raiz.name
        raiz.addChildNode(plano)
        if asesoria {   // lucernario: techo de vidrio translúcido, deja ver el interior
            let vidrio = Mat.pbr(NSColor(Color(hex: "#bfe3f5")), rugosidad: 0.05, metal: 0.2); vidrio.transparency = 0.22; vidrio.writesToDepthBuffer = false
            raiz.addChildNode(nodo(SCNBox(width: W + 0.1, height: 0.05, length: D + 0.1, chamferRadius: 0), vidrio, y: H + 0.12))
        }
        // Cielo raso blanco con luminaria y luz propia (oculto salvo con la cámara adentro)
        let cielo = Mat.pbr(NSColor(calibratedWhite: 0.95, alpha: 1), rugosidad: 0.9); cielo.isDoubleSided = true
        let losa = nodo(SCNBox(width: W, height: 0.06, length: D, chamferRadius: 0), cielo, y: H); losa.castsShadow = false
        techo.addChildNode(losa)
        techo.addChildNode(nodo(SCNBox(width: 1.1, height: 0.04, length: 0.35, chamferRadius: 0.02), Mat.emisivo(NSColor(calibratedRed: 1, green: 0.97, blue: 0.9, alpha: 1), fuerza: 1.5), y: H - 0.04, z: -0.4))
        let foco = SCNNode(); foco.light = SCNLight(); foco.light!.type = .omni; foco.light!.intensity = 160
        foco.light!.attenuationStartDistance = 1; foco.light!.attenuationEndDistance = 5; foco.position = SCNVector3(0, H - 0.3, -0.3)
        techo.addChildNode(foco)
        techo.isHidden = true
        raiz.addChildNode(techo)
        // Pantalla del color de su estado (se actualiza)
        raiz.addChildNode(nodo(SCNBox(width: 0.62, height: 0.4, length: 0.04, chamferRadius: 0.02), pantalla, y: 1.05, z: -1.05))
        // Pizarra afuera, junto a la puerta, con nombre, estado y horarios
        pizarra.lightingModel = .constant; pizarra.isDoubleSided = true
        let pz = nodo(SCNPlane(width: 1.22, height: 0.83), pizarra, y: 1.17, x: -1.25, z: D / 2 + 0.45)   // paralela a la fachada, junto a la puerta
        raiz.addChildNode(pz)

        // Grilla: muros (con hueco de puerta), escritorio, estante, planta y pizarra
        let m0 = mundo(0, -D / 2); nav.rect(m0.x, m0.y, W / 2, t / 2, yaw)
        let ac = mundo(0.2, -D / 2 - 0.22); nav.rect(ac.x, ac.y, 0.4, 0.17, yaw)      // equipo de aire acondicionado
        for s: CGFloat in [-1, 1] {
            let ml = mundo(s * W / 2, 0); nav.rect(ml.x, ml.y, t / 2, D / 2, yaw)
            let mf = mundo(s * (puertaW / 2 + tramo / 2), D / 2 - 0.04); nav.rect(mf.x, mf.y, tramo / 2, t / 2 + 0.06, yaw)   // muro + hoja de la puerta
        }
        let md = mundo(0, -0.85); nav.rect(md.x, md.y, 0.8, 0.38, yaw, margen: 0.2)
        let me = mundo(-1.25, -1.45); nav.rect(me.x, me.y, 0.45, 0.18, yaw, margen: 0.2)
        let mp = mundo(1.4, -1.35); nav.circulo(mp.x, mp.y, 0.2)
        let mb = mundo(-1.25, D / 2 + 0.45); nav.rect(mb.x, mb.y, 0.6, 0.05, yaw)
        silla = mundo(0, 0.05)
        puerta = mundo(0, D / 2 + 1.1)
        mirarEscritorio = yaw + .pi
        actualizar(a)
    }

    private var firma = ""
    func actualizar(_ a: Agente) {
        let f = a.estado + a.ultima + a.proxima
        guard f != firma else { return }
        firma = f
        pantalla.diffuse.contents = NSColor.black
        pantalla.emission.contents = NSColor(a.color); pantalla.emission.intensity = 1.2
        pizarra.diffuse.contents = Pizarra.imagen(a)
    }
}

enum Pizarra {
    /// Bandera de Chile para el palacio.
    @MainActor
    static func bandera() -> NSImage {
        NSImage(size: NSSize(width: 300, height: 200), flipped: true) { r in
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 300, height: 100).fill()
            NSColor(calibratedRed: 0.84, green: 0.09, blue: 0.16, alpha: 1).setFill(); NSRect(x: 0, y: 100, width: 300, height: 100).fill()
            NSColor(calibratedRed: 0.0, green: 0.22, blue: 0.65, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 100, height: 100).fill()
            let e = NSBezierPath(), c = NSPoint(x: 50, y: 50)
            for k in 0..<10 {
                let rad: CGFloat = k % 2 == 0 ? 28 : 11, a = -CGFloat.pi / 2 + CGFloat(k) * .pi / 5
                let pt = NSPoint(x: c.x + cos(a) * rad, y: c.y + sin(a) * rad)
                k == 0 ? e.move(to: pt) : e.line(to: pt)
            }
            e.close(); NSColor.white.setFill(); e.fill()
            return true
        }
    }

    /// Placa dorada con texto (anexo de Asesoría).
    @MainActor
    static func placa(_ texto: String) -> NSImage {
        NSImage(size: NSSize(width: 400, height: 170), flipped: false) { r in
            NSColor(calibratedRed: 0.72, green: 0.56, blue: 0.2, alpha: 1).setFill(); NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12).fill()
            NSColor(calibratedRed: 0.25, green: 0.18, blue: 0.05, alpha: 1).setStroke()
            let b = NSBezierPath(roundedRect: r.insetBy(dx: 8, dy: 8), xRadius: 8, yRadius: 8); b.lineWidth = 4; b.stroke()
            let at: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Times New Roman Bold", size: 40) ?? NSFont.boldSystemFont(ofSize: 40), .foregroundColor: NSColor(calibratedRed: 0.2, green: 0.13, blue: 0.03, alpha: 1)]
            let lineas = texto.split(separator: " ", maxSplits: 1).map(String.init)
            for (k, l) in lineas.enumerated() {
                let t = (l as NSString).size(withAttributes: at)
                (l as NSString).draw(at: NSPoint(x: (r.width - t.width) / 2, y: r.height - 30 - CGFloat(k + 1) * 50), withAttributes: at)
            }
            return true
        }
    }

    /// Letrero rojo con texto blanco (p. ej. «URGENCIAS»).
    @MainActor
    static func letrero(_ texto: String, ancho: CGFloat = 620) -> NSImage {
        NSImage(size: NSSize(width: ancho, height: 100), flipped: false) { r in
            NSColor(calibratedRed: 0.78, green: 0.08, blue: 0.12, alpha: 1).setFill(); NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill()
            var tam: CGFloat = 64
            var at: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: tam, weight: .heavy), .foregroundColor: NSColor.white]
            var t = (texto as NSString).size(withAttributes: at)
            while t.width > r.width - 40 && tam > 20 {          // el texto nunca se corta: se achica hasta caber
                tam -= 2; at[.font] = NSFont.systemFont(ofSize: tam, weight: .heavy); t = (texto as NSString).size(withAttributes: at)
            }
            (texto as NSString).draw(at: NSPoint(x: (r.width - t.width) / 2, y: (r.height - t.height) / 2), withAttributes: at)
            return true
        }
    }

    /// Pantalla de fachada: «EN ESTE EDIFICIO TRABAJAN», nombre del barrio y cada agente con su estado en color.
    @MainActor
    static func directorio(_ barrio: String, _ agentes: [Agente]) -> NSImage {
        NSImage(size: NSSize(width: 1000, height: 620), flipped: true) { r in
            NSColor(calibratedRed: 0.05, green: 0.08, blue: 0.14, alpha: 1).setFill()
            NSBezierPath(roundedRect: r, xRadius: 26, yRadius: 26).fill()
            NSColor(calibratedWhite: 1, alpha: 0.12).setStroke()
            let borde = NSBezierPath(roundedRect: r.insetBy(dx: 8, dy: 8), xRadius: 20, yRadius: 20); borde.lineWidth = 4; borde.stroke()
            let gris: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: NSColor(calibratedWhite: 0.7, alpha: 1), .kern: 3]
            ("EN ESTE EDIFICIO TRABAJAN" as NSString).draw(at: NSPoint(x: 44, y: 34), withAttributes: gris)
            let titulo: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 54, weight: .bold), .foregroundColor: NSColor.white]
            (barrio as NSString).draw(at: NSPoint(x: 44, y: 76), withAttributes: titulo)
            let dos = agentes.count > 6, filas = dos ? (agentes.count + 1) / 2 : max(1, agentes.count)
            let alto = min(70, 440 / CGFloat(filas)), tam = min(34, alto * 0.52)
            for (i, a) in agentes.enumerated() {
                let col = dos ? i / filas : 0, fila = dos ? i % filas : i
                let x: CGFloat = 44 + CGFloat(col) * 470, y: CGFloat = 165 + CGFloat(fila) * alto
                let c = NSColor(a.color)
                c.setFill(); NSBezierPath(ovalIn: NSRect(x: x, y: y + alto * 0.18, width: tam * 0.8, height: tam * 0.8)).fill()
                let nombre: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: tam, weight: .medium), .foregroundColor: NSColor.white]
                let est: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: tam * 0.7, weight: .semibold), .foregroundColor: c]
                var n = a.nombre
                let maxAncho: CGFloat = dos ? 300 : 620
                while (n as NSString).size(withAttributes: nombre).width > maxAncho && n.count > 4 { n = String(n.dropLast(2)) + "…" }
                (n as NSString).draw(at: NSPoint(x: x + tam * 1.15, y: y), withAttributes: nombre)
                let e = a.etiquetaEstado as NSString
                e.draw(at: NSPoint(x: x + (dos ? 455 : 912) - e.size(withAttributes: est).width, y: y + tam * 0.22), withAttributes: est)
            }
            return true
        }
    }

    @MainActor
    static func imagen(_ a: Agente) -> NSImage {
        NSImage(size: NSSize(width: 680, height: 460), flipped: true) { r in
            NSColor(calibratedRed: 0.07, green: 0.1, blue: 0.13, alpha: 1).setFill(); NSBezierPath(roundedRect: r, xRadius: 18, yRadius: 18).fill()
            NSColor(calibratedRed: 0.55, green: 0.42, blue: 0.25, alpha: 1).setStroke()
            let borde = NSBezierPath(roundedRect: r.insetBy(dx: 5, dy: 5), xRadius: 16, yRadius: 16); borde.lineWidth = 10; borde.stroke()
            let t = { (s: String, f: NSFont, c: NSColor, y: CGFloat, alto: CGFloat) in
                (s as NSString).draw(in: NSRect(x: 34, y: y, width: 612, height: alto), withAttributes: [.font: f, .foregroundColor: c])
            }
            let c = NSColor(a.color)
            t(a.nombre, .systemFont(ofSize: 44, weight: .bold), .white, 26, 56)
            c.setFill(); NSBezierPath(ovalIn: NSRect(x: 36, y: 98, width: 20, height: 20)).fill()
            (a.etiquetaEstado.uppercased() as NSString).draw(at: NSPoint(x: 66, y: 92), withAttributes: [.font: NSFont.systemFont(ofSize: 26, weight: .semibold), .foregroundColor: c])
            t(String(a.def.does.prefix(170)) + (a.def.does.count > 170 ? "…" : ""), .systemFont(ofSize: 25), NSColor(calibratedWhite: 0.85, alpha: 1), 136, 210)
            t("Última  \(a.ultima)", .monospacedSystemFont(ofSize: 22, weight: .regular), NSColor(calibratedWhite: 0.65, alpha: 1), 360, 30)
            t("Próxima \(a.proxima)", .monospacedSystemFont(ofSize: 22, weight: .regular), NSColor(calibratedWhite: 0.65, alpha: 1), 394, 30)
            return true
        }
    }
}

// MARK: - Persona: personaje distinto por agente, que camina con física

@MainActor
final class Persona {
    let raiz = SCNNode()
    private let cuerpo = SCNNode()
    private var piernas: [SCNNode] = [], brazos: [SCNNode] = []
    private let anillo = SCNNode(geometry: SCNTorus(ringRadius: 0.55, pipeRadius: 0.05))
    private let insignia = SCNNode(geometry: SCNSphere(radius: 0.07))
    private let alerta: SCNNode
    private var cartel = SCNNode()
    private weak var oficina: Oficina?
    private var centroZona: CGPoint, radioZona: CGFloat
    private var origen: (o: Oficina, c: CGPoint, r: CGFloat)?, alterna: (o: Oficina, c: CGPoint, r: CGFloat)?
    private(set) var enAlterna = false
    private var azar: Azar
    var pos = CGPoint.zero
    var alturaActual: CGFloat = 0
    private var yaw: CGFloat = 0
    private var ruta: [CGPoint] = []
    private var meta: Meta = .escritorio
    private var esperarHasta: CFTimeInterval = 0
    private var fase: CGFloat = 0
    private var estado = ""
    var llamado = false
    var replanear = false
    private let velocidad: CGFloat
    private var mats: (ropa: SCNMaterial, piel: SCNMaterial, pelo: SCNMaterial)?
    private var fusionado = false

    /// Realismo sin costo: agrega orejas, cejas, boca, cuello de camisa y cinturón, y fusiona todas las piezas fijas
    /// del cuerpo (cabeza, torso, pelo, accesorios) en un solo objeto. Piernas y brazos siguen sueltos para animarse.
    /// Sombras: solo el cuerpo fusionado y las piernas (los brazos y detalles no la necesitan).
    func fusionar() {
        guard !fusionado else { return }
        fusionado = true
        if let m = mats {
            let oscuro = Mat.pbr(NSColor(calibratedWhite: 0.1, alpha: 1), rugosidad: 0.45)
            for x: CGFloat in [-0.215, 0.215] { cuerpo.addChildNode(nodo(SCNSphere(radius: 0.05), m.piel, y: 1.77, x: x)) }
            for x: CGFloat in [-0.08, 0.08] { cuerpo.addChildNode(nodo(SCNBox(width: 0.08, height: 0.018, length: 0.02, chamferRadius: 0.008), m.pelo, y: 1.865, x: x, z: 0.2)) }
            cuerpo.addChildNode(nodo(SCNBox(width: 0.09, height: 0.02, length: 0.02, chamferRadius: 0.008), Mat.pbr(NSColor(Color(hex: "#8a3b3b"))), y: 1.685, z: 0.205))
            let cuello = nodo(SCNTorus(ringRadius: 0.11, pipeRadius: 0.035), m.ropa, y: 1.5); cuerpo.addChildNode(cuello)
            cuerpo.addChildNode(nodo(SCNCylinder(radius: 0.255, height: 0.06), oscuro, y: 0.82))
            cuerpo.addChildNode(nodo(SCNBox(width: 0.08, height: 0.06, length: 0.02, chamferRadius: 0.01), Mat.pbr(NSColor(Color(hex: "#c9a13b")), rugosidad: 0.3, metal: 0.9), y: 0.82, z: 0.255))
        }
        let fijos = cuerpo.childNodes.filter { n in
            n.geometry != nil && n.childNodes.isEmpty && n.actionKeys.isEmpty && (n.constraints ?? []).isEmpty && !n.isHidden && n !== insignia
        }
        raiz.enumerateHierarchy { n, _ in n.castsShadow = false }
        if fijos.count > 1 {
            let g = SCNNode()
            for n in fijos { n.removeFromParentNode(); g.addChildNode(n) }
            let plano = g.flattenedClone(); plano.castsShadow = true
            cuerpo.addChildNode(plano)
        }
        for pierna in piernas { pierna.enumerateHierarchy { n, _ in n.castsShadow = true } }
    }

    enum Meta { case escritorio, plaza, sede, audiencia, puerta }

    static func ceo() -> Persona {
        let p = Persona(vacio: ())
        p.armar(piel: "#e4b894", ropa: NSColor.white, pantalon: "#2a3140", pelo: "corto", peloC: "#8c8c8c", acc: "urg", escala: 1.05)
        p.insignia.isHidden = true
        p.cuerpo.addChildNode(nodo(SCNBox(width: 0.28, height: 0.36, length: 0.02, chamferRadius: 0.01), Mat.pbr(NSColor(Color(hex: "#6b4f35"))), y: 1.1, x: 0.36, z: 0.2))
        p.raiz.addChildNode(etiqueta("Alcalde", y: 2.45, grande: false))
        p.fusionar(); return p
    }

    /// Guardia de la sede: uniforme verde oliva, gorra, cinturón y fusil.
    static func guardia() -> Persona {
        let p = Persona(vacio: ())
        p.armar(piel: "#c99a74", ropa: NSColor(Color(hex: "#4b5a33")), pantalon: "#3d4a2a", pelo: "gorra", peloC: "#2f3a1f", acc: "guardia", escala: 1.0)
        p.insignia.isHidden = true
        let negro = Mat.pbr(NSColor(calibratedWhite: 0.08, alpha: 1), rugosidad: 0.4, metal: 0.5)
        let fusil = nodo(SCNBox(width: 0.06, height: 0.85, length: 0.08, chamferRadius: 0.01), negro, y: 1.15, x: 0.3, z: 0.2)
        fusil.eulerAngles.z = 0.25
        p.cuerpo.addChildNode(fusil)
        p.cuerpo.addChildNode(nodo(SCNCylinder(radius: 0.29, height: 0.07), negro, y: 0.86))
        p.fusionar(); return p
    }

    /// Bombero: chaquetón ocre con franjas reflectantes y casco rojo.
    static func bombero() -> Persona {
        let p = Persona(vacio: ())
        p.armar(piel: "#d9ab84", ropa: NSColor(Color(hex: "#c9a227")), pantalon: "#2b2f3a", pelo: "corto", peloC: "#2a1d14", acc: "guardia", escala: 1.0)
        p.insignia.isHidden = true
        let franja = Mat.emisivo(NSColor(calibratedRed: 0.85, green: 0.95, blue: 0.85, alpha: 1), fuerza: 0.4)
        for y: CGFloat in [1.05, 1.3] { p.cuerpo.addChildNode(nodo(SCNCylinder(radius: 0.3, height: 0.05), franja, y: y)) }
        p.cuerpo.addChildNode(nodo(SCNSphere(radius: 0.27), Mat.pbr(NSColor(Color(hex: "#c62a1f")), rugosidad: 0.25, metal: 0.2), y: 1.86, z: -0.02))
        p.cuerpo.addChildNode(nodo(SCNCylinder(radius: 0.34, height: 0.04), Mat.pbr(NSColor(Color(hex: "#c62a1f")), rugosidad: 0.25), y: 1.78, z: -0.05))
        p.fusionar(); return p
    }

    /// Carabinero de tránsito: uniforme verde, gorra, cinturón y guantes blancos.
    static func carabinero() -> Persona {
        let p = Persona(vacio: ())
        p.armar(piel: "#d9ab84", ropa: NSColor(Color(hex: "#2f5d3a")), pantalon: "#2f5d3a", pelo: "gorra", peloC: "#2f5d3a", acc: "guardia", escala: 1.0)
        p.insignia.isHidden = true
        let blanco = Mat.pbr(.white, rugosidad: 0.5)
        p.cuerpo.addChildNode(nodo(SCNCylinder(radius: 0.29, height: 0.07), blanco, y: 0.86))
        for b in p.brazos { b.addChildNode(nodo(SCNSphere(radius: 0.085), blanco, y: -0.62)) }
        p.fusionar(); return p
    }

    /// Pasajero del metro: ropa, piel y peinado variados según su número.
    static func pasajero(_ k: Int) -> Persona {
        let p = Persona(vacio: ())
        let h = UInt32(truncatingIfNeeded: k &* 2654435761 &+ 97)
        func pick<T>(_ l: [T], _ s: UInt32) -> T { l[Int((h >> s) % UInt32(l.count))] }
        let ropa = NSColor(hue: CGFloat(Double(k) * 0.381966).truncatingRemainder(dividingBy: 1), saturation: 0.35 + CGFloat(h % 40) / 100, brightness: 0.45 + CGFloat((h >> 4) % 45) / 100, alpha: 1)
        p.armar(piel: pick(["#f1c9a5", "#e4b894", "#c99a72", "#a8754f", "#8a5a3b", "#f5d6c0"], 0), ropa: ropa,
                pantalon: pick(["#27303d", "#3b3f46", "#2f4a3a", "#4a3b2f", "#1f2a44", "#5a5f66", "#6b5a45"], 3),
                pelo: pick(["corto", "largo", "moño", "rizado", "gorra", "corto", "largo"], 6),
                peloC: pick(["#1d1611", "#3b2a1e", "#6b4a2f", "#a0703f", "#d9b26a", "#8c8c8c"], 9), acc: "", escala: 0.92 + CGFloat((h >> 12) % 14) / 100)
        p.insignia.isHidden = true
        p.fusionar(); return p
    }

    /// Mecánico de las cocheras: overol naranjo con franjas reflectantes y casco blanco.
    static func mecanico() -> Persona {
        let p = Persona(vacio: ())
        p.armar(piel: "#d9ab84", ropa: NSColor(Color(hex: "#e0702a")), pantalon: "#c9601f", pelo: "corto", peloC: "#2a1d14", acc: "", escala: 1.0)
        p.insignia.isHidden = true
        let franja = Mat.emisivo(NSColor(calibratedRed: 0.85, green: 0.95, blue: 0.85, alpha: 1), fuerza: 0.4)
        for y: CGFloat in [1.0, 1.28] { p.cuerpo.addChildNode(nodo(SCNCylinder(radius: 0.29, height: 0.05), franja, y: y)) }
        p.cuerpo.addChildNode(nodo(SCNSphere(radius: 0.26), Mat.pbr(.white, rugosidad: 0.3), y: 1.87, z: -0.02))
        p.fusionar(); return p
    }

    /// Quieto: piernas y brazos rectos.
    func detener() {
        for n in piernas + brazos { n.eulerAngles.x = 0 }
    }

    /// Un brazo extendido detiene y el otro hace pasar.
    func dirigir(_ t: CFTimeInterval) {
        let s = CGFloat(sin(t * 1.6))
        brazos[0].eulerAngles = SCNVector3(0, 0, -1.5 + s * 0.12)
        brazos[1].eulerAngles = SCNVector3(-1.1 - s * 0.5, 0, 0.25)
    }

    /// Busto animado para las ventanas emergentes: el personaje de cada rol habla (boca y gestos) con su vestimenta.
    static func retrato(_ tipo: String, agente a: Agente?) -> (SCNScene, SCNNode) {
        let p: Persona
        var fondo = NSColor(calibratedRed: 0.55, green: 0.7, blue: 0.85, alpha: 1)
        let oscuro = Mat.pbr(NSColor(calibratedWhite: 0.08, alpha: 1), rugosidad: 0.3, metal: 0.5)
        switch tipo {
        case "guardiaPalacio", "guardiaPlaza", "guardiaGarita", "garita", "patrulla":
            p = guardia(); fondo = NSColor(calibratedRed: 0.6, green: 0.66, blue: 0.5, alpha: 1)
        case "carabinero", "moto":
            p = carabinero(); fondo = NSColor(calibratedRed: 0.62, green: 0.75, blue: 0.62, alpha: 1)
            if tipo == "moto" { p.cuerpo.addChildNode(nodo(SCNSphere(radius: 0.27), Mat.pbr(.white, rugosidad: 0.2, metal: 0.3), y: 1.84)) }
        case "helicoptero", "cazas":
            p = Persona(vacio: ())
            p.armar(piel: "#d6a77f", ropa: NSColor(Color(hex: tipo == "cazas" ? "#6d7680" : "#556043")), pantalon: "#3d4a2a", pelo: "corto", peloC: "#2a1d14", acc: "guardia", escala: 1)
            let casco = Mat.pbr(NSColor(Color(hex: tipo == "cazas" ? "#c9ccd0" : "#4b5a33")), rugosidad: 0.35, metal: 0.3)
            p.cuerpo.addChildNode(nodo(SCNSphere(radius: 0.27), casco, y: 1.86, z: -0.02))
            p.cuerpo.addChildNode(nodo(SCNBox(width: 0.38, height: 0.1, length: 0.08, chamferRadius: 0.04), oscuro, y: 1.95, z: 0.2))   // visera levantada
            let mic = nodo(SCNCylinder(radius: 0.015, height: 0.22), oscuro, y: 1.7, x: 0.15, z: 0.17); mic.eulerAngles.z = 1.2
            p.cuerpo.addChildNode(mic)
            fondo = NSColor(calibratedRed: 0.45, green: 0.66, blue: 0.9, alpha: 1)
        case "bomberos":
            p = bombero(); fondo = NSColor(calibratedRed: 0.95, green: 0.8, blue: 0.7, alpha: 1)
        case "ambulancia":
            p = Persona(vacio: ())
            p.armar(piel: "#e2b48c", ropa: NSColor(Color(hex: "#d9472b")), pantalon: "#1f2a44", pelo: "corto", peloC: "#3b2a1e", acc: "urg", escala: 1)
            fondo = NSColor(calibratedRed: 0.93, green: 0.85, blue: 0.82, alpha: 1)
        case "caravana":
            p = Persona(vacio: ())
            p.armar(piel: "#c99a72", ropa: NSColor(calibratedWhite: 0.08, alpha: 1), pantalon: "#111111", pelo: "corto", peloC: "#1d1611", acc: "guardia", escala: 1)
            p.cuerpo.addChildNode(nodo(SCNBox(width: 0.34, height: 0.07, length: 0.04, chamferRadius: 0.02), oscuro, y: 1.82, z: 0.21))   // lentes oscuros
            p.cuerpo.addChildNode(nodo(SCNBox(width: 0.1, height: 0.3, length: 0.02, chamferRadius: 0), Mat.pbr(.white), y: 1.32, z: 0.27))
            fondo = NSColor(calibratedWhite: 0.7, alpha: 1)
        case _ where tipo.hasPrefix("metro"):
            p = Persona(vacio: ())
            p.armar(piel: "#e4b894", ropa: NSColor(Color(hex: "#d1302b")), pantalon: "#1f2a44", pelo: "gorra", peloC: "#1f2a44", acc: "guardia", escala: 1)
            fondo = NSColor(calibratedRed: 0.95, green: 0.82, blue: 0.8, alpha: 1)
        case "intruso":
            p = Persona(vacio: ())
            p.armar(piel: "#f1c9a5", ropa: NSColor(Color(hex: "#00a88e")), pantalon: "#27303d", pelo: "moño", peloC: "#3b2a1e", acc: "cer", escala: 1)
            fondo = NSColor(calibratedRed: 0.95, green: 0.75, blue: 0.75, alpha: 1)
        case "agente":
            p = Persona(vacio: ())
            if let a = a {
                let h = a.id.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31 &+ $1.value) }
                func pick<T>(_ l: [T], _ k: UInt32) -> T { l[Int((h >> k) % UInt32(l.count))] }
                let ropa = NSColor(hue: CGFloat((Double(a.indice) * 0.381966).truncatingRemainder(dividingBy: 1)), saturation: 0.6, brightness: 0.75, alpha: 1)
                p.armar(piel: pick(["#f1c9a5", "#e4b894", "#c99a72", "#a8754f", "#8a5a3b", "#f5d6c0"], 0), ropa: ropa, pantalon: "#27303d",
                        pelo: mujeres.contains(a.id) ? pick(["largo", "moño", "largo", "rizado"], 6) : pick(["corto", "rizado", "gorra", "corto", "corto"], 6),
                        peloC: pick(["#1d1611", "#3b2a1e", "#6b4a2f", "#a0703f", "#d9b26a", "#8c8c8c", "#b5452e"], 9), acc: a.zona, escala: 1)
                fondo = NSColor(Agente.color(a.estado)).blended(withFraction: 0.65, of: .white) ?? fondo
            }
        case _ where tipo.hasPrefix("flota"):          // oficial de marina: uniforme blanco y gorra
            p = Persona(vacio: ())
            p.armar(piel: "#d9a77f", ropa: NSColor(calibratedWhite: 0.96, alpha: 1), pantalon: "#1c2a44", pelo: "corto", peloC: "#2a1d14", acc: "guardia", escala: 1)
            p.cuerpo.addChildNode(nodo(SCNCylinder(radius: 0.25, height: 0.12), Mat.pbr(.white, rugosidad: 0.4), y: 1.97))
            p.cuerpo.addChildNode(nodo(SCNBox(width: 0.34, height: 0.04, length: 0.16, chamferRadius: 0.02), oscuro, y: 1.92, z: 0.2))
            fondo = NSColor(calibratedRed: 0.55, green: 0.68, blue: 0.86, alpha: 1)
        case _ where tipo.hasPrefix("puerto"):         // trabajador portuario: chaleco naranjo y casco
            p = Persona(vacio: ())
            p.armar(piel: "#c99a72", ropa: NSColor(Color(hex: "#e8761e")), pantalon: "#2b3a55", pelo: "corto", peloC: "#3b2a1e", acc: "guardia", escala: 1)
            p.cuerpo.addChildNode(nodo(SCNSphere(radius: 0.27), Mat.pbr(NSColor(Color(hex: "#f2c230")), rugosidad: 0.35), y: 1.88, z: -0.02))
            fondo = NSColor(calibratedRed: 0.6, green: 0.76, blue: 0.9, alpha: 1)
        default:
            p = Persona(vacio: ())
            p.armar(piel: "#e4b894", ropa: NSColor(Color(hex: "#3d6fb6")), pantalon: "#27303d", pelo: "corto", peloC: "#6b4a2f", acc: "guardia", escala: 1)
        }
        p.insignia.isHidden = true
        // Boca que habla y gestos suaves (asiente y gira apenas)
        let boca = nodo(SCNBox(width: 0.1, height: 0.025, length: 0.02, chamferRadius: 0.01), Mat.pbr(NSColor(Color(hex: "#7a2e2e"))), y: 1.685, z: 0.205)
        boca.runAction(.repeatForever(.sequence([.scale(to: 2.6, duration: 0.12), .scale(to: 1, duration: 0.1), .scale(to: 1.8, duration: 0.14), .scale(to: 0.8, duration: 0.12), .wait(duration: 0.15)])))
        p.cuerpo.addChildNode(boca)
        p.cuerpo.runAction(.repeatForever(.sequence([.rotateTo(x: 0.04, y: 0.12, z: 0, duration: 1.4), .rotateTo(x: -0.02, y: -0.1, z: 0, duration: 1.6)])))
        if p.brazos.count == 2 && tipo != "carabinero" {
            p.brazos[1].runAction(.repeatForever(.sequence([.rotateTo(x: -0.9, y: 0, z: 0.3, duration: 0.9), .rotateTo(x: -0.3, y: 0, z: 0.1, duration: 1.1)])))
        } else { p.dirigir(0) }
        let escena = SCNScene()
        escena.background.contents = fondo
        escena.rootNode.addChildNode(p.raiz)
        let cam = SCNNode(); cam.camera = SCNCamera(); cam.camera!.fieldOfView = 34
        cam.position = SCNVector3(0, 1.7, 1.45); cam.look(at: SCNVector3(0, 1.6, 0))
        escena.rootNode.addChildNode(cam)
        let luz = SCNNode(); luz.light = SCNLight(); luz.light!.type = .directional; luz.light!.intensity = 900
        luz.eulerAngles = SCNVector3(-0.5, 0.5, 0); escena.rootNode.addChildNode(luz)
        let amb = SCNNode(); amb.light = SCNLight(); amb.light!.type = .ambient; amb.light!.intensity = 450
        escena.rootNode.addChildNode(amb)
        return (escena, cam)
    }

    /// Agentes cuyo rol es femenino (la cronista, la contadora, la archivista…); el resto, masculino.
    static let mujeres: Set<String> = ["agenda", "bitacora", "salud", "asc", "tok", "compilador"]

    /// Paso de marcha para la ronda (sin navegación).
    func marchar(dt: CGFloat) {
        fase += dt * 6
        piernas[0].eulerAngles.x = sin(fase) * 0.5; piernas[1].eulerAngles.x = -sin(fase) * 0.5
        brazos[0].eulerAngles.x = -sin(fase) * 0.4
    }

    private init(vacio: ()) {
        centroZona = .zero; radioZona = 0; azar = Azar(semilla: 1); velocidad = 0
        alerta = SCNNode()
        raiz.addChildNode(cuerpo)
    }

    init(agente a: Agente, oficina: Oficina, centroZona: CGPoint, radioZona: CGFloat) {
        self.oficina = oficina; self.centroZona = centroZona; self.radioZona = radioZona
        let h = a.id.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31 &+ $1.value) }
        azar = Azar(semilla: UInt64(h))
        velocidad = 1.15 + CGFloat(h % 40) / 100
        let t = SCNText(string: "!", extrusionDepth: 0.06); t.font = .boldSystemFont(ofSize: 1); t.flatness = 0.1
        alerta = SCNNode(geometry: t); alerta.scale = SCNVector3(0.8, 0.8, 0.8); alerta.position = SCNVector3(-0.15, 2.55, 0)
        alerta.constraints = [SCNBillboardConstraint()]
        // El «!» late: crece y se achica alternando rojo y amarillo, para que se vea de lejos.
        let color = { (c: NSColor) in SCNAction.run { $0.geometry?.firstMaterial?.emission.contents = c; $0.geometry?.firstMaterial?.diffuse.contents = c } }
        alerta.runAction(.repeatForever(.sequence([
            .group([.scale(to: 1.35, duration: 0.45), color(.systemRed)]),
            .group([.scale(to: 0.75, duration: 0.45), color(.systemYellow)])])))
        raiz.name = "agente:\(a.id)"
        raiz.addChildNode(cuerpo)
        func pick<T>(_ l: [T], _ k: UInt32) -> T { l[Int((h >> k) % UInt32(l.count))] }
        let ropa = a.estado == "off" ? NSColor.gray : NSColor(hue: CGFloat((Double(a.indice) * 0.381966).truncatingRemainder(dividingBy: 1)), saturation: 0.6, brightness: 0.75, alpha: 1)
        armar(piel: pick(["#f1c9a5", "#e4b894", "#c99a72", "#a8754f", "#8a5a3b", "#f5d6c0"], 0), ropa: ropa,
              pantalon: pick(["#27303d", "#3b3f46", "#2f4a3a", "#4a3b2f", "#1f2a44", "#5a5f66"], 3),
              pelo: Persona.mujeres.contains(a.id) ? pick(["largo", "moño", "largo", "rizado"], 6) : pick(["corto", "rizado", "gorra", "corto", "corto"], 6),
              peloC: pick(["#1d1611", "#3b2a1e", "#6b4a2f", "#a0703f", "#d9b26a", "#8c8c8c", "#b5452e"], 9),
              acc: a.zona, escala: 0.93 + CGFloat((h >> 12) % 15) / 100)
        if Persona.mujeres.contains(a.id) {   // falda
            cuerpo.addChildNode(nodo(SCNCone(topRadius: 0.25, bottomRadius: 0.36, height: 0.42), Mat.pbr(ropa, rugosidad: 0.75), y: 0.66))
        }
        raiz.addChildNode(anillo); anillo.position.y = 0.04
        raiz.addChildNode(alerta)
        cartel = etiqueta(a.nombre, y: 2.35, grande: false)
        raiz.addChildNode(cartel)
        actualizar(a)
        fusionar()
    }

    private func armar(piel: String, ropa: NSColor, pantalon: String, pelo: String, peloC: String, acc: String, escala: CGFloat) {
        let p = cuerpo
        let mRopa = Mat.pbr(ropa, rugosidad: 0.75), mPiel = Mat.pbr(NSColor(Color(hex: piel)), rugosidad: 0.6)
        let mPant = Mat.pbr(NSColor(Color(hex: pantalon)), rugosidad: 0.8), mPelo = Mat.pbr(NSColor(Color(hex: peloC)), rugosidad: 0.85)
        mats = (mRopa, mPiel, mPelo)
        let oscuro = Mat.pbr(NSColor(calibratedWhite: 0.1, alpha: 1), rugosidad: 0.3)
        for x: CGFloat in [-0.12, 0.12] {
            let cadera = SCNNode(); cadera.position = SCNVector3(x, 0.78, 0)
            cadera.addChildNode(nodo(SCNCapsule(capRadius: 0.1, height: 0.72), mPant, y: -0.36))
            cadera.addChildNode(nodo(SCNBox(width: 0.19, height: 0.1, length: 0.3, chamferRadius: 0.04), oscuro, y: -0.73, z: 0.05))
            p.addChildNode(cadera); piernas.append(cadera)
        }
        p.addChildNode(nodo(SCNCapsule(capRadius: 0.27, height: 0.8), mRopa, y: 1.17))
        p.addChildNode(nodo(SCNCylinder(radius: 0.08, height: 0.12), mPiel, y: 1.56))
        for x: CGFloat in [-0.37, 0.37] {
            let hombro = SCNNode(); hombro.position = SCNVector3(x, 1.43, 0)
            hombro.addChildNode(nodo(SCNCapsule(capRadius: 0.07, height: 0.62), mRopa, y: -0.29))
            hombro.addChildNode(nodo(SCNSphere(radius: 0.075), mPiel, y: -0.62))
            p.addChildNode(hombro); brazos.append(hombro)
        }
        p.addChildNode(nodo(SCNSphere(radius: 0.22), mPiel, y: 1.78))
        p.addChildNode(nodo(SCNSphere(radius: 0.045), mPiel, y: 1.76, z: 0.22))
        for x: CGFloat in [-0.08, 0.08] { p.addChildNode(nodo(SCNSphere(radius: 0.028), oscuro, y: 1.82, x: x, z: 0.195)) }
        switch pelo {
        case "largo": p.addChildNode(media(0.235, mPelo, 1.82)); p.addChildNode(nodo(SCNBox(width: 0.42, height: 0.4, length: 0.12, chamferRadius: 0.05), mPelo, y: 1.62, z: -0.15))
        case "moño": p.addChildNode(media(0.232, mPelo, 1.82)); p.addChildNode(nodo(SCNSphere(radius: 0.1), mPelo, y: 1.98, z: -0.14))
        case "rizado":
            for i in 0..<9 {
                let a = CGFloat(i) / 9 * .pi * 2
                p.addChildNode(nodo(SCNSphere(radius: 0.095), mPelo, y: 1.93 + CGFloat(i % 2) * 0.03, x: cos(a) * 0.15, z: sin(a) * 0.13 - 0.03))
            }
        case "gorra": p.addChildNode(media(0.235, mPelo, 1.84)); p.addChildNode(nodo(SCNBox(width: 0.28, height: 0.025, length: 0.2, chamferRadius: 0.01), mPelo, y: 1.9, z: 0.2))
        default: p.addChildNode(media(0.232, mPelo, 1.82))
        }
        let gris = Mat.pbr(NSColor(calibratedWhite: 0.12, alpha: 1), rugosidad: 0.4)
        switch acc {
        case "urg":       // estetoscopio
            let t = nodo(SCNTorus(ringRadius: 0.17, pipeRadius: 0.015), gris, y: 1.45, z: 0.1); t.eulerAngles.x = 1.15; p.addChildNode(t)
            p.addChildNode(nodo(SCNCylinder(radius: 0.035, height: 0.02), Mat.pbr(NSColor(calibratedWhite: 0.8, alpha: 1), rugosidad: 0.2, metal: 0.9), y: 1.22, x: 0.08, z: 0.27))
        case "cer":       // gafas
            for x: CGFloat in [-0.08, 0.08] { let g = nodo(SCNTorus(ringRadius: 0.05, pipeRadius: 0.011), gris, y: 1.82, x: x, z: 0.215); g.eulerAngles.x = .pi / 2; p.addChildNode(g) }
        case "ios":       // audífonos
            let arco = nodo(SCNTorus(ringRadius: 0.24, pipeRadius: 0.022), gris, y: 1.8); arco.eulerAngles.z = .pi / 2; arco.scale = SCNVector3(1, 1, 0.4); p.addChildNode(arco)
            for x: CGFloat in [-0.23, 0.23] { let o = nodo(SCNCylinder(radius: 0.07, height: 0.06), gris, y: 1.78, x: x); o.eulerAngles.z = .pi / 2; p.addChildNode(o) }
        case "mac":       // casco de obra
            let amarillo = Mat.pbr(NSColor(Color(hex: "#f2c230")), rugosidad: 0.35)
            p.addChildNode(media(0.255, amarillo, 1.85))
            p.addChildNode(nodo(SCNCylinder(radius: 0.3, height: 0.025), amarillo, y: 1.86, z: 0.03))
        case "guardia": break
        default:          // antena
            p.addChildNode(nodo(SCNCylinder(radius: 0.012, height: 0.3), Mat.pbr(NSColor(calibratedWhite: 0.6, alpha: 1), metal: 0.8), y: 2.08, x: 0.17))
            p.addChildNode(nodo(SCNSphere(radius: 0.04), Mat.emisivo(NSColor(calibratedRed: 0.5, green: 0.8, blue: 1, alpha: 1)), y: 2.24, x: 0.17))
        }
        insignia.position = SCNVector3(-0.14, 1.32, 0.26); p.addChildNode(insignia)
        cuerpo.scale = SCNVector3(escala, escala, escala)
    }

    private func media(_ r: CGFloat, _ m: SCNMaterial, _ y: CGFloat) -> SCNNode {
        let n = nodo(SCNSphere(radius: r), m, y: y); n.scale = SCNVector3(1, 0.62, 1); return n
    }

    func colocar(en p: CGPoint, piso: CGFloat) {
        pos = p; alturaActual = piso
        raiz.position = SCNVector3(p.x, piso, p.y)
        if let o = oficina { yaw = o.mirarEscritorio; raiz.eulerAngles.y = yaw }
        esperarHasta = CACurrentMediaTime() + Double(azar.real() * 8)
    }

    /// Segunda oficina (p. ej. en La nube): desde ahora el agente camina entre ambas con irAOficina(alterna:).
    func agregarOficina(_ o: Oficina, centro: CGPoint, radio: CGFloat) {
        if origen == nil, let p = oficina { origen = (p, centroZona, radioZona) }
        alterna = (o, centro, radio)
    }

    func irAOficina(alterna si: Bool) {
        guard si != enAlterna, let dest = si ? alterna : origen else { return }
        enAlterna = si; oficina = dest.o; centroZona = dest.c; radioZona = dest.r
        if !llamado { meta = .plaza; replanear = true }      // al replanear va a la silla de la otra oficina
    }

    func actualizar(_ a: Agente) {
        guard a.estado != estado else { return }
        estado = a.estado
        let c = NSColor(a.color)
        anillo.geometry!.firstMaterial = Mat.emisivo(c, fuerza: 0.8)
        insignia.geometry!.firstMaterial = Mat.emisivo(c, fuerza: 0.8)
        alerta.geometry?.firstMaterial = Mat.emisivo(c, fuerza: 1.2)
        alerta.isHidden = !problema
        raiz.opacity = estado == "off" ? 0.65 : 1
        replanear = true
    }

    var problema: Bool { estado == "warn" || estado == "crit" }

    private var seleccionado = false
    var cartelLejos = true { didSet { if cartelLejos != oldValue { cartel.isHidden = seleccionado || !cartelLejos } } }

    func resaltar(_ si: Bool) {
        seleccionado = si
        cartel.isHidden = si || !cartelLejos    // seleccionado: su nombre ya está en la pizarra y el cartel tapaba la oficina
        SCNTransaction.begin(); SCNTransaction.animationDuration = 0.3
        anillo.scale = si ? SCNVector3(1.7, 1.7, 1.7) : SCNVector3(1, 1, 1)
        SCNTransaction.commit()
    }

    /// Un paso de simulación: decide adónde ir, camina por la ruta A* y anima piernas y brazos.
    func paso(dt: CGFloat, ahora: CFTimeInterval, nav: Navegacion, piso: (CGPoint) -> CGFloat) {
        guard let o = oficina else { return }
        if replanear { replanear = false; ruta = []; esperarHasta = 0 }
        if ruta.isEmpty && ahora >= esperarHasta {
            var destino = pos
            if llamado { meta = .audiencia; destino = Villa3D.Coordinador.audiencia }
            else if problema { meta = .puerta; destino = o.puerta }        // sale a la puerta y saluda para llamar la atención
            else if estado == "off" || meta != .escritorio { meta = .escritorio; destino = o.silla }
            else {
                let x = azar.real()
                if x < 0.6 && radioZona > 1 {   // pasea por la plaza de su barrio; a la sede va solo si lo convocan
                    meta = .plaza
                    let a = azar.real() * .pi * 2, r = 5 + azar.real() * max(0.5, radioZona - 9.5)
                    destino = CGPoint(x: centroZona.x + cos(a) * r, y: centroZona.y + sin(a) * r)
                    if hypot(centroZona.x - Mall.centro.x, centroZona.y - Mall.centro.y) < 1 {   // en el mall: pasea dentro del atrio
                        destino = Mall.polar(Mall.rFrente + 1.2 + azar.real() * 3.6, (azar.real() - 0.5) * 1.7 * Mall.atrio)
                    }
                } else { esperarHasta = ahora + 6 + Double(azar.real() * 10) }
            }
            if hypot(destino.x - pos.x, destino.y - pos.y) > 0.4 {
                ruta = nav.ruta(pos, destino)
                if !ruta.isEmpty { ruta.removeFirst() }
                directo = false
                if ruta.isEmpty && meta == .escritorio {   // sin camino en la grilla: va a su puerta y entra derecho a la silla
                    ruta = [o.puerta, o.silla]; directo = true
                }
            }
            if ruta.isEmpty && esperarHasta <= ahora { esperarHasta = ahora + 3 }
        }
        var caminando = false
        if let objetivo = ruta.first {
            let dx = objetivo.x - pos.x, dz = objetivo.y - pos.y, d = hypot(dx, dz)
            if d < 0.12 {
                ruta.removeFirst()
                if ruta.isEmpty { llegar(ahora: ahora, o: o) }
            } else {
                let avance = min(d, velocidad * dt)
                let nuevo = CGPoint(x: pos.x + dx / d * avance, y: pos.y + dz / d * avance)
                if directo || nav.libre(nuevo) || !nav.libre(pos) { pos = nuevo } else { replanear = true }
                girarHacia(atan2(dx, dz), dt: dt)
                caminando = true
            }
        }
        // Pies sobre el piso real, suavizado (escalera, placas)
        alturaActual += (piso(pos) - alturaActual) * min(1, dt * 12)
        raiz.position = SCNVector3(pos.x, alturaActual, pos.y)
        animar(caminando: caminando, dt: dt, ahora: ahora)
    }

    private func llegar(ahora: CFTimeInterval, o: Oficina) {
        switch meta {
        case .escritorio: yaw = o.mirarEscritorio; raiz.eulerAngles.y = yaw; esperarHasta = ahora + 10 + Double(azar.real() * 16)
        case .audiencia: yaw = .pi * 0.92; raiz.eulerAngles.y = yaw; esperarHasta = .infinity
        case .puerta: yaw = atan2(centroZona.x - pos.x, centroZona.y - pos.y); raiz.eulerAngles.y = yaw; esperarHasta = ahora + 40
        default: esperarHasta = ahora + 3 + Double(azar.real() * 5)
        }
    }

    private func girarHacia(_ objetivo: CGFloat, dt: CGFloat) {
        var d = objetivo - yaw
        while d > .pi { d -= 2 * .pi }; while d < -.pi { d += 2 * .pi }
        yaw += d * min(1, dt * 9)
        raiz.eulerAngles.y = yaw
    }

    private var directo = false     // ruta de respaldo (puerta → silla) que no consulta la grilla

    private func animar(caminando: Bool, dt: CGFloat, ahora: CFTimeInterval) {
        let saludar = !caminando && problema && meta == .puerta
        let teclear = !caminando && meta == .escritorio && ruta.isEmpty && estado != "off" && (oficina.map { hypot(pos.x - $0.silla.x, pos.y - $0.silla.y) < 0.35 } ?? false)
        if caminando { fase += dt * velocidad * 5.2 }
        let s = sin(fase)
        // Sentado en su escritorio: caderas sobre el asiento (0,53 m), muslos hacia el escritorio y espalda en el respaldo.
        // Solo se sienta si de verdad está sobre su silla (si quedó en la puerta o en la plaza, queda de pie).
        let enSilla = oficina.map { hypot(pos.x - $0.silla.x, pos.y - $0.silla.y) < 0.35 } ?? false
        let sentado = !caminando && meta == .escritorio && ruta.isEmpty && enSilla
        piernas[0].eulerAngles.x = sentado ? -1.3 : caminando ? s * 0.55 : 0
        piernas[1].eulerAngles.x = sentado ? -1.3 : caminando ? -s * 0.55 : 0
        cuerpo.position = SCNVector3(0, sentado ? -0.25 : caminando ? abs(cos(fase)) * 0.04 : 0, sentado ? -0.1 : 0)
        if saludar {
            let w = CGFloat(sin(ahora * 7))
            brazos[0].eulerAngles = SCNVector3(0, 0, -2.5 + w * 0.35)
            brazos[1].eulerAngles = SCNVector3(0, 0, 2.5 - w * 0.35)
        } else if teclear {
            let w = CGFloat(sin(ahora * 14)) * 0.06
            brazos[0].eulerAngles = SCNVector3(-1.1 + w, 0, -0.15)
            brazos[1].eulerAngles = SCNVector3(-1.1 - w, 0, 0.15)
        } else {
            brazos[0].eulerAngles = SCNVector3(caminando ? -s * 0.5 : 0, 0, -0.05)
            brazos[1].eulerAngles = SCNVector3(caminando ? s * 0.5 : 0, 0, 0.05)
        }
    }
}

// MARK: - Controles de cámara

extension Notification.Name { static let villaCamara = Notification.Name("villaCamara") }

struct ControlesCamara: View {
    func boton(_ icono: String, _ accion: String, _ ayuda: String) -> some View {
        Button { NotificationCenter.default.post(name: .villaCamara, object: accion) } label: {
            Image(systemName: icono).font(.system(size: 15, weight: .semibold)).frame(width: 34, height: 34)
        }
        .buttonStyle(.plain).help(ayuda)
    }
    var body: some View {
        VStack(spacing: 2) {
            boton("plus.magnifyingglass", "acercar", "Acercar (⌘+). También: rueda del mouse o pellizcar en el trackpad")
            boton("minus.magnifyingglass", "alejar", "Alejar (⌘−)")
            Divider().frame(width: 26)
            boton("arrow.counterclockwise", "izquierda", "Girar a la izquierda (⌘←). También: arrastrar con el mouse")
            boton("arrow.clockwise", "derecha", "Girar a la derecha (⌘→)")
            boton("arrow.up.circle", "subir", "Ver más desde arriba (⌘↑)")
            boton("arrow.down.circle", "bajar", "Ver más a ras de suelo (⌘↓)")
            Divider().frame(width: 26)
            boton("scope", "general", "Vista general de toda la villa (⌘0)")
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(14)
    }
}


/// Vehículo que recorre en bucle una ruta cerrada (polilínea en el plano x-z) y se detiene en sus paradas.
final class Vehiculo {
    let raiz: SCNNode
    private let pts: [CGPoint], acum: [CGFloat], total: CGFloat
    private let velocidad: CGFloat, paradas: [(s: CGFloat, seg: Double)]
    private let reversa: Set<Int>                         // tramos que recorre en retroceso (p. ej. entrar al andén)
    let largo: CGFloat, ancho: CGFloat, paciente: Bool     // huella para no encimarse; paciente: nunca pasa «liberado»
    private(set) var avance: CGFloat = 0                  // hacia dónde se mueve (en retroceso, opuesto al rumbo)
    private var enReversa = false
    private var s: CGFloat, espera: Double = 0
    private(set) var pos = CGPoint.zero, rumbo: CGFloat = 0
    var detenido = false
    var esperando: CGFloat = 0, liberado: CGFloat = 0     // anti-atasco: segundos detenido y segundos de paso libre

    var trazado: [CGPoint] { pts }
    init(_ raiz: SCNNode, ruta: [CGPoint], s: CGFloat, velocidad: CGFloat, paradas: [(s: CGFloat, seg: Double)] = [],
         reversa: Set<Int> = [], largo: CGFloat = 4.3, ancho: CGFloat = 1.8, paciente: Bool = false) {
        self.raiz = raiz; pts = ruta; self.velocidad = velocidad; self.paradas = paradas
        self.reversa = reversa; self.largo = largo; self.ancho = ancho; self.paciente = paciente
        var a: [CGFloat] = [0]
        for i in 0..<ruta.count { let p = ruta[i], q = ruta[(i + 1) % ruta.count]; a.append(a.last! + hypot(q.x - p.x, q.y - p.y)) }
        acum = a; total = a.last!
        self.s = (s.truncatingRemainder(dividingBy: total) + total).truncatingRemainder(dividingBy: total)
        ubicar(suave: false)
    }

    func paso(_ dt: CGFloat) {
        if espera > 0 { espera -= Double(dt); return }
        if detenido { return }
        let antes = s
        s += velocidad * dt * (enReversa ? 0.35 : 1)
        for p in paradas where antes < p.s && s >= p.s { s = p.s; espera = p.seg }
        if s >= total { s -= total }
        ubicar(suave: true)
    }

    private func ubicar(suave: Bool) {
        var i = 0
        while i < pts.count - 1 && acum[i + 1] < s { i += 1 }
        let p = pts[i], q = pts[(i + 1) % pts.count]
        let t = (s - acum[i]) / max(0.001, acum[i + 1] - acum[i])
        pos = CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t)
        avance = atan2(q.x - p.x, q.y - p.y)
        enReversa = reversa.contains(i)
        let meta = avance + (enReversa ? .pi : 0)
        var d = meta - rumbo
        while d > .pi { d -= 2 * .pi }
        while d < -.pi { d += 2 * .pi }
        rumbo += suave ? d * 0.25 : d
        let r = hypot(pos.x, pos.y)      // ruedas sobre el asfalto (0,075 m) o sobre el tablero del puente (0,47 m)
        let ac = Villa3D.Coordinador.acceso   // la rampa y el puente solo existen sobre el eje del acceso (no en el puerto)
        let enAcceso = abs(pos.x * cos(ac) - pos.y * sin(ac)) < 6 && pos.x * sin(ac) + pos.y * cos(ac) > 0
        raiz.position = SCNVector3(pos.x, (enAcceso && r > 84 ? 0.47 : enAcceso && r > 76 ? 0.075 + (r - 76) / 8 * 0.395 : r < 14.5 ? 0.12 : 0.075) + (r > 70 ? Islas.alturaPuente(pos) : 0), pos.y); raiz.eulerAngles.y = rumbo
    }
}


// MARK: - Centro comercial (mall) curvo, con atrio de vidrio, tiendas, estacionamientos señalizados, zona de proveedores
// con bodega de descarga y camiones repartidores

/// Geometría del mall: un arco concéntrico con el anillo periférico (no queda al borde de la isla).
/// Ángulos relativos a `ang` (positivo = sentido horario visto desde arriba, como los rumbos de la villa).
enum Mall {
    nonisolated static let ang: CGFloat = 1.95                 // entre el Taller iOS y La nube, frente al mar
    nonisolated static let rFrente: CGFloat = 66.4, rFondo: CGFloat = 75.4   // frente a 3,4 m del asfalto del anillo (pasto y vereda)
    nonisolated static let atrio: CGFloat = 0.087              // medio ancho angular del atrio (±6 m)
    nonisolated static let modulo: CGFloat = 0.065             // ancho angular de cada tienda (4,5 m a r 69)
    nonisolated static let alas = 5                             // tiendas por lado
    nonisolated static let centro = polar(70.1, 0)              // atrio (barrio «mall»)
    nonisolated static let estacionamiento: CGFloat = -0.53    // calces públicos (lado poniente)
    nonisolated static let proveedores: CGFloat = 0.61         // estacionamiento exclusivo de proveedores y bodega (oriente)
    nonisolated static func polar(_ r: CGFloat, _ t: CGFloat) -> CGPoint { CGPoint(x: sin(ang + t) * r, y: cos(ang + t) * r) }
    /// Punto en un marco tangente: `x` a lo largo del arco (hacia ángulos mayores), `z` hacia el mar, centrado en (r, t).
    nonisolated static func marco(_ r: CGFloat, _ t: CGFloat, _ x: CGFloat, _ z: CGFloat) -> CGPoint {
        let a = ang + t
        return CGPoint(x: sin(a) * (r + z) + cos(a) * x, y: cos(a) * (r + z) - sin(a) * x)
    }
    /// Sin árboles ni palmeras sobre el mall, sus estacionamientos y la bodega.
    nonisolated static func libre(_ p: CGPoint) -> Bool {
        var d = atan2(p.x, p.y) - ang
        while d > .pi { d -= 2 * .pi }; while d < -.pi { d += 2 * .pi }
        return !(hypot(p.x, p.y) > 58 && abs(d) < 0.7)
    }
    @MainActor static var pantallas: [String: SCNMaterial] = [:]
    @MainActor static var refresco: CFTimeInterval = 0
    @MainActor static var puertas: [(SCNNode, CGFloat)] = [], apertura: CGFloat = 0
    /// Agentes que también tienen oficina en La nube porque su trabajo corre en la nube (tarea programada de Claude).
    @MainActor static func enLaNube(_ agentes: [Agente]) -> [Agente] {
        agentes.filter { $0.zona != "nube" && $0.def.plist?.hasPrefix("Tarea en la nube") == true }
    }
    /// Archivo con las horas de la tarea en la nube de cada agente (si no tiene, alterna cada 20 min).
    nonisolated static let archivoNube = ["trad": "traductor-nube.json"]
}

/// Tipos de estacionamiento con su señalética.
enum Calce { case normal, discapacidad, adultoMayor, embarazada, proveedor
    var ancho: CGFloat { switch self { case .normal: 2.4; case .discapacidad: 3.2; case .adultoMayor, .embarazada: 2.6; case .proveedor: 3.8 } }
}

extension Villa3D.Coordinador {
    /// Cartel de tienda: fondo de color y nombre en blanco (el texto se achica hasta caber).
    static func cartelTienda(_ texto: String, _ fondo: NSColor, ancho: CGFloat = 620) -> NSImage {
        NSImage(size: NSSize(width: ancho, height: 110), flipped: false) { r in
            fondo.setFill(); NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12).fill()
            var tam: CGFloat = 62
            var at: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: tam, weight: .heavy), .foregroundColor: NSColor.white, .kern: 2]
            var t = (texto as NSString).size(withAttributes: at)
            while t.width > r.width - 40 && tam > 18 {
                tam -= 2; at[.font] = NSFont.systemFont(ofSize: tam, weight: .heavy); t = (texto as NSString).size(withAttributes: at)
            }
            (texto as NSString).draw(at: NSPoint(x: (r.width - t.width) / 2, y: (r.height - t.height) / 2), withAttributes: at)
            return true
        }
    }

    static func mCartel(_ texto: String, _ fondo: NSColor, ancho: CGFloat = 620, brillo: CGFloat = 0.6) -> SCNMaterial {
        let img = cartelTienda(texto, fondo, ancho: ancho)
        let m = SCNMaterial(); m.diffuse.contents = img; m.emission.contents = img; m.emission.intensity = brillo
        return m
    }

    // MARK: Señalética de estacionamientos (pictogramas dibujados, sin marcas registradas)

    /// Pictograma blanco sobre un cuadro de color: símbolo internacional de accesibilidad (azul), adulto mayor con
    /// bastón (verde) o embarazada (rosado). Con texto abajo si `texto`.
    static func pictograma(_ c: Calce, texto: Bool) -> NSImage {
        let fondo: NSColor = c == .discapacidad ? NSColor(Color(hex: "#005EB8")) : c == .adultoMayor ? NSColor(Color(hex: "#1E8449"))
            : c == .embarazada ? NSColor(Color(hex: "#D6457F")) : NSColor(Color(hex: "#E5B000"))
        let alto: CGFloat = texto ? 330 : 256
        return NSImage(size: NSSize(width: 256, height: alto), flipped: false) { r in
            fondo.setFill(); NSBezierPath(roundedRect: r, xRadius: 18, yRadius: 18).fill()
            NSColor.white.setStroke(); NSColor.white.setFill()
            let y0: CGFloat = texto ? 74 : 0
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * 256, y: y0 + y * 256) }
            func trazo(_ pts: [(CGFloat, CGFloat)], ancho: CGFloat = 20) {
                let b = NSBezierPath(); b.lineWidth = ancho; b.lineCapStyle = .round; b.lineJoinStyle = .round
                b.move(to: p(pts[0].0, pts[0].1)); for q in pts.dropFirst() { b.line(to: p(q.0, q.1)) }; b.stroke()
            }
            func cabeza(_ x: CGFloat, _ y: CGFloat, _ rr: CGFloat = 0.075) { NSBezierPath(ovalIn: NSRect(x: (x - rr) * 256, y: y0 + (y - rr) * 256, width: rr * 512, height: rr * 512)).fill() }
            switch c {
            case .discapacidad:
                cabeza(0.42, 0.82)
                trazo([(0.40, 0.70), (0.40, 0.46), (0.62, 0.46), (0.72, 0.24), (0.82, 0.24)])
                trazo([(0.40, 0.62), (0.58, 0.62)])
                let rueda = NSBezierPath(); rueda.lineWidth = 18
                rueda.appendArc(withCenter: p(0.43, 0.34), radius: 0.2 * 256, startAngle: 100, endAngle: 20, clockwise: false); rueda.stroke()
            case .adultoMayor:
                cabeza(0.45, 0.83)
                trazo([(0.45, 0.72), (0.52, 0.48)]); trazo([(0.52, 0.48), (0.42, 0.14)]); trazo([(0.52, 0.48), (0.62, 0.14)])
                trazo([(0.47, 0.66), (0.66, 0.52)]); trazo([(0.66, 0.52), (0.72, 0.12)], ancho: 12)
            case .embarazada:
                cabeza(0.48, 0.84)
                trazo([(0.48, 0.73), (0.48, 0.30)]); trazo([(0.48, 0.30), (0.42, 0.10)]); trazo([(0.48, 0.30), (0.56, 0.10)])
                let panza = NSBezierPath(ovalIn: NSRect(x: 0.47 * 256, y: y0 + 0.36 * 256, width: 0.2 * 256, height: 0.24 * 256)); panza.fill()
                trazo([(0.48, 0.64), (0.36, 0.48)], ancho: 16)
            case .proveedor:
                NSColor(calibratedWhite: 0.1, alpha: 1).setFill()
                NSBezierPath(rect: NSRect(x: 0.12 * 256, y: y0 + 0.36 * 256, width: 0.46 * 256, height: 0.32 * 256)).fill()
                NSBezierPath(rect: NSRect(x: 0.6 * 256, y: y0 + 0.36 * 256, width: 0.24 * 256, height: 0.22 * 256)).fill()
                for x: CGFloat in [0.24, 0.48, 0.74] { NSBezierPath(ovalIn: NSRect(x: (x - 0.06) * 256, y: y0 + 0.24 * 256, width: 0.12 * 256, height: 0.12 * 256)).fill() }
            case .normal: break
            }
            if texto {
                let t: String = c == .discapacidad ? "DISCAPACIDAD" : c == .adultoMayor ? "ADULTO MAYOR" : c == .embarazada ? "EMBARAZADA" : "PROVEEDORES"
                let at: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30, weight: .heavy), .foregroundColor: c == .proveedor ? NSColor.black : NSColor.white]
                let s = (t as NSString).size(withAttributes: at)
                (t as NSString).draw(at: NSPoint(x: (256 - s.width) / 2, y: 22), withAttributes: at)
            }
            return true
        }
    }

    private static var matsCalce: [String: SCNMaterial] = [:]
    static func mCalce(_ c: Calce, texto: Bool) -> SCNMaterial {
        let k = "\(c)-\(texto)"
        if let m = matsCalce[k] { return m }
        let img = pictograma(c, texto: texto)
        let m = SCNMaterial(); m.diffuse.contents = img; m.lightingModel = .physicallyBased; m.roughness.contents = 0.7
        m.isDoubleSided = true; matsCalce[k] = m
        return m
    }

    /// Franjas diagonales azul/blanco del pasillo de acceso de la silla de ruedas.
    private static let mAchurado: SCNMaterial = {
        let img = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { r in
            NSColor(Color(hex: "#005EB8")).setFill(); r.fill()
            NSColor.white.setStroke()
            for k in stride(from: -128, through: 256, by: 32) {
                let b = NSBezierPath(); b.lineWidth = 12; b.move(to: NSPoint(x: k, y: 0)); b.line(to: NSPoint(x: k + 128, y: 128)); b.stroke()
            }
            return true
        }
        let m = SCNMaterial(); m.diffuse.contents = img; m.diffuse.wrapS = .repeat; m.diffuse.wrapT = .repeat
        m.diffuse.contentsTransform = SCNMatrix4MakeScale(1, 4, 1); return m
    }()

    /// Fila de calces en un marco local de `g`: x a lo largo de la fila (desde 0), z = fondo del calce (0 → `largo`).
    /// Pinta líneas, el pictograma en el piso y un letrero en poste al fondo de cada calce especial. Devuelve los
    /// centros x de cada calce.
    @discardableResult
    func filaCalces(_ g: SCNNode, _ tipos: [Calce], largo: CGFloat, linea: SCNMaterial, amarillo: SCNMaterial, anchos: [CGFloat]? = nil) -> [CGFloat] {
        var x: CGFloat = 0, centros: [CGFloat] = []
        let poste = Mat.pbr(NSColor(calibratedWhite: 0.55, alpha: 1), rugosidad: 0.4, metal: 0.7)
        for (i, t) in tipos.enumerated() {
            let m = t == .proveedor ? amarillo : linea
            if i == 0 { g.addChildNode(nodo(SCNBox(width: 0.1, height: 0.02, length: largo, chamferRadius: 0), m, y: 0.09, x: x, z: largo / 2)) }
            let w = anchos?[i] ?? t.ancho
            g.addChildNode(nodo(SCNBox(width: 0.1, height: 0.02, length: largo, chamferRadius: 0), m, y: 0.09, x: x + w, z: largo / 2))
            var util = w, cx = x + w / 2
            if t == .discapacidad {          // pasillo de acceso achurado de 0,8 m al costado
                let ach = nodo(SCNPlane(width: 0.75, height: largo - 0.2), Villa3D.Coordinador.mAchurado, y: 0.095, x: x + w - 0.42, z: largo / 2)
                ach.eulerAngles.x = -.pi / 2; g.addChildNode(ach)
                util = w - 0.8; cx = x + util / 2
            }
            if t != .normal {
                let lado = min(util - 0.5, 1.7)
                let dec = nodo(SCNPlane(width: lado, height: lado * (t == .proveedor ? 1.0 : 1.29)), Villa3D.Coordinador.mCalce(t, texto: t != .proveedor), y: 0.1, x: cx, z: largo * 0.55)
                dec.eulerAngles.x = -.pi / 2; dec.eulerAngles.y = .pi; g.addChildNode(dec)
            }
            if t != .normal && t != .proveedor {
                // Letrero vertical al fondo del calce, mirando hacia el pasillo
                g.addChildNode(nodo(SCNCylinder(radius: 0.04, height: 2.0), poste, y: 1.0, x: cx, z: largo + 0.25))
                let l = nodo(SCNPlane(width: 0.6, height: 0.77), Villa3D.Coordinador.mCalce(t, texto: true), y: 1.75, x: cx, z: largo + 0.21)
                l.eulerAngles.y = .pi; g.addChildNode(l)
            }
            centros.append(cx)
            x += w
        }
        return centros
    }

    // MARK: Construcción

    /// Sector de anillo (de r0 a r1, de t0 a t1 relativo a `Mall.ang`) como pieza plana extruida, en coordenadas del mundo.
    private func sector(_ r0: CGFloat, _ r1: CGFloat, _ t0: CGFloat, _ t1: CGFloat, alto: CGFloat, y: CGFloat, _ m: SCNMaterial) -> SCNNode {
        // Malla propia (franja de triángulos): SCNShape triangulaba mal el arco y dejaba picos sin piso.
        let n = max(4, Int(abs(t1 - t0) / 0.01)), arriba = y + alto / 2
        var v: [SCNVector3] = [], uv: [CGPoint] = [], idx: [Int32] = []
        for k in 0...n {
            let u = CGFloat(k) / CGFloat(n), t = t0 + (t1 - t0) * u, a = Mall.polar(r0, t), b = Mall.polar(r1, t)
            v += [SCNVector3(a.x, arriba, a.y), SCNVector3(b.x, arriba, b.y)]
            uv += [CGPoint(x: u, y: 0), CGPoint(x: u, y: 1)]
        }
        for k in 0..<n { let i = Int32(2 * k); idx += [i, i + 1, i + 2, i + 1, i + 3, i + 2] }
        let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: v), SCNGeometrySource(normals: Array(repeating: SCNVector3(0, 1, 0), count: v.count)),
                                        SCNGeometrySource(textureCoordinates: uv)],
                              elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
        let mm = (m.copy() as? SCNMaterial) ?? m; mm.isDoubleSided = true
        geo.materials = [mm]
        return SCNNode(geometry: geo)
    }

    /// Caja tangente al arco centrada en (r, t), con su frente (+z local) mirando al centro de la isla.
    private func tangente(_ g: SCNNode, _ geo: SCNGeometry, _ m: SCNMaterial, r: CGFloat, t: CGFloat, y: CGFloat, frente: Bool = true) -> SCNNode {
        let q = Mall.polar(r, t)
        let n = nodo(geo, m, y: y, x: q.x, z: q.y)
        n.eulerAngles.y = Mall.ang + t + (frente ? .pi : 0)
        g.addChildNode(n)
        return n
    }

    /// Mall de gran ciudad, en arco: atrio de vidrio al centro con las oficinas de sus agentes a la vista y dos
    /// pantallas (gastos y tokens), dos alas de dos pisos con 20 tiendas, letrero, tótem con logo, estacionamiento
    /// público con calces preferentes y, al oriente, estacionamiento exclusivo de proveedores con su bodega de descarga.
    func montarMall(_ r: SCNNode) {
        let g = SCNNode(); r.addChildNode(g)
        let rf = Mall.rFrente, rb = Mall.rFondo, rc = (rf + rb) / 2, prof = rb - rf
        let muro = Mat.textura(.estuco, repetir: 3, tinte: "#efe7dc"), gris = Mat.pbr(NSColor(Color(hex: "#5d6670")), rugosidad: 0.5, metal: 0.4)
        let blanco = Mat.pbr(NSColor(calibratedWhite: 0.95, alpha: 1), rugosidad: 0.45), oscuro = Mat.pbr(NSColor(calibratedWhite: 0.16, alpha: 1), rugosidad: 0.6)
        let acero = Mat.pbr(NSColor(Color(hex: "#c9ced3")), rugosidad: 0.35, metal: 0.7)
        let asfalto = Mat.pbr(NSColor(calibratedWhite: 0.2, alpha: 1), rugosidad: 0.85), linea = Mat.pbr(NSColor(calibratedWhite: 0.94, alpha: 1))
        let amarillo = Mat.pbr(NSColor(Color(hex: "#F2C230")), rugosidad: 0.6)
        let vidrio: SCNMaterial = {
            let m = Mat.pbr(NSColor(Color(hex: "#bfe3f5")), rugosidad: 0.05, metal: 0.2); m.transparency = 0.15; m.writesToDepthBuffer = false; return m
        }()
        // ---- Atrio: piso, fachada de vidrio con puertas, techo de vidrio, muro de fondo con pantallas
        g.addChildNode(sector(rf - 1.2, rb, -Mall.atrio, Mall.atrio, alto: 0.1, y: 0.07, Mat.textura(.marmol, repetir: 6)))
        g.addChildNode(sector(rf, rb, -Mall.atrio, Mall.atrio, alto: 0.06, y: 7.1, vidrio))
        let puerta: CGFloat = 0.034                                   // medio ancho angular de las puertas (±2,2 m)
        for (t0, t1) in [(-Mall.atrio, -puerta), (puerta, Mall.atrio)] {
            let tm = (t0 + t1) / 2, largo = (t1 - t0) * rf
            _ = tangente(g, SCNBox(width: largo, height: 6.4, length: 0.08, chamferRadius: 0), vidrio, r: rf, t: tm, y: 3.2)
            let q = Mall.polar(rf, tm); nav.rect(q.x, q.y, largo / 2, 0.1, Mall.ang + tm)
        }
        for t in [-Mall.atrio, -puerta, puerta, Mall.atrio] { _ = tangente(g, SCNBox(width: 0.22, height: 6.6, length: 0.22, chamferRadius: 0), acero, r: rf, t: t, y: 3.3) }
        _ = tangente(g, SCNBox(width: 2 * Mall.atrio * rf + 0.4, height: 0.5, length: 0.3, chamferRadius: 0), gris, r: rf, t: 0, y: 6.6)      // dintel
        _ = tangente(g, SCNBox(width: 4.6, height: 0.06, length: 1.0, chamferRadius: 0.02), vidrio, r: rf - 0.5, t: 0, y: 3.55)            // marquesina de vidrio
        _ = tangente(g, SCNBox(width: 2 * puerta * rf, height: 3.2, length: 0.06, chamferRadius: 0), vidrio, r: rf, t: 0, y: 4.8)           // vidrio fijo sobre las puertas
        _ = tangente(g, SCNBox(width: 2 * puerta * rf, height: 0.14, length: 0.24, chamferRadius: 0), acero, r: rf, t: 0, y: 3.2)           // riel de las puertas
        // Puertas automáticas: dos hojas de vidrio que se corren a los lados cuando alguien se acerca (moverPuertasMall)
        let pc = Mall.polar(rf, 0), pivote = SCNNode()
        pivote.position = SCNVector3(pc.x, 0.12, pc.y); pivote.eulerAngles.y = Mall.ang + .pi
        let hojaV: SCNMaterial = { let m = Mat.pbr(NSColor(Color(hex: "#cfeaf7")), rugosidad: 0.05, metal: 0.2); m.transparency = 0.3; m.writesToDepthBuffer = false; return m }()
        Mall.puertas = []
        for lado: CGFloat in [-1, 1] {
            let hoja = SCNNode()
            hoja.addChildNode(nodo(SCNBox(width: 2.1, height: 3.0, length: 0.04, chamferRadius: 0), hojaV, y: 1.5))
            for x: CGFloat in [-1.05, 1.05] { hoja.addChildNode(nodo(SCNBox(width: 0.06, height: 3.0, length: 0.07, chamferRadius: 0), acero, y: 1.5, x: x)) }
            hoja.addChildNode(nodo(SCNBox(width: 2.1, height: 0.06, length: 0.07, chamferRadius: 0), acero, y: 0.03))
            hoja.position = SCNVector3(lado * 1.07, 0, 0.06 * lado)
            pivote.addChildNode(hoja); Mall.puertas.append((hoja, lado))
        }
        escena.rootNode.addChildNode(pivote)
        _ = tangente(g, SCNBox(width: 11, height: 1.2, length: 0.12, chamferRadius: 0.05),
                     Villa3D.Coordinador.mCartel("CENTRO COMERCIAL VILLA", NSColor(Color(hex: "#b0306a")), ancho: 1010, brillo: 0.8), r: rf - 0.2, t: 0, y: 7.9)
        var t = -Mall.atrio
        while t <= Mall.atrio + 0.001 {                                // cerchas del techo
            _ = tangente(g, SCNBox(width: 0.12, height: 0.18, length: prof, chamferRadius: 0), acero, r: rc, t: t, y: 7.0)
            t += Mall.atrio / 2
        }
        let fondoAtrio = 2 * Mall.atrio * rb
        _ = tangente(g, SCNBox(width: fondoAtrio, height: 7, length: 0.25, chamferRadius: 0), muro, r: rb, t: 0, y: 3.5)
        let qf = Mall.polar(rb, 0); nav.rect(qf.x, qf.y, fondoAtrio / 2, 0.2, Mall.ang)
        // Pantallas de gastos (Cajero) y tokens (Contador): se redibujan cada minuto con datos reales; clic → su pizarra
        for (k, id) in ["cajero", "tok"].enumerated() {
            let m = SCNMaterial(); m.lightingModel = .constant; m.diffuse.contents = NSColor(calibratedRed: 0.05, green: 0.08, blue: 0.14, alpha: 1)
            Mall.pantallas[id] = m
            let tt: CGFloat = k == 0 ? -0.042 : 0.042, q = Mall.polar(rb - 0.18, tt)
            let marco = nodo(SCNBox(width: 4.9, height: 2.85, length: 0.08, chamferRadius: 0.03), oscuro, y: 5.25, x: q.x, z: q.y)
            marco.eulerAngles.y = Mall.ang + tt + .pi
            marco.addChildNode(nodo(SCNPlane(width: 4.7, height: 2.65), m, z: 0.045))
            marco.name = "agente:\(id)"
            escena.rootNode.addChildNode(marco)
        }
        // ---- Alas de tiendas (dos pisos), cada tienda un módulo tangente al arco
        let nombres: [(String, String)] = [("MODA ANDES", "#2f4b7c"), ("TECNO SUR", "#1f7a6d"), ("CALZADO NORTE", "#8a4b2a"), ("CAFÉ LUNA", "#5b3a29"),
            ("LIBRERÍA PACÍFICO", "#3d3f7a"), ("ÓPTICA CLARA", "#2a6f97"), ("DEPORTES ATACAMA", "#c0392b"), ("FARMACIA OASIS", "#2e8b57"),
            ("JUGUETES KIRI", "#d68910"), ("PATIO DE COMIDAS", "#b0306a"), ("CINE COSTA", "#222831"), ("BANCO VILLA", "#1a5276"),
            ("PERFUMERÍA BRISA", "#8e44ad"), ("HOGAR PAMPA", "#7d6608"), ("MASCOTAS ALTIPLANO", "#117a65"), ("JOYERÍA LUZ", "#9a7d0a"),
            ("MÚSICA VIENTO", "#6c3483"), ("BELLEZA ROSA", "#c2185b"), ("SUPERMERCADO COSTA", "#196f3d"), ("ELECTRO VALLE", "#283747")]
        var k = 0
        for lado: CGFloat in [-1, 1] {
            for i in 0..<Mall.alas {
                let tm = lado * (Mall.atrio + (CGFloat(i) + 0.5) * Mall.modulo)
                let ancho = Mall.modulo * rb + 0.05
                _ = tangente(g, SCNBox(width: ancho, height: 8.6, length: prof, chamferRadius: 0), muro, r: rc, t: tm, y: 4.3)
                _ = tangente(g, SCNBox(width: ancho + 0.1, height: 0.5, length: prof + 0.3, chamferRadius: 0), blanco, r: rc, t: tm, y: 8.8)
                _ = tangente(g, SCNBox(width: ancho, height: 0.3, length: 0.4, chamferRadius: 0), blanco, r: rf - 0.05, t: tm, y: 4.3)
                if i % 2 == 0 { _ = tangente(g, SCNBox(width: 1.8, height: 1.1, length: 1.4, chamferRadius: 0.05), gris, r: rc + 1.5, t: tm, y: 9.6) }
                for piso in 0..<2 {
                    let y0: CGFloat = piso == 0 ? 0 : 4.4, (nombre, color) = nombres[k % nombres.count]; k += 1
                    _ = tangente(g, SCNBox(width: 3.5, height: 2.6, length: 0.06, chamferRadius: 0), ventana(), r: rf - 0.02, t: tm, y: y0 + 1.5)
                    _ = tangente(g, SCNBox(width: 3.6, height: 0.08, length: 0.9, chamferRadius: 0.02), Mat.pbr(NSColor(Color(hex: color)), rugosidad: 0.6), r: rf - 0.45, t: tm, y: y0 + 2.95)
                    _ = tangente(g, SCNBox(width: 3.4, height: 0.6, length: 0.06, chamferRadius: 0), Villa3D.Coordinador.mCartel(nombre, NSColor(Color(hex: color))), r: rf - 0.07, t: tm, y: y0 + 3.55)
                }
                let q = Mall.polar(rc, tm); nav.rect(q.x, q.y, ancho / 2, prof / 2, Mall.ang + tm)
            }
        }
        // ---- Tótem a la entrada: logo propio (bolsa de compras) y la palabra MALL derecha y legible, al frente
        let totem = Mall.polar(rf - 1.6, 0.07)
        let tg = SCNNode(); tg.position = SCNVector3(totem.x, 0, totem.y); tg.eulerAngles.y = Mall.ang + 0.07 + .pi
        tg.addChildNode(nodo(SCNBox(width: 1.7, height: 8.6, length: 0.6, chamferRadius: 0.12), Mat.pbr(NSColor(Color(hex: "#7a1f4a")), rugosidad: 0.4, metal: 0.3), y: 4.3))
        let logo = Villa3D.Coordinador.logoMall()
        for (z, giro) in [(CGFloat(0.31), CGFloat(0)), (-0.31, .pi)] {
            let cara = nodo(SCNPlane(width: 1.5, height: 8.2), logo, y: 4.35, z: z); cara.eulerAngles.y = giro; tg.addChildNode(cara)
        }
        g.addChildNode(tg)
        nav.rect(totem.x, totem.y, 0.9, 0.35, Mall.ang + 0.07)
        // ---- Estacionamiento público (poniente): calce de discapacidad, adulto mayor, embarazada y normales
        let tp = Mall.estacionamiento, rp: CGFloat = 68
        let lote = SCNNode(); let lq = Mall.polar(rp, tp); lote.position = SCNVector3(lq.x, 0, lq.y); lote.eulerAngles.y = Mall.ang + tp
        lote.addChildNode(nodo(SCNBox(width: 13.8, height: 0.06, length: 9.6, chamferRadius: 0), asfalto, y: 0.05))
        lote.addChildNode(nodo(SCNBox(width: 4, height: 0.06, length: 2.4, chamferRadius: 0), asfalto, y: 0.05, z: -5.8))          // entrada desde el anillo
        let fila = SCNNode(); fila.position = SCNVector3(-6.5, 0, -0.2); lote.addChildNode(fila)
        let centros = filaCalces(fila, [.discapacidad, .adultoMayor, .embarazada, .normal, .normal], largo: 4.9, linea: linea, amarillo: amarillo)
        lote.addChildNode(nodo(SCNBox(width: 2.6, height: 0.5, length: 0.06, chamferRadius: 0), Villa3D.Coordinador.mCartel("ESTACIONAMIENTO", NSColor(Color(hex: "#1a5276"))), y: 2.0, x: 5.3, z: -4.6))
        lote.addChildNode(nodo(SCNCylinder(radius: 0.05, height: 1.8), acero, y: 0.9, x: 5.3, z: -4.6))
        g.addChildNode(lote)
        let faro = Mat.emisivo(NSColor(calibratedRed: 1, green: 0.97, blue: 0.85, alpha: 1)), freno = Mat.emisivo(.systemRed, fuerza: 0.4)
        for (j, col) in [(3, NSColor(Color(hex: "#3a5f8a"))), (4, NSColor.white), (1, NSColor(Color(hex: "#7a2f2f")))] {
            let p = Mall.marco(rp, tp, -6.5 + centros[j], -0.2 + 2.45)
            let coche = auto(col, suv: j == 4, faro: faro, freno: freno); coche.scale = SCNVector3(1, 1, 1)
            coche.position = SCNVector3(p.x, 0.08, p.y); coche.eulerAngles.y = Mall.ang + tp + .pi
            escena.rootNode.addChildNode(coche)
            nav.rect(p.x, p.y, 0.75, 1.65, Mall.ang + tp)
        }
        // ---- Proveedores (oriente): estacionamiento exclusivo con tres andenes y su bodega de descarga
        let tv = Mall.proveedores
        let pv = SCNNode(); let pq = Mall.polar(rp, tv); pv.position = SCNVector3(pq.x, 0, pq.y); pv.eulerAngles.y = Mall.ang + tv
        pv.addChildNode(nodo(SCNBox(width: 14, height: 0.06, length: 10.6, chamferRadius: 0), asfalto, y: 0.05, z: -1.8))
        let andenes = SCNNode(); andenes.position = SCNVector3(-5.7, 0, -3.0); pv.addChildNode(andenes)
        filaCalces(andenes, [.proveedor, .proveedor, .proveedor], largo: 6.4, linea: linea, amarillo: amarillo)
        // Bodega de descarga con tres portones (uno por andén), andén elevado con topes de goma y letreros
        pv.addChildNode(nodo(SCNBox(width: 14.4, height: 5.2, length: 3.0, chamferRadius: 0.05), Mat.textura(.estuco, repetir: 3, tinte: "#cfd6dc"), y: 2.6, z: 5.6))
        pv.addChildNode(nodo(SCNBox(width: 14.8, height: 0.4, length: 3.4, chamferRadius: 0), gris, y: 5.4, z: 5.6))
        pv.addChildNode(nodo(SCNBox(width: 14.4, height: 1.1, length: 0.6, chamferRadius: 0), Mat.textura(.estuco, repetir: 2, tinte: "#b9b4aa"), y: 0.55, z: 3.75))
        for j in 0..<3 {
            let x = -5.7 + 1.9 + CGFloat(j) * 3.8
            pv.addChildNode(nodo(SCNBox(width: 2.8, height: 3.0, length: 0.08, chamferRadius: 0), oscuro, y: 2.6, x: x, z: 4.07))
            for s: CGFloat in [-1.2, 1.2] { pv.addChildNode(nodo(SCNBox(width: 0.3, height: 0.4, length: 0.25, chamferRadius: 0.05), oscuro, y: 0.75, x: x + s, z: 3.35)) }
        }
        pv.addChildNode(nodo(SCNBox(width: 6.4, height: 0.7, length: 0.06, chamferRadius: 0), Villa3D.Coordinador.mCartel("BODEGA DE DESCARGA", NSColor(Color(hex: "#d68910"))), y: 4.65, z: 4.08))
        // Letrero de entrada: exclusivo para proveedores
        let cartelP = Villa3D.Coordinador.mCartel("EXCLUSIVO PROVEEDORES", NSColor(Color(hex: "#d68910")), ancho: 900)
        // (al costado del lote, mirando al anillo: fuera de la vía y de la maniobra de los camiones)
        for giro in [CGFloat(0), .pi] {
            let c = nodo(SCNBox(width: 3.2, height: 0.5, length: 0.04, chamferRadius: 0), cartelP, y: 2.15, x: -7.6, z: -3.0 + (giro == 0 ? -0.03 : 0.03))
            c.eulerAngles.y = giro + .pi; pv.addChildNode(c)
        }
        let pic = nodo(SCNPlane(width: 0.75, height: 0.75), Villa3D.Coordinador.mCalce(.proveedor, texto: false), y: 2.85, x: -7.6, z: -3.04); pic.eulerAngles.y = .pi
        pv.addChildNode(pic)
        pv.addChildNode(nodo(SCNCylinder(radius: 0.05, height: 2.0), acero, y: 1.0, x: -7.6, z: -3.0))
        g.addChildNode(pv)
        let bq = Mall.marco(rp, tv, 0, 5.6); nav.rect(bq.x, bq.y, 7.4, 1.7, Mall.ang + tv)
        let aq = Mall.marco(rp, tv, 0, 3.75); nav.rect(aq.x, aq.y, 7.2, 0.3, Mall.ang + tv)
        let sp = Mall.marco(rp, tv, -7.6, -3.0); nav.circulo(sp.x, sp.y, 0.1)
        let ep = Mall.marco(rp, tp, 5.3, -4.6); nav.circulo(ep.x, ep.y, 0.1)
    }

    /// Logo del mall: bolsa de compras propia (dibujada) y la palabra MALL horizontal y grande, sobre fondo granate.
    static func logoMall() -> SCNMaterial {
        let img = NSImage(size: NSSize(width: 180, height: 984), flipped: false) { r in
            NSGradient(starting: NSColor(Color(hex: "#c2185b")), ending: NSColor(Color(hex: "#7a1f4a")))?.draw(in: r, angle: -90)
            // Bolsa: cuerpo trapecio blanco con asas
            NSColor.white.setFill(); NSColor.white.setStroke()
            let b = NSBezierPath()
            b.move(to: NSPoint(x: 38, y: 760)); b.line(to: NSPoint(x: 142, y: 760)); b.line(to: NSPoint(x: 152, y: 650)); b.line(to: NSPoint(x: 28, y: 650)); b.close(); b.fill()
            let asa = NSBezierPath(); asa.lineWidth = 9
            asa.appendArc(withCenter: NSPoint(x: 90, y: 760), radius: 30, startAngle: 0, endAngle: 180); asa.stroke()
            NSColor(Color(hex: "#c2185b")).setFill()
            NSBezierPath(ovalIn: NSRect(x: 72, y: 682, width: 36, height: 36)).fill()                 // sello del logo
            // MALL, horizontal y del ancho del tótem
            let at: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 52, weight: .black), .foregroundColor: NSColor.white, .kern: 1]
            let m = ("MALL" as NSString).size(withAttributes: at)
            ("MALL" as NSString).draw(at: NSPoint(x: (180 - m.width) / 2, y: 570), withAttributes: at)
            let chico: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 21, weight: .bold), .foregroundColor: NSColor.white]
            for (i, l) in ["CENTRO", "COMERCIAL", "VILLA"].enumerated() {
                let s = (l as NSString).size(withAttributes: chico)
                (l as NSString).draw(at: NSPoint(x: (180 - s.width) / 2, y: 500 - CGFloat(i) * 30), withAttributes: chico)
            }
            let hor: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor(white: 1, alpha: 0.85)]
            for (i, l) in ["Abierto", "10:00 – 21:00"].enumerated() {
                let s = (l as NSString).size(withAttributes: hor)
                (l as NSString).draw(at: NSPoint(x: (180 - s.width) / 2, y: 120 - CGFloat(i) * 26), withAttributes: hor)
            }
            return true
        }
        let m = SCNMaterial(); m.diffuse.contents = img; m.emission.contents = img; m.emission.intensity = 0.5
        return m
    }

    /// Puertas automáticas del mall: se abren (se corren 1,9 m a cada lado) si hay alguien a menos de 3,5 m.
    func moverPuertasMall(_ dt: CGFloat) {
        guard !Mall.puertas.isEmpty else { return }
        let c = Mall.polar(Mall.rFrente, 0)
        let cerca = personas.values.contains { hypot($0.pos.x - c.x, $0.pos.y - c.y) < 3.5 }
        let meta: CGFloat = cerca ? 1 : 0
        guard abs(Mall.apertura - meta) > 0.001 else { return }
        Mall.apertura += (meta - Mall.apertura) * min(1, dt * 3.5)
        for (h, lado) in Mall.puertas { h.position.x = lado * (1.07 + 1.9 * Mall.apertura) }
    }

    /// Redibuja las pantallas del atrio con los paneles reales de gastos y tokens (cada minuto).
    func actualizarPantallasMall(_ ahora: CFTimeInterval) {
        guard ahora - Mall.refresco > 60, !Mall.pantallas.isEmpty else { return }
        Mall.refresco = ahora
        let vistas: [(String, AnyView)] = [("cajero", AnyView(PanelGastos(pantalla: true))), ("tok", AnyView(PanelTokens(pantalla: true)))]
        for (id, v) in vistas {
            let r = ImageRenderer(content: v.frame(width: 940, height: 530))
            r.scale = 1.6
            if let img = r.nsImage, let m = Mall.pantallas[id] { m.diffuse.contents = img }
        }
    }

    /// Camión repartidor (proa en +z): cabina, furgón con el logo y seis ruedas.
    func camion(_ color: NSColor, faro: SCNMaterial, freno: SCNMaterial) -> SCNNode {
        if let m = Modelos.nodo("camion", largo: 6.4, cambios: ["Headlights": faro, "BrakeLight": freno], nombreElem: "elem:camion") { return m }
        let n = SCNNode()
        let pintura = Mat.pbr(color, rugosidad: 0.35, metal: 0.4), goma = Mat.pbr(NSColor(calibratedWhite: 0.07, alpha: 1), rugosidad: 0.9)
        let furgon = Mat.pbr(NSColor(calibratedWhite: 0.93, alpha: 1), rugosidad: 0.5)
        n.addChildNode(nodo(SCNBox(width: 2.2, height: 2.0, length: 1.9, chamferRadius: 0.15), pintura, y: 1.45, z: 2.55))
        n.addChildNode(nodo(SCNBox(width: 2.0, height: 0.8, length: 0.05, chamferRadius: 0.05), Mat.pbr(NSColor(Color(hex: "#26394d")), rugosidad: 0.1, metal: 0.5), y: 1.95, z: 3.52))
        n.addChildNode(nodo(SCNBox(width: 2.4, height: 2.7, length: 5.0, chamferRadius: 0.06), furgon, y: 1.9, z: -0.9))
        let logo = Villa3D.Coordinador.mCartel("VILLA EXPRESS", color, ancho: 900, brillo: 0.3)
        for x: CGFloat in [-1.21, 1.21] {
            let l = nodo(SCNPlane(width: 4.4, height: 0.9), logo, y: 2.1, x: x, z: -0.9); l.eulerAngles.y = x > 0 ? .pi / 2 : -.pi / 2
            n.addChildNode(l)
        }
        n.addChildNode(nodo(SCNBox(width: 2.3, height: 0.3, length: 7.2, chamferRadius: 0), Mat.pbr(NSColor(calibratedWhite: 0.25, alpha: 1)), y: 0.5, z: 0.2))
        for z: CGFloat in [2.6, -0.4, -2.4] { for x: CGFloat in [-1.05, 1.05] {
            let rueda = nodo(SCNCylinder(radius: 0.48, height: 0.38), goma, y: 0.48, x: x, z: z); rueda.eulerAngles.z = .pi / 2; n.addChildNode(rueda)
        } }
        for x: CGFloat in [-0.8, 0.8] {
            n.addChildNode(nodo(SCNBox(width: 0.3, height: 0.2, length: 0.05, chamferRadius: 0.04), faro, y: 0.9, x: x, z: 3.52))
            n.addChildNode(nodo(SCNBox(width: 0.25, height: 0.18, length: 0.05, chamferRadius: 0.03), freno, y: 0.9, x: x, z: -3.42))
        }
        Villa3D.Coordinador.hornear(n)
        let plano = n.flattenedClone()
        plano.name = "elem:camion"
        return plano
    }

    /// Camiones repartidores: dos vienen de tierra firme (túnel, puente y garita) y uno del puerto. Cada uno tiene su
    /// propio andén en el estacionamiento de proveedores: retrocede hasta la bodega, descarga 15 s, sale de frente y
    /// vuelve por el carril contrario. Respetan su largo para no encimarse con otros vehículos.
    func montarCamiones() {
        let faro = Mat.emisivo(NSColor(calibratedRed: 1, green: 0.97, blue: 0.85, alpha: 1)); focos.append(faro)
        let freno = Mat.emisivo(.systemRed, fuerza: 0.8)
        let a = Villa3D.Coordinador.acceso, tv = Mall.proveedores, rp: CGFloat = 68
        func arco(_ r: CGFloat, _ desde: CGFloat, _ hasta: CGFloat) -> [CGPoint] {
            let k = max(1, Int(abs(hasta - desde) / 0.05))
            return (0...k).map { i in let t = desde + (hasta - desde) * CGFloat(i) / CGFloat(k); return CGPoint(x: sin(t) * r, y: cos(t) * r) }
        }
        func recta(_ r0: CGFloat, _ r1: CGFloat, lado: CGFloat) -> [CGPoint] {
            let n = Int(abs(r1 - r0) / 8) + 1
            return (0...n).map { eje(r0 + (r1 - r0) * CGFloat($0) / CGFloat(n), lado) }
        }
        func largo(_ pts: [CGPoint]) -> CGFloat { zip(pts, pts.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) } }
        /// Llega por el anillo exterior (r 61), entra de frente a su andén `j`, descarga, sale en retroceso al pasillo y
        /// vuelve por el anillo interior (r 59). Todo avanza en el sentido del anillo: no hay giros en U.
        func anden(_ j: Int) -> (entra: [CGPoint], atras: [CGPoint], sale: [CGPoint], tEntra: CGFloat, tSale: CGFloat) {
            let x = -5.7 + 1.9 + CGFloat(j) * 3.8                    // centro del andén (marco del estacionamiento)
            let m = { (dx: CGFloat, z: CGFloat) in Mall.marco(rp, tv, x + dx, z) }
            let antes = m(-4.5, -6.1), pasa = m(3.5, -4.6)            // entra de frente y se pasa del andén
            let giro = m(0.6, -2.4), dock = m(0, 0.2)                 // retrocede: la puerta trasera queda contra el andén
            let pasillo = m(0, -4.4), despues = m(-4.0, -6.3)        // sale de frente
            return ([antes, pasa], [giro, dock], [pasillo, despues], atan2(antes.x, antes.y) - 0.06, atan2(despues.x, despues.y) - 0.06)
        }
        var rutas: [(ruta: [CGPoint], s: CGFloat, parada: CGFloat, reversa: Set<Int>, color: NSColor)] = []
        for (j, color, s0) in [(0, NSColor(Color(hex: "#b0306a")), CGFloat(0)), (1, NSColor(Color(hex: "#1f6fb2")), 260)] {
            let d = anden(j)
            let ida = recta(242, 63, lado: 1.7) + arco(61, a + 0.03, d.tEntra) + d.entra
            let ruta = ida + d.atras + d.sale + arco(59, d.tSale, a - 0.03) + recta(63, 242, lado: -1.7)
            rutas.append((ruta, s0, largo(ida + d.atras), [ida.count - 1, ida.count], color))
        }
        let d = anden(2), pa = PuertoYFlota.ang
        let p0 = PuertoYFlota.w(12.0, 80), p1 = PuertoYFlota.w(12.0, 64.5)
        let idaP = [p0, p1] + arco(61, pa + atan2(12.0, 61), d.tEntra) + d.entra
        let rutaP = idaP + d.atras + d.sale + arco(59, d.tSale, pa + atan2(12.0, 59)) + [PuertoYFlota.w(12.0, 64.5), PuertoYFlota.w(12.0, 80), PuertoYFlota.w(12.2, 83.5)]
        rutas.append((rutaP, 30, largo(idaP + d.atras), [idaP.count - 1, idaP.count], NSColor(Color(hex: "#d68910"))))
        for r in rutas {
            let v = Vehiculo(camion(r.color, faro: faro, freno: freno), ruta: r.ruta, s: r.s, velocidad: 7, paradas: [(r.parada, 15)],
                             reversa: r.reversa, largo: 4.8, ancho: 2.1, paciente: true)
            v.raiz.scale = SCNVector3(0.75, 0.75, 0.75)   // camión de reparto liviano de 4,8 m y 2,6 m de alto: cabe en los andenes
            vehiculos.append(v)
            escena.rootNode.addChildNode(v.raiz)
        }
    }

    // MARK: Oficina en La nube para los agentes que también trabajan en la nube

    /// Crea su segunda oficina en La nube (en el anillo de oficinas de la placa, puerta hacia el centro) y se la entrega
    /// a la persona, que desde entonces camina entre sus dos oficinas.
    func montarOficinasNube() {
        guard let c = Villa3D.Coordinador.posiciones["nube"], let r = Villa3D.Coordinador.radios["nube"] else { return }
        let extra = Mall.enLaNube(almacen.agentes), ya = almacen.agentes.filter { $0.zona == "nube" }.count
        let n = CGFloat(ya + extra.count), entrada = atan2(-c.y, -c.x)
        for (i, a) in extra.enumerated() where oficinasNube[a.id] == nil {
            guard let p = personas[a.id] else { continue }
            let ang = entrada + (CGFloat(ya + i) + 0.5) / n * .pi * 2, rr = r - 2.3
            let pos = CGPoint(x: c.x + cos(ang) * rr, y: c.y + sin(ang) * rr)
            let of = Oficina(agente: a, pos: pos, yaw: atan2(c.x - pos.x, c.y - pos.y), piso: Nube.alto, zona: almacen.zonas["nube"], nav: nav)
            escena.rootNode.addChildNode(of.raiz)
            oficinasNube[a.id] = of
            p.agregarOficina(of, centro: c, radio: r)
        }
    }

    /// Un agente de la nube trabaja en La nube mientras corre su tarea (desde cada hora programada hasta 25 min después)
    /// o si se lanzó con «Ejecutar ahora» hace menos de 20 min; el resto del tiempo, en su oficina de origen.
    func moverAgentesNube(_ ahora: CFTimeInterval) {
        guard ahora - ultimaNube > 20, !oficinasNube.isEmpty else { return }
        ultimaNube = ahora
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let min = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        for id in oficinasNube.keys {
            var enNube = (min / 20) % 2 == 0
            if let archivo = Mall.archivoNube[id],
               let d = FileManager.default.contents(atPath: Almacen.carpetaLocal + "/trabajo/" + archivo),
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                let horas = (j["horas"] as? [[Int]]) ?? []
                enNube = horas.contains { h in h.count == 2 && (0..<25).contains(min - (h[0] * 60 + h[1])) }
                if let m = (j["ultima_manual"] as? NSNumber)?.doubleValue, Date().timeIntervalSince1970 - m < 20 * 60 { enNube = true }
            }
            personas[id]?.irAOficina(alterna: enNube)
        }
    }
}

// MARK: - Islas (aeropuerto y distrito), costa (caleta, balneario, marina) y el gran letrero «SILICON VILLA»

/// Geometría de las islas nuevas. Marco local de cada una: x tangente (hacia ángulos mayores), z hacia afuera (mar).
enum Islas {
    nonisolated static let angAero: CGFloat = -1.05, rAero: CGFloat = 165, radioAero: CGFloat = 58
    nonisolated static let angDef: CGFloat = 1.1, rDef: CGFloat = 150, radioDef: CGFloat = 40          // Ejército
    nonisolated static let angFA: CGFloat = -0.55, rFA: CGFloat = 222, radioFA: CGFloat = 32           // Fuerza Aérea (junto al aeropuerto)
    nonisolated static let angNav: CGFloat = 0.07, rNav: CGFloat = 140, radioNav: CGFloat = 32         // Armada (junto al puerto)
    nonisolated static let angDist: CGFloat = -1.85, rDist: CGFloat = 152, radioDist: CGFloat = 48
    nonisolated static let angCaleta: CGFloat = -2.95, angBalneario: CGFloat = -2.38, angMarina: CGFloat = -2.64
    nonisolated static let angEner: CGFloat = 2.88, rEner: CGFloat = 203, radioEner: CGFloat = 44     // Isla de Energía y Servicios
    nonisolated static func ener(_ x: CGFloat, _ z: CGFloat) -> CGPoint { w(angEner, rEner, x, z) }
    nonisolated static func polar(_ r: CGFloat, _ a: CGFloat) -> CGPoint { CGPoint(x: sin(a) * r, y: cos(a) * r) }
    nonisolated static func w(_ ang: CGFloat, _ r: CGFloat, _ x: CGFloat, _ z: CGFloat) -> CGPoint {
        CGPoint(x: sin(ang) * (r + z) + cos(ang) * x, y: cos(ang) * (r + z) - sin(ang) * x)
    }
    nonisolated static func aero(_ x: CGFloat, _ z: CGFloat) -> CGPoint { w(angAero, rAero, x, z) }
    nonisolated static func dist(_ x: CGFloat, _ z: CGFloat) -> CGPoint { w(angDist, rDist, x, z) }
    nonisolated static func def(_ x: CGFloat, _ z: CGFloat) -> CGPoint { w(angDef, rDef, x, z) }
    nonisolated static let rCaleta: CGFloat = 118, radioCaleta: CGFloat = 20
    nonisolated static func fa(_ x: CGFloat, _ z: CGFloat) -> CGPoint { w(angFA, rFA, x, z) }
    nonisolated static func naval(_ x: CGFloat, _ z: CGFloat) -> CGPoint { w(angNav, rNav, x, z) }
    /// Punto del mundo expresado en el marco local de una isla (inversa de `w`).
    nonisolated static func local(_ ang: CGFloat, _ r: CGFloat, _ p: CGPoint) -> CGPoint {
        CGPoint(x: cos(ang) * p.x - sin(ang) * p.y, y: sin(ang) * p.x + cos(ang) * p.y - r)
    }
    /// Puente aeropuerto ⇄ base aérea (extremos en el mundo) y su llegada en el marco de la base.
    nonisolated static let puenteFA: (CGPoint, CGPoint) = {
        let a = aero(57.5, 16), c = fa(0, 0), d = hypot(a.x - c.x, a.y - c.y)
        return (a, CGPoint(x: c.x + (a.x - c.x) / d * (radioFA + 1), y: c.y + (a.y - c.y) / d * (radioFA + 1)))
    }()
    nonisolated static let entradaFA: CGPoint = local(angFA, rFA, puenteFA.1)
    nonisolated static func caleta(_ x: CGFloat, _ z: CGFloat) -> CGPoint { w(angCaleta, rCaleta, x, z) }
    /// Barrios de la isla distrito: posición local y radio de su plaza.
    nonisolated static let barrios: [(id: String, x: CGFloat, z: CGFloat, r: CGFloat)] = [
        ("trade", -18, -21, 11), ("casino", 18, -25, 8), ("banco", 19, -9, 7),
        ("uni", -19, 20, 14), ("ciencia", 19, 20, 11), ("museo", 0, 36, 8)]
    nonisolated static let zonas: Set<String> = ["trade", "banco", "casino", "uni", "ciencia", "museo", "aeropuerto", "fach", "armada", "ejercito", "defensa", "comisaria", "gobmar", "energia"]
    /// Barrios sin plaza de adoquines (sus edificios ocupan el suelo).
    nonisolated static let sinPlaza: Set<String> = ["aeropuerto", "fach", "armada", "ejercito", "defensa", "comisaria", "gobmar"]
    nonisolated static let posiciones: [String: CGPoint] = {
        var d = Dictionary(uniqueKeysWithValues: barrios.map { ($0.id, dist($0.x, $0.z)) })
        d["aeropuerto"] = aero(-12, -46); d["fach"] = fa(-12, -22); d["armada"] = naval(10, -22); d["ejercito"] = def(12, -30); d["gobmar"] = w(angNav, 0, 11, 68)
        d["defensa"] = polar(17, 2.86); d["comisaria"] = polar(48, 0.9); d["energia"] = ener(0, -12); return d
    }()
    nonisolated static let radios: [String: CGFloat] = {
        var d = Dictionary(uniqueKeysWithValues: barrios.map { ($0.id, $0.r) }); d["aeropuerto"] = 9
        for k in ["fach", "armada", "ejercito"] { d[k] = 6 }; d["defensa"] = 3.5; d["comisaria"] = 4.5; d["gobmar"] = 4; d["energia"] = 9; return d
    }()
    /// Puentes a las islas: tramo elevado (rampa de subida, tablero a 1,3 m sobre el mar, rampa de bajada).
    nonisolated static let altoPuente: CGFloat = 1.3, rampaPuente: CGFloat = 11
    nonisolated static func tramoPuente(_ hasta: CGFloat) -> (CGFloat, CGFloat) { (75, hasta - 1) }
    nonisolated static let puentes: [(ang: CGFloat, hasta: CGFloat)] = [(angAero, rAero - radioAero + 2), (angDist, rDist - radioDist + 2), (angDef, rDef - radioDef + 2), (angCaleta, rCaleta - radioCaleta + 2), (angNav, rNav - radioNav + 2), (angEner, rEner - radioEner + 2)]
    /// Altura extra de la calzada en un punto (los vehículos suben y bajan por los puentes).
    nonisolated static func alturaPuente(_ p: CGPoint) -> CGFloat {
        for b in puentes {
            let rad = p.x * sin(b.ang) + p.y * cos(b.ang), lat = p.x * cos(b.ang) - p.y * sin(b.ang)
            guard abs(lat) < 5 else { continue }
            let (rA, rB) = tramoPuente(b.hasta)
            let sube = min(rampaPuente, (rB - rA) / 2 - 0.5)
            if rad > rA && rad < rB { return rad < rA + sube ? (rad - rA) / sube * altoPuente : rad > rB - sube ? (rB - rad) / sube * altoPuente : altoPuente }
        }
        let (a, b) = puenteFA, L = hypot(b.x - a.x, b.y - a.y), dx = (b.x - a.x) / L, dz = (b.y - a.y) / L
        let t = (p.x - a.x) * dx + (p.y - a.y) * dz, lat = abs((p.x - a.x) * dz - (p.y - a.y) * dx)
        if lat < 5 && t > 0 && t < L {
            let sube = min(9.5, L / 2 - 0.5)
            return t < sube ? t / sube * altoPuente : t > L - sube ? (L - t) / sube * altoPuente : altoPuente
        }
        return 0
    }
    @MainActor static var buses: [Vehiculo] = []          // se suman al tránsito después de los autos del anillo
    nonisolated static let alturaEtiqueta: [String: CGFloat] = ["trade": 42, "banco": 12, "casino": 27, "uni": 18, "ciencia": 13, "museo": 11, "aeropuerto": 14, "fach": 13, "armada": 12, "ejercito": 10, "defensa": 11, "comisaria": 9, "gobmar": 9, "energia": 13]
    /// Sin árboles ni palmeras: avenidas a las islas, caleta, balneario, marina y letrero.
    nonisolated static func libre(_ p: CGPoint) -> Bool {
        let r = hypot(p.x, p.y), a = atan2(p.x, p.y)
        func cerca(_ b: CGFloat, _ ancho: CGFloat) -> Bool {
            var d = a - b
            while d > .pi { d -= 2 * .pi }; while d < -.pi { d += 2 * .pi }
            return abs(d) * r < ancho
        }
        if r > 56 && (cerca(angAero, 10) || cerca(angDist, 10) || cerca(angDef, 10) || cerca(angNav, 10) || cerca(angEner, 10)) { return false }
        if r > 56 && cerca(angNav + 11 / 68, 6) { return false }
        if r > 56 && cerca(angCaleta, 9) { return false }
        if r > 64 && ( cerca(angBalneario, 18) || cerca(angMarina, 10) || cerca(.pi, 14) || cerca(0.34, 14)) { return false }
        return true
    }
    /// ¿El punto está en alguna isla nueva? Devuelve su barrio para volar a él.
    nonisolated static func barrioDe(_ p: CGPoint) -> String? {
        if hypot(p.x - aero(0, 0).x, p.y - aero(0, 0).y) < radioAero + 4 { return "aeropuerto" }
        if hypot(p.x - def(0, 0).x, p.y - def(0, 0).y) < radioDef + 4 { return "ejercito" }
        if hypot(p.x - fa(0, 0).x, p.y - fa(0, 0).y) < radioFA + 4 { return "fach" }
        if hypot(p.x - naval(0, 0).x, p.y - naval(0, 0).y) < radioNav + 4 { return "armada" }
        if hypot(p.x - ener(0, 0).x, p.y - ener(0, 0).y) < radioEner + 4 { return "energia" }
        let c = dist(0, 0)
        guard hypot(p.x - c.x, p.y - c.y) < radioDist + 4 else { return nil }
        return posiciones.filter { barrios.map(\.id).contains($0.key) }.min { hypot(p.x - $0.value.x, p.y - $0.value.y) < hypot(p.x - $1.value.x, p.y - $1.value.y) }?.key
    }
}

extension Villa3D.Coordinador {
    // MARK: Ayudantes de construcción

    @discardableResult
    private func caja(_ g: SCNNode, _ w: CGFloat, _ h: CGFloat, _ l: CGFloat, _ m: SCNMaterial, x: CGFloat = 0, y: CGFloat? = nil, z: CGFloat = 0,
                      giro: CGFloat = 0, chaflan: CGFloat = 0) -> SCNNode {
        let n = nodo(SCNBox(width: w, height: h, length: l, chamferRadius: chaflan), m, y: y ?? h / 2, x: x, z: z)
        n.eulerAngles.y = giro; g.addChildNode(n); return n
    }

    @discardableResult
    private func cil(_ g: SCNNode, _ r: CGFloat, _ h: CGFloat, _ m: SCNMaterial, x: CGFloat = 0, y: CGFloat? = nil, z: CGFloat = 0) -> SCNNode {
        let n = nodo(SCNCylinder(radius: r, height: h), m, y: y ?? h / 2, x: x, z: z); g.addChildNode(n); return n
    }

    /// Letrero rectangular (cartel con texto) mirando hacia +z local.
    @discardableResult
    private func letrero(_ g: SCNNode, _ texto: String, _ color: String, ancho: CGFloat, alto: CGFloat, x: CGFloat = 0, y: CGFloat, z: CGFloat,
                         giro: CGFloat = 0, brillo: CGFloat = 0.6) -> SCNNode {
        let m = Villa3D.Coordinador.mCartel(texto, NSColor(Color(hex: color)), ancho: max(620, 110 * ancho / alto), brillo: brillo)
        let n = nodo(SCNBox(width: ancho, height: alto, length: 0.08, chamferRadius: 0.02), m, y: y, x: x, z: z)
        n.eulerAngles.y = giro; g.addChildNode(n); return n
    }

    /// Nodo con el marco local de una isla o de la costa: origen en el punto (r, ang), +z hacia afuera.
    private func marcoLocal(_ ang: CGFloat, _ r: CGFloat) -> SCNNode {
        let n = SCNNode(); let p = Islas.polar(r, ang); n.position = SCNVector3(p.x, 0, p.y); n.eulerAngles.y = ang; return n
    }

    private func aplanado(_ g: SCNNode, _ nombre: String?) -> SCNNode {
        Villa3D.Coordinador.hornear(g)
        let p = g.flattenedClone(); p.name = nombre; return p
    }

    private func arbolito(_ g: SCNNode, x: CGFloat, z: CGFloat, alto alto0: CGFloat = 3) {
        let alto = alto0 * 1.7   // copa sobre las cabezas (antes empezaba a 1,2 m)
        let tronco = Mat.textura(.corteza, repetir: 1), copa = Mat.pbr(NSColor(calibratedRed: 0.2, green: 0.45, blue: 0.2, alpha: 1), rugosidad: 0.9)
        cil(g, 0.16, alto * 0.5, tronco, x: x, z: z)
        g.addChildNode(nodo(SCNSphere(radius: alto * 0.33), copa, y: alto * 0.72, x: x, z: z))
    }

    private func palmera(_ g: SCNNode, x: CGFloat, z: CGFloat) {
        let tronco = Mat.textura(.corteza, repetir: 1), hoja = Mat.pbr(NSColor(calibratedRed: 0.2, green: 0.5, blue: 0.22, alpha: 1), rugosidad: 0.8)
        cil(g, 0.14, 4.2, tronco, x: x, z: z)
        for k in 0..<6 {
            let a = CGFloat(k) / 6 * .pi * 2
            let h = nodo(SCNBox(width: 0.4, height: 0.03, length: 2.0, chamferRadius: 0.01), hoja, y: 4.0, x: x + sin(a) * 0.9, z: z + cos(a) * 0.9)
            h.eulerAngles = SCNVector3(0.45, a, 0); g.addChildNode(h)
        }
    }

    // MARK: Avenidas y pedraplenes hacia las islas

    /// Avenida radial desde el anillo (r 61) hasta `hasta`: asfalto en la isla y pedraplén de roca sobre el mar,
    /// con soleras, barandas, faroles y un paradero con rotonda de retorno para el bus.
    private func avenidaIsla(_ r: SCNNode, ang: CGFloat, hasta: CGFloat, nombre: String, color: String) {
        let g = marcoLocal(ang, 0); r.addChildNode(g)
        let asfalto = Mat.pbr(NSColor(calibratedWhite: 0.2, alpha: 1), rugosidad: 0.85), linea = Mat.pbr(NSColor(calibratedWhite: 0.95, alpha: 1))
        let roca = Mat.textura(.adoquin, repetir: 10, tinte: "#8a8478", mezcla: 0.6), solera = Mat.pbr(NSColor(calibratedWhite: 0.75, alpha: 1))
        let poste = Mat.pbr(NSColor(calibratedWhite: 0.15, alpha: 1), rugosidad: 0.4, metal: 0.8)
        let luz = Mat.emisivo(NSColor(calibratedRed: 1, green: 0.88, blue: 0.6, alpha: 1)); focos.append(luz)
        // Tramo en tierra (anillo → borde del pasto) y puente sobre pilotes hasta la isla: el mar pasa por debajo
        let r0: CGFloat = 61, (rA, rB) = Islas.tramoPuente(hasta), alto = Islas.altoPuente, sube = min(Islas.rampaPuente, (rB - rA) / 2 - 0.5)
        let hormigon = Mat.pbr(NSColor(calibratedWhite: 0.72, alpha: 1), rugosidad: 0.7)
        caja(g, 7, 0.06, rA - r0 + 0.3, asfalto, y: 0.03, z: (r0 + rA) / 2)
        var z = r0 + 1.5
        while z < rA - 1 { caja(g, 0.12, 0.02, 1.6, linea, y: 0.07, z: z + 0.8); z += 4 }
        func y(_ z: CGFloat) -> CGFloat { z < rA + sube ? (z - rA) / sube * alto : z > rB - sube ? (rB - z) / sube * alto : alto }
        func losa(_ z0: CGFloat, _ z1: CGFloat) {
            let y0 = y(z0), y1 = y(z1), L = hypot(z1 - z0, y1 - y0), inc = -atan2(y1 - y0, z1 - z0)
            let l = caja(g, 8.2, 0.45, L + 0.05, hormigon, y: (y0 + y1) / 2 - 0.2, z: (z0 + z1) / 2); l.eulerAngles.x = inc
            let a = caja(g, 7, 0.05, L + 0.05, asfalto, y: (y0 + y1) / 2 + 0.04, z: (z0 + z1) / 2); a.eulerAngles.x = inc
            for lado: CGFloat in [-1, 1] {
                let b = caja(g, 0.08, 0.08, L + 0.05, poste, x: lado * 4.0, y: (y0 + y1) / 2 + 0.95, z: (z0 + z1) / 2); b.eulerAngles.x = inc
                let s = caja(g, 0.3, 0.16, L + 0.05, solera, x: lado * 3.65, y: (y0 + y1) / 2 + 0.1, z: (z0 + z1) / 2); s.eulerAngles.x = inc
            }
        }
        losa(rA, rA + sube); losa(rA + sube, rB - sube); losa(rB - sube, rB)
        z = rA + sube + 2
        while z < rB - sube - 1 { caja(g, 0.12, 0.02, 1.6, linea, y: alto + 0.08, z: z); z += 4 }
        // Pilotes (de a pares) cada 8 m bajo el agua, postes de baranda y faroles
        z = rA + 6
        while z < rB - 3 {
            let h = y(z) + 3.2
            for lado: CGFloat in [-1, 1] { cil(g, 0.32, h, hormigon, x: lado * 2.6, y: y(z) - 0.42 - h / 2, z: z) }
            caja(g, 6.4, 0.5, 0.7, hormigon, y: y(z) - 0.5, z: z)
            z += 8
        }
        for lado: CGFloat in [-1, 1] {
            var zp = rA + 1
            while zp < rB - 1 {
                caja(g, 0.08, 0.9, 0.08, poste, x: lado * 4.0, y: y(zp) + 0.5, z: zp)
                if Int(zp) % 12 < 3 {
                    cil(g, 0.07, 4.2, poste, x: lado * 3.9, y: y(zp) + 2.1, z: zp)
                    g.addChildNode(nodo(SCNSphere(radius: 0.22), luz, y: y(zp) + 4.3, x: lado * 3.9, z: zp))
                }
                zp += 3
            }
        }
        _ = roca
        // Paradero con rotonda de retorno (el bus da la vuelta aquí, sin entrar al anillo)
        g.addChildNode(nodo(SCNTube(innerRadius: 1.6, outerRadius: 5.6, height: 0.06), asfalto, y: 0.031, z: 67))
        cil(g, 1.5, 0.3, Mat.pbr(NSColor(calibratedRed: 0.25, green: 0.5, blue: 0.22, alpha: 1)), y: 0.15, z: 67)
        let lp: CGFloat = ang == Islas.angEner ? 9.5 : -9.5      // en la Isla de Energía, al otro lado: a la izquierda pasan los camiones del mall
        let refugio = SCNNode(); refugio.position = SCNVector3(lp, 0, 67); refugio.eulerAngles.y = lp < 0 ? .pi / 2 : -.pi / 2; g.addChildNode(refugio)
        caja(refugio, 3.2, 0.1, 1.4, Mat.pbr(NSColor(Color(hex: color)), rugosidad: 0.5), y: 2.4)
        for x: CGFloat in [-1.5, 1.5] { caja(refugio, 0.08, 2.4, 0.08, poste, x: x, z: -0.6) }
        caja(refugio, 3.0, 2.0, 0.05, Mat.pbr(NSColor(Color(hex: "#bfe3f5")), rugosidad: 0.1), y: 1.2, z: -0.65)
        letrero(refugio, "PARADERO · \(nombre)", color, ancho: 3.0, alto: 0.45, y: 2.75, z: 0.72)
        nav.rect(Islas.w(ang, 0, lp, 67).x, Islas.w(ang, 0, lp, 67).y, 0.8, 1.7, ang)
    }

    /// Bus de enlace: carrocería, ventanas, letrero y ruedas (proa en +z).
    private func bus(_ color: NSColor, _ texto: String, faro: SCNMaterial, freno: SCNMaterial) -> SCNNode {
        if let m = Modelos.nodo("bus", largo: 8.2, nombreElem: "elem:bus") {
            let cartel = Villa3D.Coordinador.mCartel(texto, color, ancho: 900, brillo: 0.5)
            for x: CGFloat in [-1.23, 1.23] {   // franja con el nombre de la ruta y faros que se encienden de noche
                let l = nodo(SCNPlane(width: 4.6, height: 0.42), cartel, y: 0.95, x: x, z: -0.2); l.eulerAngles.y = x > 0 ? .pi / 2 : -.pi / 2; m.addChildNode(l)
            }
            for x: CGFloat in [-0.8, 0.8] {
                caja(m, 0.3, 0.2, 0.05, faro, x: x, y: 0.75, z: 3.82)
                caja(m, 0.25, 0.18, 0.05, freno, x: x, y: 0.75, z: -3.82)
            }
            return m
        }
        let n = SCNNode()
        let pintura = Mat.pbr(color, rugosidad: 0.35, metal: 0.3), vidrio = Mat.pbr(NSColor(Color(hex: "#26394d")), rugosidad: 0.1, metal: 0.5)
        let goma = Mat.pbr(NSColor(calibratedWhite: 0.07, alpha: 1), rugosidad: 0.9)
        caja(n, 2.4, 2.6, 7.6, pintura, y: 1.75, chaflan: 0.2)
        for x: CGFloat in [-1.22, 1.22] { caja(n, 0.04, 0.9, 6.2, vidrio, x: x, y: 2.3, z: -0.3) }
        caja(n, 2.1, 1.0, 0.05, vidrio, y: 2.3, z: 3.81)
        let cartel = Villa3D.Coordinador.mCartel(texto, color, ancho: 900, brillo: 0.5)
        for x: CGFloat in [-1.23, 1.23] {
            let l = nodo(SCNPlane(width: 4.6, height: 0.5), cartel, y: 1.25, x: x, z: -0.2); l.eulerAngles.y = x > 0 ? .pi / 2 : -.pi / 2; n.addChildNode(l)
        }
        for z: CGFloat in [2.6, -2.4] { for x: CGFloat in [-1.1, 1.1] {
            let rueda = nodo(SCNCylinder(radius: 0.48, height: 0.32), goma, y: 0.48, x: x, z: z); rueda.eulerAngles.z = .pi / 2; n.addChildNode(rueda)
        } }
        for x: CGFloat in [-0.8, 0.8] {
            caja(n, 0.3, 0.2, 0.05, faro, x: x, y: 0.9, z: 3.82)
            caja(n, 0.25, 0.18, 0.05, freno, x: x, y: 0.9, z: -3.82)
        }
        return aplanado(n, "elem:bus")
    }

    /// Ruta del bus: paradero de la villa (rotonda r 67) ⇄ por el carril derecho ⇄ vuelta en la isla.
    private func rutaBus(ang: CGFloat, enIsla: [CGPoint]) -> [CGPoint] {
        func p(_ x: CGFloat, _ z: CGFloat) -> CGPoint { Islas.w(ang, 0, x, z) }
        var ida: [CGPoint] = [], vuelta: [CGPoint] = []
        var z: CGFloat = 72
        while z < 100 { ida.append(p(1.7, z)); z += 8 }
        z = 100
        while z > 72 { vuelta.append(p(-1.7, z)); z -= 8 }
        // Rotonda del paradero (radio 3,6 alrededor de r 67), en sentido antihorario visto desde arriba
        var rotonda: [CGPoint] = []
        for k in 0...10 {                     // entra por el carril de vuelta (x −1,7) y sale al de ida (x +1,7)
            let t = 2.0 + CGFloat(k) / 10 * (2 * .pi - 0.86)
            rotonda.append(p(cos(t) * 3.6, 67 + sin(t) * 3.6))
        }
        return ida + enIsla + vuelta + rotonda
    }

    // MARK: Montaje general

    func montarIslas(_ r: SCNNode) {
        let pasto = Mat.textura(.pasto, repetir: 14), arena = Mat.textura(.arena, repetir: 12)
        for (c, rad) in [(Islas.aero(0, 0), Islas.radioAero), (Islas.dist(0, 0), Islas.radioDist), (Islas.def(0, 0), Islas.radioDef), (Islas.caleta(0, 0), Islas.radioCaleta), (Islas.fa(0, 0), Islas.radioFA), (Islas.naval(0, 0), Islas.radioNav), (Islas.ener(0, 0), Islas.radioEner)] {
            playaNatural(centro: c, desde: rad + 1, ancho: 8)
            r.addChildNode(nodo(SCNCylinder(radius: rad, height: 0.5), pasto, y: -0.24, x: c.x, z: c.y))
            nav.anillo(c.x, c.y, rad + 1.5, hueco: 0, ancho: 0)
        }
        avenidaIsla(r, ang: Islas.angAero, hasta: Islas.rAero - Islas.radioAero + 2, nombre: "AEROPUERTO", color: "#1f6fb2")
        avenidaIsla(r, ang: Islas.angDist, hasta: Islas.rDist - Islas.radioDist + 2, nombre: "ISLA DISTRITO", color: "#6c3483")
        avenidaIsla(r, ang: Islas.angDef, hasta: Islas.rDef - Islas.radioDef + 2, nombre: "REGIMIENTO", color: "#4b5a33")
        avenidaIsla(r, ang: Islas.angNav, hasta: Islas.rNav - Islas.radioNav + 2, nombre: "BASE NAVAL", color: "#1a3d5c")
        avenidaIsla(r, ang: Islas.angEner, hasta: Islas.rEner - Islas.radioEner + 2, nombre: "ISLA DE ENERGÍA", color: "#c27c0e")
        puenteRecto(r, Islas.puenteFA.0, Islas.puenteFA.1)
        avenidaIsla(r, ang: Islas.angCaleta, hasta: Islas.rCaleta - Islas.radioCaleta + 2, nombre: "CALETA", color: "#1f6fb2")
        montarAeropuerto(r)
        montarDistrito(r)
        montarGastronomia(r)
        montarEjercito(r)
        montarFuerzaAerea(r)
        montarArmada(r)
        montarMinisterioYComisaria(r)
        montarEnergia(r)
        montarCaleta(r)
        montarBalneario(r)
        montarMarina(r)
        montarLetreroVilla(r)
    }

    // MARK: Aeropuerto

    private func largoRuta(_ pts: [CGPoint], hasta k: Int) -> CGFloat {
        var s: CGFloat = 0
        for i in 0..<min(k, pts.count - 1) { s += hypot(pts[i + 1].x - pts[i].x, pts[i + 1].y - pts[i].y) }
        return s
    }

    /// Avión de pasajeros (proa en +z): fuselaje, alas, motores, cola, ventanillas y luces de navegación.
    private func avion(_ color: NSColor, escala: CGFloat) -> SCNNode {
        if let m = Modelos.nodo("avion", largo: 14, nombreElem: "elem:avion") {
            for lado: CGFloat in [-1, 1] {   // luces de navegación: roja a babor (+x), verde a estribor
                m.addChildNode(nodo(SCNSphere(radius: 0.1), Mat.emisivo(lado > 0 ? .systemRed : .systemGreen, fuerza: 1.5), y: 1.5, x: lado * 6.5, z: -1.1))
            }
            let baliza = nodo(SCNSphere(radius: 0.12), Mat.emisivo(.systemRed, fuerza: 2), y: 4.55, z: -6.3)
            baliza.runAction(.repeatForever(.sequence([.fadeOpacity(to: 0.1, duration: 0.6), .fadeOpacity(to: 1, duration: 0.15)])))
            m.addChildNode(baliza)
            m.scale = SCNVector3(escala * 0.72, escala * 0.72, escala * 0.72)
            return m
        }
        let n = SCNNode()
        let blanco = Mat.pbr(NSColor(calibratedWhite: 0.97, alpha: 1), rugosidad: 0.22, metal: 0.25), pintura = Mat.pbr(color, rugosidad: 0.3, metal: 0.3)
        let gris = Mat.pbr(NSColor(calibratedWhite: 0.62, alpha: 1), rugosidad: 0.3, metal: 0.75), negro = Mat.pbr(NSColor(calibratedWhite: 0.06, alpha: 1), rugosidad: 0.1, metal: 0.4)
        let vientre = Mat.pbr(NSColor(calibratedWhite: 0.82, alpha: 1), rugosidad: 0.3, metal: 0.3)
        // Fuselaje: cilindro con nariz redondeada y cono de cola levantado
        let fus = nodo(SCNCylinder(radius: 0.95, height: 9.4), blanco, y: 2.0, z: 0.3); fus.eulerAngles.x = .pi / 2; n.addChildNode(fus)
        let nariz = nodo(SCNSphere(radius: 0.95), blanco, y: 2.0, z: 5.0); nariz.scale = SCNVector3(1, 0.96, 1.55); n.addChildNode(nariz)
        let cola = nodo(SCNCone(topRadius: 0.22, bottomRadius: 0.95, height: 3.4), blanco, y: 2.25, z: -6.1); cola.eulerAngles.x = -.pi / 2 - 0.12; n.addChildNode(cola)
        let panza = nodo(SCNCylinder(radius: 0.9, height: 8.6), vientre, y: 1.86, z: 0.3); panza.eulerAngles.x = .pi / 2; panza.scale = SCNVector3(1.02, 0.6, 1); n.addChildNode(panza)
        // Franja de la aerolínea, fila de ventanillas y cabina
        for lado: CGFloat in [-1, 1] {
            caja(n, 0.04, 0.3, 9.2, pintura, x: lado * 0.95, y: 1.75, z: 0.2)
            var z: CGFloat = 3.6
            while z > -4.2 { caja(n, 0.03, 0.17, 0.2, negro, x: lado * 0.955, y: 2.32, z: z); z -= 0.45 }
            let cab = caja(n, 0.03, 0.22, 0.55, negro, x: lado * 0.7, y: 2.4, z: 5.45); cab.eulerAngles.y = lado * 0.45
        }
        // Alas en flecha con winglets, motores con toma de aire y luces
        for lado: CGFloat in [-1, 1] {
            let ala = NSBezierPath(); ala.move(to: NSPoint(x: 0, y: 1.6)); ala.line(to: NSPoint(x: lado * 6.0, y: -1.4)); ala.line(to: NSPoint(x: lado * 6.0, y: -2.2))
            ala.line(to: NSPoint(x: 0, y: -0.9)); ala.close()
            let a = nodo(SCNShape(path: ala, extrusionDepth: 0.14), blanco, y: 1.55, z: 0.2); a.eulerAngles = SCNVector3(CGFloat.pi / 2, 0, lado * 0.05); n.addChildNode(a)
            caja(n, 0.08, 0.7, 0.7, pintura, x: lado * 6.0, y: 1.9, z: -1.5)
            let motor = nodo(SCNCylinder(radius: 0.46, height: 1.9), gris, y: 1.0, x: lado * 2.5, z: 1.6); motor.eulerAngles.x = .pi / 2; n.addChildNode(motor)
            let toma = nodo(SCNCylinder(radius: 0.38, height: 0.05), negro, y: 1.0, x: lado * 2.5, z: 2.56); toma.eulerAngles.x = .pi / 2; n.addChildNode(toma)
            caja(n, 0.12, 0.5, 0.9, gris, x: lado * 2.5, y: 1.42, z: 1.4)
            let est = NSBezierPath(); est.move(to: NSPoint(x: 0, y: 0.6)); est.line(to: NSPoint(x: lado * 2.4, y: -0.6)); est.line(to: NSPoint(x: lado * 2.4, y: -1.0)); est.line(to: NSPoint(x: 0, y: -0.5)); est.close()
            let e = nodo(SCNShape(path: est, extrusionDepth: 0.08), blanco, y: 2.5, z: -6.6); e.eulerAngles.x = .pi / 2; n.addChildNode(e)
            n.addChildNode(nodo(SCNSphere(radius: 0.1), Mat.emisivo(lado > 0 ? .systemRed : .systemGreen, fuerza: 1.5), y: 1.6, x: lado * 6.05, z: -1.8))
        }
        let deriva = NSBezierPath(); deriva.move(to: NSPoint(x: 0, y: 0)); deriva.line(to: NSPoint(x: -2.4, y: 0)); deriva.line(to: NSPoint(x: -3.2, y: 2.6)); deriva.line(to: NSPoint(x: -2.3, y: 2.6)); deriva.close()
        let d = nodo(SCNShape(path: deriva, extrusionDepth: 0.14), pintura, y: 2.6, z: -5.2); d.eulerAngles.y = -.pi / 2; n.addChildNode(d)
        // Tren de aterrizaje con ruedas
        let goma = Mat.pbr(NSColor(calibratedWhite: 0.07, alpha: 1), rugosidad: 0.9)
        for (x, z) in [(CGFloat(0), CGFloat(4.4)), (-0.75, -0.3), (0.75, -0.3)] {
            cil(n, 0.06, 0.9, gris, x: x, y: 0.75, z: z)
            for dx: CGFloat in [-0.14, 0.14] { let r = nodo(SCNCylinder(radius: 0.28, height: 0.18), goma, y: 0.3, x: x + dx, z: z); r.eulerAngles.z = .pi / 2; n.addChildNode(r) }
        }
        let baliza = nodo(SCNSphere(radius: 0.12), Mat.emisivo(.systemRed, fuerza: 2), y: 5.25, z: -7.4)
        baliza.runAction(.repeatForever(.sequence([.fadeOpacity(to: 0.1, duration: 0.6), .fadeOpacity(to: 1, duration: 0.15)])))
        let p = aplanado(n, "elem:avion")
        p.addChildNode(baliza)
        p.scale = SCNVector3(escala * 0.72, escala * 0.72, escala * 0.72)
        return p
    }

    private func ubicarAvion(_ n: SCNNode, _ x: CGFloat, _ z: CGFloat, _ y: CGFloat, rumbo: CGFloat) {
        let p = Islas.aero(x, z)
        n.position = SCNVector3(p.x, y + 0.04, p.y); n.eulerAngles.y = Islas.angAero + rumbo
    }

    // MARK: Isla distrito: Trade Center, banco, casino, universidad, centro científico y museo

    private func montarDistrito(_ r: SCNNode) {
        let D = marcoLocal(Islas.angDist, Islas.rDist); r.addChildNode(D)
        let asfalto = Mat.pbr(NSColor(calibratedWhite: 0.2, alpha: 1), rugosidad: 0.85), linea = Mat.pbr(NSColor(calibratedWhite: 0.95, alpha: 1))
        let vereda = Mat.textura(.adoquin, repetir: 8, tinte: "#d8cfc0", mezcla: 0.4)
        let poste = Mat.pbr(NSColor(calibratedWhite: 0.15, alpha: 1), rugosidad: 0.4, metal: 0.8)
        let luz = Mat.emisivo(NSColor(calibratedRed: 1, green: 0.88, blue: 0.6, alpha: 1)); focos.append(luz)
        // Avenida central, rotonda con pileta, calle transversal y avenida al museo
        caja(D, 7, 0.06, 43, asfalto, y: 0.03, z: -30.5)
        caja(D, 7, 0.06, 15, asfalto, y: 0.03, z: 19.5)
        for lado: CGFloat in [-1, 1] { caja(D, 30, 0.06, 6, asfalto, x: lado * 25, y: 0.03, z: 2) }
        D.addChildNode(nodo(SCNTube(innerRadius: 3.6, outerRadius: 10.4, height: 0.06), asfalto, y: 0.031, z: 2))
        cil(D, 3.4, 0.7, Mat.textura(.marmol, repetir: 2), y: 0.35, z: 2)
        cil(D, 3.0, 0.1, Mat.pbr(NSColor(calibratedRed: 0.22, green: 0.55, blue: 0.72, alpha: 1), rugosidad: 0.05, metal: 0.2), y: 0.68, z: 2)
        cil(D, 0.35, 2.6, Mat.textura(.marmol, repetir: 1), y: 1.3, z: 2)
        D.addChildNode(nodo(SCNSphere(radius: 0.8), Mat.pbr(NSColor(Color(hex: "#c9a227")), rugosidad: 0.25, metal: 0.9), y: 3.2, z: 2))
        nav.circulo(Islas.dist(0, 2).x, Islas.dist(0, 2).y, 3.0)
        var z: CGFloat = -50
        while z < -10 { caja(D, 0.12, 0.02, 1.6, linea, y: 0.07, z: z); z += 4 }
        for lado: CGFloat in [-1, 1] {
            caja(D, 2.2, 0.08, 40, vereda, x: lado * 4.6, y: 0.04, z: -30)
            var zf: CGFloat = -46
            while zf < -12 {
                cil(D, 0.07, 4.2, poste, x: lado * 4.4, z: zf)
                D.addChildNode(nodo(SCNSphere(radius: 0.22), luz, y: 4.3, x: lado * 4.4, z: zf))
                nav.circulo(Islas.dist(lado * 4.4, zf).x, Islas.dist(lado * 4.4, zf).y, 0.12)
                zf += 9
            }
        }
        // Árboles y palmeras del distrito, lejos de calles y barrios
        var azar = Azar(semilla: 41)
        for _ in 0..<70 {
            let a = azar.real() * .pi * 2, rr = 8 + azar.real() * 38
            let x = sin(a) * rr, zz = cos(a) * rr
            if abs(x) < 6 || abs(zz - 2) < 5 && abs(x) < 42 || hypot(x, zz - 2) < 12 { continue }
            if Islas.barrios.contains(where: { hypot(x - $0.x, zz - $0.z) < $0.r + 2 }) { continue }
            if hypot(x - 34, zz + 14) < 10 || hypot(x + 33, zz + 10) < 8 || hypot(x - 38, zz - 12) < 9 { continue }   // restaurante, café e iglesia
            if rr > 40 { palmera(D, x: x, z: zz) } else { arbolito(D, x: x, z: zz, alto: 2.6 + azar.real() * 1.6) }
            nav.circulo(Islas.dist(x, zz).x, Islas.dist(x, zz).y, 0.3)
        }
        // Cada barrio, en su plaza, con el frente hacia la villa
        for b in Islas.barrios {
            let c = Islas.dist(b.x, b.z), yaw = b.id == "banco" ? Islas.angDist : atan2(-c.x, -c.y)    // el banco mira a la calle
            let B = SCNNode(); B.position = SCNVector3(c.x, 0.12, c.y); B.eulerAngles.y = yaw
            func navLocal(_ x: CGFloat, _ z: CGFloat, _ hx: CGFloat, _ hz: CGFloat) {
                nav.rect(c.x + x * cos(yaw) + z * sin(yaw), c.y - x * sin(yaw) + z * cos(yaw), hx, hz, yaw)
            }
            switch b.id {
            case "trade": tradeCenter(B, navLocal)
            case "banco": banco(B, navLocal)
            case "casino": casino(B, navLocal)
            case "uni": universidad(B, navLocal)
            case "ciencia": centroCientifico(B, navLocal)
            default: museo(B, navLocal)
            }
            escena.rootNode.addChildNode(aplanado(B, nil))
        }
        escena.rootNode.addChildNode(aplanado(D, nil))
        D.removeFromParentNode()
        // Bus de enlace villa ⇄ isla distrito: entra por la avenida, da la vuelta en la rotonda y regresa
        let faro = Mat.emisivo(NSColor(calibratedRed: 1, green: 0.97, blue: 0.85, alpha: 1)); focos.append(faro)
        func pd(_ x: CGFloat, _ z: CGFloat) -> CGPoint { Islas.dist(x, z) }
        var enIsla = [pd(1.7, -44), pd(1.7, -30), pd(1.7, -14)]
        for k in 0...14 {                     // vuelta a la rotonda (radio 7) alrededor de la pileta
            let u = -1.32 + CGFloat(k) / 14 * 5.78
            enIsla.append(pd(cos(u) * 7.0, 2 + sin(u) * 7.0))
        }
        enIsla += [pd(-1.7, -14), pd(-1.7, -30), pd(-1.7, -44)]
        let ruta = rutaBus(ang: Islas.angDist, enIsla: enIsla)
        let v = Vehiculo(bus(NSColor(Color(hex: "#6c3483")), "BUS ISLA DISTRITO", faro: faro, freno: Mat.emisivo(.systemRed, fuerza: 0.8)), ruta: ruta, s: 60,
                         velocidad: 8, paradas: [(largoRuta(ruta, hasta: 5), 10)], largo: 8.2, ancho: 2.4, paciente: true)
        v.raiz.scale = SCNVector3(1, 1, 1)
        Islas.buses.append(v); escena.rootNode.addChildNode(v.raiz)
    }

    // MARK: Restaurante y cafetería gourmet, iglesia y vida nocturna (isla distrito, junto a la calle transversal)

    /// Restaurante «El Mirador» (34, −12), Café del Valle (−33, −8) e Iglesia de la Villa (37, 11), en el marco local del distrito.
    private func montarGastronomia(_ r: SCNNode) {
        func navL(_ x: CGFloat, _ z: CGFloat, _ hx: CGFloat, _ hz: CGFloat, linea: Int = #line) { let q = Islas.dist(x, z); nav.rect(q.x, q.y, hx, hz, Islas.angDist, linea: linea) }
        let marmol = Mat.textura(.marmol, repetir: 2), oro = Mat.pbr(NSColor(Color(hex: "#c9a227")), rugosidad: 0.25, metal: 0.9)
        let negro = Mat.pbr(NSColor(calibratedWhite: 0.08, alpha: 1), rugosidad: 0.35, metal: 0.3), verde = Mat.pbr(NSColor(Color(hex: "#2e6b3a")), rugosidad: 0.8)
        let mantel = Mat.pbr(NSColor(calibratedWhite: 0.98, alpha: 1), rugosidad: 0.8)
        let vela = Mat.emisivo(NSColor(calibratedRed: 1, green: 0.78, blue: 0.42, alpha: 1), fuerza: 1.4); focos.append(vela)
        let ampolleta = Mat.emisivo(NSColor(calibratedRed: 1, green: 0.86, blue: 0.6, alpha: 1), fuerza: 1.6); focos.append(ampolleta)
        func mesa(_ g: SCNNode, _ x: CGFloat, _ z: CGFloat, y: CGFloat, mantelito: SCNMaterial, silla: SCNMaterial, n: Int) {
            cil(g, 0.05, 0.75, negro, x: x, y: y + 0.375, z: z)
            cil(g, 0.55, 0.04, mantelito, x: x, y: y + 0.77, z: z)
            cil(g, 0.035, 0.12, vela, x: x, y: y + 0.85, z: z)
            for k in 0..<n {
                let a = CGFloat(k) / CGFloat(n) * 2 * .pi
                caja(g, 0.42, 0.06, 0.42, silla, x: x + sin(a) * 0.85, y: y + 0.46, z: z + cos(a) * 0.85, giro: a)
                caja(g, 0.42, 0.5, 0.05, silla, x: x + sin(a) * 1.06, y: y + 0.72, z: z + cos(a) * 1.06, giro: a)
                cil(g, 0.03, 0.44, negro, x: x + sin(a) * 0.85, y: y + 0.22, z: z + cos(a) * 0.85)
            }
        }
        func macetero(_ g: SCNNode, _ x: CGFloat, _ z: CGFloat, y: CGFloat) {
            cil(g, 0.32, 0.55, marmol, x: x, y: y + 0.275, z: z)
            g.addChildNode(nodo(SCNSphere(radius: 0.42), verde, y: y + 0.95, x: x, z: z))
        }

        // Restaurante gourmet: podio de mármol, fachada grafito con ventanales y montantes dorados, toldo, alfombra y terraza con pérgola iluminada
        let R = marcoLocal(Islas.angDist, Islas.rDist); r.addChildNode(R)
        let rx: CGFloat = 34
        let Rk = SCNNode(); Rk.position = SCNVector3(2 * rx, 0, -24); Rk.eulerAngles.y = .pi; R.addChildNode(Rk)   // fachada y terraza hacia la villa
        caja(Rk, 13, 0.3, 12.5, marmol, x: rx, y: 0.15, z: -9.8)
        caja(Rk, 12, 4.6, 7, Mat.textura(.estuco, repetir: 3, tinte: "#33393d"), x: rx, y: 2.6, z: -12)
        caja(Rk, 10.4, 3.0, 0.06, ventana(), x: rx, y: 2.0, z: -8.47)
        for x in stride(from: rx - 5.2, through: rx + 5.2, by: 1.3) { caja(Rk, 0.08, 3.0, 0.1, oro, x: x, y: 2.0, z: -8.43) }
        for lado: CGFloat in [-1, 1] { caja(Rk, 0.06, 2.4, 5.6, ventana(), x: rx + lado * 6.03, y: 2.4, z: -12) }
        caja(Rk, 10, 1.6, 0.06, ventana(), x: rx, y: 2.8, z: -15.53)
        caja(Rk, 12.6, 0.3, 7.6, oro, x: rx, y: 5.05, z: -12)
        caja(Rk, 12.2, 0.2, 7.2, negro, x: rx, y: 5.3, z: -12)
        caja(Rk, 3.2, 0.12, 2.4, negro, x: rx, y: 3.75, z: -7.3)
        for lado: CGFloat in [-1, 1] { cil(Rk, 0.05, 3.45, oro, x: rx + lado * 1.5, y: 2.02, z: -6.2) }
        caja(Rk, 1.4, 0.02, 4.6, Mat.pbr(NSColor(Color(hex: "#8b1a1a")), rugosidad: 0.95), x: rx, y: 0.31, z: -6.2)
        letrero(Rk, "RESTAURANTE GOURMET · EL MIRADOR", "#14181b", ancho: 8, alto: 0.7, x: rx, y: 4.3, z: -8.42, brillo: 0.9)
        for (x, z) in [(rx - 5.8, CGFloat(-8.2)), (rx + 5.8, -8.2), (rx - 5.8, -4.0), (rx + 5.8, -4.0)] { cil(Rk, 0.07, 3.0, negro, x: x, y: 1.8, z: z) }
        for z: CGFloat in [-8.2, -4.0] { caja(Rk, 11.8, 0.1, 0.1, negro, x: rx, y: 3.3, z: z) }
        for x in stride(from: rx - 5.4, through: rx + 5.4, by: 0.9) {
            for z: CGFloat in [-7.4, -5.8, -4.6] { Rk.addChildNode(nodo(SCNSphere(radius: 0.07), ampolleta, y: 3.15, x: x, z: z)) }
        }
        for lado: CGFloat in [-1, 1] { mesa(Rk, rx + lado * 3.6, -5.8, y: 0.3, mantelito: mantel, silla: negro, n: 4) }
        for (x, z) in [(rx - 6, CGFloat(-3.8)), (rx + 6, -3.8), (rx - 1.2, -3.8), (rx + 1.2, -3.8)] { macetero(Rk, x, z, y: 0.3) }
        navL(rx, -12, 6.2, 3.7); for lado: CGFloat in [-1, 1] { navL(rx + lado * 3.6, -18.2, 1.2, 1.2) }
        escena.rootNode.addChildNode(aplanado(R, "elem:restaurante")); R.removeFromParentNode()

        // Cafetería gourmet: fachada crema, toldo a rayas verde y negro, gran taza dorada en el techo y terraza con quitasoles
        let C = marcoLocal(Islas.angDist, Islas.rDist); r.addChildNode(C)
        let cx: CGFloat = -33
        let Ck = SCNNode(); Ck.position = SCNVector3(2 * cx, 0, -16); Ck.eulerAngles.y = .pi; C.addChildNode(Ck)   // fachada y terraza hacia la villa
        caja(Ck, 9, 0.3, 8.5, marmol, x: cx, y: 0.15, z: -6.75)
        caja(Ck, 8, 3.4, 5, Mat.textura(.estuco, repetir: 2, tinte: "#efe6d8"), x: cx, y: 2.0, z: -8)
        caja(Ck, 6.8, 2.2, 0.06, ventana(), x: cx, y: 1.75, z: -5.47)
        for lado: CGFloat in [-1, 1] { caja(Ck, 0.06, 1.8, 3.6, ventana(), x: cx + lado * 4.03, y: 1.9, z: -8) }
        caja(Ck, 8.4, 0.25, 5.4, Mat.pbr(NSColor(Color(hex: "#1e3d2f")), rugosidad: 0.5), x: cx, y: 3.8, z: -8)
        for k in 0..<8 {
            let franja = caja(Ck, 1.0, 0.06, 1.6, k % 2 == 0 ? Mat.pbr(NSColor(Color(hex: "#1e3d2f")), rugosidad: 0.8) : Mat.pbr(NSColor(calibratedWhite: 0.95, alpha: 1), rugosidad: 0.8),
                              x: cx - 3.5 + CGFloat(k), y: 3.0, z: -4.75)
            franja.eulerAngles.x = 0.35
        }
        letrero(Ck, "CAFETERÍA GOURMET · CAFÉ DEL VALLE", "#1e3d2f", ancho: 6.4, alto: 0.55, x: cx, y: 3.45, z: -5.42, brillo: 0.9)
        cil(Ck, 0.75, 0.9, oro, x: cx, y: 4.4, z: -8)
        let asa = nodo(SCNTorus(ringRadius: 0.32, pipeRadius: 0.08), oro, y: 4.45, x: cx + 0.85, z: -8); asa.eulerAngles.x = .pi / 2; Ck.addChildNode(asa)
        cil(Ck, 1.0, 0.06, oro, x: cx, y: 3.95, z: -8)
        for k in 0..<3 { let v = nodo(SCNCapsule(capRadius: 0.06, height: 0.5), Mat.pbr(NSColor(calibratedWhite: 1, alpha: 1)), y: 5.2 + CGFloat(k) * 0.12, x: cx - 0.3 + CGFloat(k) * 0.3, z: -8)
            v.opacity = 0.55; v.runAction(.repeatForever(.sequence([.moveBy(x: 0, y: 0.25, z: 0, duration: 1.4 + Double(k) * 0.3), .moveBy(x: 0, y: -0.25, z: 0, duration: 0)]))); Ck.addChildNode(v) }
        let crema = Mat.pbr(NSColor(Color(hex: "#f3ead9")), rugosidad: 0.8), madera = Mat.textura(.madera, repetir: 1, tinte: "#6b4a2f")
        for lado: CGFloat in [-1, 1] {
            mesa(Ck, cx + lado * 2.4, -3.6, y: 0.3, mantelito: marmol, silla: madera, n: 2)
            cil(Ck, 0.04, 2.4, negro, x: cx + lado * 2.4, y: 1.5, z: -3.6)
            Ck.addChildNode(nodo(SCNCone(topRadius: 0.05, bottomRadius: 1.5, height: 0.5), crema, y: 2.8, x: cx + lado * 2.4, z: -3.6))
        }
        for (x, z) in [(cx - 4.2, CGFloat(-2.8)), (cx + 4.2, -2.8)] { macetero(Ck, x, z, y: 0.3) }
        navL(cx, -8, 4.2, 2.7); for lado: CGFloat in [-1, 1] { navL(cx + lado * 2.4, -12.4, 0.9, 1.1) }
        escena.rootNode.addChildNode(aplanado(C, "elem:cafeteria")); C.removeFromParentNode()

        // Iglesia de la Villa: nave con techo a dos aguas, campanario con aguja y cruz, rosetón y vitrales que brillan de noche,
        // jardín de meditación con bancas detrás (relax y consejos de vida)
        let I = marcoLocal(Islas.angDist, Islas.rDist); r.addChildNode(I)
        let ix: CGFloat = 37, piedra = Mat.textura(.estuco, repetir: 3, tinte: "#e9e2d3"), teja = Mat.pbr(NSColor(Color(hex: "#7a3b2e")), rugosidad: 0.8)
        caja(I, 6, 5, 8, piedra, x: ix, y: 2.5, z: 11.5)
        for lado: CGFloat in [-1, 1] { let t = caja(I, 3.6, 0.18, 8.4, teja, x: ix + lado * 1.55, y: 5.95, z: 11.5); t.eulerAngles.z = -lado * 0.58 }
        caja(I, 0.3, 2.0, 0.2, piedra, x: ix, y: 6, z: 7.45)
        let tri = NSBezierPath(); tri.move(to: NSPoint(x: -3, y: 0)); tri.line(to: NSPoint(x: 3, y: 0)); tri.line(to: NSPoint(x: 0, y: 1.95)); tri.close()
        for z: CGFloat in [7.5, 15.4] { I.addChildNode(nodo(SCNShape(path: tri, extrusionDepth: 0.2), piedra, y: 5.0, x: ix, z: z)) }
        let vitral = Mat.emisivo(NSColor(calibratedRed: 0.55, green: 0.35, blue: 0.95, alpha: 1), fuerza: 0.9); focos.append(vitral)
        let roseton = nodo(SCNCylinder(radius: 0.7, height: 0.06), vitral, y: 4.0, x: ix, z: 7.46); roseton.eulerAngles.x = .pi / 2; I.addChildNode(roseton)
        let aro = nodo(SCNTorus(ringRadius: 0.72, pipeRadius: 0.06), oro, y: 4.0, x: ix, z: 7.47); aro.eulerAngles.x = .pi / 2; I.addChildNode(aro)
        for lado: CGFloat in [-1, 1] { for z: CGFloat in [9.5, 11.5, 13.5] { caja(I, 0.06, 2.2, 0.7, vitral, x: ix + lado * 3.03, y: 2.6, z: z) } }
        caja(I, 1.5, 2.4, 0.1, Mat.textura(.madera, repetir: 1, tinte: "#5a3a22"), x: ix, y: 1.2, z: 7.46)
        let arco = nodo(SCNCylinder(radius: 0.75, height: 0.1), Mat.textura(.madera, repetir: 1, tinte: "#5a3a22"), y: 2.4, x: ix, z: 7.46); arco.eulerAngles.x = .pi / 2; I.addChildNode(arco)
        caja(I, 3.4, 0.3, 1.6, piedra, x: ix, y: 0.15, z: 6.7)
        caja(I, 2.4, 9, 2.4, piedra, x: ix + 4.2, y: 4.5, z: 8.6)
        for lado: CGFloat in [-1, 1] { caja(I, 0.06, 1.2, 0.8, Mat.pbr(NSColor(calibratedWhite: 0.12, alpha: 1)), x: ix + 4.2 + lado * 1.23, y: 7.6, z: 8.6) }
        caja(I, 0.8, 1.2, 0.06, Mat.pbr(NSColor(calibratedWhite: 0.12, alpha: 1)), x: ix + 4.2, y: 7.6, z: 7.37)
        I.addChildNode(nodo(SCNPyramid(width: 2.6, height: 3.2, length: 2.6), teja, y: 9.0, x: ix + 4.2, z: 8.6))
        caja(I, 0.12, 1.3, 0.12, oro, x: ix + 4.2, y: 12.75, z: 8.6); caja(I, 0.7, 0.12, 0.12, oro, x: ix + 4.2, y: 12.95, z: 8.6)
        letrero(I, "IGLESIA DE LA VILLA · RELAX Y CONSEJOS DE VIDA", "#5b3f8c", ancho: 5.6, alto: 0.45, x: ix, y: 3.05, z: 7.42, giro: .pi, brillo: 0.9)
        caja(I, 7, 0.05, 3.2, Mat.textura(.pasto, repetir: 2), x: ix, y: 0.03, z: 17.2)
        for lado: CGFloat in [-1, 1] { caja(I, 1.6, 0.08, 0.45, Mat.textura(.madera, repetir: 1), x: ix + lado * 2, y: 0.45, z: 17.3); for e: CGFloat in [-0.6, 0.6] { caja(I, 0.08, 0.45, 0.4, negro, x: ix + lado * 2 + e, y: 0.22, z: 17.3) } }
        cil(I, 0.6, 0.5, marmol, x: ix, z: 17.3)
        I.addChildNode(nodo(SCNSphere(radius: 0.18), vela, y: 0.62, x: ix, z: 17.3))
        navL(ix, 11.5, 3.1, 4.1); navL(ix + 4.2, 8.6, 1.3, 1.3)
        escena.rootNode.addChildNode(aplanado(I, "elem:iglesia")); I.removeFromParentNode()

        for (t, ic, col, x, z, y) in [("Restaurante El Mirador", "fork.knife", NSColor(Color(hex: "#b3342b")), rx, CGFloat(-12), CGFloat(7.5)),
                                      ("Café del Valle", "cup.and.saucer.fill", NSColor(Color(hex: "#1e3d2f")), cx, -8, 6.6),
                                      ("Iglesia de la Villa", "leaf.fill", NSColor(Color(hex: "#5b3f8c")), ix, 11.5, 14.5)] {
            let e = etiqueta(t, y: 0, grande: false, icono: ic, color: col); let p = Islas.dist(x, z)
            e.position = SCNVector3(p.x, y, p.y); escena.rootNode.addChildNode(e)
        }
        montarVidaNocturna(rx: rx, cx: cx)
    }

    /// Comensales sentados (siempre) y vida nocturna de una ciudad segura: parejas paseando, alguien que trota,
    /// un vecino con su perro y gente a la salida del templo. Lo nocturno aparece solo de noche.
    private func montarVidaNocturna(rx: CGFloat, cx: CGFloat) {
        let G = marcoLocal(Islas.angDist, Islas.rDist); escena.rootNode.addChildNode(G)
        let pieles = ["#f1c9a5", "#d9a47c", "#a8714d", "#7a4e33", "#e8b896", "#c68e6a"].map { NSColor(Color(hex: $0)) }
        let ropas = ["#1c2833", "#7b241c", "#f4f6f7", "#5b2c6f", "#0e6655", "#2c3e50", "#a04000", "#34495e"].map { NSColor(Color(hex: $0)) }
        let pelos = ["#2b1d14", "#5a3a22", "#c9a66b", "#0f0f0f", "#8a4b2a", "#3b2a1a"].map { NSColor(Color(hex: $0)) }
        var n = 0
        func persona(_ mujer: Bool, _ edad: Edad = .adulto) -> PersonaPlaya {
            n += 1; return personaPlaya(mujer: mujer, edad: edad, piel: pieles[n % pieles.count], traje: ropas[n % ropas.count], pelo: pelos[(n * 2) % pelos.count], ropa: true)
        }
        func sentar(_ x: CGFloat, _ z: CGFloat, mira: CGFloat) {
            let b = persona(n % 2 == 0)
            sentado(b)
            for brazo in b.brazos { brazo.eulerAngles.x = -0.45 }                     // antebrazos sobre la mesa
            for codo in b.codos { codo.eulerAngles.x = -1.15 }
            b.codos[1].runAction(.repeatForever(.sequence([.rotateTo(x: -1.9, y: 0, z: 0, duration: 0.9), .rotateTo(x: -1.15, y: 0, z: 0, duration: 0.8), .wait(duration: 2.5 + Double(n % 3))])))
            b.cuerpo.eulerAngles.x = 0.08
            b.raiz.position = SCNVector3(x, -0.08, z); b.raiz.eulerAngles.y = mira; G.addChildNode(b.raiz)
        }
        for lado: CGFloat in [-1, 1] {                                       // a cada mesa le corresponde su silla (ángulo k·90°)
            sentar(rx + lado * 3.6, -18.2 + 0.85, mira: .pi); sentar(rx + lado * 3.6, -18.2 - 0.85, mira: 0)
            if lado > 0 { sentar(rx + lado * 3.6 + 0.85, -18.2, mira: -.pi / 2) }
            sentar(cx + lado * 2.4, -12.4 + 0.85, mira: .pi)
        }
        sentar(cx - 2.4, -12.4 - 0.85, mira: 0)
        func pasear(_ nodo: SCNNode, _ gente: [PersonaPlaya], x0: CGFloat, x1: CGFloat, z: CGFloat, vel: Double, amplitud: CGFloat = 0.42, espera: Double) {
            nodo.position = SCNVector3(x0, 0.04, z); nodo.eulerAngles.y = x1 > x0 ? .pi / 2 : -.pi / 2
            for b in gente { caminar(b, ciclo: 1.25 / vel * 0.95, amplitud: amplitud) }
            let t = Double(abs(x1 - x0)) / vel
            nodo.runAction(.sequence([.wait(duration: espera), .repeatForever(.sequence([.move(to: SCNVector3(x1, 0.04, z), duration: t), .rotateBy(x: 0, y: .pi, z: 0, duration: 1.2),
                                                                                       .move(to: SCNVector3(x0, 0.04, z), duration: t), .rotateBy(x: 0, y: .pi, z: 0, duration: 1.2)]))]))
            nodo.isHidden = true; soloDeNoche.append(nodo); G.addChildNode(nodo)
        }
        // Parejas paseando por la vereda, de un local a otro
        for (x0, x1, espera) in [(CGFloat(13), CGFloat(31), 0.0), (CGFloat(-13), CGFloat(-30), 6.0), (CGFloat(29), CGFloat(14), 11.0)] {
            let par = SCNNode(), a = persona(true), b = persona(false)
            a.raiz.position = SCNVector3(-0.32, 0, 0); b.raiz.position = SCNVector3(0.32, 0, 0)
            a.brazos[1].eulerAngles.z = 0.25; par.addChildNode(a.raiz); par.addChildNode(b.raiz)
            pasear(par, [a, b], x0: x0, x1: x1, z: 6.0, vel: 0.75, espera: espera)
        }
        // Alguien que trota a lo largo de la calle
        let trote = SCNNode(), tr = persona(false, .joven); trote.addChildNode(tr.raiz)
        pasear(trote, [tr], x0: -31, x1: 31, z: 6.6, vel: 2.6, amplitud: 0.75, espera: 3)
        // Vecino con su perro
        let paseo = SCNNode(), v = persona(false, .mayor); paseo.addChildNode(v.raiz)
        let pelaje = Mat.pbr(NSColor(Color(hex: "#a0703c")), rugosidad: 0.9), perro = SCNNode(); perro.position = SCNVector3(0.55, 0, 0.7); paseo.addChildNode(perro)
        perro.addChildNode(nodo(SCNCapsule(capRadius: 0.13, height: 0.55), pelaje, y: 0.36)); perro.childNodes[0].eulerAngles.x = .pi / 2
        perro.addChildNode(nodo(SCNSphere(radius: 0.12), pelaje, y: 0.52, z: 0.3))
        for (x, z) in [(CGFloat(-0.08), CGFloat(0.16)), (0.08, 0.16), (-0.08, -0.16), (0.08, -0.16)] {
            let pata = nodo(SCNCylinder(radius: 0.03, height: 0.25), pelaje, y: 0.12, x: x, z: z); perro.addChildNode(pata)
            pata.runAction(.repeatForever(.sequence([.rotateTo(x: (x * z > 0 ? 1 : -1) * 0.4, y: 0, z: 0, duration: 0.2), .rotateTo(x: (x * z > 0 ? -1 : 1) * 0.4, y: 0, z: 0, duration: 0.2)])))
        }
        pasear(paseo, [v], x0: -14, x1: -28, z: 5.6, vel: 0.6, espera: 8)
        // Fieles conversando a la salida de la iglesia y alguien meditando en el jardín
        var azar = Azar(semilla: 91)
        for (k, (x, z, giro)) in [(CGFloat(35.6), CGFloat(5.6), CGFloat(1.2)), (36.5, 5.3, -2.0), (38.4, 5.6, -1.4)].enumerated() {
            let b = persona(k != 1, k == 2 ? .mayor : .adulto)
            b.raiz.position = SCNVector3(x, 0.04, z); b.raiz.eulerAngles.y = giro
            quieto(b, gesto: k != 2, azar: &azar); b.raiz.isHidden = true; soloDeNoche.append(b.raiz); G.addChildNode(b.raiz)
        }
        let m = persona(true); sentado(m)
        for br in m.brazos { br.eulerAngles.x = -0.25 }                              // manos sobre las rodillas, espalda recta
        for codo in m.codos { codo.eulerAngles.x = -0.9 }
        m.raiz.position = SCNVector3(35, -0.38, 17.3); m.raiz.eulerAngles.y = .pi; G.addChildNode(m.raiz)
    }

    private func tradeCenter(_ B: SCNNode, _ nav: (CGFloat, CGFloat, CGFloat, CGFloat) -> Void) {
        let acero = Mat.pbr(NSColor(Color(hex: "#c9ced3")), rugosidad: 0.3, metal: 0.8), oscuro = Mat.pbr(NSColor(calibratedWhite: 0.2, alpha: 1), rugosidad: 0.5)
        for (x, z, lado, alto, giro) in [(CGFloat(-4.6), CGFloat(-4.0), CGFloat(5.2), CGFloat(38), CGFloat(0)), (4.8, -5.2, 4.6, 30, 0.25), (0.3, -9.0, 3.6, 22, -0.15)] {
            let t = SCNNode(); t.position = SCNVector3(x, 0, z); t.eulerAngles.y = giro; B.addChildNode(t)
            caja(t, lado, alto, lado, ventana(), y: alto / 2)
            for k in stride(from: CGFloat(3.2), to: alto, by: 3.2) { caja(t, lado + 0.08, 0.14, lado + 0.08, acero, y: k) }
            for s: CGFloat in [-1, 1] { for e: CGFloat in [-1, 1] { caja(t, 0.18, alto, 0.18, acero, x: s * lado / 2, y: alto / 2, z: e * lado / 2) } }
            caja(t, lado * 0.7, 2.2, lado * 0.7, acero, y: alto + 1.1)
            cil(t, 0.08, 5, acero, y: alto + 4.6)
            t.addChildNode(nodo(SCNSphere(radius: 0.16), Mat.emisivo(.systemRed, fuerza: 1.5), y: alto + 7.2))
            caja(t, lado + 0.6, 3.2, lado + 0.6, oscuro, y: 1.6)
            nav(x, z, lado / 2 + 0.3, lado / 2 + 0.3)
        }
        let esfera = nodo(SCNSphere(radius: 1.4), Mat.pbr(NSColor(Color(hex: "#c9a227")), rugosidad: 0.25, metal: 0.95), y: 2.6, x: -6.5, z: 4)
        B.addChildNode(esfera); cil(B, 0.6, 1.2, Mat.textura(.marmol, repetir: 1), x: -6.5, z: 4)
        nav(-6.5, 4, 0.7, 0.7)
        caja(B, 8.4, 1.4, 0.6, Mat.textura(.marmol, repetir: 2), y: 0.7, z: 8.6)
        letrero(B, "VILLA TRADE CENTER", "#1a5276", ancho: 8, alto: 0.9, y: 0.75, z: 8.92)
        nav(0, 8.6, 4.2, 0.3)
    }

    private func banco(_ B: SCNNode, _ nav: (CGFloat, CGFloat, CGFloat, CGFloat) -> Void) {
        let piedra = Mat.textura(.estuco, repetir: 3, tinte: "#efe6d2"), marmol = Mat.textura(.marmol, repetir: 2)
        let oro = Mat.pbr(NSColor(Color(hex: "#c9a227")), rugosidad: 0.25, metal: 0.95)
        caja(B, 9.4, 0.6, 6.6, marmol, z: -2.0)
        caja(B, 8.4, 5.2, 4.6, piedra, y: 3.2, z: -2.6)
        for k in 0..<6 { cil(B, 0.28, 4.6, marmol, x: -3.5 + CGFloat(k) * 1.4, y: 2.9, z: 0.6) }
        caja(B, 8.6, 0.6, 1.4, piedra, y: 5.5, z: 0.1)
        let fronton = SCNNode(); fronton.position = SCNVector3(0, 5.8, 0.75)
        let p = NSBezierPath(); p.move(to: NSPoint(x: -4.3, y: 0)); p.line(to: NSPoint(x: 4.3, y: 0)); p.line(to: NSPoint(x: 0, y: 1.6)); p.close()
        fronton.addChildNode(nodo(SCNShape(path: p, extrusionDepth: 0.5), piedra)); B.addChildNode(fronton)
        letrero(B, "BANCO CENTRAL DE LA VILLA", "#7d6608", ancho: 6.4, alto: 0.55, y: 5.5, z: 0.82)
        B.addChildNode(nodo(SCNSphere(radius: 1.6), oro, y: 6.2, z: -2.6))
        for s in 0..<3 { caja(B, 7 - CGFloat(s) * 0.4, 0.2, 0.5, marmol, y: 0.1 + CGFloat(s) * 0.2, z: 1.9 - CGFloat(s) * 0.4) }
        caja(B, 1.0, 2.0, 0.8, Mat.pbr(NSColor(Color(hex: "#1a5276")), rugosidad: 0.4), x: -5.0, z: 1.2)
        letrero(B, "CAJERO", "#1a5276", ancho: 0.9, alto: 0.25, x: -5.0, y: 1.75, z: 1.62)
        nav(0, -2.0, 4.7, 3.3); nav(-5.0, 1.2, 0.5, 0.4)
    }

    private func casino(_ B: SCNNode, _ nav: (CGFloat, CGFloat, CGFloat, CGFloat) -> Void) {
        let muro = Mat.pbr(NSColor(Color(hex: "#3b1f4a")), rugosidad: 0.35, metal: 0.35), oro = Mat.pbr(NSColor(Color(hex: "#d4af37")), rugosidad: 0.2, metal: 0.95)
        let neonRojo = Mat.emisivo(NSColor(calibratedRed: 1, green: 0.15, blue: 0.25, alpha: 1), fuerza: 2.2)
        let neonOro = Mat.emisivo(NSColor(calibratedRed: 1, green: 0.8, blue: 0.3, alpha: 1), fuerza: 1.8)
        focos += [neonRojo, neonOro]
        // Cuerpo, cornisa dorada, fachada de vidrio con franjas de luz
        caja(B, 11, 7, 6.5, muro, z: -2.6)
        caja(B, 11.4, 0.5, 6.9, oro, y: 7.25, z: -2.6)
        caja(B, 10.4, 3.6, 0.06, ventana(), y: 2.0, z: 0.68)
        for y: CGFloat in [4.1, 6.6] { caja(B, 11.1, 0.12, 0.08, neonOro, y: y, z: 0.7) }
        for x: CGFloat in [-5.5, 5.5] { caja(B, 0.12, 7, 0.08, neonOro, x: x, y: 3.5, z: 0.7) }
        // Torre con «CASINO» vertical en neón y corona dorada
        let T = SCNNode(); T.position = SCNVector3(-3.6, 0, -3.6); B.addChildNode(T)
        caja(T, 3.4, 22, 3.4, muro, y: 11)
        caja(T, 3.8, 0.5, 3.8, oro, y: 22.2)
        T.addChildNode(nodo(SCNPyramid(width: 3.4, height: 2.6, length: 3.4), oro, y: 22.45))
        caja(T, 3.6, 0.35, 3.6, oro, y: 7.6)                          // collarín donde la torre sale del techo
        for x: CGFloat in [-1.45, 1.45] { caja(T, 0.08, 12.2, 0.06, neonOro, x: x, y: 15.0, z: 1.73) }
        for y: CGFloat in [8.9, 21.1] { caja(T, 2.98, 0.08, 0.06, neonOro, y: y, z: 1.73) }
        for (i, ch) in "CASINO".enumerated() {
            let t = SCNText(string: String(ch), extrusionDepth: 0.2); t.font = NSFont.systemFont(ofSize: 1.55, weight: .black); t.flatness = 0.08
            t.materials = [neonRojo, oro, oro]
            let n = SCNNode(geometry: t); let (mn, mx) = n.boundingBox
            n.position = SCNVector3(-(mn.x + mx.x) / 2, 19.6 - CGFloat(i) * 1.9 - mn.y, 1.72); T.addChildNode(n)
        }
        // Gran letrero sobre la entrada y marquesina dorada con columnas
        letrero(B, "GRAN CASINO DE LA VILLA", "#c0392b", ancho: 9.6, alto: 1.3, y: 5.3, z: 0.75, brillo: 1.6)
        caja(B, 7, 0.3, 3.0, oro, y: 3.6, z: 2.2)
        for x: CGFloat in [-3.2, 3.2] { cil(B, 0.16, 3.6, oro, x: x, z: 3.5) }
        caja(B, 6.6, 0.06, 2.6, Mat.pbr(NSColor(Color(hex: "#8b0000")), rugosidad: 0.8), y: 0.03, z: 2.2)      // alfombra roja
        // Dado gigante y ficha de casino como esculturas
        let dado = Mat.pbr(NSColor(calibratedWhite: 0.97, alpha: 1), rugosidad: 0.3), punto = Mat.pbr(NSColor(calibratedWhite: 0.05, alpha: 1))
        let d = SCNNode(); d.position = SCNVector3(-4.8, 2.3, 3.6)
        d.addChildNode(nodo(SCNBox(width: 1.7, height: 1.7, length: 1.7, chamferRadius: 0.28), dado))
        for (x, y) in [(CGFloat(-0.45), CGFloat(0.45)), (0, 0), (0.45, -0.45)] { d.addChildNode(nodo(SCNSphere(radius: 0.15), punto, y: y, x: x, z: 0.85)) }
        for (x, z) in [(CGFloat(-0.45), CGFloat(-0.45)), (0.45, 0.45)] { d.addChildNode(nodo(SCNSphere(radius: 0.15), punto, y: 0.85, x: x, z: z)) }
        d.eulerAngles = SCNVector3(0.5, 0.6, 0.3); B.addChildNode(d)
        cil(B, 0.7, 1.3, Mat.textura(.marmol, repetir: 1), x: -4.8, z: 3.6)
        let ficha = nodo(SCNCylinder(radius: 1.0, height: 0.22), Mat.pbr(NSColor(Color(hex: "#c0392b")), rugosidad: 0.4), y: 2.2, x: 5.2, z: 3.4)
        ficha.eulerAngles.x = .pi / 2; B.addChildNode(ficha)
        B.addChildNode(nodo(SCNTorus(ringRadius: 0.75, pipeRadius: 0.06), oro, y: 2.2, x: 5.2, z: 3.52))
        cil(B, 0.6, 1.1, Mat.textura(.marmol, repetir: 1), x: 5.2, z: 3.4)
        nav(0, -2.6, 5.6, 3.4); nav(-3.6, -3.6, 1.8, 1.8); nav(-4.8, 3.6, 0.8, 0.8); nav(5.2, 3.4, 0.7, 0.7)
        // Lo que se mueve (aparte del bloque fijo): ampolletas que corren, reflectores que barren el cielo
        let foco = Mat.emisivo(NSColor(calibratedRed: 1, green: 0.85, blue: 0.4, alpha: 1), fuerza: 2.4)
        let vivo = SCNNode(); vivo.position = B.position; vivo.eulerAngles = B.eulerAngles
        for k in 0..<16 {
            let b = nodo(SCNSphere(radius: 0.12), foco, y: 3.8, x: -3.4 + CGFloat(k) * 0.45, z: 3.7)
            b.runAction(.repeatForever(.sequence([.wait(duration: Double(k % 4) * 0.15), .fadeOpacity(to: 0.1, duration: 0.3), .fadeOpacity(to: 1, duration: 0.3)])))
            vivo.addChildNode(b)
        }
        for k in 0..<22 {
            let b = nodo(SCNSphere(radius: 0.1), foco, y: 0.6 + CGFloat(k) * 0.3, x: -5.65, z: 0.75)
            b.runAction(.repeatForever(.sequence([.wait(duration: Double(k) * 0.05), .fadeOpacity(to: 0.15, duration: 0.25), .fadeOpacity(to: 1, duration: 0.25), .wait(duration: 0.6)])))
            vivo.addChildNode(b)
        }
        let haz = Mat.pbr(NSColor(calibratedRed: 1, green: 0.95, blue: 0.75, alpha: 1)); haz.emission.contents = NSColor(calibratedRed: 1, green: 0.95, blue: 0.75, alpha: 1)
        haz.transparency = 0.18; haz.writesToDepthBuffer = false; haz.isDoubleSided = true; haz.lightingModel = .constant
        for (x, fase) in [(CGFloat(3.5), 0.0), (-0.5, 1.6)] {
            let pivote = SCNNode(); pivote.position = SCNVector3(x, 7.5, -3.0)
            let cono = nodo(SCNCone(topRadius: 1.4, bottomRadius: 0.15, height: 26), haz, y: 13); cono.castsShadow = false
            let incl = SCNNode(); incl.eulerAngles.x = 0.45; incl.addChildNode(cono); pivote.addChildNode(incl)
            pivote.runAction(.repeatForever(.sequence([.wait(duration: fase), .rotateBy(x: 0, y: .pi * 2, z: 0, duration: 7)])))
            vivo.addChildNode(pivote)
        }
        escena.rootNode.addChildNode(vivo)
    }

    private func universidad(_ B: SCNNode, _ nav: (CGFloat, CGFloat, CGFloat, CGFloat) -> Void) {
        let ladrillo = Mat.textura(.estuco, repetir: 3, tinte: "#b5654a"), piedra = Mat.textura(.estuco, repetir: 3, tinte: "#efe6d2")
        let techo = Mat.pbr(NSColor(Color(hex: "#5b3a29")), rugosidad: 0.6), pasto = Mat.pbr(NSColor(calibratedRed: 0.3, green: 0.55, blue: 0.25, alpha: 1), rugosidad: 0.9)
        cil(B, 6.2, 0.06, pasto, y: 0.03)                                            // patio central
        for g: CGFloat in [0, .pi / 2] { caja(B, 12, 0.07, 1.2, Mat.textura(.adoquin, repetir: 3), y: 0.04, giro: g) }
        // Rectoría con torre del reloj (al fondo, frente al acceso)
        let R = SCNNode(); R.position = SCNVector3(0, 0, -10.5); B.addChildNode(R)
        caja(R, 6, 5, 3.6, piedra, y: 2.5)
        caja(R, 6.4, 0.4, 4.0, techo, y: 5.2)
        caja(R, 2.4, 9, 2.4, piedra, y: 9.6)
        caja(R, 2.8, 0.5, 2.8, techo, y: 14.3)
        R.addChildNode(nodo(SCNPyramid(width: 2.6, height: 2.2, length: 2.6), techo, y: 14.5))
        let reloj = SCNMaterial(); reloj.diffuse.contents = relojImagen(); reloj.emission.contents = reloj.diffuse.contents; reloj.emission.intensity = 0.3
        R.addChildNode(nodo(SCNPlane(width: 1.8, height: 1.8), reloj, y: 12.2, z: 1.22))
        caja(R, 5.6, 2.6, 0.06, ventana(), y: 2.0, z: 1.82)
        letrero(R, "UNIVERSIDAD DE LA VILLA · RECTORÍA", "#5b3a29", ancho: 5.6, alto: 0.55, y: 4.3, z: 1.86)
        nav(0, -10.5, 3.1, 1.9)
        // Facultades en anillo alrededor del patio, puertas al centro
        let facultades: [(String, String)] = [("MEDICINA", "#c0392b"), ("INGENIERÍA", "#d68910"), ("COMPUTACIÓN E IA", "#1f6fb2"), ("ECONOMÍA Y NEGOCIOS", "#196f3d"),
                                              ("DERECHO", "#7d3c98"), ("HUMANIDADES", "#a04000"), ("CIENCIAS EXACTAS", "#117a65"), ("ARQUITECTURA Y DISEÑO", "#2e4053")]
        let angs: [CGFloat] = [62, 92, 122, 151, -62, -92, -122, -151].map { $0 * .pi / 180 }
        for (k, a) in angs.enumerated() {
            let (nombre, color) = facultades[k]
            let pos = CGPoint(x: sin(a) * 10.5, y: cos(a) * 10.5)
            let F = SCNNode(); F.position = SCNVector3(pos.x, 0, pos.y); F.eulerAngles.y = a + .pi; B.addChildNode(F)
            caja(F, 4.6, 4.2, 4.0, ladrillo, y: 2.1)
            caja(F, 4.9, 0.35, 4.3, techo, y: 4.35)
            caja(F, 4.0, 1.4, 0.06, ventana(), y: 3.0, z: 2.03)
            caja(F, 1.2, 2.1, 0.06, Mat.pbr(NSColor(Color(hex: "#4a3524")), rugosidad: 0.6), y: 1.05, z: 2.03)
            letrero(F, "FACULTAD DE " + nombre, color, ancho: 4.2, alto: 0.5, y: 4.0, z: 2.09)
            nav(pos.x, pos.y, 2.3, 2.0)   // (girado: margen holgado)
        }
        caja(B, 8.6, 1.2, 0.5, Mat.textura(.marmol, repetir: 2), y: 0.6, z: 11.6)
        letrero(B, "UNIVERSIDAD DE LA VILLA", "#5b3a29", ancho: 8.2, alto: 0.8, y: 0.65, z: 11.88)
        nav(0, 11.6, 4.3, 0.3)
    }

    private func relojImagen() -> NSImage {
        NSImage(size: NSSize(width: 256, height: 256), flipped: false) { r in
            NSColor.white.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 6, dy: 6)).fill()
            NSColor.black.setStroke()
            let borde = NSBezierPath(ovalIn: r.insetBy(dx: 6, dy: 6)); borde.lineWidth = 10; borde.stroke()
            for k in 0..<12 {
                let a = CGFloat(k) / 12 * .pi * 2, b = NSBezierPath(); b.lineWidth = k % 3 == 0 ? 9 : 4
                b.move(to: NSPoint(x: 128 + sin(a) * 100, y: 128 + cos(a) * 100)); b.line(to: NSPoint(x: 128 + sin(a) * 115, y: 128 + cos(a) * 115)); b.stroke()
            }
            let h = NSBezierPath(); h.lineWidth = 10; h.move(to: NSPoint(x: 128, y: 128)); h.line(to: NSPoint(x: 128 + 50, y: 128 + 30)); h.stroke()
            let m = NSBezierPath(); m.lineWidth = 6; m.move(to: NSPoint(x: 128, y: 128)); m.line(to: NSPoint(x: 128, y: 218)); m.stroke()
            return true
        }
    }

    private func centroCientifico(_ B: SCNNode, _ nav: (CGFloat, CGFloat, CGFloat, CGFloat) -> Void) {
        let blanco = Mat.pbr(NSColor(calibratedWhite: 0.95, alpha: 1), rugosidad: 0.35), acero = Mat.pbr(NSColor(Color(hex: "#c9ced3")), rugosidad: 0.3, metal: 0.8)
        // Planetario (domo)
        B.addChildNode(nodo(SCNSphere(radius: 4), blanco, y: 0, x: -4, z: -3.5))
        cil(B, 4.05, 0.8, Mat.pbr(NSColor(Color(hex: "#117a65")), rugosidad: 0.5), x: -4, z: -3.5)
        letrero(B, "PLANETARIO", "#117a65", ancho: 3, alto: 0.5, x: -4, y: 1.3, z: 0.6)
        nav(-4, -3.5, 3.9, 3.9)
        // Laboratorios
        caja(B, 6.8, 6, 4.4, Mat.textura(.estuco, repetir: 3, tinte: "#e3e8ec"), x: 4.2, z: -4.6)
        for k in 0..<2 { caja(B, 6.4, 1.3, 0.06, ventana(), x: 4.2, y: 1.6 + CGFloat(k) * 3.0, z: -2.36) }   // 2 pisos de 3 m
        letrero(B, "CENTRO CIENTÍFICO · LABORATORIOS", "#117a65", ancho: 6.2, alto: 0.55, x: 4.2, y: 6.4, z: -2.32)
        nav(4.2, -4.6, 3.5, 2.3)
        // Observatorio
        cil(B, 1.6, 6, blanco, x: 7.2, z: 2.2)
        B.addChildNode(nodo(SCNSphere(radius: 1.65), acero, y: 6, x: 7.2, z: 2.2))
        caja(B, 0.4, 1.4, 3.4, Mat.pbr(NSColor(calibratedWhite: 0.1, alpha: 1)), x: 7.2, y: 6.6, z: 2.2)
        nav(7.2, 2.2, 1.7, 1.7)
        // Radiotelescopio
        cil(B, 0.25, 3.2, acero, x: -7.6, z: 3)
        let plato = nodo(SCNSphere(radius: 2.4), blanco, y: 3.6, x: -7.6, z: 3)
        plato.scale = SCNVector3(1, 0.3, 1); plato.eulerAngles.x = -0.7; B.addChildNode(plato)
        nav(-7.6, 3, 0.4, 0.4)
        // Escultura de ADN
        let dna = SCNNode(); dna.position = SCNVector3(1.6, 0, 2.6)
        let azul = Mat.pbr(NSColor.systemBlue, rugosidad: 0.3), rojo = Mat.pbr(NSColor.systemRed, rugosidad: 0.3)
        for k in 0..<16 {
            let t = CGFloat(k) * 0.42, y = 0.6 + CGFloat(k) * 0.28
            dna.addChildNode(nodo(SCNSphere(radius: 0.14), azul, y: y, x: cos(t) * 0.6, z: sin(t) * 0.6))
            dna.addChildNode(nodo(SCNSphere(radius: 0.14), rojo, y: y, x: -cos(t) * 0.6, z: -sin(t) * 0.6))
            if k % 2 == 0 { let b = nodo(SCNBox(width: 1.2, height: 0.05, length: 0.05, chamferRadius: 0), acero, y: y); b.eulerAngles.y = -t; dna.addChildNode(b) }
        }
        B.addChildNode(dna)
        nav(1.6, 2.6, 0.7, 0.7)
    }

    /// Museo neoclásico. Frente a la escalinata, en pedestales, los agentes y procesos que ya no se usan (clic: su historia).
    private func museo(_ B: SCNNode, _ nav: (CGFloat, CGFloat, CGFloat, CGFloat) -> Void) {
        let piedra = Mat.textura(.estuco, repetir: 3, tinte: "#f1ead9"), marmol = Mat.textura(.marmol, repetir: 2)
        caja(B, 11, 0.5, 5.6, marmol, z: -3.0)
        caja(B, 10, 5, 4.4, piedra, y: 3.0, z: -3.4)
        for k in 0..<8 { cil(B, 0.26, 4.4, marmol, x: -4.55 + CGFloat(k) * 1.3, y: 2.7, z: -0.6) }
        caja(B, 10.4, 0.6, 1.6, piedra, y: 5.2, z: -1.0)
        let p = NSBezierPath(); p.move(to: NSPoint(x: -5.2, y: 0)); p.line(to: NSPoint(x: 5.2, y: 0)); p.line(to: NSPoint(x: 0, y: 1.7)); p.close()
        let fr = nodo(SCNShape(path: p, extrusionDepth: 0.5), piedra, y: 5.5, z: -0.4); B.addChildNode(fr)
        letrero(B, "MUSEO DE LA VILLA · AGENTES HISTÓRICOS", "#7d6608", ancho: 8, alto: 0.55, y: 5.2, z: -0.16)
        for s in 0..<3 { caja(B, 8 - CGFloat(s) * 0.4, 0.2, 0.45, marmol, y: 0.1 + CGFloat(s) * 0.2, z: 0.4 - CGFloat(s) * 0.35) }
        nav(0, -3.0, 5.5, 2.8)
        // Piezas en exhibición (nodos aparte, con nombre, para el clic)
        let piezas = Villa3D.Coordinador.piezasMuseo()
        let bronce = Mat.pbr(NSColor(Color(hex: "#8c6239")), rugosidad: 0.35, metal: 0.85)
        let n = CGFloat(piezas.count)
        for (k, pz) in piezas.enumerated() {
            let x = (CGFloat(k) - (n - 1) / 2) * 1.6
            let P = SCNNode(); P.position = SCNVector3(x, 0, 2.6); P.name = "elem:museo-\(pz.id)"
            P.addChildNode(nodo(SCNBox(width: 0.9, height: 1.0, length: 0.9, chamferRadius: 0.03), marmol, y: 0.5))
            P.addChildNode(nodo(SCNBox(width: 0.44, height: 0.56, length: 0.3, chamferRadius: 0.08), bronce, y: 1.32))
            P.addChildNode(nodo(SCNSphere(radius: 0.2), bronce, y: 1.82))
            P.addChildNode(nodo(SCNCylinder(radius: 0.02, height: 0.25), bronce, y: 2.1))
            P.addChildNode(nodo(SCNSphere(radius: 0.05), Mat.emisivo(.systemGray, fuerza: 0.5), y: 2.24))
            let placa = nodo(SCNPlane(width: 0.84, height: 0.3), Villa3D.Coordinador.mCartel(pz.nombre, NSColor(Color(hex: "#3d3f7a")), ancho: 700, brillo: 0.5), y: 0.62, z: 0.46)
            P.addChildNode(placa)
            nav(x, 2.6, 0.5, 0.5)
            let w = SCNNode(); w.position = B.position; w.eulerAngles = B.eulerAngles
            w.addChildNode(P); escena.rootNode.addChildNode(w)
        }
    }

    /// Piezas del museo: `trabajo/museo.json` (agentes y procesos retirados, con su historia).
    nonisolated static func piezasMuseo() -> [(id: String, nombre: String, texto: String)] {
        guard let d = FileManager.default.contents(atPath: Almacen.carpetaLocal + "/trabajo/museo.json"),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let l = j["piezas"] as? [[String: Any]] else { return [] }
        return l.compactMap { p in
            guard let id = p["id"] as? String, let n = p["nombre"] as? String else { return nil }
            let partes = [p["que_hacia"], p["por_que"], p["reemplazo"], p["fecha"]].compactMap { $0 as? String }.filter { !$0.isEmpty }
            return (id, n, partes.joined(separator: " "))
        }
    }

    // MARK: Costa: caleta, balneario y marina

    /// Casco con forma: popa recta, costados que se cierran en una proa en punta (vista superior), en dos capas
    /// (la de abajo más angosta) y con borda de color. Proa en +z, línea de flotación en y = 0.
    private func casco(_ g: SCNNode, largo L: CGFloat, manga w: CGFloat, alto h: CGFloat, _ pintura: SCNMaterial, borda: SCNMaterial) {
        func contorno(_ k: CGFloat) -> NSBezierPath {
            let a = w * k / 2, p = NSBezierPath()
            p.move(to: NSPoint(x: -a * 0.86, y: -L / 2))
            p.line(to: NSPoint(x: a * 0.86, y: -L / 2))
            p.curve(to: NSPoint(x: a, y: L * 0.05), controlPoint1: NSPoint(x: a, y: -L * 0.4), controlPoint2: NSPoint(x: a, y: -L * 0.15))
            p.curve(to: NSPoint(x: 0, y: L / 2), controlPoint1: NSPoint(x: a, y: L * 0.3), controlPoint2: NSPoint(x: a * 0.35, y: L * 0.46))
            p.curve(to: NSPoint(x: -a, y: L * 0.05), controlPoint1: NSPoint(x: -a * 0.35, y: L * 0.46), controlPoint2: NSPoint(x: -a, y: L * 0.3))
            p.curve(to: NSPoint(x: -a * 0.86, y: -L / 2), controlPoint1: NSPoint(x: -a, y: -L * 0.15), controlPoint2: NSPoint(x: -a, y: -L * 0.4))
            p.close(); p.flatness = 0.05
            return p
        }
        func capa(_ k: CGFloat, _ alto: CGFloat, _ y: CGFloat, _ m: SCNMaterial) {
            let s = SCNShape(path: contorno(k), extrusionDepth: alto); s.chamferRadius = min(0.06, alto / 3)
            let n = nodo(s, m, y: y); n.eulerAngles.x = .pi / 2; g.addChildNode(n)
        }
        capa(0.62, h * 0.45, -h * 0.2, pintura)                    // obra viva (bajo el agua, más angosta)
        capa(1.0, h * 0.75, h * 0.35, pintura)                     // obra muerta
        capa(1.03, h * 0.12, h * 0.75, borda)                      // borda
        let cub = SCNShape(path: contorno(0.92), extrusionDepth: 0.03)
        let c = nodo(cub, Mat.textura(.madera, repetir: 2, tinte: "#b8916a"), y: h * 0.73); c.eulerAngles.x = .pi / 2; g.addChildNode(c)
    }

    private func baranda(_ g: SCNNode, largo L: CGFloat, manga w: CGFloat, y: CGFloat) {
        let acero = Mat.pbr(NSColor(calibratedWhite: 0.85, alpha: 1), rugosidad: 0.2, metal: 0.9)
        for lado: CGFloat in [-1, 1] {
            caja(g, 0.03, 0.03, L * 0.62, acero, x: lado * w * 0.45, y: y + 0.45, z: -L * 0.05)
            for k in 0..<5 { caja(g, 0.03, 0.45, 0.03, acero, x: lado * w * 0.45, y: y + 0.22, z: -L * 0.34 + CGFloat(k) * L * 0.145) }
        }
    }

    /// Bote de pesca de caleta: casco de madera pintado, borda blanca, caseta, motor fuera de borda y una boya.
    private func bote(_ color: NSColor, largo L: CGFloat = 3.6) -> SCNNode {
        let n = SCNNode(), w = L * 0.36
        if let m = Modelos.nodo("bote", largo: L) {   // casco de madera descargado; motor, mástil, red, boyas y remos se agregan encima
            m.childNodes[0].position.y = 0.05; n.addChildNode(m)
        } else {
            casco(n, largo: L, manga: w, alto: 0.7, Mat.pbr(color, rugosidad: 0.55), borda: Mat.pbr(NSColor(calibratedWhite: 0.96, alpha: 1), rugosidad: 0.5))
            caja(n, w * 0.6, 0.7, L * 0.22, Mat.pbr(NSColor(calibratedWhite: 0.95, alpha: 1), rugosidad: 0.5), y: 0.95, z: -L * 0.12, chaflan: 0.04)
            caja(n, w * 0.62, 0.22, 0.03, Mat.pbr(NSColor(Color(hex: "#26394d")), rugosidad: 0.1, metal: 0.5), y: 1.1, z: -L * 0.12 + L * 0.11 + 0.01)
            caja(n, w * 0.7, 0.05, L * 0.26, Mat.pbr(color, rugosidad: 0.5), y: 1.32, z: -L * 0.12)
        }
        // Motor fuera de borda: capota redondeada, pata con hélice y caña del timón
        let motor = Mat.pbr(NSColor(calibratedWhite: 0.12, alpha: 1), rugosidad: 0.35, metal: 0.3), acero = Mat.pbr(NSColor(calibratedWhite: 0.7, alpha: 1), rugosidad: 0.3, metal: 0.85)
        caja(n, 0.26, 0.36, 0.34, motor, y: 0.95, z: -L / 2 - 0.12, chaflan: 0.08)
        cil(n, 0.045, 0.7, motor, y: 0.45, z: -L / 2 - 0.16)
        let helice = nodo(SCNBox(width: 0.28, height: 0.05, length: 0.02, chamferRadius: 0.01), acero, y: 0.12, z: -L / 2 - 0.24)
        helice.runAction(.repeatForever(.rotateBy(x: 0, y: 0, z: .pi * 2, duration: 0.2))); n.addChildNode(helice)
        let cana = nodo(SCNCylinder(radius: 0.02, height: 0.5), acero, y: 0.98, z: -L / 2 + 0.12); cana.eulerAngles.x = .pi / 2 - 0.25; n.addChildNode(cana)
        // Mástil con luz de faena, red recogida en la proa, boyas y remos
        cil(n, 0.035, 1.4, Mat.textura(.madera, repetir: 1, tinte: "#6b4a2f"), y: 2.0, z: -L * 0.12)
        n.addChildNode(nodo(SCNSphere(radius: 0.06), Mat.emisivo(NSColor(calibratedRed: 1, green: 0.95, blue: 0.8, alpha: 1), fuerza: 1.2), y: 2.72, z: -L * 0.12))
        let red = Mat.pbr(NSColor(Color(hex: "#2f6b57")), rugosidad: 0.95)
        for (x, z, r) in [(CGFloat(-0.12), L * 0.24, CGFloat(0.22)), (0.14, L * 0.28, 0.18), (0, L * 0.2, 0.17)] {
            let bulto = nodo(SCNSphere(radius: r), red, y: 0.62, x: x, z: z); bulto.scale = SCNVector3(1.2, 0.55, 1); n.addChildNode(bulto)
        }
        for (x, z) in [(w * 0.4, L * 0.15), (-w * 0.38, L * 0.05)] { n.addChildNode(nodo(SCNSphere(radius: 0.12), Mat.pbr(NSColor.systemOrange, rugosidad: 0.5), y: 0.7, x: x, z: z)) }
        for lado: CGFloat in [-1, 1] {
            let remo = nodo(SCNCylinder(radius: 0.025, height: L * 0.55), Mat.textura(.madera, repetir: 1, tinte: "#a8865f"), y: 0.72, x: lado * w * 0.32, z: -L * 0.02)
            remo.eulerAngles.x = .pi / 2; n.addChildNode(remo)
        }
        return n
    }

    /// Yate a motor (casco blanco, franja azul, superestructura escalonada con ventanales y flybridge) o velero
    /// (casco esbelto, quilla, mástil, botavara, vela mayor, foque y jarcias).
    private func yate(_ L: CGFloat, vela: Bool) -> SCNNode {
        if let m = Modelos.nodo(vela ? "velero" : "yate", largo: L * (vela ? 1 : 1.3)) { m.childNodes[0].position.y = vela ? -0.55 : 0.1; return m }
        let n = SCNNode()
        let blanco = Mat.pbr(NSColor(calibratedWhite: 0.97, alpha: 1), rugosidad: 0.22), azul = Mat.pbr(NSColor(Color(hex: "#1a3d5c")), rugosidad: 0.3)
        let vidrio = Mat.pbr(NSColor(Color(hex: "#1d2b3a")), rugosidad: 0.05, metal: 0.6), acero = Mat.pbr(NSColor(calibratedWhite: 0.8, alpha: 1), rugosidad: 0.2, metal: 0.9)
        if vela {
            let w = L * 0.3
            casco(n, largo: L, manga: w, alto: 0.8, blanco, borda: azul)
            caja(n, 0.12, 1.1, L * 0.3, azul, y: -0.8, z: 0)                                   // quilla
            caja(n, w * 0.55, 0.38, L * 0.3, blanco, y: 0.85, z: -L * 0.08, chaflan: 0.1)          // camarote
            for lado: CGFloat in [-1, 1] { caja(n, 0.02, 0.1, L * 0.2, vidrio, x: lado * w * 0.28, y: 0.88, z: -L * 0.08) }
            let alto = L * 1.25
            cil(n, 0.05, alto, acero, y: 0.7 + alto / 2, z: L * 0.08)
            let bota = nodo(SCNCylinder(radius: 0.04, height: L * 0.42), acero, y: 1.5, z: L * 0.08 - L * 0.21); bota.eulerAngles.x = .pi / 2; n.addChildNode(bota)
            let lona = Mat.pbr(NSColor(calibratedWhite: 0.98, alpha: 1), rugosidad: 0.85); lona.isDoubleSided = true
            let mayor = NSBezierPath(); mayor.move(to: NSPoint(x: 0, y: 0)); mayor.line(to: NSPoint(x: 0, y: alto * 0.88))
            mayor.curve(to: NSPoint(x: L * 0.42, y: 0), controlPoint1: NSPoint(x: L * 0.12, y: alto * 0.6), controlPoint2: NSPoint(x: L * 0.36, y: alto * 0.25)); mayor.close()
            let mv = nodo(SCNShape(path: mayor, extrusionDepth: 0.02), lona, y: 1.56, z: L * 0.08); mv.eulerAngles.y = .pi / 2; n.addChildNode(mv)
            let foque = NSBezierPath(); foque.move(to: NSPoint(x: 0, y: 0)); foque.line(to: NSPoint(x: 0, y: alto * 0.78)); foque.line(to: NSPoint(x: -L * 0.36, y: 0)); foque.close()
            let fv = nodo(SCNShape(path: foque, extrusionDepth: 0.02), lona, y: 0.95, z: L * 0.09); fv.eulerAngles.y = .pi / 2; n.addChildNode(fv)
            // Jarcias: estay de proa y obenques
            func cabo(_ a: SCNVector3, _ b: SCNVector3) {
                let d = SCNVector3(b.x - a.x, b.y - a.y, b.z - a.z), largo = sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
                let c = SCNNode(geometry: SCNCylinder(radius: 0.012, height: largo)); c.geometry?.materials = [acero]
                c.position = SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
                c.look(at: b, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 1, 0)); n.addChildNode(c)
            }
            let tope = SCNVector3(0, 0.7 + alto, L * 0.08)
            cabo(tope, SCNVector3(0, 0.75, L * 0.48))
            for lado: CGFloat in [-1, 1] { cabo(tope, SCNVector3(lado * w * 0.45, 0.75, L * 0.05)) }
            baranda(n, largo: L, manga: w, y: 0.72)
        } else {
            let w = L * 0.34
            casco(n, largo: L, manga: w, alto: 1.0, blanco, borda: blanco)
            caja(n, w * 1.01, 0.14, L * 0.86, azul, y: 0.18, z: -L * 0.03)                     // franja de flotación
            caja(n, w * 0.78, 0.75, L * 0.48, blanco, y: 1.2, z: -L * 0.1, chaflan: 0.12)          // salón
            caja(n, w * 0.8, 0.3, L * 0.42, vidrio, y: 1.3, z: -L * 0.08)                         // ventanales
            caja(n, w * 0.62, 0.45, L * 0.28, blanco, y: 1.8, z: -L * 0.16, chaflan: 0.1)          // flybridge
            caja(n, w * 0.64, 0.16, L * 0.06, vidrio, y: 1.95, z: -L * 0.02)
            caja(n, w * 0.7, 0.05, L * 0.32, Mat.pbr(NSColor(Color(hex: "#2b4f6e")), rugosidad: 0.6), y: 2.35, z: -L * 0.18)   // toldo
            for lado: CGFloat in [-0.25, 0.25] { cil(n, 0.025, 0.4, acero, x: lado * w, y: 2.15, z: -L * 0.3) }
            cil(n, 0.03, 0.8, acero, y: 2.7, z: -L * 0.12)                                       // antena
            baranda(n, largo: L, manga: w, y: 0.92)
        }
        return n
    }

    /// Caleta de pescadores en su islote: casitas de colores, muelle con pilotes, botes amarrados y varados, redes,
    /// cajones, mercado de pescado; un bote sale a pescar y vuelve. Marco local: +z hacia mar abierto.
    private func montarCaleta(_ r: SCNNode) {
        let G = marcoLocal(Islas.angCaleta, Islas.rCaleta); r.addChildNode(G)
        let madera = Mat.textura(.madera, repetir: 4, tinte: "#7a5634"), poste = Mat.textura(.madera, repetir: 1, tinte: "#4a3524")
        let colores = ["#c0392b", "#1f6fb2", "#d68910", "#196f3d", "#f1c40f", "#8e44ad"].map { NSColor(Color(hex: $0)) }
        // Calle de tierra desde el puente
        caja(G, 4, 0.04, 14, Mat.textura(.adoquin, repetir: 3, tinte: "#b9a58a", mezcla: 0.5), y: 0.03, z: -13)
        // Casitas de pescadores
        for (k, (x, z)) in [(CGFloat(-10), CGFloat(-6)), (-12, 2), (10, -6), (12, 2)].enumerated() {
            let H = SCNNode(); H.position = SCNVector3(x, 0, z); H.eulerAngles.y = x < 0 ? .pi / 2 : -.pi / 2; G.addChildNode(H)
            caja(H, 3.6, 3.0, 3.2, Mat.textura(.madera, repetir: 1, tinte: ["#e74c3c", "#3498db", "#f4d03f", "#58d68d"][k]))
            let t = NSBezierPath(); t.move(to: NSPoint(x: -2.0, y: 0)); t.line(to: NSPoint(x: 2.0, y: 0)); t.line(to: NSPoint(x: 0, y: 1.3)); t.close()
            H.addChildNode(nodo(SCNShape(path: t, extrusionDepth: 3.5), Mat.pbr(NSColor(Color(hex: "#7b3f22")), rugosidad: 0.8), y: 3.0))
            caja(H, 0.9, 2.0, 0.05, Mat.pbr(NSColor(Color(hex: "#4a3524"))), y: 1.0, z: 1.62)
            caja(H, 0.8, 0.6, 0.05, ventana(), x: 1.0, y: 1.6, z: 1.62)
            let q = Islas.caleta(x, z); nav.rect(q.x, q.y, 1.9, 1.7, Islas.angCaleta + H.eulerAngles.y)
        }
        // Mercado de pescado y cajones
        let K = SCNNode(); K.position = SCNVector3(0, 0, 6); G.addChildNode(K)
        caja(K, 5, 2.4, 2.6, Mat.textura(.madera, repetir: 2, tinte: "#d9b38c"))
        caja(K, 5.6, 0.15, 3.4, Mat.pbr(NSColor(Color(hex: "#1f6fb2"))), y: 2.5, z: 0.3)
        letrero(K, "CALETA DE PESCADORES · PESCADO FRESCO", "#1f6fb2", ancho: 5, alto: 0.5, y: 2.9, z: 1.3)
        let kq = Islas.caleta(0, 6); nav.rect(kq.x, kq.y, 2.6, 1.4, Islas.angCaleta)
        for k in 0..<6 { caja(G, 0.6, 0.35, 0.4, Mat.pbr(NSColor(Color(hex: k % 2 == 0 ? "#2e86c1" : "#e67e22"))), x: 4 + CGFloat(k % 3) * 0.65, y: 0.17 + CGFloat(k / 3) * 0.36, z: 9) }
        // Redes secándose
        let red = Mat.pbr(NSColor(Color(hex: "#3d6b5a")), rugosidad: 0.9); red.transparency = 0.7
        for x: CGFloat in [-8, -4.5] { cil(G, 0.06, 1.6, poste, x: x, z: 10) }
        caja(G, 3.5, 1.2, 0.04, red, x: -6.25, y: 1.0, z: 10)
        // Muelle con pilotes y botes
        caja(G, 2.6, 0.2, 20, madera, y: 0.25, z: 27)
        var z: CGFloat = 18
        while z <= 37 { for x: CGFloat in [-1.2, 1.2] { cil(G, 0.12, 1.6, poste, x: x, y: -0.3, z: z) }; z += 2.5 }
        for (k, (x, zz)) in [(CGFloat(-2.6), CGFloat(26)), (-2.6, 31), (2.6, 28), (2.6, 34)].enumerated() {
            let b = bote(colores[k]); b.position = SCNVector3(x, -0.5, zz); b.eulerAngles.y = 0.05 * CGFloat(k); G.addChildNode(b)
        }
        for (k, x) in [CGFloat(-9), -6, 6.5].enumerated() {
            let b = bote(colores[k + 3]); b.position = SCNVector3(x, 0.15, 19.5); b.eulerAngles = SCNVector3(0, 0.3 * CGFloat(k) - 0.3, 0.14); G.addChildNode(b)
        }
        escena.rootNode.addChildNode(aplanado(G, "elem:caleta"))
        G.removeFromParentNode()
        // Un bote sale a pescar y vuelve
        let sale = bote(colores[5], largo: 3.6)
        let pz0 = Islas.caleta(2.8, 24), pz1 = Islas.caleta(-10, 60), pz2 = Islas.caleta(20, 80)
        sale.position = SCNVector3(pz0.x, -0.5, pz0.y); sale.eulerAngles.y = Islas.angCaleta; sale.name = "elem:caleta"
        func ir(_ p: CGPoint, _ t: Double, _ yaw: CGFloat) -> SCNAction {
            .group([.move(to: SCNVector3(p.x, -0.5, p.y), duration: t), .rotateTo(x: 0, y: yaw, z: 0, duration: 2, usesShortestUnitArc: true)])
        }
        let a = Islas.angCaleta
        sale.runAction(.repeatForever(.sequence([.wait(duration: 20), ir(pz1, 16, a - 0.2), ir(pz2, 11, a + 1.0), .wait(duration: 18), ir(pz1, 11, a - 1.6), ir(pz0, 16, a + .pi)])))
        escena.rootNode.addChildNode(sale)
        montarGenteCaleta(sale)
    }

    /// Vida de la caleta: pescadores con caña sentados en el muelle (con farol de noche), un pescador que remienda redes,
    /// la pescadera atendiendo clientes en su mesón con hielo, gaviotas que planean, un pelícano en un pilote y el
    /// pescador a bordo del bote que sale a faenar. El mercado y las gaviotas descansan de noche.
    private func montarGenteCaleta(_ bote: SCNNode) {
        let G = marcoLocal(Islas.angCaleta, Islas.rCaleta); escena.rootNode.addChildNode(G)
        let pieles = ["#a8714d", "#d9a47c", "#7a4e33", "#c68e6a", "#e8b896"].map { NSColor(Color(hex: $0)) }
        let ropas = ["#e67e22", "#1f3a5f", "#f4d03f", "#7b241c", "#2e4053", "#d35400", "#566573"].map { NSColor(Color(hex: $0)) }
        var k = 0
        func gente(_ mujer: Bool = false, _ edad: Edad = .adulto, sombrero: Bool = true) -> PersonaPlaya {
            k += 1; return personaPlaya(mujer: mujer, edad: edad, piel: pieles[k % pieles.count], traje: ropas[k % ropas.count], pelo: NSColor(Color(hex: "#2b1d14")), ropa: true, sombrero: sombrero)
        }
        let cana = Mat.pbr(NSColor(Color(hex: "#3b2a1a")), rugosidad: 0.4, metal: 0.2), hilo = Mat.pbr(NSColor(calibratedWhite: 0.9, alpha: 1))
        let farol = Mat.emisivo(NSColor(calibratedRed: 1, green: 0.8, blue: 0.45, alpha: 1), fuerza: 1.3); focos.append(farol)
        var azar = Azar(semilla: 23)
        // Pescadores sentados en el borde del muelle (tablero a 0,35 m), piernas colgando sobre el agua
        for (lado, z) in [(CGFloat(-1), CGFloat(21)), (1, 23), (-1, 35.5)] {
            let b = gente(k == 2, k == 1 ? .mayor : .adulto)
            sentado(b)
            for br in b.brazos { br.eulerAngles.x = -0.75 }
            for c in b.codos { c.eulerAngles.x = -0.7 }
            b.raiz.position = SCNVector3(lado * 1.2, -0.52, z); b.raiz.eulerAngles.y = lado * .pi / 2
            G.addChildNode(b.raiz)
            // Caña que sube desde las manos hacia el mar y cabecea; el hilo baja al agua
            let base = SCNVector3(lado * 1.75, 0.72, z), largo: CGFloat = 2.6, inc: CGFloat = 0.85
            let pv = SCNNode(); pv.position = base; pv.eulerAngles.z = -lado * inc; G.addChildNode(pv)
            pv.addChildNode(nodo(SCNCylinder(radius: 0.018, height: largo), cana, y: largo / 2))
            pv.runAction(.repeatForever(.sequence([.rotateTo(x: 0, y: 0, z: -lado * (inc + 0.08), duration: 1.6 + Double(azar.real())),
                                                   .rotateTo(x: 0, y: 0, z: -lado * inc, duration: 1.4)])))
            let px = base.x + lado * sin(inc) * largo, py = base.y + cos(inc) * largo
            G.addChildNode(nodo(SCNCylinder(radius: 0.005, height: py + 0.45), hilo, y: (py - 0.45) / 2, x: px, z: z))
            G.addChildNode(nodo(SCNSphere(radius: 0.05), Mat.pbr(NSColor.systemRed), y: -0.42, x: px, z: z))           // flotador
            caja(G, 0.3, 0.22, 0.25, Mat.pbr(NSColor(Color(hex: "#5d6d7e")), rugosidad: 0.6), x: lado * 0.75, y: 0.46, z: z - 0.5)   // balde
            cil(G, 0.07, 0.22, farol, x: lado * 0.75, y: 0.46, z: z + 0.45)
        }
        // Pescador que remienda la red colgada
        let r = gente(false, .mayor)
        r.raiz.position = SCNVector3(-6.3, 0.04, 10.7); r.raiz.eulerAngles.y = .pi
        for br in r.brazos { br.eulerAngles.x = -0.9 }
        for (j, c) in r.codos.enumerated() {
            c.runAction(.repeatForever(.sequence([.wait(duration: Double(j) * 0.4), .rotateTo(x: -1.3, y: 0, z: 0, duration: 0.5), .rotateTo(x: -0.7, y: 0, z: 0, duration: 0.6)])))
        }
        G.addChildNode(r.raiz); soloDeDia.append(r.raiz)
        // Mesón con hielo y pescado fresco, la pescadera y clientes
        let M = SCNNode(); G.addChildNode(M); soloDeDia.append(M)
        caja(M, 3.2, 0.85, 0.7, Mat.textura(.madera, repetir: 1, tinte: "#8a6a4a"), y: 0.425, z: 8.3)
        caja(M, 3.1, 0.08, 0.62, Mat.pbr(NSColor(calibratedRed: 0.88, green: 0.95, blue: 1, alpha: 1), rugosidad: 0.15), y: 0.89, z: 8.3)
        let plata = Mat.pbr(NSColor(calibratedRed: 0.72, green: 0.76, blue: 0.8, alpha: 1), rugosidad: 0.2, metal: 0.7), rojo = Mat.pbr(NSColor(Color(hex: "#c0392b")), rugosidad: 0.4)
        for i in 0..<10 {
            let pez = nodo(SCNCapsule(capRadius: 0.06, height: 0.42), i % 4 == 3 ? rojo : plata, y: 0.96, x: -1.35 + CGFloat(i) * 0.3, z: 8.25 + (i % 2 == 0 ? 0.12 : -0.12))
            pez.eulerAngles = SCNVector3(0, 0.3, .pi / 2); M.addChildNode(pez)
        }
        let q = Islas.caleta(0, 8.3); nav.rect(q.x, q.y, 1.7, 0.45, Islas.angCaleta)
        let v = gente(true, .adulto, sombrero: false)
        v.raiz.position = SCNVector3(0.3, 0.04, 7.62)
        for br in v.brazos { br.eulerAngles.x = -0.5 }
        v.codos[1].runAction(.repeatForever(.sequence([.rotateTo(x: -1.4, y: 0, z: 0, duration: 0.7), .rotateTo(x: -0.6, y: 0, z: 0, duration: 0.7), .wait(duration: 1.5)])))
        M.addChildNode(v.raiz)
        for (x, mujer) in [(CGFloat(-0.9), true), (0.9, false), (2.0, true)] {
            let c = gente(mujer, x > 1.5 ? .mayor : .adulto, sombrero: false)
            c.raiz.position = SCNVector3(x, 0.04, 9.45); c.raiz.eulerAngles.y = .pi + (x > 1.5 ? 0.4 : 0)
            quieto(c, gesto: x < 0, azar: &azar); M.addChildNode(c.raiz)
        }
        // Gaviotas planeando en círculos sobre la caleta, aleteando a ratos
        let pluma = Mat.pbr(NSColor(calibratedWhite: 0.96, alpha: 1), rugosidad: 0.7), gris = Mat.pbr(NSColor(calibratedWhite: 0.55, alpha: 1), rugosidad: 0.7)
        for i in 0..<6 {
            let orbita = SCNNode(); orbita.position = SCNVector3(CGFloat(i % 3) * 4 - 4, 6 + CGFloat(i) * 0.9, 14 + CGFloat(i / 3) * 10)
            let ave = SCNNode(); ave.position = SCNVector3(7 + CGFloat(i) * 1.3, 0, 0); orbita.addChildNode(ave)
            let cuerpo = nodo(SCNCapsule(capRadius: 0.07, height: 0.45), pluma); cuerpo.eulerAngles.x = .pi / 2; ave.addChildNode(cuerpo)
            ave.addChildNode(nodo(SCNCone(topRadius: 0, bottomRadius: 0.025, height: 0.08), Mat.pbr(NSColor.systemYellow), z: 0.26))
            for lado: CGFloat in [-1, 1] {
                let ala = SCNNode(); ala.position = SCNVector3(lado * 0.05, 0.02, 0); ave.addChildNode(ala)
                ala.addChildNode(nodo(SCNBox(width: 0.5, height: 0.015, length: 0.16, chamferRadius: 0.005), pluma, x: lado * 0.25))
                ala.addChildNode(nodo(SCNBox(width: 0.2, height: 0.016, length: 0.12, chamferRadius: 0.005), gris, x: lado * 0.55))
                ala.runAction(.repeatForever(.sequence([.rotateTo(x: 0, y: 0, z: lado * 0.45, duration: 0.18), .rotateTo(x: 0, y: 0, z: -lado * 0.3, duration: 0.18),
                                                        .rotateTo(x: 0, y: 0, z: lado * 0.45, duration: 0.18), .rotateTo(x: 0, y: 0, z: lado * 0.1, duration: 0.2),
                                                        .wait(duration: 1.5 + Double(i) * 0.4)])))
            }
            ave.eulerAngles = SCNVector3(0, 0, -0.25)
            orbita.runAction(.repeatForever(.rotateBy(x: 0, y: (i % 2 == 0 ? 1 : -1) * .pi * 2, z: 0, duration: 14 + Double(i) * 2)))
            if i % 2 == 1 { ave.eulerAngles.y = .pi }
            G.addChildNode(orbita); soloDeDia.append(orbita)
        }
        // Pelícano posado en el último pilote del muelle
        let pel = SCNNode(); pel.position = SCNVector3(1.2, 0.55, 37.2); pel.eulerAngles.y = -.pi / 2; G.addChildNode(pel)
        let pc = nodo(SCNSphere(radius: 0.28), Mat.pbr(NSColor(calibratedWhite: 0.45, alpha: 1), rugosidad: 0.8), y: 0.25); pc.scale = SCNVector3(0.8, 0.9, 1.3); pel.addChildNode(pc)
        let cuello = nodo(SCNCapsule(capRadius: 0.06, height: 0.4), pluma, y: 0.55, z: 0.18); cuello.eulerAngles.x = 0.3; pel.addChildNode(cuello)
        pel.addChildNode(nodo(SCNSphere(radius: 0.09), pluma, y: 0.76, z: 0.25))
        let pico = nodo(SCNCone(topRadius: 0.01, bottomRadius: 0.05, height: 0.5), Mat.pbr(NSColor(Color(hex: "#d4a24c"))), y: 0.72, z: 0.5); pico.eulerAngles.x = .pi / 2 + 0.25; pel.addChildNode(pico)
        pel.runAction(.repeatForever(.sequence([.wait(duration: 6), .rotateBy(x: 0, y: 0.6, z: 0, duration: 0.6), .wait(duration: 3), .rotateBy(x: 0, y: -0.6, z: 0, duration: 0.6)])))
        // Pescador a bordo del bote que sale a faenar, con la mano en la caña del motor
        let p = gente(false, .adulto)
        sentado(p); p.brazos[0].eulerAngles.x = -0.5; p.codos[0].eulerAngles.x = -0.6
        p.raiz.position = SCNVector3(0, -0.15, -1.1); bote.addChildNode(p.raiz)
    }

    private func montarBalneario(_ r: SCNNode) {
        let G = marcoLocal(Islas.angBalneario, 0); G.position.y = -0.1; r.addChildNode(G)   // la playa baja: queda a media pendiente
        let poste = Mat.pbr(NSColor(calibratedWhite: 0.9, alpha: 1)), madera = Mat.textura(.madera, repetir: 2, tinte: "#b08a5c")
        let colores = ["#e74c3c", "#f1c40f", "#3498db", "#2ecc71", "#e67e22", "#9b59b6"].map { NSColor(Color(hex: $0)) }
        var k = 0
        for fila in 0..<2 { for i in 0..<6 {
            let x = -11 + CGFloat(i) * 4.4 + CGFloat(fila) * 2.2, z: CGFloat = 78.4 + CGFloat(fila) * 2.6
            cil(G, 0.04, 2.2, poste, x: x, z: z)
            G.addChildNode(nodo(SCNCone(topRadius: 0.05, bottomRadius: 1.2, height: 0.5), Mat.pbr(colores[k % colores.count], rugosidad: 0.7), y: 2.2, x: x, z: z))
            let silla = caja(G, 0.6, 0.12, 1.6, Mat.pbr(NSColor(calibratedWhite: 0.97, alpha: 1)), x: x + 0.9, y: 0.25, z: z - 0.3); silla.eulerAngles.x = -0.15
            caja(G, 0.8, 0.02, 1.7, Mat.pbr(colores[(k + 2) % colores.count]), x: x - 0.9, y: 0.01, z: z)
            k += 1
        } }
        // Torre del salvavidas
        let T = SCNNode(); T.position = SCNVector3(13, 0, 79.5); G.addChildNode(T)
        for x: CGFloat in [-0.7, 0.7] { for z: CGFloat in [-0.7, 0.7] { cil(T, 0.07, 2.4, madera, x: x, z: z) } }
        caja(T, 1.8, 1.2, 1.8, Mat.pbr(NSColor(Color(hex: "#e74c3c"))), y: 3.0)
        caja(T, 2.0, 0.12, 2.0, madera, y: 3.7)
        cil(T, 0.03, 1.6, poste, y: 4.5, z: 0.8)
        caja(T, 0.7, 0.45, 0.02, Mat.pbr(NSColor.systemRed), x: 0.36, y: 5.0, z: 0.8)
        letrero(T, "SALVAVIDAS", "#e74c3c", ancho: 1.7, alto: 0.35, y: 3.0, z: 0.92)
        // Malla de vóleibol, quiosco y boyas
        for x: CGFloat in [-15, -9] { cil(G, 0.05, 2.4, poste, x: x, z: 76.4) }
        let malla = Mat.pbr(NSColor(calibratedWhite: 0.95, alpha: 1)); malla.transparency = 0.6
        caja(G, 6, 0.8, 0.03, malla, x: -12, y: 2.0, z: 76.4)
        let Q = SCNNode(); Q.position = SCNVector3(2, 0, 74.4); G.addChildNode(Q)
        caja(Q, 3.4, 2.4, 2.0, Mat.textura(.madera, repetir: 2, tinte: "#e8d2b0"))
        caja(Q, 3.8, 0.15, 2.6, Mat.pbr(NSColor(Color(hex: "#e67e22"))), y: 2.5, z: 0.3)
        letrero(Q, "BALNEARIO VILLA · HELADOS Y JUGOS", "#e67e22", ancho: 3.4, alto: 0.45, y: 2.85, z: 1.05)
        let qp = Islas.w(Islas.angBalneario, 0, 2, 74.4); nav.rect(qp.x, qp.y, 1.8, 1.1, Islas.angBalneario)
        let boya = [Mat.pbr(NSColor.systemRed), Mat.pbr(NSColor.white)]
        for i in 0..<14 { G.addChildNode(nodo(SCNSphere(radius: 0.28), boya[i % 2], y: -0.4, x: -12 + CGFloat(i) * 2.4, z: 95)) }
        escena.rootNode.addChildNode(aplanado(G, "elem:balneario"))
        G.removeFromParentNode()
        montarGenteBalneario(Islas.angBalneario)
    }

    private func montarMarina(_ r: SCNNode) {
        let G = marcoLocal(Islas.angMarina, 0); r.addChildNode(G)
        let tabla = Mat.textura(.madera, repetir: 4, tinte: "#a8865f"), flot = Mat.pbr(NSColor(calibratedWhite: 0.85, alpha: 1))
        caja(G, 2.2, 0.2, 20, tabla, y: -0.2, z: 92)
        caja(G, 2.4, 0.3, 20, flot, y: -0.42, z: 92)
        var lancha: SCNNode?
        for (k, z) in [CGFloat(86), 92, 98].enumerated() {
            for lado: CGFloat in [-1, 1] {
                caja(G, 7, 0.2, 1.2, tabla, x: lado * 4.6, y: -0.2, z: z)
                let b: SCNNode
                switch (k + (lado > 0 ? 1 : 0)) % 3 {
                case 0: b = yate(6.5, vela: false)
                case 1: b = yate(5.5, vela: true)
                default: b = Modelos.nodo("pesquero", largo: 6) ?? bote(NSColor(Color(hex: "#c0392b")), largo: 3.8)
                }
                b.position = SCNVector3(lado * 4.8, -0.5, z + 2.4); b.eulerAngles.y = .pi / 2 * lado
                G.addChildNode(b)
                if k == 2 && lado > 0 { lancha = b }
            }
        }
        _ = lancha
        letrero(G, "MARINA VILLA · YATES Y LANCHAS", "#1a5276", ancho: 7.5, alto: 0.7, y: 1.8, z: 82.3)
        for x: CGFloat in [-3.5, 3.5] { cil(G, 0.06, 2.1, Mat.pbr(NSColor(calibratedWhite: 0.3, alpha: 1)), x: x, z: 82.3) }
        escena.rootNode.addChildNode(aplanado(G, "elem:marina"))
        G.removeFromParentNode()
        // Lancha rápida que pasea frente a la costa
        let l = yate(4.5, vela: false); l.name = "elem:marina"
        let c = Islas.w(Islas.angMarina, 0, 0, 118)
        l.position = SCNVector3(c.x + 14, -0.4, c.y)
        let orbita = SCNNode(); orbita.position = SCNVector3(c.x, 0, c.y); escena.rootNode.addChildNode(orbita)
        l.position = SCNVector3(14, -0.5, 0); l.eulerAngles.y = .pi; orbita.addChildNode(l)
        orbita.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 40)))
    }

    // MARK: Letreros de la villa

    /// «SILICON VILLA»: dos letreros de una cara, en lugares distintos. Uno en la playa del fondo mirando a la villa
    /// (se lee desde la vista general) y otro en la playa del frente, junto al puente, mirando al mar (lo leen los
    /// que llegan). Letras en relieve, iluminadas de noche, sobre una viga con su subtítulo.
    private func montarLetreroVilla(_ r: SCNNode) {
        letreroVilla(ang: .pi, r: 78.5, haciaMar: false)
        letreroVilla(ang: 0.34, r: 79, haciaMar: true)
    }

    private func letreroVilla(ang: CGFloat, r: CGFloat, haciaMar: Bool) {
        let blanco = Mat.pbr(NSColor(calibratedWhite: 0.98, alpha: 1), rugosidad: 0.4)
        blanco.emission.contents = NSColor(calibratedRed: 0.9, green: 0.95, blue: 1, alpha: 1); blanco.emission.intensity = 0.25
        let lado = Mat.pbr(NSColor(Color(hex: "#9aa7b4")), rugosidad: 0.5, metal: 0.3), poste = Mat.pbr(NSColor(calibratedWhite: 0.35, alpha: 1), metal: 0.6)
        let g = marcoLocal(ang, r)                         // +z local = hacia el mar
        let F = SCNNode(); F.eulerAngles.y = haciaMar ? 0 : .pi; g.addChildNode(F)   // +z de F = hacia donde mira el letrero
        let t = SCNText(string: "SILICON VILLA", extrusionDepth: 0.4)
        t.font = NSFont.systemFont(ofSize: 2.6, weight: .black); t.flatness = 0.1
        t.materials = [blanco, lado, lado]
        let n = SCNNode(geometry: t)
        let (mn, mx) = n.boundingBox
        n.position = SCNVector3(-(mn.x + mx.x) / 2, 1.5 - mn.y, 0.05)      // centrado sobre la viga (sin pivot: el aplanado lo ignora)
        F.addChildNode(n)
        caja(F, 21, 0.3, 0.3, poste, y: 1.35)
        for x: CGFloat in [-9.5, -7.25, -5.0, 5.0, 7.25, 9.5] { caja(F, 0.2, 1.4, 0.2, poste, x: x, y: 0.7) }   // la placa central queda libre
        letrero(F, "VALLE DE LOS AGENTES", "#1a5276", ancho: 9, alto: 0.75, y: 0.75, z: 0.2, brillo: 0.9)
        escena.rootNode.addChildNode(aplanado(g, "elem:letrero"))
    }

    // MARK: Orilla natural: playa en pendiente bajo el agua y espuma de las olas

    /// Playa que baja suave hasta perderse bajo el agua (sin escalón) y una franja de espuma que respira en la orilla.
    func playaNatural(centro c: CGPoint, desde r0: CGFloat, ancho: CGFloat = 10, balneario: CGFloat? = nil) {
        let arena = Mat.textura(.arena, repetir: max(8, r0 / 3))
        escena.rootNode.addChildNode(nodo(SCNCone(topRadius: r0, bottomRadius: r0 + ancho, height: 0.75), arena, y: -0.395, x: c.x, z: c.y))
        let orilla = r0 + 0.48 / 0.75 * ancho                     // donde la pendiente cruza el nivel del mar (y −0,5)
        marConOleaje(centro: c, orilla: orilla, ancho: r0 > 70 ? 34 : 22, balneario: balneario)
    }

    // MARK: Gente de la playa: hombres y mujeres de distintas edades, con articulaciones

    enum Edad { case nino, joven, adulto, mayor }

    /// Persona de playa articulada: cuerpo (fusionado) y brazos/piernas como pivotes en hombros y caderas para
    /// animar la marcha. Anatomía por cápsulas: cintura, tórax, cuello, cara con ojos y nariz; pelo según sexo y edad.
    struct PersonaPlaya { let raiz: SCNNode; let piernas: [SCNNode]; let brazos: [SCNNode]; let cuerpo: SCNNode; var rodillas: [SCNNode] = []; var codos: [SCNNode] = [] }

    private func personaPlaya(mujer: Bool, edad: Edad, piel: NSColor, traje: NSColor, pelo: NSColor, ropa: Bool = false,
                              sombrero: Bool = false) -> PersonaPlaya {
        let raiz = SCNNode(), c = SCNNode()
        let mp = Mat.pbr(piel, rugosidad: 0.5), mt = Mat.pbr(traje, rugosidad: 0.65)
        let mpel = Mat.pbr(edad == .mayor ? NSColor(calibratedWhite: 0.85, alpha: 1) : pelo, rugosidad: 0.75)
        let ancho: CGFloat = mujer ? 0.86 : 1.0
        func capsula(_ g: SCNNode, _ r: CGFloat, _ h: CGFloat, _ m: SCNMaterial, x: CGFloat = 0, y: CGFloat, z: CGFloat = 0, rotz: CGFloat = 0) {
            let k = nodo(SCNCapsule(capRadius: r, height: max(h, 2 * r + 0.01)), m, y: y, x: x, z: z); k.eulerAngles.z = rotz; g.addChildNode(k)
        }
        // Cuerpo: cadera con traje, cintura, tórax, cuello, cabeza
        capsula(c, mujer ? 0.155 : 0.14, 0.34, mt, y: 0.98, rotz: .pi / 2)
        capsula(c, mujer ? 0.11 : 0.13, 0.22, ropa ? mt : mp, y: 1.13)
        let torax = nodo(SCNCapsule(capRadius: 0.15 * ancho, height: 0.4), ropa ? mt : mp, y: 1.33)
        torax.scale = SCNVector3(edad == .mayor && !mujer ? 1.28 : 1.15 * ancho, 1, edad == .mayor && !mujer ? 0.9 : 0.75); c.addChildNode(torax)
        if mujer && !ropa {
            for lado: CGFloat in [-1, 1] { c.addChildNode(nodo(SCNSphere(radius: 0.068), mt, y: 1.36, x: lado * 0.075, z: 0.085)) }
            caja(c, 0.3, 0.03, 0.02, mt, y: 1.4, z: 0.1)
        }
        if ropa { let cm = nodo(SCNCapsule(capRadius: 0.17 * ancho, height: 0.46), mt, y: 1.3); cm.scale = SCNVector3(1.15 * ancho, 1, 0.8); c.addChildNode(cm) }
        capsula(c, 0.05, 0.12, mp, y: 1.57)
        let cabeza = nodo(SCNSphere(radius: 0.11), mp, y: 1.72); cabeza.scale = SCNVector3(0.92, 1.08, 1); c.addChildNode(cabeza)
        let ojo = Mat.pbr(NSColor(calibratedWhite: 0.08, alpha: 1), rugosidad: 0.3)
        for lado: CGFloat in [-1, 1] { c.addChildNode(nodo(SCNSphere(radius: 0.014), ojo, y: 1.745, x: lado * 0.04, z: 0.1)) }
        let nariz = nodo(SCNCone(topRadius: 0, bottomRadius: 0.02, height: 0.04), mp, y: 1.71, z: 0.112); nariz.eulerAngles.x = .pi / 2; c.addChildNode(nariz)
        caja(c, 0.05, 0.01, 0.01, Mat.pbr(NSColor(Color(hex: "#9c4a4a"))), y: 1.665, z: 0.105)
        if mujer {
            let p = nodo(SCNSphere(radius: 0.118), mpel, y: 1.76, z: -0.012); c.addChildNode(p)
            capsula(c, 0.08, edad == .nino ? 0.2 : 0.36, mpel, y: 1.6, z: -0.07)
        } else if edad != .mayor || sombrero {
            let p = nodo(SCNSphere(radius: 0.114), mpel, y: 1.765, z: -0.014); p.scale = SCNVector3(1, 0.7, 1); c.addChildNode(p)
        } else {
            for lado: CGFloat in [-1, 1] { c.addChildNode(nodo(SCNSphere(radius: 0.05), mpel, y: 1.72, x: lado * 0.09, z: -0.03)) }
        }
        if sombrero {
            let paja = Mat.pbr(NSColor(Color(hex: "#e2cd94")), rugosidad: 0.9)
            cil(c, 0.22, 0.02, paja, y: 1.83); cil(c, 0.11, 0.1, paja, y: 1.88)
        }
        Villa3D.Coordinador.hornear(c)
        let cuerpo = c.flattenedClone(); raiz.addChildNode(cuerpo)
        // Piernas: pivote en la cadera
        var piernas: [SCNNode] = [], rodillas: [SCNNode] = [], codos: [SCNNode] = []
        for lado: CGFloat in [-1, 1] {
            let pv = SCNNode(); pv.position = SCNVector3(lado * 0.1, 0.95, 0)
            let g = SCNNode(), s = SCNNode()                 // muslo y, desde la rodilla, pierna con el pie
            capsula(g, 0.075, 0.46, ropa ? mt : mp, y: -0.23)
            g.addChildNode(nodo(SCNSphere(radius: 0.068), ropa ? mt : mp, y: -0.46))
            capsula(s, 0.06, 0.44, ropa ? mt : mp, y: -0.21)
            caja(s, 0.1, 0.06, 0.24, Mat.pbr(NSColor(calibratedWhite: ropa ? 0.12 : 0.6, alpha: 1), rugosidad: 0.6), y: -0.45, z: 0.05, chaflan: 0.025)
            Villa3D.Coordinador.hornear(g); pv.addChildNode(g.flattenedClone())
            let rod = SCNNode(); rod.position = SCNVector3(0, -0.46, 0)
            Villa3D.Coordinador.hornear(s); rod.addChildNode(s.flattenedClone()); pv.addChildNode(rod)
            raiz.addChildNode(pv); piernas.append(pv); rodillas.append(rod)
        }
        // Brazos: pivote en el hombro
        var brazos: [SCNNode] = []
        for lado: CGFloat in [-1, 1] {
            let pv = SCNNode(); pv.position = SCNVector3(lado * 0.22 * ancho, 1.48, 0); pv.eulerAngles.z = lado * 0.08
            let g = SCNNode(), a = SCNNode()                 // brazo y, desde el codo, antebrazo con la mano
            capsula(g, 0.055, 0.32, ropa ? mt : mp, y: -0.16)
            capsula(a, 0.045, 0.3, mp, y: -0.14)
            let mano = nodo(SCNSphere(radius: 0.048), mp, y: -0.31); mano.scale = SCNVector3(0.8, 1.25, 0.6); a.addChildNode(mano)
            Villa3D.Coordinador.hornear(g); pv.addChildNode(g.flattenedClone())
            let codo = SCNNode(); codo.position = SCNVector3(0, -0.3, 0)
            Villa3D.Coordinador.hornear(a); codo.addChildNode(a.flattenedClone()); pv.addChildNode(codo)
            raiz.addChildNode(pv); brazos.append(pv); codos.append(codo)
        }
        let escala: CGFloat = edad == .nino ? 0.56 : edad == .joven ? 0.92 : edad == .mayor ? 0.96 : 1.0
        raiz.scale = SCNVector3(escala, escala, escala)
        if edad == .mayor { cuerpo.eulerAngles.x = 0.07 }
        return PersonaPlaya(raiz: raiz, piernas: piernas, brazos: brazos, cuerpo: cuerpo, rodillas: rodillas, codos: codos)
    }

    /// Sentado en una silla o banca: muslos horizontales, piernas verticales y pies apoyados, levemente separados.
    private func sentado(_ p: PersonaPlaya) {
        for (k, pierna) in p.piernas.enumerated() { pierna.eulerAngles = SCNVector3(-1.52, 0, (k == 0 ? -1 : 1) * 0.06) }
        for rod in p.rodillas { rod.eulerAngles.x = 1.5 }
    }

    /// Marcha natural: zancada de piernas, balanceo de brazos opuesto, rebote y leve giro de cadera, a la cadencia dada.
    private func caminar(_ p: PersonaPlaya, ciclo: Double, amplitud: CGFloat = 0.42) {
        for (k, pierna) in p.piernas.enumerated() {
            let s: CGFloat = k == 0 ? 1 : -1
            let ida = SCNAction.rotateTo(x: s * amplitud, y: 0, z: 0, duration: ciclo / 2), vuelta = SCNAction.rotateTo(x: -s * amplitud, y: 0, z: 0, duration: ciclo / 2)
            ida.timingMode = .easeInEaseOut; vuelta.timingMode = .easeInEaseOut
            pierna.runAction(.repeatForever(.sequence([ida, vuelta])), forKey: "paso")
        }
        for (k, brazo) in p.brazos.enumerated() {
            let s: CGFloat = k == 0 ? -1 : 1, z = brazo.eulerAngles.z
            let ida = SCNAction.rotateTo(x: s * amplitud * 0.8, y: 0, z: z, duration: ciclo / 2), vuelta = SCNAction.rotateTo(x: -s * amplitud * 0.8, y: 0, z: z, duration: ciclo / 2)
            ida.timingMode = .easeInEaseOut; vuelta.timingMode = .easeInEaseOut
            brazo.runAction(.repeatForever(.sequence([ida, vuelta])), forKey: "paso")
        }
        for (k, rod) in p.rodillas.enumerated() {                 // la rodilla se flexiona cuando la pierna pasa adelante
            let flexa = SCNAction.rotateTo(x: amplitud * 1.3, y: 0, z: 0, duration: ciclo / 4), estira = SCNAction.rotateTo(x: 0.05, y: 0, z: 0, duration: ciclo / 4)
            flexa.timingMode = .easeOut; estira.timingMode = .easeIn
            rod.runAction(.sequence([.wait(duration: k == 0 ? ciclo / 2 : 0), .repeatForever(.sequence([flexa, estira, .wait(duration: ciclo / 2)]))]), forKey: "paso")
        }
        for codo in p.codos { codo.runAction(.rotateTo(x: -0.3, y: 0, z: 0, duration: 0.3), forKey: "paso") }
        // Rebote en posición absoluta: al cambiar de paso a quieto (o al revés) el torso nunca acumula altura sobre las piernas.
        p.cuerpo.position = SCNVector3(0, 0, 0)
        let sube = SCNAction.move(to: SCNVector3(0, 0.035, 0), duration: ciclo / 4), baja = SCNAction.move(to: SCNVector3(0, 0, 0), duration: ciclo / 4)
        sube.timingMode = .easeOut; baja.timingMode = .easeIn
        p.cuerpo.runAction(.repeatForever(.sequence([sube, baja])), forKey: "paso")
    }

    private func quieto(_ p: PersonaPlaya, gesto: Bool, azar: inout Azar) {
        for pierna in p.piernas { pierna.removeAction(forKey: "paso"); pierna.runAction(.rotateTo(x: 0, y: 0, z: 0, duration: 0.4)) }
        for rod in p.rodillas { rod.removeAction(forKey: "paso"); rod.runAction(.rotateTo(x: 0.04, y: 0, z: 0, duration: 0.4)) }
        for codo in p.codos { codo.removeAction(forKey: "paso"); codo.runAction(.rotateTo(x: -0.15, y: 0, z: 0, duration: 0.4)) }
        for (k, brazo) in p.brazos.enumerated() {
            brazo.removeAction(forKey: "paso")
            let z = brazo.eulerAngles.z
            if gesto && k == 1 {        // conversa: mueve la mano
                brazo.runAction(.repeatForever(.sequence([.rotateTo(x: -1.0, y: 0, z: z, duration: 0.8), .rotateTo(x: -0.6, y: 0, z: z + 0.2, duration: 0.7),
                                                          .rotateTo(x: -0.9, y: 0, z: z, duration: 0.9), .wait(duration: 1.5 + Double(azar.real()) * 2)])), forKey: "paso")
            } else { brazo.runAction(.rotateTo(x: 0, y: 0, z: z, duration: 0.4)) }
        }
        p.cuerpo.removeAction(forKey: "paso")
        p.cuerpo.runAction(.move(to: SCNVector3(0, 0, 0), duration: 0.3))
        let peso = SCNAction.sequence([.rotateTo(x: p.cuerpo.eulerAngles.x, y: 0, z: 0.025, duration: 2.2), .rotateTo(x: p.cuerpo.eulerAngles.x, y: 0, z: -0.02, duration: 2.6)])
        p.cuerpo.runAction(.repeatForever(peso), forKey: "paso")
    }

    private func montarGenteBalneario(_ ang: CGFloat) {
        let pieles = ["#f1c9a5", "#d9a47c", "#a8714d", "#7a4e33", "#e8b896", "#c68e6a"].map { NSColor(Color(hex: $0)) }
        let trajes = ["#e74c3c", "#2980b9", "#f1c40f", "#16a085", "#8e44ad", "#e67e22", "#2c3e50", "#ff6f91"].map { NSColor(Color(hex: $0)) }
        let pelos = ["#2b1d14", "#5a3a22", "#c9a66b", "#0f0f0f", "#8a4b2a", "#3b2a1a"].map { NSColor(Color(hex: $0)) }
        let G = marcoLocal(ang, 0); escena.rootNode.addChildNode(G)
        var azar = Azar(semilla: 77)
        func p(_ k: Int) -> NSColor { pieles[k % pieles.count] }
        func tr(_ k: Int) -> NSColor { trajes[k % trajes.count] }
        func pe(_ k: Int) -> NSColor { pelos[k % pelos.count] }
        func yArena(_ z: CGFloat) -> CGFloat { z < 79 ? -0.02 : -0.02 - (z - 79) * 0.075 }
        // Tomando sol: acostados boca arriba o boca abajo, con brazos abiertos o bajo la cabeza
        for k in 0..<8 {
            let b = personaPlaya(mujer: k % 2 == 0, edad: k % 4 == 3 ? .mayor : k % 3 == 1 ? .joven : .adulto, piel: p(k), traje: tr(k), pelo: pe(k))
            let x = -10.5 + CGFloat(k) * 3.1 - 0.9, z = 78.6 + CGFloat(k % 2) * 2.6 + 0.7
            let bocaAbajo = k % 3 == 2
            b.raiz.eulerAngles = SCNVector3(bocaAbajo ? CGFloat.pi / 2 : -CGFloat.pi / 2, 0, 0)
            b.raiz.position = SCNVector3(x, yArena(z) + 0.12, z)
            for (j, br) in b.brazos.enumerated() { br.eulerAngles = SCNVector3(k % 2 == 0 ? -2.8 : 0, 0, (j == 0 ? -1 : 1) * (k % 2 == 0 ? 0.3 : 0.5)) }
            G.addChildNode(b.raiz); soloDeDia.append(b.raiz)
        }
        // Grupos conversando de pie (distintas edades), con gestos y cambio de peso
        let edades: [Edad] = [.joven, .adulto, .mayor, .adulto, .joven, .mayor, .adulto]
        for k in 0..<7 {
            let b = personaPlaya(mujer: k % 2 == 1, edad: edades[k], piel: p(k + 2), traje: tr(k + 3), pelo: pe(k + 1), sombrero: k == 2 || k == 5)
            let zp = 82.0 + azar.real() * 1.0, xg = -14 + CGFloat(k / 2) * 9 + CGFloat(k % 2) * 1.1
            b.raiz.position = SCNVector3(xg, yArena(zp), zp); b.raiz.eulerAngles.y = k % 2 == 0 ? 1.2 : -1.9
            quieto(b, gesto: k % 3 != 2, azar: &azar)
            G.addChildNode(b.raiz); soloDeDia.append(b.raiz)
        }
        // Niños haciendo un castillo de arena (palean con los brazos)
        let castillo = Mat.textura(.arena, repetir: 1, tinte: "#d8c08a")
        caja(G, 0.8, 0.35, 0.8, castillo, x: 5.55, y: yArena(83.4) + 0.16, z: 83.4)
        for (x, z) in [(CGFloat(5.25), CGFloat(83.1)), (5.85, 83.1), (5.25, 83.7), (5.85, 83.7)] { cil(G, 0.12, 0.6, castillo, x: x, y: yArena(z) + 0.3, z: z) }
        for k in 0..<2 {
            let b = personaPlaya(mujer: k == 0, edad: .nino, piel: p(k + 3), traje: tr(k + 1), pelo: pe(k + 2))
            b.raiz.position = SCNVector3(4.7 + CGFloat(k) * 1.7, yArena(83.4) - 0.22, 83.4); b.raiz.eulerAngles.y = k == 0 ? .pi / 2 : -.pi / 2
            for pierna in b.piernas { pierna.eulerAngles.x = -0.15 }                    // de rodillas: muslo vertical, pierna apoyada atrás
            for rod in b.rodillas { rod.eulerAngles.x = 1.55 }
            for brazo in b.brazos {
                brazo.runAction(.repeatForever(.sequence([.rotateTo(x: -1.3, y: 0, z: 0, duration: 0.5), .rotateTo(x: -0.5, y: 0, z: 0, duration: 0.6), .wait(duration: 0.4)])))
            }
            G.addChildNode(b.raiz); soloDeDia.append(b.raiz)
        }
        // Turistas caminando por la orilla: cada uno a su ritmo; a veces se detienen a mirar el mar
        for k in 0..<5 {
            let b = personaPlaya(mujer: k % 2 == 0, edad: [.adulto, .mayor, .joven, .adulto, .mayor][k], piel: p(k + 1), traje: tr(k + 4), pelo: pe(k + 3),
                                 ropa: k % 2 == 1, sombrero: k == 1 || k == 4)
            let z: CGFloat = 83.6 + CGFloat(k % 3) * 0.6, x0: CGFloat = -16 + CGFloat(k) * 2.5, x1: CGFloat = 18 - CGFloat(k) * 1.5
            let vel = 0.85 + Double(azar.real()) * 0.45, ciclo = 1.25 / vel * 0.95
            b.raiz.position = SCNVector3(x0, yArena(z), z); b.raiz.eulerAngles.y = .pi / 2
            G.addChildNode(b.raiz)
            if k >= 3 { soloDeDia.append(b.raiz) }               // de noche pasean solo algunos
            let medio = x0 + (x1 - x0) * (0.4 + azar.real() * 0.3)
            func tramo(_ hasta: CGFloat, desde: CGFloat) -> SCNAction {
                .sequence([.run { [weak self] _ in self?.caminar(b, ciclo: ciclo) }, .move(to: SCNVector3(hasta, yArena(z), z), duration: Double(abs(hasta - desde)) / vel)])
            }
            var az = Azar(semilla: UInt64(100 + k))
            let mira = SCNAction.sequence([.run { [weak self] _ in self?.quieto(b, gesto: false, azar: &az) }, .rotateTo(x: 0, y: 0, z: 0, duration: 1.2),
                                           .wait(duration: 4 + Double(k)), .rotateTo(x: 0, y: .pi / 2, z: 0, duration: 1.2)])
            b.raiz.runAction(.repeatForever(.sequence([
                .wait(duration: Double(k) * 3), tramo(medio, desde: x0), mira, tramo(x1, desde: medio),
                .run { [weak self] _ in self?.quieto(b, gesto: false, azar: &az) }, .rotateTo(x: 0, y: -.pi / 2, z: 0, duration: 1.5),
                tramo(x0, desde: x1), .run { [weak self] _ in self?.quieto(b, gesto: false, azar: &az) }, .rotateTo(x: 0, y: .pi / 2, z: 0, duration: 1.5)])))
        }
        // Nadadores a crol y a pecho dentro de las boyas, y bañistas con el agua a la cintura
        for k in 0..<8 {
            let b = personaPlaya(mujer: k % 2 == 1, edad: k == 5 ? .joven : .adulto, piel: p(k), traje: tr(k + 2), pelo: pe(k))
            let x = -10 + CGFloat(k) * 2.8 + azar.real(), z = 88.5 + azar.real() * 4.5
            if k % 3 == 0 {                                   // de pie en el agua, conversando
                b.raiz.position = SCNVector3(x, -1.25, z); b.raiz.eulerAngles.y = azar.real() * 6.28
                quieto(b, gesto: true, azar: &azar)
                b.raiz.runAction(.repeatForever(.sequence([.moveBy(x: 0, y: 0.08, z: 0, duration: 1.6), .moveBy(x: 0, y: -0.08, z: 0, duration: 1.6)])))
                G.addChildNode(b.raiz); soloDeDia.append(b.raiz); continue
            }
            let nadador = SCNNode(); nadador.position = SCNVector3(x, -0.62, z)
            b.raiz.eulerAngles = SCNVector3(CGFloat.pi / 2 - 0.08, 0, 0); b.raiz.position = SCNVector3(0, 0, -0.8)
            nadador.addChildNode(b.raiz)
            for (j, brazo) in b.brazos.enumerated() {                         // brazada de crol: vuelta completa, alternada
                brazo.eulerAngles.x = j == 0 ? 0 : .pi
                brazo.runAction(.repeatForever(.rotateBy(x: -2 * .pi, y: 0, z: 0, duration: 1.6)))
            }
            for (j, pierna) in b.piernas.enumerated() {                       // patada
                let s: CGFloat = j == 0 ? 1 : -1
                pierna.runAction(.repeatForever(.sequence([.rotateTo(x: s * 0.25, y: 0, z: 0, duration: 0.3), .rotateTo(x: -s * 0.25, y: 0, z: 0, duration: 0.3)])))
            }
            nadador.eulerAngles.y = .pi / 2
            let largo: CGFloat = 4 + azar.real() * 3
            nadador.runAction(.repeatForever(.sequence([.moveBy(x: largo, y: 0, z: 0, duration: Double(largo) / 0.7), .rotateBy(x: 0, y: .pi, z: 0, duration: 2),
                                                         .moveBy(x: -largo, y: 0, z: 0, duration: Double(largo) / 0.7), .rotateBy(x: 0, y: .pi, z: 0, duration: 2)])))
            nadador.runAction(.repeatForever(.sequence([.moveBy(x: 0, y: 0.06, z: 0, duration: 0.8), .moveBy(x: 0, y: -0.06, z: 0, duration: 0.8)])))
            G.addChildNode(nadador); soloDeDia.append(nadador)
        }
    }

    // MARK: Mar con oleaje (malla animada en la GPU)

    /// Franja de mar alrededor de la orilla: trenes de olas con frente irregular que avanzan, se peraltan al llegar
    /// (Gerstner), rompen en espuma con textura, la espuma sube por la arena y se retira; agua turquesa en lo bajo y
    /// azul profundo mar adentro, con brillos finos. Todo se calcula en la tarjeta gráfica.
    func marConOleaje(centro c: CGPoint, orilla: CGFloat, ancho: CGFloat = 34, balneario: CGFloat? = nil) {
        let nA = 720, nR = 56, r0 = orilla - 4, r1 = orilla + ancho
        var v: [SCNVector3] = [], uv: [CGPoint] = [], idx: [Int32] = []
        for j in 0...nR {
            let u = CGFloat(j) / CGFloat(nR), r = r0 + (r1 - r0) * pow(u, 1.7)
            for i in 0...nA {
                let a = CGFloat(i) / CGFloat(nA) * 2 * .pi
                v.append(SCNVector3(sin(a) * r, 0, cos(a) * r)); uv.append(CGPoint(x: CGFloat(i) / CGFloat(nA), y: u))
            }
        }
        let fila = Int32(nA + 1)
        for j in 0..<Int32(nR) { for i in 0..<Int32(nA) {
            let a = j * fila + i, b = a + 1, d = a + fila, e = d + 1
            idx += [a, d, b, b, d, e]
        } }
        let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: v), SCNGeometrySource(normals: Array(repeating: SCNVector3(0, 1, 0), count: v.count)),
                                        SCNGeometrySource(textureCoordinates: uv)],
                              elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = NSColor(calibratedRed: 0.1, green: 0.3, blue: 0.4, alpha: 1)
        m.roughness.contents = 0.06; m.metalness.contents = 0.1
        m.blendMode = .alpha; m.writesToDepthBuffer = true
        m.shaderModifiers = [
            .geometry: """
            #pragma arguments
            float orilla;
            float balx;
            float balz;
            #pragma varyings
            float2 pxz;
            float cresta;
            float prof;
            float bal;
            #pragma body
            float2 p = _geometry.position.xz;
            float r = length(p);
            float2 dir = p / max(r, 0.001);
            float ang = atan2(dir.y, dir.x);
            float d = r - orilla;
            float t = scn_frame.time;
            float bajo = 1.0 - smoothstep(0.0, 16.0, d);
            float amp = (0.05 + 0.13 * bajo) * smoothstep(-2.5, 1.5, d) * (1.0 - smoothstep(20.0, 34.0, d)) + 0.02;
            float k1 = 0.62 + 0.55 * bajo;
            float f1 = d * k1 + t * 1.2 + sin(ang * 7.0 + t * 0.15) * 1.1 + sin(ang * 23.0) * 0.35;
            float f2 = d * 1.7 - t * 1.7 + ang * 41.0;
            float f3 = p.x * 0.29 + p.y * 0.21 + t * 0.9;
            float s1 = sin(f1);
            float h = amp * (s1 + 0.22 * sin(f2)) + 0.03 * sin(f3) + 0.02 * sin(p.x * 0.71 - p.y * 0.53 - t * 1.3);
            float q = 0.6 * bajo;
            _geometry.position.xz -= dir * (q * amp * cos(f1) * 1.8);
            _geometry.position.y += h * smoothstep(-3.5, 0.3, d);
            float dh = amp * k1 * cos(f1) + 0.22 * amp * 1.7 * cos(f2);
            _geometry.normal = normalize(float3(-dh * dir.x, 1.0, -dh * dir.y));
            out.pxz = p;
            out.cresta = smoothstep(0.8, 1.0, s1) * (1.0 - smoothstep(1.5, 9.0, d)) * 0.9;
            out.prof = d;
            out.bal = smoothstep(0.95, 0.985, dot(dir, float2(balx, balz)));
            """,
            .surface: """
            #pragma body
            float d = in.prof;
            float2 p = in.pxz;
            float t = scn_frame.time;
            float3 hondo = float3(0.10, 0.30, 0.40), bajo = float3(0.18, 0.62, 0.64);
            float3 agua = mix(bajo, hondo, smoothstep(-1.0, 20.0, d));
            float n = sin(p.x * 2.3 + t * 1.4) * sin(p.y * 2.1 - t * 1.2) + 0.5 * sin(p.x * 5.7 - p.y * 4.9 + t * 2.1) + 0.25 * sin(p.x * 11.3 + p.y * 9.1 - t * 3.0);
            float espuma = clamp(in.cresta * (0.55 + 0.6 * n), 0.0, 1.0);
            float enBal = in.bal;                                  // solo en el balneario la ola sube por la arena
            float lava = (1.0 - smoothstep(-2.5, 0.8, d)) * (0.55 + 0.45 * sin(t * 1.2 + d * 1.6 + n * 1.5)) * mix(0.35, 1.0, enBal);
            espuma = max(espuma, clamp(lava * (0.7 + 0.4 * n), 0.0, 1.0));
            _surface.diffuse.rgb = mix(agua, float3(0.95, 0.97, 1.0), espuma);
            _surface.normal = normalize(_surface.normal + float3(n * 0.05, n * 0.03, n * 0.04));
            _surface.roughness = mix(0.05, 0.65, espuma);
            _surface.diffuse.a = (1.0 - smoothstep(24.0, 34.0, d)) * mix(0.92, 1.0, espuma) * mix(smoothstep(-0.4, 0.3, d), smoothstep(-3.2, -2.0, d), enBal);
            """
        ]
        m.setValue(orilla, forKey: "orilla")
        let b = balneario.map { CGPoint(x: sin($0), y: cos($0)) } ?? .zero
        m.setValue(b.x, forKey: "balx"); m.setValue(b.y, forKey: "balz")
        geo.materials = [m]
        let nodoMar = SCNNode(geometry: geo); nodoMar.position = SCNVector3(c.x, -0.47, c.y); nodoMar.castsShadow = false
        nodoMar.renderingOrder = 5
        escena.rootNode.addChildNode(nodoMar)
    }

    /// Aplana las piezas de una persona en un solo nodo (rápido de dibujar) y conserva su escala.
    private func aplanadoVivo(_ n: SCNNode) -> SCNNode {
        let s = n.scale, r = n.eulerAngles
        n.scale = SCNVector3(1, 1, 1); n.eulerAngles = SCNVector3(0, 0, 0)
        Villa3D.Coordinador.hornear(n)
        let p = n.flattenedClone(); p.scale = s; p.eulerAngles = r
        let g = SCNNode(); g.addChildNode(p); return g
    }

    // MARK: Aeropuerto internacional: dos pistas paralelas, cuatro puestos, tres vuelos en ciclo

    /// Tramo de una ruta animada (marco local de una isla): punto, altura, segundos, si va en retroceso y actitud.
    fileprivate struct Tramo {
        var x: CGFloat, z: CGFloat, y: CGFloat, t: Double
        var atras = false, cabeceo: CGFloat = 0, alabeo: CGFloat = 0, modo: SCNActionTimingMode = .linear
    }

    /// Anima un nodo (proa en +z) por una ruta del marco `marco`, repitiéndola para siempre después de `espera` s.
    fileprivate func animarRuta(_ n: SCNNode, marco: (CGFloat, CGFloat) -> CGPoint, giro: CGFloat, ruta pts: [Tramo], espera: Double, rumbo0: CGFloat) {
        let p0 = marco(pts[0].x, pts[0].z)
        n.position = SCNVector3(p0.x, pts[0].y + 0.04, p0.y); n.eulerAngles.y = giro + rumbo0
        var acciones: [SCNAction] = []
        var rumbo = rumbo0
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i], dx = b.x - a.x, dz = b.z - a.z
            if hypot(dx, dz) > 0.01 { rumbo = atan2(dx, dz) + (b.atras ? .pi : 0) }
            let w = marco(b.x, b.z)
            let mover = SCNAction.move(to: SCNVector3(w.x, b.y + 0.04, w.y), duration: b.t); mover.timingMode = b.modo
            let girar = SCNAction.rotateTo(x: b.cabeceo, y: giro + rumbo, z: b.alabeo, duration: min(b.t, b.y > 1 ? b.t : 1.6), usesShortestUnitArc: true)
            acciones.append(.group([mover, girar]))
        }
        n.runAction(.sequence([.wait(duration: espera), .repeatForever(.sequence(acciones))]))
    }

    fileprivate func arcoTramos(_ cx: CGFloat, _ cz: CGFloat, _ rad: CGFloat, _ a0: CGFloat, _ a1: CGFloat, y0: CGFloat, y1: CGFloat, t: Double, alabeo: CGFloat) -> [Tramo] {
        (1...14).map { k in
            let u = CGFloat(k) / 14, a = a0 + (a1 - a0) * u
            return Tramo(x: cx + sin(a) * rad, z: cz + cos(a) * rad, y: y0 + (y1 - y0) * u, t: t / 14, alabeo: alabeo)
        }
    }

    private func montarAeropuerto(_ r: SCNNode) {
        let A = marcoLocal(Islas.angAero, Islas.rAero); r.addChildNode(A)
        let asfalto = Mat.pbr(NSColor(calibratedWhite: 0.18, alpha: 1), rugosidad: 0.85), blanco = Mat.pbr(NSColor(calibratedWhite: 0.96, alpha: 1))
        let amarillo = Mat.pbr(NSColor(Color(hex: "#F2C230")), rugosidad: 0.6), hormigon = Mat.pbr(NSColor(calibratedWhite: 0.62, alpha: 1), rugosidad: 0.8)
        let gris = Mat.pbr(NSColor(Color(hex: "#8d98a3")), rugosidad: 0.5, metal: 0.4), acero = Mat.pbr(NSColor(Color(hex: "#c9ced3")), rugosidad: 0.35, metal: 0.7)
        let luzAzul = Mat.emisivo(NSColor.systemBlue, fuerza: 1.2), luzBlanca = Mat.emisivo(NSColor(calibratedWhite: 1, alpha: 1), fuerza: 1.2)
        let luzRoja = Mat.emisivo(NSColor.systemRed, fuerza: 1.2), luzVerde = Mat.emisivo(NSColor.systemGreen, fuerza: 1.2)
        focos += [luzAzul, luzBlanca, luzRoja, luzVerde]
        // Pistas 09L/27R (z 4) y 09R/27L (z 24), con marcas, umbrales, números y luces
        func pista(_ x0: CGFloat, _ x1: CGFloat, z: CGFloat, nombres: (String, String)) {
            let largo = x1 - x0, cx = (x0 + x1) / 2
            caja(A, largo, 0.04, 7, asfalto, x: cx, y: 0.035, z: z)
            var x = x0 + 8
            while x < x1 - 8 { caja(A, 3, 0.02, 0.25, blanco, x: x, y: 0.065, z: z); x += 6 }
            for (lado, nombre) in [(CGFloat(-1), nombres.0), (1, nombres.1)] {
                let xe = lado < 0 ? x0 : x1
                var zz = z - 2.7
                while zz < z + 2.8 { caja(A, 3, 0.02, 0.4, blanco, x: xe - lado * 2, y: 0.065, z: zz); zz += 0.9 }
                caja(A, 0.3, 0.02, 7, blanco, x: xe - lado * 4.5, y: 0.065, z: z)
                let num = nodo(SCNPlane(width: 2.6, height: 1.6), Villa3D.Coordinador.mCartel(nombre, NSColor(calibratedWhite: 0.18, alpha: 1), ancho: 300, brillo: 0), y: 0.07, x: xe - lado * 7.5, z: z)
                num.eulerAngles = SCNVector3(-CGFloat.pi / 2, lado < 0 ? -CGFloat.pi / 2 : CGFloat.pi / 2, 0); A.addChildNode(num)
                for k in 0..<5 { caja(A, 0.2, 0.12, 0.2, lado < 0 ? luzVerde : luzRoja, x: xe, y: 0.08, z: z - 2.8 + CGFloat(k) * 1.4) }
            }
            for lado: CGFloat in [-1, 1] {
                var xl = x0
                while xl <= x1 { caja(A, 0.2, 0.12, 0.2, luzBlanca, x: xl, y: 0.08, z: z + lado * 3.6); xl += 6 }
            }
        }
        pista(-32, 52, z: 4, nombres: ("09L", "27R"))
        pista(-28, 48, z: 24, nombres: ("09R", "27L"))
        // Calles de rodaje A (z −6) y B (z 14), conectores y plataforma
        caja(A, 88, 0.04, 4, asfalto, x: 10, y: 0.035, z: -6); caja(A, 88, 0.02, 0.15, amarillo, x: 10, y: 0.062, z: -6)
        caja(A, 82, 0.04, 4, asfalto, x: 10, y: 0.035, z: 14); caja(A, 82, 0.02, 0.15, amarillo, x: 10, y: 0.062, z: 14)
        for (x, z0, z1) in [(CGFloat(-30), CGFloat(-6), CGFloat(4)), (10, -6, 4), (50, -6, 4), (-28, 4, 14), (46, 4, 14), (-26, 14, 24), (46, 14, 24)] {
            caja(A, 4, 0.04, z1 - z0, asfalto, x: x, y: 0.036, z: (z0 + z1) / 2)
        }
        for z: CGFloat in [-8.2, -3.8, 11.8, 16.2] {
            var xl: CGFloat = -32
            while xl <= 52 { caja(A, 0.15, 0.1, 0.15, luzAzul, x: xl, y: 0.07, z: z); xl += 7 }
        }
        caja(A, 54, 0.04, 12, hormigon, x: 4, y: 0.034, z: -16)
        let puestos: [CGFloat] = [-14, -2, 10, 22]
        for gx in puestos {
            caja(A, 0.15, 0.02, 10, amarillo, x: gx, y: 0.06, z: -16)
            caja(A, 4, 0.02, 0.15, amarillo, x: gx, y: 0.06, z: -21.2)
        }
        // Terminal internacional: dos niveles, techo curvo, ocho mangas, torre y letreros
        let T = SCNNode(); T.position = SCNVector3(4, 0, -27)
        caja(T, 46, 7, 8, Mat.textura(.estuco, repetir: 5, tinte: "#e9edf1"), y: 3.55)
        for z: CGFloat in [4.04, -4.04] { caja(T, 45, 2.4, 0.06, ventana(), y: 2.0, z: z); caja(T, 45, 2.2, 0.06, ventana(), y: 5.1, z: z) }
        let techo = nodo(SCNCylinder(radius: 5.5, height: 48), Mat.pbr(NSColor(Color(hex: "#d8dee4")), rugosidad: 0.3, metal: 0.6), y: 7.0)
        techo.eulerAngles.z = .pi / 2; techo.scale = SCNVector3(0.35, 1, 1); T.addChildNode(techo)
        letrero(T, "AEROPUERTO INTERNACIONAL VILLA", "#1f6fb2", ancho: 22, alto: 1.6, y: 8.8, z: -4.4, giro: .pi, brillo: 0.8)
        letrero(T, "SALIDAS INTERNACIONALES · LLEGADAS", "#1f6fb2", ancho: 12, alto: 0.8, y: 6.6, z: 4.12)
        for gx in puestos {
            caja(T, 1.6, 2.4, 4.6, gris, x: gx - 4 - 2, y: 3.6, z: 6.3)
            caja(T, 0.3, 2.4, 0.3, acero, x: gx - 4 - 2, y: 1.2, z: 8.2)
        }
        A.addChildNode(T)
        let tq = Islas.aero(4, -27); nav.rect(tq.x, tq.y, 23, 4, Islas.angAero)
        // Torre de control alta, hangar de mantenimiento y terminal de carga
        let tx: CGFloat = 34, tz: CGFloat = -30
        cil(A, 1.5, 22, Mat.textura(.estuco, repetir: 3, tinte: "#dfe4e8"), x: tx, z: tz)
        caja(A, 5, 3, 5, ventana(), x: tx, y: 23.5, z: tz, chaflan: 0.2)
        caja(A, 5.6, 0.4, 5.6, gris, x: tx, y: 25.2, z: tz)
        cil(A, 0.06, 4, acero, x: tx, y: 27.4, z: tz)
        A.addChildNode(nodo(SCNSphere(radius: 0.22), Mat.emisivo(.systemRed, fuerza: 1.5), y: 29.5, x: tx, z: tz))
        let tqq = Islas.aero(tx, tz); nav.circulo(tqq.x, tqq.y, 1.7)
        // Hangar de mantenimiento a escala real: nave de radio 7 m y 15 m de fondo, portón de 9,6 × 4,8 m (cabe el avión de la villa)
        let h = nodo(SCNCylinder(radius: 7, height: 15), Mat.pbr(NSColor(Color(hex: "#aab4bd")), rugosidad: 0.4, metal: 0.6), y: 0, x: 44, z: -17)
        h.eulerAngles.z = .pi / 2; A.addChildNode(h)
        // Frontón en arco del mismo radio que la nave, con portón corredizo de paneles que cabe dentro del arco
        // y una rendija entreabierta iluminada por dentro
        let arco = NSBezierPath(); arco.move(to: NSPoint(x: -6.98, y: 0))
        arco.appendArc(withCenter: .zero, radius: 6.98, startAngle: 180, endAngle: 0, clockwise: true); arco.close(); arco.flatness = 0.02
        let fronton = nodo(SCNShape(path: arco, extrusionDepth: 0.12), Mat.pbr(NSColor(Color(hex: "#8f9aa4")), rugosidad: 0.45, metal: 0.6), y: 0, x: 36.5, z: -17)
        fronton.eulerAngles.y = .pi / 2; A.addChildNode(fronton)
        let panel = Mat.pbr(NSColor(Color(hex: "#5d6873")), rugosidad: 0.5, metal: 0.55), marco = Mat.pbr(NSColor(calibratedWhite: 0.2, alpha: 1), rugosidad: 0.5, metal: 0.6)
        caja(A, 0.06, 4.8, 9.6, ventana(), x: 36.42, y: 2.4, z: -17)                          // interior iluminado
        for k in 0..<6 {                                                                    // 6 hojas; la 4ª queda corrida
            let z = -17 - 4.0 + CGFloat(k) * 1.6 + (k == 3 ? 0.6 : 0)
            caja(A, 0.1, 4.75, 1.58, panel, x: 36.36 - (k == 3 ? 0.1 : 0), y: 2.37, z: z)
            caja(A, 0.11, 4.75, 0.05, marco, x: 36.35 - (k == 3 ? 0.1 : 0), y: 2.37, z: z - 0.79)
        }
        caja(A, 0.2, 0.18, 9.9, marco, x: 36.38, y: 4.85, z: -17)                             // dintel y riel
        for lado: CGFloat in [-1, 1] { caja(A, 0.2, 4.9, 0.16, marco, x: 36.38, y: 2.45, z: -17 + lado * 4.87) }
        A.addChildNode(nodo(SCNSphere(radius: 0.16), Mat.emisivo(.systemOrange, fuerza: 1.4), y: 5.5, x: 36.3, z: -17))   // baliza sobre el portón
        let hq = Islas.aero(44, -17); nav.rect(hq.x, hq.y, 7.5, 7, Islas.angAero)
        caja(A, 12, 5, 7, Mat.textura(.estuco, repetir: 3, tinte: "#cfd6dc"), x: 44, z: -31)
        letrero(A, "CARGA · CARGO", "#d68910", ancho: 5, alto: 0.7, x: 44, y: 4.2, z: -27.45)
        let cq = Islas.aero(44, -31); nav.rect(cq.x, cq.y, 6, 3.5, Islas.angAero)
        // Manga de viento y radar
        cil(A, 0.06, 5, acero, x: 52, z: 30)
        let manga = nodo(SCNCone(topRadius: 0.15, bottomRadius: 0.4, height: 2), Mat.pbr(NSColor.systemOrange), y: 4.8, x: 52.9, z: 30)
        manga.eulerAngles.z = .pi / 2; A.addChildNode(manga)
        // Lado tierra: avenida, calle frente a la terminal y estacionamiento con calces preferentes
        caja(A, 7, 0.05, 22, asfalto, y: 0.031, z: -49)
        caja(A, 46, 0.05, 5, asfalto, x: 4, y: 0.03, z: -35.5)
        caja(A, 16, 0.05, 9.5, asfalto, x: 16, y: 0.03, z: -43.8)
        let fila = SCNNode(); fila.position = SCNVector3(24.4, 0, -39.4); fila.eulerAngles.y = .pi; A.addChildNode(fila)
        filaCalces(fila, [.discapacidad, .adultoMayor, .embarazada, .normal, .normal], largo: 5.0, linea: blanco, amarillo: amarillo,
                   anchos: [3.0, 2.4, 2.4, 2.4, 2.4])
        escena.rootNode.addChildNode(aplanado(A, "elem:aeropuerto"))
        A.removeFromParentNode()
        // Aviones: tres en ciclo (despegan por la 09R y aterrizan por la 09L), uno en mantenimiento y una avioneta
        // Dos vuelos con ciclo de 240 s desfasados 120 s: cuando uno rueda, el otro está embarcando o en el aire
        let colores = ["#b0306a", "#1f6fb2"].map { NSColor(Color(hex: $0)) }
        for k in 0..<2 {
            let av = avion(colores[k], escala: 1)
            escena.rootNode.addChildNode(av)
            animarRuta(av, marco: Islas.aero, giro: Islas.angAero, ruta: rutaVuelo(gate: puestos[k * 2]), espera: Double(k) * 120, rumbo0: .pi)
        }
        for (k, gx) in [puestos[1], puestos[3]].enumerated() {           // dos aviones embarcando en sus puestos
            let parado = avion(NSColor(Color(hex: k == 0 ? "#d68910" : "#117a65")), escala: 1)
            let pp = Islas.aero(gx, -15.5); parado.position = SCNVector3(pp.x, 0.04, pp.y); parado.eulerAngles.y = Islas.angAero + .pi
            escena.rootNode.addChildNode(parado)
        }
        let chico = avion(NSColor(Color(hex: "#c0392b")), escala: 0.5)
        let pc = Islas.aero(29, -15); chico.position = SCNVector3(pc.x, 0.04, pc.y); chico.eulerAngles.y = Islas.angAero + .pi
        escena.rootNode.addChildNode(chico)
        // Tráfico de paso en altura (rutas internacionales que cruzan sobre el mar)
        for (k, (a0, alt, dur)) in [(CGFloat(0.4), CGFloat(120), 75.0), (2.3, 140, 90.0), (-2.4, 105, 80.0)].enumerated() {
            let av = avion(NSColor(Color(hex: ["#2c3e50", "#7d3c98", "#1a5276"][k])), escala: 1.3)
            let p0 = Islas.polar(480, a0), p1 = Islas.polar(480, a0 + .pi * 0.85)
            av.position = SCNVector3(p0.x, alt, p0.y); av.eulerAngles.y = atan2(p1.x - p0.x, p1.y - p0.y)
            av.runAction(.sequence([.wait(duration: Double(k) * 25), .repeatForever(.sequence([.move(to: SCNVector3(p1.x, alt, p1.y), duration: dur),
                                                                                                .hide(), .move(to: SCNVector3(p0.x, alt, p0.y), duration: 0), .wait(duration: 20), .unhide()]))]))
            escena.rootNode.addChildNode(av)
        }
        // Bus de enlace villa ⇄ aeropuerto
        let faro = Mat.emisivo(NSColor(calibratedRed: 1, green: 0.97, blue: 0.85, alpha: 1)); focos.append(faro)
        let fr = Mat.emisivo(.systemRed, fuerza: 0.8)
        func pa(_ x: CGFloat, _ z: CGFloat) -> CGPoint { Islas.aero(x, z) }
        let enIsla = [pa(1.7, -58), pa(1.7, -46), pa(4, -38), pa(20, -38), pa(23.4, -36.3), pa(20, -34.8), pa(-12, -34.8), pa(-15.4, -36.3),
                      pa(-12, -38), pa(-4, -38), pa(-1.7, -46), pa(-1.7, -58)]
        let ruta = rutaBus(ang: Islas.angAero, enIsla: enIsla)
        let b = Vehiculo(bus(NSColor(Color(hex: "#1f6fb2")), "BUS AEROPUERTO", faro: faro, freno: fr), ruta: ruta, s: 0, velocidad: 8,
                         paradas: [(largoRuta(ruta, hasta: 9), 12)], largo: 8.2, ancho: 2.4, paciente: true)
        b.raiz.scale = SCNVector3(1, 1, 1)
        Islas.buses.append(b); escena.rootNode.addChildNode(b.raiz)
    }

    /// Ciclo de un vuelo (≈ 3 min 10 s) desde su puesto `gate`.
    fileprivate func rutaVuelo(gate gx: CGFloat) -> [Tramo] {
        var p: [Tramo] = [Tramo(x: gx, z: -15.5, y: 0, t: 0),
                          Tramo(x: gx, z: -15.5, y: 0, t: 130.3),                                // embarque (largo: ordena los turnos)
                          Tramo(x: gx, z: -6, y: 0, t: 8, atras: true),                          // retroceso
                          Tramo(x: -28, z: -6, y: 0, t: 10),                                     // rodaje por A
                          Tramo(x: -28, z: 14, y: 0, t: 6),                                      // cruza la 09L, a la B
                          Tramo(x: -26, z: 14, y: 0, t: 1.5), Tramo(x: -26, z: 24, y: 0, t: 3),  // a la cabecera 09R
                          Tramo(x: -22, z: 24, y: 0, t: 2.5),
                          Tramo(x: 30, z: 24, y: 0, t: 7, modo: .easeIn),                        // carrera de despegue
                          Tramo(x: 60, z: 24, y: 8, t: 2.4, cabeceo: -0.18),
                          Tramo(x: 130, z: 24, y: 35, t: 4.5, cabeceo: -0.12)]
        p += arcoTramos(130, 94, 70, .pi, 0, y0: 35, y1: 42, t: 10, alabeo: -0.35)              // vuelta mar adentro
        p.append(Tramo(x: -110, z: 164, y: 42, t: 9))
        p += arcoTramos(-110, 84, 80, 0, -.pi, y0: 42, y1: 22, t: 11, alabeo: -0.35)
        p += [Tramo(x: -34, z: 4, y: 0.6, t: 6, cabeceo: -0.05),                                 // aproximación 09L
              Tramo(x: -28, z: 4, y: 0, t: 0.8),
              Tramo(x: 40, z: 4, y: 0, t: 8, modo: .easeOut),                                    // frenado
              Tramo(x: 50, z: 4, y: 0, t: 3), Tramo(x: 50, z: -6, y: 0, t: 3),                  // sale por el conector
              Tramo(x: gx, z: -6, y: 0, t: 10),
              Tramo(x: gx, z: -15.5, y: 0, t: 4)]
        return p
    }

    // MARK: Isla Defensa: Fuerza Aérea, Armada y Ejército, comunicados con el Ministerio de Defensa

    /// Caza polivalente (tipo F-16), proa en +z: fuselaje afinado con lomo, radomo gris, cabina de burbuja dorada, toma de aire
    /// ventral, alas trapezoidales con misiles en las puntas, estanques subalares, deriva con timón, estabilizadores,
    /// aletas ventrales, tobera de titanio con pétalos, tren de aterrizaje, escarapelas y luces de navegación.
    private func caza(_ color: NSColor, tren: Bool = true) -> SCNNode {
        if let m = Modelos.nodo("caza", largo: 10.2, nombreElem: "elem:jet") {
            let alza: CGFloat = tren ? 0.55 : 0
            m.childNodes[0].position.y = alza
            for lado: CGFloat in [-1, 1] {
                m.addChildNode(nodo(SCNSphere(radius: 0.06), Mat.emisivo(lado > 0 ? .systemRed : .systemGreen, fuerza: 1.5), y: alza + 0.78, x: lado * 4.55, z: -2.55))
            }
            if tren {   // rueda de nariz y dos principales con sus patas
                let goma = Mat.pbr(NSColor(calibratedWhite: 0.06, alpha: 1), rugosidad: 0.9), llanta = Mat.pbr(NSColor(calibratedWhite: 0.75, alpha: 1), rugosidad: 0.3, metal: 0.8)
                for (x, z, r) in [(CGFloat(0), CGFloat(2.6), CGFloat(0.18)), (-0.9, -1.2, 0.24), (0.9, -1.2, 0.24)] {
                    let h = alza + 0.35 - r
                    cil(m, 0.04, h, llanta, x: x, y: r + h / 2, z: z)
                    let rueda = nodo(SCNCylinder(radius: r, height: 0.15), goma, y: r, x: x, z: z); rueda.eulerAngles.z = .pi / 2; m.addChildNode(rueda)
                }
            }
            m.scale = SCNVector3(0.72, 0.72, 0.72)
            return m
        }
        let n = SCNNode()
        let m = Mat.pbr(color, rugosidad: 0.55, metal: 0.25), claro = Mat.pbr(color.blended(withFraction: 0.22, of: .white) ?? color, rugosidad: 0.55, metal: 0.25)
        let radomo = Mat.pbr(NSColor(calibratedWhite: 0.36, alpha: 1), rugosidad: 0.6, metal: 0.1), titanio = Mat.pbr(NSColor(calibratedWhite: 0.3, alpha: 1), rugosidad: 0.3, metal: 0.95)
        let negro = Mat.pbr(NSColor(calibratedWhite: 0.03, alpha: 1), rugosidad: 0.7), blanco = Mat.pbr(NSColor(calibratedWhite: 0.94, alpha: 1), rugosidad: 0.4)
        let vidrio = Mat.pbr(NSColor(calibratedRed: 0.62, green: 0.5, blue: 0.22, alpha: 1), rugosidad: 0.04, metal: 0.85)
        let junta = Mat.pbr(NSColor(calibratedWhite: 0.2, alpha: 1), rugosidad: 0.6)
        func plano(_ pts: [(CGFloat, CGFloat)], _ grosor: CGFloat, _ mat: SCNMaterial, y: CGFloat, x: CGFloat = 0) {
            let b = NSBezierPath(); b.move(to: NSPoint(x: pts[0].0, y: pts[0].1)); for q in pts.dropFirst() { b.line(to: NSPoint(x: q.0, y: q.1)) }; b.close()
            let s = SCNShape(path: b, extrusionDepth: grosor); s.chamferRadius = grosor * 0.45
            let k = nodo(s, mat, y: y, x: x); k.eulerAngles.x = .pi / 2; n.addChildNode(k)
        }
        // Fuselaje: más ancho que alto, con lomo dorsal que corre desde la cabina hasta la deriva
        let cuerpo = nodo(SCNCapsule(capRadius: 0.5, height: 7.6), m, y: 1.15, z: -0.3); cuerpo.eulerAngles.x = .pi / 2; cuerpo.scale = SCNVector3(1.12, 1, 0.82); n.addChildNode(cuerpo)
        caja(n, 0.62, 0.42, 4.6, m, y: 1.5, z: -1.2, chaflan: 0.2)
        let cola = nodo(SCNCone(topRadius: 0.42, bottomRadius: 0.52, height: 1.2), m, y: 1.12, z: -3.6); cola.eulerAngles.x = -.pi / 2; n.addChildNode(cola)
        let nariz = nodo(SCNCone(topRadius: 0.02, bottomRadius: 0.44, height: 2.0), radomo, y: 1.12, z: 4.25); nariz.eulerAngles.x = .pi / 2; n.addChildNode(nariz)
        let pitot = nodo(SCNCylinder(radius: 0.015, height: 0.7), titanio, y: 1.12, z: 5.55); pitot.eulerAngles.x = .pi / 2; n.addChildNode(pitot)
        // Cabina: burbuja dorada de una pieza, arco del parabrisas y asiento eyectable que se adivina adentro
        let cab = nodo(SCNSphere(radius: 0.4), vidrio, y: 1.6, z: 2.15); cab.scale = SCNVector3(0.78, 0.72, 2.5); n.addChildNode(cab)
        let arco = nodo(SCNTorus(ringRadius: 0.3, pipeRadius: 0.025), junta, y: 1.62, z: 2.85); arco.eulerAngles.x = .pi / 2; arco.scale = SCNVector3(1, 1, 0.9); n.addChildNode(arco)
        caja(n, 0.3, 0.4, 0.2, negro, y: 1.75, z: 1.7)
        // Toma de aire ventral con su boca oscura y paneles
        caja(n, 0.95, 0.62, 2.8, m, y: 0.62, z: 0.9, chaflan: 0.18)
        caja(n, 0.82, 0.5, 0.06, negro, y: 0.62, z: 2.31)
        for z: CGFloat in [0.4, -1.4, 2.6] { caja(n, 1.02, 0.02, 0.02, junta, y: 1.48, z: z) }
        // Alas trapezoidales con flaperones, misiles en las puntas y estanques subalares
        for lado: CGFloat in [-1, 1] {
            plano([(lado * 0.5, 1.6), (lado * 3.75, -1.3), (lado * 3.75, -2.25), (lado * 0.5, -2.3)], 0.08, m, y: 1.08)
            caja(n, 2.6, 0.03, 0.04, junta, x: lado * 2.1, y: 1.1, z: -1.85)
            let mis = nodo(SCNCylinder(radius: 0.065, height: 2.5), blanco, y: 1.08, x: lado * 3.88, z: -1.3); mis.eulerAngles.x = .pi / 2; n.addChildNode(mis)
            let cono = nodo(SCNCone(topRadius: 0, bottomRadius: 0.065, height: 0.3), radomo, y: 1.08, x: lado * 3.88, z: 0.1); cono.eulerAngles.x = .pi / 2; n.addChildNode(cono)
            for g: CGFloat in [0, .pi / 2] { caja(n, 0.34, 0.01, 0.22, blanco, x: lado * 3.88, y: 1.08, z: -2.4).eulerAngles.z = g }
            let est = nodo(SCNCapsule(capRadius: 0.21, height: 2.5), claro, y: 0.62, x: lado * 1.9, z: -0.5); est.eulerAngles.x = .pi / 2; n.addChildNode(est)
            caja(n, 0.06, 0.3, 0.9, m, x: lado * 1.9, y: 0.88, z: -0.6)
            // Escarapela de la Fuerza Aérea sobre cada ala
            let esc = nodo(SCNCylinder(radius: 0.32, height: 0.012), Mat.pbr(NSColor(Color(hex: "#1f3f8f")), rugosidad: 0.5), y: 1.13, x: lado * 2.4, z: -1.3); n.addChildNode(esc)
            n.addChildNode(nodo(SCNCylinder(radius: 0.14, height: 0.014), blanco, y: 1.135, x: lado * 2.4, z: -1.3))
            n.addChildNode(nodo(SCNSphere(radius: 0.06), Mat.emisivo(lado > 0 ? .systemRed : .systemGreen, fuerza: 1.6), y: 1.1, x: lado * 3.76, z: -1.8))
            // Estabilizadores horizontales y aletas ventrales
            plano([(lado * 0.45, -3.0), (lado * 2.3, -4.15), (lado * 2.3, -4.6), (lado * 0.45, -4.45)], 0.06, m, y: 1.0)
            let alet = caja(n, 0.04, 0.45, 0.9, m, x: lado * 0.42, y: 0.55, z: -3.0); alet.eulerAngles.z = lado * 0.4
        }
        // Deriva con timón y antena; luz blanca en la punta
        let dv = NSBezierPath(); dv.move(to: NSPoint(x: 0, y: 0)); dv.line(to: NSPoint(x: -2.5, y: 0)); dv.line(to: NSPoint(x: -3.25, y: 2.35)); dv.line(to: NSPoint(x: -2.55, y: 2.35)); dv.close()
        let ds = SCNShape(path: dv, extrusionDepth: 0.09); ds.chamferRadius = 0.04
        let d = nodo(ds, m, y: 1.6, z: -1.6); d.eulerAngles.y = -.pi / 2; n.addChildNode(d)
        caja(n, 0.1, 1.5, 0.03, junta, y: 2.5, z: -4.35).eulerAngles.x = -0.3
        n.addChildNode(nodo(SCNSphere(radius: 0.05), Mat.emisivo(.white, fuerza: 1.5), y: 3.95, z: -4.85))
        // Tobera: cono de titanio con pétalos y su interior oscuro
        let tob = nodo(SCNCone(topRadius: 0.34, bottomRadius: 0.42, height: 1.0), titanio, y: 1.12, z: -4.55); tob.eulerAngles.x = -.pi / 2; n.addChildNode(tob)
        let pet = nodo(SCNTorus(ringRadius: 0.34, pipeRadius: 0.035), junta, y: 1.12, z: -5.05); pet.eulerAngles.x = .pi / 2; n.addChildNode(pet)
        let boca = nodo(SCNCylinder(radius: 0.3, height: 0.02), negro, y: 1.12, z: -5.02); boca.eulerAngles.x = .pi / 2; n.addChildNode(boca)
        // Tren de aterrizaje: rueda de nariz y dos principales con amortiguadores y compuertas
        if tren {
            let goma = Mat.pbr(NSColor(calibratedWhite: 0.06, alpha: 1), rugosidad: 0.9), llanta = Mat.pbr(NSColor(calibratedWhite: 0.75, alpha: 1), rugosidad: 0.3, metal: 0.8)
            for (x, z, r) in [(CGFloat(0), CGFloat(1.9), CGFloat(0.2)), (-0.62, -1.1, 0.27), (0.62, -1.1, 0.27)] {
                cil(n, 0.04, 0.7, llanta, x: x, y: r + 0.3, z: z)
                let rueda = nodo(SCNCylinder(radius: r, height: 0.16), goma, y: r, x: x, z: z); rueda.eulerAngles.z = .pi / 2; n.addChildNode(rueda)
                let cubo = nodo(SCNCylinder(radius: r * 0.5, height: 0.17), llanta, y: r, x: x, z: z); cubo.eulerAngles.z = .pi / 2; n.addChildNode(cubo)
                if x != 0 { caja(n, 0.03, 0.45, 0.6, m, x: x * 1.25, y: 0.62, z: z) }
            }
        }
        let p = aplanado(n, "elem:jet"); p.scale = SCNVector3(0.72, 0.72, 0.72); return p
    }

    private func buqueGuerra(_ L: CGFloat, submarino: Bool = false) -> SCNNode {
        let n = SCNNode()
        let gris = Mat.pbr(NSColor(Color(hex: "#6b7781")), rugosidad: 0.45, metal: 0.5), oscuro = Mat.pbr(NSColor(calibratedWhite: 0.2, alpha: 1), rugosidad: 0.5)
        if submarino, let m = Modelos.nodo("submarino", largo: L, nombreElem: "elem:armada") { m.childNodes[0].position.y = -L * 0.07; return m }
        if submarino {
            let t = nodo(SCNCapsule(capRadius: L * 0.07, height: L), oscuro, y: 0.1); t.eulerAngles.x = .pi / 2; n.addChildNode(t)
            caja(n, L * 0.06, L * 0.12, L * 0.16, oscuro, y: L * 0.12, z: L * 0.1, chaflan: 0.2)
            return aplanado(n, "elem:armada")
        }
        if let m = Modelos.nodo("buque", largo: L, nombreElem: "elem:armada") { m.childNodes[0].position.y = -L * 0.02; return m }
        casco(n, largo: L, manga: L * 0.13, alto: 1.4, gris, borda: oscuro)
        caja(n, L * 0.1, 1.8, L * 0.26, gris, y: 2.2, z: -L * 0.02, chaflan: 0.1)
        caja(n, L * 0.08, 1.2, L * 0.12, gris, y: 3.6, z: L * 0.02, chaflan: 0.08)
        caja(n, L * 0.09, 0.3, L * 0.1, Mat.pbr(NSColor(Color(hex: "#1d2b3a")), rugosidad: 0.1, metal: 0.6), y: 3.5, z: L * 0.08)
        cil(n, 0.12, 3.4, gris, y: 5.6, z: 0)
        caja(n, 1.6, 0.2, 0.2, gris, y: 6.6)
        caja(n, L * 0.06, 0.6, L * 0.05, gris, y: 1.6, z: L * 0.3)
        let canon = nodo(SCNCylinder(radius: 0.08, height: 2.2), oscuro, y: 1.75, z: L * 0.3 + 1.1); canon.eulerAngles.x = .pi / 2; n.addChildNode(canon)
        caja(n, L * 0.1, 0.06, L * 0.18, Mat.pbr(NSColor(calibratedWhite: 0.35, alpha: 1)), y: 1.42, z: -L * 0.34)       // helipuerto
        return aplanado(n, "elem:armada")
    }

    private func soldado() -> SCNNode {
        let n = SCNNode(), verde = Mat.pbr(NSColor(Color(hex: "#4b5a33")), rugosidad: 0.8), piel = Mat.pbr(NSColor(Color(hex: "#c99b78")), rugosidad: 0.6)
        let negro = Mat.pbr(NSColor(calibratedWhite: 0.1, alpha: 1))
        for lado: CGFloat in [-1, 1] { cil(n, 0.08, 0.85, verde, x: lado * 0.1, y: 0.43); caja(n, 0.12, 0.1, 0.24, negro, x: lado * 0.1, y: 0.05, z: 0.04) }
        caja(n, 0.38, 0.6, 0.22, verde, y: 1.15, chaflan: 0.06)
        for lado: CGFloat in [-1, 1] { cil(n, 0.055, 0.6, verde, x: lado * 0.24, y: 1.1) }
        n.addChildNode(nodo(SCNSphere(radius: 0.12), piel, y: 1.6))
        let casco = nodo(SCNSphere(radius: 0.14), verde, y: 1.66); casco.scale = SCNVector3(1, 0.65, 1.05); n.addChildNode(casco)
        caja(n, 0.05, 0.7, 0.05, negro, x: 0.28, y: 1.35, z: 0.05)                                                  // fusil al hombro
        return aplanadoVivo(n)
    }

    // MARK: Fuerzas Armadas en islas propias: Ejército, Fuerza Aérea (junto al aeropuerto) y Armada (junto al puerto)

    /// Puente recto entre dos puntos en tierra (rampas en ambos extremos, tablero a 1,3 m, pilotes): para unir islas.
    private func puenteRecto(_ r: SCNNode, _ a: CGPoint, _ b: CGPoint) {
        let L = hypot(b.x - a.x, b.y - a.y), ang = atan2(b.x - a.x, b.y - a.y)
        let g = SCNNode(); g.position = SCNVector3(a.x, 0, a.y); g.eulerAngles.y = ang; r.addChildNode(g)    // +z local: de a hacia b
        let asfalto = Mat.pbr(NSColor(calibratedWhite: 0.2, alpha: 1), rugosidad: 0.85), hormigon = Mat.pbr(NSColor(calibratedWhite: 0.72, alpha: 1), rugosidad: 0.7)
        let poste = Mat.pbr(NSColor(calibratedWhite: 0.15, alpha: 1), rugosidad: 0.4, metal: 0.8), solera = Mat.pbr(NSColor(calibratedWhite: 0.75, alpha: 1))
        let alto = Islas.altoPuente, sube = min(9.5, L / 2 - 0.5)
        func y(_ z: CGFloat) -> CGFloat { z < sube ? z / sube * alto : z > L - sube ? (L - z) / sube * alto : alto }
        func losa(_ z0: CGFloat, _ z1: CGFloat) {
            let y0 = y(z0), y1 = y(z1), l = hypot(z1 - z0, y1 - y0), inc = -atan2(y1 - y0, z1 - z0)
            caja(g, 8.2, 0.45, l + 0.05, hormigon, y: (y0 + y1) / 2 - 0.2, z: (z0 + z1) / 2).eulerAngles.x = inc
            caja(g, 7, 0.05, l + 0.05, asfalto, y: (y0 + y1) / 2 + 0.04, z: (z0 + z1) / 2).eulerAngles.x = inc
            for lado: CGFloat in [-1, 1] {
                caja(g, 0.08, 0.08, l + 0.05, poste, x: lado * 4.0, y: (y0 + y1) / 2 + 0.95, z: (z0 + z1) / 2).eulerAngles.x = inc
                caja(g, 0.3, 0.16, l + 0.05, solera, x: lado * 3.65, y: (y0 + y1) / 2 + 0.1, z: (z0 + z1) / 2).eulerAngles.x = inc
            }
        }
        losa(0, sube); if L - 2 * sube > 0.1 { losa(sube, L - sube) }; losa(L - sube, L)
        var z: CGFloat = 5
        while z < L - 3 {
            let h = y(z) + 3.2
            for lado: CGFloat in [-1, 1] { cil(g, 0.32, h, hormigon, x: lado * 2.6, y: y(z) - 0.42 - h / 2, z: z) }
            z += 7
        }
        for lado: CGFloat in [-1, 1] { var zp: CGFloat = 1; while zp < L - 1 { caja(g, 0.08, 0.9, 0.08, poste, x: lado * 4.0, y: y(zp) + 0.5, z: zp); zp += 3 } }
    }

    /// Rotonda de retorno (radio 3,6) en un punto de un marco, para los vehículos que dan la vuelta.
    private func rotonda(_ marco: (CGFloat, CGFloat) -> CGPoint, _ cx: CGFloat, _ cz: CGFloat, desde a0: CGFloat, hasta a1: CGFloat, radio: CGFloat = 3.6) -> [CGPoint] {
        (0...10).map { k in let a = a0 + (a1 - a0) * CGFloat(k) / 10; return marco(cx + cos(a) * radio, cz + sin(a) * radio) }
    }

    private func plazaRotonda(_ g: SCNNode, x: CGFloat, z: CGFloat) {
        g.addChildNode(nodo(SCNTube(innerRadius: 1.6, outerRadius: 5.6, height: 0.06), Mat.pbr(NSColor(calibratedWhite: 0.2, alpha: 1), rugosidad: 0.85), y: 0.031, x: x, z: z))
        cil(g, 1.5, 0.3, Mat.pbr(NSColor(calibratedRed: 0.25, green: 0.5, blue: 0.22, alpha: 1)), x: x, y: 0.15, z: z)
    }

    // Vehículos militares con más detalle

    /// Tanque: casco con frente inclinado, orugas con ruedas de rodaje y rodillos, torre facetada, cañón con freno de
    /// boca, escotilla, ametralladora, antena y camuflaje.
    private func tanque() -> SCNNode {
        if let m = Modelos.nodo("tanque", largo: 9, nombreElem: "elem:ejercito") { m.scale = SCNVector3(1, 1, 1); return m }
        let n = SCNNode()
        let verde = Mat.pbr(NSColor(Color(hex: "#56623b")), rugosidad: 0.75, metal: 0.25), mancha = Mat.pbr(NSColor(Color(hex: "#3f4a2a")), rugosidad: 0.8, metal: 0.2)
        let oruga = Mat.pbr(NSColor(calibratedWhite: 0.13, alpha: 1), rugosidad: 0.9, metal: 0.3), acero = Mat.pbr(NSColor(calibratedWhite: 0.35, alpha: 1), rugosidad: 0.5, metal: 0.7)
        for lado: CGFloat in [-1, 1] {
            caja(n, 0.75, 0.95, 6.4, oruga, x: lado * 1.5, y: 0.5, chaflan: 0.42)
            for k in 0..<6 { let w = nodo(SCNCylinder(radius: 0.36, height: 0.2), acero, y: 0.42, x: lado * 1.89, z: -2.4 + CGFloat(k) * 0.96); w.eulerAngles.z = .pi / 2; n.addChildNode(w) }
            caja(n, 0.85, 0.08, 6.6, verde, x: lado * 1.5, y: 1.0)                                      // faldón
        }
        let perfil = NSBezierPath(); perfil.move(to: NSPoint(x: -3.0, y: 0)); perfil.line(to: NSPoint(x: 2.6, y: 0)); perfil.line(to: NSPoint(x: 3.3, y: 0.55))
        perfil.line(to: NSPoint(x: 2.4, y: 0.95)); perfil.line(to: NSPoint(x: -3.0, y: 0.95)); perfil.close()
        let casco = nodo(SCNShape(path: perfil, extrusionDepth: 2.3), verde, y: 0.95); casco.eulerAngles.y = -.pi / 2; n.addChildNode(casco)
        let tp = NSBezierPath(); tp.move(to: NSPoint(x: -1.4, y: -1.1)); tp.line(to: NSPoint(x: 1.4, y: -1.1)); tp.line(to: NSPoint(x: 1.8, y: 0.2)); tp.line(to: NSPoint(x: 0.9, y: 1.4))
        tp.line(to: NSPoint(x: -0.9, y: 1.4)); tp.line(to: NSPoint(x: -1.8, y: 0.2)); tp.close()
        let torre = nodo(SCNShape(path: tp, extrusionDepth: 0.75), verde, y: 2.3, z: -0.4); torre.eulerAngles.x = .pi / 2; n.addChildNode(torre)
        caja(n, 1.0, 0.5, 0.5, mancha, x: 0.5, y: 2.35, z: -1.0)
        let canon = nodo(SCNCylinder(radius: 0.11, height: 4.6), verde, y: 2.25, z: 3.4); canon.eulerAngles.x = .pi / 2; n.addChildNode(canon)
        let boca = nodo(SCNCylinder(radius: 0.16, height: 0.35), acero, y: 2.25, z: 5.6); boca.eulerAngles.x = .pi / 2; n.addChildNode(boca)
        cil(n, 0.34, 0.3, verde, x: 0.5, y: 2.85, z: -0.6)
        let am = nodo(SCNCylinder(radius: 0.04, height: 1.0), acero, y: 3.05, x: 0.5, z: -0.2); am.eulerAngles.x = .pi / 2; n.addChildNode(am)
        cil(n, 0.02, 2.4, acero, x: -0.8, y: 3.8, z: -1.3)
        for (x, z) in [(CGFloat(-0.8), CGFloat(1.5)), (0.7, -2.0), (-0.6, -1.0)] { caja(n, 0.7, 0.03, 0.9, mancha, x: x, y: 1.92, z: z) }
        let p = aplanado(n, "elem:ejercito"); p.scale = SCNVector3(1, 1, 1); return p
    }

    /// Jeep militar (proa en +z): capó, parabrisas con marco, carpa de lona, rueda de repuesto, defensas y antena.
    private func jeep(_ color: NSColor = NSColor(Color(hex: "#56623b"))) -> SCNNode {
        if let m = Modelos.nodo("humvee", largo: 4.6, nombreElem: "elem:ejercito") { m.scale = SCNVector3(1, 1, 1); return m }
        let n = SCNNode()
        let m = Mat.pbr(color, rugosidad: 0.7, metal: 0.25), lona = Mat.pbr(NSColor(Color(hex: "#6f6a4a")), rugosidad: 0.9)
        let goma = Mat.pbr(NSColor(calibratedWhite: 0.07, alpha: 1), rugosidad: 0.9), acero = Mat.pbr(NSColor(calibratedWhite: 0.3, alpha: 1), rugosidad: 0.5, metal: 0.7)
        caja(n, 1.9, 0.75, 4.2, m, y: 0.85, chaflan: 0.1)
        caja(n, 1.85, 0.3, 1.5, m, y: 1.35, z: 1.25, chaflan: 0.08)
        caja(n, 1.8, 0.6, 0.06, Mat.pbr(NSColor(Color(hex: "#1d2b3a")), rugosidad: 0.1, metal: 0.5), y: 1.6, z: 0.45).eulerAngles.x = -0.25
        caja(n, 1.9, 0.9, 2.0, lona, y: 1.75, z: -1.0, chaflan: 0.15)
        let rep = nodo(SCNCylinder(radius: 0.4, height: 0.25), goma, y: 1.15, z: -2.2); rep.eulerAngles.x = .pi / 2; n.addChildNode(rep)
        caja(n, 2.0, 0.18, 0.15, acero, y: 0.55, z: 2.15)
        for z: CGFloat in [1.35, -1.35] { for x: CGFloat in [-1.0, 1.0] {
            let w = nodo(SCNCylinder(radius: 0.42, height: 0.32), goma, y: 0.42, x: x, z: z); w.eulerAngles.z = .pi / 2; n.addChildNode(w)
        } }
        cil(n, 0.015, 2.2, acero, x: -0.8, y: 2.6, z: -1.6)
        let p = aplanado(n, "elem:ejercito"); p.scale = SCNVector3(1, 1, 1); return p
    }

    /// Camión militar de transporte: cabina, carrocería con arcos y lona, seis ruedas.
    private func camionMilitar(_ color: NSColor = NSColor(Color(hex: "#56623b")), nombre: String = "elem:ejercito") -> SCNNode {
        if let m = Modelos.nodo("camionmil", largo: 6.6, pintura: (color, ["Truck", "TruckDark", "TruckTop"]), nombreElem: nombre) {
            m.scale = SCNVector3(1, 1, 1); return m
        }
        let n = SCNNode()
        let m = Mat.pbr(color, rugosidad: 0.7, metal: 0.25), lona = Mat.pbr(NSColor(Color(hex: "#6f6a4a")), rugosidad: 0.9)
        let goma = Mat.pbr(NSColor(calibratedWhite: 0.07, alpha: 1), rugosidad: 0.9)
        caja(n, 2.3, 1.9, 1.9, m, y: 1.55, z: 2.6, chaflan: 0.12)
        caja(n, 2.1, 0.7, 0.05, Mat.pbr(NSColor(Color(hex: "#1d2b3a")), rugosidad: 0.1, metal: 0.5), y: 2.0, z: 3.56)
        caja(n, 2.4, 0.5, 4.6, m, y: 1.1, z: -0.9)
        let carpa = nodo(SCNCylinder(radius: 1.2, height: 4.6), lona, y: 1.9, z: -0.9); carpa.eulerAngles.x = .pi / 2; carpa.scale = SCNVector3(1, 1, 0.8); n.addChildNode(carpa)
        caja(n, 2.4, 0.6, 4.6, lona, y: 1.55, z: -0.9)
        for z: CGFloat in [2.6, -0.4, -2.2] { for x: CGFloat in [-1.1, 1.1] {
            let w = nodo(SCNCylinder(radius: 0.5, height: 0.38), goma, y: 0.5, x: x, z: z); w.eulerAngles.z = .pi / 2; n.addChildNode(w)
        } }
        let p = aplanado(n, nombre); p.scale = SCNVector3(1, 1, 1); return p
    }

    /// Militar articulado (uniforme, casco y fusil), para formar y marchar con zancada real.
    private func militar(_ uniforme: NSColor, casco: NSColor, piel: NSColor) -> PersonaPlaya {
        let p = personaPlaya(mujer: false, edad: .adulto, piel: piel, traje: uniforme, pelo: NSColor(calibratedWhite: 0.1, alpha: 1), ropa: true)
        let c = nodo(SCNSphere(radius: 0.135), Mat.pbr(casco, rugosidad: 0.6), y: 1.79); c.scale = SCNVector3(1, 0.62, 1.08); p.raiz.addChildNode(c)
        let fusil = nodo(SCNBox(width: 0.05, height: 0.75, length: 0.07, chamferRadius: 0), Mat.pbr(NSColor(calibratedWhite: 0.12, alpha: 1)), y: -0.25, z: 0.04)
        p.brazos[1].addChildNode(fusil)
        for k in [0, 1] { p.piernas[k].addChildNode(nodo(SCNBox(width: 0.12, height: 0.12, length: 0.26, chamferRadius: 0.03), Mat.pbr(NSColor(calibratedWhite: 0.08, alpha: 1)), y: -0.92, z: 0.05)) }
        return p
    }

    private func pieles() -> [NSColor] { ["#f1c9a5", "#d9a47c", "#a8714d", "#7a4e33", "#c68e6a"].map { NSColor(Color(hex: $0)) } }

    // MARK: Ejército

    private func montarEjercito(_ r: SCNNode) {
        let D = marcoLocal(Islas.angDef, Islas.rDef); r.addChildNode(D)
        let asfalto = Mat.pbr(NSColor(calibratedWhite: 0.18, alpha: 1), rugosidad: 0.85), blanco = Mat.pbr(NSColor(calibratedWhite: 0.96, alpha: 1))
        let hormigon = Mat.pbr(NSColor(calibratedWhite: 0.6, alpha: 1), rugosidad: 0.8), verdeMil = Mat.textura(.estuco, repetir: 3, tinte: "#7d8a5c")
        let acero = Mat.pbr(NSColor(Color(hex: "#c9ced3")), rugosidad: 0.35, metal: 0.7), gris = Mat.pbr(NSColor(Color(hex: "#6b7781")), rugosidad: 0.5, metal: 0.4)
        func navL(_ x: CGFloat, _ z: CGFloat, _ hx: CGFloat, _ hz: CGFloat, linea: Int = #line) { let q = Islas.def(x, z); nav.rect(q.x, q.y, hx, hz, Islas.angDef, linea: linea) }
        // Acceso, guardia y avenida con rotonda
        caja(D, 7, 0.05, 16, asfalto, y: 0.03, z: -34)
        caja(D, 3, 2.6, 3, verdeMil, x: 6, z: -36); navL(6, -36, 1.6, 1.6)
        for x: CGFloat in [-3.8, 3.8] { cil(D, 0.12, 3.6, gris, x: x, z: -37) }
        caja(D, 7.6, 0.25, 0.25, gris, y: 3.3, z: -37)
        letrero(D, "REGIMIENTO · EJÉRCITO DE LA VILLA", "#4b5a33", ancho: 6, alto: 0.6, y: 3.9, z: -36.9)
        plazaRotonda(D, x: 0, z: -22)
        // Cuarteles, comando, patio de formación con bandera, parque de vehículos, polígono de tiro y torre
        for z: CGFloat in [-20, -13, -6] {
            caja(D, 15, 3.4, 4.2, verdeMil, x: -18, z: z)
            caja(D, 15.4, 0.3, 4.6, Mat.pbr(NSColor(Color(hex: "#3d4630")), rugosidad: 0.7), x: -18, y: 3.55, z: z)
            caja(D, 14, 1.0, 0.06, ventana(), x: -18, y: 2.0, z: z + 2.13)
            navL(-18, z, 7.6, 2.2)
        }
        caja(D, 10, 5, 6, verdeMil, x: 14, z: 28); caja(D, 9, 1.2, 0.06, ventana(), x: 14, y: 3.2, z: 24.97)
        letrero(D, "COMANDO DEL REGIMIENTO", "#4b5a33", ancho: 5, alto: 0.55, x: 14, y: 4.4, z: 24.95); navL(14, 28, 5.2, 3.2)
        caja(D, 16, 0.05, 10, hormigon, x: 12, y: 0.03, z: -14)
        for x in stride(from: CGFloat(5), through: 19, by: 3.5) { caja(D, 0.1, 0.02, 9, blanco, x: x, y: 0.06, z: -14) }
        cil(D, 0.1, 9, acero, x: 21, z: -20); navL(21, -20, 0.2, 0.2)
        let bandera = SCNMaterial(); bandera.diffuse.contents = NSColor(Color(hex: "#4b5a33")); bandera.isDoubleSided = true
        D.addChildNode(nodo(SCNPlane(width: 2.2, height: 1.4), bandera, y: 8.2, x: 22.1, z: -20))
        caja(D, 30, 0.05, 15, asfalto, x: 11, y: 0.03, z: 6.5)
        for x in stride(from: CGFloat(-2), through: 24, by: 4.2) { caja(D, 0.1, 0.02, 6, blanco, x: x, y: 0.06, z: 10) }
        caja(D, 24, 0.05, 6, Mat.pbr(NSColor(Color(hex: "#b9a58a")), rugosidad: 0.9), x: -16, y: 0.03, z: 22)
        for x in stride(from: CGFloat(-26), through: -6, by: 4) {
            cil(D, 0.05, 1.4, Mat.textura(.madera, repetir: 1), x: x, z: 24.6)
            let blanco2 = nodo(SCNCylinder(radius: 0.45, height: 0.05), Mat.pbr(NSColor.systemRed), y: 1.5, x: x, z: 24.6); blanco2.eulerAngles.x = .pi / 2; D.addChildNode(blanco2)
        }
        let tv = SCNNode(); tv.position = SCNVector3(29, 0, -6); D.addChildNode(tv)
        for x: CGFloat in [-1, 1] { for z: CGFloat in [-1, 1] { cil(tv, 0.12, 7, acero, x: x, z: z) } }
        caja(tv, 3, 2, 3, verdeMil, y: 7.8); caja(tv, 3.4, 0.25, 3.4, gris, y: 8.9); navL(29, -6, 1.3, 1.3)
        escena.rootNode.addChildNode(aplanado(D, "elem:ejercito"))
        D.removeFromParentNode()
        // Vehículos estacionados en el parque
        for (k, x) in [CGFloat(0), 4.2, 8.4].enumerated() { let t = tanque(); let p = Islas.def(x, 10); t.position = SCNVector3(p.x, 0.04, p.y); t.eulerAngles.y = Islas.angDef + .pi; escena.rootNode.addChildNode(t); _ = k }
        for x: CGFloat in [12.6, 16.8] { let c = camionMilitar(); let p = Islas.def(x, 10); c.position = SCNVector3(p.x, 0.04, p.y); c.eulerAngles.y = Islas.angDef + .pi; escena.rootNode.addChildNode(c) }
        for x: CGFloat in [21, 24] { let j = jeep(); let p = Islas.def(x, 10.8); j.position = SCNVector3(p.x, 0.04, p.y); j.eulerAngles.y = Islas.angDef + .pi; escena.rootNode.addChildNode(j) }
        // Sección que marcha por el patio, con zancada y braceo; guardias en el acceso
        let seccion = SCNNode(); var caras = pieles()
        for f in 0..<3 { for c in 0..<4 {
            let s = militar(NSColor(Color(hex: "#4b5a33")), casco: NSColor(Color(hex: "#3d4630")), piel: caras[(f * 4 + c) % caras.count])
            s.raiz.position = SCNVector3(CGFloat(c) * 0.9 - 1.35, 0, -CGFloat(f) * 1.1); seccion.addChildNode(s.raiz)
            caminar(s, ciclo: 1.0, amplitud: 0.5)
        } }
        let ps = Islas.def(6, -18); seccion.position = SCNVector3(ps.x, 0.04, ps.y); seccion.eulerAngles.y = Islas.angDef + .pi / 2
        escena.rootNode.addChildNode(seccion)
        let pa = Islas.def(6, -18), pb = Islas.def(18, -18), pc = Islas.def(18, -10), pd = Islas.def(6, -10)
        func paso(_ p: CGPoint, _ yaw: CGFloat, _ s: Double) -> SCNAction {
            .sequence([.rotateTo(x: 0, y: Islas.angDef + yaw, z: 0, duration: 1.4, usesShortestUnitArc: true), .move(to: SCNVector3(p.x, 0.04, p.y), duration: s)])
        }
        seccion.runAction(.repeatForever(.sequence([paso(pb, .pi / 2, 10), paso(pc, 0, 7), paso(pd, -.pi / 2, 10), paso(pa, .pi, 7)])))
        soloDeDia.append(seccion)
        for x: CGFloat in [-4.6, 4.6] {
            let g = militar(NSColor(Color(hex: "#4b5a33")), casco: NSColor(Color(hex: "#3d4630")), piel: caras.removeFirst())
            let p = Islas.def(x, -38); g.raiz.position = SCNVector3(p.x, 0.04, p.y); g.raiz.eulerAngles.y = Islas.angDef + .pi
            escena.rootNode.addChildNode(g.raiz)
        }
        // Tanque que patrulla el perímetro del parque
        let tk = tanque()
        let t0 = Islas.def(26, -2), t1 = Islas.def(-4, -2), t2 = Islas.def(-4, 15), t3 = Islas.def(26, 15)
        tk.position = SCNVector3(t0.x, 0.04, t0.y)
        func avanza(_ p: CGPoint, _ yaw: CGFloat, _ s: Double) -> SCNAction {
            .sequence([.rotateTo(x: 0, y: Islas.angDef + yaw, z: 0, duration: 3, usesShortestUnitArc: true), .move(to: SCNVector3(p.x, 0.04, p.y), duration: s)])
        }
        tk.runAction(.repeatForever(.sequence([avanza(t1, -.pi / 2, 16), avanza(t2, 0, 9), avanza(t3, .pi / 2, 16), avanza(t0, .pi, 9)])))
        escena.rootNode.addChildNode(tk); soloDeDia.append(tk)
        // Convoy (jeep y camión) que sale a la villa por el puente y vuelve
        func pd2(_ x: CGFloat, _ z: CGFloat) -> CGPoint { Islas.def(x, z) }
        let enIsla = [pd2(1.7, -42), pd2(1.7, -30)] + rotonda(Islas.def, 0, -22, desde: -1.32, hasta: -1.32 + 5.78, radio: 7) + [pd2(-1.7, -30), pd2(-1.7, -42)]
        let ruta = rutaBus(ang: Islas.angDef, enIsla: enIsla)
        for (k, v) in [jeep(), camionMilitar()].enumerated() {
            let veh = Vehiculo(v, ruta: ruta, s: CGFloat(k) * 14, velocidad: 7, paradas: [], largo: k == 0 ? 3.1 : 5.3, ancho: 1.6, paciente: true)
            Islas.buses.append(veh); escena.rootNode.addChildNode(veh.raiz)
            if k == 1 { soloDeDia.append(veh.raiz) }            // de noche sale solo el jeep
        }
        pulsoRadio(en: Islas.def(29, -6), altura: 10)
    }

    // MARK: Fuerza Aérea (isla junto al aeropuerto, unida por puente)

    private func montarFuerzaAerea(_ r: SCNNode) {
        let F = marcoLocal(Islas.angFA, Islas.rFA); r.addChildNode(F)
        let asfalto = Mat.pbr(NSColor(calibratedWhite: 0.18, alpha: 1), rugosidad: 0.85), blanco = Mat.pbr(NSColor(calibratedWhite: 0.96, alpha: 1))
        let hormigon = Mat.pbr(NSColor(calibratedWhite: 0.6, alpha: 1), rugosidad: 0.8), gris = Mat.pbr(NSColor(Color(hex: "#8d98a3")), rugosidad: 0.5, metal: 0.4)
        let luz = Mat.emisivo(NSColor(calibratedRed: 1, green: 0.9, blue: 0.6, alpha: 1)); focos.append(luz)
        func navL(_ x: CGFloat, _ z: CGFloat, _ hx: CGFloat, _ hz: CGFloat, linea: Int = #line) { let q = Islas.fa(x, z); nav.rect(q.x, q.y, hx, hz, Islas.angFA, linea: linea) }
        let e = Islas.entradaFA                                              // donde llega el puente (marco local)
        caja(F, 6, 0.05, hypot(e.x + 14, e.y + 14), asfalto, x: (e.x - 14) / 2, y: 0.03, z: (e.y - 14) / 2).eulerAngles.y = atan2(-14 - e.x, -14 - e.y)
        plazaRotonda(F, x: -17, z: -14)
        caja(F, 52, 0.04, 6, asfalto, y: 0.035, z: 8)
        var x: CGFloat = -22
        while x < 22 { caja(F, 2.4, 0.02, 0.22, blanco, x: x, y: 0.065, z: 8); x += 5 }
        for lado: CGFloat in [-1, 1] { var xl: CGFloat = -26; while xl <= 26 { caja(F, 0.18, 0.1, 0.18, luz, x: xl, y: 0.08, z: 8 + lado * 3.1); xl += 5 } }
        caja(F, 40, 0.04, 12.2, hormigon, x: 2, y: 0.034, z: -4.1)   // plataforma hasta las puertas de los refugios
        caja(F, 4, 0.04, 6, asfalto, x: -22, y: 0.036, z: 4)
        // Los cazas miden 10,2 m y estacionan con la cola a z ≈ -9,6: los refugios quedan detrás, con la puerta en z = -10,2
        // (antes la puerta estaba en -6,5 y medio avión la atravesaba).
        for xr: CGFloat in [-6, 4, 14] {
            let ref = nodo(SCNCylinder(radius: 4.6, height: 10), Mat.pbr(NSColor(Color(hex: "#7e8770")), rugosidad: 0.8), y: 0, x: xr, z: -15.2)   // cabe el caza completo
            ref.eulerAngles.x = .pi / 2; F.addChildNode(ref)
            // Frente en arco que sigue la bóveda: marco de hormigón (anillo) y portón con la misma curva; la mitad inferior queda bajo el suelo
            let marcoA = nodo(SCNTube(innerRadius: 4.4, outerRadius: 4.78, height: 0.3), hormigon, y: 0, x: xr, z: -10.2); marcoA.eulerAngles.x = .pi / 2; F.addChildNode(marcoA)
            let acero = Mat.pbr(NSColor(Color(hex: "#4f5a4a")), rugosidad: 0.85, metal: 0.15)
            let porton = nodo(SCNCylinder(radius: 4.4, height: 0.12), acero, y: 0, x: xr, z: -10.23); porton.eulerAngles.x = .pi / 2; F.addChildNode(porton)
            let junta = Mat.pbr(NSColor(calibratedWhite: 0.15, alpha: 1))
            caja(F, 0.06, 4.36, 0.04, junta, x: xr, y: 2.18, z: -10.15)                                  // unión de las dos hojas
            for h: CGFloat in [1.0, 2.0, 3.0, 3.8] {                                               // refuerzos horizontales dentro del arco
                caja(F, 2 * sqrt(4.4 * 4.4 - h * h) - 0.15, 0.06, 0.04, junta, x: xr, y: h, z: -10.15)
            }
            navL(xr, -15.2, 4.7, 5.1)
        }
        cil(F, 1.0, 6, Mat.textura(.estuco, repetir: 2, tinte: "#dfe4e8"), x: 18, z: -19.5); F.addChildNode(nodo(SCNSphere(radius: 2.2), blanco, y: 7.6, x: 18, z: -19.5))
        navL(18, -19.5, 1.1, 1.1)
        cil(F, 1.2, 5, Mat.textura(.estuco, repetir: 2, tinte: "#dfe4e8"), x: 22, z: -4); caja(F, 4, 3, 4, ventana(), x: 22, y: 6.5, z: -4, chaflan: 0.2)
        navL(22, -4, 1.3, 1.3)
        caja(F, 9, 4, 5, Mat.textura(.estuco, repetir: 3, tinte: "#e3e8ec"), x: 4, z: -22)
        letrero(F, "BASE AÉREA · FUERZA AÉREA DE LA VILLA", "#1a5276", ancho: 8, alto: 0.6, x: 4, y: 3.3, z: -19.45)
        navL(4, -22, 4.7, 2.7)
        escena.rootNode.addChildNode(aplanado(F, "elem:fach"))
        F.removeFromParentNode()
        // Cazas: dos salen de sus refugios, despegan, patrullan sobre el mar y vuelven; uno en alerta en la plataforma
        let grisFA = NSColor(Color(hex: "#8d98a3"))
        for (k, xr) in [CGFloat(-6), 4, 14].enumerated() {
            let c = caza(grisFA)
            if k == 2 { let p = Islas.fa(xr, -4.0); c.position = SCNVector3(p.x, 0.04, p.y); c.eulerAngles.y = Islas.angFA; escena.rootNode.addChildNode(c); continue }
            escena.rootNode.addChildNode(c)
            var ruta: [Tramo] = [Tramo(x: xr, z: -4.5, y: 0, t: 0), Tramo(x: xr, z: -4.5, y: 0, t: 35), Tramo(x: xr, z: 1, y: 0, t: 3),
                                 Tramo(x: -22, z: 1, y: 0, t: 7), Tramo(x: -22, z: 8, y: 0, t: 3), Tramo(x: -19, z: 8, y: 0, t: 1.5),
                                 Tramo(x: 14, z: 8, y: 0, t: 4, modo: .easeIn), Tramo(x: 50, z: 12, y: 14, t: 2, cabeceo: -0.3), Tramo(x: 120, z: 50, y: 50, t: 3.5, cabeceo: -0.15)]
            ruta += arcoTramos(120, 130, 80, .pi * 0.85, -0.3, y0: 50, y1: 56, t: 9, alabeo: 0.6)
            ruta += [Tramo(x: -40, z: 170, y: 55, t: 7), Tramo(x: -90, z: 80, y: 38, t: 5, alabeo: 0.4), Tramo(x: -70, z: 8, y: 16, t: 4, alabeo: 0.3),
                     Tramo(x: -30, z: 8, y: 0.5, t: 3.5, cabeceo: -0.04), Tramo(x: -24, z: 8, y: 0, t: 0.6), Tramo(x: 18, z: 8, y: 0, t: 5, modo: .easeOut),
                     Tramo(x: 22, z: 8, y: 0, t: 1.5), Tramo(x: 22, z: 1, y: 0, t: 2.5), Tramo(x: xr, z: 1, y: 0, t: 5), Tramo(x: xr, z: -4.5, y: 0, t: 3, atras: true)]
            animarRuta(c, marco: Islas.fa, giro: Islas.angFA, ruta: ruta, espera: Double(k) * 60, rumbo0: .pi)
            if k == 1 { cazaReserva = (c, c.position) }      // de noche patrulla solo el primero
        }
        // Jeep de la base que va y viene del aeropuerto por el puente
        let (a, b) = Islas.puenteFA, d = CGPoint(x: (b.x - a.x) / hypot(b.x - a.x, b.y - a.y), y: (b.y - a.y) / hypot(b.x - a.x, b.y - a.y))
        let lat = CGPoint(x: d.y, y: -d.x)
        func carril(_ p: CGPoint, _ s: CGFloat) -> CGPoint { CGPoint(x: p.x + lat.x * s, y: p.y + lat.y * s) }
        let ida = [carril(a, 1.7), carril(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), 1.7), carril(b, 1.7)]
        let vuelta = [carril(b, -1.7), carril(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), -1.7), carril(a, -1.7)]
        let ruta = ida + rotonda(Islas.fa, -17, -14, desde: 0, hasta: 2 * .pi - 0.6) + vuelta + rotonda(Islas.aero, 54, 14, desde: 0, hasta: 2 * .pi - 0.6)
        let v = Vehiculo(jeep(NSColor(Color(hex: "#5d6d7e"))), ruta: ruta, s: 0, velocidad: 7, paradas: [], largo: 3.1, ancho: 1.6, paciente: true)
        Islas.buses.append(v); escena.rootNode.addChildNode(v.raiz)
        pulsoRadio(en: Islas.fa(18, -19.5), altura: 10)
    }

    // MARK: Armada (isla unida al puerto; depende de la Gobernación Marítima, que depende del Ministerio de Defensa)

    private func montarArmada(_ r: SCNNode) {
        let N = marcoLocal(Islas.angNav, Islas.rNav); r.addChildNode(N)
        let asfalto = Mat.pbr(NSColor(calibratedWhite: 0.18, alpha: 1), rugosidad: 0.85), hormigon = Mat.pbr(NSColor(calibratedWhite: 0.6, alpha: 1), rugosidad: 0.8)
        func navL(_ x: CGFloat, _ z: CGFloat, _ hx: CGFloat, _ hz: CGFloat, linea: Int = #line) { let q = Islas.naval(x, z); nav.rect(q.x, q.y, hx, hz, Islas.angNav, linea: linea) }
        caja(N, 7, 0.05, 14, asfalto, y: 0.03, z: -27)
        plazaRotonda(N, x: 0, z: -16)
        caja(N, 12, 6, 6, Mat.textura(.estuco, repetir: 3, tinte: "#e8eef2"), x: -16, z: -14)
        caja(N, 11, 1.4, 0.06, ventana(), x: -16, y: 3.6, z: -10.97)
        letrero(N, "BASE NAVAL · ARMADA DE LA VILLA", "#1a3d5c", ancho: 7, alto: 0.7, x: -16, y: 5.3, z: -10.95)
        navL(-16, -14, 6.2, 3.2)
        caja(N, 10, 5, 7, Mat.pbr(NSColor(Color(hex: "#8d98a3")), rugosidad: 0.6, metal: 0.4), x: 15.5, z: -12); navL(15.5, -12, 5.2, 3.7)
        caja(N, 40, 0.05, 14, hormigon, y: 0.03, z: 14)
        let grua = SCNNode(); grua.position = SCNVector3(6, 0, 14); N.addChildNode(grua)
        caja(grua, 0.6, 12, 0.6, Mat.pbr(NSColor.systemYellow), y: 6); caja(grua, 0.5, 0.5, 14, Mat.pbr(NSColor.systemYellow), y: 12, z: 4)
        navL(6, 14, 0.5, 0.5)
        for xm: CGFloat in [-14, 0, 14] {
            caja(N, 3.4, 0.4, 26, hormigon, x: xm, y: 0.2, z: 38)
            var z: CGFloat = 28
            while z < 51 { cil(N, 0.3, 1.6, hormigon, x: xm - 1.5, y: -0.6, z: z); cil(N, 0.3, 1.6, hormigon, x: xm + 1.5, y: -0.6, z: z); z += 4 }
        }
        cil(N, 0.1, 9, Mat.pbr(NSColor(Color(hex: "#c9ced3")), rugosidad: 0.35, metal: 0.7), x: -4, z: -9)
        let bandera = SCNMaterial(); bandera.diffuse.contents = NSColor(Color(hex: "#1a3d5c")); bandera.isDoubleSided = true
        N.addChildNode(nodo(SCNPlane(width: 2.2, height: 1.4), bandera, y: 8.2, x: -2.9, z: -9))
        escena.rootNode.addChildNode(aplanado(N, "elem:armada"))
        N.removeFromParentNode()
        for (xb, L, sub) in [(CGFloat(-7), CGFloat(24), false), (7, 18, false), (21, 14, true), (-21, 12, false)] {
            let b = buqueGuerra(L, submarino: sub)
            let p = Islas.naval(xb, 40); b.position = SCNVector3(p.x, -0.5, p.y); b.eulerAngles.y = Islas.angNav
            escena.rootNode.addChildNode(b)
        }
        // Infantes de marina de guardia y camión de la Armada que va y viene del puerto
        var caras = pieles()
        for x: CGFloat in [-4.4, 4.4] {
            let g = militar(NSColor(Color(hex: "#1a3d5c")), casco: NSColor(calibratedWhite: 0.95, alpha: 1), piel: caras.removeFirst())
            let p = Islas.naval(x, -22); g.raiz.position = SCNVector3(p.x, 0.04, p.y); g.raiz.eulerAngles.y = Islas.angNav + .pi
            escena.rootNode.addChildNode(g.raiz)
        }
        func pn(_ x: CGFloat, _ z: CGFloat) -> CGPoint { Islas.naval(x, z) }
        let enIsla = [pn(1.7, -34), pn(1.7, -24)] + rotonda(Islas.naval, 0, -16, desde: -1.32, hasta: -1.32 + 5.78, radio: 7) + [pn(-1.7, -24), pn(-1.7, -34)]
        let ruta = rutaBus(ang: Islas.angNav, enIsla: enIsla)
        let v = Vehiculo(camionMilitar(NSColor(Color(hex: "#1a3d5c")), nombre: "elem:armada"), ruta: ruta, s: 0, velocidad: 7, paradas: [], largo: 5.3, ancho: 1.6, paciente: true)
        Islas.buses.append(v); escena.rootNode.addChildNode(v.raiz)
        pulsoRadio(en: Islas.naval(-4, -9), altura: 10)
        // Gobernación Marítima del puerto, junto a la cabecera del puente
        let pg = Islas.posiciones["gobmar"]!, yg = atan2(-pg.x, -pg.y)
        let Gm = SCNNode(); Gm.position = SCNVector3(pg.x, 0, pg.y); Gm.eulerAngles.y = yg
        caja(Gm, 7, 4, 4.4, Mat.textura(.estuco, repetir: 3, tinte: "#f2f4f6"))
        caja(Gm, 7.4, 0.4, 4.8, Mat.pbr(NSColor(Color(hex: "#1a3d5c")), rugosidad: 0.5), y: 4.2)
        caja(Gm, 6.4, 1.2, 0.06, ventana(), y: 2.5, z: 2.23)
        letrero(Gm, "GOBERNACIÓN MARÍTIMA · PUERTO", "#1a3d5c", ancho: 6, alto: 0.55, y: 3.6, z: 2.26)
        cil(Gm, 0.06, 5, Mat.pbr(NSColor(Color(hex: "#c9ced3")), metal: 0.7), x: 2.8, y: 6.9, z: -1.6)
        escena.rootNode.addChildNode(aplanado(Gm, "elem:gobmar"))
        nav.rect(pg.x, pg.y, 3.7, 2.4, yg)
        pulsoRadio(en: CGPoint(x: pg.x + 2.8 * cos(yg) - 1.6 * sin(yg), y: pg.y - 2.8 * sin(yg) - 1.6 * cos(yg)), altura: 9.4)
    }

    /// Ondas de radio: anillos que se expanden desde una antena (enlace con el Ministerio de Defensa).
    func pulsoRadio(en p: CGPoint, altura: CGFloat) {
        let m = Mat.emisivo(NSColor(calibratedRed: 0.4, green: 0.9, blue: 1, alpha: 1), fuerza: 1.2); m.writesToDepthBuffer = false
        for k in 0..<3 {
            let a = nodo(SCNTorus(ringRadius: 0.6, pipeRadius: 0.05), m, y: altura, x: p.x, z: p.y); a.opacity = 0; a.castsShadow = false
            a.runAction(.repeatForever(.sequence([.wait(duration: Double(k) * 0.9), .group([.scale(to: 9, duration: 2.7), .sequence([.fadeOpacity(to: 0.9, duration: 0.3), .fadeOpacity(to: 0, duration: 2.4)])]),
                                                  .scale(to: 1, duration: 0), .wait(duration: Double(2 - k) * 0.9)])))
            escena.rootNode.addChildNode(a)
        }
    }

    /// Patrullera de Carabineros: carrocería verde con puertas blancas, franja «CARABINEROS», baliza azul/roja que destella.
    private func patrullaCarabineros(faro: SCNMaterial, freno: SCNMaterial) -> SCNNode {
        if let m = Modelos.nodo("policia", largo: 4.4, pintura: (NSColor(Color(hex: "#1e5631")), ["Black"]), cambios: ["Headlights": faro, "TailLights": freno]) {
            // Patrulla verde y blanca con rótulo CARABINEROS y barra de luces que destella
            let rotulo = Villa3D.Coordinador.mCartel("CARABINEROS", NSColor(Color(hex: "#1e5631")), ancho: 700, brillo: 0.2)
            for x: CGFloat in [-1.04, 1.04] { let l = nodo(SCNPlane(width: 1.6, height: 0.2), rotulo, y: 0.62, x: x, z: 0.1); l.eulerAngles.y = x > 0 ? .pi / 2 : -.pi / 2; m.addChildNode(l) }
            for (x, c) in [(CGFloat(-0.3), NSColor.systemBlue), (0.3, NSColor.systemRed)] {
                let b = nodo(SCNBox(width: 0.4, height: 0.12, length: 0.24, chamferRadius: 0.04), Mat.emisivo(c, fuerza: 2), y: 1.5, x: x, z: -0.3)
                b.runAction(.repeatForever(.sequence([.wait(duration: x < 0 ? 0 : 0.35), .fadeOpacity(to: 0.15, duration: 0.2), .fadeOpacity(to: 1, duration: 0.2), .wait(duration: 0.3)])))
                m.addChildNode(b)
            }
            m.scale = SCNVector3(1, 1, 1); m.name = "elem:comisaria"
            return m
        }
        let base = auto(NSColor(Color(hex: "#1e5631")), faro: faro, freno: freno)
        let g = SCNNode(); g.addChildNode(base)
        let blanco = Mat.pbr(NSColor(calibratedWhite: 0.96, alpha: 1), rugosidad: 0.3, metal: 0.4)
        for x: CGFloat in [-0.91, 0.91] { caja(g, 0.03, 0.42, 1.9, blanco, x: x, y: 0.62, z: 0.1) }
        let rotulo = Villa3D.Coordinador.mCartel("CARABINEROS", NSColor(Color(hex: "#1e5631")), ancho: 700, brillo: 0.2)
        for x: CGFloat in [-0.93, 0.93] { let l = nodo(SCNPlane(width: 1.6, height: 0.2), rotulo, y: 0.62, x: x, z: 0.1); l.eulerAngles.y = x > 0 ? .pi / 2 : -.pi / 2; g.addChildNode(l) }
        caja(g, 1.1, 0.12, 0.3, Mat.pbr(NSColor(calibratedWhite: 0.2, alpha: 1)), y: 1.55, z: -0.2)
        for (x, c) in [(CGFloat(-0.32), NSColor.systemBlue), (0.32, NSColor.systemRed)] {
            let b = nodo(SCNBox(width: 0.42, height: 0.14, length: 0.26, chamferRadius: 0.04), Mat.emisivo(c, fuerza: 2), y: 1.66, x: x, z: -0.2)
            b.runAction(.repeatForever(.sequence([.wait(duration: x < 0 ? 0 : 0.35), .fadeOpacity(to: 0.15, duration: 0.2), .fadeOpacity(to: 1, duration: 0.2), .wait(duration: 0.3)])))
            g.addChildNode(b)
        }
        g.scale = SCNVector3(1, 1, 1); g.name = "elem:comisaria"
        return g
    }

    // MARK: Ministerio de Defensa (sede de gobierno) y Comisaría (Carabineros)

    private func montarMinisterioYComisaria(_ r: SCNNode) {
        // Ministerio de Defensa: detrás del palacio, frente al centro
        let pm = Islas.posiciones["defensa"]!, ym = atan2(-pm.x, -pm.y)
        let M = SCNNode(); M.position = SCNVector3(pm.x, 0.12, pm.y); M.eulerAngles.y = ym
        let piedra = Mat.textura(.estuco, repetir: 3, tinte: "#e9e4d6"), marmol = Mat.textura(.marmol, repetir: 2), acero = Mat.pbr(NSColor(Color(hex: "#c9ced3")), rugosidad: 0.35, metal: 0.7)
        caja(M, 7, 3.6, 3.4, piedra, z: -0.6)
        for k in 0..<5 { cil(M, 0.18, 3.2, marmol, x: -2.6 + CGFloat(k) * 1.3, y: 1.6, z: 1.25) }
        caja(M, 7.2, 0.4, 0.8, piedra, y: 3.4, z: 1.2)
        letrero(M, "MINISTERIO DE DEFENSA", "#3d4630", ancho: 5, alto: 0.5, y: 3.4, z: 1.62)
        cil(M, 0.08, 6, acero, x: 2.6, y: 6.6, z: -1.4)
        M.addChildNode(nodo(SCNSphere(radius: 0.18), Mat.emisivo(.systemRed, fuerza: 1.5), y: 9.7, x: 2.6, z: -1.4))
        escena.rootNode.addChildNode(aplanado(M, "elem:ministerio"))
        nav.rect(pm.x, pm.y, 3.6, 2.2, ym)
        let ant = CGPoint(x: pm.x + 2.6 * cos(ym) - 1.4 * sin(ym), y: pm.y - 2.6 * sin(ym) - 1.4 * cos(ym))
        pulsoRadio(en: ant, altura: 9.6)
        // Comisaría de Carabineros, junto a la avenida de acceso
        let pc = Islas.posiciones["comisaria"]!, yc = atan2(-pc.x, -pc.y)
        let C = SCNNode(); C.position = SCNVector3(pc.x, 0, pc.y); C.eulerAngles.y = yc
        let verde = Mat.pbr(NSColor(Color(hex: "#1e5631")), rugosidad: 0.6), blanco = Mat.textura(.estuco, repetir: 3, tinte: "#f3f1ea")
        caja(C, 8.4, 4, 5, blanco, z: -1.2)
        caja(C, 8.8, 0.4, 5.4, verde, y: 4.2, z: -1.2)
        caja(C, 7.8, 1.2, 0.06, ventana(), y: 2.4, z: 1.32)
        caja(C, 1.4, 2.2, 0.06, Mat.pbr(NSColor(Color(hex: "#4a3524"))), y: 1.1, z: 1.33)
        letrero(C, "COMISARÍA · CARABINEROS DE LA VILLA", "#1e5631", ancho: 7.2, alto: 0.6, y: 3.6, z: 1.36)
        cil(C, 0.06, 4, acero, x: 3.6, y: 6.2, z: -2.5)
        C.addChildNode(nodo(SCNSphere(radius: 0.14), Mat.emisivo(.systemBlue, fuerza: 1.5), y: 8.3, x: 3.6, z: -2.5))
        caja(C, 4.4, 0.05, 9, Mat.pbr(NSColor(calibratedWhite: 0.2, alpha: 1), rugosidad: 0.85), x: 7.0, y: 0.03, z: -1.2)
        escena.rootNode.addChildNode(aplanado(C, "elem:comisaria"))
        nav.rect(pc.x - 1.2 * sin(yc), pc.y - 1.2 * cos(yc), 4.4, 2.7, yc)
        let faro = Mat.emisivo(NSColor(calibratedRed: 1, green: 0.97, blue: 0.85, alpha: 1)), freno = Mat.emisivo(.systemRed, fuerza: 0.4)
        for lz: CGFloat in [-4.0, -1.2, 1.6] {                         // estacionadas en batería al costado del edificio
            let a = patrullaCarabineros(faro: faro, freno: freno)
            let p = CGPoint(x: pc.x + 7.0 * cos(yc) + lz * sin(yc), y: pc.y - 7.0 * sin(yc) + lz * cos(yc))
            a.position = SCNVector3(p.x, 0.08, p.y); a.eulerAngles.y = yc + .pi / 2
            escena.rootNode.addChildNode(a)
            nav.rect(p.x, p.y, 0.8, 1.7, yc)
        }
    }
}

// MARK: - Isla de Energía y Servicios (centrales, agua potable, meteorología, red, residuos y observatorio)

extension Villa3D.Coordinador {
    /// Punto local de la isla a partir de un ángulo (grados; 0 = hacia el mar abierto, ±180 = hacia la villa) y un radio.
    private func polE(_ r: CGFloat, _ grados: CGFloat) -> (x: CGFloat, z: CGFloat) {
        let a = grados * .pi / 180; return (sin(a) * r, cos(a) * r)
    }

    /// Bocanada de humo/vapor para las partículas: varias manchas radiales suaves superpuestas, con matices de gris para dar volumen.
    @MainActor private static let humo: NSImage = {
        let img = NSImage(size: NSSize(width: 128, height: 128))
        img.lockFocus()
        if let g = NSGraphicsContext.current?.cgContext {
            var semilla: UInt64 = 7
            func azar() -> CGFloat { semilla = semilla &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(semilla >> 33) / CGFloat(UInt64(1) << 31) }
            for k in 0..<26 {
                let a = azar() * 2 * .pi, d = k == 0 ? 0 : azar() * 22, r = 16 + azar() * 24
                let c = CGPoint(x: 64 + cos(a) * d, y: 64 + sin(a) * d), tono = 0.68 + azar() * 0.32, al = 0.22 + azar() * 0.26
                let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: [CGColor(gray: tono, alpha: al), CGColor(gray: tono, alpha: 0)] as CFArray, locations: [0, 1])!
                g.drawRadialGradient(grad, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
            }
        }
        img.unlockFocus(); return img
    }()

    /// Módulo fotovoltaico: celdas azul oscuro con marco de aluminio.
    @MainActor private static let celdasSolares: NSImage = {
        let img = NSImage(size: NSSize(width: 96, height: 64))
        img.lockFocus()
        NSColor(calibratedRed: 0.76, green: 0.79, blue: 0.82, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 96, height: 64).fill()
        for c in 0..<6 { for f in 0..<4 {
            let t = 0.08 + CGFloat((c * 7 + f * 3) % 5) * 0.012
            NSColor(calibratedRed: t, green: t + 0.09, blue: t + 0.27, alpha: 1).setFill()
            NSRect(x: 3 + CGFloat(c) * 15, y: 3 + CGFloat(f) * 14.5, width: 14, height: 13.5).fill()
        } }
        img.unlockFocus(); return img
    }()

    /// Barra cilíndrica entre dos puntos (cañerías, cables, celosías).
    @discardableResult
    private func barra(_ g: SCNNode, _ a: SCNVector3, _ b: SCNVector3, _ r: CGFloat, _ m: SCNMaterial) -> SCNNode {
        let d = SCNVector3(b.x - a.x, b.y - a.y, b.z - a.z), L = max(sqrt(d.x * d.x + d.y * d.y + d.z * d.z), 0.001)
        let n = nodo(SCNCylinder(radius: r, height: L), m, y: (a.y + b.y) / 2, x: (a.x + b.x) / 2, z: (a.z + b.z) / 2)
        let la = sqrt(d.z * d.z + d.x * d.x)
        if la > 1e-5 { n.rotation = SCNVector4(d.z / la, 0, -d.x / la, acos(max(-1, min(1, d.y / L)))) }
        g.addChildNode(n); return n
    }

    /// Sólido de revolución a partir de un perfil (radio, altura): torre hiperboloide, antenas parabólicas.
    private func torno(_ perfil: [(r: CGFloat, y: CGFloat)], lados: Int = 40) -> SCNGeometry {
        var v: [SCNVector3] = [], nr: [SCNVector3] = [], tc: [CGPoint] = [], ix: [Int32] = []
        let m = perfil.count, y0 = perfil[0].y, alto = max(abs(perfil[m - 1].y - y0), 0.01)
        for i in 0...lados {
            let a = CGFloat(i) / CGFloat(lados) * 2 * .pi
            for j in 0..<m {
                let p = perfil[j], p0 = perfil[max(0, j - 1)], p1 = perfil[min(m - 1, j + 1)]
                let dr = p1.r - p0.r, dy = p1.y - p0.y, L = max(hypot(dr, dy), 1e-6)
                v.append(SCNVector3(p.r * cos(a), p.y, p.r * sin(a)))
                nr.append(SCNVector3(dy / L * cos(a), -dr / L, dy / L * sin(a)))
                tc.append(CGPoint(x: CGFloat(i) / CGFloat(lados) * 6, y: (p.y - y0) / alto * 2))
            }
        }
        for i in 0..<lados { for j in 0..<(m - 1) {
            let a = Int32(i * m + j), b = Int32((i + 1) * m + j)
            ix += [a, a + 1, b, b, a + 1, b + 1]
        } }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: v), SCNGeometrySource(normals: nr), SCNGeometrySource(textureCoordinates: tc)],
                           elements: [SCNGeometryElement(indices: ix, primitiveType: .triangles)])
    }

    /// Torre de celosía de 4 patas con arriostramiento en X; tramos alternados de dos colores (balizaje rojo y blanco).
    private func celosia(_ g: SCNNode, _ x: CGFloat, _ z: CGFloat, alto: CGFloat, base: CGFloat, cima: CGFloat, tramos: Int, _ m1: SCNMaterial, _ m2: SCNMaterial) {
        for k in 0..<tramos {
            let f0 = CGFloat(k) / CGFloat(tramos), f1 = CGFloat(k + 1) / CGFloat(tramos)
            let s0 = base + (cima - base) * f0, s1 = base + (cima - base) * f1, y0 = alto * f0, y1 = alto * f1
            let m = k % 2 == 0 ? m1 : m2, esq: [(CGFloat, CGFloat)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
            for i in 0..<4 {
                let j = (i + 1) % 4
                let a0 = SCNVector3(x + esq[i].0 * s0, y0, z + esq[i].1 * s0), a1 = SCNVector3(x + esq[i].0 * s1, y1, z + esq[i].1 * s1)
                let b0 = SCNVector3(x + esq[j].0 * s0, y0, z + esq[j].1 * s0), b1 = SCNVector3(x + esq[j].0 * s1, y1, z + esq[j].1 * s1)
                barra(g, a0, a1, 0.05 + s0 * 0.02, m); barra(g, a0, b1, 0.025, m); barra(g, b0, a1, 0.025, m)
            }
        }
    }

    /// Penacho de vapor o humo con partículas: nace en un disco, sube frenándose, se ensancha, se desvanece y lo arrastra la brisa.
    private func vapor(_ x: CGFloat, _ z: CGFloat, y: CGFloat, radio: CGFloat, tasa: CGFloat, vida: CGFloat, sube: CGFloat, tam: CGFloat, crece: CGFloat,
                       gris: CGFloat = 0.97, opacidad: CGFloat = 0.8, viento: CGFloat = 1) {
        let ps = SCNParticleSystem()
        ps.particleImage = Self.humo
        ps.emitterShape = SCNCylinder(radius: radio, height: 0.2); ps.birthLocation = .volume
        ps.birthRate = tasa; ps.warmupDuration = vida
        ps.particleLifeSpan = vida; ps.particleLifeSpanVariation = vida * 0.25
        ps.emittingDirection = SCNVector3(0, 1, 0); ps.spreadingAngle = 12
        ps.particleVelocity = sube; ps.particleVelocityVariation = sube * 0.4; ps.dampingFactor = 0.2
        ps.acceleration = SCNVector3(0.34 * viento, 0.05, 0.2 * viento)
        ps.particleSize = tam; ps.particleSizeVariation = tam * 0.35
        ps.particleAngleVariation = 360; ps.particleAngularVelocityVariation = 22
        ps.particleColor = NSColor(calibratedWhite: gris, alpha: 1); ps.particleColorVariation = SCNVector4(0, 0, 0.05, 0)
        ps.blendMode = .alpha; ps.sortingMode = .distance; ps.isLightingEnabled = false
        let t = CAKeyframeAnimation(); t.values = [1, (1 + crece) / 2, crece]          // el controlador de tamaño multiplica particleSize; t.keyTimes = [0, 0.35, 1]
        let o = CAKeyframeAnimation(); o.values = [0, opacidad, opacidad * 0.55, 0]; o.keyTimes = [0, 0.1, 0.55, 1]
        ps.propertyControllers = [.size: SCNParticlePropertyController(animation: t), .opacity: SCNParticlePropertyController(animation: o)]
        let q = Islas.ener(x, z), n = SCNNode(); n.position = SCNVector3(q.x, y, q.y); n.addParticleSystem(ps); escena.rootNode.addChildNode(n)
    }

    /// Camión de servicio de la isla (proa +z, 6,6 × 2,4 m, base en y = 0): chasis con largueros, cabina avanzada con
    /// parabrisas, ventanas, pilares, visera, espejos, parrilla, parachoques, faros y barra de balizas; ruedas con neumático,
    /// llanta, maza y pernos (duales atrás), estanque de combustible y escape. La carrocería depende del oficio.
    private func camionServicio(_ oficio: String, _ color: String, nombre: String, faro: SCNMaterial, freno: SCNMaterial) -> SCNNode {
        let n = SCNNode()
        let pintura = Mat.pbr(NSColor(Color(hex: color)), rugosidad: 0.32, metal: 0.35)
        let negro = Mat.pbr(NSColor(calibratedWhite: 0.07, alpha: 1), rugosidad: 0.85), goma = Mat.pbr(NSColor(calibratedWhite: 0.045, alpha: 1), rugosidad: 0.95)
        let llanta = Mat.pbr(NSColor(calibratedWhite: 0.72, alpha: 1), rugosidad: 0.25, metal: 0.9), cromo = Mat.pbr(NSColor(calibratedWhite: 0.88, alpha: 1), rugosidad: 0.1, metal: 1)
        let vidrioC = Mat.pbr(NSColor(Color(hex: "#16232e")), rugosidad: 0.04, metal: 0.75), blancoC = Mat.pbr(NSColor(calibratedWhite: 0.93, alpha: 1), rugosidad: 0.4, metal: 0.1)
        let ambar = Mat.emisivo(NSColor(calibratedRed: 1, green: 0.58, blue: 0.08, alpha: 1), fuerza: 0.9)
        let reflectivo = Mat.pbr(NSColor(Color(hex: "#f2f3f4")), rugosidad: 0.2); reflectivo.emission.contents = NSColor(calibratedWhite: 0.22, alpha: 1)
        let franja = Mat.pbr(NSColor(Color(hex: "#e74c3c")), rugosidad: 0.3); franja.emission.contents = NSColor(calibratedRed: 0.2, green: 0.02, blue: 0, alpha: 1)

        // Chasis, ruedas y mecánica
        for x: CGFloat in [-0.45, 0.45] { caja(n, 0.16, 0.26, 6.3, negro, x: x, y: 0.85, z: -0.05) }
        func rueda(_ x: CGFloat, _ z: CGFloat, _ ancho: CGFloat) {
            let s: CGFloat = x > 0 ? 1 : -1
            let t = nodo(SCNTube(innerRadius: 0.29, outerRadius: 0.5, height: ancho), goma, y: 0.5, x: x, z: z); t.eulerAngles.z = .pi / 2; n.addChildNode(t)
            let l = nodo(SCNCylinder(radius: 0.3, height: ancho - 0.06), llanta, y: 0.5, x: x, z: z); l.eulerAngles.z = .pi / 2; n.addChildNode(l)
            let c = nodo(SCNCylinder(radius: 0.11, height: ancho + 0.04), cromo, y: 0.5, x: x, z: z); c.eulerAngles.z = .pi / 2; n.addChildNode(c)
            for k in 0..<8 {
                let a = CGFloat(k) * .pi / 4
                let p = nodo(SCNCylinder(radius: 0.022, height: 0.05), negro, y: 0.5 + sin(a) * 0.19, x: x + s * (ancho / 2 - 0.02), z: z + cos(a) * 0.19); p.eulerAngles.z = .pi / 2; n.addChildNode(p)
            }
        }
        for s: CGFloat in [-1, 1] {
            rueda(s * 1.0, 2.3, 0.34)
            for z: CGFloat in [-1.35, -2.45] { rueda(s * 0.86, z, 0.26); rueda(s * 1.12, z, 0.26) }
            caja(n, 0.62, 0.05, 2.45, negro, x: s * 1.0, y: 1.08, z: -1.9)                                   // guardabarros del tándem
            caja(n, 0.5, 0.45, 0.03, goma, x: s * 1.0, y: 0.6, z: -3.15)                                     // faldón
            caja(n, 0.3, 0.06, 0.06, negro, x: s * 0.75, y: 0.6, z: 1.3)                                     // soporte del estanque
        }
        let estanque = nodo(SCNCylinder(radius: 0.27, height: 1.1), cromo, y: 0.72, x: -0.95, z: 0.55); estanque.eulerAngles.x = .pi / 2; n.addChildNode(estanque)
        let aire = nodo(SCNCylinder(radius: 0.16, height: 0.9), negro, y: 0.72, x: 0.95, z: 0.55); aire.eulerAngles.x = .pi / 2; n.addChildNode(aire)
        cil(n, 0.075, 1.6, cromo, x: 1.02, y: 3.0, z: 1.27); cil(n, 0.09, 0.08, negro, x: 1.02, y: 3.82, z: 1.27)   // escape vertical

        // Cabina avanzada
        caja(n, 2.36, 1.55, 1.95, pintura, y: 1.95, z: 2.33, chaflan: 0.1)
        caja(n, 2.3, 0.86, 1.86, vidrioC, y: 3.15, z: 2.35, chaflan: 0.06)
        caja(n, 2.36, 0.2, 1.97, pintura, y: 3.67, z: 2.33, chaflan: 0.08)
        for s: CGFloat in [-1, 1] {
            caja(n, 0.08, 0.86, 0.08, pintura, x: s * 1.14, y: 3.15, z: 3.25)                              // pilar A
            caja(n, 0.08, 0.86, 0.1, pintura, x: s * 1.14, y: 3.15, z: 1.45)                               // pilar trasero
            caja(n, 0.05, 1.45, 0.03, negro, x: s * 1.18, y: 2.05, z: 1.62)                                // junta de la puerta
            caja(n, 0.04, 0.05, 0.22, cromo, x: s * 1.2, y: 2.4, z: 1.8)                                   // manilla
            cil(n, 0.02, 1.0, cromo, x: s * 1.2, y: 2.1, z: 1.4)                                           // pasamanos
            caja(n, 0.42, 0.05, 0.5, negro, x: s * 1.0, y: 0.98, z: 2.05)                                  // peldaño
            barra(n, SCNVector3(s * 1.16, 3.25, 3.1), SCNVector3(s * 1.46, 3.25, 3.25), 0.025, negro)       // brazo del espejo
            caja(n, 0.08, 0.5, 0.24, negro, x: s * 1.48, y: 3.0, z: 3.25)
            caja(n, 0.02, 0.44, 0.19, vidrioC, x: s * 1.43, y: 3.0, z: 3.25)
            caja(n, 0.34, 0.17, 0.04, faro, x: s * 0.82, y: 1.5, z: 3.31)                                  // faro
            caja(n, 0.14, 0.12, 0.04, ambar, x: s * 1.08, y: 1.5, z: 3.31)                                 // intermitente
            caja(n, 0.22, 0.32, 0.05, freno, x: s * 1.02, y: 1.0, z: -3.28)                                // focos traseros
            caja(n, 0.1, 0.32, 0.05, ambar, x: s * 0.84, y: 1.0, z: -3.28)
            let w = caja(n, 0.75, 0.025, 0.025, negro, x: s * 0.45, y: 2.82, z: 3.29); w.eulerAngles.z = s * 0.25   // limpiaparabrisas
        }
        caja(n, 1.3, 0.55, 0.04, negro, y: 1.95, z: 3.31)                                                    // parrilla
        for k in 0..<4 { caja(n, 1.26, 0.04, 0.03, cromo, y: 1.75 + CGFloat(k) * 0.13, z: 3.33) }
        caja(n, 2.44, 0.32, 0.26, negro, y: 1.02, z: 3.24)                                                  // parachoques
        caja(n, 0.5, 0.11, 0.03, blancoC, y: 1.02, z: 3.38)                                                 // patente
        let visera = caja(n, 2.3, 0.04, 0.3, negro, y: 3.6, z: 3.38); visera.eulerAngles.x = 0.15
        caja(n, 1.3, 0.12, 0.26, ambar, y: 3.84, z: 2.6)                                                    // barra de balizas
        caja(n, 1.36, 0.05, 0.3, negro, y: 3.77, z: 2.6)
        caja(n, 2.2, 0.12, 0.22, negro, y: 0.82, z: -3.28)                                                  // barra antiempotramiento

        switch oficio {
        case "agua":   // cisterna de acero inoxidable de sección elíptica, con anillos, pasarela, domos, escalera y válvulas
            let inox = Mat.pbr(NSColor(Color(hex: "#d9dee3")), rugosidad: 0.18, metal: 0.95)
            caja(n, 1.3, 0.16, 4.4, negro, y: 1.06, z: -1.0)
            for z: CGFloat in [-2.6, -1.0, 0.6] { caja(n, 1.9, 0.22, 0.2, negro, y: 1.2, z: z) }
            let t = nodo(SCNCylinder(radius: 1.0, height: 4.4), inox, y: 2.0, z: -1.0); t.eulerAngles.x = .pi / 2; t.scale = SCNVector3(1.15, 1, 0.8); n.addChildNode(t)
            for z: CGFloat in [1.2, -3.2] { let c = nodo(SCNSphere(radius: 1.0), inox, y: 2.0, z: z); c.scale = SCNVector3(1.15, 0.8, 0.14); n.addChildNode(c) }
            for z: CGFloat in [-2.5, -1.6, -0.4, 0.5] {
                let a = nodo(SCNTube(innerRadius: 1.0, outerRadius: 1.035, height: 0.07), inox, y: 2.0, z: z); a.eulerAngles.x = .pi / 2; a.scale = SCNVector3(1.15, 1, 0.8); n.addChildNode(a)
            }
            caja(n, 0.55, 0.04, 3.8, negro, y: 2.83, z: -1.0)
            for z: CGFloat in [-0.3, -1.9] { cil(n, 0.3, 0.12, inox, y: 2.86, z: z); cil(n, 0.12, 0.08, cromo, y: 2.96, z: z) }
            for s: CGFloat in [-1, 1] {
                barra(n, SCNVector3(s * 0.35, 3.25, -2.8), SCNVector3(s * 0.35, 3.25, 0.8), 0.02, cromo)
                for z: CGFloat in [-2.8, -1.0, 0.8] { barra(n, SCNVector3(s * 0.35, 2.83, z), SCNVector3(s * 0.35, 3.25, z), 0.018, cromo) }
                barra(n, SCNVector3(s * 0.25, 1.1, -3.38), SCNVector3(s * 0.25, 2.95, -3.38), 0.022, cromo)
                letrero(n, "AGUA POTABLE", "#1f6fb2", ancho: 2.4, alto: 0.38, x: s * 1.16, y: 2.05, z: -1.0, giro: s * .pi / 2, brillo: 0.4)
                caja(n, 0.04, 0.1, 4.0, reflectivo, x: s * 1.16, y: 1.55, z: -1.0)
                caja(n, 0.35, 0.55, 1.0, inox, x: s * 0.95, y: 1.35, z: 0.35)                               // gabinete de mangueras
            }
            for k in 0..<7 { caja(n, 0.56, 0.025, 0.025, cromo, y: 1.25 + CGFloat(k) * 0.26, z: -3.38) }
            let v = nodo(SCNCylinder(radius: 0.09, height: 0.5), cromo, y: 1.15, x: 0.55, z: -3.35); v.eulerAngles.x = .pi / 2; n.addChildNode(v)
            cil(n, 0.12, 0.03, franja, x: 0.55, y: 1.29, z: -3.4)
        case "residuos":   // recolector de carga trasera: caja compactadora con nervios, tolva, cilindros, pisaderas y franjas reflectantes
            caja(n, 2.4, 2.25, 3.55, pintura, y: 2.27, z: -0.75, chaflan: 0.12)
            for s: CGFloat in [-1, 1] {
                for k in 0..<8 { caja(n, 0.05, 2.1, 0.07, pintura, x: s * 1.215, y: 2.27, z: 0.85 - CGFloat(k) * 0.45) }
                caja(n, 0.04, 0.12, 3.5, reflectivo, x: s * 1.22, y: 1.35, z: -0.75)
                letrero(n, "RECOLECCIÓN · RECICLAJE", "#1e8449", ancho: 2.6, alto: 0.4, x: s * 1.26, y: 2.55, z: -0.75, giro: s * .pi / 2, brillo: 0.4)
                barra(n, SCNVector3(s * 1.25, 1.55, -2.4), SCNVector3(s * 1.25, 3.25, -2.75), 0.07, negro)   // cilindro de la compuerta
                barra(n, SCNVector3(s * 1.25, 2.3, -2.5), SCNVector3(s * 1.25, 3.2, -2.73), 0.035, cromo)
                caja(n, 0.6, 0.05, 0.38, negro, x: s * 0.82, y: 0.72, z: -3.62)                             // pisadera del peoneta
                cil(n, 0.025, 1.3, cromo, x: s * 1.0, y: 1.95, z: -3.52)
                caja(n, 0.16, 0.16, 0.06, ambar, x: s * 1.05, y: 3.48, z: -3.25)
            }
            caja(n, 2.42, 2.35, 0.95, pintura, y: 2.12, z: -3.0, chaflan: 0.1)                             // compuerta trasera
            let tapa = caja(n, 2.42, 0.12, 1.0, pintura, y: 3.3, z: -3.05); tapa.eulerAngles.x = -0.2
            caja(n, 2.0, 0.75, 0.1, negro, y: 1.35, z: -3.46)                                               // boca de la tolva
            caja(n, 1.95, 0.08, 0.35, cromo, y: 1.0, z: -3.45)                                              // labio de carga
            for k in 0..<5 {
                let c = caja(n, 0.16, 0.6, 0.02, k % 2 == 0 ? franja : reflectivo, x: -0.9 + CGFloat(k) * 0.45, y: 2.4, z: -3.49); c.eulerAngles.z = 0.6
            }
        case "nuclear":   // camión grúa con canastillo (cuadrilla eléctrica): carrocería de gabinetes, torreta, plumas aislada y de acero, estabilizadores
            caja(n, 2.4, 1.25, 4.45, pintura, y: 1.78, z: -1.0, chaflan: 0.05)
            for s: CGFloat in [-1, 1] {
                for k in 0..<4 {
                    let z = 0.7 - CGFloat(k) * 1.1
                    caja(n, 0.03, 1.05, 0.02, negro, x: s * 1.205, y: 1.78, z: z + 0.52)
                    caja(n, 0.035, 0.05, 0.16, cromo, x: s * 1.21, y: 2.05, z: z)
                }
                caja(n, 0.04, 0.1, 4.3, reflectivo, x: s * 1.21, y: 1.3, z: -1.0)
                caja(n, 0.35, 0.5, 0.35, negro, x: s * 1.3, y: 0.6, z: -3.05)                              // estabilizador
                caja(n, 0.45, 0.05, 0.45, negro, x: s * 1.3, y: 0.08, z: -3.05)
                barra(n, SCNVector3(s * 1.3, 0.85, -3.05), SCNVector3(s * 1.0, 1.4, -3.05), 0.06, cromo)
            }
            cil(n, 0.55, 0.3, negro, y: 2.55, z: -2.5); cil(n, 0.38, 0.55, pintura, y: 2.95, z: -2.5)      // torreta
            let pluma = caja(n, 0.34, 0.34, 3.85, pintura, y: 3.35, z: -0.6); pluma.eulerAngles.x = -0.06   // pluma inferior, sobre el apoyo de la cabina
            let aislada = caja(n, 0.26, 0.26, 3.5, blancoC, y: 3.72, z: -0.75); aislada.eulerAngles.x = -0.06
            barra(n, SCNVector3(0, 2.7, -1.9), SCNVector3(0, 3.18, 0.0), 0.08, negro)
            barra(n, SCNVector3(0, 2.9, -1.4), SCNVector3(0, 3.2, -0.2), 0.04, cromo)
            caja(n, 0.08, 0.95, 0.08, negro, y: 2.85, z: 1.2); caja(n, 0.6, 0.08, 0.2, negro, y: 3.2, z: 1.2)   // apoyo de la pluma
            caja(n, 0.75, 0.95, 0.75, blancoC, x: 0.75, y: 3.0, z: -2.95, chaflan: 0.04)                     // canastillo de fibra
            caja(n, 0.77, 0.08, 0.77, pintura, x: 0.75, y: 3.48, z: -2.95)
            for (x, z) in [(CGFloat(-0.75), CGFloat(-3.05)), (-0.4, -3.05)] {
                n.addChildNode(nodo(SCNCone(topRadius: 0.02, bottomRadius: 0.13, height: 0.45), franja, y: 2.65, x: x, z: z))
            }
            letrero(n, "ENERGÍA · CUADRILLA", "#b9770e", ancho: 2.2, alto: 0.32, x: 1.22, y: 1.75, z: -1.0, giro: .pi / 2, brillo: 0.4)
            letrero(n, "ENERGÍA · CUADRILLA", "#b9770e", ancho: 2.2, alto: 0.32, x: -1.22, y: 1.75, z: -1.0, giro: -.pi / 2, brillo: 0.4)
        default:   // furgón técnico: red (mástil telescópico con antena) o meteorología (radomo, mástil de sensores y panel solar)
            let red = oficio == "isp"
            caja(n, 2.4, 2.0, 4.3, blancoC, y: 2.15, z: -1.05, chaflan: 0.08)
            for s: CGFloat in [-1, 1] {
                caja(n, 0.04, 0.24, 4.32, pintura, x: s * 1.2, y: 1.62, z: -1.05)
                caja(n, 0.04, 0.08, 4.32, reflectivo, x: s * 1.2, y: 1.42, z: -1.05)
                caja(n, 0.03, 1.5, 0.02, negro, x: s * 1.215, y: 2.05, z: 0.3); caja(n, 0.03, 1.5, 0.02, negro, x: s * 1.215, y: 2.05, z: -0.6)
                caja(n, 0.03, 0.4, 0.55, vidrioC, x: s * 1.215, y: 2.55, z: -0.15)
                caja(n, 0.035, 0.05, 0.14, cromo, x: s * 1.22, y: 2.0, z: -0.45)
                letrero(n, red ? "RED · TELECOMUNICACIONES" : "METEOROLOGÍA · MEDICIÓN", red ? "#ca6f1e" : "#2471a3",
                        ancho: 2.2, alto: 0.34, x: s * 1.23, y: 2.55, z: -2.0, giro: s * .pi / 2, brillo: 0.4)
                barra(n, SCNVector3(s * 0.95, 3.25, 0.7), SCNVector3(s * 0.95, 3.25, -2.9), 0.025, cromo)   // baca
            }
            caja(n, 0.02, 1.8, 0.02, negro, y: 2.1, z: -3.21)                                                // puertas traseras
            for x: CGFloat in [-0.25, 0.25] { caja(n, 0.05, 0.14, 0.03, cromo, x: x, y: 2.1, z: -3.22) }
            if red {
                for k in 0..<6 { caja(n, 0.5, 0.025, 0.04, cromo, x: -0.5, y: 3.28, z: 0.4 - CGFloat(k) * 0.4) }
                barra(n, SCNVector3(-0.75, 3.28, 0.5), SCNVector3(-0.75, 3.28, -1.7), 0.02, cromo); barra(n, SCNVector3(-0.25, 3.28, 0.5), SCNVector3(-0.25, 3.28, -1.7), 0.02, cromo)
                for (k, r) in [CGFloat(0.12), 0.095, 0.07].enumerated() { cil(n, r, 1.3, k == 2 ? cromo : negro, x: 0.65, y: 3.8 + CGFloat(k) * 1.1, z: -2.7) }
                caja(n, 0.5, 0.06, 0.06, negro, x: 0.65, y: 6.35, z: -2.7)
                let plato = SCNNode(); plato.position = SCNVector3(0.65, 6.15, -2.55); plato.eulerAngles.x = .pi / 2 - 0.25; n.addChildNode(plato)
                let pm = blancoC.copy() as! SCNMaterial; pm.isDoubleSided = true
                plato.addChildNode(SCNNode(geometry: { let g = torno([(r: 0.01, y: 0), (r: 0.2, y: 0.03), (r: 0.38, y: 0.1), (r: 0.5, y: 0.18)], lados: 24); g.materials = [pm]; return g }()))
                caja(n, 0.28, 0.5, 0.1, blancoC, x: 0.85, y: 6.35, z: -2.85)
                caja(n, 0.7, 0.55, 0.6, negro, x: -0.6, y: 0.85, z: -2.3)                                    // generador
            } else {
                cil(n, 0.32, 0.25, negro, y: 3.27, z: -2.2); n.addChildNode(nodo({ let g = SCNSphere(radius: 0.62); g.isGeodesic = true; g.segmentCount = 8; return g }(), blancoC, y: 3.85, z: -2.2))
                let panel = nodo(SCNBox(width: 1.6, height: 0.04, length: 1.0, chamferRadius: 0), { let m = Mat.pbr(.white, rugosidad: 0.12, metal: 0.5); m.diffuse.contents = Self.celdasSolares; return m }(), y: 3.3, z: -0.3)
                n.addChildNode(panel)
                cil(n, 0.035, 1.8, cromo, x: 0.9, y: 4.05, z: 0.75)
                caja(n, 0.9, 0.03, 0.03, cromo, x: 0.9, y: 4.95, z: 0.75)
                for k in 0..<3 {
                    let a = CGFloat(k) * 2 * .pi / 3
                    barra(n, SCNVector3(0.45, 5.05, 0.75), SCNVector3(0.45 + cos(a) * 0.2, 5.05, 0.75 + sin(a) * 0.2), 0.012, cromo)
                    n.addChildNode(nodo(SCNSphere(radius: 0.055), blancoC, y: 5.05, x: 0.45 + cos(a) * 0.2, z: 0.75 + sin(a) * 0.2))
                }
                caja(n, 0.04, 0.12, 0.35, blancoC, x: 1.35, y: 5.05, z: 0.75)
            }
        }
        let p = aplanado(n, nombre); p.scale = SCNVector3(1, 1, 1); return p
    }

    /// Excavadora hidráulica sobre orugas: tren de rodaje con zapatas, rodillos, rueda motriz y guía; tornamesa; superestructura
    /// con contrapeso redondeado, capó con rejillas, escape, cabina ROPS de vidrio, pluma y brazo con cilindros cromados y balde con dientes.
    private func excavadora() -> SCNNode {
        let n = SCNNode()
        let amarillo = Mat.pbr(NSColor(Color(hex: "#f2b705")), rugosidad: 0.38, metal: 0.25), amOsc = Mat.pbr(NSColor(Color(hex: "#c98f00")), rugosidad: 0.5, metal: 0.25)
        let negro = Mat.pbr(NSColor(calibratedWhite: 0.07, alpha: 1), rugosidad: 0.85), acero = Mat.pbr(NSColor(calibratedWhite: 0.32, alpha: 1), rugosidad: 0.6, metal: 0.8)
        let cromo = Mat.pbr(NSColor(calibratedWhite: 0.9, alpha: 1), rugosidad: 0.08, metal: 1), vidrioC = Mat.pbr(NSColor(Color(hex: "#1c2d3a")), rugosidad: 0.04, metal: 0.7)
        let polvo = Mat.pbr(NSColor(Color(hex: "#8a7a63")), rugosidad: 0.95, metal: 0.1)

        // Tren de rodaje: dos orugas de 3,4 m (zapatas en el contorno), bastidor central y tornamesa
        for s: CGFloat in [-1, 1] {
            let x = s * 1.05
            caja(n, 0.55, 0.42, 2.7, acero, x: x, y: 0.5)
            for k in 0..<22 { caja(n, 0.6, 0.06, 0.13, polvo, x: x, y: 0.03, z: -1.35 + CGFloat(k) * 0.129) }   // zapatas en el suelo
            for k in 0..<20 { caja(n, 0.6, 0.06, 0.13, negro, x: x, y: 0.93, z: -1.25 + CGFloat(k) * 0.13) }    // zapatas arriba
            for z: CGFloat in [-1.55, 1.55] {
                let r = nodo(SCNCylinder(radius: 0.44, height: 0.6), negro, y: 0.48, x: x, z: z); r.eulerAngles.z = .pi / 2; n.addChildNode(r)
                let m = nodo(SCNCylinder(radius: 0.3, height: 0.64), z < 0 ? acero : amOsc, y: 0.48, x: x, z: z); m.eulerAngles.z = .pi / 2; n.addChildNode(m)
            }
            for k in 0..<5 { let r = nodo(SCNCylinder(radius: 0.12, height: 0.62), acero, y: 0.2, x: x, z: -0.9 + CGFloat(k) * 0.45); r.eulerAngles.z = .pi / 2; n.addChildNode(r) }
            for z: CGFloat in [-0.5, 0.5] { let r = nodo(SCNCylinder(radius: 0.08, height: 0.4), acero, y: 0.78, x: x, z: z); r.eulerAngles.z = .pi / 2; n.addChildNode(r) }
        }
        caja(n, 1.6, 0.4, 1.4, acero, y: 0.55)
        cil(n, 0.95, 0.22, negro, y: 0.88)

        // Superestructura (gira sobre la tornamesa; mirando al acopio)
        let u = SCNNode(); u.position = SCNVector3(0, 0, 0); u.eulerAngles.y = 0.25; n.addChildNode(u)
        caja(u, 2.5, 0.25, 2.9, amOsc, y: 1.12, z: -0.2)
        caja(u, 1.45, 0.95, 1.6, amarillo, x: 0.48, y: 1.72, z: -0.65, chaflan: 0.08)                  // capó del motor
        for k in 0..<6 { caja(u, 0.9, 0.02, 0.06, negro, x: 0.48, y: 2.205, z: -1.2 + CGFloat(k) * 0.18) }   // rejillas
        let cw = nodo(SCNCylinder(radius: 1.25, height: 0.9), amarillo, y: 1.62, z: -0.9); cw.scale = SCNVector3(1, 1, 0.55); u.addChildNode(cw)   // contrapeso
        caja(u, 2.3, 0.9, 0.3, amarillo, y: 1.62, z: -1.25)
        caja(u, 2.5, 0.05, 0.08, negro, y: 1.25, z: -1.6)
        cil(u, 0.07, 0.75, negro, x: 0.85, y: 2.55, z: -0.4); cil(u, 0.09, 0.06, negro, x: 0.85, y: 2.94, z: -0.4)   // escape
        caja(u, 0.85, 0.25, 0.5, negro, x: -0.75, y: 1.38, z: -0.75)                                     // estanque hidráulico
        // Cabina: estructura de pilares con vidrio, techo, peldaños y pasamanos
        let cab = SCNNode(); cab.position = SCNVector3(-0.68, 1.25, 0.6); u.addChildNode(cab)
        caja(cab, 0.95, 1.5, 1.35, vidrioC, y: 0.82, chaflan: 0.04)
        for (x, z) in [(CGFloat(-0.47), CGFloat(0.66)), (0.47, 0.66), (-0.47, -0.66), (0.47, -0.66)] { caja(cab, 0.07, 1.55, 0.07, amarillo, x: x, y: 0.82, z: z) }
        caja(cab, 1.0, 0.1, 1.4, amarillo, y: 1.62); caja(cab, 0.97, 0.25, 1.37, amarillo, y: 0.12)
        caja(cab, 0.02, 0.05, 0.6, negro, x: 0.48, y: 0.85, z: -0.2)
        cil(cab, 0.02, 0.9, negro, x: -0.52, y: 0.65, z: -0.3)
        caja(cab, 0.25, 0.04, 0.3, negro, x: -0.6, y: -0.4, z: 0.2)
        caja(cab, 0.18, 0.1, 0.06, Mat.emisivo(NSColor(calibratedRed: 1, green: 0.95, blue: 0.85, alpha: 1), fuerza: 0.7), x: 0.25, y: 1.6, z: 0.71)   // foco de trabajo
        cil(cab, 0.07, 0.12, Mat.emisivo(NSColor(calibratedRed: 1, green: 0.58, blue: 0.08, alpha: 1), fuerza: 0.9), x: -0.3, y: 1.73, z: -0.4)   // baliza
        // Pluma y brazo en el plano x = 0,25, con cilindros hidráulicos (camisa amarilla y vástago cromado)
        let px: CGFloat = 0.2
        let pie = SCNVector3(px, 1.45, 0.95), codo = SCNVector3(px, 3.55, 2.8), muñeca = SCNVector3(px, 1.15, 4.05)
        func viga(_ a: SCNVector3, _ b: SCNVector3, _ w: CGFloat, _ h: CGFloat) {
            let d = SCNVector3(b.x - a.x, b.y - a.y, b.z - a.z), L = sqrt(d.y * d.y + d.z * d.z)
            let v = nodo(SCNBox(width: w, height: h, length: L, chamferRadius: 0.04), amarillo, y: (a.y + b.y) / 2, x: a.x, z: (a.z + b.z) / 2)
            v.eulerAngles.x = -atan2(d.y, d.z); u.addChildNode(v)
        }
        func cilindro(_ a: SCNVector3, _ b: SCNVector3, _ r: CGFloat) {
            let m = SCNVector3(a.x + (b.x - a.x) * 0.55, a.y + (b.y - a.y) * 0.55, a.z + (b.z - a.z) * 0.55)
            barra(u, a, m, r, amOsc); barra(u, m, b, r * 0.5, cromo)
            for p in [a, b] { let o = nodo(SCNCylinder(radius: r * 0.9, height: 0.4), negro, y: p.y, x: p.x, z: p.z); o.eulerAngles.z = .pi / 2; u.addChildNode(o) }
        }
        caja(u, 0.5, 0.45, 0.5, amOsc, x: px, y: 1.45, z: 0.95)                                           // pie de la pluma
        let quiebre = SCNVector3(px, 3.05, 1.75)
        viga(pie, quiebre, 0.42, 0.55); viga(quiebre, codo, 0.42, 0.5)
        viga(codo, muñeca, 0.32, 0.42)
        for p in [pie, quiebre, codo] { let o = nodo(SCNCylinder(radius: 0.17, height: 0.5), acero, y: p.y, x: p.x, z: p.z); o.eulerAngles.z = .pi / 2; u.addChildNode(o) }
        cilindro(SCNVector3(px, 1.35, 1.35), SCNVector3(px, 2.75, 1.95), 0.11)                          // cilindro de la pluma
        cilindro(SCNVector3(px, 3.35, 1.95), SCNVector3(px, 3.95, 2.95), 0.09)                          // cilindro del brazo
        cilindro(SCNVector3(px, 3.1, 3.05), SCNVector3(px, 1.65, 3.85), 0.075)                          // cilindro del balde
        barra(u, SCNVector3(px, 2.6, 1.6), SCNVector3(px, 3.3, 2.6), 0.03, negro)                       // mangueras
        // Balde con dientes, apoyado en el acopio
        let b = SCNNode(); b.position = muñeca; b.eulerAngles.x = 0.5; u.addChildNode(b)
        caja(b, 0.85, 0.06, 0.75, acero, y: -0.45, z: 0.3); caja(b, 0.85, 0.75, 0.06, acero, y: -0.1, z: -0.05)
        for s: CGFloat in [-1, 1] { caja(b, 0.05, 0.7, 0.75, acero, x: s * 0.42, y: -0.15, z: 0.25) }
        caja(b, 0.86, 0.12, 0.12, amarillo, y: 0.2, z: -0.05)
        for k in 0..<5 { let d = nodo(SCNPyramid(width: 0.1, height: 0.22, length: 0.06), cromo, y: -0.45, x: -0.34 + CGFloat(k) * 0.17, z: 0.68); d.eulerAngles.x = .pi / 2; b.addChildNode(d) }
        b.addChildNode(nodo(SCNSphere(radius: 0.32), polvo, y: -0.25, z: 0.3))                           // carga de escombros
        return n
    }

    func montarEnergia(_ r: SCNNode) {
        let A = Islas.angEner
        func marco() -> SCNNode { let n = marcoLocal(A, Islas.rEner); r.addChildNode(n); return n }
        func fijar(_ g: SCNNode, _ nombre: String) { escena.rootNode.addChildNode(aplanado(g, nombre)); g.removeFromParentNode() }
        func navR(_ x: CGFloat, _ z: CGFloat, _ hx: CGFloat, _ hz: CGFloat, _ giro: CGFloat = 0, linea: Int = #line) {
            let q = Islas.ener(x, z); nav.rect(q.x, q.y, hx, hz, A + giro, linea: linea)
        }
        func navC(_ x: CGFloat, _ z: CGFloat, _ rr: CGFloat, linea: Int = #line) { let q = Islas.ener(x, z); nav.circulo(q.x, q.y, rr, linea: linea) }
        let asfalto = Mat.pbr(NSColor(calibratedWhite: 0.19, alpha: 1), rugosidad: 0.85), blanco = Mat.pbr(NSColor(calibratedWhite: 0.96, alpha: 1))
        let hormigon = Mat.pbr(NSColor(calibratedWhite: 0.78, alpha: 1), rugosidad: 0.8), gris = Mat.pbr(NSColor(Color(hex: "#7b8790")), rugosidad: 0.5, metal: 0.5)
        let acero = Mat.pbr(NSColor(Color(hex: "#c9ced3")), rugosidad: 0.3, metal: 0.8), agua = Mat.pbr(NSColor(Color(hex: "#2f7fb5")), rugosidad: 0.08, metal: 0.2)
        let vidrio = Mat.pbr(NSColor(Color(hex: "#3b6f94")), rugosidad: 0.08, metal: 0.6), grava = Mat.pbr(NSColor(Color(hex: "#b9ad97")), rugosidad: 0.95)
        let luz = Mat.emisivo(NSColor(calibratedRed: 1, green: 0.9, blue: 0.6, alpha: 1)); focos.append(luz)

        // Calles: avenida desde el puente y circunvalación de la isla (radio 30, dos carriles)
        let calles = marco()
        caja(calles, 7, 0.05, 17, asfalto, y: 0.03, z: -35.5)
        calles.addChildNode(nodo(SCNTube(innerRadius: 27, outerRadius: 33, height: 0.05), asfalto, y: 0.032))
        for k in 0..<60 where k % 2 == 0 {
            let a = CGFloat(k) / 60 * 2 * .pi
            caja(calles, 0.14, 0.02, 1.6, blanco, x: sin(a) * 30, y: 0.065, z: cos(a) * 30, giro: a + .pi / 2)
        }
        for g in stride(from: CGFloat(0), to: 360, by: 30) where abs(g - 180) > 10 {        // faroles en el borde interior
            let p = polE(25.5, g); cil(calles, 0.07, 4.2, gris, x: p.x, z: p.z); calles.addChildNode(nodo(SCNSphere(radius: 0.25), luz, y: 4.3, x: p.x, z: p.z)); navC(p.x, p.z, 0.15)
        }
        fijar(calles, "elem:energia")

        // Central nuclear (CPU), tipo PWR: contención cilíndrica con cúpula, edificio auxiliar con chimenea de ventilación,
        // sala de turbinas, torre de enfriamiento hiperboloide de tiro natural y patio de alta tensión.
        let N = marco()
        let hormigonT = Mat.textura(.estuco, repetir: 4, tinte: "#d2cdc3"), chapa = Mat.pbr(NSColor(Color(hex: "#9fabb4")), rugosidad: 0.45, metal: 0.45)
        let rojo = Mat.pbr(NSColor(Color(hex: "#c0392b")), rugosidad: 0.5), oscuro = Mat.pbr(NSColor(calibratedWhite: 0.1, alpha: 1), rugosidad: 0.9)
        let aislador = Mat.pbr(NSColor(Color(hex: "#7a4a2a")), rugosidad: 0.3)
        func transformador(_ g: SCNNode, _ x: CGFloat, _ z: CGFloat) {
            let t = SCNNode(); t.position = SCNVector3(x, 0, z); g.addChildNode(t)
            caja(t, 1.7, 0.2, 1.3, hormigon)
            caja(t, 1.3, 1.3, 0.9, gris, y: 0.85)
            for k in 0..<5 { caja(t, 0.05, 1.0, 0.45, gris, x: -0.5 + CGFloat(k) * 0.25, y: 0.8, z: 0.68) }
            for k in 0..<3 { cil(t, 0.07, 0.75, aislador, x: -0.4 + CGFloat(k) * 0.4, y: 1.85) }
        }
        cil(N, 4.5, 7.5, hormigonT, x: 11, z: 9)
        N.addChildNode(nodo(SCNSphere(radius: 4.5), hormigonT, y: 7.5, x: 11, z: 9))
        cil(N, 4.62, 0.35, gris, x: 11, y: 7.4, z: 9)
        caja(N, 0.4, 2.6, 2.2, chapa, x: 6.45, z: 9)                                            // compuerta de equipos
        navC(11, 9, 4.6)
        caja(N, 5, 4, 3, Mat.textura(.estuco, repetir: 2, tinte: "#c9ccd0"), x: 11, z: 15.5); navR(11, 15.5, 2.6, 1.6)
        cil(N, 0.55, 20, hormigonT, x: 9.3, z: 14.6)                                             // chimenea de ventilación
        for h: CGFloat in [16, 18.2] { cil(N, 0.57, 0.9, rojo, x: 9.3, y: h, z: 14.6) }
        caja(N, 9, 5.4, 5, chapa, x: 3, z: 18); caja(N, 9.2, 0.3, 5.2, gris, x: 3, y: 5.55, z: 18)
        for k in 0..<7 { caja(N, 0.08, 5.2, 0.04, gris, x: -1.2 + CGFloat(k) * 1.4, y: 2.6, z: 15.48) }       // nervaduras del revestimiento
        caja(N, 8, 1.1, 0.06, ventana(), x: 3, y: 3.6, z: 15.47); navR(3, 18, 4.6, 2.6)
        caja(N, 2.4, 2.8, 0.06, chapa, x: 0.5, y: 1.4, z: 15.46)                                   // portón de montaje
        letrero(N, "CENTRAL NUCLEAR · CPU", "#c27c0e", ancho: 5.5, alto: 0.6, x: 3, y: 4.75, z: 15.45)
        transformador(N, 8.6, 18.0); navC(8.6, 18.0, 1.0)
        // Patio de alta tensión: transformadores, pórticos y líneas aéreas de tres conductores
        let py = (x: CGFloat(20.5), z: CGFloat(6))
        caja(N, 3.4, 0.03, 4.4, grava, x: py.x, y: 0.02, z: py.z)
        transformador(N, py.x - 0.6, py.z - 1); transformador(N, py.x - 0.6, py.z + 1.2); navR(py.x, py.z, 1.7, 2.2)
        for (gx, gz) in [(py.x + 1.2, py.z), (CGFloat(8.6), CGFloat(20.6))] {
            for d: CGFloat in [-1, 1] { celosia(N, gx, gz + d * 1.3, alto: 7, base: 0.18, cima: 0.12, tramos: 3, acero, acero) }
            caja(N, 0.25, 0.25, 2.9, acero, x: gx, y: 7, z: gz)
        }
        for d: CGFloat in [-0.9, 0, 0.9] { barra(N, SCNVector3(8.6, 6.9, 20.6 + d), SCNVector3(py.x + 1.2, 6.9, py.z + d), 0.035, oscuro) }
        // Torre de enfriamiento hiperboloide sobre pilares en X, con estanque y anillo superior
        let tN = SCNNode(); tN.position = SCNVector3(17, 0, -5); N.addChildNode(tN)
        let perfilT: [(r: CGFloat, y: CGFloat)] = (0...20).map { k in let y = CGFloat(k); return (3.4 * sqrt(1 + pow((y - 14) / 9.87, 2)), y + 1.3) }
        let mT = Mat.textura(.estuco, repetir: 3, tinte: "#d9d5cd"); mT.isDoubleSided = true
        tN.addChildNode(nodo(torno(perfilT, lados: 56), mT))
        tN.addChildNode(nodo(SCNTube(innerRadius: 3.85, outerRadius: 4.12, height: 0.35), hormigon, y: 21.4))
        tN.addChildNode(nodo(SCNCylinder(radius: 5.7, height: 0.08), oscuro, y: 0.06))
        tN.addChildNode(nodo(SCNTube(innerRadius: 5.75, outerRadius: 6.05, height: 0.45), hormigon, y: 0.22))
        for k in 0..<28 {
            let a = CGFloat(k) / 28 * 2 * .pi, b = a + 0.12, c = a - 0.12
            barra(tN, SCNVector3(5.9 * cos(a), 0, 5.9 * sin(a)), SCNVector3(5.9 * cos(b), 1.35, 5.9 * sin(b)), 0.11, hormigon)
            barra(tN, SCNVector3(5.9 * cos(a), 0, 5.9 * sin(a)), SCNVector3(5.9 * cos(c), 1.35, 5.9 * sin(c)), 0.11, hormigon)
        }
        navC(17, -5, 6.1)
        fijar(N, "elem:ener-nuclear")
        vapor(17, -5, y: 21.7, radio: 3.2, tasa: 24, vida: 12, sube: 3.2, tam: 3.0, crece: 3.0, opacidad: 0.9, viento: 1.8)

        // Central hidroeléctrica (memoria): embalse con terraplén, presa de gravedad con vertedero, tuberías forzadas,
        // casa de máquinas con transformador y canal de descarga.
        let Hd = marco()
        let pasto = Mat.textura(.pasto, repetir: 3), espuma = Mat.pbr(NSColor(calibratedWhite: 0.95, alpha: 1), rugosidad: 0.3)
        espuma.emission.contents = NSColor(calibratedWhite: 0.3, alpha: 1)
        Hd.addChildNode(nodo(SCNCone(topRadius: 4.5, bottomRadius: 5.2, height: 2.8), pasto, y: 1.4, x: -9, z: 17))
        Hd.addChildNode(nodo(SCNCylinder(radius: 4.35, height: 0.06), agua, y: 2.83, x: -9, z: 17)); navC(-9, 17, 5.3)
        caja(Hd, 7.6, 3.4, 1.4, hormigonT, x: -9, z: 12.2)
        caja(Hd, 7.8, 0.2, 1.6, hormigon, x: -9, y: 3.5, z: 12.2)
        for k in 0..<16 { cil(Hd, 0.03, 0.6, gris, x: -12.7 + CGFloat(k) * 0.49, y: 3.9, z: 11.5) }  // baranda del coronamiento
        caja(Hd, 7.8, 0.05, 0.05, gris, x: -9, y: 4.18, z: 11.5)
        let chute = nodo(SCNBox(width: 1.2, height: 0.08, length: 3.6, chamferRadius: 0), espuma, y: 1.75, x: -5.9, z: 11.4); chute.eulerAngles.x = -0.97; Hd.addChildNode(chute)
        for d: CGFloat in [-0.65, 0.65] { let mur = nodo(SCNBox(width: 0.15, height: 0.5, length: 3.6, chamferRadius: 0), hormigon, y: 1.85, x: -5.9 + d, z: 11.4); mur.eulerAngles.x = -0.97; Hd.addChildNode(mur) }
        caja(Hd, 1.8, 0.05, 1.4, espuma, x: -5.9, y: 0.04, z: 9.9)
        for x: CGFloat in [-10.2, -8.2] {
            barra(Hd, SCNVector3(x, 2.6, 11.6), SCNVector3(x, 1.0, 10.0), 0.38, acero)
            caja(Hd, 1.0, 1.0, 0.8, hormigon, x: x, y: 2.4, z: 11.4)
        }
        caja(Hd, 5, 3.8, 3, Mat.textura(.estuco, repetir: 2, tinte: "#cfdbe3"), x: -9, z: 8.5); navR(-9, 8.5, 2.6, 1.6)
        caja(Hd, 5.2, 0.25, 3.2, gris, x: -9, y: 3.9, z: 8.5)
        for k in 0..<4 { caja(Hd, 0.8, 2.2, 0.06, ventana(), x: -10.8 + CGFloat(k) * 1.2, y: 1.9, z: 6.98) }
        letrero(Hd, "HIDROELÉCTRICA · MEMORIA", "#1f6fb2", ancho: 4.4, alto: 0.5, x: -9, y: 3.35, z: 6.97)
        caja(Hd, 3, 0.05, 2.6, agua, x: -9, y: 0.035, z: 5.6)
        caja(Hd, 3.4, 0.25, 0.2, hormigon, x: -9, y: 0.12, z: 4.25)
        fijar(Hd, "elem:ener-hidro")
        vapor(-5.9, 10.2, y: 0.5, radio: 0.7, tasa: 6, vida: 3, sube: 0.6, tam: 0.9, crece: 2.6, opacidad: 0.45, viento: 0.4)

        // Central geotérmica (disco): casa de turbinas, torre de enfriamiento de tiro mecánico con ventiladores,
        // pozos con árbol de válvulas y vaporductos aislados sobre soportes, con lazo de dilatación.
        let G = marco()
        caja(G, 6, 3.8, 4, chapa, x: -17, z: -1); caja(G, 6.2, 0.25, 4.2, gris, x: -17, y: 3.9, z: -1); navR(-17, -1, 3.1, 2.1)
        caja(G, 5.4, 0.9, 0.06, ventana(), x: -17, y: 2.7, z: 1.02)
        letrero(G, "GEOTÉRMICA · DISCO", "#a0522d", ancho: 3.8, alto: 0.5, x: -17, y: 3.2, z: -3.03, giro: .pi)
        caja(G, 6, 2.8, 2.6, Mat.pbr(NSColor(Color(hex: "#6f8a7a")), rugosidad: 0.6, metal: 0.3), x: -19, z: -7.6); navR(-19, -7.6, 3.1, 1.4)
        for k in 0..<3 {
            let x = -21 + CGFloat(k) * 2
            G.addChildNode(nodo(SCNTube(innerRadius: 0.78, outerRadius: 0.88, height: 1.0), chapa, y: 3.3, x: x, z: -7.6))
            G.addChildNode(nodo(SCNCylinder(radius: 0.78, height: 0.05), oscuro, y: 3.0, x: x, z: -7.6))
            for j in 0..<6 { caja(G, 0.05, 1.0, 0.04, chapa, x: x - 0.9 + CGFloat(j) * 0.36, y: 1.6, z: -6.28) }
        }
        let pozos: [(CGFloat, CGFloat)] = [(-21, 5), (-16.5, 6.5), (-12.5, 3)]
        for (x, z) in pozos {
            caja(G, 1.6, 0.15, 1.6, hormigon, x: x, z: z); navC(x, z, 0.8)
            cil(G, 0.2, 1.6, gris, x: x, z: z)
            for h: CGFloat in [0.7, 1.3] { G.addChildNode(nodo(SCNTorus(ringRadius: 0.28, pipeRadius: 0.04), rojo, y: h, x: x + 0.25, z: z)) }
        }
        let tubo: [[(CGFloat, CGFloat)]] = [[(-21, 5), (-21, 3), (-19, 3), (-19, 1.05)],
                                           [(-16.5, 6.5), (-16.5, 4.8), (-15.2, 4.8), (-15.2, 3.4), (-16.5, 3.4), (-16.5, 1.05)],
                                           [(-12.5, 3), (-14.4, 3), (-14.4, 1.05)]]
        for ruta in tubo {
            for k in 1..<ruta.count {
                let a = ruta[k - 1], b = ruta[k]
                barra(G, SCNVector3(a.0, 1.2, a.1), SCNVector3(b.0, 1.2, b.1), 0.17, acero)
                if k < ruta.count - 1 { cil(G, 0.05, 1.05, gris, x: b.0, z: b.1); G.addChildNode(nodo(SCNSphere(radius: 0.18), acero, y: 1.2, x: b.0, z: b.1)) }
            }
        }
        fijar(G, "elem:ener-geo")
        for k in 0..<3 { vapor(-21 + CGFloat(k) * 2, -7.6, y: 3.9, radio: 0.65, tasa: 5, vida: 7, sube: 1.8, tam: 1.6, crece: 3.2, opacidad: 0.75, viento: 0.8) }
        for (x, z) in pozos.prefix(2) { vapor(x, z, y: 1.7, radio: 0.12, tasa: 4, vida: 4, sube: 1.2, tam: 0.5, crece: 3, opacidad: 0.5, viento: 0.7) }

        // Parque solar (batería): mesas de módulos fotovoltaicos con estructura y celdas visibles
        let S = marco()
        let celdas = Mat.pbr(.white, rugosidad: 0.12, metal: 0.5); celdas.diffuse.contents = Self.celdasSolares
        for g in stride(from: CGFloat(30), through: 84, by: 4.5) {
            for rr: CGFloat in [36.0, 38.4, 40.8] {
                let p = polE(rr, g), m = SCNNode(); m.position = SCNVector3(p.x, 0, p.z); m.eulerAngles.y = g * .pi / 180 + .pi; S.addChildNode(m)
                for dx: CGFloat in [-0.9, 0.9] { cil(m, 0.05, 0.7, gris, x: dx, z: 0.45); cil(m, 0.05, 1.35, gris, x: dx, z: -0.45) }
                let pl = nodo(SCNBox(width: 2.4, height: 0.05, length: 1.5, chamferRadius: 0), celdas, y: 1.05); pl.eulerAngles.x = -0.55; m.addChildNode(pl)
                navC(p.x, p.z, 1.25)
            }
        }
        let ps = polE(37.9, 19), gs = CGFloat(19) * .pi / 180     // antes de la primera mesa (30°): sin taparla
        letrero(S, "PARQUE SOLAR · BATERÍA", "#d4ac0d", ancho: 4.4, alto: 0.55, x: ps.x, y: 1.4, z: ps.z, giro: gs + .pi)
        for d: CGFloat in [-1.9, 1.9] { cil(S, 0.05, 1.12, gris, x: ps.x + cos(gs) * d, z: ps.z - sin(gs) * d) }
        fijar(S, "elem:ener-solar")

        // Planta de residuos y escombros: nave de transferencia con portones, chimenea de valorización energética,
        // contenedores de reciclaje, acopio de escombros y excavadora.
        let R = marco()
        let pr = polE(39, 150), gr = CGFloat(150) * .pi / 180
        let nave = SCNNode(); nave.position = SCNVector3(pr.x, 0, pr.z); nave.eulerAngles.y = gr; R.addChildNode(nave)
        caja(nave, 8, 4.2, 4.6, Mat.pbr(NSColor(Color(hex: "#5f7d4a")), rugosidad: 0.55, metal: 0.35))
        for k in 0..<4 { let t = nodo(SCNBox(width: 2.0, height: 0.12, length: 4.8, chamferRadius: 0), gris, y: 4.45, x: -3 + CGFloat(k) * 2); t.eulerAngles.z = 0.25; nave.addChildNode(t) }
        for dx: CGFloat in [-2.2, 1.6] { caja(nave, 2.2, 2.9, 0.06, oscuro, x: dx, y: 1.45, z: -2.33) }
        cil(nave, 0.45, 13, hormigonT, x: 3.2, z: 1.2); cil(nave, 0.47, 0.6, rojo, x: 3.2, y: 12.4, z: 1.2)
        letrero(nave, "PLANTA DE RESIDUOS · LIMPIEZA DEL MAC", "#2e7d32", ancho: 6.5, alto: 0.6, y: 3.6, z: -2.35, giro: .pi)
        navR(pr.x, pr.z, 4.1, 2.4, gr)
        for (k, c) in ["#2e7d32", "#1f6fb2", "#d4ac0d", "#7f8c8d"].enumerated() {
            let g = 135 - CGFloat(k) * 3.2, p = polE(37.5, g), b = SCNNode(); b.position = SCNVector3(p.x, 0, p.z); b.eulerAngles.y = g * .pi / 180; R.addChildNode(b)
            let mc = Mat.pbr(NSColor(Color(hex: c)), rugosidad: 0.6, metal: 0.2)
            caja(b, 1.7, 1.1, 1.2, mc); caja(b, 1.8, 0.08, 1.3, mc, y: 1.15); caja(b, 0.06, 0.9, 1.0, oscuro, x: 0.86, y: 0.55)
            navC(p.x, p.z, 1.0)
        }
        let pe = polE(38.5, 122)
        for (dx, dz, rr, hh, c) in [(CGFloat(0), CGFloat(0), CGFloat(2.1), CGFloat(1.9), "#b9ad97"), (0.8, 0.6, 1.3, 1.3, "#8d8478"), (-0.7, -0.5, 1.1, 1.0, "#a5714e")] {
            R.addChildNode(nodo(SCNCone(topRadius: 0.15, bottomRadius: rr, height: hh), Mat.pbr(NSColor(Color(hex: c)), rugosidad: 0.95), y: hh / 2, x: pe.x + dx, z: pe.z + dz))
        }
        navC(pe.x, pe.z, 2.2)
        let px = polE(41.6, 127), ex = excavadora(); ex.position = SCNVector3(px.x, 0, px.z); ex.eulerAngles.y = -0.37   // excavadora de 8 t cargando escombros del acopio
        ex.scale = SCNVector3(0.8, 0.8, 0.8); R.addChildNode(ex)
        let amarillo = Mat.pbr(NSColor(Color(hex: "#f1c40f")), rugosidad: 0.45, metal: 0.2)
        navC(px.x, px.z, 1.8)
        fijar(R, "elem:ener-residuos")
        let pch = (x: pr.x + cos(gr) * 3.2 + sin(gr) * 1.2, z: pr.z - sin(gr) * 3.2 + cos(gr) * 1.2)
        vapor(pch.x, pch.z, y: 13.1, radio: 0.3, tasa: 4, vida: 9, sube: 1.4, tam: 1.0, crece: 4.5, gris: 0.8, opacidad: 0.35)

        // Estación meteorológica: mástil de celosía de 12 m con anemómetro y veleta, parcela de pasto cercada con abrigo
        // meteorológico (garita de persianas) y pluviómetro, y caseta con radomo geodésico.
        let M = marco()
        let pm = polE(38, 105), pc = polE(38, 113), gm = CGFloat(113) * .pi / 180
        celosia(M, pm.x, pm.z, alto: 12, base: 0.28, cima: 0.12, tramos: 6, acero, acero); navC(pm.x, pm.z, 0.45)
        caja(M, 1.8, 0.06, 0.06, acero, x: pm.x, y: 10, z: pm.z)
        for d: CGFloat in [-0.85, 0.85] { cil(M, 0.07, 0.25, blanco, x: pm.x + d, y: 10.15, z: pm.z) }
        caja(M, 4, 3, 3.6, blanco, x: pc.x, z: pc.z, giro: gm); navR(pc.x, pc.z, 2.1, 1.9, gm)
        cil(M, 0.7, 1.2, blanco, x: pc.x, y: 3.6, z: pc.z)
        let radomo = SCNSphere(radius: 1.5); radomo.isGeodesic = true; radomo.segmentCount = 10
        M.addChildNode(nodo(radomo, Mat.pbr(NSColor(calibratedWhite: 0.97, alpha: 1), rugosidad: 0.35), y: 5.4, x: pc.x, z: pc.z))
        let pg = polE(37.6, 98.5), parcela = SCNNode(); parcela.position = SCNVector3(pg.x, 0, pg.z); parcela.eulerAngles.y = CGFloat(98.5) * .pi / 180; M.addChildNode(parcela)
        caja(parcela, 3.4, 0.03, 2.8, pasto, y: 0.02)
        for (dx, dz) in [(CGFloat(-1.7), CGFloat(-1.4)), (1.7, -1.4), (1.7, 1.4), (-1.7, 1.4)] { cil(parcela, 0.04, 1.0, gris, x: dx, z: dz) }
        for (w, l, dx, dz) in [(CGFloat(3.4), CGFloat(0.03), CGFloat(0), CGFloat(-1.4)), (3.4, 0.03, 0, 1.4), (0.03, 2.8, -1.7, 0), (0.03, 2.8, 1.7, 0)] {
            for h: CGFloat in [0.45, 0.95] { caja(parcela, w, 0.03, l, gris, x: dx, y: h, z: dz) }
        }
        for (dx, dz) in [(CGFloat(-0.35), CGFloat(-0.3)), (0.35, -0.3), (0.35, 0.3), (-0.35, 0.3)] { cil(parcela, 0.035, 1.2, blanco, x: dx - 0.6, z: dz) }
        caja(parcela, 0.85, 0.7, 0.75, blanco, x: -0.6, y: 1.5)
        for k in 0..<5 { caja(parcela, 0.8, 0.02, 0.02, gris, x: -0.6, y: 1.25 + CGFloat(k) * 0.12, z: -0.39) }
        caja(parcela, 1.0, 0.06, 0.9, blanco, x: -0.6, y: 1.88)
        cil(parcela, 0.12, 0.45, acero, x: 0.9, y: 0.5, z: 0.5); cil(parcela, 0.03, 0.3, gris, x: 0.9, y: 0.15, z: 0.5)
        navC(pg.x, pg.z, 1.6)
        letrero(M, "ESTACIÓN METEOROLÓGICA", "#5dade2", ancho: 3.8, alto: 0.5, x: pc.x - sin(gm) * 1.83, y: 2.4, z: pc.z - cos(gm) * 1.83, giro: gm + .pi)
        fijar(M, "elem:ener-clima")
        let anemo = SCNNode(); let qa = Islas.ener(pm.x, pm.z); anemo.position = SCNVector3(qa.x, 12.1, qa.y)
        for k in 0..<3 { let b = nodo(SCNBox(width: 0.5, height: 0.03, length: 0.03, chamferRadius: 0), gris, x: 0.25); let h = SCNNode(); h.eulerAngles.y = CGFloat(k) * 2.094; h.addChildNode(b)
            let copa = nodo(SCNSphere(radius: 0.1), blanco, x: 0.5); copa.scale = SCNVector3(1, 1, 0.5); h.addChildNode(copa); anemo.addChildNode(h) }
        anemo.addChildNode(nodo(SCNCylinder(radius: 0.04, height: 0.3), gris, y: -0.15))
        anemo.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 1.2))); anemo.name = "elem:ener-clima"; escena.rootNode.addChildNode(anemo)
        let qv = Islas.ener(pm.x + 0.85, pm.z), veleta = SCNNode(); veleta.position = SCNVector3(qv.x, 10.5, qv.y); veleta.name = "elem:ener-clima"; veleta.eulerAngles.y = A + 0.6
        veleta.addChildNode(nodo(SCNBox(width: 0.03, height: 0.03, length: 1.0, chamferRadius: 0), gris))
        let aleta = nodo(SCNBox(width: 0.02, height: 0.25, length: 0.3, chamferRadius: 0), blanco, z: -0.45); veleta.addChildNode(aleta)
        veleta.runAction(.repeatForever(.sequence([.rotateBy(x: 0, y: 0.25, z: 0, duration: 2.5), .rotateBy(x: 0, y: -0.4, z: 0, duration: 3.5), .rotateBy(x: 0, y: 0.15, z: 0, duration: 2)])))
        escena.rootNode.addChildNode(veleta)

        // Observatorio astronómico: torre cilíndrica con pasarela perimetral y cúpula semiesférica con ranura de observación
        let O = marco()
        let po = polE(38, -12)
        cil(O, 3.2, 4, Mat.textura(.estuco, repetir: 2, tinte: "#eef0f2"), x: po.x, z: po.z); navC(po.x, po.z, 3.3)
        O.addChildNode(nodo(SCNTube(innerRadius: 3.2, outerRadius: 3.9, height: 0.12), gris, y: 3.0, x: po.x, z: po.z))
        for k in 0..<20 { let a = CGFloat(k) / 20 * 2 * .pi; cil(O, 0.03, 0.9, gris, x: po.x + cos(a) * 3.85, y: 3.5, z: po.z + sin(a) * 3.85) }
        O.addChildNode(nodo(SCNTube(innerRadius: 3.82, outerRadius: 3.88, height: 0.05), gris, y: 3.95, x: po.x, z: po.z))
        caja(O, 1.0, 2.1, 0.08, Mat.pbr(NSColor(Color(hex: "#4a3524"))), x: po.x - sin(-0.209) * 3.2, y: 1.05, z: po.z - cos(-0.209) * 3.2, giro: -0.209)
        letrero(O, "OBSERVATORIO", "#34495e", ancho: 3, alto: 0.5, x: po.x - sin(-0.209) * 3.25, y: 2.5, z: po.z - cos(-0.209) * 3.25, giro: -0.209 + .pi)
        fijar(O, "elem:ener-astro")
        let cup = SCNNode(); let qo = Islas.ener(po.x, po.z); cup.position = SCNVector3(qo.x, 4, qo.y); cup.name = "elem:ener-astro"
        cup.addChildNode(nodo(SCNSphere(radius: 3.2), Mat.pbr(NSColor(Color(hex: "#dfe6ec")), rugosidad: 0.25, metal: 0.6)))
        for k in 0..<9 {
            let t = 0.08 + CGFloat(k) * 0.18, s = nodo(SCNBox(width: 0.9, height: 0.62, length: 0.05, chamferRadius: 0), oscuro, y: sin(t) * 3.21, z: cos(t) * 3.21)
            s.eulerAngles.x = -t; cup.addChildNode(s)
        }
        cup.runAction(.repeatForever(.sequence([.rotateBy(x: 0, y: 1.2, z: 0, duration: 9), .wait(duration: 6), .rotateBy(x: 0, y: -0.7, z: 0, duration: 6), .wait(duration: 8)])))
        escena.rootNode.addChildNode(cup)

        // Terreno disponible para una nueva dependencia
        let L = marco()
        let pl = polE(38, -52), gl = CGFloat(-52) * .pi / 180
        caja(L, 17, 0.04, 5.6, grava, x: pl.x, y: 0.025, z: pl.z, giro: gl)
        for dx: CGFloat in [-8.4, 8.4] { for dz: CGFloat in [-2.7, 2.7] {
            cil(L, 0.07, 1.1, gris, x: pl.x + cos(gl) * dx + sin(gl) * dz, z: pl.z - sin(gl) * dx + cos(gl) * dz)
        } }
        letrero(L, "TERRENO DISPONIBLE · NUEVA INDUSTRIA", "#7f8c8d", ancho: 5.2, alto: 0.55, x: pl.x - sin(gl) * 2.8, y: 1.3, z: pl.z - cos(gl) * 2.8, giro: gl + .pi)
        fijar(L, "elem:ener-terreno")

        // Planta de agua potable: decantadores circulares con puente barredor giratorio, edificio de cloración con filtros
        // de arena abiertos y estanque elevado de pedestal.
        let W = marco()
        let aguaD = Mat.pbr(NSColor(Color(hex: "#4f8f8a")), rugosidad: 0.08, metal: 0.2)
        for g: CGFloat in [-86, -99] {
            let p = polE(38, g)
            cil(W, 2.4, 1.4, hormigonT, x: p.x, z: p.z)
            W.addChildNode(nodo(SCNCylinder(radius: 2.25, height: 0.06), aguaD, y: 1.37, x: p.x, z: p.z))
            W.addChildNode(nodo(SCNTube(innerRadius: 1.95, outerRadius: 2.05, height: 0.14), hormigon, y: 1.4, x: p.x, z: p.z))
            cil(W, 0.3, 1.75, hormigon, x: p.x, z: p.z)
            navC(p.x, p.z, 2.5)
            let q = Islas.ener(p.x, p.z), puente = SCNNode(); puente.position = SCNVector3(q.x, 1.6, q.y); puente.name = "elem:ener-agua"
            puente.addChildNode(nodo(SCNBox(width: 2.35, height: 0.1, length: 0.5, chamferRadius: 0), acero, x: 1.17))
            for d: CGFloat in [-0.24, 0.24] { puente.addChildNode(nodo(SCNBox(width: 2.35, height: 0.03, length: 0.03, chamferRadius: 0), amarillo, y: 0.45, x: 1.17, z: d)) }
            puente.addChildNode(nodo(SCNBox(width: 0.3, height: 0.35, length: 0.6, chamferRadius: 0.03), gris, y: 0.2, x: 2.35))
            puente.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: g == -86 ? 50 : 64)))
            escena.rootNode.addChildNode(puente)
        }
        let pf = polE(38, -112), gf = CGFloat(-112) * .pi / 180
        let wf = SCNNode(); wf.position = SCNVector3(pf.x, 0, pf.z); wf.eulerAngles.y = gf; W.addChildNode(wf)
        caja(wf, 3, 3, 3.8, Mat.textura(.estuco, repetir: 2, tinte: "#d6eaf8"), x: -1); caja(wf, 3.2, 0.2, 4, gris, x: -1, y: 3.05)
        caja(wf, 2.4, 0.8, 0.06, ventana(), x: -1, y: 1.7, z: 1.92)
        caja(wf, 2, 1.1, 3.8, hormigonT, x: 1.5)
        for dz: CGFloat in [-0.95, 0.95] { caja(wf, 1.7, 0.05, 1.7, aguaD, x: 1.5, y: 1.08, z: dz) }
        caja(wf, 1.8, 0.12, 0.15, hormigon, x: 1.5, y: 1.12)
        letrero(wf, "AGUA POTABLE", "#1f6fb2", ancho: 2.8, alto: 0.5, x: -1, y: 2.4, z: -1.93, giro: .pi)
        navR(pf.x, pf.z, 2.6, 2.0, gf)
        let pt = polE(38, -124)
        W.addChildNode(nodo(SCNCone(topRadius: 0.7, bottomRadius: 1.2, height: 1.2), hormigonT, y: 0.6, x: pt.x, z: pt.z))
        cil(W, 0.7, 6.4, hormigonT, x: pt.x, y: 4.4, z: pt.z)
        W.addChildNode(nodo(SCNCone(topRadius: 2.0, bottomRadius: 0.7, height: 1.4), Mat.pbr(NSColor(Color(hex: "#5dade2")), rugosidad: 0.4, metal: 0.3), y: 8.3, x: pt.x, z: pt.z))
        let tanque = nodo(SCNSphere(radius: 2.1), Mat.pbr(NSColor(Color(hex: "#5dade2")), rugosidad: 0.4, metal: 0.3), y: 9.4, x: pt.x, z: pt.z); tanque.scale = SCNVector3(1, 0.75, 1); W.addChildNode(tanque)
        navC(pt.x, pt.z, 1.4)
        fijar(W, "elem:ener-agua")

        // Proveedora de Red: edificio corporativo de vidrio con equipos de climatización del centro de datos en la azotea,
        // torre de telecomunicaciones de celosía con balizaje rojo y blanco y antenas de microondas, y estación terrena satelital.
        let I = marco()
        let pi2 = polE(38, -145), gi = CGFloat(-145) * .pi / 180
        let ib = SCNNode(); ib.position = SCNVector3(pi2.x, 0, pi2.z); ib.eulerAngles.y = gi; I.addChildNode(ib)
        caja(ib, 5.5, 11, 4.6, vidrio); caja(ib, 5.7, 0.4, 4.8, gris, y: 11.2)
        for k in 1..<6 { caja(ib, 5.56, 0.08, 4.66, gris, y: CGFloat(k) * 1.85) }                    // losas entre pisos
        for (dx, dz) in [(CGFloat(-1.6), CGFloat(-1.2)), (0, -1.2), (1.6, -1.2), (-1.6, 1.0), (0, 1.0)] {
            caja(ib, 1.3, 0.7, 1.6, blanco, x: dx, y: 11.75, z: dz)
            ib.addChildNode(nodo(SCNCylinder(radius: 0.45, height: 0.06), oscuro, y: 12.12, x: dx, z: dz))
        }
        letrero(ib, "PROVEEDORA DE RED · INTERNET", "#e67e22", ancho: 5, alto: 0.55, y: 9.8, z: -2.33, giro: .pi)
        navR(pi2.x, pi2.z, 2.8, 2.4, gi)
        let pa = polE(38, -160)
        celosia(I, pa.x, pa.z, alto: 22, base: 0.75, cima: 0.25, tramos: 8, rojo, blanco); navC(pa.x, pa.z, 0.8)
        for (h, a) in [(CGFloat(13), CGFloat(0.4)), (16, 2.5), (11, 4.4), (19, 1.4)] {
            let w = 0.25 + 0.55 * (1 - h / 22)
            let d = nodo(SCNCylinder(radius: 0.55, height: 0.35), blanco, y: h, x: pa.x + cos(a) * (w + 0.2), z: pa.z + sin(a) * (w + 0.2)); d.eulerAngles.z = .pi / 2; d.eulerAngles.y = -a; I.addChildNode(d)
        }
        cil(I, 0.05, 2.5, acero, x: pa.x, y: 23.2, z: pa.z)
        let pd = polE(41.4, -153), sat = SCNNode(); sat.position = SCNVector3(pd.x, 0, pd.z); sat.eulerAngles.y = gi; I.addChildNode(sat)
        cil(sat, 0.35, 1.6, gris)
        let parab: [(r: CGFloat, y: CGFloat)] = (0...10).map { k in let r = CGFloat(k) * 0.16; return (r, r * r / 3.2) }
        let mD = Mat.pbr(NSColor(calibratedWhite: 0.94, alpha: 1), rugosidad: 0.4); mD.isDoubleSided = true
        let plato = nodo(torno(parab, lados: 28), mD, y: 1.9); plato.eulerAngles.x = -0.75; sat.addChildNode(plato)
        navC(pd.x, pd.z, 1.0)
        fijar(I, "elem:ener-isp")
        let baliza = nodo(SCNSphere(radius: 0.3), Mat.emisivo(.systemRed, fuerza: 2)); let qb = Islas.ener(pa.x, pa.z); baliza.position = SCNVector3(qb.x, 24.6, qb.y)
        baliza.runAction(.repeatForever(.sequence([.fadeOpacity(to: 0.15, duration: 0.7), .fadeOpacity(to: 1, duration: 0.7)]))); escena.rootNode.addChildNode(baliza)

        // Parque eólico mar adentro (red): fundación con pieza de transición amarilla, torre cónica, góndola y palas aguzadas
        for g: CGFloat in [-60, -25, 10, 45, 80] {
            let p = polE(60, g), q = Islas.ener(p.x, p.z)
            let t = SCNNode(); t.position = SCNVector3(q.x, -0.5, q.y); t.eulerAngles.y = A + g * .pi / 180; t.name = "elem:ener-eolica"
            t.addChildNode(nodo(SCNCylinder(radius: 0.75, height: 1.6), gris, y: 0.8))
            t.addChildNode(nodo(SCNCylinder(radius: 0.7, height: 2.6), amarillo, y: 2.9))
            t.addChildNode(nodo(SCNTube(innerRadius: 0.7, outerRadius: 1.6, height: 0.12), gris, y: 4.2))
            t.addChildNode(nodo(SCNCone(topRadius: 0.3, bottomRadius: 0.62, height: 19), blanco, y: 13.7))
            t.addChildNode(nodo(SCNBox(width: 1.1, height: 1.1, length: 3.2, chamferRadius: 0.35), blanco, y: 23.6, z: -0.5))
            let rotor = SCNNode(); rotor.position = SCNVector3(0, 23.6, 1.25)
            let buje = nodo(SCNCone(topRadius: 0.05, bottomRadius: 0.48, height: 0.9), blanco); buje.eulerAngles.x = .pi / 2; rotor.addChildNode(buje)
            for k in 0..<3 {
                let h = SCNNode(); h.eulerAngles.z = CGFloat(k) * 2.094
                let pala = nodo(SCNCone(topRadius: 0.04, bottomRadius: 0.38, height: 10), blanco, y: 5.3); pala.scale = SCNVector3(1, 1, 0.28); pala.eulerAngles.y = 0.25
                h.addChildNode(pala); rotor.addChildNode(h)
            }
            rotor.runAction(.repeatForever(.rotateBy(x: 0, y: 0, z: -.pi * 2, duration: 5 + Double(abs(g)) / 40)))
            t.addChildNode(rotor); escena.rootNode.addChildNode(t)
        }

        // Vehículos de servicio: bus, cisterna de agua y camión recolector van y vuelven de la villa;
        // camioneta eléctrica, técnicos de red y meteorología recorren la circunvalación de la isla.
        let faro = Mat.emisivo(NSColor(calibratedRed: 1, green: 0.97, blue: 0.85, alpha: 1)); focos.append(faro)
        let fr = Mat.emisivo(.systemRed, fuerza: 0.8)
        func e(_ x: CGFloat, _ z: CGFloat) -> CGPoint { Islas.ener(x, z) }
        var exterior: [CGPoint] = []           // carril exterior (r 31,5): entra por la derecha, da la vuelta y sale por la izquierda
        for k in 0...48 { let t = 0.06 + CGFloat(k) / 48 * (2 * .pi - 0.12); exterior.append(e(sin(t) * 31.5, -cos(t) * 31.5)) }
        let enIsla = [e(1.7, -44), e(1.7, -34)] + exterior + [e(-1.7, -34), e(-1.7, -44)]
        let ruta = rutaBus(ang: A, enIsla: enIsla)
        let bus0 = Vehiculo(bus(NSColor(Color(hex: "#c27c0e")), "ISLA DE ENERGÍA", faro: faro, freno: fr), ruta: ruta, s: 0, velocidad: 8,
                            paradas: [(largoRuta(ruta, hasta: 9), 10)], largo: 8.2, ancho: 2.4, paciente: true)
        bus0.raiz.scale = SCNVector3(1, 1, 1)
        let total = largoRuta(ruta, hasta: ruta.count)
        let cisterna = camionServicio("agua", "#1f6fb2", nombre: "elem:ener-agua", faro: faro, freno: fr)
        let basura = camionServicio("residuos", "#2e7d32", nombre: "elem:ener-residuos", faro: faro, freno: fr)
        for (k, v) in [bus0, Vehiculo(cisterna, ruta: ruta, s: total * 0.36, velocidad: 7, largo: 6.6, ancho: 2.4, paciente: true),
                       Vehiculo(basura, ruta: ruta, s: total * 0.68, velocidad: 7, largo: 6.6, ancho: 2.4, paciente: true)].enumerated() {
            Islas.buses.append(v); escena.rootNode.addChildNode(v.raiz)
            if k == 2 { soloDeDia.append(v.raiz) }
        }
        var interior: [CGPoint] = []           // carril interior (r 28,5), sentido contrario, en circuito cerrado
        for k in 0..<36 { let t = -CGFloat(k) / 36 * 2 * .pi; interior.append(e(sin(t) * 28.5, -cos(t) * 28.5)) }
        let largoInt = 2 * .pi * 28.5
        let electrica = camionServicio("nuclear", "#d4ac0d", nombre: "elem:ener-nuclear", faro: faro, freno: fr)
        let red = camionServicio("isp", "#e67e22", nombre: "elem:ener-isp", faro: faro, freno: fr)
        let meteo = camionServicio("clima", "#2e86c1", nombre: "elem:ener-clima", faro: faro, freno: fr)
        for (k, c) in [electrica, red, meteo].enumerated() {
            let v = Vehiculo(c, ruta: interior, s: largoInt * CGFloat(k) / 3, velocidad: 5.5, largo: 6.6, ancho: 2.4, paciente: true)
            Islas.buses.append(v); escena.rootNode.addChildNode(v.raiz)
        }
        pulsoRadio(en: Islas.ener(pa.x, pa.z), altura: 20)
    }
}
