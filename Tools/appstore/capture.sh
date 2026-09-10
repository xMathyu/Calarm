#!/bin/bash
# Captura una pantalla del simulador: idioma + pantalla + archivo de salida.
D=${DEVICE:?exporta DEVICE con el UDID del simulador}
BUNDLE=MathyuSolutions.Calarm
LANG_TAG="$1"; SCREEN="$2"; OUT="$3"; SEED="$4"
xcrun simctl terminate $D $BUNDLE >/dev/null 2>&1
ARGS=(-AppleLanguages "($LANG_TAG)" -demoScreen "$SCREEN")
[ -n "$SEED" ] && ARGS+=(-seedDemoData)
xcrun simctl launch $D $BUNDLE "${ARGS[@]}" >/dev/null 2>&1
sleep 4
xcrun simctl io $D screenshot "$OUT" >/dev/null 2>&1
sips -g pixelWidth -g pixelHeight "$OUT" | tail -2 | tr '\n' ' '
echo "→ $OUT"
