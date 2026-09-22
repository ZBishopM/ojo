<#
Banco de VISION sobre una captura fija, para comparar configuraciones del
modelo (cuantizacion de pesos, del mmproj, del KV) sin depender de lo que haya
en pantalla ese dia.

POR QUE EXISTE: `probar-senalar.ps1` y `comparar-precision.ps1` miden sobre la
ventana viva de Discord, que cambia entre ejecuciones -- sirven para ver si Ojo
funciona, no para decidir si Q6_K ve igual que Q8_0. Para eso hace falta la
MISMA imagen y la MISMA respuesta correcta en cada vuelta.

Dos tipos de prueba sobre `escenas/captura-referencia.jpg` (1280x720, una
captura real que Ojo mando al modelo el 2026-09-22):

  LEER     texto que se ve en la imagen; se comprueba la cifra exacta
  SENALAR  un sitio; acierta si el punto cae dentro de la caja, con un margen
           de 20 px, y se anota la distancia al centro

Las cajas se midieron en pixeles sobre recortes con rejilla de 10 px, no a
ojo. Se usa el MISMO prompt de sistema que Ojo, para medir lo que Ojo usa.

    .\banco-vision.ps1 -Nombre base
    .\banco-vision.ps1 -Nombre q6 -Modelo F:\...\Q6_K.gguf -Extra '-ctk','q8_0'
#>
param(
    [Parameter(Mandatory)][string]$Nombre,
    [string]$Modelo = 'F:\ai\models\qwen3-vl-8b\Qwen3-VL-8B-Instruct-Q8_0.gguf',
    [string]$Mmproj = 'F:\ai\models\qwen3-vl-8b\mmproj-F16.gguf',
    [string[]]$Extra = @(),
    [int]$Vueltas = 1,
    [string]$Imagen = 'D:\2026-projects\ojo\escenas\captura-referencia.jpg',
    [string]$Raiz = 'D:\2026-projects\ojo'
)
$ErrorActionPreference = 'Stop'
$llama = 'F:\ai\llama.cpp\llama-server.exe'
$W = 1280; $H = 720
$MARGEN = 20

