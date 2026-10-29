# Villa de Agentes

Una villa 3D para macOS (SwiftUI + SceneKit) donde cada **agente automático** de tu Mac —un script, un servicio de `launchd`, una tarea en la nube— tiene su oficina, su personaje y su pizarra. Los ves caminar, trabajar y avisar cuando algo necesita atención.

- Isla principal con barrios (hospital, biblioteca, La nube, taller de apps, bodega del Mac), sede de gobierno con audiencia, puerto con barcos y flota protectora, centro comercial, cuartel de bomberos, tránsito con física, día y noche según la hora del Mac.
- Islas unidas por puentes: aeropuerto internacional (dos pistas, vuelos coordinados), distrito con Trade Center, banco, casino, universidad, centro científico y museo de agentes retirados, y una isla por rama de defensa (Ejército, Fuerza Aérea junto al aeropuerto y Armada junto al puerto, bajo una Gobernación Marítima y un Ministerio de Defensa), además de una comisaría.
- Costa con caleta de pescadores en su islote, balneario con bañistas articulados, marina y mar con oleaje en la GPU; letreros «SILICON VILLA».
- Plano desplegable (botón «Plano») y cámara que llega de frente y busca sola una vista sin edificios que tapen el destino.
- Pizarras con estado, horario, historial y botón «Ejecutar ahora»; centro de mando con salud del Mac y alarma; paneles de gastos y de tokens con gráficos.

La primera vez se abre con una **villa de ejemplo** (agentes ficticios). Ningún dato sale de tu Mac.

## Requisitos

- macOS 14 o posterior.
- Herramientas de línea de comandos de Xcode: `xcode-select --install`.
- Opcional, para el ícono: `pip3 install pillow`.

## Compilar e instalar

```sh
git clone https://github.com/<tu-usuario>/villa-de-agentes.git
cd villa-de-agentes
./build.sh                # compila e instala en /Applications
./build.sh --solo-compilar  # solo compila
```

## Agregar tus agentes

Botón **Agentes** en la barra de herramientas → nombre, barrio, qué hace, horario y (opcional) el servicio de `launchd` (`com.tu.agente`). Su oficina aparece al instante en el barrio elegido. Desde la misma hoja puedes quitarlos (no se toca su programa).

También puedes editar los archivos directamente en `~/Library/Application Support/Villa de Agentes/`:

| Archivo | Contenido |
|---|---|
| `agentes.json` | Barrios (`zonas`) y agentes (`agentes`: `id`, `zone`, `name`, `status`, `does`, `sched`, `plist`…). |
| `estado.json` | Estado en vivo opcional: `{"generado": 0, "agentes": {"<id>": {"status": "ok", "last": "…", "next": "…", "nota": "…"}}}`. |
| `resultados/<id>.json` | Resultado de cada agente: `{"status": "ok", "resumen": "…", "detalle": ["…"]}`. |
| `trabajo/museo.json` | Piezas del museo (agentes retirados). |

Estados: `ok`, `fixed`, `warn` (atención), `crit`, `off` (apagado a propósito). Un agente con `plist` se ejecuta con «Ejecutar ahora» (`launchctl kickstart`).

Los identificadores de barrio son fijos porque cada uno tiene su lugar en la isla: `urg`, `cer`, `nube`, `ios`, `mac`, `sede`, `mall`, `puerto`, `aeropuerto`, `trade`, `banco`, `casino`, `museo`, `uni`, `ciencia`, `fach`, `armada`, `ejercito`, `defensa`, `comisaria`, `gobmar`. Sus nombres visibles sí se pueden cambiar.

## Privacidad

La app solo lee su carpeta de datos y, en modo lectura, el estado del propio Mac (espacio en disco, memoria, carga) para el centro de mando. No envía nada a internet. La audiencia con IA es opcional y solo funciona si tú levantas un servidor local en `http://127.0.0.1:8790` con un endpoint `/preguntar`.

## Licencia

MIT.
