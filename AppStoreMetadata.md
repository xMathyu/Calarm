# Calarm — App Store metadata (borrador)

> **Idioma primario de la tienda: Inglés (EE. UU.)** — verificado por API el 2026-09-09
> (`app.primaryLocale = en-US`). Los dos únicos locales son `en-US` y `es-MX`. Esto importa:
> lo que falte en es-MX (capturas, por ejemplo) se hereda de en-US, en inglés.

---

## Ficha propuesta para 1.0.8 (2026-09-09)

Apple indexa **nombre + subtítulo + keywords como una sola bolsa**: repetir una palabra en
dos campos no la posiciona mejor, solo gasta caracteres. La **descripción no se indexa** —
su único trabajo es convertir a quien ya llegó. El nombre pesa más que el subtítulo, y el
subtítulo más que las keywords, así que los términos con más volumen van en el nombre.

Lo que había hasta 1.0.7 gastaba la mitad del presupuesto: es-MX repetía `alarma`,
`cumpleaños` y `evento` (ya estaban en nombre y subtítulo), más 8 caracteres en los espacios
después de cada coma, más `equipos` — que nadie busca: quien busca alarmas para sus reuniones
escribe `teams`. en-US repetía 5 de 10 términos y dejaba 20 caracteres sin usar.

| | es-MX | en-US |
|---|---|---|
| Términos indexados antes | 12 | 11 |
| Términos indexados después | 17 | 20 |

### es-MX

- **Nombre (30/30)**: `Calarm: Alarma y Avisos con IA`
- **Subtítulo (27/30)**: `Despertador y recordatorios`
- **Keywords (96/100)**:
```
medicamento,pastilla,cita,cumpleaños,aniversario,evento,calendario,reunión,compartida,pago,turno
```

### en-US

- **Name (22/30)**: `Calarm: AI Alarm Clock`
- **Subtitle (27/30)**: `Birthdays, meds & reminders`
- **Keywords (95/100)**:
```
anniversary,medication,pill,appointment,shared,family,bill,shift,recurring,calendar,teams,event
```

### de-DE (nuevo en 1.0.9)

Alemania y toda la UE estuvieron **bloqueadas desde el lanzamiento** por el estado de
comerciante del Digital Services Act (ver la sección "Bloqueo en la UE"). La ficha alemana se
prepara igual por dos razones: **Suiza y Liechtenstein sí están disponibles** y sus usuarios
tienen el iPhone en alemán, así que la ven desde el primer día; y el día que se resuelva el
DSA, Alemania y Austria abren con la ficha ya puesta.

- **Name (29/30)**: `Calarm: Wecker & Erinnerungen`
- **Subtitle (30/30)**: `Geburtstage und Termine mit KI`
- **Keywords (98/100)**:
```
medikament,tablette,jahrestag,kalender,besprechung,geteilt,familie,rechnung,schicht,hochzeit,teams
```

17 términos indexados. `Wecker` y `Erinnerungen` son los dos de más volumen de la categoría en
alemán y van en el nombre; `KI` (no "AI") es como se busca la inteligencia artificial en alemán.

**La app sigue en inglés para ellos.** La descripción alemana por eso no cita botones en alemán
—en pantalla dicen "Go", "Join", "Snooze"— ni promete Siri en alemán: las frases de Siri solo
existen en español e inglés, y el asistente entiende esos dos idiomas. La descripción lo dice
al final, para no ganarse reseñas de una estrella por sorpresa.

### Locales por agregar — después de las capturas, no antes

`es-ES` y `en-GB` no necesitan tocar la app (la UI ya está en español e inglés) y cada uno es
una bolsa de keywords más. Pero **una localización sin capturas propias hereda las del idioma
primario**, que hoy están en inglés: agregar es-ES antes de subir capturas en español
reproduce en España exactamente el problema que tiene es-MX. Orden: capturas primero.

- **es-ES** — subtítulo `Avisos, citas y cumpleaños` (26/30), keywords (92/100):
  `medicación,pastilla,aniversario,evento,calendario,reunión,compartida,recibo,turno,boda,teams`
- **en-GB** — keywords (92/100):
  `anniversary,medication,tablet,shared,family,bill,shift,rota,recurring,calendar,teams,meeting`

