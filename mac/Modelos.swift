import SceneKit
import AppKit

/// Modelos 3D descargados (Poly Pizza: CC-BY 3.0 y dominio público; créditos en modelos/CREDITOS.md), convertidos
/// con herramientas/glb2scn.swift a .scn binario: una sola malla, proa hacia +z, base en y = 0 y largo 1.
/// Cada archivo se lee una vez (milisegundos); cada uso es un clon que comparte la geometría, así que pesan casi nada en memoria.
/// Si falta un archivo, `nodo` devuelve nil y la villa usa el modelo dibujado a mano.
enum Modelos {
    private static var cache: [String: SCNNode] = [:]
    private static let candado = NSLock()

    private static func base(_ nombre: String) -> SCNNode? {
        candado.lock(); defer { candado.unlock() }
        if let n = cache[nombre] { return n }
        guard let url = Bundle.main.url(forResource: nombre, withExtension: "scn"),
              let n = (try? SCNScene(url: url))?.rootNode.childNodes.first else { return nil }
        n.castsShadow = false
        if nombre == "buque" {
            n.geometry?.materials.forEach { $0.isDoubleSided = true }   // su casco es de una sola cara: sin esto no se ve desde un costado
            n.eulerAngles.y = .pi   // viene con la proa (torres dobles delante del puente) hacia -z: navegaba de popa
        }
        cache[nombre] = n
        return n
    }

    /// Lee todos los modelos en segundo plano al abrir la villa, para que montar la escena no espere al disco.
    static func precargar() {
        DispatchQueue.global(qos: .userInitiated).async {
            for n in ["avion", "caza", "buque", "pesquero", "yate", "velero", "bus", "camionmil", "auto2", "suv", "tanque", "humvee", "heli", "ambulancia", "bomba", "camion", "policia", "moto", "carguero", "submarino", "bote", "tanquero", "pesquero2"] { _ = base(n) }
        }
    }

    /// Clon de `largo` metros. `pintura` recolorea los materiales con esos nombres; `cambios` reemplaza materiales por nombre
    /// (p. ej. faros que se encienden de noche).
    static func nodo(_ nombre: String, largo: CGFloat, pintura: (NSColor, Set<String>)? = nil, cambios: [String: SCNMaterial] = [:], nombreElem: String? = nil) -> SCNNode? {
        guard let b = base(nombre) else { return nil }
        let n = b.clone()
        if (pintura != nil || !cambios.isEmpty), let g = b.geometry?.copy() as? SCNGeometry {
            g.materials = g.materials.map { m in
                if let r = cambios[m.name ?? ""] { return r }
                if let (color, nombres) = pintura, nombres.contains(m.name ?? "") {
                    let p = m.copy() as! SCNMaterial; p.diffuse.contents = color; return p
                }
                return m
            }
            n.geometry = g
        }
        n.scale = SCNVector3(largo, largo, largo)
        let c = SCNNode(); c.name = nombreElem; c.addChildNode(n)   // contenedor: quien lo use puede escalarlo o girarlo libremente
        return c
    }
}
