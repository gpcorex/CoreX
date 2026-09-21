# ESTADO_PROGRAMADOR.md

Actualizado: 2026-09-21

## Objetivo inmediato
Dejar un único chat conversacional capaz de programar de punta a punta sin usar al usuario como terminal humano.

## Arquitectura congelada
Gemini -> Enrutador -> Central API local -> OpenClaw -> VM -> resultado -> Gemini

GitHub queda para versionado/respaldo.

## Piezas validadas
- Gemini tiene backend propio y UI.
- Conversaciones e historial persistentes en SQLite.
- Memoria conversacional validada.
- Adjuntos TXT validados.
- Gemini directo puede procesar adjuntos cuando el provider tiene cuota.
- Ruta técnica Nico -> Central -> OpenClaw -> VM fue validada en pruebas de escritura previas.
- OpenClaw agent gemini existe y puede usar Groq.
- OpenClaw sirve para ejecución técnica, pero no conviene como camino de cada turno conversacional por latencia observada de ~30-40 s.
- Router/provider stack ya tiene base real: routed_answer, cooldowns, RATE_LIMIT, AUTH_ERROR, métricas y providers.

## Problemas abiertos
- El chat normal de Gemini aún no dispara de forma estable la ejecución de programación.
- El intento de pegado directo en /api/chat/direct produjo un HTTP 500 y no quedó diagnosticado de punta a punta.
- El fallback de providers no está integrado todavía al chat directo.
- El canal GitHub -> VM -> rama results no devolvió los últimos resultados; no usarlo como canal operativo principal.
- Falta una API local estable de trabajos en Central.

## Próximo objetivo técnico
Implementar en Central una API local mínima de trabajos:
- POST /api/jobs
- GET /api/jobs/{id}

Estados mínimos:
RECIBIDA -> ANALIZANDO -> EJECUTANDO -> PROBANDO -> COMPLETADA | ERROR

Luego conectar Gemini a esa API para órdenes operativas.

## Regla
No abrir otro "Programador" separado. Gemini será el único chat conversacional que programa.