Portugués (Brasil) es el mercado grande que falta, pero va junto con la UI traducida: una
ficha en un idioma que la app no habla se paga en reseñas de una estrella.

## Categoría
- **Primaria**: Productivity
- **Secundaria**: Lifestyle

## Precio
- **Gratis** (cambiable después si decides agregar IAP "Calarm Pro")

## Edad mínima
- 4+

---

## Descripción 1.0.8 (4000 char máx)

No se indexa: está escrita para convertir. Cuenta lo que la ficha de 1.0.7 no contaba —el
asistente con Apple Intelligence, los tonos y el audio importado, personas de confianza, la
Isla Dinámica, los varios horarios por alarma y la sincronización por iCloud— y ya no menciona
AlarmKit, SwiftData ni CloudKit, que a nadie que busca una alarma le dicen nada.

### es-MX

```
Las alarmas del Reloj sirven para despertarte. Calarm suena igual de fuerte —aunque el iPhone esté en silencio, bloqueado o en modo Enfoque— para todo lo demás: la pastilla de las 8, el cumpleaños de tu mamá, la cita del dentista, el pago que vence el 3.

MÁS QUE UN DESPERTADOR
• Medicamentos y citas: cada día, los lunes y miércoles, o cada 21 días. Y varios horarios en una sola alarma, para las que se toman tres veces al día.
• Cumpleaños y aniversarios: ponle la foto de la persona y se repite cada año sin que la toques.
• Pagos y vencimientos: el 3 de cada mes, sin falta.
• Turnos y rutinas: lunes a las 5 p. m. y sábado a las 11 a. m., en la misma alarma.

DÍSELO Y LISTO
"Recuérdame la pastilla todos los días a las 9." El asistente de Calarm la programa por ti con Apple Intelligence, sin que nada salga de tu iPhone. Con Siri también: "Pon una alarma en Calarm." (El asistente necesita un iPhone compatible con Apple Intelligence.)

TUS EVENTOS DEL CALENDARIO, CON ALARMA DE VERDAD
Calarm lee tu Calendario de Apple y le pone hasta 3 avisos a cada evento: al inicio, 15 minutos antes, una hora antes. Si el evento tiene dirección, cuando suena aparece "Ir" en lugar de "Posponer": detiene la alarma y abre Mapas con la ruta. Si es una reunión de Teams, Zoom o Google Meet, aparece "Unirse" y entras sin buscar el enlace.

ELIGE CÓMO SUENA
Seis tonos —Campana, Marimba, Radar, Arpegio, Pulso y Arpa— o tu propio audio importado desde Archivos. Cada alarma puede tener el suyo.

CONTRÓLALA SIN DESBLOQUEAR
Detén o pospón la alarma que está sonando desde la Live Activity y la Isla Dinámica.

PERSONAS DE CONFIANZA
Deja que tu pareja, un familiar o tu asistente administre tus alarmas desde su teléfono: lo que programen suena en tu iPhone. La invitación llega por Mensajes y le quitas el acceso cuando quieras.

TUS ALARMAS EN TODOS TUS DISPOSITIVOS
Se sincronizan por tu iCloud. Sin cuenta nueva, sin contraseña nueva.

SIN ANUNCIOS, SIN SEGUIMIENTO, SIN SERVIDORES NUESTROS
Tus alarmas son tuyas. No hay registro, no hay analítica de terceros, no vendemos nada.

Para quienes no quieren perderse lo importante.
```

### en-US

