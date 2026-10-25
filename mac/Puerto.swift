import SwiftUI
import SceneKit
import AppKit

// MARK: - Puerto de proveedores y grupo de batalla del portaaviones
//
// El puerto es la puerta de la villa al exterior: ahí trabajan los agentes que conectan el Mac con apps y servicios
// externos (Gmail, iMessage, el otro Mac, la App Store, los proveedores de IA de la memoria) y quedan muelles libres
// para los futuros agentes proveedores. Cada barco refleja a su agente: su luz de mástil toma el color de su estado.
//
// El portaaviones y su escolta patrullan el mar: cada buque es un agente protector u optimizador del Mac
// (seguridad, optimizador, salud, respaldos, red). Si hay una alarma, la flota acelera y cierra el cerco sobre la isla.

@MainActor
final class PuertoYFlota {
    nonisolated static let ang: CGFloat = -0.48                 // rumbo del puerto: entre el cuartel de bomberos y la Bodega del Mac
    nonisolated static let centro = CGPoint(x: sin(ang) * 69, y: cos(ang) * 69)    // capitanía (barrio «puerto»)
    nonisolated static let flotaAng: CGFloat = 2.75             // la flota patrulla al otro lado de la isla, frente a la cámara

    /// Buques de la escolta: cada uno lo comanda un agente protector u optimizador.
    nonisolated static let buques: [(id: String, nombre: String)] = [("seg", "Fragata Antivirus"), ("opt", "Destructor Optimizador"),
        ("salud", "Corbeta Salud del Mac"), ("resp", "Patrullero Respaldos"), ("red", "Submarino Vigía de red")]

    /// Agente que refleja cada elemento del puerto o de la flota.
    nonisolated static func agenteDe(_ e: String) -> String? {
        switch e {
        case "puerto-carguero": return "sincmac"
        case "puerto-tanquero": return "mem"
        case "puerto-lancha": return "trad"
        case "puerto-faro": return "asc"
        default: return e.hasPrefix("flota-") && e != "flota-portaaviones" ? String(e.dropFirst(6)) : nil
        }
    }

    /// Punto del puerto en coordenadas locales: `lat` a lo largo de la costa, `r` distancia al centro de la isla.
    nonisolated static func w(_ lat: CGFloat, _ r: CGFloat) -> CGPoint {
        CGPoint(x: sin(ang) * r + cos(ang) * lat, y: cos(ang) * r - sin(ang) * lat)
    }

    /// Sin árboles ni palmeras sobre el puerto ni sobre su avenida.
    nonisolated static func libre(_ p: CGPoint) -> Bool {
        let r = p.x * sin(ang) + p.y * cos(ang), lat = p.x * cos(ang) - p.y * sin(ang)
        if r > 58 && abs(lat) < 36 { return false }
        if r > 10 && r < 66 && abs(lat) < 4.8 { return false }
        return true
    }

    let escena: SCNScene, nav: Navegacion
    private(set) var luces: [SCNMaterial] = []                  // focos que se encienden de noche
    private var estado: [(id: String, m: SCNMaterial)] = []     // luz de mástil de cada barco según su agente
    private lazy var luzAlmirante = Mat.emisivo(.systemGreen, fuerza: 1.6)
    /// Ruta de la lancha: punto, si llega a él en marcha atrás y cuántos segundos espera al llegar.
    private var lancha = SCNNode(), rutaLancha: [(p: CGPoint, atras: Bool, espera: CGFloat)] = []
    private var tramo = 0, sTramo: CGFloat = 0, vLancha: CGFloat = 0, rumboLancha: CGFloat = 0, espera: CGFloat = 6
    /// Estela que sigue a un barco sobre la superficie del mar; su espuma corre hacia atrás según la velocidad.
    private final class Estela {
        let raiz: SCNNode, m: SCNMaterial, sx: CGFloat, sy: CGFloat, zoff: CGFloat
        weak var barco: SCNNode?
        var off: CGFloat = 0, v: CGFloat = 0
        init(raiz: SCNNode, m: SCNMaterial, sx: CGFloat, sy: CGFloat, zoff: CGFloat, barco: SCNNode) {
            self.raiz = raiz; self.m = m; self.sx = sx; self.sy = sy; self.zoff = zoff; self.barco = barco
        }
    }
    private var estelas: [Estela] = [], estelaLancha: Estela?
    nonisolated static let abreKelvin: CGFloat = tan(19.47 * .pi / 180)     // ángulo de Kelvin: toda estela se abre así
    private static var cacheEspuma: CGImage?
    private var portaaviones = SCNNode(), escoltas: [(n: SCNNode, lat: CGFloat, fwd: CGFloat)] = []
    private var fase: CGFloat = 0, radioFlota: CGFloat = 185, rumboFlota: CGFloat = 0
    private var ultimoEstado: CFTimeInterval = 0

    // Materiales compartidos (pocos materiales = pocos dibujos)
    private lazy var hormigon = Mat.textura(.estuco, repetir: 8, tinte: "#b3aea4")
    private lazy var acero = Mat.pbr(NSColor(Color(hex: "#c9ced3")), rugosidad: 0.45, metal: 0.6)
    private lazy var amarillo = Mat.pbr(NSColor(Color(hex: "#f2c230")), rugosidad: 0.6)
    private lazy var negro = Mat.pbr(NSColor(calibratedWhite: 0.1, alpha: 1), rugosidad: 0.5)
    private lazy var blanco = Mat.pbr(NSColor(calibratedWhite: 0.94, alpha: 1), rugosidad: 0.5)
    private lazy var rojo = Mat.pbr(NSColor(Color(hex: "#b8322a")), rugosidad: 0.55)
    private lazy var roca = Mat.pbr(NSColor(Color(hex: "#6c6b66")), rugosidad: 0.95)
    private lazy var gris = Mat.pbr(NSColor(Color(hex: "#6f7882")), rugosidad: 0.55, metal: 0.35)
    private lazy var grisOscuro = Mat.pbr(NSColor(Color(hex: "#3b4148")), rugosidad: 0.7, metal: 0.2)
    private lazy var vidrio: SCNMaterial = {
        let m = Mat.pbr(NSColor(Color(hex: "#26394d")), rugosidad: 0.12, metal: 0.55)
        m.emission.contents = NSColor(calibratedRed: 1, green: 0.82, blue: 0.5, alpha: 1); m.emission.intensity = 0.3; return m
    }()
    private lazy var contenedores: [SCNMaterial] = ["#b8322a", "#1f6fb2", "#2e8b57", "#e67e22", "#7f8c8d", "#6c3f8f"].map {
        Mat.pbr(NSColor(Color(hex: $0)), rugosidad: 0.6, metal: 0.25)
    }

    init(escena: SCNScene, nav: Navegacion) { self.escena = escena; self.nav = nav }

    // MARK: Construcción

