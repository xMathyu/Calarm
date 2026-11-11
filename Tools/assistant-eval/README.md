# Tools/assistant-eval

Banco de pruebas de la pestaña Asistente contra el modelo on-device de Apple Intelligence,
corriendo en el Mac (macOS 27 trae el mismo `SystemLanguageModel` que el iPhone). Sirve para
cambiar el prompt o las tools con números en la mano, no a ojo: el modelo de 3B es
caprichoso y cada cambio que arregla un caso suele romper otro.

`gen.py` **extrae del código real** las instrucciones (`instructionsText`), los
`@Generable Arguments` de las tools y los helpers de `AssistantService`, y los junta con
`driver.swift`, donde las tools son simuladas: solo anotan qué pidió el modelo. Así lo que se
prueba nunca se desfasa de la app.

```sh
Tools/assistant-eval/run.sh unit     # helpers puros (rangos, idioma, "creé" falso, JSON…)
Tools/assistant-eval/run.sh tokens   # cuánto ocupan prompt + tools
Tools/assistant-eval/run.sh eval     # 15 casos calificados × TRIALS (default 3)
ONLY=0,5 Tools/assistant-eval/run.sh eval
Tools/assistant-eval/run.sh chat "pon una alarma mañana a las 8||y otra el viernes"
BASELINE_REF=HEAD Tools/assistant-eval/run.sh eval   # mismo examen al código de un commit
```

La calificación replica las reglas que aplica `CreateReminderTool` (una vez frente a semanal,
horarios extra en la misma alarma, avisos), así que mide lo que quedaría guardado, no solo lo
que dijo el modelo. El reloj está fijo en el reporte original: martes 2026-11-10 18:59, Lima.

Referencia (2026-11-10, 15 casos × 3): el código anterior fallaba 13/45 y respondía en el
idioma equivocado 24 veces; el actual falla 4/45 y 3.

Trampas:
- **Nunca dos corridas a la vez**: las sesiones concurrentes del modelo se cuelgan.
- Envolver `session.respond` en un task group con timeout también se cuelga.
- Una corrida completa tarda ~10 min; más si hay simuladores ocupando la máquina.
