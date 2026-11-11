#!/bin/bash
# Captura una pantalla del simulador: idioma + pantalla + archivo de salida.
D=${DEVICE:?exporta DEVICE con el UDID del simulador}
BUNDLE=MathyuSolutions.Calarm
LANG_TAG="$1"; SCREEN="$2"; OUT="$3"; SEED="$4"
xcrun simctl terminate $D $BUNDLE >/dev/null 2>&1
ARGS=(-AppleLanguages "($LANG_TAG)" -demoScreen "$SCREEN")
# Portugués de Brasil: idioma pt-BR y región Brasil (hora en 24 h, R$ 59,90).
[ "$LANG_TAG" = "pt" ] && ARGS=(-AppleLanguages "(pt-BR)" -AppleLocale pt_BR -demoScreen "$SCREEN")
[ -n "$SEED" ] && ARGS+=(-seedDemoData)
xcrun simctl launch $D $BUNDLE "${ARGS[@]}" >/dev/null 2>&1
# Un simulador recién creado tarda más en arrancar la app: WAIT=15 ./capture.sh …
sleep ${WAIT:-4}
xcrun simctl io $D screenshot "$OUT" >/dev/null 2>&1
sips -g pixelWidth -g pixelHeight "$OUT" | tail -2 | tr '\n' ' '
echo "→ $OUT"
