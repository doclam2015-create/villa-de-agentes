import Foundation
import CoreGraphics

/// Grilla de caminata de la villa (como navBuild de la villa web): cada obstáculo marca sus
/// celdas ocupadas, ensanchadas por el radio de una persona. Las rutas se buscan con A*
/// (8 direcciones) y se suavizan por línea de vista: nadie atraviesa muros, muebles ni barandas.
final class Navegacion {
    let celda: CGFloat = 0.3
    let origen: CGFloat = -205        // cubre la isla principal y las islas del aeropuerto y del distrito
    let n = 1367
    let margen: CGFloat = 0.28           // radio de una persona
    private(set) var bloq: [Bool]

    init() { bloq = Array(repeating: false, count: n * n) }

    @inline(__always) func celdaDe(_ x: CGFloat, _ z: CGFloat) -> (Int, Int) {
        (Int(((x - origen) / celda).rounded(.down)), Int(((z - origen) / celda).rounded(.down)))
    }
    @inline(__always) func centro(_ i: Int, _ j: Int) -> CGPoint {
        CGPoint(x: origen + (CGFloat(i) + 0.5) * celda, y: origen + (CGFloat(j) + 0.5) * celda)
    }
    @inline(__always) func libre(_ i: Int, _ j: Int) -> Bool {
        i >= 0 && j >= 0 && i < n && j < n && !bloq[j * n + i]
    }
    func libre(_ p: CGPoint) -> Bool { let (i, j) = celdaDe(p.x, p.y); return libre(i, j) }

    /// Rectángulo girado (centro, semiejes, ángulo en Y). valor=false lo libera (puertas, escaleras).
    func rect(_ cx: CGFloat, _ cz: CGFloat, _ hx: CGFloat, _ hz: CGFloat, _ yaw: CGFloat, valor: Bool = true, margen m: CGFloat? = nil) {
        let mm = m ?? margen
        let r = hypot(hx, hz) + mm
        let (i0, j0) = celdaDe(cx - r, cz - r), (i1, j1) = celdaDe(cx + r, cz + r)
        let c = cos(yaw), s = sin(yaw)
        guard max(0, j0) <= min(n - 1, j1), max(0, i0) <= min(n - 1, i1) else { return }
        for j in max(0, j0)...min(n - 1, j1) {
            for i in max(0, i0)...min(n - 1, i1) {
                let p = centro(i, j), dx = p.x - cx, dz = p.y - cz
                let lx = dx * c - dz * s, lz = dx * s + dz * c
                if abs(lx) <= hx + mm && abs(lz) <= hz + mm { bloq[j * n + i] = valor }
            }
        }
    }

    func circulo(_ cx: CGFloat, _ cz: CGFloat, _ r: CGFloat, valor: Bool = true) {
        let rr = r + margen
        let (i0, j0) = celdaDe(cx - rr, cz - rr), (i1, j1) = celdaDe(cx + rr, cz + rr)
        guard max(0, j0) <= min(n - 1, j1), max(0, i0) <= min(n - 1, i1) else { return }
        for j in max(0, j0)...min(n - 1, j1) {
            for i in max(0, i0)...min(n - 1, i1) {
                let p = centro(i, j)
                if hypot(p.x - cx, p.y - cz) <= rr { bloq[j * n + i] = valor }
            }
        }
    }

    /// Baranda circular con un hueco (ángulo central y ancho angular) para la escalera.
    func anillo(_ cx: CGFloat, _ cz: CGFloat, _ r: CGFloat, hueco: CGFloat, ancho: CGFloat) {
        let rr = r + 1
        let (i0, j0) = celdaDe(cx - rr, cz - rr), (i1, j1) = celdaDe(cx + rr, cz + rr)
        guard max(0, j0) <= min(n - 1, j1), max(0, i0) <= min(n - 1, i1) else { return }
        for j in max(0, j0)...min(n - 1, j1) {
            for i in max(0, i0)...min(n - 1, i1) {
                let p = centro(i, j), d = hypot(p.x - cx, p.y - cz)
                guard abs(d - r) <= margen + 0.15 else { continue }
                var a = atan2(p.y - cz, p.x - cx) - hueco
                while a > .pi { a -= 2 * .pi }; while a < -.pi { a += 2 * .pi }
                if abs(a) > ancho / 2 { bloq[j * n + i] = true }
            }
        }
    }

    /// Celda libre más cercana (por si alguien queda dentro de un margen).
    func cercanaLibre(_ p: CGPoint) -> CGPoint {
        let (i, j) = celdaDe(p.x, p.y)
        if libre(i, j) { return p }
        for r in 1...25 {
            for dj in -r...r { for di in -r...r where abs(di) == r || abs(dj) == r {
                if libre(i + di, j + dj) { return centro(i + di, j + dj) }
            } }
        }
        return p
    }

