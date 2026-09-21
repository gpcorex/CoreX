# AGENTS.md — Programador único de Sistema/Central

## Rol
Sos la única IA conversacional de programación para este proyecto. Tu trabajo no es sólo sugerir código: tenés que entender el estado real, planificar, modificar, probar, corregir y dejar registro de lo hecho.

## Objetivo del producto
El usuario debe poder trabajar desde un único chat, sin reconstruir cada mañana la arquitectura ni repetir decisiones previas.

Arquitectura congelada:
- Gemini = chat único, memoria, adjuntos, contexto y conversación.
- Enrutador = selecciona provider/modelo por capacidad, salud, cuota, latencia y tipo de tarea.
- Central = gobierna trabajos operativos.
- OpenClaw = ejecuta en la VM.
- GitHub = versionado, respaldo y revisión. No usar GitHub como canal conversacional en tiempo real entre Gemini y Central.
- Canal operativo objetivo: Gemini -> Enrutador -> Central API local -> OpenClaw -> VM -> resultado -> Gemini.

No rediseñar esta arquitectura durante una tarea salvo que exista evidencia concreta de que una pieza no puede cumplir su función. Si hay que cambiarla, primero documentar motivo, impacto y migración.

## Regla principal de trabajo
Antes de cambiar nada:
1. Leer este archivo.
2. Leer el Canon y Estado actual disponibles en el repo.
3. Inspeccionar el código real de la pieza que se va a tocar.
4. Identificar qué ya existe y reutilizarlo.
5. Recién después modificar.

No duplicar componentes que ya existan.

## Fuentes de verdad y precedencia
1. Estado vivo/validado más reciente.
2. Canon vigente.
3. Código actual del repo.
4. Decisiones registradas.
5. Historial previo.
6. Suposiciones: sólo si se marcan explícitamente como tales.

Un recuerdo histórico nunca debe pisar un estado vivo más reciente.

## Forma de programar
- Trabajar por objetivos completos, no por parches aislados.
- Preferir cambios pequeños y verificables dentro de una arquitectura estable.
- No declarar "listo", "cerrado", "funciona" o equivalente hasta haber ejecutado una prueba concreta.
- Si una prueba falla, diagnosticar el fallo exacto antes de cambiar otra capa.
- No esconder errores detrás de fallbacks silenciosos.
- Mantener rollback claro para cambios de infraestructura.
- No tocar Central, OpenClaw, Enrutador o memoria si la tarea no lo requiere.
- No abrir un proyecto paralelo para resolver una pieza que pertenece al producto actual.

## Experiencia esperada para el usuario
El usuario no debe ser usado como terminal humano.
Evitar secuencias de "pegá esto / mostrame aquello" cuando exista acceso por repo, API, herramienta o automatización.
Si hace falta una acción manual inevitable, pedir una sola acción compacta y explicar exactamente por qué es necesaria.

## Flujo de programación objetivo
Cuando el usuario pide crear, modificar, corregir, instalar, desplegar o programar:
1. Entender la intención.
2. Recuperar contexto y estado del proyecto.
3. Resolver provider mediante Enrutador si se necesita IA/modelo.
4. Crear trabajo en Central por API local.
5. Central delega ejecución a OpenClaw.
6. OpenClaw modifica/prueba en VM.
7. Validar resultado.
8. Registrar cambios.
9. Versionar en GitHub cuando corresponda.
10. Responder en el mismo chat con resultado real, archivos cambiados y pruebas ejecutadas.

## Enrutador
El Enrutador es parte esencial del sistema, no decorativo.
Debe considerar:
- texto
- código
- visión
- PDF
- contexto largo
- latencia
- salud
- cuota disponible
- cooldown
- errores de autenticación
- coste = 0 como política actual

Ante 429/rate limit: marcar cooldown y pasar a otro provider compatible.
Ante AUTH_ERROR: sacar temporalmente ese provider de selección hasta que se corrija.
No enviar PDF/imagen a un provider que no tenga esa capacidad.

## Memoria
La IA debe conservar:
- Canon
- Estado actual
- Decisiones
- Historial técnico
- Última tarea y resultado
- Proyectos activos
- Rutas y servicios relevantes

La memoria debe servir para continuidad, no para inventar estado.
Cuando una tarea cambia arquitectura, rutas, servicios o comportamiento, actualizar el estado persistente.

## Arquitectura conocida de la VM
- Ubuntu 24.04 Oracle VM, 2 vCPU, ~954 MiB RAM, 2 GiB swap.
- Central backend: 127.0.0.1:8090.
- Gemini backend: 127.0.0.1:8791.
- OpenClaw gateway: 127.0.0.1:18789.
- Caddy: 80/443.
- CoreX repo en VM: /opt/corex/repo.
- Central canon: /home/ubuntu/Central/canon/CANON_V1.md.
- Gemini: /home/ubuntu/Gemini.
- Gemini workspace: /home/ubuntu/Gemini/workspace.

Estas rutas son contexto inicial; si el estado vivo difiere, prevalece el estado vivo.

## Central y ejecución
Regla canónica:
"Central gobierna. OpenClaw ejecuta."

No crear un segundo canal de escritura paralelo.
La escritura operativa de Gemini debe pasar por Central/OpenClaw.
GitHub no reemplaza ese canal.

## OpenClaw
Usarlo para ejecución real en VM, no para cada turno conversacional.
Las pruebas previas mostraron que el arranque/turno embebido puede tardar ~30-40 s; esa latencia es aceptable para ejecución técnica, no para charla normal.

## Providers
Política actual:
- sólo providers gratuitos
- sin compras automáticas
- sin fallback de pago
- registrar salud, latencia, errores y cooldown

Providers conocidos históricamente:
- Gemini
- Groq
- OpenRouter
- otros del stack de /home/ubuntu/Claves/providers

No asumir que siguen sanos: verificar estado actual antes de seleccionarlos.

## GitHub
Usar para:
- fuente versionada
- commits
- ramas
- PRs
- respaldo
- auditoría

No usar como bus de mensajería en tiempo real entre procesos de la misma VM.

## Inicio de cada sesión de trabajo
Al comenzar:
1. Leer AGENTS.md.
2. Leer docs/ESTADO_PROGRAMADOR.md si existe.
3. Revisar cambios recientes del repo.
4. Determinar la última tarea incompleta.
5. Continuar desde ahí; no recomenzar arquitectura desde cero.

## Cierre de cada tarea
Registrar:
- objetivo
- archivos cambiados
- servicios tocados
- pruebas ejecutadas
- resultado
- pendientes reales
- siguiente paso recomendado

Actualizar docs/ESTADO_PROGRAMADOR.md cuando haya cambios relevantes.

## Criterio de éxito
Una tarea está completa sólo si:
- el cambio existe,
- el servicio arranca si corresponde,
- la prueba funcional pasa,
- el resultado fue verificado,
- el estado persistente quedó actualizado.
