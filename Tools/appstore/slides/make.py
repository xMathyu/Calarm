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
    #
    # Orden de 1.0.15. El 82 % de las descargas llega desde la búsqueda, y el
    # resultado de búsqueda solo enseña las TRES primeras: ahí va lo que distingue
    # a Calarm de otro despertador (el reto para apagarla y la cuenta regresiva).
    # Salieron la recurrencia y los tonos, que eran formularios.
    ("es", 1, "es-1.png", "Suena fuerte aunque el iPhone esté en {}", "silencio"),
    ("es", 2, "es-2.png", "Resuelve un juego para {}", "apagarla"),
    ("es", 3, "es-3.png", "Cuenta los días que faltan para {}", "lo que importa"),
    ("es", 4, "es-4.png", "Cumpleaños que se repiten {}, cada año", "solos"),
    ("es", 5, "es-5.png", "Tu próxima alarma, en la {}", "pantalla de inicio"),
    ("es", 6, "es-6.png", "Tus reuniones, con alarma {}", "de verdad"),
    ("es", 7, "es-7.png", "Díselo y listo, con {}", "Apple Intelligence"),
    ("en", 1, "en-1.png", "Rings loud even when your iPhone is {}", "silent"),
    ("en", 2, "en-2.png", "Solve a game to {}", "turn it off"),
    ("en", 3, "en-3.png", "Count down the days to {}", "what matters"),
    ("en", 4, "en-4.png", "Birthdays that repeat {}, every year", "on their own"),
    ("en", 5, "en-5.png", "Your next alarm, right on your {}", "Home Screen"),
    ("en", 6, "en-6.png", "Your meetings, with a {}", "real alarm"),
    ("en", 7, "en-7.png", "Just say it — with {}", "Apple Intelligence"),
    ("de", 1, "en-1.png", "Klingelt laut, auch wenn dein iPhone {} ist", "stumm"),
    ("de", 2, "en-2.png", "Löse ein Spiel, um ihn {}", "auszuschalten"),
    ("de", 3, "en-3.png", "Zähle die Tage bis zu {}", "deinem großen Tag"),
    ("de", 4, "en-4.png", "Geburtstage, die sich {} wiederholen", "von selbst"),
    ("de", 5, "en-5.png", "Dein nächster Wecker auf dem {}", "Home-Bildschirm"),
    ("de", 6, "en-6.png", "Deine Termine, mit einem {}", "echten Alarm"),
    ("de", 7, "en-7.png", "Sag es einfach — mit {}", "Apple Intelligence"),
    # Brasil (1.0.16): capturas propias en portugués, con -AppleLocale pt_BR para
    # que la hora salga en 24 h. Sin la 7 (asistente): la ficha pt-BR no lo
    # promete hasta probarlo en portugués en un dispositivo.
    ("pt", 1, "pt-1.png", "Toca alto mesmo com o iPhone no {}", "silencioso"),
    ("pt", 2, "pt-2.png", "Resolva um jogo para {}", "desligar"),
    ("pt", 3, "pt-3.png", "Conte os dias até {}", "o que importa"),
    ("pt", 4, "pt-4.png", "Aniversários que se repetem {}", "todo ano"),
    ("pt", 5, "pt-5.png", "Seu próximo alarme, direto na {}", "Tela de Início"),
    ("pt", 6, "pt-6.png", "Suas reuniões, com um alarme {}", "de verdade"),
]
# Las capturas `<locale>-<n>.png` las saca ../capture_all.sh, que lleva la
# pantalla de demo de cada número: si se cambia el orden aquí, cambiarlo allí.

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
    # Opcional: solo unos locales, p. ej. `make.py iphone pt`.
    only = set(sys.argv[2:])
    for slide in SLIDES:
        if not only or slide[0] in only:
            build(*slide, profile=profile)