```
The Clock app's alarms are for waking up. Calarm rings just as loud — even when your iPhone is silent, locked or in Focus — for everything else: the 8 a.m. pill, your mom's birthday, the dentist at 4, the bill due on the 3rd.

MORE THAN A WAKE-UP ALARM
• Meds and appointments: every day, Mondays and Wednesdays, or every 21 days. And several times in a single alarm, for the ones you take three times a day.
• Birthdays and anniversaries: add the person's photo and it repeats every year on its own.
• Bills and due dates: the 3rd of every month, no exceptions.
• Shifts and routines: Monday at 5 p.m. and Saturday at 11 a.m., in the same alarm.

JUST SAY IT
"Remind me to take my pill every day at 9." Calarm's assistant schedules it with Apple Intelligence, and nothing leaves your iPhone. Siri works too: "Set an alarm in Calarm." (The assistant needs an iPhone that supports Apple Intelligence.)

YOUR CALENDAR EVENTS, WITH A REAL ALARM
Calarm reads your Apple Calendar and gives each event up to 3 alerts: at start, 15 minutes before, an hour before. If the event has an address, "Go" replaces "Snooze" when it rings: it stops the alarm and opens Maps with directions. If it's a Teams, Zoom or Google Meet call, "Join" takes you straight in.

CHOOSE HOW IT SOUNDS
Six tones — Chime, Marimba, Radar, Arpeggio, Pulse and Harp — or your own audio imported from Files. Every alarm can have its own.

CONTROL IT WITHOUT UNLOCKING
Stop or snooze the ringing alarm from the Live Activity and the Dynamic Island.

TRUSTED HELPERS
Let your partner, a family member or your assistant manage your alarms from their phone: what they schedule rings on your iPhone. The invite arrives over Messages, and you can revoke access whenever you want.

YOUR ALARMS ON ALL YOUR DEVICES
They sync through your own iCloud. No new account, no new password.

NO ADS, NO TRACKING, NO SERVERS OF OURS
Your alarms are yours. No sign-up, no third-party analytics, nothing to sell.

For people who refuse to miss what matters.
```

---

## Capturas (1.0.8) — reales, generadas del simulador

Las de mayo eran renders generados (`ChatGPT Image May 23, 2026…`), en inglés, con la lista
anterior al rediseño de 1.0.5, y **es-MX no tenía ninguna**: heredaba las de en-US. Ahora los
dos locales tienen su propio set, capturado de la app corriendo, en su idioma.

