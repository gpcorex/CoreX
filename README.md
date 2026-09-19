# CoreX Deploy Hub

Repositorio de control para despliegues de la VM.

## Objetivo
Unificar despliegue y mantenimiento de proyectos como:
- Central
- Android Bridge
- Gemini
- Verita
- futuros servicios

## Seguridad
Este repositorio no debe contener secretos.
Variables sensibles y credenciales viven solamente en la VM, bajo /etc/corex/.

## Flujo
ChatGPT/GitHub -> commit en CoreX -> VM detecta cambio -> deploy -> log local.

## Estructura
- bootstrap.sh: instalación inicial en la VM
- deploy.sh: sincroniza proyectos declarados
- projects/: scripts independientes por proyecto