# El mismo SISTEMA que ojo.ps1, leido de alli para que no se desincronicen.
$fuente = Get-Content "$Raiz\ojo.ps1" -Raw
$SISTEMA = [regex]::Match($fuente, "(?s)\`$SISTEMA = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
if (-not $SISTEMA) { throw 'no encontre $SISTEMA en ojo.ps1' }

$LEER = @(
    @{ q = 'Que hora marca el reloj de la barra superior?';                        esp = '12[:.]17' }
    @{ q = 'Cuantos vatios marca la barra superior?';                               esp = '218' }
    @{ q = 'Que porcentaje de RAM indica la barra superior?';                       esp = '45' }
    @{ q = 'Como se llama el archivo abierto en el editor de arriba a la izquierda?'; esp = 'test\.py' }
    @{ q = 'Que temperatura tiene la GPU segun la barra superior?';                 esp = '47' }
)
# Cajas en pixeles: x1, y1, x2, y2.
$SENALAR = @(
    @{ q = 'Senala el reloj de la barra superior.';                                  caja = 622, 3, 656, 20 }
    @{ q = 'Senala donde la barra superior indica el consumo en vatios.';            caja = 752, 3, 775, 20 }
    @{ q = 'Senala donde la barra superior indica el porcentaje de RAM.';            caja = 905, 3, 943, 20 }
    @{ q = 'Senala el boton de cerrar (la X) de la ventana del editor de arriba a la izquierda.'; caja = 612, 31, 628, 46 }
    @{ q = 'Senala la pestana del archivo test.py en el editor.';                    caja = 159, 51, 218, 70 }
    @{ q = "Senala donde pone 'Dejame ver'.";                                         caja = 588, 654, 692, 674 }
)

function Matar { Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'" | Where-Object { $_.CommandLine -match '--port 8099' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue } }

Matar; Start-Sleep -Seconds 3
$a = @('--model', $Modelo, '--mmproj', $Mmproj, '--ctx-size', '8192', '--n-gpu-layers', '99',
       '--flash-attn', 'on', '--threads', '6', '--parallel', '1', '--load-mode', 'none',
       '--cache-ram', '1024', '--port', '8099', '--host', '127.0.0.1') + $Extra
$null = Start-Process $llama -ArgumentList $a -WindowStyle Hidden -PassThru `
        -RedirectStandardError "$Raiz\banco-vision.log" -RedirectStandardOutput "$Raiz\banco-vision.out"
for ($i = 0; $i -lt 600; $i++) {
    Start-Sleep -Milliseconds 300
    try { if ((Invoke-RestMethod http://127.0.0.1:8099/health -TimeoutSec 2).status -eq 'ok') { break } } catch { }
}

$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Imagen))
function Preguntar($q) {
    $cuerpo = @{
        stream = $false; max_tokens = 200; temperature = 0
        chat_template_kwargs = @{ enable_thinking = $false }
        messages = @(
            @{ role = 'system'; content = $SISTEMA },
            @{ role = 'user'; content = @(
                @{ type = 'image_url'; image_url = @{ url = "data:image/jpeg;base64,$b64" } },
                @{ type = 'text'; text = $q }) })
    } | ConvertTo-Json -Depth 8 -Compress
    $r = Invoke-RestMethod http://127.0.0.1:8099/v1/chat/completions -Method Post -ContentType 'application/json' `
            -Body ([Text.Encoding]::UTF8.GetBytes($cuerpo)) -TimeoutSec 300
    $t = $r.choices[0].message.content
    $j = $null
    $m = [regex]::Match($t, '(?s)\{.*\}')
    if ($m.Success) { try { $j = $m.Value | ConvertFrom-Json } catch { } }
    @{ texto = $t; json = $j; ms = [math]::Round($r.timings.prompt_ms + $r.timings.predicted_ms) }
}

$filas = @()
for ($v = 1; $v -le $Vueltas; $v++) {
    foreach ($p in $LEER) {
        $r = Preguntar $p.q
        $dijo = if ($r.json.decir) { $r.json.decir } else { $r.texto }
        $filas += [pscustomobject]@{ tipo = 'leer'; q = $p.q; ok = [bool]($dijo -match $p.esp); px = $null; dijo = $dijo; ms = $r.ms }
    }
    foreach ($p in $SENALAR) {
        $r = Preguntar $p.q
        $s = $r.json.senalar
        $ok = $false; $d = $null
        if ($s -and $null -ne $s.x -and $null -ne $s.y) {
            # Algunos modelos Qwen contestan en escala 0-1000 aunque se les pida
            # 0-1. Se acepta y se anota: es la forma nativa de Qwen-VL, y
            # castigarla mediria la obediencia al formato, no la vision.
            $x = [double]$s.x; $y = [double]$s.y
            if ($x -gt 1 -or $y -gt 1) { $x /= 1000; $y /= 1000 }
            $px = $x * $W; $py = $y * $H
            $c = $p.caja
            $ok = $px -ge ($c[0] - $MARGEN) -and $px -le ($c[2] + $MARGEN) -and $py -ge ($c[1] - $MARGEN) -and $py -le ($c[3] + $MARGEN)
            $d = [math]::Round([math]::Sqrt([math]::Pow($px - ($c[0] + $c[2]) / 2, 2) + [math]::Pow($py - ($c[1] + $c[3]) / 2, 2)))
        }
        $filas += [pscustomobject]@{ tipo = 'senalar'; q = $p.q; ok = $ok; px = $d; dijo = $r.texto; ms = $r.ms }
    }
}
Matar

$leer = @($filas | Where-Object tipo -eq 'leer')
$sen  = @($filas | Where-Object tipo -eq 'senalar')
$dist = @($sen | Where-Object { $null -ne $_.px } | ForEach-Object px)
$res = [ordered]@{
    nombre      = $Nombre
    modelo      = Split-Path $Modelo -Leaf
    mmproj      = Split-Path $Mmproj -Leaf
    extra       = ($Extra -join ' ')
    leer        = "{0}/{1}" -f @($leer | Where-Object ok).Count, $leer.Count
    senalar     = "{0}/{1}" -f @($sen | Where-Object ok).Count, $sen.Count
    px_mediana  = if ($dist.Count) { ($dist | Sort-Object)[[int]($dist.Count / 2)] } else { $null }
    sin_punto   = @($sen | Where-Object { $null -eq $_.px }).Count
    ms_medio    = [math]::Round(($filas | Measure-Object ms -Average).Average)
    filas       = $filas
}
$f = "$Raiz\banco-vision.json"
$todas = @(if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json }) + [pscustomobject]$res
$todas | ConvertTo-Json -Depth 6 | Set-Content $f -Encoding utf8
[pscustomobject]$res
