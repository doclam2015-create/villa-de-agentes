import SwiftUI
import SceneKit
import AppKit

// MARK: - Metro de la Villa: Línea Circular elevada
//
// Viaducto de doble vía que rodea toda la villa central sobre la costa (r 82 m, riel a 11 m: pasa sobre puentes,
// avenidas, el patio de contenedores y la playa). Pilas cada ≤ 20 m donde el suelo lo permite, nunca sobre avenidas,
// puentes ni delante del letrero que mira al mar. Nueve estaciones con el nombre del lugar al que llegan, cada una con
// una torre de acceso en tierra firme (escalera y ascensor), pasarela techada sobre las vías al andén exterior (con su
// ascensor), puertas de andén que abren solo con el tren detenido, barandas y veredas accesibles hasta el anillo
// periférico; estacionamientos en tierra donde se llega a pie sin cruzar edificios. Cuatro trenes de dos coches
// (dos por sentido) y un ramal a las Cocheras y Talleres sobre el mar. Todo se autoaudita en trabajo/auditoria-metro.txt.

@MainActor
final class MetroVilla {
    static let riel: CGFloat = 11, entreVias: CGFloat = 1.9
    static let largoCoche: CGFloat = 15, pasoCoche: CGFloat = 15.4, largoAnden: CGFloat = 36
    nonisolated static let radio: CGFloat = 82
    nonisolated static let rojo = NSColor(calibratedRed: 0.82, green: 0.19, blue: 0.17, alpha: 1)

    /// Estaciones en orden de ángulo creciente, con el nombre del lugar al que llegan.
    nonisolated static let estaciones: [(id: String, nombre: String, grados: CGFloat, estacionamiento: Bool, conecta: String)] = [
        ("naval", "BASE NAVAL", 6, true, "el puente a la Base Naval y la Gobernación Marítima"),
        ("regimiento", "REGIMIENTO", 47, true, "el puente al Regimiento del Ejército"),
        ("mall", "MALL SILICON", 84, false, "la entrada poniente del Mall Silicon y su estacionamiento público"),
        ("cerebro", "SEGUNDO CEREBRO", 122, false, "Segundo cerebro y La nube"),
        ("energia", "ISLA DE ENERGÍA", 149, false, "el puente a la Isla de Energía (centrales, agua potable, meteorología, red, residuos y observatorio) y las Cocheras del metro"),
        ("caleta", "CALETA · MARINA", 205, false, "el puente a la Caleta de pescadores y la Marina"),
        ("balneario", "BALNEARIO", 235, false, "el Balneario Villa y su playa"),
        ("trade", "VILLA TRADE", 265, true, "el puente a la isla Distrito: Villa Trade Center, Banco, Casino y Universidad"),
        ("aeropuerto", "AEROPUERTO · FACh", 290, true, "el puente al Aeropuerto Internacional y a la Base Aérea"),
        ("puerto", "PUERTO", 320, false, "la Capitanía del puerto y el Servicio de urgencias")]
    nonisolated static func ang(_ g: CGFloat) -> CGFloat { g * .pi / 180 }
    nonisolated static func posicion(_ k: Int) -> CGPoint { Islas.polar(radio, ang(estaciones[k].grados)) }

    /// Ramal a las cocheras y su nave sobre el mar (+z local hacia afuera). El ramal sale tangente de la vía exterior
    /// (r 83,9) a los 162°, justo después del andén de «Isla de Energía», describe un arco de 25 m de radio (el mayor que
    /// cabe antes de la Caleta; antes tenía tramos de 11 m) y entra recto y radial a la nave. Puntos cada ~1 m.
    nonisolated static let angCocheras: CGFloat = ang(175.5), rCocheras: CGFloat = 129, radioRamal: CGFloat = 25
    nonisolated static let ramalCtrl: [CGPoint] = {
        let r0: CGFloat = 83.9, phi = angCocheras - ang(162), rho = radioRamal
        let u = CGPoint(x: sin(angCocheras), y: cos(angCocheras)), w = CGPoint(x: cos(angCocheras), y: -sin(angCocheras))
        func mundo(_ a: CGFloat, _ b: CGFloat) -> CGPoint { CGPoint(x: u.x * a + w.x * b, y: u.y * a + w.y * b) }
        // marco (a: radial por las cocheras, b: tangente hacia ángulos mayores); recta de desvío, arco y recta radial
        let largoDesvio = max(0, (r0 * sin(phi) + rho * sin(phi) - rho) / cos(phi))
        var pts = [mundo(r0 * cos(phi), -r0 * sin(phi))]
        let p1 = (a: r0 * cos(phi) + largoDesvio * sin(phi), b: -r0 * sin(phi) + largoDesvio * cos(phi))
        if largoDesvio > 0.2 { pts.append(mundo(p1.a, p1.b)) }
        let c = (a: p1.a + rho * cos(phi), b: p1.b - rho * sin(phi)), giro = .pi / 2 - phi
        let n = Int(rho * giro)
        for k in 1...n { let q = phi + giro * CGFloat(k) / CGFloat(n); pts.append(mundo(c.a - rho * cos(q), c.b + rho * sin(q))) }
        var r = c.a + 1
        while r < rCocheras + 26 { pts.append(mundo(r, 0)); r += 1 }
        pts.append(mundo(rCocheras + 26, 0))
        return pts
    }()
    nonisolated static var centroCocheras: CGPoint { Islas.polar(rCocheras + 3, angCocheras) }

    /// Sin árboles bajo el viaducto ni en las cocheras.
    nonisolated static func libre(_ p: CGPoint) -> Bool {
        let r = hypot(p.x, p.y)
        if r > 73 && r < 92 { return false }
        let c = centroCocheras
        return hypot(p.x - c.x, p.y - c.y) > 34
    }

