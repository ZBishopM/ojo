<#
Monta y desmonta una partida de League FALSA para probar Ojo sin jugar.

    .\partida.ps1 -Empezar     certificado, API falsa en el 2999 y el proceso
                               "League of Legends" (una copia inerte de ping.exe)
    .\partida.ps1 -Terminar    lo quita todo

Con la partida puesta, ojo.ps1 y el supervisor se comportan como con el juego:
la puerta ve el proceso, el sondeo ve el puerto, y la API devuelve datos.

El proceso falso no es el juego y no toca nada del juego: Vanguard vigila el
ejecutable real de Riot, no nombres de proceso.
#>
param([switch]$Empezar, [switch]$Terminar, [string]$Datos)
$ErrorActionPreference = 'Stop'
$aqui = $PSScriptRoot
$tmp = Join-Path $env:TEMP 'ojo-prueba-lol'
New-Item -ItemType Directory -Force $tmp | Out-Null

function Parar {
    Get-Process 'League of Legends' -EA SilentlyContinue | Where-Object { $_.Path -like "$tmp*" } |
        Stop-Process -Force -EA SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name='python.exe'" -EA SilentlyContinue |
        Where-Object { $_.CommandLine -match 'prueba-lol\\servidor\.py' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }
}

if ($Terminar) { Parar; 'partida falsa terminada'; return }
if (-not $Empezar) { throw 'usa -Empezar o -Terminar' }
Parar

# Certificado autofirmado, como el del cliente del juego.
$cert = Join-Path $tmp 'cert.pem'; $clave = Join-Path $tmp 'clave.pem'
if (-not (Test-Path $cert)) {
    & 'C:\Program Files\Git\usr\bin\openssl.exe' req -x509 -newkey rsa:2048 -nodes -days 30 `
        -subj '/CN=127.0.0.1' -keyout $clave -out $cert 2>$null
}

# La partida inventada de lol.ps1, en la forma cruda de la API.
if (-not $Datos) {
    . (Join-Path (Split-Path $aqui) 'lol.ps1')
    $Datos = Join-Path $tmp 'allgamedata.json'
    [IO.File]::WriteAllText($Datos, ((Partida-Inventada 'riotid' 3500 2) | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}

$py = Join-Path (Split-Path $aqui) 'stt\.venv\Scripts\python.exe'
Start-Process $py -ArgumentList (Join-Path $aqui 'servidor.py'), $cert, $clave, $Datos -WindowStyle Hidden

# El "juego": ping.exe con otro nombre. Get-Process toma el nombre del
# ejecutable, que es lo unico que miran ojo.ps1 y el supervisor.
$exe = Join-Path $tmp 'League of Legends.exe'
Copy-Item "$env:SystemRoot\System32\PING.EXE" $exe -Force
Start-Process $exe -ArgumentList '-t', '127.0.0.1' -WindowStyle Hidden

for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 200
    $ok = & curl.exe -sk -o NUL -w '%{http_code}' https://127.0.0.1:2999/liveclientdata/allgamedata 2>$null
    if ($ok -eq '200') { break }
}
"partida falsa en marcha: proceso 'League of Legends' vivo=$([bool](Get-Process 'League of Legends' -EA SilentlyContinue)), API=$ok"
