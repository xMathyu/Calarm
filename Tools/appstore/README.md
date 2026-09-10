# Tools/appstore

El pipeline de release y de capturas de la App Store, en scripts en vez de en la memoria de
nadie. Todos usan `ci_scripts/asc.py`, así que necesitan las credenciales en el entorno:

```sh
export ASC_KEY_ID=…            # llave de App Store Connect
export ASC_ISSUER_ID=…         # issuer de la misma página
```

## Sacar una versión

```sh
# 1. Subir MARKETING_VERSION en el proyecto y pushear a main.
#    El push dispara Xcode Cloud, que archiva Y sube el build. El número de build
#    lo pone Xcode Cloud y coincide con el de la corrida.
# 2. Esperar el build (sale en cuanto está subido):
./watch_build.py 60
# 3. Crear la versión en App Store Connect y cargarle la ficha (ver AppStoreMetadata.md,
#    que es la fuente de verdad de los textos), y entonces:
./submit.py 1.0.9 60
```

Tres trampas que ya costaron tiempo y están anotadas en los propios scripts:

- **El texto promocional no se copia** a la versión nueva. `POST /v1/appStoreVersions` clona
  keywords, descripción y URLs, pero deja `promotionalText` vacío: hay que PATCHearlo o sale
  a producción en blanco.
- **El nombre y el subtítulo no viven en la versión** sino en `appInfoLocalizations`. El
  appInfo publicado es de solo lectura; al crear una versión aparece un **segundo** appInfo
  editable, y es ese el que hay que PATCHear.
- **Crear un `appStoreVersionLocalization` para un locale nuevo crea también su
  `appInfoLocalization`.** Intentar crearla a mano después da 409: hay que PATCHearla.

## Capturas

```sh
export DEVICE=$(xcrun simctl list devices available | grep "iPhone 17 Pro Max" | grep -o "[0-9A-F-]\{36\}")
xcodebuild -scheme Calarm -destination "platform=iOS Simulator,id=$DEVICE" build   # sin CODE_SIGNING_ALLOWED=NO
xcrun simctl install $DEVICE <ruta>/Calarm.app
xcrun simctl privacy $DEVICE grant calendar MathyuSolutions.Calarm
xcrun simctl status_bar $DEVICE override --time "9:41" --batteryState charged --batteryLevel 100

./capture.sh es list  shots/es-1-lista.png seed    # "seed" siembra datos de demo
./capture.sh es editor shots/es-2-editor.png
./capture_page.sh es 0 shots/onb-es-0.png          # slides de bienvenida

python3 slides/make.py          # compone los titulares → slide-*.png (1320×2868)
python3 slides/make.py ipad     # → slide-ipad-*.png (2064×2752)
./upload_shots.py APP_IPHONE_67 "<locId>=slide-es-*.png"
```

`DemoData.swift` (solo DEBUG) llena la app con siete alarmas, una categoría propia y tres
eventos de calendario; `-demoScreen` abre una pantalla directa. Los títulos siguen el idioma
de lanzamiento, porque el título de una alarma es contenido del usuario.

**El árbol de accesibilidad del simulador no expone las vistas de la app**, así que AXPress no
sirve y los toques por coordenadas fallan la mitad de las veces: de ahí el router por
argumentos. Lo único que hay que atender a mano es el permiso de alarmas, una vez por
instalación, con Enter sobre la ventana del simulador:

```sh
osascript -e 'tell application "Simulator" to activate' -e 'delay 1' \
          -e 'tell application "System Events" to key code 36'
```
