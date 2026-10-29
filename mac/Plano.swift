import SwiftUI

// MARK: - Plano desplegable de la villa
//
// Mapa visto desde arriba con la isla principal, sus barrios, la costa, las islas del aeropuerto, del distrito y de
// defensa, el puerto, el mall y la flota. Un clic en cualquier lugar vuela la cámara hasta ahí (sin pasar por la
// vista general). Los barrios con agentes en atención se marcan en rojo.

struct LugarPlano: Identifiable {
    let id: String, nombre: String, p: CGPoint, icono: String, color: Color
    var barrio: String? = nil, distancia: CGFloat = 40
}

@MainActor
enum PlanoVilla {
    static func lugares(_ almacen: Almacen) -> [LugarPlano] {
        var l: [LugarPlano] = []
        for (zid, c) in Villa3D.Coordinador.posiciones {
            let z = almacen.zonas[zid]
            l.append(LugarPlano(id: zid, nombre: z?.name ?? zid, p: c, icono: iconoBarrio[zid] ?? "circle.fill",
                                color: Color(hex: z?.roof ?? "#888888"), barrio: zid))
        }
        l.append(LugarPlano(id: "sede", nombre: "Sede de gobierno", p: .zero, icono: "building.columns.fill", color: Color(hex: "#b8892b"), barrio: "sede-palacio"))
        let costa: [(String, String, CGFloat, String)] = [
                                                          ("balneario", "Balneario", Islas.angBalneario, "beach.umbrella.fill"),
                                                          ("marina", "Marina", Islas.angMarina, "sailboat.fill"),
                                                          ("letrero", "Letrero Silicon Villa", .pi, "sparkles")]
        for (id, n, x, z, i) in [("restaurante", "Restaurante El Mirador", CGFloat(34), CGFloat(-12), "fork.knife"), ("cafeteria", "Café del Valle", -33, -8, "cup.and.saucer.fill"),
                                 ("iglesia", "Iglesia de la Villa", 37, 11.5, "leaf.fill")] {
            l.append(LugarPlano(id: id, nombre: n, p: Islas.dist(x, z), icono: i, color: .purple, distancia: 30))
        }
        l.append(LugarPlano(id: "caleta", nombre: "Caleta de pescadores", p: Islas.caleta(0, 0), icono: "fish.fill", color: .cyan, distancia: 40))
        for (id, n, a, i) in costa { l.append(LugarPlano(id: id, nombre: n, p: Islas.polar(84, a), icono: i, color: .cyan, distancia: 34)) }
        l.append(LugarPlano(id: "flota", nombre: "Flota de la Armada", p: Islas.polar(185, PuertoYFlota.flotaAng), icono: "shield.lefthalf.filled", color: .gray, barrio: "flota"))
        for k in MetroVilla.estaciones.indices {
            let e = MetroVilla.estaciones[k]
            l.append(LugarPlano(id: "metro-" + e.id, nombre: "Metro · " + e.nombre.capitalized, p: MetroVilla.posicion(k), icono: "tram.fill", color: Color(nsColor: MetroVilla.rojo), distancia: 42))
        }
        l.append(LugarPlano(id: "metro-cocheras", nombre: "Cocheras y Talleres del Metro", p: MetroVilla.centroCocheras, icono: "wrench.and.screwdriver.fill", color: Color(nsColor: MetroVilla.rojo), distancia: 70))
        return l
    }
}

struct VistaPlano: View {
    @EnvironmentObject var almacen: Almacen
    @ObservedObject var c = ControlVilla.shared
    @State private var sobre: String?
    private let alcance: CGFloat = 232        // metros desde el centro hasta el borde del plano

