import SwiftUI
import SceneKit
import AppKit

// MARK: - Utilidades de escena: nodos, materiales PBR, texturas procedurales, cielo y azar fijo

@MainActor
func nodo(_ g: SCNGeometry, _ m: SCNMaterial, y: CGFloat = 0, x: CGFloat = 0, z: CGFloat = 0) -> SCNNode {
    g.materials = [m]
    let n = SCNNode(geometry: g)
    n.position = SCNVector3(x, y, z)
    return n
}

/// Letrero que siempre mira a la cámara.
@MainActor
/// Ícono representativo de cada barrio (SF Symbols): en la villa 3D, la barra lateral y la vista del barrio.
let iconoBarrio: [String: String] = ["urg": "cross.case.fill", "cer": "brain.head.profile", "nube": "cloud.fill",
                                     "ios": "iphone.gen3", "mac": "laptopcomputer", "sede": "building.columns.fill",
                                     "puerto": "ferry.fill", "mall": "bag.fill",
                                     "trade": "building.2.fill", "banco": "banknote.fill", "casino": "suit.spade.fill", "museo": "building.columns.circle.fill",
                                     "uni": "graduationcap.fill", "ciencia": "atom", "aeropuerto": "airplane",
                                     "fach": "airplane.circle.fill", "armada": "ferry.fill", "ejercito": "shield.lefthalf.filled", "defensa": "shield.checkered", "comisaria": "light.beacon.max.fill", "gobmar": "water.waves", "energia": "bolt.fill", "industrial": "gearshape.2.fill"]

func etiqueta(_ texto: String, y: Double, grande: Bool, icono: String? = nil, color: NSColor = .systemBlue) -> SCNNode {
    let fuente = NSFont.systemFont(ofSize: grande ? 44 : 30, weight: .semibold)
    let attr: [NSAttributedString.Key: Any] = [.font: fuente, .foregroundColor: NSColor.white]
    let tam = (texto as NSString).size(withAttributes: attr)
    let alto = tam.height + 16
    let d: CGFloat = icono == nil ? 0 : alto + 34              // insignia redonda con el ícono, a la izquierda del nombre
    let sep: CGFloat = icono == nil ? 0 : 10
    let img = NSImage(size: NSSize(width: d + sep + tam.width + 36, height: max(alto, d)), flipped: false) { r in
        let pill = NSRect(x: d + sep, y: (r.height - alto) / 2, width: tam.width + 36, height: alto)
        NSColor(calibratedRed: 0.04, green: 0.06, blue: 0.1, alpha: 0.82).setFill()
        NSBezierPath(roundedRect: pill, xRadius: alto / 2, yRadius: alto / 2).fill()
        (texto as NSString).draw(at: NSPoint(x: pill.minX + 18, y: pill.minY + 8), withAttributes: attr)
        if let icono {
            let c = NSRect(x: 2, y: 2, width: d - 4, height: d - 4)
            color.setFill(); NSBezierPath(ovalIn: c).fill()
            NSColor.white.setStroke(); let b = NSBezierPath(ovalIn: c.insetBy(dx: 3, dy: 3)); b.lineWidth = 6; b.stroke()
            let cfg = NSImage.SymbolConfiguration(pointSize: d * 0.42, weight: .bold).applying(.init(paletteColors: [.white]))
            if let sym = NSImage(systemSymbolName: icono, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                let t = sym.size
                sym.draw(in: NSRect(x: c.midX - t.width / 2, y: c.midY - t.height / 2, width: t.width, height: t.height))
            }
        }
        return true
    }
    let k: CGFloat = grande ? 0.034 : 0.012
    let plano = SCNPlane(width: img.size.width * k, height: img.size.height * k)
    let m = SCNMaterial(); m.diffuse.contents = img; m.lightingModel = .constant; m.isDoubleSided = true
    m.readsFromDepthBuffer = !grande
    plano.materials = [m]
    let n = SCNNode(geometry: plano)
    n.position.y = CGFloat(y)
    n.constraints = [SCNBillboardConstraint()]
    n.renderingOrder = 10
    n.castsShadow = false
    return n
}

