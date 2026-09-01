#!/usr/bin/env python3
"""Genera los tonos de alarma de Calarm (Calarm/Sounds/*.caf).

Los tonos son sintetizados aquí (sin dependencias ni licencias de terceros) para
poder regenerarlos o afinarlos sin buscar audio externo:

    python3 Tools/generate_tones.py

Dos restricciones de AlarmKit mandan en el diseño:

  * El archivo debe vivir en el bundle de la app y durar MENOS de 30 s
    (`AlertConfiguration.AlertSound.named`).
  * iOS 26 no hace loop del sonido personalizado: lo reproduce UNA vez. Por eso
    cada archivo dura ~28 s con el patrón repetido internamente, y así el alerta
    suena todo el tiempo aunque el sistema no repita.

Salida: CAF/IMA4 mono 44.1 kHz (~620 KB por tono). El formato NO es casual: el
reproductor de sonidos del sistema (el mismo que usan las notificaciones) acepta
Linear PCM, IMA4/ADPCM, µLaw y aLaw — no AAC. Para volver a PCM sin comprimir,
cambiar `AFCONVERT_ARGS` a `["-d", "LEI16"]` (~2.5 MB por tono).
"""

from __future__ import annotations

import math
import os
import struct
import subprocess
import sys
import wave

SAMPLE_RATE = 44100
DURATION = 28.0  # segundos; el límite de AlarmKit es 30
FADE_OUT = 0.08  # segundos, para que el corte final no chasquee
AFCONVERT_ARGS = ["-d", "ima4"]

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Calarm", "Sounds")


# --- síntesis ---------------------------------------------------------------

def render(freq, dur, partials, decay, attack=0.006, tremolo=0.0):
    """Una nota: suma de parciales con envolvente ataque + decaimiento exponencial.

    `partials` es [(razón de frecuencia, amplitud)]; razones no enteras dan el
    timbre inarmónico de una campana, enteras dan madera/cuerda.
    """
    n = int(dur * SAMPLE_RATE)
    attack_n = max(1, int(attack * SAMPLE_RATE))
    out = [0.0] * n
    for ratio, amp in partials:
        omega = 2.0 * math.pi * freq * ratio / SAMPLE_RATE
        # Los parciales altos se apagan antes: es lo que hace que suene a golpe.
        partial_decay = decay / (1.0 + 0.55 * (ratio - 1.0))
        for i in range(n):
            env = math.exp(-i / (partial_decay * SAMPLE_RATE))
            if i < attack_n:
                env *= i / attack_n
            out[i] += amp * env * math.sin(omega * i)
    if tremolo:
        for i in range(n):
            out[i] *= 0.65 + 0.35 * math.sin(2.0 * math.pi * tremolo * i / SAMPLE_RATE)
    # Release corto para que ninguna nota termine en seco.
    release_n = min(n, int(0.004 * SAMPLE_RATE))
    for k in range(release_n):
        out[n - release_n + k] *= 1.0 - k / release_n
    return out


def beep(freq, dur, harmonics=4):
    """Pitido tipo despertador: armónicos impares (onda cuadrada suavizada)."""
    partials = [(2 * k + 1, 1.0 / (2 * k + 1)) for k in range(harmonics)]
    return render(freq, dur, partials, decay=dur * 3, attack=0.004)


def mix(buffer, note, at):
    start = int(at * SAMPLE_RATE)
    end = min(len(buffer), start + len(note))
    for i in range(start, end):
        buffer[i] += note[i - start]


def build(pattern, cycle):
    """Repite `pattern` (lista de (offset, nota)) cada `cycle` segundos."""
    total = int(DURATION * SAMPLE_RATE)
    buf = [0.0] * total
    t = 0.0
    while t < DURATION:
        for offset, note in pattern:
            if t + offset < DURATION:
                mix(buf, note, t + offset)
        t += cycle
    return buf


