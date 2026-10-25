#!/bin/zsh
# Compila «Villa de Agentes.app» (SwiftUI + SceneKit) y la instala en /Applications.
# Requiere macOS 14+ y las herramientas de línea de comandos de Xcode (xcode-select --install).
# --solo-compilar: solo compila.
set -e
cd "$(dirname "$0")"
APP="${TMPDIR:-/tmp}/villa-build/Villa de Agentes.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -parse-as-library mac/*.swift -o "$APP/Contents/MacOS/VillaDeAgentes" -target "$(uname -m)-apple-macos14.0"
cp mac/Info.plist "$APP/Contents/Info.plist"
python3 icono.py "$APP/Contents/Resources/AppIcon.icns" || echo "(Sin ícono: instala Pillow con «pip3 install pillow» y vuelve a compilar.)"
xattr -cr "$APP"
IDENT=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')
codesign --force --deep --sign "${IDENT:--}" "$APP"
[ "$1" = "--solo-compilar" ] && { echo "Compilada en $APP"; exit 0; }
osascript -e 'quit app "Villa de Agentes"' 2>/dev/null || true
if [ -d "/Applications/Villa de Agentes.app" ]; then
  mkdir -p "$HOME/Library/Application Support/VillaDeAgentes/respaldos-app"
  ditto "/Applications/Villa de Agentes.app" "$HOME/Library/Application Support/VillaDeAgentes/respaldos-app/Villa de Agentes $(date +%Y%m%d-%H%M%S).app"
  rm -rf "/Applications/Villa de Agentes.app"
fi
cp -R "$APP" /Applications/
echo "Instalada en /Applications/Villa de Agentes.app"
