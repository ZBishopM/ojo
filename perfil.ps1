#Requires -Version 5.1
<#
El PERFIL del usuario y de su PC, "ya masticado": lo que Ojo sabe siempre y
no tiene que adivinar.

POR QUE: en los retos del 2026-09-23, a "cuanta VRAM estoy usando" (que el oido
escribio "virra") contesto "23% de la bateria de tu portatil". Es un PC de
escritorio sin bateria, y nadie se lo habia dicho. Palabras del usuario: "hay
que darle todos los datos ya masticados para que no adivine nada".

Dos partes en perfil.json:
  - "equipo": se genera del sistema (CIM, nvidia-smi, pantallas). Se rehace con
    -Generar; lo lanza ojo.ps1 si falta.
  - "usuario": a mano (ubicacion, juegos y apps). Se conserva al regenerar.

    .\perfil.ps1 -Generar          rehace la parte del equipo
    .\perfil.ps1                   muestra el bloque que recibe el modelo
    . .\perfil.ps1                 (con punto) Perfil-Texto
#>
$ErrorActionPreference = 'Stop'
$PERFIL_ARCHIVO = Join-Path $PSScriptRoot 'perfil.json'

function Generar-Perfil {
    Add-Type -AssemblyName System.Windows.Forms
    $cs = Get-CimInstance Win32_ComputerSystem
    $gpu = (& nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits) -split ',\s*'
    $equipo = [ordered]@{
        tipo      = if (@(Get-CimInstance Win32_Battery).Count) { 'portátil (con batería)' } else { 'PC de escritorio, SIN batería' }
        placa     = "$($cs.Manufacturer) $($cs.Model)"
        cpu       = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim()
        gpu       = "$($gpu[0]) con $([math]::Round([double]$gpu[1] / 1024, 1)) GB de VRAM"
        ram       = "$([math]::Round($cs.TotalPhysicalMemory / 1GB)) GB"
        monitores = @([Windows.Forms.Screen]::AllScreens | ForEach-Object { "$($_.Bounds.Width)x$($_.Bounds.Height)$(if ($_.Primary) { ' (principal)' })" })
        sistema   = (Get-CimInstance Win32_OperatingSystem).Caption
    }
    $usuario = if (Test-Path $PERFIL_ARCHIVO) { ([IO.File]::ReadAllText($PERFIL_ARCHIVO, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json).usuario } else { $null }
    if (-not $usuario) {
        $usuario = [ordered]@{
            vive_en  = 'Perú (hora de Lima, moneda: soles)'
            juegos   = @('League of Legends (sobre todo ARAM Mayhem)', 'Hearthstone')
            apps     = @('Discord', 'WhatsApp (en Firefox)', 'Firefox Developer Edition', 'WezTerm', 'GlazeWM (workspaces)', 'DaVinci Resolve')
        }
    }
    $p = [ordered]@{ generado = (Get-Date -Format 'yyyy-MM-dd'); equipo = $equipo; usuario = $usuario }
    [IO.File]::WriteAllText($PERFIL_ARCHIVO, ($p | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    $p
}

# El bloque para el modelo (~8 lineas).
function Perfil-Texto {
    if (-not (Test-Path $PERFIL_ARCHIVO)) { $null = Generar-Perfil }
    $p = [IO.File]::ReadAllText($PERFIL_ARCHIVO, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    $e = $p.equipo; $u = $p.usuario
    "`n`nPERFIL (exacto; es SU equipo, no lo adivines):`n" + (@(
        "equipo: $($e.tipo); $($e.cpu); $($e.gpu); $($e.ram) de RAM; $($e.sistema)"
        "monitores: $(@($e.monitores) -join ' y ')"
        "vive en: $($u.vive_en)"
        "juega: $(@($u.juegos) -join ', ')"
        "usa: $(@($u.apps) -join ', ')"
    ) -join "`n")
}

if ($MyInvocation.InvocationName -eq '.') { return }
if ($args -contains '-Generar') { $null = Generar-Perfil }
Perfil-Texto
