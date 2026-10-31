import SwiftUI

@main
struct VillaDeAgentesApp: App {
    @StateObject private var almacen = Almacen()

    var body: some Scene {
        WindowGroup("Villa de Agentes") {
            VistaPrincipal()
                .environmentObject(almacen)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1400, height: 860)
        .commands {
            CommandMenu("Villa") {
                Button("Revisar ahora") { Task { await almacen.revisar() } }.keyboardShortcut("r")
                Button("Ejecutar agente seleccionado") { if let a = almacen.seleccionado { Task { await almacen.ejecutar(a) } } }
                    .keyboardShortcut("e").disabled(almacen.seleccionado?.servicio == nil)
                Button("Catálogo de la Fábrica (todas mis apps)") { ControlVilla.shared.verFabrica.toggle() }.keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Lupa de aumento") { ControlVilla.shared.lupa.toggle() }.keyboardShortcut("l")
                Button("Congelar o reanudar (para capturas)") { ControlVilla.shared.alternarCongelar() }.keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()
                Button("Acercar") { NotificationCenter.default.post(name: .villaCamara, object: "acercar") }.keyboardShortcut("+")
                Button("Alejar") { NotificationCenter.default.post(name: .villaCamara, object: "alejar") }.keyboardShortcut("-")
                Button("Girar a la izquierda") { NotificationCenter.default.post(name: .villaCamara, object: "izquierda") }.keyboardShortcut(.leftArrow)
                Button("Girar a la derecha") { NotificationCenter.default.post(name: .villaCamara, object: "derecha") }.keyboardShortcut(.rightArrow)
                Button("Ver desde más arriba") { NotificationCenter.default.post(name: .villaCamara, object: "subir") }.keyboardShortcut(.upArrow)
                Button("Ver más a ras de suelo") { NotificationCenter.default.post(name: .villaCamara, object: "bajar") }.keyboardShortcut(.downArrow)
                Button("Vista general") { NotificationCenter.default.post(name: .villaCamara, object: "general") }.keyboardShortcut("0")
                Divider()
                ForEach(Array(Seccion.allCases.enumerated()), id: \.offset) { i, s in
                    Button(s.rawValue) { UserDefaults.standard.set(s.rawValue, forKey: "seccion") }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                }
            }
        }
        Settings { VistaAjustes().environmentObject(almacen) }
    }
}
