# SecureBackups - Resilience Ring

## Contexto del proyecto

VLABS instala este sistema en clientes como servicio de respaldo comercial. Cada cliente tiene uno o más **peers** (servidores Windows) que corren el agente (`Execute-Backup.ps1`) y se respaldan entre sí a través de Tailscale.

El ecosistema tiene tres capas:
1. **Peer agent** (`Execute-Backup.ps1`, `VLABS-SecureBackup.ps1`) - corre en cada servidor cliente
2. **RRM** (`ResilienceRingManager.ps1`) - UI de gestión que corre en el servidor del cliente
3. **API + Web** (`ResilienceRingAPI`, `resilience-ring-web`) - plataforma central de VLABS

## Repos relacionados

- **SecureBackups** (este repo) - scripts PowerShell del agente peer + RRM
  - Ruta en peers: `C:\VLABS_resiliencering\` (puede variar por cliente)
  - Config/datos: `C:\ProgramData\VLABS_ResilienceRing\`
  - Logs: `C:\ProgramData\VLABS_ResilienceRing\Logs\`
- **ResilienceRingAPI** - API .NET en `C:\Users\mike\Proyectos\VLABS\ACC\ResilienceRingAPI`
- **resilience-ring-web** - Angular frontend en `C:\Users\mike\Proyectos\VLABS\ACC\resilience-ring-web`

## Archivos clave

| Archivo | Propósito |
|---|---|
| `Execute-Backup.ps1` | Ejecuta un job de backup. Llamado por tarea programada y manualmente |
| `VLABS-SecureBackup.ps1` | Menu TUI de gestion. Lanzar backups manuales, configurar jobs/destinos |
| `ResilienceRingManager.ps1` | UI de monitoreo del anillo. Muestra estado de peers y jobs |
| `PeerManagement.ps1` | Funciones de Tailscale, conectividad, descubrimiento de peers |
| `CryptoUtils.ps1` | Cifrado de credenciales con DPAPI |
| `version.txt` | Version del agente peer (auto-update la compara contra GitHub) |
| `rrm-version.txt` | Version del RRM (separado del agente) |

## Arquitectura de datos

- `jobs.json` - Master data: configuracion de jobs (no cambia en runtime)
- `jobs-status.json` - Transaction data: estado/historial de ejecuciones
- `ring-config.json` - Config del anillo: RrmApiUrl, ApiKey, Hostname, StoragePath
- `destinations.json` - Destinos de backup configurados

## Auto-update

- Tarea programada `RR-AutoUpdate` corre cada hora
- Llama `Execute-Backup.ps1 -UpdateOnly`
- Descarga archivos individualmente via GitHub Contents API (no ZIP)
- Verifica version en `version.txt` antes de actualizar
- Debe registrarse con principal SYSTEM y `-WindowStyle Hidden`
- Si un peer no puede auto-actualizarse, bootstrap manual:
  ```powershell
  $installPath = "C:\VLABS_resiliencering"
  $base = "https://raw.githubusercontent.com/GonzFC/SecureBackups/main"
  @("Execute-Backup.ps1","VLABS-SecureBackup.ps1","PeerManagement.ps1","CryptoUtils.ps1","version.txt","rrm-version.txt") | ForEach-Object {
      Invoke-WebRequest "$base/$_" -OutFile "$installPath\$_" -UseBasicParsing -TimeoutSec 30
      Write-Host "OK: $_"
  }
  ```

## Convenciones criticas

- **Solo ASCII puro en todos los .ps1** - PowerShell 5.1 en Windows lee con codepage del sistema (CP1252 por defecto). Caracteres Unicode (em dashes, flechas, box-drawing) causan ParseException. Nunca usar: `—`, `→`, `─`, `≈`, ni ningún caracter fuera de ASCII 0-127.
- **Exit codes robocopy**: 0-7 = exito (bit flags), 8+ = error. Usar `[System.Diagnostics.Process]::Start()` con `UseShellExecute=$false` para leer ExitCode de forma confiable (Start-Process -NoNewWindow puede retornar ExitCode=null en PS 5.1).
- **Start-Process para jobs manuales**: usar `Start-Process -WindowStyle Hidden` (no `Start-Job`) para que el proceso hijo sobreviva si se cierra la ventana padre.
- **Heartbeat a API**: `Send-RrmHeartbeat` en bloque `finally` de `Invoke-BackupJob`. Todo path de falla (Tailscale, crash early) debe mandar heartbeat para que la API no quede en status "Running".
- **Separacion master/transaction**: `jobs.json` nunca se modifica en runtime. `jobs-status.json` es la unica fuente de estado mutable.

## Bugs conocidos y por que el codigo esta como esta

Estas decisiones de diseno no son obvias. Si ves el codigo y te preguntas "por que hacen esto asi", la razon esta aqui.

### PowerShell 5.1 no lee UTF-8 sin BOM
Los .ps1 en este repo son ASCII puro. Antes tenian em dashes (`-`), flechas (`->`), caracteres box-drawing. PowerShell 5.1 en Windows usa CP1252 por defecto si no hay BOM, convirtiendo esos chars en `a-"` y causando ParseException al cargar el script. El resultado visible: jobs se quedaban en status "Running" porque el proceso moria antes de arrancar. **Regla: nunca usar caracteres fuera de ASCII 0-127 en ningun .ps1.**

