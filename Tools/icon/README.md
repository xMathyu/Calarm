# Ícono de Calarmi

Despertador con las agujas en forma de check (dirección «C», elegida el 2026-11-11).
Fuente en SVG de 1024 px, a sangre: iOS pone las esquinas.

| Archivo | Para |
|---|---|
| `light.svg` | `AppIcon` normal, la web (`app-icon.png`, favicon, apple-touch-icon) |
| `dark.svg` | `AppIcon` en modo oscuro |
| `tinted.svg` | `AppIcon` tintado (escala de grises sobre negro) |

```sh
swift render.swift light.svg AppIcon-1024.png 1024     # PNG sin canal alfa, como pide Apple
swift variants.swift AppIcon-1024.png out/              # azul, morado, verde y rosa (Plus) + vistas previas de 240 px
```

Los colores de Plus salen de girar el tono del ícono normal (CIHueAdjust), así que basta con
cambiar `light.svg` y volver a correr los dos comandos.