def normalize(buf, peak=0.89):
    high = max(abs(v) for v in buf) or 1.0
    gain = peak / high
    fade_n = int(FADE_OUT * SAMPLE_RATE)
    n = len(buf)
    for i in range(n):
        v = buf[i] * gain
        if i >= n - fade_n:
            v *= (n - i) / fade_n
        buf[i] = v
    return buf


def write_wav(path, buf):
    frames = b"".join(
        struct.pack("<h", max(-32768, min(32767, int(v * 32767)))) for v in buf
    )
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(frames)


# --- los seis tonos ---------------------------------------------------------

# Notas en Hz (cuarta y quinta octava).
A4, CS5, E5, G5, A5, C6, CS6, E6, G6, C7 = (
    440.0, 554.37, 659.26, 783.99, 880.0, 1046.50, 1108.73, 1318.51, 1567.98, 2093.00
)

BELL = [(1.0, 1.0), (2.02, 0.55), (2.41, 0.35), (3.04, 0.22), (4.52, 0.12)]
WOOD = [(1.0, 1.0), (4.0, 0.32), (10.1, 0.10)]
PLUCK = [(1.0, 1.0), (2.0, 0.45), (3.0, 0.22), (4.0, 0.12), (5.0, 0.07)]
HARP = [(1.0, 1.0), (2.0, 0.28), (3.0, 0.09)]


def tones():
    yield "tone-chime", build(
        [
            (0.00, render(C6, 2.2, BELL, 1.30)),
            (0.36, render(E6, 2.2, BELL, 1.30)),
            (0.72, render(G6, 2.2, BELL, 1.30)),
            (1.08, render(C7, 2.6, BELL, 1.60)),
        ],
        cycle=4.0,
    )

    yield "tone-marimba", build(
        [
            (0.00, render(G5, 0.9, WOOD, 0.42)),
            (0.17, render(C6, 0.9, WOOD, 0.42)),
            (0.34, render(E6, 0.9, WOOD, 0.42)),
            (0.51, render(C6, 1.1, WOOD, 0.52)),
        ],
        cycle=2.0,
    )

    yield "tone-radar", build(
        [
            (0.00, beep(1000.0, 0.16)),
            (0.26, beep(1000.0, 0.16)),
            (0.52, beep(1250.0, 0.20)),
        ],
        cycle=1.15,
    )

    yield "tone-arpeggio", build(
        [
            (0.00, render(A4, 1.0, PLUCK, 0.55)),
            (0.12, render(CS5, 1.0, PLUCK, 0.55)),
            (0.24, render(E5, 1.0, PLUCK, 0.55)),
            (0.36, render(A5, 1.0, PLUCK, 0.55)),
            (0.48, render(CS6, 1.4, PLUCK, 0.75)),
        ],
        cycle=2.5,
    )

    yield "tone-pulse", build(
        [
            (0.00, render(A4, 0.34, [(1.0, 1.0), (2.0, 0.30)], 0.16, tremolo=14.0)),
            (0.40, render(A4, 0.34, [(1.0, 1.0), (2.0, 0.30)], 0.16, tremolo=14.0)),
        ],
        cycle=0.8,
    )

    ascending = [A4, CS5, E5, A5, CS6, E6, G6]
    yield "tone-harp", build(
        [(0.20 * i, render(f, 1.8, HARP, 1.05, attack=0.012))
         for i, f in enumerate(ascending)],
        cycle=5.0,
    )


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    for name, buf in tones():
        wav = os.path.join(OUT_DIR, name + ".wav")
        caf = os.path.join(OUT_DIR, name + ".caf")
        write_wav(wav, normalize(buf))
        subprocess.run(
            ["afconvert", "-f", "caff", *AFCONVERT_ARGS, wav, caf],
            check=True,
        )
        os.remove(wav)
        print(f"{name}.caf  {os.path.getsize(caf) / 1024:6.0f} KB")


if __name__ == "__main__":
    sys.exit(main())
