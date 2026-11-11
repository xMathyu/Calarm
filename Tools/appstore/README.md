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

DEVICE=<iPhone> WAIT=15 ./capture_all.sh               # shots/es-1.png … en-7.png
DEVICE=<iPad> WAIT=15 PREFIX=ipad- ./capture_all.sh    # shots/ipad-es-1.png …
./capture.sh es list shots/es-1.png seed               # una sola; "seed" siembra datos de demo
./capture_page.sh es 0 shots/onb-es-0.png              # slides de bienvenida

python3 slides/make.py          # compone los titulares → slide-*.png (1320×2868)
python3 slides/make.py ipad     # → slide-ipad-*.png (2064×2752)
./upload_shots.py APP_IPHONE_67 "<locId>=slide-es-*.png"
```

El orden de las capturas vive en dos sitios que tienen que coincidir: `SCREENS` en
`capture_all.sh` y `SLIDES` en `slides/make.py`. `shots/` y los `slide-*.png` no se versionan.

**El permiso de alarmas ya no hay que aceptarlo (desde 2026-11-10).** En DEBUG, con
`-demoScreen`, `AlarmScheduler.schedule` no llama a AlarmKit y el aviso de permiso de la lista
no se pinta, así que el diálogo del sistema nunca sale. En Xcode 27 no hay Simulator.app y la
ventana de DeviceHub no siempre queda al frente: mandar Return a ciegas puede caer en otra app.
El acceso al calendario sí es TCC: `xcrun simctl privacy <UDID> grant calendar MathyuSolutions.Calarm`
**antes** del primer arranque. Si el diálogo ya salió, no se va ni cerrando la app: reiniciar el
simulador (`simctl shutdown` + `bootstatus -b`) lo quita y el permiso concedido se conserva.

`DemoData.swift` (solo DEBUG) llena la app con siete alarmas, una categoría propia y tres
eventos de calendario; `-demoScreen` abre una pantalla directa. Los títulos siguen el idioma
de lanzamiento, porque el título de una alarma es contenido del usuario.

**El árbol de accesibilidad del simulador no expone las vistas de la app**, así que AXPress no
sirve y los toques por coordenadas fallan la mitad de las veces: de ahí el router por
argumentos, y de ahí que las capturas no dependan de tocar nada.
