# Guía rápida de App Icon para Calarm

## Concepto sugerido

**Visual**: un reloj/campana estilizado con un detalle pastelito o regalo, sobre el coral característico de Calarm (#FF6633).

Variaciones rápidas:
- Campana con confeti detrás (eventos)
- Reloj con un pequeño pastel encima (cumple + alarma)
- Solo la silueta de campana sobre el degradado coral → naranja

> El icono debe leerse claro a 60×60 px (tamaño en la Home Screen).

---

## Forma rápida (sin diseñador)

### Opción A — Bakery.app (recomendada, gratis en Mac)
1. Instala **Bakery** desde Mac App Store
2. Selecciona "iOS App Icon"
3. Pon un emoji o SF Symbol como base (ej. `alarm.fill`, `bell.badge.fill`)
4. Background gradient: coral `#FF6633` → naranja `#FF9933`
5. Exporta como `AppIcon.appiconset` (genera todos los tamaños)
6. Reemplaza la carpeta `Calarm/Calarm/Assets.xcassets/AppIcon.appiconset/` con la generada

### Opción B — Figma + bakery.app
1. Diseña 1024×1024 en Figma
2. Exporta PNG
3. Sube a [appicon.co](https://appicon.co) → descarga el zip
4. Drag al `AppIcon.appiconset` en Xcode

### Opción C — Generación con IA
Promot ejemplo para DALL-E / Midjourney / etc:
> "Minimalist iOS app icon, alarm clock with confetti, vibrant coral gradient background (#FF6633 to #FF9933), Apple Liquid Glass style, 1024x1024, no text, soft shadows"

Después usa [appicon.co](https://appicon.co) para generar todos los tamaños.

---

## Tamaños que Xcode espera (iOS 26)

Si usas Bakery/appicon.co se generan automáticamente. Para referencia:

- 1024×1024 (App Store)
- 180×180, 120×120 (iPhone)
- 167×167, 152×152, 76×76 (iPad)
- Tinted variant (iOS 18+ — modo dark/tinted home screen)
- Light variant
- Dark variant

iOS 26 soporta **3 variantes** (Light / Dark / Tinted). Bakery las genera todas.

---

## Cómo instalarlo en el proyecto

1. En Xcode, abrir `Assets.xcassets` → `AppIcon`
2. Arrastrar las imágenes a las casillas correspondientes (o reemplazar la carpeta `AppIcon.appiconset` completa)
3. Build & Run — el ícono nuevo aparece en la Home Screen
