import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

@MainActor
enum Exportador {
    /// Informe PDF en una carpeta temporal; la vista previa decide si se guarda o se comparte.
    static func pdf(_ al: Almacen) -> URL? {
        let texto = NSMutableAttributedString()
        func p(_ s: String, _ f: NSFont, _ c: NSColor = .black) {
            texto.append(NSAttributedString(string: s + "\n", attributes: [.font: f, .foregroundColor: c]))
        }
        p("Villa de Agentes — informe", .systemFont(ofSize: 20, weight: .bold))
        p(Date().formatted(date: .long, time: .shortened) + " · \(al.agentes.count) agentes · \(al.conProblemas.count) en atención\n", .systemFont(ofSize: 11), .darkGray)
        for (zid, z) in al.zonas.sorted(by: { $0.value.name < $1.value.name }) {
            p(z.name, .systemFont(ofSize: 14, weight: .semibold))
            for a in al.agentes where a.zona == zid {
                p("• \(a.nombre) — \(a.etiquetaEstado) · última \(a.ultima) · próxima \(a.proxima)", .systemFont(ofSize: 11, weight: .medium),
                  a.estado == "warn" ? .systemOrange : .black)
                if !a.resultado.isEmpty { p("   \(a.resultado)", .systemFont(ofSize: 10), .darkGray) }
                if let s = a.vivo?.solucion { p("   Solución: \(s)", .systemFont(ofSize: 10), .darkGray) }
            }
            p("", .systemFont(ofSize: 6))
        }
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 612, height: 792)
        info.topMargin = 40; info.bottomMargin = 40; info.leftMargin = 44; info.rightMargin = 44
        let vista = NSTextView(frame: NSRect(x: 0, y: 0, width: 612 - 88, height: 792 - 80))
        vista.textStorage?.setAttributedString(texto)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Informe Villa de Agentes \(Date().formatted(.iso8601.year().month().day())).pdf")
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let op = NSPrintOperation(view: vista, printInfo: info)
        op.showsPrintPanel = false; op.showsProgressPanel = false
        return op.run() ? url : nil
    }

    static func guardarCSV(_ al: Almacen) {
        let campo = { (s: String) in "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var csv = "Agente;Barrio;Estado;Última;Próxima;Resultado\n"
        for a in al.agentes {
            csv += [a.nombre, al.zonas[a.zona]?.name ?? a.zona, a.etiquetaEstado, a.ultima, a.proxima, a.resultado].map(campo).joined(separator: ";") + "\n"
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Agentes de la villa.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        if panel.runModal() == .OK, let u = panel.url {
            try? Data(("\u{FEFF}" + csv).utf8).write(to: u)  // BOM: Excel lee bien los acentos
            NSWorkspace.shared.activateFileViewerSelecting([u])
        }
    }

    static func compartir(_ u: URL) {
        guard let v = NSApp.keyWindow?.contentView else { return }
        NSSharingServicePicker(items: [u]).show(relativeTo: .zero, of: v, preferredEdge: .minY)
    }
}

/// Previsualizador real del PDF antes de guardarlo o compartirlo.
struct VistaPreviaPDF: View {
    let url: URL
    @Environment(\.dismiss) var cerrar
    var body: some View {
        VStack(spacing: 0) {
            PDFVista(url: url).frame(minWidth: 620, minHeight: 720)
            HStack {
                Button("Abrir en Vista Previa") { NSWorkspace.shared.open(url) }.help("Abre el PDF en la app Vista Previa")
                Button("Compartir…") { Exportador.compartir(url) }.help("Mail, Mensajes, AirDrop…")
                Spacer()
                Button("Cerrar") { cerrar() }.keyboardShortcut(.cancelAction)
                Button("Guardar…") {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = url.lastPathComponent
                    panel.allowedContentTypes = [.pdf]
                    if panel.runModal() == .OK, let d = panel.url {
                        try? FileManager.default.removeItem(at: d)
                        try? FileManager.default.copyItem(at: url, to: d)
                        NSWorkspace.shared.activateFileViewerSelecting([d])
                        cerrar()
                    }
                }.keyboardShortcut(.defaultAction).help("Guarda el informe donde elijas")
            }
            .padding(12)
        }
    }
}

struct PDFVista: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView(); v.autoScales = true; v.document = PDFDocument(url: url); return v
    }
    func updateNSView(_ v: PDFView, context: Context) {}
}