### `proc.ExitCode` es null con `Start-Process -NoNewWindow` en PS 5.1
En `Invoke-BackupToPeer`, robocopy se lanza via `[System.Diagnostics.Process]::Start()` con `UseShellExecute=$false`, NO con `Start-Process`. Razon: `Start-Process -NoNewWindow -PassThru` en algunos builds de Windows/PS 5.1 cierra el handle del proceso antes de que `ExitCode` sea legible, retornando null. Con `ProcessStartInfo` + `UseShellExecute=$false` el handle se mantiene abierto hasta que se llama `Dispose()` explicitamente.

### `Start-Job` vs `Start-Process` para ejecutar jobs manualmente
`VLABS-SecureBackup.ps1` usa `Start-Process -WindowStyle Hidden` para lanzar `Execute-Backup.ps1`. Antes usaba `Start-Job`. El problema con `Start-Job`: el proceso hijo esta atado a la sesion padre. Cuando el usuario cierra la ventana del menu, el job de backup se mata a mitad, sin reportar resultado a la API. `Start-Process` crea un proceso completamente independiente.

### Dos version files separados
`version.txt` es la version del peer agent. `rrm-version.txt` es la version del RRM. Son independientes porque el RRM y el agente pueden actualizarse por separado. Ambos se deben bumpar cuando cambia el archivo correspondiente.

### Auto-update solo en tarea programada, nunca antes de un job
Antes de v1.9.73, `Invoke-AutoUpdate` se llamaba antes de cada backup. Si GitHub era lento o el ZIP fallaba, el backup nunca arrancaba. Ahora `Invoke-AutoUpdate` solo se llama en modo `-UpdateOnly` (tarea programada horaria). Los jobs de backup no esperan actualizaciones.

### Tarea `RR-AutoUpdate` debe correr como SYSTEM
Si se registra con el usuario actual y ese usuario no tiene sesion activa (ej. servidor sin nadie logueado), la tarea falla silenciosamente. `Ensure-AutoUpdateTask` en ambos scripts verifica el principal y recrea la tarea si no es SYSTEM.

### Heartbeat en `finally`, no solo en el camino feliz
`Send-RrmHeartbeat` esta en el bloque `finally` de `Invoke-BackupJob` para garantizar que la API siempre reciba el resultado final. Ademas, los paths de falla tempranos (Tailscale unavailable, crash antes de `Invoke-BackupJob`) tambien mandan heartbeat explicitamente. Sin esto, la API queda mostrando el job como "Running" indefinidamente.

## Versiones actuales

- Peer agent: ver `version.txt` (actualmente 1.9.78)
- RRM: ver `rrm-version.txt` (actualmente 1.2.5)

## Como probar cambios

En el servidor Windows con el repo clonado, desde PowerShell Admin:

```powershell
# Probar un job especifico (visible, muestra logs en consola)
.\Execute-Backup.ps1 -JobName "nombre-del-job"

# Probar solo el autoupdate
.\Execute-Backup.ps1 -UpdateOnly

# Ver log del dia
$logDir = "C:\ProgramData\VLABS_ResilienceRing\Logs"
Get-ChildItem $logDir | Sort-Object LastWriteTime | Select-Object -Last 1 | Get-Content | Select-Object -Last 80

# Ver tarea programada de autoupdate
Get-ScheduledTask "RR-AutoUpdate" | Select-Object TaskName, @{N='Principal';E={$_.Principal.UserId}}, @{N='Args';E={$_.Actions.Arguments}}
```

## Flujo de trabajo recomendado

1. Editar archivo en repo local del servidor Windows
2. Probar con `.\Execute-Backup.ps1 -JobName "..."` directamente
3. Si funciona, bump version en `version.txt` (y `rrm-version.txt` si cambia RRM)
4. Commit + push a `main`
5. Los peers se auto-actualizan en la siguiente hora via tarea programada
