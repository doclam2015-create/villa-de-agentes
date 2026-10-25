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
        static let radioAla: [String: CGFloat] = ["urg": 11.4, "cer": 6.7, "ios": 7.5, "mac": 8.2, "nube": 7.2, "puerto": 5.6, "mall": 5.0]
        static let corteNube: CGFloat = 0.13          // medio ángulo del corte de la circunvalación bajo la escalera de La nube
        static let cuartelAng: CGFloat = -0.785      // entre Urgencias y la Bodega del Mac, mirando al palacio
        private var carabinero: Persona?
        private var barrera = SCNNode(), aberturaBarrera: CGFloat = 0
        private var guardiaRonda: Persona?
        private var helicoptero = SCNNode(), aviones: [SCNNode] = [], intruso = SCNNode()
        nonisolated static let acceso: CGFloat = 0.645      // rumbo de la avenida de acceso y el puente (entre Bodega del Mac y Taller iOS)
        private var focos: [SCNMaterial] = []
        private var estrellas = SCNNode()           // cielo estrellado nítido (sigue a la cámara)
        private var puerto: PuertoYFlota?          // puerto de proveedores y grupo del portaaviones
        private var sol = SCNNode(), ambiente = SCNNode()
        private var ultimoCielo = -1
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
            let cu = centroCuartel
            let enCuartel: (CGPoint) -> Bool = { hypot($0.x - cu.x, $0.y - cu.y) < 6.2 }
            for d in [nil, "sede"] + Coordinador.posiciones.keys.filter({ !Islas.zonas.contains($0) }).sorted() {
                revisar("carro bomba → \(d ?? "cuartel")", rutaBomberos(d), 4.5, 1.7, cerrada: false, ignorar: enCuartel)
            }
            let c = Coordinador.posiciones["urg"]!, hy = atan2(-c.x, -c.y)
            for (k, a) in ambHosp.enumerated() {
                let ruta = a.ruta.map { CGPoint(x: c.x + $0.x * cos(hy) + $0.y * sin(hy), y: c.y - $0.x * sin(hy) + $0.y * cos(hy)) }
                revisar("ambulancia \(k + 1) del hospital", ruta, 3.6, 1.45, cerrada: false)
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
            playaNatural(centro: .zero, desde: 79)                         // playa en pendiente hasta el agua (sin escalón), con espuma
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
                if !nav.libre(p) || !PuertoYFlota.libre(p) || !Mall.libre(p) || !Islas.libre(p) { continue }
                let alto = 3 + gen.real() * 3, especie = gen.real(), m = verdes[Int(gen.real() * 4.99)]
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
                for g in rumbos where abs(p.x * cos(g) - p.y * sin(g)) < 4 && p.x * sin(g) + p.y * cos(g) > 0 { enCalle = true }
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
                if !PuertoYFlota.libre(CGPoint(x: x0, y: z0)) || !Mall.libre(CGPoint(x: x0, y: z0)) || !Islas.libre(CGPoint(x: x0, y: z0)) { continue }        // el puerto ocupa esa playa
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
                    let piso = nodo(SCNBox(width: 6.4, height: 0.06, length: 9.4, chamferRadius: 0), asfalto, y: 0.05, x: c.x, z: c.y); piso.eulerAngles.y = yaw
                    r.addChildNode(piso)
                    // Calces en batería: discapacidad (azul, con pasillo achurado), adulto mayor, embarazada y uno normal
                    let fila = SCNNode(), q0 = local(0.8, -4.6)
                    fila.position = SCNVector3(q0.x, 0, q0.y); fila.eulerAngles.y = yaw - .pi / 2
                    filaCalces(fila, [.discapacidad, .adultoMayor, .embarazada, .normal], largo: 3.6, linea: blanco, amarillo: blanco, anchos: [3.0, 2.1, 2.1, 2.0])
                    r.addChildNode(fila)
                    let cartel = SCNMaterial(); cartel.diffuse.contents = Pizarra.letrero("VISITAS"); cartel.emission.contents = Pizarra.letrero("VISITAS"); cartel.emission.intensity = 0.4
                    let qc = local(2.9, 4.4)
                    let cart = nodo(SCNBox(width: 1.6, height: 0.4, length: 0.05, chamferRadius: 0), cartel, y: 1.5, x: qc.x, z: qc.y); cart.eulerAngles.y = yaw
                    r.addChildNode(cart); r.addChildNode(nodo(SCNCylinder(radius: 0.05, height: 1.3), hierro, y: 0.65, x: qc.x, z: qc.y))
                    nav.rect(c.x, c.y, 3.2, 4.7, yaw)
                    sendero(pl.ang, hasta: hypot(c.x, c.y) - 4.6, ancho: 3, m: asfalto)
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
            for (lz, col) in [(CGFloat(-0.55), NSColor(calibratedWhite: 0.85, alpha: 1)), (3.6, NSColor(Color(hex: "#7a2f2f")))] {
                let lx: CGFloat = -1.0
                let a = auto(col, suv: lz < 0, faro: faro, freno: freno)
                a.scale = SCNVector3(0.72, 0.72, 0.72)
                a.position = SCNVector3(c.x + lx * cos(yaw) + lz * sin(yaw), 0.08, c.y - lx * sin(yaw) + lz * cos(yaw))
                a.eulerAngles.y = yaw + .pi / 2
                escena.rootNode.addChildNode(a)
            }
        }

        private func montarAmbulancia(_ r: SCNNode) {
            // Estacionamiento dedicado detrás del hospital; si hay un agente en atención, salen a la entrada de Urgencias.
            let c = Coordinador.posiciones["urg"]!, hy = atan2(-c.x, -c.y)
            let lote = SCNNode(); lote.position = SCNVector3(c.x, 0, c.y); lote.eulerAngles.y = hy
            lote.addChildNode(nodo(SCNBox(width: 7.6, height: 0.05, length: 3.6, chamferRadius: 0), Mat.pbr(NSColor(calibratedWhite: 0.2, alpha: 1), rugosidad: 0.85), y: 0.15, z: -6.3))
            for x: CGFloat in [-2.8, 0, 2.8] {
                lote.addChildNode(nodo(SCNBox(width: 0.08, height: 0.06, length: 3.0, chamferRadius: 0), Mat.pbr(.white), y: 0.16, x: x, z: -6.3))
            }
            let cartel = SCNMaterial(); cartel.diffuse.contents = Pizarra.letrero("AMBULANCIAS"); cartel.emission.contents = Pizarra.letrero("AMBULANCIAS"); cartel.emission.intensity = 0.4
            // Cartel de doble cara en la esquina del estacionamiento, en ángulo hacia el hospital: legible desde ambos lados
            // y fuera de la vista frontal de las oficinas del ala (antes quedaba detrás de las ambulancias, tapado por el ala).
            let sx: CGFloat = 4.2, sz: CGFloat = -7.9, giro = atan2(-sx, -sz)
            let letrero = SCNNode(); letrero.position = SCNVector3(sx, 0, sz); letrero.eulerAngles.y = giro
            let metal = Mat.pbr(.gray, metal: 0.8)
            letrero.addChildNode(nodo(SCNBox(width: 3.3, height: 0.6, length: 0.05, chamferRadius: 0.02), metal, y: 2.0))
            for (z, g): (CGFloat, CGFloat) in [(0.03, 0), (-0.03, .pi)] {
                let cara = nodo(SCNPlane(width: 3.2, height: 0.52), cartel, y: 2.0, z: z); cara.eulerAngles.y = g
                letrero.addChildNode(cara)
            }
            for x: CGFloat in [-1.45, 1.45] {
                letrero.addChildNode(nodo(SCNCylinder(radius: 0.05, height: 1.75), metal, y: 0.875, x: x))
                let lx = sx + x * cos(giro), lz = sz - x * sin(giro)
                let q = CGPoint(x: c.x + lx * cos(hy) + lz * sin(hy), y: c.y - lx * sin(hy) + lz * cos(hy)); nav.circulo(q.x, q.y, 0.08)
            }
            lote.addChildNode(letrero)
            Coordinador.hornear(lote)
            escena.rootNode.addChildNode(lote.flattenedClone())
            for o: CGFloat in [-1.4, 1.4] {
                // Física: una por cada costado (antes iban paralelas a 1,2 m y se superponían) y se detienen junto al ala
                // de Urgencias, fuera de los pilares de la marquesina (antes los cruzaban en diagonal).
                let lado: CGFloat = o < 0 ? -1 : 1
                let ruta = [CGPoint(x: o, y: -6.3), CGPoint(x: lado * 5.0, y: -4.6), CGPoint(x: lado * 5.0, y: 4.4)]
                let amb = ambulancia(); amb.name = "elem:ambulancia"; amb.scale = SCNVector3(0.72, 0.72, 0.72)
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
            let W: CGFloat = 10.6, D: CGFloat = 8, H: CGFloat = 4.4, t: CGFloat = 0.25
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
            let rescate = carroBomba(rescate: true); rescate.name = "elem:bomberos"; rescate.scale = SCNVector3(0.72, 0.72, 0.72)
            let pr = mundoC(2.6, 0.6); rescate.position = SCNVector3(pr.x, 0.1, pr.y); rescate.eulerAngles.y = yaw
            nav.rect(pr.x, pr.y, 0.9, 2.3, yaw)
            escena.rootNode.addChildNode(rescate)
            bomba = carroBomba(rescate: false); bomba.name = "elem:bomberos"; bomba.scale = SCNVector3(0.72, 0.72, 0.72)
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
            var pts = [polar(34.6, a0), polar(21, a0)]
            guard let d = destino else { return pts }
            if d == "sede" { pts.append(polar(15.3, a0)); return pts }
            if d == "mall" {        // por la avenida del puerto y el anillo periférico hasta la entrada del mall
                let ap = PuertoYFlota.ang
                for k in 1...4 { pts.append(polar(21, a0 + (ap - a0) * CGFloat(k) / 4)) }
                var r: CGFloat = 25
                while r < 61 { pts.append(polar(r, ap)); r += 6 }
                var t = ap
                while t < Mall.ang { pts.append(polar(61, t)); t += 0.06 }
                pts += [polar(61, Mall.ang), polar(62.0, Mall.ang)]
                return pts
            }
            guard let c = Coordinador.posiciones[d], let rad = Coordinador.radios[d] else { return pts }
            let at = atan2(c.x, c.y)
            var delta = at - a0
            while delta > .pi { delta -= 2 * .pi }; while delta < -.pi { delta += 2 * .pi }
            if d == "nube" { delta -= (delta > 0 ? 1 : -1) * (Coordinador.corteNube + 0.1) }   // no sube ni atraviesa la escalera
            let pasos = max(1, Int(abs(delta) / 0.12))
            for k in 1...pasos { pts.append(polar(21, a0 + delta * CGFloat(k) / CGFloat(pasos))) }
            if d != "nube" { pts.append(polar(hypot(c.x, c.y) - rad + 0.5, at)) }
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
            let plano = n.flattenedClone()
            if escolta {   // balizas azul y roja que destellan
                for (x, col) in [(-0.35, NSColor.systemBlue), (0.35, NSColor.systemRed)] as [(CGFloat, NSColor)] {
                    let b = nodo(SCNBox(width: 0.4, height: 0.12, length: 0.25, chamferRadius: 0.04), Mat.emisivo(col, fuerza: 2), y: 0.97 + alto, x: x, z: -0.3)
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
            let caravana = recta(16, 58, lado: -1.7) + anillo(59, desde: a - 0.05, sube: false) + recta(58, 16, lado: 1.7)
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
                v.raiz.scale = SCNVector3(0.72, 0.72, 0.72)       // a escala con edificios y personas
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
            let cuerpo = h.flattenedClone()
            let rotor = SCNNode(); rotor.position = SCNVector3(0, 1.3, 0)
            for g: CGFloat in [0, .pi / 2] { let p = nodo(SCNBox(width: 11, height: 0.05, length: 0.35, chamferRadius: 0), negro); p.eulerAngles.y = g; rotor.addChildNode(p) }
            rotor.runAction(.repeatForever(.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: 0.22)))
            let rotorCola = SCNNode(); rotorCola.position = SCNVector3(0.2, 0.8, -5.9)
            rotorCola.addChildNode(nodo(SCNBox(width: 0.05, height: 1.6, length: 0.18, chamferRadius: 0), negro))
            rotorCola.runAction(.repeatForever(.rotateBy(x: 2 * .pi, y: 0, z: 0, duration: 0.15)))
            let baliza = nodo(SCNSphere(radius: 0.16), Mat.emisivo(.systemRed, fuerza: 2), y: -0.95, z: -0.5)
            baliza.runAction(.repeatForever(.sequence([.fadeOpacity(to: 0.1, duration: 0.5), .fadeOpacity(to: 1, duration: 0.1)])))
            cuerpo.addChildNode(rotor); cuerpo.addChildNode(rotorCola); cuerpo.addChildNode(baliza)
            cuerpo.addChildNode(etiqueta("Defensa aérea", y: 2.4, grande: false, icono: "shield.lefthalf.filled", color: NSColor(Color(hex: "#3b4a2f"))))
            helicoptero = cuerpo; helicoptero.name = "elem:helicoptero"
            escena.rootNode.addChildNode(helicoptero)
            // Dos cazas en formación
            let gris = Mat.pbr(NSColor(Color(hex: "#7d8791")), rugosidad: 0.35, metal: 0.6)
            func triangulo(_ pts: [NSPoint], _ grosor: CGFloat) -> SCNShape {
                let b = NSBezierPath(); b.move(to: pts[0]); for p in pts.dropFirst() { b.line(to: p) }; b.close()
                return SCNShape(path: b, extrusionDepth: grosor)
            }
            for _ in 0..<2 {
                let j = SCNNode()
                let fus = nodo(SCNCylinder(radius: 0.55, height: 8), gris); fus.eulerAngles.x = .pi / 2; j.addChildNode(fus)
                let nariz = nodo(SCNCone(topRadius: 0, bottomRadius: 0.55, height: 2.4), gris, z: 5.2); nariz.eulerAngles.x = .pi / 2; j.addChildNode(nariz)
                let cab = nodo(SCNSphere(radius: 0.45), vidrio, y: 0.45, z: 2.2); cab.scale = SCNVector3(1, 0.8, 2.2); j.addChildNode(cab)
                let ala = nodo(triangulo([NSPoint(x: -5, y: -2), NSPoint(x: 5, y: -2), NSPoint(x: 0, y: 3)], 0.15), gris, z: -0.6); ala.eulerAngles.x = .pi / 2; j.addChildNode(ala)
                let tim = nodo(triangulo([NSPoint(x: -2.2, y: -0.8), NSPoint(x: 2.2, y: -0.8), NSPoint(x: 0, y: 1)], 0.1), gris, z: -3.6); tim.eulerAngles.x = .pi / 2; j.addChildNode(tim)
                let der = nodo(triangulo([NSPoint(x: 0, y: 0), NSPoint(x: 2.2, y: 0), NSPoint(x: 2.2, y: 2)], 0.12), gris, y: 0.4, z: -2.0); der.eulerAngles.y = .pi / 2; j.addChildNode(der)
                j.addChildNode(nodo(SCNCylinder(radius: 0.42, height: 0.3), Mat.emisivo(.systemOrange, fuerza: 2.5), z: -4.1))
                j.childNodes.last?.eulerAngles.x = .pi / 2
                let plano = j.flattenedClone()
                plano.name = "elem:cazas"
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
        }

        /// Ronda del helicóptero y pasadas de los cazas. Si el Vigilante de seguridad está en alerta,
        /// aparece el intruso y los cazas lo interceptan en círculo cerrado.
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
                let ti = t * 2 * .pi / 90
                let pi = SCNVector3(sin(ti) * 66, 28, cos(ti) * 66)
                intruso.position = pi
                for (i, av) in aviones.enumerated() {
                    let f = t * 2 * .pi / 6 + CGFloat(i) * .pi
                    av.position = SCNVector3(pi.x + sin(f) * 14, pi.y + 1.5, pi.z + cos(f) * 14)
                    av.eulerAngles = SCNVector3(0, f + .pi / 2, -0.7)
                }
            } else {
                let ciclo: CGFloat = 28, k = floor(t / ciclo), u = t.truncatingRemainder(dividingBy: ciclo)
                let dir = k * 2.17, fx = sin(dir), fz = cos(dir)
                let desvio = (k.truncatingRemainder(dividingBy: 3) - 1) * 18
                for (i, av) in aviones.enumerated() {
                    let largo = u * 55 - 330 - CGFloat(i) * 7, lado = desvio + CGFloat(i) * 6
                    av.position = SCNVector3(fx * largo + fz * lado, 42, fz * largo - fx * lado)
                    av.eulerAngles = SCNVector3(0, dir, 0)
                }
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
                    if zid != "mall" && zid != "aeropuerto" {   // el mall tiene su propio piso de mármol (encimados parpadeaban)
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
                kind == "dome" ? (2.4, 5.6, piso + 1.85, 2.0, 1.24) : (3.1, 4.9, 1.85, 2.0, 1.24)
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
                h.addChildNode(nodo(SCNBox(width: 7, height: 7.2, length: 5.5, chamferRadius: 0.05), muro, y: 3.9))
                for y: CGFloat in [2.75, 5.15, 7.55] { h.addChildNode(nodo(SCNBox(width: 7.12, height: 0.22, length: 5.62, chamferRadius: 0), blanco, y: y)) }
                h.addChildNode(nodo(SCNBox(width: 7.2, height: 0.5, length: 5.7, chamferRadius: 0), blanco, y: 7.75))
                func vent(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat, _ g: CGFloat) {
                    let w = SCNNode(); w.position = SCNVector3(x, y, z); w.eulerAngles.y = g
                    w.addChildNode(nodo(SCNBox(width: 1.05, height: 1.25, length: 0.05, chamferRadius: 0), blanco))
                    w.addChildNode(nodo(SCNPlane(width: 0.85, height: 1.05), v, z: 0.03))
                    h.addChildNode(w)
                }
                for y: CGFloat in [1.6, 4.0, 6.4] {
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
                for (w, hh) in [(CGFloat(1.6), CGFloat(0.5)), (0.5, 1.6)] { h.addChildNode(nodo(SCNBox(width: w, height: hh, length: 0.1, chamferRadius: 0), rojo, y: 6.4, z: 2.82)) }
                h.addChildNode(nodo(SCNCylinder(radius: 2.1, height: 0.12), gris, y: 8.06))
                let hm = Mat.pbr(.white, rugosidad: 0.4)
                for x: CGFloat in [-0.55, 0.55] { h.addChildNode(nodo(SCNBox(width: 0.22, height: 0.02, length: 1.5, chamferRadius: 0), hm, y: 8.13, x: x)) }
                h.addChildNode(nodo(SCNBox(width: 1.1, height: 0.02, length: 0.22, chamferRadius: 0), hm, y: 8.13))
                let m0 = mundo(0, 0); nav.rect(m0.x, m0.y, 3.7, 2.95, yaw)
                let m1 = mundo(0, 3.85); nav.rect(m1.x, m1.y, 2.2, 1.1, yaw)
                for x: CGFloat in [-2.5, 2.5] { let mp = mundo(x, 6.7); nav.circulo(mp.x, mp.y, 0.15) }
            case "library":
                let yawL = atan2(-c.x, -c.y)
                let g = SCNNode(); g.eulerAngles.y = yawL; n.addChildNode(g)
                let vidrio = Mat.pbr(NSColor(Color(hex: "#9fd8ff")), rugosidad: 0.05, metal: 0.2); vidrio.transparency = 0.5
                g.addChildNode(nodo(SCNBox(width: 7, height: 7, length: 5.5, chamferRadius: 0.1), vidrio, y: 3.6))
                let marco = Mat.pbr(NSColor(calibratedWhite: 0.85, alpha: 1), metal: 0.7)
                for x in stride(from: -3.5, through: 3.5, by: 1.75) { g.addChildNode(nodo(SCNBox(width: 0.12, height: 7, length: 5.6, chamferRadius: 0), marco, y: 3.6, x: x)) }
                // Losas de piso (tres pisos), puerta doble de vidrio con marco y alero, y escalones
                for y: CGFloat in [0.15, 2.45, 4.75, 7.05] { g.addChildNode(nodo(SCNBox(width: 7.1, height: 0.18, length: 5.6, chamferRadius: 0), marco, y: y)) }
                let oscuro = Mat.pbr(NSColor(calibratedWhite: 0.18, alpha: 1), rugosidad: 0.3, metal: 0.7)
                g.addChildNode(nodo(SCNBox(width: 2.4, height: 2.3, length: 0.1, chamferRadius: 0), oscuro, y: 1.3, z: 2.8))
                for x: CGFloat in [-0.56, 0.56] {
                    let hoja = Mat.pbr(NSColor(Color(hex: "#bfe6ff")), rugosidad: 0.05, metal: 0.2); hoja.transparency = 0.45
                    g.addChildNode(nodo(SCNBox(width: 1.04, height: 2.1, length: 0.04, chamferRadius: 0), hoja, y: 1.25, x: x, z: 2.86))
                    g.addChildNode(nodo(SCNBox(width: 0.04, height: 0.5, length: 0.06, chamferRadius: 0.02), Mat.pbr(.white, metal: 0.9), y: 1.2, x: x * 0.15, z: 2.9))
                }
                g.addChildNode(nodo(SCNBox(width: 3.4, height: 0.15, length: 1.4, chamferRadius: 0.02), marco, y: 2.65, z: 3.4))
                g.addChildNode(nodo(SCNBox(width: 3.0, height: 0.15, length: 0.9, chamferRadius: 0), Mat.textura(.marmol, repetir: 1), y: 0.2, z: 3.2))
                let cerebro = nodo(SCNSphere(radius: 1.5), Mat.pbr(NSColor(Color(hex: "#f19ab8")), rugosidad: 0.5), y: 8.8, x: c.x, z: c.y)
                cerebro.scale = SCNVector3(1.25, 0.9, 1)
                cerebro.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 14)))
                escena.rootNode.addChildNode(cerebro)   // gira: queda fuera del bloque estático
                nav.rect(c.x, c.y, 3.5, 2.75, yawL)
            case "port":
                PuertoYFlota.capitania(n, c: c, muro: muro, techo: NSColor(Color(hex: z.roof)), nav: nav)
            case "trade", "bank", "casino", "museum", "university", "science", "airport":
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
                        let pos = Mall.marco(71.6, 0, (CGFloat(i) - (n - 1) / 2) * 4.0, 0)
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
            puerto?.mover(CGFloat(dt), ahora: ahora, alerta: !incidentes.isEmpty, agentes: almacen.agentes)
            moverAgentesNube(ahora)
            actualizarPantallasMall(ahora)
            moverPuertasMall(CGFloat(dt))
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
        func volar(_ p: SCNVector3, distancia d: CGFloat, inclinacion i: CGFloat? = nil, giro g: CGFloat? = nil) {
            metaObjetivo = p; metaDistancia = d
            if let i { metaInclinacion = i }
            if let g {
                var dd = g - metaGiro
                while dd > .pi { dd -= 2 * .pi }; while dd < -.pi { dd += 2 * .pi }
                metaGiro += dd
            }
            suavidad = 3.2
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
            if Islas.zonas.contains(zid) {  // barrios de la isla distrito: edificios altos, se ven de más lejos
                volar(SCNVector3(c.x, 0, c.y), distancia: max(r * 3.2, 40), inclinacion: 0.55, giro: atan2(c.x, c.y)); return
            }
            if zid == "puerto" {          // el puerto se ve entero: capitanía, muelles, barcos y faro, mirando al mar
                let m = PuertoYFlota.w(0, 88)
                volar(SCNVector3(m.x, 0, m.y), distancia: 72, inclinacion: 0.72, giro: PuertoYFlota.ang + .pi); return
            }
            volar(SCNVector3(c.x, zid == "nube" ? Nube.alto : 0, c.y), distancia: r * 2.6, inclinacion: 0.78)
        }

        func enfocarSede() { techos(nil); atenuarEmblema(de: nil); volar(SCNVector3(2.5, 3.0, 4.0), distancia: 27, inclinacion: 0.36, giro: 0.3) }

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
        static let volables = ["garita", "ambulancia", "puerto", "flota", "avion", "bus", "caleta", "balneario", "marina", "letrero"]

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
                    else if e.hasPrefix("museo-") { irBarrio("museo") }
                    else if Coordinador.volables.contains(where: { e.hasPrefix($0) }) { enfocarElemento(x) }
                    return
                }
                n = x.parent
            }
            guard let g = hits.first?.worldCoordinates ?? suelo(punto) else { return }
            // Barcos (se mueven): basta un clic cerca
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
        let W: CGFloat = 3.6, D: CGFloat = 3.4, H: CGFloat = 2.4, t: CGFloat = 0.12, puertaW: CGFloat = 1.25
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
         reversa: Set<Int> = [], largo: CGFloat = 3.1, ancho: CGFloat = 1.3, paciente: Bool = false) {
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
        raiz.position = SCNVector3(pos.x, enAcceso && r > 84 ? 0.47 : enAcceso && r > 76 ? 0.075 + (r - 76) / 8 * 0.395 : r < 14.5 ? 0.12 : 0.075, pos.y); raiz.eulerAngles.y = rumbo
    }
}


