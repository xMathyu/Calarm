# Calarm — App Store metadata (borrador)

> Idioma primario: **Español (México)**. Localización opcional: Inglés.

---

## Nombre

- **Nombre App Store**: `Calarm` (corto, único, brand)
- **Subtítulo (30 char)**: `Alarmas para cumpleaños y más`

## Categoría
- **Primaria**: Productivity
- **Secundaria**: Lifestyle

## Precio
- **Gratis** (cambiable después si decides agregar IAP "Calarm Pro")

## Edad mínima
- 4+

---

## Descripción (4000 char máx, ~600 recomendado)

Calarm convierte tus fechas importantes en alarmas que suenan como las del Reloj de Apple — fuerte, aunque tu iPhone esté en silencio, bloqueado o en modo Focus.

A diferencia del Reloj nativo, Calarm fue hecho para eventos de la vida real:

🎂 **Cumpleaños y aniversarios anuales**
Programa una alarma para el cumpleaños de un amigo y ponle su foto. Se repite cada año sin que la toques.

🔁 **Recurrencias que el Reloj no hace**
Cada 2 semanas, cada mes, los lunes y miércoles, cada año en una fecha exacta. Todo lo que necesites.

📅 **Tus eventos del calendario también suenan**
Activa el tab Calendario y Calarm leerá tus eventos de la app Calendario de Apple. Configura cuántos avisos quieres por evento (hasta 3): "al inicio", "15 min antes", "1 hora antes".

📍 **¿Tienes que llegar manejando?**
Cuando suena la alarma de un evento con ubicación, en lugar de "posponer" aparece un botón "Ir": detiene la alarma y abre Maps con direcciones automáticamente.

💼 **Detección automática de reuniones de Teams**
Si tu calendario sincroniza con Outlook/Exchange, Calarm detecta los enlaces de Microsoft Teams y muestra un botón "Unirse en Teams" para entrar al meeting sin buscar el link.

✨ **Diseñado para iOS 26**
Liquid Glass nativo, AlarmKit del sistema, SwiftData. Todo privado en tu dispositivo — sin servidor, sin cuentas, sin ads.

---

## Keywords (100 char máx, separados por coma, sin espacios)

```
alarma,cumpleaños,recordatorio,aniversario,evento,calendario,teams,reunión,despertador,recurrente
```

## What's New (versión inicial)
```
Primera versión de Calarm:

• Alarmas con foto o icono para cumpleaños, aniversarios y eventos
• Recurrencias avanzadas: cada N días/semanas/meses/años
• Hasta 3 avisos por evento del calendario
• Botón "Ir" que abre Maps cuando suena la alarma
• Detección automática de reuniones de Teams
```

## What's New (1.0.3)

Español:
```
• Reuniones: el botón "Unirse" ahora funciona con Microsoft Teams, Zoom y Google Meet, y siempre abre el enlace correcto
• Siri en español e inglés: di "Pon una alarma en Calarm" o "Set an alarm in Calarm"
• Personas de confianza: comparte tu lista para que alguien más te ayude a administrar tus alarmas
• Categorías personalizadas con color e icono propios
• Nuevo selector de emojis para el icono de tus alarmas
• Editor de alarmas renovado y más fácil de usar
• Mejoras de estabilidad: las alarmas eliminadas ya no vuelven a sonar
```

Inglés:
```
• Meetings: the "Join" button now works with Microsoft Teams, Zoom and Google Meet, and always opens the right link
• Siri in English and Spanish: say "Set an alarm in Calarm" or "Pon una alarma en Calarm"
• Trusted helpers: share your list so someone else can help manage your alarms
• Custom categories with their own color and icon
• New emoji picker for your alarm icons
• Stability fixes: deleted alarms no longer ring again
```

---

## Privacy

### Privacy Practices (App Store Connect → App Privacy)

| Categoría | Recolectamos | Para qué | Asociado al usuario | Tracking |
|---|---|---|---|---|
| Contact Info | No | — | — | — |
| Health & Fitness | No | — | — | — |
| Financial Info | No | — | — | — |
| Location | No | — | — | — |
| Sensitive Info | No | — | — | — |
| Contacts | No | — | — | — |
| User Content | **Photos** | Mostrar foto en alarma de un recordatorio creado por el usuario. Almacenadas localmente en el dispositivo. | No | No |
| Browsing History | No | — | — | — |
| Search History | No | — | — | — |
| Identifiers | No | — | — | — |
| Purchases | No | — | — | — |
| Usage Data | No | — | — | — |
| Diagnostics | No | — | — | — |
| Other Data | **Calendar events (read)** | Detectar reuniones para programar alarmas. No se almacenan fuera del dispositivo. | No | No |

> Cuando agreguemos iCloud sync: actualizar a "User Content → stored in iCloud private database (Apple). End-to-end encrypted."

### Privacy Policy URL
- Sugerencia: hosteado en GitHub Pages o Notion. URL ejemplo: `https://calarm.mathyusolutions.com/privacy`
- Contenido mínimo: qué se accede (calendario, fotos, AlarmKit), dónde se guarda (local), que no hay servidor ni tracking.

---

## Marketing

### Promotional Text (170 char, editable sin re-revisión de App)

Español (146 char):
```
Alarmas que suenan aunque tu iPhone esté en silencio. Ahora con comandos de Siri y botón para unirte a tus reuniones de Teams, Zoom y Google Meet.
```

Inglés (139 char):
```
Alarms that ring even when your iPhone is silenced. Now with Siri commands and a join button for your Teams, Zoom and Google Meet meetings.
```

Anterior (1.0.0):
```
Alarmas inteligentes que suenan aunque tu iPhone esté en silencio. Cumpleaños recurrentes, recordatorios y eventos del calendario en una sola app.
```

### URL del soporte
- Email: `xmathyu@gmail.com` (o crear `support@calarm.app`)
- O issue tracker: `https://github.com/xMathyu/Calarm/issues`

---

## Screenshots requeridos

Mínimo: iPhone 6.7" (1290x2796) y iPhone 6.5" (1284x2778). Apple acepta el mismo set para tamaños cercanos.

**Sugerencia de 5 screenshots:**

1. **Lista de alarmas** con grupos Hoy/Mañana/Esta semana — muestra recordatorios variados con fotos y categorías
2. **Editor de un cumpleaños** — foto, recurrencia anual, aviso 1 día antes
3. **Pantalla de detalle de evento del calendario** con 3 avisos configurados y botón Ir
4. **Alarma sonando** (simulación) — pantalla completa con foto + botones Detener / Ir
5. **Vista de Ajustes** mostrando el toggle de Teams + diagnóstico

> Generables desde el simulador con `Cmd+S` o herramientas como [Rotato](https://rotato.app) o [Mockuuups Studio](https://mockuuups.studio) para mockups con marco de iPhone.

---

## TestFlight (antes de App Store público)

1. Apple Developer → App Store Connect → My Apps → `+` → New App
2. Bundle ID: `MathyuSolutions.Calarm`
3. SKU: `calarm-ios-001`
4. Subir build con Archive → Distribute App → TestFlight
5. Agregar testers internos (hasta 100 cuentas Apple ID, sin review)
6. Para externos: review rápida (~24h) y hasta 10,000 testers vía link público

> Para probar el sharing de Fase B (CloudKit), todos los testers necesitan TestFlight + iCloud activo.