    struct Via {
        var pts: [CGPoint] = [], s: [CGFloat] = [], cerrada = false
        var largo: CGFloat { s.last ?? 0 }
        func eje(_ d0: CGFloat) -> (p: CGPoint, t: CGPoint) {
            var d = d0
            if cerrada { d = d.truncatingRemainder(dividingBy: largo); if d < 0 { d += largo } } else { d = min(max(d, 0), largo) }
            var lo = 0, hi = s.count - 1
            while hi - lo > 1 { let m = (lo + hi) / 2; if s[m] <= d { lo = m } else { hi = m } }
            let a = pts[lo], b = pts[hi], u = (d - s[lo]) / max(s[hi] - s[lo], 0.0001), len = max(hypot(b.x - a.x, b.y - a.y), 0.0001)
            return (CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u), CGPoint(x: (b.x - a.x) / len, y: (b.y - a.y) / len))
        }
        func cercano(_ q: CGPoint) -> CGFloat {
            s[pts.indices.min { hypot(pts[$0].x - q.x, pts[$0].y - q.y) < hypot(pts[$1].x - q.x, pts[$1].y - q.y) }!]
        }
    }

    final class Tren {
        let via: Int
        var coches: [SCNNode] = [], puertas: [[(hoja: SCNNode, z: CGFloat, lado: CGFloat)]] = []
        var faros: [(blanco: SCNMaterial, rojo: SCNMaterial)] = []
        var s: CGFloat = 0, v: CGFloat = 0, dir: CGFloat = 1, destino = 0, espera: CGFloat = 0, apertura: CGFloat = 0
        var lat: CGFloat = 0
        init(via: Int) { self.via = via }
    }

    /// Paso de la ruta de un pasajero: caminar a un punto, desaparecer unos segundos y reaparecer en otro (ascensor,
    /// subir al tren), esperar en el andén o terminar.
    enum Paso { case ir(SCNVector3), salto(CGFloat, SCNVector3), esperar, fin }
    final class Pasajero {
        let p: Persona
        var ruta: [Paso] = [], activo = false, oculto = false, reloj: CGFloat = 0, estacion = 0, lado: CGFloat = 1
        init(_ p: Persona) { self.p = p }
        var esperando: Bool { if case .esperar? = ruta.first { return true }; return false }
    }

    let escena: SCNScene, nav: Navegacion
    private(set) var luces: [SCNMaterial] = []
    private(set) var vias: [Via] = []          // 0: Línea Circular, 1: ramal a cocheras
    private(set) var paradas: [CGFloat] = []
    private var trenes: [Tren] = []
    private var pasajeros: [Pasajero] = []
    private var llegadas: [CGFloat] = []       // reloj de la próxima persona que llega a cada estación
    private var estacionados: [[(p: CGPoint, d: CGFloat)]] = [] // junto a cada auto estacionado (de ahí salen y ahí vuelven)
    private var puertasAnden: [[CGFloat: [(hoja: SCNNode, base: SCNVector3, t: CGPoint, s: CGFloat)]]] = []   // puertas de andén por estación y lado
    nonisolated static let latVereda: CGFloat = 12.1, latCalle: CGFloat = 17.8      // vereda entre torre y anillo, y borde del anillo
    private var latParque: [CGFloat] = []    // por estación: franja de la vereda que llega al estacionamiento
    private var salidas: [CGFloat] = []      // por estación: dónde la vereda de la torre baja al anillo (evita obstáculos)
    private var torres: [[CGFloat: (fin: CGFloat, puerta: CGPoint)]] = []   // por estación y lado (+1 interior, −1 exterior)
    private var azar = Azar(semilla: 29)
    private var informe: [String] = []          // autoauditoría: trabajo/auditoria-metro.txt

    init(escena: SCNScene, nav: Navegacion) {
        self.escena = escena; self.nav = nav
        var anillo = Via(); anillo.cerrada = true
        let n = Int(2 * .pi * MetroVilla.radio)
        for i in 0...n { anillo.pts.append(Islas.polar(MetroVilla.radio, 2 * .pi * CGFloat(i) / CGFloat(n))) }
        var ramal = Via(); ramal.pts = MetroVilla.ramalCtrl
        for i in [0, 1] {
            var v = i == 0 ? anillo : ramal
            v.s = [0]
            for j in 1..<v.pts.count { v.s.append(v.s[j - 1] + hypot(v.pts[j].x - v.pts[j - 1].x, v.pts[j].y - v.pts[j - 1].y)) }
            vias.append(v)
        }
        paradas = MetroVilla.estaciones.indices.map { vias[0].cercano(MetroVilla.posicion($0)) }
    }

    func eje(_ v: Int, _ d: CGFloat) -> (p: CGPoint, t: CGPoint) { vias[v].eje(d) }
    /// Normal del eje: en la Línea Circular apunta hacia el centro de la villa (lado +1 = andén interior).
    private func normal(_ t: CGPoint) -> CGPoint { CGPoint(x: t.y, y: -t.x) }
    private func punto(_ v: Int, _ d: CGFloat, _ lat: CGFloat, _ y: CGFloat) -> SCNVector3 {
        let (p, t) = eje(v, d), n = normal(t); return SCNVector3(p.x + n.x * lat, y, p.y + n.y * lat)
    }

    /// Lejos de puentes, avenidas, acceso y explanada del puerto (para pilas, torres y estacionamientos).
    nonisolated static func cerca(_ a: CGFloat, _ b: CGFloat, _ r: CGFloat, _ ancho: CGFloat) -> Bool {
        var d = a - b
        while d > .pi { d -= 2 * .pi }; while d < -.pi { d += 2 * .pi }
        return abs(d) * r < ancho
    }
    nonisolated static func sueloLibre(_ p: CGPoint, margen: CGFloat = 2.5, pilar: Bool = false) -> Bool {
        for dx in [-margen, 0, margen] { for dz in [-margen, 0, margen] where Islas.alturaPuente(CGPoint(x: p.x + dx, y: p.y + dz)) > 0 { return false } }
        let r = hypot(p.x, p.y), a = atan2(p.x, p.y)
        for b in [Islas.angAero, Islas.angDist, Islas.angDef, Islas.angNav, Islas.angCaleta, Islas.angEner, Villa3D.Coordinador.acceso] {
            var d = a - b
            while d > .pi { d -= 2 * .pi }; while d < -.pi { d += 2 * .pi }
            if abs(d) * r < 5.5 + margen && r > 58 { return false }
        }
        if pilar && r > 64 && cerca(a, 0.34, r, 12) { return false }     // el letrero de 0,34 mira al mar: ninguna pila delante
        let pa = PuertoYFlota.ang, rp = p.x * sin(pa) + p.y * cos(pa), lp = p.x * cos(pa) - p.y * sin(pa)
        if rp > 60 && rp < 132 && abs(lp) < 42 {         // en la explanada: pilas solo entre la calle central y los contenedores, o fuera de ellos
            if pilar { return (abs(lp) > 6 && abs(lp) < 15) || abs(lp) > 32 }
            return rp < 76.5 && abs(lp) > 7 + margen          // en tierra, antes de la explanada (la capitanía la marca la navegación)
        }
        return true
    }

    /// Tierra firme sin edificios, calles ni la Gobernación Marítima, para torres y estacionamientos.
    private func tierraLibre(_ q: CGPoint, margen: CGFloat) -> Bool {
        let r = hypot(q.x, q.y)
        guard r >= 64.5, MetroVilla.sueloLibre(q, margen: margen), nav.libre(q) else { return false }
        let a = atan2(q.x, q.y)
        if MetroVilla.cerca(a, Islas.angNav + 11 / 68, r, 8) { return false }                   // Gobernación Marítima
        if MetroVilla.cerca(a, .pi, r, 14) { return false }                                      // delante del letrero que mira a la villa
        if r > 74.5 && (MetroVilla.cerca(a, Islas.angBalneario, r, 18) || MetroVilla.cerca(a, Islas.angMarina, r, 10)) { return false }   // bajadas a la playa y a la marina
        return true
    }

    // MARK: Construcción

    func montar(_ r: SCNNode) {
        let hormigon = Mat.pbr(NSColor(calibratedWhite: 0.72, alpha: 1), rugosidad: 0.9)
        let hormigonOsc = Mat.pbr(NSColor(calibratedWhite: 0.55, alpha: 1), rugosidad: 0.92)
        let placa = Mat.pbr(NSColor(calibratedWhite: 0.32, alpha: 1), rugosidad: 0.95)
        let acero = Mat.pbr(NSColor(calibratedWhite: 0.62, alpha: 1), rugosidad: 0.3, metal: 0.9)
        let cobre = Mat.pbr(NSColor(calibratedRed: 0.45, green: 0.3, blue: 0.2, alpha: 1), rugosidad: 0.4, metal: 0.8)
        let poste = Mat.pbr(NSColor(calibratedWhite: 0.45, alpha: 1), rugosidad: 0.5, metal: 0.6)
        let R = MetroVilla.riel, ev = MetroVilla.entreVias
        var curva: CGFloat = 0       // giro (rad) entre dovelas contiguas: alarga cada pieza para cerrar la cuña del lado exterior
        func caja(_ w: CGFloat, _ h: CGFloat, _ l: CGFloat, _ m: SCNMaterial, _ p: CGPoint, _ t: CGPoint, lat: CGFloat, y: CGFloat) {
            let n = normal(t), q = CGPoint(x: p.x + n.x * lat, y: p.y + n.y * lat)
            let b = nodo(SCNBox(width: w, height: h, length: l + (abs(lat) + w / 2) * curva, chamferRadius: 0), m, y: y, x: q.x, z: q.y)
            b.eulerAngles.y = atan2(t.x, t.y); r.addChildNode(b)
        }
        func enEstacion(_ d: CGFloat) -> Bool {
            let L = vias[0].largo
            return paradas.contains { var x = abs($0 - d).truncatingRemainder(dividingBy: L); x = min(x, L - x); return x < MetroVilla.largoAnden / 2 }
        }
        let finLosa = MetroVilla.rCocheras - 24 + 0.5
        let inicioRamal = vias[1].s[vias[1].pts.firstIndex { hypot($0.x, $0.y) > 85.8 } ?? 0]
        // Viaducto (Línea Circular y ramal) por dovelas de 3 m (1 m en el ramal, que es curvo): cajón, losa, vía en placa,
        // rieles y pretiles; cada pieza se alarga lo justo para que no queden quiebres en la curva
        for v in 0..<2 {
            let L = vias[v].largo, A = MetroVilla.largoAnden
            let bordes = v == 0 ? paradas.flatMap { [$0 - A / 2, $0 + A / 2].map { ($0 + L).truncatingRemainder(dividingBy: L) } } : []
            var cortes = Array(stride(from: 0 as CGFloat, to: L, by: v == 0 ? 3 : 1)).filter { c in !bordes.contains { abs($0 - c) < 0.8 } } + bordes
            cortes.sort(); cortes.append(L)
            for i in 0..<(cortes.count - 1) {
                let d = cortes[i], d1 = cortes[i + 1]
                guard d1 - d > 0.05 else { continue }
                let a = eje(v, d).p, b = eje(v, d1).p
                let m = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), len = hypot(b.x - a.x, b.y - a.y)
                let t = CGPoint(x: (b.x - a.x) / max(len, 0.001), y: (b.y - a.y) / max(len, 0.001)), l = len + 0.06
                let ta = eje(v, d - 0.5).t, tb = eje(v, d1 + 0.5).t
                curva = abs(atan2(ta.x * tb.y - ta.y * tb.x, ta.x * tb.x + ta.y * tb.y)) / 2
                if v == 0 {
                    let est = enEstacion((d + d1) / 2), grados = atan2(m.x, m.y) * 180 / .pi
                    caja(4.4, 1.7, l, hormigon, m, t, lat: 0, y: R - 1.45)                 // cajón pretensado
                    caja(est ? 13.4 : 8.8, 0.38, l, hormigon, m, t, lat: 0, y: R - 0.41)   // losa superior
                    for s in [-ev, ev] {
                        caja(2.5, 0.2, l, placa, m, t, lat: s, y: R - 0.12)
                        for k in [-0.7175, 0.7175] as [CGFloat] { caja(0.075, 0.17, l, acero, m, t, lat: s + k, y: R + 0.06) }
                    }
                    let desvio = grados > 160 && grados < 175             // el ramal sale por la vía exterior: sin pretil ahí
                    if !est { for s in [-4.25, 4.25] as [CGFloat] where !(desvio && s < 0) { caja(0.3, 1.05, l, hormigonOsc, m, t, lat: s, y: R + 0.1) } }
                } else if hypot(m.x, m.y) < finLosa {                        // ramal de vía única hasta la losa de las cocheras
                    if d >= inicioRamal {
                        caja(2.6, 1.5, l, hormigon, m, t, lat: 0, y: R - 1.35)
                        caja(5.2, 0.38, l, hormigon, m, t, lat: 0, y: R - 0.41)
                        for s in [-2.45, 2.45] as [CGFloat] { caja(0.25, 1.0, l, hormigonOsc, m, t, lat: s, y: R + 0.1) }
                        caja(2.5, 0.2, l, placa, m, t, lat: 0, y: R - 0.13)
                    }
                    for k in [-0.7175, 0.7175] as [CGFloat] { caja(0.075, 0.17, l, acero, m, t, lat: k, y: R + 0.065) }
                }
            }
        }
        curva = 0
        // Catenaria de la Línea Circular: postes centrales cada ~18 m, ménsulas e hilo de contacto
        do {
            let L = vias[0].largo, pasos = Int(L / 18)
            var previo: (CGPoint, CGPoint)? = nil
            for k in 0...pasos {
                let (p, t) = eje(0, CGFloat(k) / CGFloat(pasos) * L), n = normal(t)
                if k < pasos {
                    r.addChildNode(nodo(SCNCylinder(radius: 0.13, height: 6.2), poste, y: R + 2.9, x: p.x, z: p.y))
                    caja(4.6, 0.12, 0.12, poste, p, t, lat: 0, y: R + 5.75)
                    for s in [-ev, ev] { caja(0.05, 0.4, 0.05, poste, p, t, lat: s, y: R + 5.5) }
                }
                if let (pa, ta) = previo {
                    for s in [-ev, ev] {
                        let na = normal(ta), q0 = CGPoint(x: pa.x + na.x * s, y: pa.y + na.y * s), q1 = CGPoint(x: p.x + n.x * s, y: p.y + n.y * s)
                        let len = hypot(q1.x - q0.x, q1.y - q0.y), tt = CGPoint(x: (q1.x - q0.x) / len, y: (q1.y - q0.y) / len)
                        let mm = CGPoint(x: (q0.x + q1.x) / 2, y: (q0.y + q1.y) / 2)
                        caja(0.03, 0.03, len, cobre, mm, tt, lat: 0, y: R + 5.3)
                        caja(0.02, 0.02, len, cobre, mm, tt, lat: 0, y: R + 5.75)
                    }
                }
                previo = (p, t)
            }
        }
        // Pilas en martillo cada ~18 m (también bajo las estaciones); se saltan puentes, avenidas, acceso y puerto
        for v in 0..<2 {
            let L = vias[v].largo
            // Pilas cada ≤ 20 m: desde la última, la posición libre más lejana dentro de 20 m (o la primera libre si no hay)
            let d0p: CGFloat = v == 0 ? 4 : inicioRamal + 4
            var libres: [CGFloat] = []
            for x in stride(from: d0p, to: v == 0 ? d0p + L - 6 : L, by: 1.5) {
                let p = eje(v, x).p
                if v == 1 && hypot(p.x, p.y) > finLosa - 1 { break }
                if MetroVilla.sueloLibre(p, pilar: true) { libres.append(x) }
            }
            var elegidas: [CGFloat] = []
            if let pri = libres.first {
                elegidas = [pri]
                while let u = elegidas.last {
                    let dentro = libres.filter { $0 > u + 6 && $0 <= u + 20 }
                    guard let sig = dentro.last ?? libres.first(where: { $0 > u + 20 }) else { break }
                    elegidas.append(sig)
                }
            }
            var pilas: [CGFloat] = []
            for dq in elegidas {
                let (p, t) = eje(v, dq)
                do {
                    if !nav.libre(p) { informe.append(String(format: "OBSTÁCULO  pila sobre algo ocupado en (x %.1f, z %.1f)", p.x, p.y)) }
                    nav.circulo(p.x, p.y, v == 0 ? 1.6 : 1.2); pilas.append(dq)
                    let alto = R - 2.3 + 0.5
                    r.addChildNode(nodo(SCNCylinder(radius: v == 0 ? 1.0 : 0.75, height: alto), hormigon, y: -0.5 + alto / 2, x: p.x, z: p.y))
                    caja(v == 0 ? 6.4 : 3.6, 1.0, 2.0, hormigon, p, t, lat: 0, y: R - 2.75)
                    r.addChildNode(nodo(SCNCylinder(radius: 1.5, height: 0.6), hormigonOsc, y: -0.35, x: p.x, z: p.y))
                }
            }
            if v == 0, let pri = pilas.first, let ult = pilas.last {
                let vanos = zip(pilas, pilas.dropFirst() + [pri + L]).map { $1 - $0 }
                informe.append(String(format: "Línea Circular: %d pilas, vano máximo %.0f m", pilas.count, vanos.max() ?? 0))
                for (k, w) in vanos.enumerated() where w > 30 {
                    let p = eje(0, pilas[k] + w / 2).p
                    informe.append(String(format: "VANO LARGO  %.0f m en (x %.1f, z %.1f)", w, p.x, p.y))
                }
                _ = ult
            }
        }
        estacionados = MetroVilla.estaciones.map { _ in [] }
        salidas = paradas; latParque = paradas.map { _ in MetroVilla.latVereda }
        for k in MetroVilla.estaciones.indices { montarEstacion(r, k, hormigon, acero) }
        for k in MetroVilla.estaciones.indices { montarEstacionamiento(r, k) }
        montarCocheras(r, hormigon, acero, placa)
        // Trenes en servicio: dos por sentido, repartidos en la línea
        for (k, dir) in [(0, 1), (4, 1), (2, -1), (7, -1)] as [(Int, CGFloat)] {
            let tren = armarTren(via: 0, servicio: "L1  CIRCULAR")
            tren.dir = dir; tren.lat = dir * ev; tren.s = paradas[k]; tren.destino = k; tren.espera = CGFloat(3 + trenes.count * 4)
            trenes.append(tren); ubicar(tren)
        }
        // Pasajeros: personas que se reutilizan
        for i in 0..<110 {
            let p = Persona.pasajero(i); p.raiz.isHidden = true; escena.rootNode.addChildNode(p.raiz)
            pasajeros.append(Pasajero(p))
        }
        llegadas = MetroVilla.estaciones.indices.map { _ in CGFloat(azar.real() * 4) }
        try? (informe.joined(separator: "\n") + "\n").write(toFile: Almacen.carpetaLocal + "/trabajo/auditoria-metro.txt", atomically: true, encoding: .utf8)
        for k in MetroVilla.estaciones.indices { for lado in [-1, 1] as [CGFloat] { for _ in 0..<2 { esperar(k, lado, inicial: true) } } }
    }

    private func montarEstacion(_ r: SCNNode, _ k: Int, _ hormigon: SCNMaterial, _ acero: SCNMaterial) {
        let R = MetroVilla.riel, A = MetroVilla.largoAnden, d0 = paradas[k], e = MetroVilla.estaciones[k]
        let piso = Mat.pbr(NSColor(calibratedWhite: 0.82, alpha: 1), rugosidad: 0.6)
        let tactil = Mat.pbr(NSColor(Color(hex: "#f2c200")), rugosidad: 0.7)
        let vidrio = Mat.pbr(NSColor(calibratedRed: 0.75, green: 0.88, blue: 0.95, alpha: 0.28), rugosidad: 0.05)
        vidrio.transparency = 0.3; vidrio.isDoubleSided = true; vidrio.writesToDepthBuffer = false
        let techo = Mat.pbr(NSColor(calibratedWhite: 0.93, alpha: 1), rugosidad: 0.4, metal: 0.2)
        let banda = Mat.pbr(MetroVilla.rojo, rugosidad: 0.5)
        let banco = Mat.pbr(NSColor(Color(hex: "#7a5532")), rugosidad: 0.6)
        let luz = Mat.emisivo(NSColor(calibratedRed: 0.95, green: 0.97, blue: 1, alpha: 1), fuerza: 1); luces.append(luz)
        let cartel = Villa3D.Coordinador.mCartel(e.nombre, MetroVilla.rojo, ancho: 900, brillo: 0.7)
        let marco = Mat.pbr(NSColor(calibratedWhite: 0.2, alpha: 1), rugosidad: 0.4, metal: 0.6)
        let asfalto = Mat.pbr(NSColor(calibratedWhite: 0.16, alpha: 1), rugosidad: 0.95), linea = Mat.pbr(.white, rugosidad: 0.6)
        func caja(_ w: CGFloat, _ h: CGFloat, _ l: CGFloat, _ m: SCNMaterial, d: CGFloat, lat: CGFloat, y: CGFloat) {
            let (p, t) = eje(0, d), n = normal(t), q = CGPoint(x: p.x + n.x * lat, y: p.y + n.y * lat)
            let b = nodo(SCNBox(width: w, height: h, length: l, chamferRadius: 0), m, y: y, x: q.x, z: q.y)
            b.eulerAngles.y = atan2(t.x, t.y); r.addChildNode(b)
        }
        func punto2(_ d: CGFloat, _ lat: CGFloat) -> CGPoint { let (p, t) = eje(0, d), n = normal(t); return CGPoint(x: p.x + n.x * lat, y: p.y + n.y * lat) }
        // Una sola torre de acceso (escalera y ascensor), en tierra del lado de la villa. Al andén exterior se llega por
        // una pasarela techada sobre las vías (más alta que la catenaria) y un ascensor en ese andén: nada queda en el agua.
        let tl: CGFloat = 9.4, Ht = R + 10
        func cabe(_ fin: CGFloat) -> Bool {
            for o in [-3.6, -2.1, 0, 2.1, 3.6] as [CGFloat] { for l in [-1.6, 0, 1.6] as [CGFloat] {
                if !tierraLibre(punto2(d0 + fin + o, tl + l), margen: 1.5) { return false }
            } }
            return true
        }
        func caminoLibre(_ fin: CGFloat) -> Bool {             // vereda de la puerta al anillo sin obstáculos
            let dp = d0 + fin - (fin > 0 ? 1 : -1) * 3.2
            return stride(from: 11.4 as CGFloat, through: MetroVilla.latCalle, by: 0.8).allSatisfy {
                let q = punto2(dp, $0); return MetroVilla.sueloLibre(q, margen: 0) && nav.libre(q) }
        }
        let fines = ([15, -15, 11, -11, 7, -7, 3, -3] as [CGFloat]).filter(cabe)
        let finT = fines.first { caminoLibre($0) && (!e.estacionamiento || lugarEstacionamiento(k, fin: $0) != nil) }
            ?? fines.first { caminoLibre($0) } ?? fines.first
        var lados: [CGFloat: (fin: CGFloat, puerta: CGPoint)] = [:]
        if let fin = finT {
            let (_, t) = eje(0, d0 + fin), q = punto2(d0 + fin, tl), sg: CGFloat = fin > 0 ? 1 : -1, yaw = atan2(t.x, t.y)
            let torre = nodo(SCNBox(width: 3.2, height: Ht + 0.5, length: 4.2, chamferRadius: 0.05), hormigon, y: (Ht - 0.5) / 2, x: q.x, z: q.y)
            torre.eulerAngles.y = yaw; r.addChildNode(torre)
            for y in stride(from: 1.6 as CGFloat, to: Ht - 1.5, by: 3.2) { caja(0.06, 1.0, 3.0, vidrio, d: d0 + fin, lat: tl - 1.62, y: y) }
            caja(1.4, Ht + 0.5, 1.4, vidrio, d: d0 + fin + sg * 2.9, lat: tl, y: (Ht - 0.5) / 2)       // cubo del ascensor, apoyado en el suelo
            caja(1.36, 2.4, 1.36, acero, d: d0 + fin + sg * 2.9, lat: tl, y: R + 2.3)
            caja(3.0, 0.3, 2.6, piso, d: d0 + fin, lat: tl - 2.3, y: R + 0.95)                       // pasarela al andén interior (a nivel)
            caja(3.25, 0.5, 4.3, banda, d: d0 + fin, lat: tl, y: Ht - 0.25)
            caja(0.9, 0.9, 0.06, Villa3D.Coordinador.mCartel("M", MetroVilla.rojo, ancho: 200, brillo: 0.9), d: d0 + fin - sg * 2.14, lat: tl, y: Ht - 1.6)
            caja(1.6, 2.2, 0.06, marco, d: d0 + fin - sg * 2.13, lat: tl, y: 1.1)                     // puerta de calle
            caja(2.2, 0.32, 0.06, cartel, d: d0 + fin - sg * 2.14, lat: tl, y: 2.6)
            // Pasarela techada sobre ambas vías, desde la torre hasta el ascensor del andén exterior
            let a0: CGFloat = -6.35, a1 = tl - 1.6, mid = (a0 + a1) / 2, largo = a1 - a0
            caja(largo, 0.3, 2.6, hormigon, d: d0 + fin, lat: mid, y: R + 7.0)
            caja(largo, 0.1, 2.62, banda, d: d0 + fin, lat: mid, y: R + 6.82)
            for s in [-1.25, 1.25] as [CGFloat] {
                caja(largo, 2.3, 0.06, vidrio, d: d0 + fin + s, lat: mid, y: R + 8.3)
                caja(largo, 0.12, 0.12, marco, d: d0 + fin + s, lat: mid, y: R + 9.45)
            }
            caja(largo + 0.4, 0.18, 3.0, techo, d: d0 + fin, lat: mid, y: R + 9.6)
            caja(1.4, 8.6, 1.4, vidrio, d: d0 + fin, lat: -5.65, y: R + 5.4)                          // ascensor del andén exterior
            caja(1.36, 2.4, 1.36, acero, d: d0 + fin, lat: -5.65, y: R + 2.3)
            caja(1.6, 0.3, 1.6, banda, d: d0 + fin, lat: -5.65, y: R + 9.85)
            let puerta = punto2(d0 + fin - sg * 3.2, tl)
            nav.rect(q.x, q.y, 1.7, 2.2, yaw)
            let ce = punto2(d0 + fin + sg * 2.9, tl); nav.rect(ce.x, ce.y, 0.8, 0.8, yaw)
            for l in [-1, 1] as [CGFloat] { lados[l] = (fin, puerta) }
            informe.append("Estación \(e.nombre): torre de acceso en tierra (extremo \(fin > 0 ? "+" : "−")), pasarela sobre las vías al andén exterior")
        } else {
            informe.append("SIN ACCESO  estación \(e.nombre): no cabe la torre en tierra")
        }
        torres.append(lados)
        func enPasarela(_ d: CGFloat) -> Bool { finT.map { abs(d - (d0 + $0)) < 3 } ?? false }
        // Andenes laterales: piso, borde táctil, mampara, marquesina y luminarias (la mampara interior se abre a la pasarela)
        var d = d0 - A / 2
        while d < d0 + A / 2 - 0.01 {
            let dm = d + 1.5
            for lado in [-1, 1] as [CGFloat] {
                caja(3.1, 1.35, 3.0, piso, d: dm, lat: lado * 5.05, y: R + 0.425)          // andén lateral (borde a 3,5 m del eje)
                caja(0.5, 0.012, 3.0, tactil, d: dm, lat: lado * 3.75, y: R + 1.106)
                caja(0.06, 0.05, 3.0, marco, d: dm, lat: lado * 3.53, y: R + 1.08)
                if !(lado > 0 && enPasarela(dm)) {
                    caja(0.04, 2.4, 3.0, vidrio, d: dm, lat: lado * 6.55, y: R + 2.3)        // mampara contra el viento
                    caja(0.1, 0.1, 3.0, marco, d: dm, lat: lado * 6.55, y: R + 3.5)
                }
                caja(4.1, 0.18, 3.0, techo, d: dm, lat: lado * 4.95, y: R + 4.75)          // marquesina
                caja(4.1, 0.08, 3.0, banda, d: dm, lat: lado * 4.95, y: R + 4.62)
                caja(0.5, 0.04, 2.6, luz, d: dm, lat: lado * 4.6, y: R + 4.6)
            }
            d += 3
        }
        let vidrioP = Mat.pbr(NSColor(calibratedRed: 0.8, green: 0.9, blue: 0.95, alpha: 0.35), rugosidad: 0.05)
        vidrioP.transparency = 0.4; vidrioP.isDoubleSided = true; vidrioP.writesToDepthBuffer = false
        let medio = MetroVilla.pasoCoche / 2
        let aberturas = ([-4.6, -0.6, 3.4] as [CGFloat]).flatMap { [medio + $0, -medio - $0] }.sorted()   // frente a las puertas del tren detenido
        var hojasK: [CGFloat: [(hoja: SCNNode, base: SCNVector3, t: CGPoint, s: CGFloat)]] = [:]
        for lado in [-1, 1] as [CGFloat] {
            var a = -A / 2
            for o in aberturas + [A / 2 + 1] {
                var x = a
                while x < o - 1 - 0.05 {                                      // paños fijos de 1,5 m de alto
                    let x1 = min(x + 3, o - 1)
                    caja(0.05, 1.45, x1 - x, vidrioP, d: d0 + (x + x1) / 2, lat: lado * 3.62, y: R + 1.1 + 0.73)
                    caja(0.1, 0.08, x1 - x, marco, d: d0 + (x + x1) / 2, lat: lado * 3.62, y: R + 2.6)
                    x = x1
                }
                if o <= A / 2 {
                    for s in [-1, 1] as [CGFloat] {
                        caja(0.12, 1.6, 0.12, marco, d: d0 + o + s * 1.06, lat: lado * 3.62, y: R + 1.9)
                        let (p, t) = eje(0, d0 + o + s * 0.5), n = normal(t)
                        let base = SCNVector3(p.x + n.x * lado * 3.7, R + 1.1 + 0.73, p.y + n.y * lado * 3.7)
                        let h = nodo(SCNBox(width: 0.04, height: 1.45, length: 1.0, chamferRadius: 0), vidrioP)
                        h.position = base; h.eulerAngles.y = atan2(t.x, t.y); r.addChildNode(h)
                        h.addChildNode(nodo(SCNBox(width: 0.06, height: 0.06, length: 1.0, chamferRadius: 0), banda, y: 0.2))
                        hojasK[lado, default: []].append((h, base, t, s))
                    }
                }
                a = o + 1
            }
            for y in [R + 1.6, R + 2.2] as [CGFloat] {                          // baranda en cada extremo del andén
                for s in [-1, 1] as [CGFloat] { caja(3.1, 0.06, 0.06, tactil, d: d0 + s * (A / 2 - 0.1), lat: lado * 5.05, y: y) }
            }
            for s in [-1, 1] as [CGFloat] { for l in [3.6, 5.05, 6.5] as [CGFloat] { caja(0.07, 1.1, 0.07, marco, d: d0 + s * (A / 2 - 0.1), lat: lado * l, y: R + 1.65) } }
        }
        puertasAnden.append(hojasK)
        if let fin = finT {                                                     // barandas de la pasarela a nivel
            for s in [-1, 1] as [CGFloat] { caja(1.3, 1.1, 0.05, vidrioP, d: d0 + fin + s * 1.28, lat: 7.2, y: R + 1.65) }
        }
        informe.append("  seguridad: puertas de andén, barandas en extremos y pasarelas, ascensores en ambos andenes")
        for lado in [-1, 1] as [CGFloat] {
            var kk = d0 - A / 2 + 1.5
            while kk < d0 + A / 2 { if !(lado > 0 && enPasarela(kk)) { caja(0.16, 3.7, 0.16, marco, d: kk, lat: lado * 6.4, y: R + 2.9) }; kk += 6 }
            for dz in [-9, 0, 9] as [CGFloat] where !(finT.map { abs(d0 + dz + 3 - (d0 + $0)) < 2.8 } ?? false) {
                caja(0.5, 0.08, 1.8, banco, d: d0 + dz + 3, lat: lado * 5.9, y: R + 1.55)
                caja(0.08, 0.45, 1.8, banco, d: d0 + dz + 3, lat: lado * 6.15, y: R + 1.8)
                caja(0.4, 0.45, 0.08, marco, d: d0 + dz + 3.8, lat: lado * 5.9, y: R + 1.32)
                caja(0.4, 0.45, 0.08, marco, d: d0 + dz + 2.2, lat: lado * 5.9, y: R + 1.32)
            }
            for dz in [-12, 12] as [CGFloat] {                 // letreros colgantes con el nombre
                let (p, t) = eje(0, d0 + dz), n = normal(t), q = CGPoint(x: p.x + n.x * lado * 4.95, y: p.y + n.y * lado * 4.95)
                let s = nodo(SCNBox(width: 2.8, height: 0.55, length: 0.08, chamferRadius: 0.02), cartel, y: R + 3.75, x: q.x, z: q.y)
                s.eulerAngles.y = atan2(t.x, t.y) + .pi / 2; r.addChildNode(s)
                caja(0.03, 0.75, 0.03, marco, d: d0 + dz, lat: lado * 4.95 - 1.2, y: R + 4.3)
                caja(0.03, 0.75, 0.03, marco, d: d0 + dz, lat: lado * 4.95 + 1.2, y: R + 4.3)
            }
            for dz in [-6, 6] as [CGFloat] where !(finT.map { abs(dz - $0) < 3.6 } ?? false) { caja(0.07, 0.7, 4.2, cartel, d: d0 + dz, lat: lado * 6.48, y: R + 2.55) }   // en la mampara
        }
        let (p, _) = eje(0, d0)
        let et = etiqueta("Metro · \(e.nombre.capitalized)", y: Double(R + 12), grande: false, icono: "tram.fill", color: MetroVilla.rojo)
        et.position = SCNVector3(p.x, R + 12, p.y); escena.rootNode.addChildNode(et)
    }

    /// Lugar en tierra para el estacionamiento de la estación `k` (6, 4 o 3 puestos), lo más cerca del andén y sin
    /// pisar la torre de acceso en `fin`.
    private func lugarEstacionamiento(_ k: Int, fin: CGFloat?, d0: CGFloat? = nil) -> (dc: CGFloat, n: Int)? {
        let d0 = d0 ?? paradas[k], Lc: CGFloat = 10.75
        func cabe(_ c: CGFloat, _ media: CGFloat, _ mg: CGFloat) -> Bool {
            for o in stride(from: -media, through: media, by: 1.0) { for l in stride(from: -5.25 as CGFloat, through: 5.25, by: 1.05) {
                let (p, t) = eje(0, c + o), n = normal(t)
                if hypot(p.x + n.x * (Lc + l), p.y + n.y * (Lc + l)) < 65.9 { return false }      // lejos de los autos del anillo
                if !tierraLibre(CGPoint(x: p.x + n.x * (Lc + l), y: p.y + n.y * (Lc + l)), margen: mg) { return false }
            } }
            return true
        }
        // Se llega caminando a la torre por alguna franja de vereda sin cruzar edificios (las avenidas se cruzan en cebra)
        func aPieHastaTorre(_ c: CGFloat, _ media: CGFloat) -> Bool {
            guard let fin = fin else { return false }
            let dp = d0 + fin - (fin > 0 ? 1 : -1) * 3.2, borde = c + (c < dp ? media + 0.2 : -media - 0.2)
            return ([MetroVilla.latVereda, 14.0, 15.6, 16.6] as [CGFloat]).contains { lat in
                stride(from: min(borde, dp), through: max(borde, dp), by: 0.8).allSatisfy {
                    let (p, t) = eje(0, $0), n = normal(t), q = CGPoint(x: p.x + n.x * lat, y: p.y + n.y * lat)
                    return !MetroVilla.sueloLibre(q, margen: 0) || nav.libre(q) || (abs($0 - dp) < 2.5 && lat < 12.6)
                }
            }
        }
        for mg in [3.5, 2.5] as [CGFloat] {          // primero bien lejos de las avenidas con tránsito
            for n in [6, 4, 3] {
                let media = CGFloat(n) * 1.25 + 0.5
                if let o = stride(from: -42 as CGFloat, through: 42, by: 1.5).sorted(by: { abs($0) < abs($1) })
                    .filter({ o in fin.map { abs(o - $0) > media + 3.6 + 1 } ?? true })
                    .first(where: { cabe(d0 + $0, media, mg) && aPieHastaTorre(d0 + $0, media) }) { return (d0 + o, n) }
            }
        }
        return nil
    }

    /// Estacionamiento en tierra, después de todas las torres para no quitarles su lugar.
    private func montarEstacionamiento(_ r: SCNNode, _ k: Int) {
        let d0 = paradas[k], e = MetroVilla.estaciones[k]
        let asfalto = Mat.pbr(NSColor(calibratedWhite: 0.16, alpha: 1), rugosidad: 0.95), linea = Mat.pbr(.white, rugosidad: 0.6)
        let marco = Mat.pbr(NSColor(calibratedWhite: 0.2, alpha: 1), rugosidad: 0.4, metal: 0.6)
        func caja(_ w: CGFloat, _ h: CGFloat, _ l: CGFloat, _ m: SCNMaterial, d: CGFloat, lat: CGFloat, y: CGFloat) {
            let (p, t) = eje(0, d), n = normal(t), q = CGPoint(x: p.x + n.x * lat, y: p.y + n.y * lat)
            let b = nodo(SCNBox(width: w, height: h, length: l, chamferRadius: 0), m, y: y, x: q.x, z: q.y)
            b.eulerAngles.y = atan2(t.x, t.y); r.addChildNode(b)
        }
        func punto2(_ d: CGFloat, _ lat: CGFloat) -> CGPoint { let (p, t) = eje(0, d), n = normal(t); return CGPoint(x: p.x + n.x * lat, y: p.y + n.y * lat) }
        // Estacionamiento en tierra, entre el anillo periférico y el viaducto (no bajo él ni en la playa): una fila de
        // 3 a 6 puestos en batería con pasillo de 5,5 m y entrada desde el anillo. Del lado contrario a la torre.
        var puestos: [(p: CGPoint, d: CGFloat)] = []
        let Lc: CGFloat = 10.75, finT = torres[k][1]?.fin, sgT: CGFloat = (finT ?? 1) > 0 ? 1 : -1
        let elegido = lugarEstacionamiento(k, fin: finT)
        if e.estacionamiento, let (dc, np) = elegido {
            let media = CGFloat(np) * 1.25 + 0.5
            caja(10.5, 0.1, 2 * media, asfalto, d: dc, lat: Lc, y: 0.05)
            let ent = dc + sgT * max(0, media - 3)
            caja(3.2, 0.1, min(5.0, 2 * media), asfalto, d: ent, lat: Lc + 6.7, y: 0.05)                          // entrada desde el anillo
            for j in 0...np { caja(5.0, 0.01, 0.1, linea, d: dc - CGFloat(np) * 1.25 + CGFloat(j) * 2.5, lat: Lc - 2.75, y: 0.105) }
            caja(0.1, 0.01, CGFloat(np) * 2.5, linea, d: dc, lat: Lc - 0.25, y: 0.105)
            let colores: [NSColor] = [.white, .black, NSColor(Color(hex: "#9aa3ad")), NSColor(Color(hex: "#7a1d1d")), NSColor(Color(hex: "#1f3f6b")), NSColor(Color(hex: "#3c4a3e"))]
            for j in 0..<np {
                let o = -CGFloat(np) * 1.25 + 1.25 + CGFloat(j) * 2.5, (p, t) = eje(0, dc + o), n = normal(t)
                puestos.append((CGPoint(x: p.x + n.x * (Lc + 0.3), y: p.y + n.y * (Lc + 0.3)), dc + o))
                guard azar.real() < 0.75 else { continue }
                if let a = Modelos.nodo(azar.real() < 0.3 ? "suv" : "auto2", largo: 4.3, pintura: (colores[Int(azar.real() * 5.99)], ["Blue", "White"])) {
                    a.position = SCNVector3(p.x + n.x * (Lc - 2.75), 0.1, p.y + n.y * (Lc - 2.75)); a.eulerAngles.y = atan2(-n.x, -n.y)
                    escena.rootNode.addChildNode(a)
                }
                _ = t
            }
            let senal = Villa3D.Coordinador.mCartel("P  ESTACIONAMIENTO METRO", NSColor(Color(hex: "#1f5fae")), ancho: 900, brillo: 0.6)
            caja(0.08, 0.6, 3.4, senal, d: dc - sgT * (media - 1.8), lat: Lc + 4.9, y: 2.6)
            caja(0.08, 2.4, 0.08, marco, d: dc - sgT * (media - 1.8), lat: Lc + 4.9, y: 1.2)
            let c = punto2(dc, Lc), (_, tc) = eje(0, dc); nav.rect(c.x, c.y, 5.25, media, atan2(tc.x, tc.y), margen: 0)
            informe.append("Estación \(e.nombre): estacionamiento en tierra, \(np) puestos, a \(Int(abs(dc - d0))) m del centro del andén")
        } else if e.estacionamiento {
            informe.append("SIN ESTACIONAMIENTO  estación \(e.nombre): no hay suelo libre alcanzable a pie desde la torre")
        }
        estacionados[k] = puestos
        // Veredas accesibles (sin escalones, 2,4 m): puerta de la torre → anillo periférico, y estacionamiento → torre
        guard let fin = finT else { return }
        let baldosa = Mat.pbr(NSColor(calibratedWhite: 0.68, alpha: 1), rugosidad: 0.85), guia = Mat.pbr(NSColor(Color(hex: "#f2c200")), rugosidad: 0.7)
        let dp = d0 + fin - sgT * 3.2, LT = MetroVilla.latVereda
        var bloqueos = 0, dondeB: [String] = []
        func tramo(_ da: CGFloat, _ db: CGFloat, lat: CGFloat) {          // a lo largo de la vía
            var d = min(da, db)
            while d < max(da, db) - 0.05 {
                let d1 = min(d + 2, max(da, db)), m = (d + d1) / 2, q = punto2(m, lat)
                if !MetroVilla.sueloLibre(q, margen: 0) {                  // cruza una avenida: paso de cebra
                    for x in stride(from: d, to: d1, by: 1) { caja(2.4, 0.01, 0.5, linea, d: x + 0.25, lat: lat, y: 0.11) }
                } else {
                    if !nav.libre(q) { bloqueos += 1; dondeB.append(String(format: "(x %.1f, z %.1f)", q.x, q.y)) }
                    caja(2.0, 0.06, d1 - d + 0.02, baldosa, d: m, lat: lat, y: 0.03)
                    caja(0.3, 0.012, d1 - d, guia, d: m, lat: lat, y: 0.066)    // huella podotáctil
                }
                d = d1
            }
        }
        // De la puerta (lat 9,4) baja recto hasta lat 12,4 (fuera de la torre), y si enfrente hay algo, se corre por el costado hasta un
        // tramo despejado antes de llegar al anillo
        func radialLibre(_ d: CGFloat) -> Bool {
            stride(from: LT + 0.5, through: MetroVilla.latCalle, by: 0.8).allSatisfy { let q = punto2(d, $0); return MetroVilla.sueloLibre(q, margen: 0) && nav.libre(q) }
        }
        let corrimientos = stride(from: 0 as CGFloat, through: 12, by: 1.5).flatMap { [-sgT * $0, sgT * $0] }
        func tangLibre(_ da: CGFloat, _ db: CGFloat, _ lat: CGFloat) -> Bool {
            stride(from: min(da, db), through: max(da, db), by: 0.8).allSatisfy { let q = punto2($0, lat); return !MetroVilla.sueloLibre(q, margen: 0) || nav.libre(q) }
        }
        // borde del estacionamiento más cercano a la torre (la vereda empieza ahí, no dentro del asfalto)
        let cercaP: CGFloat? = puestos.isEmpty ? nil : [puestos.first!.d, puestos.last!.d].min { abs($0 - dp) < abs($1 - dp) }.map { $0 + ($0 < dp ? 1.9 : -1.9) }
        let franjas: [CGFloat] = [LT, 14.0, 15.6, 16.6]
        let ds = corrimientos.map { dp + $0 }.first { x in radialLibre(x) && tangLibre(dp, x, LT) && (cercaP.map { c in franjas.contains { tangLibre(c, x, $0) } } ?? true) }
            ?? corrimientos.map { dp + $0 }.first { radialLibre($0) && tangLibre(dp, $0, LT) } ?? dp
        salidas[k] = ds
        func radial(_ d: CGFloat, _ l0: CGFloat, _ l1f: CGFloat) {
            var l = l0
            while l < l1f - 0.01 {
                let l1 = min(l + 2, l1f), q = punto2(d, (l + l1) / 2)
                if !MetroVilla.sueloLibre(q, margen: 0) || (l > 11.2 && !nav.libre(q)) { bloqueos += 1; dondeB.append(String(format: "radial (x %.1f, z %.1f)", q.x, q.y)) }
                caja(l1 - l + 0.02, 0.06, 2.0, baldosa, d: d, lat: (l + l1) / 2, y: 0.03)
                caja(l1 - l, 0.012, 0.3, guia, d: d, lat: (l + l1) / 2, y: 0.066)
                l = l1
            }
        }
        radial(dp, 9.4, LT)
        if abs(ds - dp) > 0.1 { tramo(dp, ds, lat: LT) }
        radial(ds, LT, MetroVilla.latCalle)
        if let c = cercaP {
            let lp = franjas.first { tangLibre(c, ds, $0) } ?? LT
            latParque[k] = lp
            tramo(c, ds, lat: lp)
        }
        informe.append(bloqueos == 0 ? "  veredas accesibles despejadas (torre ↔ anillo\(puestos.isEmpty ? "" : " ↔ estacionamiento"))"
                                     : "VEREDA OBSTRUIDA  estación \(e.nombre): \(bloqueos) tramos sobre algo ocupado " + dondeB.joined(separator: " "))
    }

    /// Cocheras y talleres sobre el mar: losa sobre pilotes, abanico de tres vías, nave con portones, foso de
    /// inspección, puente grúa, dos trenes en mantención y mecánicos.
    private func montarCocheras(_ r: SCNNode, _ hormigon: SCNMaterial, _ acero: SCNMaterial, _ placa: SCNMaterial) {
        let R = MetroVilla.riel, G = SCNNode()
        let c = Islas.polar(MetroVilla.rCocheras, MetroVilla.angCocheras)
        G.position = SCNVector3(c.x, 0, c.y); G.eulerAngles.y = MetroVilla.angCocheras; r.addChildNode(G)
        @discardableResult
        func caja(_ w: CGFloat, _ h: CGFloat, _ l: CGFloat, _ m: SCNMaterial, x: CGFloat = 0, y: CGFloat, z: CGFloat) -> SCNNode {
            let n = nodo(SCNBox(width: w, height: h, length: l, chamferRadius: 0), m, y: y, x: x, z: z); G.addChildNode(n); return n
        }
        let muro = Mat.pbr(NSColor(Color(hex: "#5d6f82")), rugosidad: 0.55, metal: 0.35)
        let muroClaro = Mat.pbr(NSColor(Color(hex: "#c9d1d8")), rugosidad: 0.6, metal: 0.2)
        let amarillo = Mat.pbr(NSColor(Color(hex: "#f2c200")), rugosidad: 0.45, metal: 0.4)
        let oscuro = Mat.pbr(NSColor(calibratedWhite: 0.08, alpha: 1), rugosidad: 0.8)
        let luz = Mat.emisivo(NSColor(calibratedRed: 1, green: 0.97, blue: 0.88, alpha: 1), fuerza: 1); luces.append(luz)
        let claraboya = Mat.pbr(NSColor(calibratedRed: 0.7, green: 0.85, blue: 0.95, alpha: 1), rugosidad: 0.1, metal: 0.2)
        claraboya.emission.contents = NSColor(calibratedRed: 1, green: 0.95, blue: 0.8, alpha: 1); luces.append(claraboya)
        // Losa sobre pilotes
        caja(24, 0.6, 56, hormigon, y: R - 0.52, z: 3)
        for x in [-9, 0, 9] as [CGFloat] { for z in stride(from: -22 as CGFloat, through: 28, by: 10) {
            G.addChildNode(nodo(SCNCylinder(radius: 0.8, height: R), hormigon, y: -0.5 + R / 2 - 0.3, x: x, z: z))
        } }
        for x in [-11.8, 11.8] as [CGFloat] { caja(0.25, 1.0, 56, hormigon, x: x, y: R + 0.25, z: 3) }
        // Vías: central (continúa el ramal) y dos laterales con sus diagonales
        for x in [-5, 0, 5] as [CGFloat] {
            let z0: CGFloat = x == 0 ? -25 : -11
            caja(2.5, 0.2, 31 - z0, placa, x: x, y: R - 0.12, z: (z0 + 31) / 2 - 0.5)
            for k in [-0.7175, 0.7175] as [CGFloat] { caja(0.075, 0.17, 31 - z0, acero, x: x + k, y: R + 0.06, z: (z0 + 31) / 2 - 0.5) }
        }
        for s in [-1, 1] as [CGFloat] {
            let dz: CGFloat = 10, dx: CGFloat = 5, L = hypot(dx, dz)
            for k in [-0.7175, 0.7175] as [CGFloat] { caja(0.075, 0.17, L, acero, x: s * dx / 2 + k, y: R + 0.06, z: -16).eulerAngles.y = s * atan2(dx, dz) }
            caja(2.5, 0.19, L, placa, x: s * dx / 2, y: R - 0.13, z: -16).eulerAngles.y = s * atan2(dx, dz)
        }
        // Nave de mantención (z −6 a +30), abierta hacia la villa con tres portones
        let H: CGFloat = 9
        caja(0.3, H, 36, muro, x: -9.6, y: R + H / 2, z: 12)
        caja(0.3, H, 36, muro, x: 9.6, y: R + H / 2, z: 12)
        caja(19.5, H, 0.3, muro, y: R + H / 2, z: 30)
        for x in [-7.5, -2.5, 2.5, 7.5] as [CGFloat] { caja(0.6, H, 0.6, muroClaro, x: x, y: R + H / 2, z: -6) }
        caja(19.5, 2.2, 0.4, muroClaro, y: R + H - 1.1, z: -6)
        for (k, x) in ([-5, 0, 5] as [CGFloat]).enumerated() {        // portones enrollables (el central abierto)
            if k != 1 { caja(4.2, 2.5, 0.12, muro, x: x, y: R + H - 3.4, z: -5.9) }
            caja(4.4, 0.12, 0.2, amarillo, x: x, y: R + 0.06, z: -6)
        }
        for s in [-1, 1] as [CGFloat] {                                // techo a dos aguas con lucarnas
            caja(10.4, 0.25, 36.6, muroClaro, x: s * 4.95, y: R + H + 0.85, z: 12).eulerAngles.z = -s * 0.18
            for z in stride(from: 0 as CGFloat, through: 24, by: 6) { caja(2.4, 0.06, 3.2, claraboya, x: s * 4.4, y: R + H + 1.0, z: z).eulerAngles.z = -s * 0.18 }
        }
        caja(19.5, 2.0, 0.3, muroClaro, y: R + H + 1.0, z: -6.1)
        caja(12, 1.1, 0.1, Villa3D.Coordinador.mCartel("COCHERAS Y TALLERES · METRO VILLA", MetroVilla.rojo, ancho: 1400, brillo: 0.8), y: R + H + 0.7, z: -6.35).eulerAngles.y = .pi
        // Interior: foso de inspección, puente grúa, luminarias y bancos de trabajo
        caja(1.2, 0.05, 30, oscuro, y: R - 0.01, z: 13)
        caja(19, 0.6, 0.7, amarillo, y: R + H - 1.4, z: 10)
        caja(1.0, 0.8, 1.2, amarillo, x: 3, y: R + H - 2.1, z: 10)
        for z in stride(from: 0 as CGFloat, through: 26, by: 6.5) { for x in [-5, 0, 5] as [CGFloat] { caja(0.3, 0.08, 2.4, luz, x: x, y: R + H - 0.3, z: z) } }
        for z in [4, 14, 22] as [CGFloat] { for x in [-8.8, 8.8] as [CGFloat] { caja(0.8, 0.9, 2.0, muro, x: x, y: R + 0.45, z: z) } }
        for (x, z, giro) in [(-7.9, 8, 1.2), (7.9, 18, -1.6), (2.6, -2, 0.4)] as [(CGFloat, CGFloat, CGFloat)] {   // mecánicos
            let m = Persona.mecanico()
            m.raiz.position = G.convertPosition(SCNVector3(x, R + 0.1, z), to: nil); m.raiz.eulerAngles.y = MetroVilla.angCocheras + giro
            escena.rootNode.addChildNode(m.raiz)
        }
        // Trenes en mantención en las vías laterales, dentro de la nave
        for x in [-5, 5] as [CGFloat] {
            let t = armarTren(via: 1, servicio: "FUERA DE SERVICIO")
            for (k, c) in t.coches.enumerated() {
                c.position = G.convertPosition(SCNVector3(x, R + 0.145, 13 + (k == 0 ? 7.7 : -7.7)), to: nil)
                c.eulerAngles.y = MetroVilla.angCocheras + (k == 0 ? 0 : .pi)
            }
        }
        // Tren de maniobras: va y viene por el ramal entre la nave y la salida a la línea
        let m = armarTren(via: 1, servicio: "MANIOBRAS")
        m.s = vias[1].largo - 22; m.dir = 1; m.espera = 12
        trenes.append(m); ubicar(m)
    }

    // MARK: Trenes

    private func armarTren(via: Int, servicio: String) -> Tren {
        let tren = Tren(via: via), color = MetroVilla.rojo
        let blanco = Mat.pbr(NSColor(calibratedWhite: 0.94, alpha: 1), rugosidad: 0.25, metal: 0.15)
        let gris = Mat.pbr(NSColor(calibratedWhite: 0.3, alpha: 1), rugosidad: 0.6, metal: 0.4)
        let negro = Mat.pbr(NSColor(calibratedWhite: 0.07, alpha: 1), rugosidad: 0.5)
        let franja = Mat.pbr(color, rugosidad: 0.3, metal: 0.1)
        let ventana = Mat.pbr(NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.16, alpha: 1), rugosidad: 0.08, metal: 0.3)
        ventana.emission.contents = NSColor(calibratedRed: 1, green: 0.95, blue: 0.82, alpha: 1); ventana.emission.intensity = 0.1
        luces.append(ventana)
        let puertaM = Mat.pbr(NSColor(calibratedWhite: 0.86, alpha: 1), rugosidad: 0.3, metal: 0.2)
        let rueda = Mat.pbr(NSColor(calibratedWhite: 0.4, alpha: 1), rugosidad: 0.35, metal: 0.9)
        let acero = Mat.pbr(NSColor(calibratedWhite: 0.55, alpha: 1), rugosidad: 0.3, metal: 0.9)
        let letrero = Villa3D.Coordinador.mCartel(servicio, color, ancho: 700, brillo: 1.1)
        let L = MetroVilla.largoCoche, H: CGFloat = 3.6, W: CGFloat = 2.8, piso: CGFloat = 1.1
        for k in 0..<2 {
            let c = SCNNode(), cuerpo = SCNNode()
            @discardableResult
            func caja(_ w: CGFloat, _ h: CGFloat, _ l: CGFloat, _ m: SCNMaterial, x: CGFloat = 0, y: CGFloat, z: CGFloat = 0, ch: CGFloat = 0) -> SCNNode {
                let n = nodo(SCNBox(width: w, height: h, length: l, chamferRadius: ch), m, y: y, x: x, z: z); cuerpo.addChildNode(n); return n
            }
            caja(W, H - 0.95, L - 1.2, blanco, y: 0.95 + (H - 0.95) / 2, z: -0.6, ch: 0.22)       // caja de aluminio (cabina en +z)
            caja(W - 0.3, 0.5, L - 1.4, gris, y: 0.8, z: -0.6)                                     // faldón
            caja(W, 2.0, 1.4, blanco, y: 1.95, z: L / 2 - 0.85, ch: 0.3)                           // morro
            caja(W - 0.3, 1.25, 0.08, ventana, y: 2.55, z: L / 2 - 0.1).eulerAngles.x = -0.32      // parabrisas panorámico
            caja(W - 0.1, 0.5, 1.2, blanco, y: 3.35, z: L / 2 - 0.75, ch: 0.2)
            let blancoF = Mat.emisivo(NSColor(calibratedRed: 1, green: 0.98, blue: 0.9, alpha: 1), fuerza: 0)
            let rojoF = Mat.emisivo(NSColor(calibratedRed: 1, green: 0.08, blue: 0.05, alpha: 1), fuerza: 0)
            for x in [-0.95, 0.95] as [CGFloat] {
                let f = nodo(SCNCylinder(radius: 0.13, height: 0.06), blancoF, y: 1.35, x: x, z: L / 2 - 0.13); f.eulerAngles.x = .pi / 2; cuerpo.addChildNode(f)
                caja(0.22, 0.1, 0.05, rojoF, x: x * 0.82, y: 1.12, z: L / 2 - 0.14)
            }
            tren.faros.append((blancoF, rojoF))
            caja(1.5, 0.26, 0.05, letrero, y: 3.18, z: L / 2 - 0.15)                               // letrero de destino
            caja(W + 0.01, 0.42, 1.0, franja, y: 1.25, z: L / 2 - 0.9)
            caja(1.9, 0.18, 0.4, negro, y: 0.62, z: L / 2 - 0.2)                                   // acoplador
            for lado in [-1, 1] as [CGFloat] {
                caja(0.02, 0.2, L - 1.6, franja, x: lado * (W / 2 + 0.005), y: 1.55, z: -0.4)
                caja(0.02, 0.06, L - 1.6, franja, x: lado * (W / 2 + 0.005), y: 3.12, z: -0.4)
                for (zc, an) in [(-6.35, 1.7), (-2.6, 2.4), (1.4, 2.4), (4.85, 1.9)] as [(CGFloat, CGFloat)] {   // ventanas entre puertas
                    caja(0.02, 0.95, an, ventana, x: lado * (W / 2 + 0.006), y: 2.42, z: zc)
                }
            }
            for z in [-4.2, 2.6] as [CGFloat] { caja(1.5, 0.32, 2.2, gris, y: H + 0.12, z: z, ch: 0.08) }     // equipos de clima
            caja(W - 0.6, 0.06, L - 2, gris, y: H, z: -0.6)
            caja(2.1, 2.5, 0.45, negro, y: 2.2, z: -L / 2 - 0.05, ch: 0.1)                       // fuelle de intercirculación
            for zb in [-L / 2 + 2.6, L / 2 - 2.8] {                                               // bogies con cuatro ruedas
                caja(2.15, 0.36, 2.7, gris, y: 0.55, z: zb)
                for x in [-0.7175, 0.7175] as [CGFloat] {
                    for dz in [-0.95, 0.95] as [CGFloat] {
                        let w = nodo(SCNCylinder(radius: 0.42, height: 0.14), rueda, y: 0.42, x: x, z: zb + dz)
                        w.eulerAngles.z = .pi / 2; cuerpo.addChildNode(w)
                    }
                }
                caja(2.5, 0.12, 0.25, negro, y: 0.78, z: zb)
            }
            if k == 0 {                                                                              // pantógrafo contra el hilo a 5,3 m
                caja(1.2, 0.18, 1.4, gris, y: H + 0.2, z: -1.0)
                caja(0.06, 0.06, 1.25, acero, y: H + 0.62, z: -1.42).eulerAngles.x = 0.62
                caja(0.06, 0.06, 1.25, acero, y: H + 1.25, z: -1.42).eulerAngles.x = -0.62
                caja(1.6, 0.06, 0.1, acero, y: 5.25, z: -1.42)
            }
            c.addChildNode(cuerpo.flattenedClone())
            var hojas: [(hoja: SCNNode, z: CGFloat, lado: CGFloat)] = []
            for lado in [-1, 1] as [CGFloat] {                                                      // puertas de doble hoja, 3 por lado
                for zc in [-4.0, 0.0, 4.0] as [CGFloat] {
                    for sgn in [-1, 1] as [CGFloat] {
                        let h = SCNNode()
                        h.addChildNode(nodo(SCNBox(width: 0.04, height: 2.0, length: 0.7, chamferRadius: 0), puertaM, y: piso + 1.0))
                        h.addChildNode(nodo(SCNBox(width: 0.05, height: 1.0, length: 0.42, chamferRadius: 0), ventana, y: piso + 1.35))
                        let z = zc + sgn * 0.36 - 0.6
                        h.position = SCNVector3(lado * (W / 2 + 0.02), 0, z)
                        c.addChildNode(h); hojas.append((h, z, sgn))
                    }
                    c.addChildNode(nodo(SCNBox(width: 0.03, height: 2.1, length: 1.52, chamferRadius: 0), negro, y: piso + 1.02, x: lado * (W / 2 + 0.003), z: zc - 0.6))
                }
            }
            tren.puertas.append(hojas)
            c.name = via == 1 ? "elem:metro-cocheras" : "elem:metro-tren"
            escena.rootNode.addChildNode(c)
            tren.coches.append(c)
        }
        return tren
    }

    private func ubicar(_ tren: Tren) {
        let paso = MetroVilla.pasoCoche
        for (k, c) in tren.coches.enumerated() {
            let off: CGFloat = k == 0 ? paso / 2 : -paso / 2
            // Cada coche se apoya en sus dos bogies (±4,8 m) sobre la vía: en curva la caja sigue la cuerda entre ellos y
            // dos coches contiguos no se montan.
            func bogie(_ d: CGFloat) -> CGPoint { let (p, t) = eje(tren.via, d), n = normal(t); return CGPoint(x: p.x + n.x * tren.lat, y: p.y + n.y * tren.lat) }
            let a = bogie(tren.s + off + 4.8), b = bogie(tren.s + off - 4.8)
            c.position = SCNVector3((a.x + b.x) / 2, MetroVilla.riel + 0.145, (a.y + b.y) / 2)
            c.eulerAngles.y = atan2(a.x - b.x, a.y - b.y) + (k == 0 ? 0 : .pi)
            // Puertas del lado del andén: el de la vía en uso queda al +x local del coche que va adelante
            let ladoAnden: CGFloat = ((tren.dir > 0) == (k == 0)) ? 1 : -1
            for h in tren.puertas[k] {
                h.hoja.position.z = h.z + h.lado * ((h.hoja.position.x > 0) == (ladoAnden > 0) ? tren.apertura * 0.68 : 0)
            }
            let adelante = (k == 0) == (tren.dir > 0)
            tren.faros[k].blanco.emission.intensity = adelante ? 1.6 : 0
            tren.faros[k].rojo.emission.intensity = adelante ? 0 : 1.4
        }
    }

    /// Distancia que le falta a un tren de la Línea Circular hasta `meta`, en su sentido de marcha.
    private func falta(_ t: Tren, _ meta: CGFloat) -> CGFloat {
        let L = vias[0].largo
        var f = ((meta - t.s) * t.dir).truncatingRemainder(dividingBy: L); if f < 0 { f += L }
        return f
    }

    func mover(_ dt: CGFloat) {
        let n = MetroVilla.estaciones.count, L = vias[0].largo
        for tren in trenes {
            let vmax: CGFloat = tren.via == 0 ? 14 : 4, acel: CGFloat = 1.1, fren: CGFloat = 1.2
            if tren.espera > 0 {
                tren.espera -= dt
                tren.apertura = tren.via == 1 ? 0 : tren.espera > 2.5 ? min(1, tren.apertura + dt / 1.6) : max(0, tren.apertura - dt / 1.6)
                if tren.espera <= 0 {
                    tren.apertura = 0
                    if tren.via == 0 { tren.destino = (tren.destino + (tren.dir > 0 ? 1 : n - 1)) % n } else { tren.dir = -tren.dir }
                }
                ubicar(tren); continue
            }
            var resta: CGFloat
            if tren.via == 0 { resta = falta(tren, paradas[tren.destino]); if resta > L - 0.05 { resta = 0 } }
            else { resta = tren.dir > 0 ? (vias[1].largo - 22) - tren.s : tren.s - 36 }
            if resta <= 0.05 {
                if tren.via == 0 { tren.s = paradas[tren.destino]; tren.espera = 13; abordar(tren) } else { tren.espera = 25 }
                tren.v = 0
            } else {
                let frenado = tren.v * tren.v / (2 * fren)
                tren.v = resta <= frenado + 0.2 ? max(0.6, tren.v - fren * dt) : min(vmax, tren.v + acel * dt)
                tren.s += min(tren.v * dt, resta) * tren.dir
                if tren.via == 0 { tren.s = tren.s.truncatingRemainder(dividingBy: L); if tren.s < 0 { tren.s += L } }
            }
            ubicar(tren)
        }
        var abiertas: [Int: [CGFloat: CGFloat]] = [:]
        for tren in trenes where tren.via == 0 && tren.espera > 0 { abiertas[tren.destino, default: [:]][tren.dir > 0 ? 1 : -1] = tren.apertura }
        for (k, lados) in puertasAnden.enumerated() {
            for (lado, hojas) in lados {
                let ap = (abiertas[k]?[lado] ?? 0) * 0.95
                for h in hojas { h.hoja.position = SCNVector3(h.base.x + h.t.x * h.s * ap, h.base.y, h.base.z + h.t.y * h.s * ap) }
            }
        }
        moverPasajeros(dt)
    }

    // MARK: Pasajeros

    private func anden(_ k: Int, _ lado: CGFloat, _ d: CGFloat, _ lat: CGFloat) -> SCNVector3 { punto(0, paradas[k] + d, lado * lat, MetroVilla.riel + 1.1) }

    private func libreP() -> Pasajero? { pasajeros.first { !$0.activo } }

    private func iniciar(_ ps: Pasajero, _ k: Int, _ lado: CGFloat, _ ruta: [Paso], en inicio: SCNVector3?) {
        ps.activo = true; ps.estacion = k; ps.lado = lado; ps.ruta = ruta; ps.reloj = 0; ps.oculto = false
        ps.p.raiz.isHidden = inicio == nil
        if let i = inicio { ps.p.raiz.position = i }
    }

    /// Recorrido a pie desde la calle o un auto estacionado hasta la puerta de la torre, siempre por la vereda.
    private func aPie(_ k: Int, _ t: (fin: CGFloat, puerta: CGPoint)) -> [SCNVector3] {
        let dp = paradas[k] + t.fin - (t.fin > 0 ? 1 : -1) * 3.2, LT = MetroVilla.latVereda, ds = salidas[k]
        func v(_ d: CGFloat, _ lat: CGFloat, _ y: CGFloat = 0.07) -> SCNVector3 { punto(0, d, lat, y) }
        func porVereda(_ da: CGFloat, _ db: CGFloat) -> [SCNVector3] {       // a lo largo de la vereda curva
            var r: [SCNVector3] = [], d = da
            let paso: CGFloat = db > da ? 5 : -5
            while abs(db - d) > 5 { d += paso; r.append(v(d, LT)) }
            return r + [v(db, LT)]
        }
        let autos = estacionados[k]
        if !autos.isEmpty && azar.real() < 0.55 {
            let a = autos[Int(azar.real() * CGFloat(autos.count - 1) + 0.5)]
            let lp = latParque[k]
            if lp == LT { return [SCNVector3(a.p.x, 0.1, a.p.y), v(a.d, LT)] + porVereda(a.d, dp) }
            var r = [SCNVector3(a.p.x, 0.1, a.p.y), v(a.d, lp)], d = a.d
            let paso: CGFloat = ds > a.d ? 5 : -5
            while abs(ds - d) > 5 { d += paso; r.append(v(d, lp)) }
            return r + [v(ds, lp), v(ds, LT)] + porVereda(ds, dp)
        }
        return [v(ds + (CGFloat(azar.real()) - 0.5) * 1.4, MetroVilla.latCalle), v(ds, LT)] + porVereda(ds, dp)
    }

    /// Junto al ascensor (andén exterior) o a la pasarela (andén interior), arriba.
    private func llegada(_ k: Int, _ lado: CGFloat, _ fin: CGFloat) -> SCNVector3 { anden(k, lado, fin - (fin > 0 ? 1.3 : -1.3), 5.0) }

    /// Alguien llega a la estación: camina a la torre, sube (y cruza la pasarela si va al andén exterior) y espera.
    private func esperar(_ k: Int, _ lado: CGFloat, inicial: Bool = false) {
        guard let t = torres[k][lado], let ps = libreP() else { return }
        let lugar = anden(k, lado, (CGFloat(azar.real()) - 0.5) * 26, 4.4 + CGFloat(azar.real()) * 1.4)
        if inicial { iniciar(ps, k, lado, [.esperar], en: lugar); orientar(ps, k, lado); return }
        let base = SCNVector3(t.puerta.x, 0.07, t.puerta.y), camino = aPie(k, t)
        iniciar(ps, k, lado, camino.dropFirst().map { .ir($0) } + [.ir(base), .salto(lado > 0 ? 5 : 9, llegada(k, lado, t.fin)), .ir(lugar), .esperar], en: camino[0])
    }

    private func orientar(_ ps: Pasajero, _ k: Int, _ lado: CGFloat) {
        let (_, t) = eje(0, paradas[k]), n = normal(t)
        ps.p.raiz.eulerAngles.y = atan2(-n.x * lado, -n.y * lado)     // de frente a la vía
    }

    /// Llega un tren: bajan 1 a 3 personas y, tras ellas, suben las que esperaban en ese andén.
    private func abordar(_ tren: Tren) {
        guard let k = paradas.firstIndex(where: { abs($0 - tren.s) < 0.5 }) else { return }
        let lado: CGFloat = tren.dir > 0 ? 1 : -1, s = tren.s, medio = MetroVilla.pasoCoche / 2
        let puertas = [-4.6, -0.6, 3.4].flatMap { (zc: CGFloat) -> [CGFloat] in [s + medio + zc, s - medio - zc] }
        let R = MetroVilla.riel + 1.1
        for ps in pasajeros where ps.activo && ps.estacion == k && ps.lado == lado && ps.esperando {
            let cur = ps.p.raiz.position
            func dist(_ d: CGFloat) -> CGFloat { let q = punto(0, d, lado * 3.9, R); return hypot(q.x - cur.x, q.z - cur.z) }
            let d = puertas.min { dist($0) < dist($1) } ?? s
            ps.ruta = [.ir(punto(0, d, lado * 3.9, R)), .ir(punto(0, d, lado * 2.4, R)), .fin]
            ps.reloj = 2.2 + CGFloat(azar.real()) * 1.5                 // esperan que abran y bajen los demás
        }
        guard let t = torres[k][lado] else { return }
        for i in 0..<(1 + Int(azar.real() * 2.99)) {
            guard let ps = libreP() else { break }
            let d = puertas[Int(azar.real() * CGFloat(puertas.count - 1) + 0.5)] - paradas[k]
            let base = SCNVector3(t.puerta.x, 0.07, t.puerta.y), camino = aPie(k, t).reversed().map { Paso.ir($0) }
            iniciar(ps, k, lado, [.salto(1.7 + CGFloat(i) * 0.8, anden(k, lado, d, 3.7)), .ir(anden(k, lado, d, 4.7)),
                                  .ir(llegada(k, lado, t.fin)), .salto(lado > 0 ? 5 : 9, base)] + camino + [.fin], en: nil)
        }
    }

    private func moverPasajeros(_ dt: CGFloat) {
        for k in llegadas.indices {
            llegadas[k] -= dt
            if llegadas[k] <= 0 {
                llegadas[k] = 5 + CGFloat(azar.real()) * 9
                let lado: CGFloat = azar.real() < 0.5 ? 1 : -1
                if pasajeros.filter({ $0.activo && $0.estacion == k && $0.lado == lado }).count < 5 { esperar(k, lado) }
            }
        }
        for ps in pasajeros where ps.activo {
            if ps.reloj > 0 && !ps.oculto { ps.reloj -= dt; ps.p.detener(); continue }
            guard let paso = ps.ruta.first else { ps.activo = false; ps.p.raiz.isHidden = true; continue }
            switch paso {
            case .esperar:
                ps.p.detener()
            case .fin:
                ps.activo = false; ps.p.raiz.isHidden = true; ps.ruta = []
            case .salto(let t, let q):
                if !ps.oculto { ps.oculto = true; ps.p.raiz.isHidden = true; ps.reloj = t }
                ps.reloj -= dt
                if ps.reloj <= 0 { ps.oculto = false; ps.reloj = 0; ps.p.raiz.position = q; ps.p.raiz.isHidden = false; ps.ruta.removeFirst() }
            case .ir(let q):
                let a = ps.p.raiz.position, dx = q.x - a.x, dz = q.z - a.z, d = hypot(dx, dz), v: CGFloat = 1.35 * dt
                if d <= v {
                    ps.p.raiz.position = q; ps.ruta.removeFirst()
                    if case .esperar? = ps.ruta.first { orientar(ps, ps.estacion, ps.lado) }
                } else {
                    ps.p.raiz.position = SCNVector3(a.x + dx / d * v, q.y, a.z + dz / d * v)
                    ps.p.raiz.eulerAngles.y = atan2(dx, dz)
                    ps.p.marchar(dt: dt * 0.75)
                }
            }
        }
    }

    // MARK: Clics, plano y reportes

    /// Estación o cocheras bajo un punto del mundo, para abrir su reporte y volar a ella.
    func elementoEn(_ g: SCNVector3) -> (id: String, p: CGPoint)? {
        let q = CGPoint(x: g.x, y: g.z), c = MetroVilla.centroCocheras
        if hypot(q.x - c.x, q.y - c.y) < 30 && g.y > 2 { return ("metro-cocheras", c) }
        for k in paradas.indices {
            let p = eje(0, paradas[k]).p
            if hypot(q.x - p.x, q.y - p.y) < 21 && g.y > 4 { return ("metro-" + MetroVilla.estaciones[k].id, p) }
        }
        return nil
    }

    /// Puerta de la torre de acceso de cada estación (entrada y salida a nivel del suelo), para las vistas del panel Metro.
    func accesos() -> [(nombre: String, puerta: CGPoint)] {
        paradas.indices.compactMap { k in
            guard k < torres.count, let t = torres[k][1] ?? torres[k][-1] else { return nil }
            return (MetroVilla.estaciones[k].nombre, t.puerta)
        }
    }

    private func eta(_ k: Int, _ lado: CGFloat) -> String {
        let L = vias[0].largo
        let cand = trenes.filter { $0.via == 0 && ($0.dir > 0) == (lado > 0) }.map { t -> CGFloat in
            if t.espera > 0 && abs(t.s - paradas[k]) < 0.5 { return 0 }
            let f = falta(t, paradas[k]), entre = Int(f / (L / CGFloat(paradas.count)))
            return f / 9 + CGFloat(entre) * 13 + max(0, t.espera)
        }
        guard let m = cand.min() else { return "sin trenes" }
        return m < 1 ? "tren en el andén" : "próximo tren en \(Int(m.rounded())) s"
    }

    func reporte(_ e: String) -> (titulo: String, quien: String, texto: String) {
        let enAndenes = pasajeros.filter { $0.activo && $0.esperando }.count
        let enCamino = pasajeros.filter { $0.activo && !$0.esperando }.count
        let servicio = trenes.filter { $0.via == 0 }.count
        if e == "metro-cocheras" {
            return ("Cocheras y Talleres del Metro", "Jefe de taller · mantención del material rodante",
                    "Dos trenes en revisión en la nave (bogies, frenos y pantógrafo) y uno haciendo maniobras en el ramal. Foso de inspección y puente grúa operativos. En la Línea Circular circulan \(servicio) trenes.")
        }
        if e == "metro-tren" {
            return ("Metro de la Villa · Línea Circular", "Conductor de turno",
                    "Doble vía elevada de \(Int(vias[0].largo)) m alrededor de la villa central, \(paradas.count) estaciones y \(servicio) trenes de dos coches, dos por sentido. Ahora hay \(enAndenes) personas esperando en los andenes y \(enCamino) entrando o saliendo de las estaciones.")
        }
        let id = String(e.dropFirst(6))
        guard let k = MetroVilla.estaciones.firstIndex(where: { $0.id == id }) else { return ("Metro de la Villa", "Línea Circular", "") }
        let est = MetroVilla.estaciones[k]
        func esp(_ l: CGFloat) -> Int { pasajeros.filter { $0.activo && $0.estacion == k && $0.lado == l && $0.esperando }.count }
        let park = est.estacionamiento ? " Estacionamiento en tierra con \(estacionados[k].count) puestos y vereda accesible hasta la torre." : ""
        return ("Estación \(est.nombre.capitalized)", "Jefa de estación · Línea Circular",
                "Conecta con \(est.conecta). Andén interior: \(esp(1)) esperando, \(eta(k, 1)). Andén exterior: \(esp(-1)) esperando, \(eta(k, -1)).\(park)")
    }
}