// MARK: - Centro comercial (mall) curvo, con atrio de vidrio, tiendas, estacionamientos señalizados, zona de proveedores
// con bodega de descarga y camiones repartidores

/// Geometría del mall: un arco concéntrico con el anillo periférico (no queda al borde de la isla).
/// Ángulos relativos a `ang` (positivo = sentido horario visto desde arriba, como los rumbos de la villa).
enum Mall {
    nonisolated static let ang: CGFloat = 1.95                 // entre el Taller iOS y La nube, frente al mar
    nonisolated static let rFrente: CGFloat = 64.6, rFondo: CGFloat = 74
    nonisolated static let atrio: CGFloat = 0.087              // medio ancho angular del atrio (±6 m)
    nonisolated static let modulo: CGFloat = 0.065             // ancho angular de cada tienda (4,5 m a r 69)
    nonisolated static let alas = 5                             // tiendas por lado
    nonisolated static let centro = polar(68.5, 0)              // atrio (barrio «mall»)
    nonisolated static let estacionamiento: CGFloat = -0.53    // calces públicos (lado poniente)
    nonisolated static let proveedores: CGFloat = 0.53         // estacionamiento exclusivo de proveedores y bodega (oriente)
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
            let coche = auto(col, suv: j == 4, faro: faro, freno: freno); coche.scale = SCNVector3(0.72, 0.72, 0.72)
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
        let p0 = PuertoYFlota.w(11.4, 80), p1 = PuertoYFlota.w(11.4, 64.5)
        let idaP = [p0, p1] + arco(61, pa + atan2(11.4, 61), d.tEntra) + d.entra
        let rutaP = idaP + d.atras + d.sale + arco(59, d.tSale, pa + atan2(10.6, 59)) + [PuertoYFlota.w(10.6, 64.5), PuertoYFlota.w(10.6, 80), PuertoYFlota.w(12.2, 83.5)]
        rutas.append((rutaP, 30, largo(idaP + d.atras), [idaP.count - 1, idaP.count], NSColor(Color(hex: "#d68910"))))
        for r in rutas {
            let v = Vehiculo(camion(r.color, faro: faro, freno: freno), ruta: r.ruta, s: r.s, velocidad: 7, paradas: [(r.parada, 15)],
                             reversa: r.reversa, largo: 5.3, ancho: 1.8, paciente: true)
            v.raiz.scale = SCNVector3(0.72, 0.72, 0.72)
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
    nonisolated static let angAero: CGFloat = -1.05, rAero: CGFloat = 150, radioAero: CGFloat = 40
    nonisolated static let angDist: CGFloat = -1.85, rDist: CGFloat = 152, radioDist: CGFloat = 48
    nonisolated static let angCaleta: CGFloat = 2.70, angBalneario: CGFloat = -2.38, angMarina: CGFloat = -2.64
    nonisolated static func polar(_ r: CGFloat, _ a: CGFloat) -> CGPoint { CGPoint(x: sin(a) * r, y: cos(a) * r) }
    nonisolated static func w(_ ang: CGFloat, _ r: CGFloat, _ x: CGFloat, _ z: CGFloat) -> CGPoint {
        CGPoint(x: sin(ang) * (r + z) + cos(ang) * x, y: cos(ang) * (r + z) - sin(ang) * x)
    }
    nonisolated static func aero(_ x: CGFloat, _ z: CGFloat) -> CGPoint { w(angAero, rAero, x, z) }
    nonisolated static func dist(_ x: CGFloat, _ z: CGFloat) -> CGPoint { w(angDist, rDist, x, z) }
    /// Barrios de la isla distrito: posición local y radio de su plaza.
    nonisolated static let barrios: [(id: String, x: CGFloat, z: CGFloat, r: CGFloat)] = [
        ("trade", -18, -21, 11), ("casino", 18, -25, 8), ("banco", 19, -9, 7),
        ("uni", -19, 20, 14), ("ciencia", 19, 20, 11), ("museo", 0, 36, 8)]
    nonisolated static let zonas: Set<String> = ["trade", "banco", "casino", "uni", "ciencia", "museo", "aeropuerto"]
    nonisolated static let posiciones: [String: CGPoint] = {
        var d = Dictionary(uniqueKeysWithValues: barrios.map { ($0.id, dist($0.x, $0.z)) })
        d["aeropuerto"] = aero(-10, -30); return d
    }()
    nonisolated static let radios: [String: CGFloat] = {
        var d = Dictionary(uniqueKeysWithValues: barrios.map { ($0.id, $0.r) }); d["aeropuerto"] = 9; return d
    }()
    @MainActor static var buses: [Vehiculo] = []          // se suman al tránsito después de los autos del anillo
    nonisolated static let alturaEtiqueta: [String: CGFloat] = ["trade": 42, "banco": 12, "casino": 22, "uni": 18, "ciencia": 13, "museo": 11, "aeropuerto": 14]
    /// Sin árboles ni palmeras: avenidas a las islas, caleta, balneario, marina y letrero.
    nonisolated static func libre(_ p: CGPoint) -> Bool {
        let r = hypot(p.x, p.y), a = atan2(p.x, p.y)
        func cerca(_ b: CGFloat, _ ancho: CGFloat) -> Bool {
            var d = a - b
            while d > .pi { d -= 2 * .pi }; while d < -.pi { d += 2 * .pi }
            return abs(d) * r < ancho
        }
        if r > 56 && (cerca(angAero, 10) || cerca(angDist, 10)) { return false }
        if r > 64 && (cerca(angCaleta, 12) || cerca(angBalneario, 18) || cerca(angMarina, 10) || cerca(.pi, 14) || cerca(0.26, 14)) { return false }
        return true
    }
    /// ¿El punto está en alguna isla nueva? Devuelve su barrio para volar a él.
    nonisolated static func barrioDe(_ p: CGPoint) -> String? {
        if hypot(p.x - aero(0, 0).x, p.y - aero(0, 0).y) < radioAero + 4 { return "aeropuerto" }
        let c = dist(0, 0)
        guard hypot(p.x - c.x, p.y - c.y) < radioDist + 4 else { return nil }
        return posiciones.filter { $0.key != "aeropuerto" }.min { hypot(p.x - $0.value.x, p.y - $0.value.y) < hypot(p.x - $1.value.x, p.y - $1.value.y) }?.key
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

    private func arbolito(_ g: SCNNode, x: CGFloat, z: CGFloat, alto: CGFloat = 3) {
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
        let r0: CGFloat = 61, largo = hasta - r0
        caja(g, 7, 0.06, largo, asfalto, y: 0.03, z: r0 + largo / 2)
        caja(g, 11, 0.6, hasta - 82, roca, y: -0.29, z: (82 + hasta) / 2)            // pedraplén sobre el mar
        var z = r0 + 1.5
        while z < hasta - 1 { caja(g, 0.12, 0.02, 1.6, linea, y: 0.07, z: z + 0.8); z += 4 }
        for lado: CGFloat in [-1, 1] {
            caja(g, 0.3, 0.16, hasta - 76, solera, x: lado * 3.65, y: 0.08, z: (76 + hasta) / 2)
            caja(g, 0.08, 0.08, hasta - 84, poste, x: lado * 4.6, y: 0.9, z: (84 + hasta) / 2)        // baranda
            var zp: CGFloat = 86
            while zp < hasta - 2 {
                caja(g, 0.08, 0.9, 0.08, poste, x: lado * 4.6, y: 0.45, z: zp)
                if Int(zp) % 12 < 3 {
                    cil(g, 0.07, 4.2, poste, x: lado * 4.2, z: zp)
                    g.addChildNode(nodo(SCNSphere(radius: 0.22), luz, y: 4.3, x: lado * 4.2, z: zp))
                }
                zp += 3
            }
        }
        // Paradero con rotonda de retorno (el bus da la vuelta aquí, sin entrar al anillo)
        g.addChildNode(nodo(SCNTube(innerRadius: 1.6, outerRadius: 5.6, height: 0.06), asfalto, y: 0.031, z: 67))
        cil(g, 1.5, 0.3, Mat.pbr(NSColor(calibratedRed: 0.25, green: 0.5, blue: 0.22, alpha: 1)), y: 0.15, z: 67)
        let refugio = SCNNode(); refugio.position = SCNVector3(-8.0, 0, 67); refugio.eulerAngles.y = .pi / 2; g.addChildNode(refugio)
        caja(refugio, 3.2, 0.1, 1.4, Mat.pbr(NSColor(Color(hex: color)), rugosidad: 0.5), y: 2.4)
        for x: CGFloat in [-1.5, 1.5] { caja(refugio, 0.08, 2.4, 0.08, poste, x: x, z: -0.6) }
        caja(refugio, 3.0, 2.0, 0.05, Mat.pbr(NSColor(Color(hex: "#bfe3f5")), rugosidad: 0.1), y: 1.2, z: -0.65)
        letrero(refugio, "PARADERO · \(nombre)", color, ancho: 3.0, alto: 0.45, y: 2.75, z: 0.72)
        nav.rect(Islas.w(ang, 0, -8.0, 67).x, Islas.w(ang, 0, -8.0, 67).y, 0.8, 1.7, ang)
    }

    /// Bus de enlace: carrocería, ventanas, letrero y ruedas (proa en +z).
    private func bus(_ color: NSColor, _ texto: String, faro: SCNMaterial, freno: SCNMaterial) -> SCNNode {
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
        for (c, rad) in [(Islas.aero(0, 0), Islas.radioAero), (Islas.dist(0, 0), Islas.radioDist)] {
            playaNatural(centro: c, desde: rad + 1, ancho: 8)
            r.addChildNode(nodo(SCNCylinder(radius: rad, height: 0.5), pasto, y: -0.24, x: c.x, z: c.y))
            nav.anillo(c.x, c.y, rad + 1.5, hueco: 0, ancho: 0)
        }
        avenidaIsla(r, ang: Islas.angAero, hasta: Islas.rAero - Islas.radioAero + 2, nombre: "AEROPUERTO", color: "#1f6fb2")
        avenidaIsla(r, ang: Islas.angDist, hasta: Islas.rDist - Islas.radioDist + 2, nombre: "ISLA DISTRITO", color: "#6c3483")
        montarAeropuerto(r)
        montarDistrito(r)
        montarCaleta(r)
        montarBalneario(r)
        montarMarina(r)
        montarLetreroVilla(r)
    }

    // MARK: Aeropuerto

    private func montarAeropuerto(_ r: SCNNode) {
        let A = marcoLocal(Islas.angAero, Islas.rAero); r.addChildNode(A)
        let asfalto = Mat.pbr(NSColor(calibratedWhite: 0.18, alpha: 1), rugosidad: 0.85), blanco = Mat.pbr(NSColor(calibratedWhite: 0.96, alpha: 1))
        let amarillo = Mat.pbr(NSColor(Color(hex: "#F2C230")), rugosidad: 0.6), hormigon = Mat.pbr(NSColor(calibratedWhite: 0.62, alpha: 1), rugosidad: 0.8)
        let gris = Mat.pbr(NSColor(Color(hex: "#8d98a3")), rugosidad: 0.5, metal: 0.4), acero = Mat.pbr(NSColor(Color(hex: "#c9ced3")), rugosidad: 0.35, metal: 0.7)
        let luzAzul = Mat.emisivo(NSColor.systemBlue, fuerza: 1.2), luzBlanca = Mat.emisivo(NSColor(calibratedWhite: 1, alpha: 1), fuerza: 1.2)
        focos += [luzAzul, luzBlanca]
        // Pista 09/27 con marcas, rodaje, conectores y plataforma
        caja(A, 70, 0.04, 7, asfalto, y: 0.035, z: 9)
        var x: CGFloat = -28
        while x < 28 { caja(A, 3, 0.02, 0.25, blanco, x: x, y: 0.065, z: 9); x += 6 }
        for lado: CGFloat in [-1, 1] {
            var zz: CGFloat = 6.4
            while zz < 11.8 { caja(A, 3, 0.02, 0.4, blanco, x: lado * 32.5, y: 0.065, z: zz); zz += 0.9 }
            caja(A, 0.3, 0.02, 7, blanco, x: lado * 30, y: 0.065, z: 9)
            var xl: CGFloat = -34
            while xl <= 34 { caja(A, 0.2, 0.12, 0.2, luzBlanca, x: xl, y: 0.08, z: 9 + lado * 3.6); xl += 5.5 }
        }
        caja(A, 64, 0.04, 4, asfalto, y: 0.035, z: 0)
        caja(A, 64, 0.02, 0.15, amarillo, y: 0.062, z: 0)
        for lado: CGFloat in [-1, 1] {
            caja(A, 4, 0.04, 9, asfalto, x: lado * 30, y: 0.036, z: 4.5)
            var xl: CGFloat = -31
            while xl <= 31 { caja(A, 0.15, 0.1, 0.15, luzAzul, x: xl, y: 0.07, z: lado * 2.2); xl += 6 }
        }
        caja(A, 46, 0.04, 10, hormigon, y: 0.034, z: -6)
        for gx: CGFloat in [-6, 8] {            // puestos de estacionamiento de aviones
            caja(A, 0.15, 0.02, 8, amarillo, x: gx, y: 0.06, z: -6)
            caja(A, 4, 0.02, 0.15, amarillo, x: gx, y: 0.06, z: -10.2)
        }
        // Terminal: cuerpo, fachada de vidrio, techo curvo, mangas, letreros
        let T = SCNNode(); T.position = SCNVector3(0, 0, -16)
        caja(T, 34, 6, 8, Mat.textura(.estuco, repetir: 4, tinte: "#e9edf1"), y: 3.05)
        caja(T, 33, 4.6, 0.06, ventana(), y: 2.9, z: 4.04)
        caja(T, 33, 4.6, 0.06, ventana(), y: 2.9, z: -4.04)
        let techo = nodo(SCNCylinder(radius: 5, height: 36), Mat.pbr(NSColor(Color(hex: "#d8dee4")), rugosidad: 0.3, metal: 0.6), y: 6.0)
        techo.eulerAngles.z = .pi / 2; techo.scale = SCNVector3(0.35, 1, 1); T.addChildNode(techo)
        letrero(T, "AEROPUERTO INTERNACIONAL VILLA", "#1f6fb2", ancho: 18, alto: 1.4, y: 7.6, z: -4.4, giro: .pi, brillo: 0.8)
        letrero(T, "SALIDAS · LLEGADAS", "#1f6fb2", ancho: 7, alto: 0.7, y: 5.6, z: 4.12)
        for gx: CGFloat in [-6, 8] {
            caja(T, 1.6, 2.2, 4, gris, x: gx - 2, y: 3.4, z: 6)
            caja(T, 0.3, 2.4, 0.3, acero, x: gx - 2, y: 1.2, z: 7.7)
        }
        nav.rect(Islas.aero(0, -16).x, Islas.aero(0, -16).y, 17, 4, Islas.angAero)
        A.addChildNode(T)
        // Torre de control
        let tx: CGFloat = -22, tz: CGFloat = -18
        cil(A, 1.3, 16, Mat.textura(.estuco, repetir: 3, tinte: "#dfe4e8"), x: tx, z: tz)
        caja(A, 4.4, 2.6, 4.4, ventana(), x: tx, y: 17.3, z: tz, chaflan: 0.2)
        caja(A, 5, 0.4, 5, gris, x: tx, y: 18.8, z: tz)
        cil(A, 0.06, 3, acero, x: tx, y: 20.5, z: tz)
        A.addChildNode(nodo(SCNSphere(radius: 0.2), Mat.emisivo(.systemRed, fuerza: 1.5), y: 22.1, x: tx, z: tz))
        nav.circulo(Islas.aero(tx, tz).x, Islas.aero(tx, tz).y, 1.5)
        // Hangares de arco
        for hx: CGFloat in [-29, 29] {
            let h = nodo(SCNCylinder(radius: 4.2, height: 10), Mat.pbr(NSColor(Color(hex: "#aab4bd")), rugosidad: 0.4, metal: 0.6), y: 0, x: hx, z: -7.5)
            h.eulerAngles.z = .pi / 2; A.addChildNode(h)
            caja(A, 0.1, 3.6, 7, Mat.pbr(NSColor(calibratedWhite: 0.25, alpha: 1)), x: hx + (hx < 0 ? 5.02 : -5.02), y: 1.8, z: -7.5)
            nav.rect(Islas.aero(hx, -7.5).x, Islas.aero(hx, -7.5).y, 5, 4.2, Islas.angAero)
        }
        // Manga de viento
        cil(A, 0.06, 5, acero, x: 34, z: 15)
        let manga = nodo(SCNCone(topRadius: 0.15, bottomRadius: 0.4, height: 2), Mat.pbr(NSColor.systemOrange), y: 4.8, x: 34.9, z: 15)
        manga.eulerAngles.z = .pi / 2; A.addChildNode(manga)
        // Lado tierra: calle frente a la terminal, estacionamiento con calces preferentes
        caja(A, 34, 0.05, 5, asfalto, y: 0.03, z: -23.5)
        caja(A, 7, 0.05, 20, asfalto, y: 0.031, z: -34)
        caja(A, 14, 0.05, 9, asfalto, x: 12, y: 0.03, z: -30)
        let fila = SCNNode(); fila.position = SCNVector3(18.9, 0, -26.0); fila.eulerAngles.y = .pi; A.addChildNode(fila)
        filaCalces(fila, [.discapacidad, .adultoMayor, .embarazada, .normal, .normal], largo: 4.6, linea: blanco, amarillo: amarillo,
                   anchos: [3.0, 2.4, 2.4, 2.4, 2.4])
        // Lo estático del aeropuerto va aparte (con nombre) para que un clic lo muestre
        escena.rootNode.addChildNode(aplanado(A, "elem:aeropuerto"))
        A.removeFromParentNode()
        // Aviones: dos en sus puestos (uno sale, vuela y vuelve), una avioneta junto al hangar
        let faro = Mat.emisivo(NSColor(calibratedRed: 1, green: 0.97, blue: 0.85, alpha: 1)); focos.append(faro)
        let parado = avion(NSColor(Color(hex: "#1f6fb2")), escala: 1)
        ubicarAvion(parado, 8, -6.5, 0, rumbo: .pi)
        escena.rootNode.addChildNode(parado)
        let chico = avion(NSColor(Color(hex: "#c0392b")), escala: 0.5)
        ubicarAvion(chico, -19, -3.5, 0, rumbo: .pi / 2)
        escena.rootNode.addChildNode(chico)
        let vuela = avion(NSColor(Color(hex: "#b0306a")), escala: 1)
        escena.rootNode.addChildNode(vuela)
        programarVuelo(vuela)
        // Bus de enlace villa ⇄ aeropuerto
        let fr = Mat.emisivo(.systemRed, fuerza: 0.8)
        func pa(_ x: CGFloat, _ z: CGFloat) -> CGPoint { Islas.aero(x, z) }
        let enIsla = [pa(1.7, -40), pa(1.7, -30), pa(4, -25), pa(12, -25), pa(14, -22.5), pa(12, -21.8), pa(-12, -21.8), pa(-14, -23.5),
                      pa(-12, -25.2), pa(-4, -25.2), pa(-1.7, -30), pa(-1.7, -40)]
        let ruta = rutaBus(ang: Islas.angAero, enIsla: enIsla)
        let b = Vehiculo(bus(NSColor(Color(hex: "#1f6fb2")), "BUS AEROPUERTO", faro: faro, freno: fr), ruta: ruta, s: 0, velocidad: 8,
                         paradas: [(largoRuta(ruta, hasta: 9), 12)], largo: 5.5, ancho: 1.8, paciente: true)
        b.raiz.scale = SCNVector3(0.72, 0.72, 0.72)
        Islas.buses.append(b); escena.rootNode.addChildNode(b.raiz)
    }

    private func largoRuta(_ pts: [CGPoint], hasta k: Int) -> CGFloat {
        var s: CGFloat = 0
        for i in 0..<min(k, pts.count - 1) { s += hypot(pts[i + 1].x - pts[i].x, pts[i + 1].y - pts[i].y) }
        return s
    }

    /// Avión de pasajeros (proa en +z): fuselaje, alas, motores, cola, ventanillas y luces de navegación.
    private func avion(_ color: NSColor, escala: CGFloat) -> SCNNode {
        let n = SCNNode()
        let blanco = Mat.pbr(NSColor(calibratedWhite: 0.97, alpha: 1), rugosidad: 0.3, metal: 0.2), pintura = Mat.pbr(color, rugosidad: 0.35, metal: 0.3)
        let gris = Mat.pbr(NSColor(calibratedWhite: 0.55, alpha: 1), rugosidad: 0.4, metal: 0.6), negro = Mat.pbr(NSColor(calibratedWhite: 0.08, alpha: 1))
        let fus = nodo(SCNCapsule(capRadius: 0.95, height: 11), blanco, y: 1.9); fus.eulerAngles.x = .pi / 2; n.addChildNode(fus)
        caja(n, 0.05, 0.25, 8.5, pintura, x: 0.93, y: 2.0)
        caja(n, 0.05, 0.25, 8.5, pintura, x: -0.93, y: 2.0)
        caja(n, 1.2, 0.35, 0.05, negro, y: 2.2, z: 5.35)                            // parabrisas
        for lado: CGFloat in [-1, 1] {
            let ala = caja(n, 5.2, 0.16, 2.0, blanco, x: lado * 3.2, y: 1.5, z: 0.4)
            ala.eulerAngles.y = lado * 0.32
            let motor = nodo(SCNCylinder(radius: 0.42, height: 1.6), gris, y: 1.05, x: lado * 2.6, z: 1.1); motor.eulerAngles.x = .pi / 2; n.addChildNode(motor)
            let est = caja(n, 2.0, 0.1, 0.9, blanco, x: lado * 1.25, y: 2.2, z: -5.0); est.eulerAngles.y = lado * 0.3
            n.addChildNode(nodo(SCNSphere(radius: 0.12), Mat.emisivo(lado < 0 ? .systemRed : .systemGreen, fuerza: 1.5), y: 1.55, x: lado * 5.6, z: -0.3))
        }
        caja(n, 0.16, 2.2, 1.8, pintura, y: 3.3, z: -5.0)                             // deriva
        let baliza = nodo(SCNSphere(radius: 0.12), Mat.emisivo(.systemRed, fuerza: 2), y: 4.45, z: -5.3)
        baliza.runAction(.repeatForever(.sequence([.fadeOpacity(to: 0.1, duration: 0.6), .fadeOpacity(to: 1, duration: 0.15)])))
        for z: CGFloat in [4.2, -0.2] { cil(n, 0.07, 0.9, gris, y: 0.45, z: z) }       // tren de aterrizaje
        for x: CGFloat in [-0.5, 0.5] { cil(n, 0.07, 0.9, gris, x: x, y: 0.45, z: -0.2) }
        let p = aplanado(n, "elem:avion")
        p.addChildNode(baliza)
        p.scale = SCNVector3(escala * 0.72, escala * 0.72, escala * 0.72)
        return p
    }

    private func ubicarAvion(_ n: SCNNode, _ x: CGFloat, _ z: CGFloat, _ y: CGFloat, rumbo: CGFloat) {
        let p = Islas.aero(x, z)
        n.position = SCNVector3(p.x, y + 0.04, p.y); n.eulerAngles.y = Islas.angAero + rumbo
    }

    /// Ciclo completo (≈ 3 min): embarque, retroceso, rodaje, despegue, vuelta sobre el mar, aproximación, aterrizaje y
    /// regreso al puesto. Coordenadas del marco del aeropuerto; las acciones se repiten para siempre.
    private func programarVuelo(_ n: SCNNode) {
        struct P { var x: CGFloat, z: CGFloat, y: CGFloat, t: Double, atras = false, cabeceo: CGFloat = 0, alabeo: CGFloat = 0 }
        var pts: [P] = [P(x: -6, z: -6.5, y: 0, t: 0)]
        func arco(_ cx: CGFloat, _ cz: CGFloat, _ rad: CGFloat, _ a0: CGFloat, _ a1: CGFloat, y0: CGFloat, y1: CGFloat, t: Double, alabeo: CGFloat) {
            for k in 1...12 {
                let u = CGFloat(k) / 12, a = a0 + (a1 - a0) * u
                pts.append(P(x: cx + sin(a) * rad, z: cz + cos(a) * rad, y: y0 + (y1 - y0) * u, t: t / 12, alabeo: alabeo))
            }
        }
        pts += [P(x: -6, z: -6.5, y: 0, t: 25),                                    // embarque
                P(x: -6, z: 0, y: 0, t: 7, atras: true),                            // retroceso
                P(x: -30, z: 0, y: 0, t: 6), P(x: -30, z: 9, y: 0, t: 3),           // rodaje
                P(x: -27, z: 9, y: 0, t: 2.5),
                P(x: 12, z: 9, y: 0, t: 6),                                         // carrera de despegue
                P(x: 40, z: 9, y: 7, t: 2.2, cabeceo: -0.18),
                P(x: 110, z: 9, y: 34, t: 4.5, cabeceo: -0.12)]
        arco(110, 70, 61, .pi, 0, y0: 34, y1: 42, t: 9, alabeo: -0.35)              // vuelta mar adentro
        pts.append(P(x: -90, z: 131, y: 40, t: 8))
        arco(-90, 70, 61, 0, -.pi, y0: 40, y1: 22, t: 9, alabeo: -0.35)
        pts += [P(x: -28, z: 9, y: 0.6, t: 5.5, cabeceo: -0.05),                    // aproximación
                P(x: -24, z: 9, y: 0, t: 0.8),                                      // toque
                P(x: 22, z: 9, y: 0, t: 7),                                         // frenado
                P(x: 30, z: 9, y: 0, t: 3), P(x: 30, z: 0, y: 0, t: 3),            // sale de la pista
                P(x: -6, z: 0, y: 0, t: 8), P(x: -6, z: -6.5, y: 0, t: 3.5)]       // al puesto
        let p0 = Islas.aero(pts[0].x, pts[0].z)
        n.position = SCNVector3(p0.x, 0.04, p0.y); n.eulerAngles.y = Islas.angAero + .pi
        var acciones: [SCNAction] = []
        var rumbo: CGFloat = .pi
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            let dx = b.x - a.x, dz = b.z - a.z
            if hypot(dx, dz) > 0.01 { rumbo = atan2(dx, dz) + (b.atras ? .pi : 0) }
            let w = Islas.aero(b.x, b.z)
            let mover = SCNAction.move(to: SCNVector3(w.x, b.y + 0.04, w.y), duration: b.t)
            if i == 6 { mover.timingMode = .easeIn }
            if i == pts.count - 5 { mover.timingMode = .easeOut }
            let girar = SCNAction.rotateTo(x: b.cabeceo, y: Islas.angAero + rumbo, z: b.alabeo, duration: min(b.t, b.y > 1 ? b.t : 1.6), usesShortestUnitArc: true)
            acciones.append(.group([mover, girar]))
        }
        n.runAction(.repeatForever(.sequence(acciones)))
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
        nav.circulo(Islas.dist(0, 2).x, Islas.dist(0, 2).y, 3.5)
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
            if rr > 40 { palmera(D, x: x, z: zz) } else { arbolito(D, x: x, z: zz, alto: 2.6 + azar.real() * 1.6) }
            nav.circulo(Islas.dist(x, zz).x, Islas.dist(x, zz).y, 0.3)
        }
        // Cada barrio, en su plaza, con el frente hacia la villa
        for b in Islas.barrios {
            let c = Islas.dist(b.x, b.z), yaw = atan2(-c.x, -c.y)
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
                         velocidad: 8, paradas: [(largoRuta(ruta, hasta: 5), 10)], largo: 5.5, ancho: 1.8, paciente: true)
        v.raiz.scale = SCNVector3(0.72, 0.72, 0.72)
        Islas.buses.append(v); escena.rootNode.addChildNode(v.raiz)
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
        caja(T, 3.4, 17, 3.4, muro, y: 8.5)
        caja(T, 3.8, 0.5, 3.8, oro, y: 17.2)
        T.addChildNode(nodo(SCNPyramid(width: 3.4, height: 2.6, length: 3.4), oro, y: 17.45))
        for (i, ch) in "CASINO".enumerated() {
            let t = SCNText(string: String(ch), extrusionDepth: 0.2); t.font = NSFont.systemFont(ofSize: 1.9, weight: .black); t.flatness = 0.1
            t.materials = [neonRojo, oro, oro]
            let n = SCNNode(geometry: t); let (mn, mx) = n.boundingBox
            n.pivot = SCNMatrix4MakeTranslation((mn.x + mx.x) / 2, mn.y, 0)
            n.position = SCNVector3(0, 15.2 - CGFloat(i) * 2.25, 1.72); T.addChildNode(n)
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
        for k in 0..<3 { caja(B, 6.4, 1.1, 0.06, ventana(), x: 4.2, y: 1.2 + CGFloat(k) * 1.8, z: -2.36) }
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
        casco(n, largo: L, manga: w, alto: 0.7, Mat.pbr(color, rugosidad: 0.55), borda: Mat.pbr(NSColor(calibratedWhite: 0.96, alpha: 1), rugosidad: 0.5))
        caja(n, w * 0.6, 0.7, L * 0.22, Mat.pbr(NSColor(calibratedWhite: 0.95, alpha: 1), rugosidad: 0.5), y: 0.95, z: -L * 0.12, chaflan: 0.04)
        caja(n, w * 0.62, 0.22, 0.03, Mat.pbr(NSColor(Color(hex: "#26394d")), rugosidad: 0.1, metal: 0.5), y: 1.1, z: -L * 0.12 + L * 0.11 + 0.01)
        caja(n, w * 0.7, 0.05, L * 0.26, Mat.pbr(color, rugosidad: 0.5), y: 1.32, z: -L * 0.12)
        caja(n, 0.22, 0.5, 0.25, Mat.pbr(NSColor(calibratedWhite: 0.15, alpha: 1), rugosidad: 0.4), y: 0.55, z: -L / 2 - 0.12)
        n.addChildNode(nodo(SCNSphere(radius: 0.12), Mat.pbr(NSColor.systemOrange), y: 0.7, x: w * 0.4, z: L * 0.15))
        return n
    }

    /// Yate a motor (casco blanco, franja azul, superestructura escalonada con ventanales y flybridge) o velero
    /// (casco esbelto, quilla, mástil, botavara, vela mayor, foque y jarcias).
    private func yate(_ L: CGFloat, vela: Bool) -> SCNNode {
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

    private func montarCaleta(_ r: SCNNode) {
        let G = marcoLocal(Islas.angCaleta, 0); r.addChildNode(G)
        let madera = Mat.textura(.madera, repetir: 4, tinte: "#7a5634"), poste = Mat.textura(.madera, repetir: 1, tinte: "#4a3524")
        // Muelle de madera hacia el mar, con pilotes
        caja(G, 2.6, 0.2, 20, madera, y: 0.25, z: 88)
        var z: CGFloat = 79
        while z <= 98 { for x: CGFloat in [-1.2, 1.2] { cil(G, 0.12, 1.4, poste, x: x, y: -0.2, z: z) }; z += 2.5 }
        // Botes amarrados (agua) y varados en la arena
        let colores = ["#c0392b", "#1f6fb2", "#d68910", "#196f3d", "#f1c40f", "#8e44ad"].map { NSColor(Color(hex: $0)) }
        for (k, (x, zz)) in [(CGFloat(-2.6), CGFloat(86)), (-2.6, 91), (2.6, 89), (2.6, 94)].enumerated() {
            let b = bote(colores[k]); b.position = SCNVector3(x, -0.5, zz); b.eulerAngles.y = 0.05 * CGFloat(k); G.addChildNode(b)
        }
        for (k, x) in [CGFloat(-7), -4.6, 3.8].enumerated() {
            let b = bote(colores[k + 3]); b.position = SCNVector3(x, 0.22, 79.8); b.eulerAngles = SCNVector3(0, 0.3 * CGFloat(k) - 0.3, 0.14); G.addChildNode(b)
        }
        // Redes secándose, cajones y puesto de venta
        let red = Mat.pbr(NSColor(Color(hex: "#3d6b5a")), rugosidad: 0.9); red.transparency = 0.7
        for x: CGFloat in [6.5, 9.5] { cil(G, 0.06, 1.6, poste, x: x, z: 74.5) }
        caja(G, 3, 1.2, 0.04, red, x: 8, y: 1.0, z: 74.5)
        for k in 0..<4 { caja(G, 0.6, 0.35, 0.4, Mat.pbr(NSColor(Color(hex: k % 2 == 0 ? "#2e86c1" : "#e67e22"))), x: 3 + CGFloat(k % 2) * 0.65, y: 0.17 + CGFloat(k / 2) * 0.36, z: 74) }
        let K = SCNNode(); K.position = SCNVector3(-1, 0, 72.5); G.addChildNode(K)
        caja(K, 3.6, 2.4, 2.2, Mat.textura(.madera, repetir: 2, tinte: "#d9b38c"))
        caja(K, 4.0, 0.15, 2.8, Mat.pbr(NSColor(Color(hex: "#1f6fb2"))), y: 2.5, z: 0.3)
        letrero(K, "CALETA DE PESCADORES · PESCADO FRESCO", "#1f6fb2", ancho: 3.6, alto: 0.45, y: 2.85, z: 1.1)
        let kp = Islas.w(Islas.angCaleta, 0, -1, 72.5); nav.rect(kp.x, kp.y, 1.9, 1.2, Islas.angCaleta)
        escena.rootNode.addChildNode(aplanado(G, "elem:caleta"))
        G.removeFromParentNode()
        // Un bote sale a pescar y vuelve
        let sale = bote(colores[5], largo: 3.6)
        let pz0 = Islas.w(Islas.angCaleta, 0, 2.8, 84), pz1 = Islas.w(Islas.angCaleta, 0, 8, 120), pz2 = Islas.w(Islas.angCaleta, 0, -16, 135)
        sale.position = SCNVector3(pz0.x, -0.5, pz0.y); sale.eulerAngles.y = Islas.angCaleta; sale.name = "elem:caleta"
        func ir(_ p: CGPoint, _ t: Double, _ yaw: CGFloat) -> SCNAction {
            .group([.move(to: SCNVector3(p.x, -0.5, p.y), duration: t), .rotateTo(x: 0, y: yaw, z: 0, duration: 2, usesShortestUnitArc: true)])
        }
        let a = Islas.angCaleta
        sale.runAction(.repeatForever(.sequence([.wait(duration: 20), ir(pz1, 14, a + 0.15), ir(pz2, 10, a - 1.2), .wait(duration: 18), ir(pz1, 10, a + 1.6), ir(pz0, 14, a + .pi)])))
        escena.rootNode.addChildNode(sale)
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
                default: b = bote(NSColor(Color(hex: "#c0392b")), largo: 3.8)
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
        letreroVilla(ang: 0.26, r: 79, haciaMar: true)
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
        n.pivot = SCNMatrix4MakeTranslation((mn.x + mx.x) / 2, mn.y, 0)
        n.position = SCNVector3(0, 1.5, 0.05)
        F.addChildNode(n)
        caja(F, 21, 0.3, 0.3, poste, y: 1.35)
        for x in stride(from: CGFloat(-9.5), through: 9.5, by: 3.8) { caja(F, 0.2, 1.4, 0.2, poste, x: x, y: 0.7) }
        letrero(F, "VALLE DE LOS AGENTES", "#1a5276", ancho: 9, alto: 0.75, y: 0.75, z: 0.2, brillo: 0.9)
        escena.rootNode.addChildNode(aplanado(g, "elem:letrero"))
    }

    // MARK: Orilla natural: playa en pendiente bajo el agua y espuma de las olas

    /// Playa que baja suave hasta perderse bajo el agua (sin escalón) y una franja de espuma que respira en la orilla.
    func playaNatural(centro c: CGPoint, desde r0: CGFloat, ancho: CGFloat = 10) {
        let arena = Mat.textura(.arena, repetir: max(8, r0 / 3))
        escena.rootNode.addChildNode(nodo(SCNCone(topRadius: r0, bottomRadius: r0 + ancho, height: 0.75), arena, y: -0.395, x: c.x, z: c.y))
        let orilla = r0 + 0.48 / 0.75 * ancho                     // donde la pendiente cruza el nivel del mar (y −0,5)
        let espuma = Mat.pbr(NSColor(calibratedWhite: 1, alpha: 1), rugosidad: 0.9); espuma.transparency = 0.55; espuma.writesToDepthBuffer = false
        for (k, (d, w)) in [(CGFloat(-0.2), CGFloat(0.9)), (0.9, 0.6)].enumerated() {
            let a = nodo(SCNTube(innerRadius: orilla + d, outerRadius: orilla + d + w, height: 0.02), espuma, y: -0.485 + CGFloat(k) * 0.003, x: c.x, z: c.y)
            a.castsShadow = false
            let crece = SCNAction.scale(to: 1 + 1.2 / orilla, duration: 2.6), vuelve = SCNAction.scale(to: 1, duration: 2.6)
            crece.timingMode = .easeInEaseOut; vuelve.timingMode = .easeInEaseOut
            a.runAction(.repeatForever(.sequence([.wait(duration: Double(k) * 1.3), .group([crece, .fadeOpacity(to: 0.35, duration: 2.6)]),
                                                  .group([vuelve, .fadeOpacity(to: 1, duration: 2.6)])])))
            escena.rootNode.addChildNode(a)
        }
    }

    // MARK: Bañistas, turistas y nadadores del balneario

    private func banista(_ traje: NSColor, piel: NSColor, sombrero: Bool = false) -> SCNNode {
        let n = SCNNode(), mp = Mat.pbr(piel, rugosidad: 0.7), mt = Mat.pbr(traje, rugosidad: 0.6)
        cil(n, 0.07, 0.75, mp, x: -0.09, y: 0.375); cil(n, 0.07, 0.75, mp, x: 0.09, y: 0.375)
        caja(n, 0.34, 0.26, 0.2, mt, y: 0.86, chaflan: 0.06)
        caja(n, 0.32, 0.36, 0.18, mp, y: 1.15, chaflan: 0.07)
        for x: CGFloat in [-0.22, 0.22] { cil(n, 0.05, 0.6, mp, x: x, y: 1.05) }
        n.addChildNode(nodo(SCNSphere(radius: 0.13), mp, y: 1.47))
        if sombrero { cil(n, 0.2, 0.03, Mat.pbr(NSColor(Color(hex: "#e8d29a")), rugosidad: 0.8), y: 1.58); cil(n, 0.1, 0.12, Mat.pbr(NSColor(Color(hex: "#e8d29a"))), y: 1.64) }
        return n
    }

    private func montarGenteBalneario(_ ang: CGFloat) {
        let pieles = ["#f1c9a5", "#d9a47c", "#a8714d", "#7a4e33", "#e8b896"].map { NSColor(Color(hex: $0)) }
        let trajes = ["#e74c3c", "#2980b9", "#f1c40f", "#16a085", "#8e44ad", "#e67e22", "#2c3e50"].map { NSColor(Color(hex: $0)) }
        let G = marcoLocal(ang, 0); escena.rootNode.addChildNode(G)
        var azar = Azar(semilla: 77)
        func p(_ k: Int) -> NSColor { pieles[k % pieles.count] }
        func tr(_ k: Int) -> NSColor { trajes[k % trajes.count] }
        func yArena(_ z: CGFloat) -> CGFloat { z < 79 ? -0.02 : -0.02 - (z - 79) * 0.075 }   // la playa baja hacia el agua
        // Tomando sol en toallas (acostados) junto a los quitasoles
        for k in 0..<8 {
            let b = banista(tr(k), piel: p(k)), x = -10.5 + CGFloat(k) * 3.1, z = 78.6 + CGFloat(k % 2) * 2.6
            b.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, 0); b.position = SCNVector3(x - 0.9, yArena(z) + 0.1, z + 0.7); G.addChildNode(b)
        }
        // De pie conversando, con sombrero o sin él, y niños con un castillo de arena
        for k in 0..<6 {
            let b = banista(tr(k + 3), piel: p(k + 2), sombrero: k % 2 == 0)
            let zp = 82.2 + azar.real() * 0.8
            b.position = SCNVector3(-14 + CGFloat(k) * 5.2 + azar.real(), yArena(zp), zp); b.eulerAngles.y = azar.real() * 6.28
            G.addChildNode(b)
        }
        for k in 0..<2 {
            let b = banista(tr(k + 1), piel: p(k + 3)); b.scale = SCNVector3(0.6, 0.6, 0.6)
            b.position = SCNVector3(5 + CGFloat(k) * 1.1, yArena(83.4), 83.4); b.eulerAngles.y = CGFloat(k) * .pi; G.addChildNode(b)
        }
        let castillo = Mat.textura(.arena, repetir: 1, tinte: "#d8c08a")
        caja(G, 0.8, 0.35, 0.8, castillo, x: 5.55, y: yArena(83.4) + 0.16, z: 83.4)
        for (x, z) in [(CGFloat(5.25), CGFloat(83.1)), (5.85, 83.1), (5.25, 83.7), (5.85, 83.7)] { cil(G, 0.12, 0.6, castillo, x: x, y: yArena(z) + 0.3, z: z) }
        // Turistas que pasean por la orilla, ida y vuelta
        for k in 0..<3 {
            let b = banista(tr(k + 4), piel: p(k + 1), sombrero: k == 1)
            let z: CGFloat = 84.0 + CGFloat(k) * 0.5, x0: CGFloat = -15 + CGFloat(k) * 4, x1: CGFloat = 17 - CGFloat(k) * 3
            b.position = SCNVector3(x0, yArena(z), z); b.eulerAngles.y = .pi / 2
            let ida = SCNAction.move(to: SCNVector3(x1, yArena(z), z), duration: Double(x1 - x0) / 0.9)
            let vuelta = SCNAction.move(to: SCNVector3(x0, yArena(z), z), duration: Double(x1 - x0) / 0.9)
            b.runAction(.repeatForever(.sequence([.wait(duration: Double(k) * 4), ida, .rotateTo(x: 0, y: -.pi / 2, z: 0, duration: 0.8),
                                                  vuelta, .rotateTo(x: 0, y: .pi / 2, z: 0, duration: 0.8)])))
            G.addChildNode(b)
        }
        // Nadadores dentro de las boyas: cabeza y hombros sobre el agua, braceando y meciéndose con las olas
        for k in 0..<9 {
            let b = SCNNode(), mp = Mat.pbr(p(k), rugosidad: 0.7)
            b.addChildNode(nodo(SCNSphere(radius: 0.14), mp, y: 0.2))
            b.addChildNode(nodo(SCNBox(width: 0.36, height: 0.12, length: 0.18, chamferRadius: 0.05), Mat.pbr(tr(k)), y: 0.02))
            if k % 3 == 0 { b.addChildNode(nodo(SCNTorus(ringRadius: 0.32, pipeRadius: 0.1), Mat.pbr(NSColor(Color(hex: k % 2 == 0 ? "#ff6f61" : "#ffd23f"))), y: 0.0)) }
            for lado: CGFloat in [-1, 1] {
                let brazo = nodo(SCNCylinder(radius: 0.045, height: 0.5), mp, y: 0.12, x: lado * 0.22); brazo.eulerAngles.z = lado * 1.2
                brazo.runAction(.repeatForever(.sequence([.rotateTo(x: 0.8, y: 0, z: lado * 1.2, duration: 0.7), .rotateTo(x: -0.8, y: 0, z: lado * 1.2, duration: 0.7)])))
                b.addChildNode(brazo)
            }
            let x = -10 + CGFloat(k) * 2.6 + azar.real(), z = 88.5 + azar.real() * 4.5
            b.position = SCNVector3(x, -0.6, z)
            let mece = SCNAction.sequence([.moveBy(x: 0, y: 0.12, z: 0, duration: 1.3), .moveBy(x: 0, y: -0.12, z: 0, duration: 1.3)])
            let nada = SCNAction.sequence([.moveBy(x: 2.5, y: 0, z: 0, duration: 9), .rotateBy(x: 0, y: .pi, z: 0, duration: 1.2),
                                           .moveBy(x: -2.5, y: 0, z: 0, duration: 9), .rotateBy(x: 0, y: .pi, z: 0, duration: 1.2)])
            b.eulerAngles.y = .pi / 2
            b.runAction(.repeatForever(mece)); b.runAction(.repeatForever(nada))
            G.addChildNode(b)
        }
        // Olas que llegan a la bahía: crestas que avanzan hacia la playa, se hacen espuma y desaparecen
        let espuma = Mat.pbr(NSColor(calibratedWhite: 1, alpha: 1), rugosidad: 0.9); espuma.transparency = 0.7; espuma.writesToDepthBuffer = false
        for k in 0..<4 {
            let ola = nodo(SCNBox(width: 34, height: 0.08, length: 0.5, chamferRadius: 0.04), espuma, y: -0.47, z: 100)
            ola.opacity = 0; ola.castsShadow = false
            ola.runAction(.repeatForever(.sequence([
                .wait(duration: Double(k) * 2.5),
                .move(to: SCNVector3(0, -0.47, 100), duration: 0),
                .group([.move(to: SCNVector3(0, -0.47, 86.2), duration: 10), .sequence([.fadeOpacity(to: 0.9, duration: 3), .wait(duration: 5), .fadeOpacity(to: 0, duration: 2)])]),
                .wait(duration: Double(3 - k) * 2.5)])))
            G.addChildNode(ola)
        }
    }
}