    /// Lo que no se mueve (explanada, muelles, rompeolas, bodegas, contenedores, faroles, boyas) va al bloque estático;
    /// barcos, grúas y faro van aparte porque responden al clic.
    func montar(_ r: SCNNode) {
        let g = SCNNode(); g.eulerAngles.y = PuertoYFlota.ang; r.addChildNode(g)    // local: x = a lo largo de la costa, z = hacia el mar
        // Explanada de hormigón con muro de atraque, defensas y bitas
        g.addChildNode(nodo(SCNBox(width: 62, height: 0.75, length: 10.4, chamferRadius: 0), hormigon, y: -0.32, x: 0, z: 82.9))
        g.addChildNode(nodo(SCNBox(width: 62, height: 0.02, length: 0.16, chamferRadius: 0), amarillo, y: 0.065, z: 87.5))
        g.addChildNode(nodo(SCNBox(width: 62, height: 0.4, length: 0.22, chamferRadius: 0.05), negro, y: -0.28, z: 88.2))
        var lat: CGFloat = -29
        while lat <= 29 {
            if abs(abs(lat) - 14) > 3 { bita(g, lat, 87.4) }
            lat += 4
        }
        // Muelles (A: tanquero y lancha; B: carguero y grúas) sobre pilotes
        for (x, largo) in [(CGFloat(-14), CGFloat(24)), (14, 20)] {
            let medio = 88 + largo / 2
            g.addChildNode(nodo(SCNBox(width: 5, height: 0.55, length: largo, chamferRadius: 0), hormigon, y: -0.22, x: x, z: medio))
            g.addChildNode(nodo(SCNBox(width: 0.12, height: 0.02, length: largo, chamferRadius: 0), amarillo, y: 0.065, x: x - 2.3, z: medio))
            g.addChildNode(nodo(SCNBox(width: 0.12, height: 0.02, length: largo, chamferRadius: 0), amarillo, y: 0.065, x: x + 2.3, z: medio))
            var t: CGFloat = 90
            while t < 88 + largo {
                for s: CGFloat in [-2.2, 2.2] { g.addChildNode(nodo(SCNCylinder(radius: 0.28, height: 2.6), negro, y: -1.6, x: x + s, z: t)) }
                for s: CGFloat in [-2.1, 2.1] { bita(g, x + s, t + 1) }
                t += 4
            }
        }
        // Rompeolas de rocas con dos brazos; la boca del puerto queda entre ambos
        rompeolas(g, [CGPoint(x: 31, y: 87), CGPoint(x: 40, y: 117), CGPoint(x: 25, y: 126)])
        rompeolas(g, [CGPoint(x: -31, y: 87), CGPoint(x: -37, y: 116), CGPoint(x: -29, y: 123)])
        // Boyas de la boca: verde a babor, roja a estribor
        for (x, z, c) in [(CGFloat(-25), CGFloat(124), NSColor.systemGreen), (19, 128, .systemRed)] {
            let luz = Mat.emisivo(c, fuerza: 1.2); luces.append(luz)
            g.addChildNode(nodo(SCNCylinder(radius: 0.55, height: 1.0), Mat.pbr(c, rugosidad: 0.5), y: -0.2, x: x, z: z))
            g.addChildNode(nodo(SCNCone(topRadius: 0, bottomRadius: 0.45, height: 1.0), Mat.pbr(c, rugosidad: 0.5), y: 0.8, x: x, z: z))
            g.addChildNode(nodo(SCNSphere(radius: 0.16), luz, y: 1.4, x: x, z: z))
        }
        // Bodegas portuarias de techo curvo, a los costados de la capitanía
        for (x, letrero) in [(CGFloat(-18), "IMPORTACIÓN"), (18, "EXPORTACIÓN")] {
            let muro = Mat.textura(.estuco, repetir: 3, tinte: x < 0 ? "#c7d3dc" : "#d8cfc0")
            g.addChildNode(nodo(SCNBox(width: 10, height: 4, length: 7, chamferRadius: 0.05), muro, y: 2, x: x, z: 71))
            let techo = nodo(SCNCylinder(radius: 3.65, height: 10.3), Mat.pbr(NSColor(Color(hex: "#8d99a3")), rugosidad: 0.5, metal: 0.6), y: 3.6, x: x, z: 71)
            techo.eulerAngles.z = .pi / 2; techo.scale = SCNVector3(0.45, 1, 1); g.addChildNode(techo)
            g.addChildNode(nodo(SCNBox(width: 4, height: 3.2, length: 0.08, chamferRadius: 0), grisOscuro, y: 1.6, x: x, z: 74.53))   // portón al muelle
            for dx: CGFloat in [-2.9, 2.9] {                                                                                       // ventanas junto al portón
                g.addChildNode(nodo(SCNBox(width: 1.3, height: 0.8, length: 0.06, chamferRadius: 0), vidrio, y: 2.5, x: x + dx, z: 74.52))
            }
            // Fachada hacia la villa: puerta de personal con marco y alero, ventanas a ambos lados y letrero bajo el
            // techo curvo (antes iba a 3,3 m y el borde del techo lo tapaba a medias).
            let puerta = Mat.pbr(NSColor(Color(hex: "#4a5560")), rugosidad: 0.45, metal: 0.5)
            g.addChildNode(nodo(SCNBox(width: 1.6, height: 2.3, length: 0.05, chamferRadius: 0), grisOscuro, y: 1.15, x: x, z: 67.47))    // marco
            g.addChildNode(nodo(SCNBox(width: 1.3, height: 2.1, length: 0.06, chamferRadius: 0), puerta, y: 1.05, x: x, z: 67.44))         // hoja
            g.addChildNode(nodo(SCNBox(width: 0.32, height: 0.6, length: 0.07, chamferRadius: 0), vidrio, y: 1.55, x: x, z: 67.42))        // mirilla
            g.addChildNode(nodo(SCNBox(width: 2.0, height: 0.08, length: 0.6, chamferRadius: 0.02), grisOscuro, y: 2.32, x: x, z: 67.2))  // alero
            for dx: CGFloat in [-3.3, 3.3] {
                g.addChildNode(nodo(SCNBox(width: 1.6, height: 0.9, length: 0.06, chamferRadius: 0), vidrio, y: 1.75, x: x + dx, z: 67.47))
                g.addChildNode(nodo(SCNBox(width: 1.75, height: 0.08, length: 0.14, chamferRadius: 0), grisOscuro, y: 1.27, x: x + dx, z: 67.45))   // alféizar
            }
            for sx: CGFloat in [-1, 1] { for z: CGFloat in [69.3, 72.7] {                                                         // ventanas altas en los costados
                g.addChildNode(nodo(SCNBox(width: 0.06, height: 0.6, length: 1.8, chamferRadius: 0), vidrio, y: 2.9, x: x + sx * 5.02, z: z))
            } }
            let cartel = SCNMaterial(); cartel.diffuse.contents = Pizarra.letrero(letrero); cartel.emission.contents = Pizarra.letrero(letrero); cartel.emission.intensity = 0.4
            let c = nodo(SCNBox(width: 4.4, height: 0.7, length: 0.06, chamferRadius: 0), cartel, y: 2.75, x: x, z: 67.44); c.eulerAngles.y = .pi
            g.addChildNode(c)
            let p = PuertoYFlota.w(x, 71); nav.rect(p.x, p.y, 5.1, 3.6, PuertoYFlota.ang)
        }
        // Patios de contenedores apilados (1 a 3 de alto)
        var azar = Azar(semilla: 7)
        for (x0, x1) in [(CGFloat(-29), CGFloat(-19.5)), (19.5, 29)] {
            var x = x0
            while x < x1 {
                var z: CGFloat = 79.2
                while z < 86 {
                    let alto = 1 + Int(azar.real() * 2.99)
                    for k in 0..<alto {
                        let m = contenedores[Int(azar.real() * CGFloat(contenedores.count - 1) + 0.5)]
                        g.addChildNode(nodo(SCNBox(width: 2.6, height: 1.25, length: 1.2, chamferRadius: 0.02), m, y: 0.68 + CGFloat(k) * 1.27, x: x + 1.3, z: z))
                    }
                    z += 1.4
                }
                x += 2.9
            }
        }
        // Faroles altos de la explanada y los muelles
        let poste = Mat.pbr(NSColor(calibratedWhite: 0.25, alpha: 1), rugosidad: 0.4, metal: 0.7)
        let foco = Mat.emisivo(NSColor(calibratedRed: 1, green: 0.88, blue: 0.62, alpha: 1)); luces.append(foco)
        for (x, z) in [(CGFloat(-24), CGFloat(78.2)), (-8, 78.2), (8, 78.2), (24, 78.2), (-14, 110), (14, 106)] {
            g.addChildNode(nodo(SCNCylinder(radius: 0.12, height: 8), poste, y: 4, x: x, z: z))
            g.addChildNode(nodo(SCNBox(width: 1.2, height: 0.25, length: 0.5, chamferRadius: 0.05), foco, y: 8.05, x: x, z: z))
        }
        // Huella física de lo que queda dentro de la isla
        for x: CGFloat in [-24, -8, 8, 24] { let p = PuertoYFlota.w(x, 78.2); nav.circulo(p.x, p.y, 0.15) }

        montarGruas()
        montarFaro()
        montarMuelleLibre()
        montarBarcosDelPuerto()
        montarFlota()
    }

