# Resilience Ring + VLABS Monitor - Architecture

## Overview

**Resilience Ring** es un cliente Windows que sincroniza backups locales a múltiples nodos remotos vía Tailscale, creando redundancia geográfica distribuida.

**VLABS Monitor** es el servidor centralizado (dentro de la misma red Tailscale) que:
- Recibe telemetría de todos los clientes Resilience Ring
- Presenta un dashboard unificado
- Envía alertas por Telegram cuando se requiere acción

## Components

### 1. Resilience Ring (Cliente Windows)
- **Ubicación:** Cada sitio del cliente
- **Función:** Ejecutar backups programados hacia nodos hermanos
- **Reporta a:** VLABS Monitor

**Datos que reporta:**
- Heartbeat periódico (estoy vivo)
- Status de cada backup (success/failed)
- Checksums de archivos copiados
- Errores y excepciones
- Métricas: tiempo de ejecución, bytes transferidos

### 2. VLABS Monitor (Servidor)
- **Ubicación:** Un nodo dentro de Tailscale (ej: gz-app26)
- **Componentes:**

#### a) Collector Service
- API REST que recibe datos de clientes
- Almacena en SQLite/PostgreSQL
- Endpoints:
  - `POST /api/heartbeat` - Cliente reporta que está vivo
  - `POST /api/backup/result` - Resultado de un backup
  - `POST /api/backup/checksum` - Verificación de integridad
  - `GET /api/health` - Health check del servicio

#### b) Dashboard Web
- Vista de todos los clientes registrados
- Filtros por:
  - Etiqueta (grupo/cliente)
  - Dominio Tailscale
  - Estado (healthy/warning/critical)
- Historial de backups por nodo
- Gráficas de tendencias

#### c) Alert Engine
- Evalúa condiciones de alerta:
  - Heartbeat no recibido en X minutos
  - Backup fallido
  - Checksum mismatch
  - Espacio en disco bajo
- **Envía alertas SOLO por Telegram** al grupo "Clawdey - VLABS Monitor"

## Data Flow

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  Sitio A (SLP)  │     │  Sitio B (MTY)  │     │  Sitio C (GDL)  │
│ Resilience Ring │     │ Resilience Ring │     │ Resilience Ring │
└────────┬────────┘     └────────┬────────┘     └────────┬────────┘
         │                       │                       │
         │  Tailscale (100.x.x.x network)               │
         │                       │                       │
         └───────────────────────┼───────────────────────┘
                                 │
                                 ▼
                    ┌────────────────────────┐
                    │     VLABS Monitor      │
                    │  (gz-app26 / Tailscale)│
                    ├────────────────────────┤
                    │ • Collector Service    │
                    │ • Dashboard Web        │
                    │ • Alert Engine         │
                    └───────────┬────────────┘
                                │
                                ▼
                    ┌────────────────────────┐
                    │  Telegram Group        │
                    │  "Clawdey - VLABS Mon" │
                    └────────────────────────┘
```

## Backup Flow (con checksums)

1. Scheduled Task dispara Execute-Backup.ps1
2. Conecta Tailscale
3. Monta share SMB
4. Copia archivos con robocopy
5. **NUEVO:** Calcula checksum SHA256 de archivos copiados
6. **NUEVO:** Verifica checksum en destino
7. **NUEVO:** Reporta resultado + checksum a VLABS Monitor
8. Aplica retención
9. Desconecta

## Security Notes

- Todo el tráfico va por Tailscale (WireGuard encrypted)
- Credenciales SMB encriptadas con DPAPI (por máquina/usuario)
- Sin encriptación en reposo (misma entidad legal dueña de todos los nodos)
- VLABS Monitor solo accesible dentro de Tailscale

## Telegram Alerts

**Grupo:** Clawdey - VLABS Monitor

**Tipos de alerta:**
- 🔴 CRITICAL: Backup fallido, checksum mismatch
- 🟡 WARNING: Heartbeat retrasado, espacio bajo
- 🟢 INFO: Backup completado (opcional, configurable)

---
*Documento creado: 2026-02-11*
*Autores: Gonzalo + Clawdey*