    // MARK: A*

    private var g: [Float] = []
    private var desde: [Int32] = []
    private var visto: [UInt32] = []
    private var cerrado: [UInt32] = []
    private var sello: UInt32 = 0

    func ruta(_ a: CGPoint, _ b: CGPoint) -> [CGPoint] {
        let a = cercanaLibre(a), b = cercanaLibre(b)
        let (ai, aj) = celdaDe(a.x, a.y), (bi, bj) = celdaDe(b.x, b.y)
        if g.isEmpty { g = Array(repeating: 0, count: n * n); desde = Array(repeating: -1, count: n * n); visto = Array(repeating: 0, count: n * n) }
        sello &+= 1
        let ini = aj * n + ai, fin = bj * n + bi
        var heap = Monticulo()
        g[ini] = 0; desde[ini] = -1; visto[ini] = sello
        heap.push(h(ai, aj, bi, bj), ini)
        if cerrado.isEmpty { cerrado = Array(repeating: 0, count: n * n) }
        let pasos: [(Int, Int, Float)] = [(1, 0, 1), (-1, 0, 1), (0, 1, 1), (0, -1, 1), (1, 1, 1.4142), (1, -1, 1.4142), (-1, 1, 1.4142), (-1, -1, 1.4142)]
        var hallado = false, iter = 0
        while let (_, k) = heap.pop() {
            if k == fin { hallado = true; break }
            if cerrado[k] == sello { continue }
            cerrado[k] = sello
            iter += 1; if iter > 160_000 { break }
            let i = k % n, j = k / n
            for (di, dj, c) in pasos {
                let ni = i + di, nj = j + dj
                guard libre(ni, nj) else { continue }
                if di != 0 && dj != 0 && (!libre(i + di, j) || !libre(i, j + dj)) { continue } // no cortar esquinas
                let nk = nj * n + ni, ng = g[k] + c
                if visto[nk] != sello || ng < g[nk] {
                    visto[nk] = sello; g[nk] = ng; desde[nk] = Int32(k)
                    heap.push(ng + h(ni, nj, bi, bj), nk)
                }
            }
        }
        guard hallado else { return [] }
        var celdas: [Int] = []
        var k = fin
        while k != -1 { celdas.append(k); if k == ini { break }; k = Int(desde[k]) }
        celdas.reverse()
        var pts = celdas.map { centro($0 % n, $0 / n) }
        pts[0] = a; pts[pts.count - 1] = b
        return suavizar(pts)
    }

    @inline(__always) private func h(_ i: Int, _ j: Int, _ bi: Int, _ bj: Int) -> Float {
        let dx = Float(abs(i - bi)), dy = Float(abs(j - bj))
        return max(dx, dy) + 0.4142 * min(dx, dy)
    }

    /// Quita puntos intermedios mientras haya línea de vista libre.
    private func suavizar(_ p: [CGPoint]) -> [CGPoint] {
        guard p.count > 2 else { return p }
        var r = [p[0]], i = 0
        while i < p.count - 1 {
            var j = p.count - 1
            while j > i + 1 && !vista(p[i], p[j]) { j -= 1 }
            r.append(p[j]); i = j
        }
        return r
    }

    func vista(_ a: CGPoint, _ b: CGPoint) -> Bool {
        let d = hypot(b.x - a.x, b.y - a.y), pasos = max(1, Int(d / (celda * 0.5)))
        for s in 0...pasos {
            let t = CGFloat(s) / CGFloat(pasos)
            if !libre(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)) { return false }
        }
        return true
    }
}

/// Montículo binario mínimo para A*.
struct Monticulo {
    private var a: [(Float, Int)] = []
    mutating func push(_ f: Float, _ k: Int) {
        a.append((f, k)); var i = a.count - 1
        while i > 0 { let p = (i - 1) / 2; if a[p].0 <= a[i].0 { break }; a.swapAt(p, i); i = p }
    }
    mutating func pop() -> (Float, Int)? {
        guard !a.isEmpty else { return nil }
        let r = a[0]; let u = a.removeLast()
        if !a.isEmpty {
            a[0] = u; var i = 0
            while true {
                let l = 2 * i + 1, d = l + 1; var m = i
                if l < a.count && a[l].0 < a[m].0 { m = l }
                if d < a.count && a[d].0 < a[m].0 { m = d }
                if m == i { break }; a.swapAt(m, i); i = m
            }
        }
        return r
    }
}
