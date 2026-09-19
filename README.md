# Conector Deploy Hub

Repositorio de control para despliegues de la VM.

## Objetivo
Unificar despliegue y mantenimiento de:
- Central
- Android Bridge
- Verita
- futuros servicios

## Nombre
El puente operativo se llama **Conector**.
El repositorio mantiene temporalmente el nombre histórico `gpcorex/CoreX` para no romper el circuito de sincronización mientras se completa la migración.

## Seguridad
Este repositorio no debe contener secretos.
Variables sensibles y credenciales viven solamente en la VM, fuera del repositorio.

## Flujo
ChatGPT/GitHub -> commit -> Conector detecta cambio -> VM ejecuta -> validación/resultado.

## Estructura
- bootstrap.sh: instalación inicial del Conector en la VM
- deploy.sh: despachador de despliegues
- projects/: scripts independientes por proyecto
- central-ops/: tareas operativas de Central