    private func bita(_ g: SCNNode, _ x: CGFloat, _ z: CGFloat) {
        g.addChildNode(nodo(SCNCylinder(radius: 0.16, height: 0.45), negro, y: 0.28, x: x, z: z))
        g.addChildNode(nodo(SCNCylinder(radius: 0.22, height: 0.08), negro, y: 0.52, x: x, z: z))
    }

    private func rompeolas(_ g: SCNNode, _ pts: [CGPoint]) {
        var azar = Azar(semilla: UInt64(abs(pts[0].x * 13)))
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1], largo = hypot(b.x - a.x, b.y - a.y), yaw = atan2(b.x - a.x, b.y - a.y)
            let base = nodo(SCNBox(width: 4, height: 1.7, length: largo + 2, chamferRadius: 0.4), roca, y: -0.35, x: (a.x + b.x) / 2, z: (a.y + b.y) / 2)
            base.eulerAngles.y = yaw; g.addChildNode(base)
            var t: CGFloat = 0
            while t <= largo {
                let s = (azar.real() - 0.5) * 3, q = CGPoint(x: a.x + (b.x - a.x) * t / largo + cos(yaw) * s, y: a.y + (b.y - a.y) * t / largo - sin(yaw) * s)
                let piedra = nodo(SCNSphere(radius: 0.7 + azar.real() * 0.6), roca, y: 0.5 + azar.real() * 0.3, x: q.x, z: q.y)
                piedra.scale = SCNVector3(1, 0.6 + azar.real() * 0.3, 1.2); g.addChildNode(piedra)
                t += 2.1
            }
        }
    }

    /// Pieza clicable: se arma en coordenadas del puerto, se aplana y queda con su nombre.
    private func pieza(_ nombre: String, _ armar: (SCNNode) -> Void) -> SCNNode {
        let g = SCNNode(); g.eulerAngles.y = PuertoYFlota.ang
        armar(g)
        Villa3D.Coordinador.hornear(g)
        let f = g.flattenedClone(); f.name = nombre
        escena.rootNode.addChildNode(f)
        return f
    }

    /// Dos grúas pórtico sobre el muelle B; su carro va y viene sobre el carguero con un contenedor colgando.
    private func montarGruas() {
        for (k, z) in [CGFloat(95), 104].enumerated() {
            let raiz = SCNNode(); raiz.eulerAngles.y = PuertoYFlota.ang; raiz.name = "elem:puerto-grua"
            let cuerpo = SCNNode()
            for (x, zz) in [(CGFloat(11.8), z - 1.6), (11.8, z + 1.6), (16.2, z - 1.6), (16.2, z + 1.6)] {
                cuerpo.addChildNode(nodo(SCNBox(width: 0.45, height: 10, length: 0.45, chamferRadius: 0), amarillo, y: 5, x: x, z: zz))
            }
            for zz in [z - 1.6, z + 1.6] {
                cuerpo.addChildNode(nodo(SCNBox(width: 4.9, height: 0.5, length: 0.5, chamferRadius: 0), amarillo, y: 2.2, x: 14, z: zz))
            }
            cuerpo.addChildNode(nodo(SCNBox(width: 17, height: 0.7, length: 1.2, chamferRadius: 0), amarillo, y: 10.3, x: 17.5, z: z))    // pluma sobre el barco
            cuerpo.addChildNode(nodo(SCNBox(width: 2.2, height: 1.6, length: 2.4, chamferRadius: 0.05), grisOscuro, y: 11.3, x: 10.4, z: z))  // contrapeso
            cuerpo.addChildNode(nodo(SCNBox(width: 1.4, height: 1.2, length: 1.4, chamferRadius: 0.05), vidrio, y: 9.4, x: 15.2, z: z))      // cabina
            for zz in [z - 1.6, z + 1.6] {
                let tirante = nodo(SCNCylinder(radius: 0.05, height: 9), acero, y: 12.6, x: 19.5, z: zz); tirante.eulerAngles.z = 1.15
                cuerpo.addChildNode(tirante)
                cuerpo.addChildNode(nodo(SCNBox(width: 0.3, height: 3, length: 0.3, chamferRadius: 0), amarillo, y: 12.1, x: 14, z: zz))
            }
            Villa3D.Coordinador.hornear(cuerpo)
            raiz.addChildNode(cuerpo.flattenedClone())
            // Carro con cable y contenedor; va y viene sobre el barco (tiempos distintos para cada grúa)
            let carro = SCNNode(); carro.position = SCNVector3(14.5, 9.7, z)
            carro.addChildNode(nodo(SCNBox(width: 1.3, height: 0.5, length: 1.3, chamferRadius: 0.05), grisOscuro))
            carro.addChildNode(nodo(SCNCylinder(radius: 0.03, height: 4.6), acero, y: -2.5))
            carro.addChildNode(nodo(SCNBox(width: 2.6, height: 1.25, length: 1.2, chamferRadius: 0.02), contenedores[k == 0 ? 1 : 3], y: -5.4))
            let ida = SCNAction.moveBy(x: 7.5, y: 0, z: 0, duration: 7); ida.timingMode = .easeInEaseOut
            carro.runAction(.repeatForever(.sequence([.wait(duration: 2 + Double(k) * 3), ida, .wait(duration: 2.5), ida.reversed(), .wait(duration: 1)])))
            raiz.addChildNode(carro)
            escena.rootNode.addChildNode(raiz)
        }
    }

    /// Faro a rayas en la punta del rompeolas, con haz giratorio. Su linterna toma el color del Vigía de la App Store.
    private func montarFaro() {
        let raiz = SCNNode(); raiz.name = "elem:puerto-faro"
        let base = PuertoYFlota.w(25, 126); raiz.position = SCNVector3(base.x, 0, base.y)
        let cuerpo = SCNNode()
        cuerpo.addChildNode(nodo(SCNCylinder(radius: 1.6, height: 1.2), hormigon, y: 0.5))
        for k in 0..<5 {
            let kk = CGFloat(k)
            cuerpo.addChildNode(nodo(SCNCone(topRadius: 1.05 - kk * 0.08 - 0.08, bottomRadius: 1.05 - kk * 0.08, height: 1.8), k % 2 == 0 ? blanco : rojo, y: 2 + kk * 1.8))
        }
        cuerpo.addChildNode(nodo(SCNCylinder(radius: 1.0, height: 0.15), negro, y: 10.6))
        cuerpo.addChildNode(nodo(SCNTube(innerRadius: 0.95, outerRadius: 1.0, height: 0.45), negro, y: 10.9))
        let linterna = Mat.emisivo(.systemGreen, fuerza: 1.8)
        estado.append(("asc", linterna))
        cuerpo.addChildNode(nodo(SCNCylinder(radius: 0.6, height: 1.1), linterna, y: 11.3))
        cuerpo.addChildNode(nodo(SCNCone(topRadius: 0, bottomRadius: 0.8, height: 0.8), rojo, y: 12.25))
        raiz.addChildNode(cuerpo.flattenedClone())
        // Haz de luz giratorio
        let haz = SCNNode(); haz.position = SCNVector3(0, 11.3, 0)
        let mHaz = Mat.emisivo(NSColor(calibratedRed: 1, green: 0.95, blue: 0.7, alpha: 1), fuerza: 1.2)
        mHaz.transparency = 0.22; mHaz.writesToDepthBuffer = false; mHaz.isDoubleSided = true; luces.append(mHaz)
        let rayo = SCNCone(topRadius: 1.4, bottomRadius: 0.15, height: 22)
        let r1 = nodo(rayo, mHaz, z: 11.2); r1.eulerAngles.x = .pi / 2; r1.castsShadow = false
        haz.addChildNode(r1)
        haz.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 9)))
        raiz.addChildNode(haz)
        let e = etiqueta("Faro · Vigía de la App Store", y: 14.5, grande: false, icono: "binoculars.fill", color: .systemTeal)
        raiz.addChildNode(e)
        escena.rootNode.addChildNode(raiz)
    }

    /// Muelle 3, libre: listo para los próximos agentes proveedores.
    private func montarMuelleLibre() {
        _ = pieza("elem:puerto-muelle") { g in
            let cartel = SCNMaterial(); cartel.diffuse.contents = Pizarra.letrero("MUELLE LIBRE"); cartel.emission.contents = Pizarra.letrero("MUELLE LIBRE"); cartel.emission.intensity = 0.4
            let c = nodo(SCNBox(width: 4.4, height: 0.72, length: 0.08, chamferRadius: 0.02), cartel, y: 2.2, x: 0, z: 86.6); c.eulerAngles.y = .pi
            g.addChildNode(c)
            for x: CGFloat in [-1.9, 1.9] { g.addChildNode(nodo(SCNCylinder(radius: 0.07, height: 1.9), acero, y: 1.0, x: x, z: 86.6)) }
            // Puestos de amarre marcados en el agua para los barcos que vendrán
            for x: CGFloat in [-6, 6] {
                g.addChildNode(nodo(SCNBox(width: 0.12, height: 0.03, length: 14, chamferRadius: 0), amarillo, y: -0.44, x: x - 2.4, z: 95.5))
                g.addChildNode(nodo(SCNBox(width: 0.12, height: 0.03, length: 14, chamferRadius: 0), amarillo, y: -0.44, x: x + 2.4, z: 95.5))
                g.addChildNode(nodo(SCNCylinder(radius: 0.35, height: 0.8), amarillo, y: -0.3, x: x, z: 103))   // boya de amarre
            }
        }
        let p = PuertoYFlota.w(0, 86.6), e = etiqueta("Muelle libre · nuevos proveedores", y: 3.6, grande: false, icono: "plus.circle.fill", color: .systemYellow)
        e.position = SCNVector3(p.x, 3.6, p.y); escena.rootNode.addChildNode(e)
        let q = PuertoYFlota.w(0, 86.6); nav.circulo(q.x, q.y, 0.1)
    }

    // MARK: Barcos

    /// Casco visto desde arriba (proa hacia +z), extruido en vertical y centrado en `y`.
    private func casco(largo L: CGFloat, manga B: CGFloat, alto H: CGFloat, proa: CGFloat, _ m: SCNMaterial, y: CGFloat) -> SCNNode {
        let hb = B / 2, z0 = -L / 2, z1 = L / 2 - proa
        let p = NSBezierPath()
        p.move(to: NSPoint(x: -hb * 0.82, y: z0)); p.line(to: NSPoint(x: hb * 0.82, y: z0))
        p.line(to: NSPoint(x: hb, y: z0 + L * 0.12)); p.line(to: NSPoint(x: hb, y: z1))
        p.curve(to: NSPoint(x: 0, y: L / 2), controlPoint1: NSPoint(x: hb, y: z1 + proa * 0.55), controlPoint2: NSPoint(x: hb * 0.35, y: L / 2))
        p.curve(to: NSPoint(x: -hb, y: z1), controlPoint1: NSPoint(x: -hb * 0.35, y: L / 2), controlPoint2: NSPoint(x: -hb, y: z1 + proa * 0.55))
        p.line(to: NSPoint(x: -hb, y: z0 + L * 0.12)); p.close()
        p.flatness = 0.25
        let n = nodo(SCNShape(path: p, extrusionDepth: H), m, y: y)
        n.eulerAngles.x = .pi / 2       // el trazado (x, y) queda en (x, z) y la extrusión en vertical
        return n
    }

    /// Estela realista: dos brazos que se abren desde la popa con el ángulo de Kelvin (19,5°) y se deshilachan en
    /// plumas, la espuma revuelta de la hélice al centro, olas transversales tenues entre los brazos y un desvanecido
    /// suave hacia atrás. La forma es una máscara fija; la espuma es una textura en vetas que corre hacia popa.
    /// Va sobre la superficie del mar (no colgando del casco, que sube y baja con las olas y la hundía a ratos).
    @discardableResult
    private func estelaDe(_ barco: SCNNode, manga: CGFloat, largo: CGFloat, popa: CGFloat) -> Estela {
        let ancho = manga * 1.2 + 2 * largo * PuertoYFlota.abreKelvin
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = PuertoYFlota.espuma()
        m.diffuse.wrapS = .repeat; m.diffuse.wrapT = .repeat; m.diffuse.mipFilter = .linear
        m.roughness.contents = 0.75; m.metalness.contents = 0.0
        m.transparent.contents = PuertoYFlota.mascaraEstela(manga: manga, largo: largo, ancho: ancho)
        m.transparencyMode = .aOne
        m.writesToDepthBuffer = false; m.blendMode = .alpha
        let plano = nodo(SCNPlane(width: ancho, height: largo), m)
        plano.eulerAngles.x = -.pi / 2; plano.castsShadow = false; plano.renderingOrder = 1
        let raiz = SCNNode(); raiz.addChildNode(plano)
        escena.rootNode.addChildNode(raiz)
        let e = Estela(raiz: raiz, m: m, sx: ancho / 7, sy: largo / 7, zoff: popa - largo / 2, barco: barco)
        estelas.append(e)
        return e
    }

    /// Forma de la estela (canal alfa), en metros reales del barco: arriba de la imagen = lejos de la popa.
    private static func mascaraEstela(manga: CGFloat, largo: CGFloat, ancho: CGFloat) -> CGImage {
        let W = 256, H = 512, abre = abreKelvin
        var px = [UInt8](repeating: 0, count: W * H * 4)
        var azar = Azar(semilla: UInt64(manga * 100 + largo))
        let ondaT = max(1.2, manga * 1.3)                       // separación de las olas transversales y de las plumas
        for j in 0..<H {
            let d = CGFloat(H - 1 - j) / CGFloat(H - 1) * largo     // metros desde la popa
            let fade = pow(max(0, 1 - d / largo), 1.7) * min(1, d / 0.6)
            let xa = manga * 0.5 + d * abre, th = 0.10 + d * 0.03   // brazo exterior (Kelvin)
            let xb = manga * 0.45 + d * abre * 0.62                 // brazo interior, más tenue
            let w = manga * 0.42 + d * 0.06                         // ancho del revuelto de la hélice
            let helice = 0.9 * exp(-d / (largo * 0.4)) + 0.12
            for i in 0..<W {
                let x = (CGFloat(i) + 0.5) / CGFloat(W) * ancho - ancho / 2, ax = abs(x)
                let centro = exp(-pow(x / w, 2) * 1.6) * helice
                let pluma = 0.6 + 0.4 * pow(sin(d * .pi / ondaT + ax * 0.8), 2)
                let brazo = exp(-pow((ax - xa) / th, 2)) * 0.95 * pluma
                let brazo2 = exp(-pow((ax - xb) / (th * 1.4), 2)) * 0.35
                var transv: CGFloat = 0
                if ax < xa { transv = 0.16 * pow(sin((d + 0.25 * x * x / max(1, d)) * .pi / ondaT), 2) * (1 - ax / xa) }
                var v = max(centro, brazo, brazo2) + transv
                v *= 0.8 + 0.2 * azar.real()
                v = min(1, v) * fade
                let k = (j * W + i) * 4, a = UInt8(min(255, v * 235))
                px[k] = a; px[k + 1] = a; px[k + 2] = a; px[k + 3] = a
            }
        }
        return px.withUnsafeMutableBytes { b in
            CGContext(data: b.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
    }

    /// Espuma en vetas alargadas (ruido periódico, se repite sin costuras): blanca donde rompe, translúcida entre medio.
    private static func espuma() -> CGImage {
        if let i = cacheEspuma { return i }
        let s = 128
        var azar = Azar(semilla: 5)
        struct Capa { let gx: Int, gy: Int, peso: CGFloat, v: [CGFloat] }
        var capas: [Capa] = []
        for (gx, gy, p) in [(8, 3, 0.45), (16, 6, 0.28), (32, 12, 0.17), (64, 32, 0.10)] as [(Int, Int, CGFloat)] {
            capas.append(Capa(gx: gx, gy: gy, peso: p, v: (0..<(gx * gy)).map { _ in azar.real() }))
        }
        func muestra(_ c: Capa, _ u: CGFloat, _ w: CGFloat) -> CGFloat {
            let fx = u * CGFloat(c.gx), fy = w * CGFloat(c.gy)
            let x0 = Int(fx) % c.gx, y0 = Int(fy) % c.gy, x1 = (x0 + 1) % c.gx, y1 = (y0 + 1) % c.gy
            var tx = fx - floor(fx), ty = fy - floor(fy)
            tx = tx * tx * (3 - 2 * tx); ty = ty * ty * (3 - 2 * ty)
            let a = c.v[y0 * c.gx + x0], b = c.v[y0 * c.gx + x1], cc = c.v[y1 * c.gx + x0], d = c.v[y1 * c.gx + x1]
            let arriba = a + (b - a) * tx, abajo = cc + (d - cc) * tx
            return arriba + (abajo - arriba) * ty
        }
        var px = [UInt8](repeating: 0, count: s * s * 4)
        for j in 0..<s {
            for i in 0..<s {
                let u = CGFloat(i) / CGFloat(s), w = CGFloat(j) / CGFloat(s)
                var n: CGFloat = 0
                for c in capas { n += muestra(c, u, w) * c.peso }
                var t = max(0, min(1, (n - 0.38) / 0.34)); t = t * t * (3 - 2 * t)
                let alfa = 0.3 + 0.7 * t
                let k = (j * s + i) * 4
                px[k] = UInt8((0.82 + 0.18 * t) * alfa * 255); px[k + 1] = UInt8((0.86 + 0.14 * t) * alfa * 255)
                px[k + 2] = UInt8((0.9 + 0.1 * t) * alfa * 255); px[k + 3] = UInt8(alfa * 255)
            }
        }
        let img = px.withUnsafeMutableBytes { b in
            CGContext(data: b.baseAddress, width: s, height: s, bitsPerComponent: 8, bytesPerRow: s * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
        cacheEspuma = img
        return img
    }

    private func luzDeEstado(_ id: String) -> SCNMaterial {
        let m = Mat.emisivo(.systemGreen, fuerza: 1.8); estado.append((id, m)); return m
    }

    /// Carguero portacontenedores (Sincronizar apps al otro Mac), tanquero de combustible (Proveedor de memoria) y
    /// lancha correo (Traductor de correos y Buzón de SMS), que entra y sale del puerto.
    private func montarBarcosDelPuerto() {
        // Carguero junto al muelle B, proa al mar
        _ = pieza("elem:puerto-carguero") { g in
            let b = SCNNode(); b.position = SCNVector3(20.6, 0, 100); g.addChildNode(b)
            b.addChildNode(casco(largo: 26, manga: 6, alto: 2.8, proa: 5, Mat.pbr(NSColor(Color(hex: "#1d3c5a")), rugosidad: 0.6), y: 0.1))
            b.addChildNode(casco(largo: 26.1, manga: 6.1, alto: 0.6, proa: 5, rojo, y: -0.9))
            b.addChildNode(nodo(SCNBox(width: 5.4, height: 0.15, length: 19, chamferRadius: 0), grisOscuro, y: 1.55, z: 0.5))
            var azar = Azar(semilla: 11)
            for fila in 0..<5 { for col in 0..<3 {
                let alto = 1 + Int(azar.real() * 2.99)
                for k in 0..<alto {
                    let m = contenedores[Int(azar.real() * CGFloat(contenedores.count - 1) + 0.5)]
                    b.addChildNode(nodo(SCNBox(width: 1.5, height: 1.0, length: 3.0, chamferRadius: 0.02), m, y: 2.15 + CGFloat(k) * 1.02, x: -1.65 + CGFloat(col) * 1.65, z: 8 - CGFloat(fila) * 3.2))
                }
            } }
            b.addChildNode(nodo(SCNBox(width: 5.2, height: 4.2, length: 3.2, chamferRadius: 0.05), blanco, y: 3.7, z: -10.4))      // puente de mando a popa
            b.addChildNode(nodo(SCNBox(width: 5.4, height: 0.7, length: 1.0, chamferRadius: 0), vidrio, y: 5.2, z: -8.8))
            b.addChildNode(nodo(SCNBox(width: 1.4, height: 2.2, length: 1.6, chamferRadius: 0.1), rojo, y: 6.6, z: -11.3))           // chimenea
            b.addChildNode(nodo(SCNCylinder(radius: 0.06, height: 3), acero, y: 7.3, z: -9.8))
            b.addChildNode(nodo(SCNSphere(radius: 0.22), luzDeEstado("sincmac"), y: 8.9, z: -9.8))
            b.addChildNode(nodo(SCNBox(width: 0.12, height: 0.12, length: 6, chamferRadius: 0), acero, y: 0.3, x: -3.4, z: 2))     // amarras
        }
        etiquetaEn(20.6, 100, y: 11, "Carguero · Sincronizar apps", icono: "shippingbox.fill", color: .systemBlue)
        // Tanquero junto al muelle A
        _ = pieza("elem:puerto-tanquero") { g in
            let b = SCNNode(); b.position = SCNVector3(-20.6, 0, 101); g.addChildNode(b)
            b.addChildNode(casco(largo: 24, manga: 5.5, alto: 2.6, proa: 4.5, Mat.pbr(NSColor(calibratedWhite: 0.13, alpha: 1), rugosidad: 0.55), y: 0.1))
            b.addChildNode(casco(largo: 24.1, manga: 5.6, alto: 0.6, proa: 4.5, rojo, y: -0.85))
            b.addChildNode(nodo(SCNBox(width: 5, height: 0.15, length: 17, chamferRadius: 0), Mat.pbr(NSColor(Color(hex: "#7c3b2a")), rugosidad: 0.8), y: 1.45, z: 1))
            for z: CGFloat in [6.5, 2.5, -1.5] { b.addChildNode(nodo(SCNSphere(radius: 1.4), blanco, y: 1.6, z: z)) }       // tanques
            for x: CGFloat in [-0.6, 0.6] {
                let tubo = nodo(SCNCylinder(radius: 0.12, height: 16), acero, y: 1.75, x: x, z: 1); tubo.eulerAngles.x = .pi / 2
                b.addChildNode(tubo)
            }
            b.addChildNode(nodo(SCNBox(width: 4.6, height: 3.6, length: 3, chamferRadius: 0.05), blanco, y: 3.3, z: -9.2))
            b.addChildNode(nodo(SCNBox(width: 4.8, height: 0.6, length: 0.9, chamferRadius: 0), vidrio, y: 4.6, z: -7.7))
            b.addChildNode(nodo(SCNBox(width: 1.2, height: 2, length: 1.4, chamferRadius: 0.1), Mat.pbr(NSColor(Color(hex: "#f2c230"))), y: 5.8, z: -10))
            b.addChildNode(nodo(SCNCylinder(radius: 0.06, height: 3), acero, y: 6.5, z: -8.6))
            b.addChildNode(nodo(SCNSphere(radius: 0.22), luzDeEstado("mem"), y: 8.1, z: -8.6))
            // Manguera de carga desde el muelle
            let m = nodo(SCNCylinder(radius: 0.14, height: 3.6), negro, y: 1.2, x: 3.4, z: 1); m.eulerAngles.z = 1.25
            b.addChildNode(m)
        }
        etiquetaEn(-20.6, 101, y: 10, "Tanquero · Proveedor de memoria", icono: "fuelpump.fill", color: .systemOrange)
        // Lancha correo: se arma en sus propias coordenadas (proa +z) porque navega
        let b = SCNNode()
        b.addChildNode(casco(largo: 6, manga: 2.1, alto: 1.1, proa: 1.6, blanco, y: -0.15))
        b.addChildNode(casco(largo: 6.05, manga: 2.15, alto: 0.25, proa: 1.6, Mat.pbr(NSColor(Color(hex: "#1f6fb2"))), y: -0.55))
        b.addChildNode(nodo(SCNBox(width: 1.5, height: 1.0, length: 2.0, chamferRadius: 0.15), Mat.pbr(NSColor(Color(hex: "#1f6fb2"))), y: 0.9, z: -0.4))
        b.addChildNode(nodo(SCNBox(width: 1.55, height: 0.4, length: 1.2, chamferRadius: 0.05), vidrio, y: 1.05, z: 0.15))
        b.addChildNode(nodo(SCNCylinder(radius: 0.04, height: 1.3), acero, y: 2.0, z: -0.8))
        b.addChildNode(nodo(SCNSphere(radius: 0.13), luzDeEstado("trad"), y: 2.7, z: -0.8))
        b.addChildNode(nodo(SCNSphere(radius: 0.11), luzDeEstado("sms"), y: 2.2, x: 0.5, z: -0.8))
        let plano = b.flattenedClone()
        lancha.addChildNode(plano)
        lancha.addChildNode(etiqueta("Lancha correo", y: 4, grande: false, icono: "envelope.fill", color: .systemIndigo))
        lancha.name = "elem:puerto-lancha"
        escena.rootNode.addChildNode(lancha)
        let el = estelaDe(lancha, manga: 2.1, largo: 14, popa: -3); el.raiz.opacity = 0; estelaLancha = el
        // Ruta cerrada. Amarre con proa a tierra en el canal entre el muelle A (borde en x −11,5) y los puestos libres
        // (x −8,4): el canal es más angosto que la eslora (6 m), así que no gira ahí: sale en marcha atrás hasta pasar la
        // punta del muelle (z 112), se detiene, vira en agua abierta, sale por la boca, da la vuelta y entra alineada.
        let pts: [(CGFloat, CGFloat, Bool, CGFloat)] = [
            (-9.8, 97, false, 8),            // amarre
            (-9.8, 116.5, true, 2.5),        // fin de la marcha atrás: vira aquí
            (-4, 124, false, 0), (4, 137, false, 0), (-6, 151, false, 0), (-18, 142, false, 0),
            (-13, 128, false, 0),
            (-9.8, 116.5, false, 0)]         // entra por el eje del canal
        rutaLancha = pts.map { (PuertoYFlota.w($0.0, $0.1), $0.2, $0.3) }
        let p0 = rutaLancha[0].p, pa = rutaLancha[rutaLancha.count - 1].p
        lancha.position = SCNVector3(p0.x, -0.1, p0.y)
        rumboLancha = atan2(p0.x - pa.x, p0.y - pa.y)
        lancha.eulerAngles.y = rumboLancha
    }

    private func etiquetaEn(_ lat: CGFloat, _ r: CGFloat, y: CGFloat, _ t: String, icono: String, color: NSColor) {
        let p = PuertoYFlota.w(lat, r), e = etiqueta(t, y: Double(y), grande: false, icono: icono, color: color)
        e.position = SCNVector3(p.x, y, p.y); escena.rootNode.addChildNode(e)
    }

    // MARK: Flota

    private func montarFlota() {
        // Portaaviones (proa +z): casco, cubierta de vuelo en ángulo, isla con radar, aviones y estela
        let b = SCNNode()
        b.addChildNode(casco(largo: 56, manga: 9, alto: 5, proa: 11, gris, y: 0.5))
        b.addChildNode(casco(largo: 56.2, manga: 9.2, alto: 0.6, proa: 11, rojo, y: -1.6))
        let cub = NSBezierPath()
        for (k, q) in [(-4.6, -29.0), (5.8, -29.0), (7.6, -8.0), (7.6, 22.0), (3.6, 30.5), (-3.2, 30.5), (-5.2, 18.0), (-11.5, 6.0), (-11.5, -6.0), (-6.5, -26.0)].enumerated() {
            let pt = NSPoint(x: q.0, y: q.1); if k == 0 { cub.move(to: pt) } else { cub.line(to: pt) }
        }
        cub.close()
        let cubierta = nodo(SCNShape(path: cub, extrusionDepth: 0.5), grisOscuro, y: 3.25); cubierta.eulerAngles.x = .pi / 2
        b.addChildNode(cubierta)
        // Marcas de cubierta: eje de despegue y pista en ángulo
        var z: CGFloat = -26
        while z < 28 { b.addChildNode(nodo(SCNBox(width: 0.2, height: 0.03, length: 1.6, chamferRadius: 0), blanco, y: 3.52, x: 1.5, z: z)); z += 3 }
        let angulada = nodo(SCNBox(width: 0.25, height: 0.03, length: 34, chamferRadius: 0), amarillo, y: 3.52, x: -3.5, z: -6); angulada.eulerAngles.y = -0.16
        b.addChildNode(angulada)
        // Isla de mando a estribor
        b.addChildNode(nodo(SCNBox(width: 2.4, height: 4, length: 8, chamferRadius: 0.05), gris, y: 5.5, x: 6.2, z: -4))
        b.addChildNode(nodo(SCNBox(width: 2.2, height: 1.8, length: 5, chamferRadius: 0.05), gris, y: 8.4, x: 6.2, z: -3.4))
        b.addChildNode(nodo(SCNBox(width: 2.3, height: 0.5, length: 5.1, chamferRadius: 0), vidrio, y: 8.9, x: 6.2, z: -3.4))
        b.addChildNode(nodo(SCNCylinder(radius: 0.15, height: 5), acero, y: 11.8, x: 6.2, z: -4))
        b.addChildNode(nodo(SCNSphere(radius: 0.3), luzAlmirante, y: 14.4, x: 6.2, z: -4))
        // Aviones en cubierta
        for (x, zz, g) in [(CGFloat(-2.5), CGFloat(20), CGFloat(0.4)), (-1, 15, 0.4), (3.5, 10, -0.5), (3.5, 5, -0.5), (-7.5, 0, 0.9), (-7.5, -4.5, 0.9)] {
            let j = SCNNode(); j.position = SCNVector3(x, 3.75, zz); j.eulerAngles.y = g
            j.addChildNode(nodo(SCNBox(width: 0.55, height: 0.45, length: 3.4, chamferRadius: 0.2), Mat.pbr(NSColor(Color(hex: "#8a939c")), rugosidad: 0.4, metal: 0.4)))
            j.addChildNode(nodo(SCNBox(width: 2.8, height: 0.08, length: 1.1, chamferRadius: 0.03), Mat.pbr(NSColor(Color(hex: "#8a939c")), rugosidad: 0.4, metal: 0.4), z: -0.3))
            j.addChildNode(nodo(SCNBox(width: 1.2, height: 0.06, length: 0.5, chamferRadius: 0.02), Mat.pbr(NSColor(Color(hex: "#8a939c")), rugosidad: 0.4, metal: 0.4), z: -1.5))
            j.addChildNode(nodo(SCNBox(width: 0.06, height: 0.6, length: 0.5, chamferRadius: 0.02), Mat.pbr(NSColor(Color(hex: "#8a939c")), rugosidad: 0.4, metal: 0.4), y: 0.3, z: -1.5))
            b.addChildNode(j)
        }
        Villa3D.Coordinador.hornear(b)
        portaaviones.addChildNode(b.flattenedClone())
        let radar = SCNNode(); radar.position = SCNVector3(6.2, 10.2, -1.6)
        radar.addChildNode(nodo(SCNBox(width: 2.4, height: 0.9, length: 0.1, chamferRadius: 0.02), acero))
        radar.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 4)))
        portaaviones.addChildNode(radar)
        portaaviones.addChildNode(etiqueta("Portaaviones Defensor", y: 18, grande: false, icono: "shield.lefthalf.filled", color: .systemBlue))
        portaaviones.name = "elem:flota-portaaviones"
        escena.rootNode.addChildNode(portaaviones)
        estelaDe(portaaviones, manga: 9, largo: 90, popa: -28)
        // Escolta: cada buque es un agente protector u optimizador
        let buques: [(id: String, nombre: String, icono: String, color: NSColor, lat: CGFloat, fwd: CGFloat, sub: Bool)] = [
            ("seg", "Fragata Antivirus", "lock.shield.fill", .systemRed, 0, 36, false),
            ("opt", "Destructor Optimizador", "speedometer", .systemOrange, -20, 8, false),
            ("salud", "Corbeta Salud del Mac", "heart.text.square.fill", .systemPink, 20, 8, false),
            ("resp", "Patrullero Respaldos", "externaldrive.fill.badge.timemachine", .systemGreen, 0, -34, false),
            ("red", "Submarino Vigía de red", "network", .systemTeal, -15, -22, true)]
        for e in buques {
            let n = SCNNode(); n.name = "elem:flota-\(e.id)"
            let c = SCNNode()
            if e.sub {
                let tubo = nodo(SCNCapsule(capRadius: 1.3, height: 18), grisOscuro, y: -0.4); tubo.eulerAngles.x = .pi / 2
                c.addChildNode(tubo)
                c.addChildNode(nodo(SCNBox(width: 0.9, height: 2.2, length: 3, chamferRadius: 0.4), grisOscuro, y: 1.6, z: 3))
                c.addChildNode(nodo(SCNCylinder(radius: 0.05, height: 1.6), acero, y: 3.4, z: 3.2))
                c.addChildNode(nodo(SCNSphere(radius: 0.18), luzDeEstado(e.id), y: 4.3, z: 3.2))
            } else {
                c.addChildNode(casco(largo: 22, manga: 3.6, alto: 3, proa: 6, gris, y: 0))
                c.addChildNode(casco(largo: 22.1, manga: 3.7, alto: 0.4, proa: 6, rojo, y: -1.3))
                c.addChildNode(nodo(SCNBox(width: 2.8, height: 2.4, length: 6.5, chamferRadius: 0.05), gris, y: 2.7, z: -1.5))
                c.addChildNode(nodo(SCNBox(width: 2.4, height: 1.2, length: 3, chamferRadius: 0.05), gris, y: 4.5, z: 0.4))
                c.addChildNode(nodo(SCNBox(width: 2.45, height: 0.4, length: 0.3, chamferRadius: 0), vidrio, y: 4.6, z: 1.9))
                c.addChildNode(nodo(SCNBox(width: 1.1, height: 1.6, length: 1.4, chamferRadius: 0.1), grisOscuro, y: 4.4, z: -3.6))      // chimenea
                c.addChildNode(nodo(SCNCylinder(radius: 0.08, height: 4.4), acero, y: 6.6, z: -0.9))
                c.addChildNode(nodo(SCNSphere(radius: 0.24), luzDeEstado(e.id), y: 9, z: -0.9))
                c.addChildNode(nodo(SCNBox(width: 1.3, height: 0.7, length: 1.6, chamferRadius: 0.2), gris, y: 1.85, z: 6.2))           // cañón
                let canon = nodo(SCNCylinder(radius: 0.08, height: 2.6), acero, y: 1.95, z: 8.2); canon.eulerAngles.x = .pi / 2
                c.addChildNode(canon)
                c.addChildNode(nodo(SCNBox(width: 2, height: 0.2, length: 2, chamferRadius: 0), grisOscuro, y: 1.6, z: 3.6))           // lanzadores
                c.addChildNode(nodo(SCNBox(width: 3, height: 0.05, length: 4, chamferRadius: 0), grisOscuro, y: 1.53, z: -8.2))        // helipuerto
            }
            Villa3D.Coordinador.hornear(c)
            n.addChildNode(c.flattenedClone())
            if !e.sub {
                let r = SCNNode(); r.position = SCNVector3(0, 7.3, -0.9)
                r.addChildNode(nodo(SCNBox(width: 1.5, height: 0.5, length: 0.08, chamferRadius: 0.02), acero))
                r.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 3)))
                n.addChildNode(r)
            }
            n.addChildNode(etiqueta(e.nombre, y: e.sub ? 7 : 12, grande: false, icono: e.icono, color: e.color))
            escena.rootNode.addChildNode(n)
            estelaDe(n, manga: e.sub ? 2.6 : 3.6, largo: e.sub ? 22 : 36, popa: e.sub ? -9 : -11)
            escoltas.append((n, e.lat, e.fwd))
        }
        for n in [portaaviones] + escoltas.map(\.n) { n.enumerateHierarchy { x, _ in x.castsShadow = false } }
        lancha.enumerateHierarchy { x, _ in x.castsShadow = false }
    }

    /// Barco más cercano a un punto del mar (los barcos se mueven: el clic no necesita ser exacto).
    func cercano(_ p: SCNVector3) -> SCNNode? {
        let lista: [(SCNNode, CGFloat)] = [(portaaviones, 30)] + escoltas.map { ($0.n, 13) } + [(lancha, 5)]
        return lista.map { ($0.0, hypot($0.0.position.x - p.x, $0.0.position.z - p.z) / $0.1) }
            .filter { $0.1 < 1 }.min { $0.1 < $1.1 }?.0
    }

    var posPortaaviones: SCNVector3 { portaaviones.position }
    var rumbo: CGFloat { rumboFlota }

    // MARK: Movimiento (cada cuadro)

    /// `alerta`: hay un incidente o una alarma en la villa → la flota acelera y cierra el cerco.
    func mover(_ dt: CGFloat, ahora: CFTimeInterval, alerta: Bool, agentes: [Agente]) {
        let t = CGFloat(ahora)
        // Flota: elipse frente a la isla; en alerta, más cerca y más rápido
        // Lejos de la costa (84 m): en alerta se acerca, pero el buque más cercano queda a unos 20 m de la playa.
        radioFlota += ((alerta ? 160 : 185) - radioFlota) * min(1, dt * 0.08)
        fase += dt * 2 * .pi / (alerta ? 150 : 280)
        let a = PuertoYFlota.flotaAng
        let T = CGPoint(x: cos(a), y: -sin(a)), R = CGPoint(x: sin(a), y: cos(a))
        let A: CGFloat = 40, B: CGFloat = 10
        let c = CGPoint(x: R.x * radioFlota + T.x * A * cos(fase) + R.x * B * sin(fase), y: R.y * radioFlota + T.y * A * cos(fase) + R.y * B * sin(fase))
        let d = CGPoint(x: -T.x * A * sin(fase) + R.x * B * cos(fase), y: -T.y * A * sin(fase) + R.y * B * cos(fase))
        rumboFlota = atan2(d.x, d.y)
        let F = CGPoint(x: sin(rumboFlota), y: cos(rumboFlota)), S = CGPoint(x: cos(rumboFlota), y: -sin(rumboFlota))
        let ola = sin(t * 0.7) * 0.06
        portaaviones.position = SCNVector3(c.x, -0.2 + ola, c.y)
        portaaviones.eulerAngles = SCNVector3(0, rumboFlota, sin(t * 0.5) * 0.008)
        for (k, e) in escoltas.enumerated() {
            let p = CGPoint(x: c.x + S.x * e.lat + F.x * e.fwd, y: c.y + S.y * e.lat + F.y * e.fwd)
            e.n.position = SCNVector3(p.x, -0.1 + sin(t * 0.9 + CGFloat(k)) * 0.08, p.y)
            e.n.eulerAngles = SCNVector3(0, rumboFlota, sin(t * 0.8 + CGFloat(k)) * 0.02)
        }
        // Lancha correo: recorre su circuito; frena antes de cada parada, arranca suave, sale del amarre en marcha
        // atrás y vira solo cuando está detenida en agua abierta (así nunca barre el muelle con la proa o la popa).
        let n = rutaLancha.count
        let ori = rutaLancha[tramo], dest = rutaLancha[(tramo + 1) % n]
        let largoT = max(0.1, hypot(dest.p.x - ori.p.x, dest.p.y - ori.p.y))
        let dir = atan2(dest.p.x - ori.p.x, dest.p.y - ori.p.y)
        var objetivo = rumboLancha
        if espera > 0 {
            espera -= dt; vLancha = 0
            if !dest.atras { objetivo = dir }                       // detenida: apunta la proa al próximo tramo
        } else {
            var v: CGFloat = dest.atras ? 1.2 : 3.2
            if dest.espera > 0 { v *= max(0.18, min(1, (largoT - sTramo) / 6)) }     // frena al llegar
            if ori.espera > 0 { v *= max(0.25, min(1, 0.25 + sTramo / 5)) }          // arranca suave
            vLancha = v
            sTramo += v * dt
            objetivo = dest.atras ? dir + .pi : dir
            if sTramo >= largoT { sTramo = 0; tramo = (tramo + 1) % n; espera = dest.espera }
        }
        var giro = objetivo - rumboLancha
        while giro > .pi { giro -= 2 * .pi }; while giro < -.pi { giro += 2 * .pi }
        rumboLancha += giro * min(1, dt * (espera > 0 ? 1.1 : 1.6))
        let a0 = rutaLancha[tramo].p, a1 = rutaLancha[(tramo + 1) % n].p
        let f = min(1, sTramo / max(0.1, hypot(a1.x - a0.x, a1.y - a0.y)))
        lancha.position = SCNVector3(a0.x + (a1.x - a0.x) * f, -0.1 + sin(t * 1.3) * 0.05, a0.y + (a1.y - a0.y) * f)
        lancha.eulerAngles = SCNVector3(-0.035 * vLancha / 3.2, rumboLancha, sin(t * 1.1) * 0.03)   // levanta la proa al acelerar
        if let e = estelaLancha {
            let haciaAtras = rutaLancha[(tramo + 1) % n].atras
            e.v = haciaAtras ? 0 : vLancha
            let meta: CGFloat = haciaAtras ? 0 : min(1, vLancha / 3.2)
            e.raiz.opacity += (meta - e.raiz.opacity) * min(1, dt * 0.8)
        }
        // Estelas: siguen la popa de cada barco sobre la superficie del mar y su espuma corre hacia atrás
        let velFlota = hypot(d.x, d.y) * 2 * .pi / (alerta ? 150 : 280)
        for e in estelas {
            guard let b = e.barco else { continue }
            if e !== estelaLancha { e.v = velFlota }
            let yaw = b.eulerAngles.y
            e.raiz.position = SCNVector3(b.position.x + sin(yaw) * e.zoff, -0.46, b.position.z + cos(yaw) * e.zoff)
            e.raiz.eulerAngles.y = yaw
            e.off += dt * max(0.3, e.v) / 7
            if e.off > 1000 { e.off -= 1000 }
            e.m.diffuse.contentsTransform = SCNMatrix4Mult(SCNMatrix4MakeScale(e.sx, e.sy, 1), SCNMatrix4MakeTranslation(0, e.off, 0))
        }
        // Luces de estado cada 3 s
        if ahora - ultimoEstado > 3 {
            ultimoEstado = ahora
            for (id, m) in estado {
                guard let ag = agentes.first(where: { $0.id == id }) else { m.emission.contents = NSColor.gray; m.diffuse.contents = NSColor.gray; continue }
                let col = ag.estado == "off" ? NSColor.gray : NSColor(ag.color)
                m.emission.contents = col; m.diffuse.contents = col
            }
            let col: NSColor = alerta ? .systemRed : .systemGreen
            luzAlmirante.emission.contents = col; luzAlmirante.diffuse.contents = col
        }
    }

    // MARK: Capitanía (edificio del barrio «puerto»)

    static func capitania(_ n: SCNNode, c: CGPoint, muro: SCNMaterial, techo: NSColor, nav: Navegacion) {
        let yaw = atan2(-c.x, -c.y)                       // frente hacia el palacio
        let h = SCNNode(); h.eulerAngles.y = yaw; n.addChildNode(h)
        let blanco = Mat.pbr(NSColor(calibratedWhite: 0.95, alpha: 1), rugosidad: 0.5)
        let azul = Mat.pbr(techo, rugosidad: 0.5)
        let vidrio = Mat.pbr(NSColor(Color(hex: "#26394d")), rugosidad: 0.12, metal: 0.55)
        vidrio.emission.contents = NSColor(calibratedRed: 1, green: 0.82, blue: 0.5, alpha: 1); vidrio.emission.intensity = 0.35
        h.addChildNode(nodo(SCNBox(width: 6, height: 0.3, length: 4.4, chamferRadius: 0), Mat.pbr(NSColor(calibratedWhite: 0.6, alpha: 1)), y: 0.15))
        h.addChildNode(nodo(SCNBox(width: 5.6, height: 3.2, length: 4, chamferRadius: 0.05), muro, y: 1.9))
        h.addChildNode(nodo(SCNBox(width: 5.8, height: 0.3, length: 4.2, chamferRadius: 0), azul, y: 3.6))
        for x: CGFloat in [-1.9, 0, 1.9] { h.addChildNode(nodo(SCNPlane(width: 1.1, height: 1.2), vidrio, y: 2.3, x: x, z: 2.02)) }
        h.addChildNode(nodo(SCNBox(width: 1.3, height: 1.9, length: 0.06, chamferRadius: 0), vidrio, y: 1.25, z: 2.03))     // puerta
        // Torre de control del puerto con sala vidriada
        h.addChildNode(nodo(SCNCylinder(radius: 0.9, height: 3.4), blanco, y: 5.4, x: 1.3, z: -0.6))
        h.addChildNode(nodo(SCNCylinder(radius: 1.25, height: 1.2), vidrio, y: 7.7, x: 1.3, z: -0.6))
        h.addChildNode(nodo(SCNCylinder(radius: 1.4, height: 0.25), azul, y: 8.4, x: 1.3, z: -0.6))
        h.addChildNode(nodo(SCNCylinder(radius: 0.05, height: 2), Mat.pbr(.gray, metal: 0.8), y: 9.5, x: 1.3, z: -0.6))
        // Letrero y mástil de señales
        let cartel = SCNMaterial(); cartel.diffuse.contents = Pizarra.letrero("CAPITANÍA"); cartel.emission.contents = Pizarra.letrero("CAPITANÍA"); cartel.emission.intensity = 0.5
        h.addChildNode(nodo(SCNBox(width: 3.4, height: 0.55, length: 0.06, chamferRadius: 0), cartel, y: 3.15, z: 2.06))
        h.addChildNode(nodo(SCNCylinder(radius: 0.05, height: 6), Mat.pbr(.gray, metal: 0.8), y: 3, x: -2.4, z: 2.6))
        let verga = nodo(SCNCylinder(radius: 0.03, height: 2), Mat.pbr(.gray, metal: 0.8), y: 5.3, x: -2.4, z: 2.6); verga.eulerAngles.z = .pi / 2
        h.addChildNode(verga)
        for (k, col) in [NSColor.systemRed, .systemYellow, .systemBlue].enumerated() {
            h.addChildNode(nodo(SCNBox(width: 0.5, height: 0.35, length: 0.02, chamferRadius: 0), Mat.pbr(col), y: 5.0 - CGFloat(k) * 0.4, x: -1.7, z: 2.6))
        }
        func mundo(_ x: CGFloat, _ z: CGFloat) -> CGPoint { CGPoint(x: c.x + x * cos(yaw) + z * sin(yaw), y: c.y - x * sin(yaw) + z * cos(yaw)) }
        let m0 = mundo(0, 0); nav.rect(m0.x, m0.y, 3.0, 2.2, yaw)
        let mm = mundo(-2.4, 2.6); nav.circulo(mm.x, mm.y, 0.1)
    }
}
