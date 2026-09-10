#!/usr/bin/env python3
"""Compone las capturas del simulador en slides de App Store (1320x2868).

Cada slide es una página HTML que Chrome headless fotografía al tamaño exacto
que pide Apple para 6.9". El título va arriba, con una palabra en el naranja de
la app; la captura va debajo, en un marco redondeado que sangra por abajo.
"""
import html
import subprocess
from pathlib import Path

HERE = Path(__file__).parent
SHOTS = HERE.parent / "shots"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

PROFILES = {
    "iphone": dict(w=1320, h=2868, prefix="", pad_top=150,
                   font=92, font_long=84, stage_top=505, shot_w=1080, radius=68),
    "ipad": dict(w=2064, h=2752, prefix="ipad-", pad_top=170,
                 font=124, font_long=112, stage_top=560, shot_w=1680, radius=52),
}

# El locale de las capturas puede diferir del de los titulares: la ficha alemana
# rotula en alemán las capturas inglesas, porque eso es lo que un usuario alemán
# se va a encontrar al abrir la app.
SHOT_LOCALE = {"de": "en"}

SLIDES = [
    # (locale, orden, archivo de captura, título, palabra destacada)
    ("es", 1, "es-1-lista.png", "Suena fuerte aunque el iPhone esté en {}", "silencio"),
    ("es", 2, "es-2-editor.png", "Cumpleaños que se repiten {}, cada año", "solos"),
    ("es", 3, "es-3-recurrencia.png", "Cada 2 semanas, lunes y miércoles, {}", "cada 21 días"),
    ("es", 4, "es-4-calendario.png", "Tus reuniones, con alarma {}", "de verdad"),
    ("es", 5, "es-5-asistente.png", "Díselo y listo, con {}", "Apple Intelligence"),
    ("es", 6, "es-4-tonos.png", "Elige {} cada alarma", "cómo suena"),
    ("en", 1, "en-1-list.png", "Rings loud even when your iPhone is {}", "silent"),
    ("en", 2, "en-2-editor.png", "Birthdays that repeat {}, every year", "on their own"),
    ("en", 3, "en-3-repeat.png", "Every 2 weeks, Mondays and Wednesdays, {}", "every 21 days"),
    ("en", 4, "en-4-calendar.png", "Your meetings, with a {}", "real alarm"),
    ("en", 5, "en-5-assistant.png", "Just say it — with {}", "Apple Intelligence"),
    ("en", 6, "en-6-tones.png", "Choose {} each alarm sounds", "how"),
    ("de", 1, "en-1-list.png", "Klingelt laut, auch wenn dein iPhone {} ist", "stumm"),
    ("de", 2, "en-2-editor.png", "Geburtstage, die sich {} wiederholen", "von selbst"),
    ("de", 3, "en-3-repeat.png", "Alle 2 Wochen, montags und mittwochs, {}", "alle 21 Tage"),
    ("de", 4, "en-4-calendar.png", "Deine Termine, mit einem {}", "echten Alarm"),
    ("de", 5, "en-5-assistant.png", "Sag es einfach — mit {}", "Apple Intelligence"),
    ("de", 6, "en-6-tones.png", "Wähle, {} jeder Alarm klingt", "wie"),
]

PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><style>
  * {{ margin:0; padding:0; box-sizing:border-box; }}
  html, body {{ width:{w}px; height:{h}px; overflow:hidden; }}
  body {{
    background:
      radial-gradient(120% 70% at 50% -8%, #FFE2D2 0%, rgba(255,226,210,0) 62%),
      linear-gradient(180deg, #FFFBF8 0%, #FDF1EA 100%);
    font-family:-apple-system, "SF Pro Display", "Helvetica Neue", Helvetica, Arial, sans-serif;
    -webkit-font-smoothing:antialiased;
  }}
  .caption {{
    padding:{pad_top}px 108px 0;
    text-align:center;
    font-size:{font}px;
    line-height:1.1;
    font-weight:800;
    letter-spacing:-0.024em;
    color:#1B1613;
    text-wrap:balance;
  }}
  .caption em {{ font-style:normal; color:#E04A1E; }}
  .stage {{
    position:absolute;
    top:{stage_top}px; left:50%;
    transform:translateX(-50%);
    width:{shot_w}px;
  }}
  .stage img {{
    display:block;
    width:{shot_w}px;
    border-radius:{radius}px;
    border:2px solid rgba(27,22,19,0.10);
    box-shadow:0 40px 90px rgba(74,38,20,0.20), 0 8px 24px rgba(74,38,20,0.10);
  }}
</style></head>
<body>
  <div class="caption">{caption}</div>
  <div class="stage"><img src="{src}"></div>
</body></html>
"""


def build(locale, order, shot, template, highlight, profile="iphone"):
    cfg = PROFILES[profile]
    # En el set de iPad el titular no puede hablar del iPhone.
    if profile == "ipad":
        template = template.replace("iPhone", "iPad")
    caption = html.escape(template).replace("{}", f"<em>{html.escape(highlight)}</em>")
    long_caption = len(template.replace("{}", highlight)) > 46
    shot_locale = SHOT_LOCALE.get(locale, locale)
    shot_file = SHOTS / (f"{cfg['prefix']}{shot_locale}-{order}.png" if cfg["prefix"] else shot)
    page = PAGE.format(
        w=cfg["w"], h=cfg["h"],
        pad_top=cfg["pad_top"],
        font=cfg["font_long"] if long_caption else cfg["font"],
        stage_top=cfg["stage_top"],
        shot_w=cfg["shot_w"],
        radius=cfg["radius"],
        caption=caption,
        src=shot_file.as_posix(),
    )
    out_html = HERE / f"{cfg['prefix']}{locale}-{order}.html"
    out_png = HERE / f"slide-{cfg['prefix']}{locale}-{order}.png"
    out_html.write_text(page, encoding="utf-8")
    subprocess.run([
        CHROME, "--headless", "--disable-gpu", "--hide-scrollbars",
        "--allow-file-access-from-files",
        f"--window-size={cfg['w']},{cfg['h']}",
        f"--screenshot={out_png}",
        "--virtual-time-budget=3000",
        out_html.as_uri(),
    ], capture_output=True, check=True)
    size = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(out_png)],
                          capture_output=True, text=True).stdout.split()
    print(f"{out_png.name}: {size[-3]}x{size[-1]}")


if __name__ == "__main__":
    import sys
    profile = sys.argv[1] if len(sys.argv) > 1 else "iphone"
    for slide in SLIDES:
        build(*slide, profile=profile)