    var body: some View {
        let lugares = PlanoVilla.lugares(almacen)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { withAnimation(.easeInOut(duration: 0.25)) { c.planoAbierto.toggle() } } label: {
                    HStack(spacing: 6) {
                        Label("Plano", systemImage: "map.fill").font(.headline)
                        Image(systemName: c.planoAbierto ? "chevron.down" : "chevron.up").font(.caption.bold())
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).help(c.planoAbierto ? "Plegar el plano" : "Desplegar el plano")
                if c.planoAbierto {
                    Spacer()
                    Button { c.verPlano = false } label: { Image(systemName: "xmark.circle.fill").font(.title3) }.buttonStyle(.plain).help("Ocultar el plano (vuelve con el botón Plano)")
                }
            }
            if c.planoAbierto {
            GeometryReader { g in
                let lado = min(g.size.width, g.size.height), esc = lado / (2 * alcance)
                let centro = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
                // Norte arriba: el +z del mundo hacia abajo de la pantalla (como se ve desde la vista general)
                let aPantalla = { (p: CGPoint) in CGPoint(x: centro.x + p.x * esc, y: centro.y + p.y * esc) }
                ZStack {
                    Canvas { ctx, _ in
                        func circulo(_ p: CGPoint, _ r: CGFloat, _ color: Color) {
                            let q = aPantalla(p); ctx.fill(Path(ellipseIn: CGRect(x: q.x - r * esc, y: q.y - r * esc, width: 2 * r * esc, height: 2 * r * esc)), with: .color(color))
                        }
                        ctx.fill(Path(CGRect(x: 0, y: 0, width: g.size.width, height: g.size.height)), with: .color(Color(red: 0.1, green: 0.3, blue: 0.42)))
                        // Tierra firme, islas y playas
                        let tierra = CGPoint(x: sin(Villa3D.Coordinador.acceso) * 606, y: cos(Villa3D.Coordinador.acceso) * 606)
                        circulo(tierra, 412, Color(red: 0.87, green: 0.8, blue: 0.62)); circulo(tierra, 402, Color(red: 0.42, green: 0.6, blue: 0.35))
                        for (p, r) in [(CGPoint.zero, CGFloat(76)), (Islas.aero(0, 0), Islas.radioAero), (Islas.dist(0, 0), Islas.radioDist), (Islas.def(0, 0), Islas.radioDef), (Islas.caleta(0, 0), Islas.radioCaleta), (Islas.fa(0, 0), Islas.radioFA), (Islas.naval(0, 0), Islas.radioNav), (Islas.ener(0, 0), Islas.radioEner)] {
                            circulo(p, r + 9, Color(red: 0.9, green: 0.84, blue: 0.66)); circulo(p, r, Color(red: 0.36, green: 0.6, blue: 0.32))
                        }
                        // Caminos: anillo, avenidas y pedraplenes
                        var anillo = Path(); anillo.addEllipse(in: CGRect(x: centro.x - 60 * esc, y: centro.y - 60 * esc, width: 120 * esc, height: 120 * esc))
                        ctx.stroke(anillo, with: .color(.black.opacity(0.55)), lineWidth: max(1.5, 3 * esc))
                        var circ = Path(); circ.addEllipse(in: CGRect(x: centro.x - 21 * esc, y: centro.y - 21 * esc, width: 42 * esc, height: 42 * esc))
                        ctx.stroke(circ, with: .color(.black.opacity(0.4)), lineWidth: max(1, 2 * esc))
                        for (a, hasta) in [(Villa3D.Coordinador.acceso, CGFloat(232)), (Islas.angAero, Islas.rAero - Islas.radioAero + 2),
                                           (Islas.angDist, Islas.rDist - Islas.radioDist + 2), (Islas.angDef, Islas.rDef - Islas.radioDef + 2), (Islas.angCaleta, Islas.rCaleta - Islas.radioCaleta + 2), (Islas.angNav, Islas.rNav - Islas.radioNav + 2), (Islas.angEner, Islas.rEner - Islas.radioEner + 2)] {
                            var c = Path(); c.move(to: aPantalla(Islas.polar(21, a))); c.addLine(to: aPantalla(Islas.polar(hasta, a)))
                            ctx.stroke(c, with: .color(.black.opacity(0.55)), lineWidth: max(1.5, 3 * esc))
                        }
                        var pfa = Path(); pfa.move(to: aPantalla(Islas.puenteFA.0)); pfa.addLine(to: aPantalla(Islas.puenteFA.1))
                        ctx.stroke(pfa, with: .color(.black.opacity(0.55)), lineWidth: max(1.5, 3 * esc))
                        // Metro: Línea Circular y ramal a las cocheras
                        let rm = MetroVilla.radio * esc, cm = aPantalla(.zero)
                        ctx.stroke(Path(ellipseIn: CGRect(x: cm.x - rm, y: cm.y - rm, width: 2 * rm, height: 2 * rm)), with: .color(Color(nsColor: MetroVilla.rojo)), lineWidth: max(2, 3.5 * esc))
                        var ramal = Path(); ramal.move(to: aPantalla(MetroVilla.ramalCtrl[0]))
                        for q in MetroVilla.ramalCtrl.dropFirst().dropLast() { ramal.addLine(to: aPantalla(q)) }
                        ramal.addLine(to: aPantalla(MetroVilla.centroCocheras))
                        ctx.stroke(ramal, with: .color(Color(nsColor: MetroVilla.rojo)), style: StrokeStyle(lineWidth: max(1.5, 2.5 * esc), dash: [4, 3]))
                        // Pistas del aeropuerto y de la base aérea
                        for (marco, pistas) in [(Islas.aero, [(-32.0, 52.0, 4.0), (-28.0, 48.0, 24.0)]), (Islas.fa, [(-26.0, 26.0, 8.0)])] as [((CGFloat, CGFloat) -> CGPoint, [(Double, Double, Double)])] {
                            for (x0, x1, z) in pistas {
                                var p = Path(); p.move(to: aPantalla(marco(CGFloat(x0), CGFloat(z)))); p.addLine(to: aPantalla(marco(CGFloat(x1), CGFloat(z))))
                                ctx.stroke(p, with: .color(Color(white: 0.2)), lineWidth: max(2, 6 * esc))
                            }
                        }
                    }
                    // Lugares (con clic)
                    ForEach(lugares) { lu in
                        let q = aPantalla(lu.p)
                        let alerta = almacen.agentes.contains { $0.zona == lu.id && $0.enAtencion }
                        Button { ir(lu) } label: {
                            Image(systemName: lu.icono).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 20, height: 20).background(alerta ? Color.red : lu.color, in: Circle())
                                .overlay(Circle().stroke(.white, lineWidth: sobre == lu.id ? 2 : 1))
                        }
                        .buttonStyle(.plain).help(lu.nombre)
                        .onHover { sobre = $0 ? lu.id : (sobre == lu.id ? nil : sobre) }
                        .position(q)
                    }
                    if let s = sobre, let lu = lugares.first(where: { $0.id == s }) {
                        Text(lu.nombre).font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.regularMaterial, in: Capsule()).position(x: aPantalla(lu.p).x, y: aPantalla(lu.p).y - 18)
                    }
                }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { e in
                    let w = CGPoint(x: (e.location.x - centro.x) / esc, y: (e.location.y - centro.y) / esc)
                    c.elemento = nil; c.coord?.volarA(w, distancia: 45)
                })
            }
            .frame(width: 260, height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Text("Clic en un ícono o en el mapa: vuela ahí").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(width: c.planoAbierto ? 280 : nil)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func ir(_ lu: LugarPlano) {
        switch lu.barrio {
        case "sede-palacio": c.abrirSede()
        case "flota": c.mostrarElemento("flota-portaaviones"); c.coord?.irFlota()
        case let z?: c.irBarrio(z)
        case nil where lu.id.hasPrefix("metro"): c.mostrarElemento(lu.id); c.coord?.volarA(lu.p, distancia: lu.distancia, deFrente: true)
        case nil: c.elemento = nil; c.coord?.volarA(lu.p, distancia: lu.distancia, deFrente: true)
        }
    }
}
