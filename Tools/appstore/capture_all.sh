#!/bin/bash
# Saca todas las capturas de la ficha, en español e inglés, en un simulador:
#
#   DEVICE=<udid> ./capture_all.sh              → shots/es-1.png … shots/en-7.png (iPhone)
#   DEVICE=<udid> PREFIX=ipad- ./capture_all.sh → shots/ipad-es-1.png …        (iPad)
#   DEVICE=<udid> LANGS=pt ./capture_all.sh     → shots/pt-1.png … (Brasil)
#
# El número de cada captura es su posición en la ficha y tiene que coincidir con
# SLIDES en slides/make.py. Cada captura vuelve a sembrar los datos de demo: los
# títulos siguen el idioma de lanzamiento, y la vista del Calendario (mes o
# agenda) se decide al sembrar.
#
# Antes, una vez por simulador: instalar la app (build Debug), aceptar el permiso
# de alarmas y dar acceso al calendario (ver README).
set -euo pipefail
: "${DEVICE:?exporta DEVICE con el UDID del simulador}"
PREFIX=${PREFIX:-}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$HERE/shots"

SCREENS=(list challenge countdowns editor widgets agenda assistant)

for LANG_TAG in ${LANGS:-es en}; do
  for i in "${!SCREENS[@]}"; do
    n=$((i + 1))
    "$HERE/capture.sh" "$LANG_TAG" "${SCREENS[$i]}" "$HERE/shots/${PREFIX}${LANG_TAG}-${n}.png" seed
  done
done
