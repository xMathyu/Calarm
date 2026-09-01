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

## What's New (1.0.4) — publicado

> Copiado desde App Store Connect vía API. Sirve de referencia para no repetir
> features en versiones siguientes: 1.0.4 ya anunció personas de confianza,
> varios horarios por alarma, el buscador de emojis, los avisos en la pantalla
> principal y las mejoras de traducción al inglés.

Español:
```
• NUEVO — Personas de confianza: permite que alguien de confianza (tu pareja, un familiar, tu asistente) vea y administre todas tus alarmas desde su teléfono. Lo que programen suena en tu iPhone. La invitación llega por Mensajes con un simple enlace y puedes revocar el acceso cuando quieras.
• Varios horarios por alarma: una misma alarma ahora puede sonar en días y horas distintos (por ejemplo, lunes a las 5 p. m. y sábado a las 11 a. m.).
• Nuevo selector de emojis: busca entre todos los emojis por nombre o categoría para personalizar el icono de tus alarmas.
• Avisos más simples: agrega, cambia o quita todos los avisos de una alarma directamente en su pantalla principal, sin menús ocultos.
• Mejoras de traducción al inglés y correcciones visuales en el editor.
```

## What's New (1.0.5)

Español:
```
• Enciende o apaga cada alarma con un switch en la lista, sin abrir el editor
• El editor guarda solo: se fueron Guardar y Cancelar, ahora basta con "Listo"
• Detén la alarma que está sonando desde la Live Activity o la Isla Dinámica, sin desbloquear el iPhone
• Lista rediseñada: la hora al frente con el día al lado y las etiquetas alineadas bajo el título
• En una lista compartida, cada persona puede ponerse sus propios avisos sin cambiar los de los demás
• El selector de fecha se oculta cuando la recurrencia ya fija los días
• Corregido: al pedirle a la IA "pon mi daily todos los lunes", la alarma quedaba diaria en vez de semanal
```

Inglés:
```
• Turn each alarm on or off with a switch right in the list, without opening the editor
• The editor now saves on its own: Save and Cancel are gone, just tap "Done"
• Stop a ringing alarm straight from the Live Activity or Dynamic Island, without unlocking your iPhone
• Redesigned list: the time leads with the day beside it and the labels lined up under the title
• On a shared list, each person can set their own alerts without changing anyone else's
• The date picker is hidden when the recurrence already fixes the days
• Fixed: asking the AI for "my daily standup every Monday" created a daily alarm instead of a weekly one
```

## What's New (1.0.6)

Español:
```
• Las alarmas que ya pasaron dejan de aparecer como activadas: su interruptor se muestra apagado, con la etiqueta "Vencida" y la fecha en que sonaron
• La sección que las agrupa ahora se llama "Vencidas", en vez de "Sin próxima fecha"
```

Inglés:
```
• Alarms that already went off no longer show as enabled: their switch appears off, labeled "Expired" along with the date they rang
• The section that groups them is now called "Expired" instead of "No next date"
```

## What's New (1.0.7)

Español:
```
• Elige cómo suena cada alarma: seis tonos nuevos (Campana, Marimba, Radar, Arpegio, Pulso y Arpa), y cada alarma puede tener el suyo o seguir el predeterminado de Ajustes
• Importa tu propio audio desde Archivos y úsalo como tono de alarma
• Corregido: al renombrar una alarma, las que ya estaban programadas seguían sonando con el nombre anterior — también en el Apple Watch
```

Inglés:
```
• Choose how each alarm sounds: six new tones (Chime, Marimba, Radar, Arpeggio, Pulse and Harp), and every alarm can use its own or follow the default from Settings
• Import your own audio from Files and use it as an alarm tone
• Fixed: renaming an alarm left the already-scheduled ones ringing with the old name — on Apple Watch too
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

Español (104 char):
```
Ahora eliges cómo suena cada alarma: seis tonos nuevos, o tu propio audio importado desde Archivos.
```

Inglés (91 char):
```
Now you choose how each alarm sounds: six new tones, or your own audio imported from Files.
```

Anterior (1.0.6, publicado):
```
Las alarmas que ya sonaron dejan de verse como activadas: ahora salen apagadas, marcadas como vencidas y con la fecha en que sonaron.
```
```
Alarms that already rang no longer look enabled: they now show as off, marked expired, with the date they rang.
```

Anterior (1.0.5, publicado):
```
Enciende o apaga cada alarma desde la lista, y detén la que está sonando desde la Isla Dinámica. Ahora el editor guarda solo.
```
```
Turn any alarm on or off right from the list, and stop the one that's ringing from the Dynamic Island. The editor now saves on its own.
```

Anterior (1.0.4, publicado):
```
Alarmas que suenan aunque tu iPhone esté en silencio. Nuevo: personas de confianza que administran tus alarmas, varios horarios por alarma y buscador de emojis.
```
```
Alarms that ring even when your iPhone is silent. New: trusted helpers who manage your alarms, multiple schedules per alarm, and a searchable emoji picker.
```

Anterior (1.0.3):
```
Alarmas que suenan aunque tu iPhone esté en silencio. Ahora con comandos de Siri y botón para unirte a tus reuniones de Teams, Zoom y Google Meet.
```
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