struct Azar {
    private var s: UInt64
    init(semilla: UInt64) { s = (semilla &* 0x9E37_79B9_7F4A_7C15) | 1 }
    mutating func real() -> CGFloat {
        s ^= s << 13; s ^= s >> 7; s ^= s << 17
        return CGFloat(s >> 11) / CGFloat(UInt64(1) << 53)
    }
}

enum Textura: Int { case arena, pasto, adoquin, marmol, estuco, corteza, madera }

@MainActor
enum Mat {
    private static var cache: [Textura: CGImage] = [:]

    static func pbr(_ c: NSColor, rugosidad: CGFloat = 0.7, metal: CGFloat = 0) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = c
        m.roughness.contents = rugosidad
        m.metalness.contents = metal
        return m
    }

    static func emisivo(_ c: NSColor, fuerza: CGFloat = 1) -> SCNMaterial {
        let m = pbr(c, rugosidad: 0.4)
        m.emission.contents = c
        m.emission.intensity = fuerza
        return m
    }

    static func textura(_ t: Textura, repetir: CGFloat, tinte: String? = nil, mezcla: CGFloat = 1) -> SCNMaterial {
        let m = pbr(.white, rugosidad: t == .marmol ? 0.35 : 0.88)
        m.diffuse.contents = imagen(t)
        m.diffuse.wrapS = .repeat; m.diffuse.wrapT = .repeat
        m.diffuse.mipFilter = .linear
        let r = max(1, repetir)
        m.diffuse.contentsTransform = SCNMatrix4MakeScale(r, r, 1)
        // Relieve: mapa normal calculado de la misma textura (juntas de adoquín, vetas, corteza); costo solo de GPU, mínimo.
        if t != .marmol {
            m.normal.contents = normal(t)
            m.normal.wrapS = .repeat; m.normal.wrapT = .repeat; m.normal.mipFilter = .linear
            m.normal.contentsTransform = SCNMatrix4MakeScale(r, r, 1)
            m.normal.intensity = 0.9
        }
        if let tinte {
            let c = NSColor(Color(hex: tinte)).usingColorSpace(.deviceRGB) ?? .white
            m.multiply.contents = NSColor(calibratedRed: 1 - (1 - c.redComponent) * mezcla, green: 1 - (1 - c.greenComponent) * mezcla,
                                          blue: 1 - (1 - c.blueComponent) * mezcla, alpha: 1)
        }
        return m
    }

    private static var cacheNormal: [Textura: CGImage] = [:]

    /// Mapa normal a partir del brillo de la textura (operador de Sobel), una vez por textura.
    private static func normal(_ t: Textura) -> CGImage {
        if let i = cacheNormal[t] { return i }
        let s = 256, fuerza: CGFloat = [.adoquin: 7, .corteza: 6, .madera: 3, .pasto: 4, .arena: 3, .estuco: 2.5][t] ?? 3
        var px = [UInt8](repeating: 0, count: s * s * 4)
        px.withUnsafeMutableBytes { b in
            let ctx = CGContext(data: b.baseAddress, width: s, height: s, bitsPerComponent: 8, bytesPerRow: s * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(imagen(t), in: CGRect(x: 0, y: 0, width: s, height: s))
        }
        func h(_ x: Int, _ y: Int) -> CGFloat {
            let i = (((y + s) % s) * s + ((x + s) % s)) * 4
            return (CGFloat(px[i]) + CGFloat(px[i + 1]) + CGFloat(px[i + 2])) / 765
        }
        var out = [UInt8](repeating: 255, count: s * s * 4)
        for y in 0..<s {
            for x in 0..<s {
                let dx = (h(x + 1, y) - h(x - 1, y)) * fuerza, dy = (h(x, y + 1) - h(x, y - 1)) * fuerza
                let l = sqrt(dx * dx + dy * dy + 1), i = (y * s + x) * 4
                out[i] = UInt8(max(0, min(255, (-dx / l * 0.5 + 0.5) * 255)))
                out[i + 1] = UInt8(max(0, min(255, (dy / l * 0.5 + 0.5) * 255)))
                out[i + 2] = UInt8(max(0, min(255, (1 / l * 0.5 + 0.5) * 255)))
            }
        }
        let img = out.withUnsafeMutableBytes { b in
            CGContext(data: b.baseAddress, width: s, height: s, bitsPerComponent: 8, bytesPerRow: s * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
        cacheNormal[t] = img
        return img
    }

    private static func imagen(_ t: Textura) -> CGImage {
        if let i = cache[t] { return i }
        let s = 256
        let ctx = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var g = Azar(semilla: UInt64(t.rawValue + 11))
        func color(_ r: CGFloat, _ gg: CGFloat, _ b: CGFloat, _ v: CGFloat, _ k: inout Azar) -> CGColor {
            let d = (k.real() - 0.5) * 2 * v
            return CGColor(red: r + d, green: gg + d, blue: b + d, alpha: 1)
        }
        let base: (CGFloat, CGFloat, CGFloat, CGFloat) = {
            switch t {
            case .arena: return (0.86, 0.78, 0.6, 0.06)
            case .pasto: return (0.30, 0.50, 0.22, 0.07)
            case .adoquin: return (0.62, 0.60, 0.56, 0.05)
            case .marmol: return (0.93, 0.92, 0.90, 0.02)
            case .estuco: return (0.95, 0.94, 0.92, 0.03)
            case .corteza: return (0.38, 0.27, 0.18, 0.05)
            case .madera: return (0.86, 0.73, 0.56, 0.04)
            }
        }()
        ctx.setFillColor(CGColor(red: base.0, green: base.1, blue: base.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        switch t {
        case .adoquin:
            let n = 4, w = CGFloat(s) / CGFloat(n)
            ctx.setFillColor(CGColor(red: 0.42, green: 0.40, blue: 0.37, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
            for j in 0..<n { for i in 0..<n + 1 {
                let x = CGFloat(i) * w - (j % 2 == 0 ? 0 : w / 2)
                ctx.setFillColor(color(base.0, base.1, base.2, 0.07, &g))
                ctx.addPath(CGPath(roundedRect: CGRect(x: x + 3, y: CGFloat(j) * w + 3, width: w - 6, height: w - 6), cornerWidth: 6, cornerHeight: 6, transform: nil))
                ctx.fillPath()
            } }
        case .madera:
            for k in 0..<40 {
                ctx.setFillColor(color(base.0, base.1, base.2, 0.08, &g))
                ctx.fill(CGRect(x: 0, y: CGFloat(k) * 6.4, width: CGFloat(s), height: 3 + g.real() * 4))
            }
        case .corteza:
            for k in 0..<32 {
                ctx.setFillColor(color(base.0 * 0.8, base.1 * 0.8, base.2 * 0.8, 0.05, &g))
                ctx.fill(CGRect(x: CGFloat(k) * 8, y: 0, width: 2 + g.real() * 3, height: CGFloat(s)))
            }
        case .marmol:
            ctx.setLineWidth(1.4)
            for _ in 0..<7 {
                ctx.setStrokeColor(CGColor(red: 0.62, green: 0.62, blue: 0.64, alpha: 0.45))
                ctx.move(to: CGPoint(x: g.real() * 256, y: 0))
                ctx.addCurve(to: CGPoint(x: g.real() * 256, y: 256), control1: CGPoint(x: g.real() * 256, y: 85), control2: CGPoint(x: g.real() * 256, y: 170))
                ctx.strokePath()
            }
        default: break
        }
        // Grano fino para que nada se vea plano
        for _ in 0..<5000 {
            ctx.setFillColor(color(base.0, base.1, base.2, base.3, &g).copy(alpha: 0.55)!)
            let x = g.real() * CGFloat(s), y = g.real() * CGFloat(s), r = 1 + g.real() * (t == .pasto ? 3 : 2)
            ctx.fill(CGRect(x: x, y: y, width: r, height: r))
        }
        let img = ctx.makeImage()!
        cache[t] = img
        return img
    }
}

/// Cielo panorámico (equirectangular) según la hora: degradé, arrebol y estrellas de noche.
enum Cielo {
    static func imagen(dia: Double, atardecer: Double) -> CGImage {
        let w = 1024, h = 512
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func mezcla(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> (Double, Double, Double) {
            (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
        }
        let arriba = mezcla((0.02, 0.03, 0.09), (0.22, 0.47, 0.84), dia)
        var horizonte = mezcla((0.07, 0.09, 0.2), (0.74, 0.85, 0.96), dia)
        horizonte = mezcla(horizonte, (1.0, 0.56, 0.32), atardecer * 0.8)
        let abajo = mezcla((0.02, 0.03, 0.06), (0.45, 0.55, 0.62), dia)
        let cs = CGColorSpaceCreateDeviceRGB()
        let col = { (c: (Double, Double, Double)) in CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1) }
        let grad = CGGradient(colorsSpace: cs, colors: [col(abajo), col(horizonte), col(arriba)] as CFArray, locations: [0.42, 0.5, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: h), options: [])
        if false {      // las estrellas ahora son puntos nítidos (cieloEstrellado); en la imagen se veían difusas
            var g = Azar(semilla: 99)
            for _ in 0..<900 {
                let y = CGFloat(h) * (0.55 + g.real() * 0.45), r = 0.6 + g.real() * 1.4
                ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: (0.4 + g.real() * 0.6) * (1 - dia * 2)))
                ctx.fillEllipse(in: CGRect(x: g.real() * CGFloat(w), y: y, width: r, height: r))
            }
        }
        return ctx.makeImage()!
    }
}


/// Cielo estrellado nítido: estrellas como puntos de 1 a 2,5 px en pantalla (no se agrandan con el zoom), sobre una
/// cúpula que sigue a la cámara. Se dibujan primero y sin profundidad: todo lo demás queda delante.
@MainActor
func cieloEstrellado() -> SCNNode {
    var g = Azar(semilla: 99)
    func capa(_ n: Int, radio px: CGFloat, brillo: ClosedRange<CGFloat>) -> SCNNode {
        var v: [SCNVector3] = [], c: [Float] = []
        for _ in 0..<n {
            let az = g.real() * 2 * .pi, el = asin(0.03 + g.real() * 0.97), r: CGFloat = 150
            v.append(SCNVector3(cos(el) * sin(az) * r, sin(el) * r, cos(el) * cos(az) * r))
            let b = brillo.lowerBound + g.real() * (brillo.upperBound - brillo.lowerBound), t = g.real()
            c += [Float(b * (0.86 + 0.14 * t)), Float(b * 0.93), Float(b * (1 - 0.1 * t)), 1]
        }
        let colores = SCNGeometrySource(data: Data(bytes: c, count: c.count * 4), semantic: .color, vectorCount: n,
                                        usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
        let e = SCNGeometryElement(indices: (0..<Int32(n)).map { $0 }, primitiveType: .point)
        e.pointSize = 1; e.minimumPointScreenSpaceRadius = px; e.maximumPointScreenSpaceRadius = px
        let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: v), colores], elements: [e])
        let m = SCNMaterial(); m.lightingModel = .constant; m.diffuse.contents = NSColor.white
        m.writesToDepthBuffer = false; m.readsFromDepthBuffer = false
        geo.materials = [m]
        let nodo = SCNNode(geometry: geo); nodo.castsShadow = false; nodo.renderingOrder = -100
        return nodo
    }
    let raiz = SCNNode()
    raiz.addChildNode(capa(2200, radio: 0.75, brillo: 0.4...0.85))
    raiz.addChildNode(capa(320, radio: 1.25, brillo: 0.8...1.0))
    raiz.addChildNode(capa(50, radio: 1.7, brillo: 1.0...1.0))
    return raiz
}