| Set | Tamaño | Cuántas |
|---|---|---|
| `APP_IPHONE_67` (6.9") | 1320×2868 | 6 por locale |
| `APP_IPAD_PRO_3GEN_129` (13") | 2064×2752 | 6 por locale |

El set de 6.5" se eliminó: con uno de 6.9" Apple escala para los tamaños menores, y mantener
uno viejo en inglés era peor que no tenerlo.

Las seis pantallas: lista con grupos y categorías · editor de un cumpleaños (anual, dos
avisos) · selector de recurrencia con próximas ocurrencias · calendario con tres eventos y el
botón "Unirse en Teams" · asistente con Apple Intelligence · selector de tonos.

### Cómo regenerarlas

`DemoData.swift` (solo DEBUG) siembra siete alarmas, una categoría propia y tres eventos de
calendario; los títulos siguen el idioma de lanzamiento, porque el título de una alarma es
contenido del usuario. `-demoScreen` abre una pantalla directamente, así que la corrida no
depende de tocar nada:

```
xcodebuild -scheme Calarm -destination "platform=iOS Simulator,id=<UDID>" build   # sin CODE_SIGNING_ALLOWED=NO
xcrun simctl install <UDID> <ruta>/Calarm.app
xcrun simctl privacy <UDID> grant calendar MathyuSolutions.Calarm
xcrun simctl status_bar <UDID> override --time "9:41" --batteryState charged --batteryLevel 100
xcrun simctl launch <UDID> MathyuSolutions.Calarm -seedDemoData -AppleLanguages "(es)" -demoScreen list
xcrun simctl io <UDID> screenshot lista.png
```

Pantallas disponibles: `list`, `editor`, `recurrence`, `tones`, `assistant`, `settings`,
`helpers`, `calendar`. El permiso de alarmas aparece una vez por instalación: se acepta con
Enter (`key code 36`) sobre la ventana del simulador. Reinstalar encima conserva datos y
permisos.

Los titulares se componen sobre la captura con `Tools/appstore/slides/make.py` (Chrome headless
al tamaño exacto) y se suben con `Tools/appstore/upload_shots.py`, que crea el set, reserva cada
asset, manda los bytes con las `uploadOperations` y confirma con el checksum MD5. Todo el
pipeline —capturas, composición, subida, espera del build y envío a revisión— está en
`Tools/appstore/`, con su README.

---

## What's New (1.0.8)

Español:
```
• Bienvenida nueva: cinco pantallas que te cuentan para qué sirve Calarm la primera vez que la abres, en lugar de una sola lista de features
• Comparte Calarm desde Ajustes, con un toque
• Las invitaciones a personas de confianza ahora llevan el enlace para descargar Calarm: quien la reciba puede instalarla y aceptar sin buscar nada
```

Inglés:
```
• A new welcome: five screens that tell you what Calarm is for the first time you open it, instead of a single list of features
• Share Calarm from Settings with a single tap
• Invitations to trusted helpers now include the link to download Calarm, so whoever gets one can install it and accept without hunting for anything
```

---

## Descripción de-DE (1.0.9)

```
Die Wecker der Uhr-App sind fürs Aufstehen da. Calarm klingelt genauso laut – auch wenn das iPhone stumm, gesperrt oder im Fokus ist – für alles andere: die Tablette um 8, Mamas Geburtstag, der Zahnarzttermin um 16 Uhr, die Rechnung am 3.

MEHR ALS EIN WECKER
• Medikamente und Termine: jeden Tag, montags und mittwochs, oder alle 21 Tage. Und mehrere Uhrzeiten in einem einzigen Alarm, für alles, was dreimal täglich ansteht.
• Geburtstage und Jahrestage: Foto der Person hinzufügen, und der Alarm wiederholt sich jedes Jahr von selbst.
• Rechnungen und Fristen: am 3. jedes Monats, ohne Ausnahme.
• Schichten und Routinen: montags um 17 Uhr und samstags um 11 Uhr, im selben Alarm.

DEINE KALENDERTERMINE, MIT EINEM ECHTEN ALARM
Calarm liest deinen Apple Kalender und gibt jedem Termin bis zu 3 Hinweise: zum Start, 15 Minuten vorher, eine Stunde vorher. Hat der Termin eine Adresse, stoppt ein Tippen den Alarm und öffnet Karten mit der Route. Ist es ein Teams-, Zoom- oder Meet-Meeting, kommst du mit einem Tippen direkt hinein, ohne den Link zu suchen.

SAG ES EINFACH
„Remind me to take my pill every day at 9." Der Assistent legt den Alarm für dich an – mit Apple Intelligence, und nichts verlässt dein iPhone. (Der Assistent benötigt ein iPhone, das Apple Intelligence unterstützt.)

WÄHLE, WIE ER KLINGT
Sechs Töne – Glocke, Marimba, Radar, Arpeggio, Puls und Harfe – oder dein eigenes Audio aus der Dateien-App. Jeder Alarm kann seinen eigenen haben.

STEUERE IHN, OHNE ZU ENTSPERREN
Stoppe oder schlummere den klingelnden Alarm direkt in der Live-Aktivität und der Dynamic Island.

VERTRAUENSPERSONEN
Lass deinen Partner, ein Familienmitglied oder deine Assistenz deine Alarme vom eigenen Telefon aus verwalten: Was sie einstellen, klingelt auf deinem iPhone. Die Einladung kommt per Nachrichten, und du kannst den Zugriff jederzeit wieder entziehen.

DEINE ALARME AUF ALLEN GERÄTEN
Sie synchronisieren sich über deine eigene iCloud. Kein neues Konto, kein neues Passwort.

KEINE WERBUNG, KEIN TRACKING, KEINE SERVER VON UNS
Deine Alarme gehören dir. Keine Anmeldung, keine Analyse durch Dritte, nichts zu verkaufen.

Für alle, die nichts Wichtiges verpassen wollen.

Hinweis: Die App-Oberfläche ist auf Englisch und Spanisch verfügbar.
```

### Texto promocional de-DE

```
Nicht nur zum Aufwachen: Tabletten, Geburtstage, Termine, Rechnungen und Schichten. Klingelt laut, auch wenn das iPhone stumm oder gesperrt ist.
```

---

## What's New (1.0.9)

Español:
```
• Corregido: en un iPhone configurado en un idioma que Calarm no habla —alemán, portugués, japonés— la app se veía a medias en español, con las fechas en inglés. Ahora se ve entera en inglés
```

Inglés:
```
• Fixed: on an iPhone set to a language Calarm doesn't speak — German, Portuguese, Japanese — the app showed up half in Spanish, with dates in English. Now it shows up fully in English
```

Alemán:
```
• Behoben: Auf einem iPhone, dessen Sprache Calarm nicht spricht, erschien die App halb auf Spanisch, mit englischen Datumsangaben. Jetzt erscheint sie vollständig auf Englisch
```

## What's New (1.0.11)

Español:
```
• Nuevo: "Aviso por defecto" en Ajustes. Elige con cuánta anticipación quieres que suenen tus alarmas —de 5 minutos a una semana antes— y cada evento de tu calendario lo usa sin que tengas que entrar uno por uno
• Nuevo: elige qué calendarios mira Calarm. Los del trabajo sí, el compartido de casa no, o como prefieras
• Nuevo: "Solo eventos a los que asisto" deja sin alarma los eventos que rechazaste y los que son de otra persona
• Nuevo: cuenta regresiva antes de que suene la alarma, en la Isla Dinámica y en la pantalla bloqueada
```

Inglés:
```
• New: "Default alert" in Settings. Choose how far ahead your alarms should ring — from 5 minutes to a week before — and every event in your calendar uses it, with no need to open them one by one
• New: choose which calendars Calarm watches. Work ones yes, the shared home one no, or however you like
• New: "Only events I'm attending" leaves without an alarm the events you declined and the ones that belong to someone else
• New: a countdown before the alarm rings, in the Dynamic Island and on the Lock Screen
```

Alemán:
```
• Neu: „Default alert" in den Einstellungen. Lege fest, wie lange im Voraus deine Wecker klingeln sollen – von 5 Minuten bis zu einer Woche – und jeder Termin in deinem Kalender übernimmt es, ohne dass du sie einzeln öffnen musst
• Neu: Wähle aus, welche Kalender Calarm beobachtet. Die vom Beruf ja, den gemeinsamen zu Hause nicht – oder wie du magst
• Neu: „Only events I'm attending" lässt Termine ohne Wecker, die du abgesagt hast oder die jemand anderem gehören
• Neu: ein Countdown, bevor der Wecker klingelt – in der Dynamic Island und auf dem Sperrbildschirm
```

## What's New (1.0.10)

Español:
```
• Corregido: al guardar una alarma sin ponerle nombre, el editor se cerraba sin crear nada y sin decir por qué. Ahora te pide el nombre y no se pierde lo que ya habías configurado
• El calendario se cierra solo al elegir el día, en vez de quedarse abierto tapando el resto
• Si la fecha ya pasó, la alarma te avisa de que no va a sonar
• Corregido: pedirle al asistente "una alarma a las 9" de noche la ponía para hoy —una hora que ya pasó— en vez de para mañana
```

Inglés:
```
• Fixed: saving an alarm without a name closed the editor without creating anything, and without saying why. Now it asks you for the name and keeps what you had set up
• The calendar closes itself when you pick a day, instead of staying open over everything else
• If the date has already passed, the alarm now warns you that it won't ring
• Fixed: asking the assistant for "an alarm at 9" late at night set it for today — an hour that had already gone by — instead of tomorrow
```

Alemán:
```
• Behoben: Beim Speichern eines Weckers ohne Namen schloss sich der Editor, ohne etwas anzulegen und ohne zu sagen, warum. Jetzt fragt er nach dem Namen und behält, was du eingestellt hast
• Der Kalender schließt sich von selbst, sobald du einen Tag auswählst, statt alles Weitere zu verdecken
• Liegt das Datum in der Vergangenheit, weist der Wecker jetzt darauf hin, dass er nicht klingeln wird
• Behoben: "Wecker um 9" spät abends legte der Assistent auf heute — eine Uhrzeit, die schon vorbei war — statt auf morgen
```

---

## Histórico de la ficha (hasta 1.0.7)

Lo de abajo es lo que estuvo publicado antes de la ficha de 1.0.8. Se conserva para no
re-anunciar features en las notas de versiones siguientes.

### Nombre y keywords hasta 1.0.7
- es-MX: `Calarm: Alarmas inteligentes` / `Cumpleaños, eventos y avisos` /
  `alarma, cumpleaños, recordatorio, aniversario, evento, calendario, equipos, reunión, recurrente`
- en-US: `Calarm: Smart Alarms` / `Birthdays, events & reminders` /
  `alarm,birthday,reminder,anniversary,event,calendar,teams,meeting,recurring,smart`

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
