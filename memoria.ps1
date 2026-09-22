# Memorias temporales: se cargan cuando hacen falta y se descargan despues.
#
# POR QUE EXISTE, medido y no supuesto. El modelo de `ojo` (Qwen3-VL-8B) falla
# cuando en el contexto hay OTRO valor asignado a la misma clave por la que se
# pregunta: 0/5 en tres casos distintos. Sin valor rival acierta siempre,
# incluso con 15.993 tokens -- no es longitud, no es posicion, y entiende el
# matiz de la pregunta perfectamente (5/5 pidiendole el valor rival).
#
# El diagnostico completo esta en MEDICIONES.md. De el salen DOS reglas de
# diseno que este archivo respeta:
#
#   1. Curar eligiendo ARCHIVOS no basta. Se midio: quitar presets.ini arregla
#      la pregunta de cache-ram (5/5) y NO arregla la de n-cpu-moe (0/5),
#      porque ese valor rival tambien esta en MEDICIONES.md. Por eso las
#      memorias son notas cortas escritas a mano, no referencias a archivos.
#
#   2. EL MODELO NO ELIGE. Elegir entre candidatos parecidos es justo lo que
#      falla. La puntuacion de aqui es determinista: cuenta terminos y no se
#      deja llevar por la frecuencia. Cuando duda, pregunta al usuario.
#
#   .\memoria.ps1 -Pregunta "cuanta RAM reserva llama-server?"
#   .\memoria.ps1 -Listar        los titulares y su presupuesto
#   .\memoria.ps1 -Calibrar      acierto de seleccion contra el conjunto anotado
#   .\memoria.ps1 -Olvidar       vacia lo cargado
param(
    [string]$Pregunta,
    [switch]$Listar,
    [switch]$Calibrar,
    # Cargar con punto (`. .\memoria.ps1 -ComoModulo`) define las funciones y no
    # ejecuta nada. Existe porque lanzarlo como proceso hijo costaba 649 ms y
    # casi todo era arrancar pwsh: puntuar ocho titulares es aritmetica.
    #
    # Un interruptor explicito y no husmear $MyInvocation.InvocationName -eq '.',
    # que falla segun como se invoque.
    [switch]$ComoModulo,
    [switch]$Olvidar,
    # Carga esa memoria sin puntuar. Es la respuesta del usuario cuando el
    # selector dice 'preguntar', y la salida de emergencia cuando se equivoca.
    [string]$Forzar,
    [string]$Dir = "$PSScriptRoot\memorias",
    # Presupuesto de las memorias cargadas. El contexto es de 8.192 tokens y la
    # imagen se come ~550, asi que esto es lo que queda sin apretar.
    [int]$PresupuestoTokens = 1500
)

$ESTADO = Join-Path $Dir 'estado.json'

# Palabras que aparecen en cualquier pregunta y no dicen de que va. Sin esto,
# "que" y "de" puntuan a todas las memorias por igual y el umbral no separa.
$VACIAS = @(
    'que','cual','cuales','cuanto','cuanta','cuantos','cuantas','como','donde','cuando',
    'por','para','con','sin','del','las','los','una','uno','unos','unas','este','esta',
    'esto','eso','ese','esa','hay','tiene','tienen','esta','estan','ser','son','fue',
    'the','and','for','was','are','mi','tu','su','me','te','se','lo','la','el','de',
    'en','al','es','un','y','o','a','si','no','mas','muy','yo','nos','aqui','ahi'
)

# Quita tildes y enes: "cuanta" y "cuánta" tienen que puntuar igual, porque el
# usuario escribe de las dos formas y las claves de las notas tambien.
function Normalizar([string]$s) {
    if (-not $s) { return '' }
    $d = $s.ToLower().Normalize([Text.NormalizationForm]::FormD)
    $sb = [Text.StringBuilder]::new()
    foreach ($c in $d.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne 'NonSpacingMark') { [void]$sb.Append($c) }
    }
    $sb.ToString().Normalize([Text.NormalizationForm]::FormC)
}

function Terminos([string]$s) {
    $t = Normalizar $s
    $base = @($t -split '[^a-z0-9\-]+' | Where-Object { $_.Length -ge 3 -and $VACIAS -notcontains $_ })
    # Los compuestos con guion se indexan ENTEROS y TAMBIEN por partes. Sin
    # esto, "n-cpu-moe" en la pregunta no engancha con "cpu" ni "moe" en las
    # claves: la raiz de cinco letras lo deja en "n-cpu" y no coincide con nada.
    # Se cazo en -Calibrar, que para eso esta.
    $partes = @()
    foreach ($w in $base) {
        if ($w.Contains('-')) {
            $partes += @($w -split '-' | Where-Object { $_.Length -ge 3 -and $VACIAS -notcontains $_ })
        }
    }
    @($base + $partes)
}

# Raiz pobre: los cinco primeros caracteres. No es un lematizador, y no hace
# falta uno -- "modelo/modelos", "memoria/memorias" y "carga/cargar" comparten
# prefijo en espanol. Documentado como atajo consciente.
function Raiz([string]$w) { if ($w.Length -gt 5) { $w.Substring(0, 5) } else { $w } }

function Leer-Memorias([string]$dir) {
    $out = @()
    foreach ($f in Get-ChildItem $dir -Filter '*.md' -ErrorAction SilentlyContinue) {
        $txt = Get-Content $f.FullName -Raw
        $m = [regex]::Match($txt, '(?s)^---\r?\n(.*?)\r?\n---\r?\n(.*)$')
        if (-not $m.Success) { Write-Warning "sin frontmatter: $($f.Name)"; continue }
        $fm = $m.Groups[1].Value; $cuerpo = $m.Groups[2].Value.Trim()
        $tit = [regex]::Match($fm, '(?m)^titular:\s*(.+)$').Groups[1].Value.Trim()
        $cla = [regex]::Match($fm, '(?m)^claves:\s*(.+)$').Groups[1].Value.Trim()
        if (-not $tit) { Write-Warning "sin titular: $($f.Name)"; continue }
        $out += [pscustomobject]@{
            nombre  = $f.BaseName
            titular = $tit
            claves  = $cla
            cuerpo  = $cuerpo
            tokens  = [int]($cuerpo.Length / 4)
        }
    }
    $out
}

# Puntuacion determinista. Las `claves` pesan mas que el `titular` porque estan
# escritas a proposito para que enganchen; el titular esta escrito para leerse.
# Se divide por el numero de terminos de la pregunta para que una pregunta larga
# no puntue mas alto que una corta solo por ser larga.
function Puntuar($memorias, [string]$pregunta) {
    $pt = @(Terminos $pregunta | ForEach-Object { Raiz $_ } | Select-Object -Unique)
    if (-not $pt.Count) { return @() }
    $res = foreach ($m in $memorias) {
        $tt = @(Terminos $m.titular | ForEach-Object { Raiz $_ })
        $ct = @(Terminos $m.claves  | ForEach-Object { Raiz $_ })
        $p = 0.0
        foreach ($w in $pt) {
            if ($ct -contains $w) { $p += 1.5 }
            elseif ($tt -contains $w) { $p += 1.0 }
        }
        [pscustomobject]@{ memoria = $m; puntos = [math]::Round($p / $pt.Count, 3) }
    }
    @($res | Sort-Object puntos -Descending)
}

# Los dos umbrales. Salen de -Calibrar contra el conjunto anotado del final de
# este archivo, no de mi gusto: con UMBRAL mas bajo carga basura y con VENTAJA
# mas baja carga la memoria equivocada en vez de preguntar.
$UMBRAL  = 0.30   # por debajo de esto, no hay nada que se parezca
$VENTAJA = 1.60   # la mejor tiene que sacarle esto a la segunda para ir sola

function Elegir($memorias, [string]$pregunta) {
    $p = Puntuar $memorias $pregunta
    if (-not $p.Count -or $p[0].puntos -lt $UMBRAL) {
        return @{ accion = 'nada'; puntuacion = $p }
    }
    $segunda = if ($p.Count -gt 1) { $p[1].puntos } else { 0 }
    if ($segunda -eq 0 -or ($p[0].puntos / $segunda) -ge $VENTAJA) {
        return @{ accion = 'cargar'; elegida = $p[0].memoria; puntuacion = $p }
    }
    # Empate tecnico. Aqui NO se adivina y tampoco se pregunta: se cargan las
    # dos.
    #
    # Preguntar era el diseno original y no tenia donde contestarse -- el
    # overlay es WS_EX_TRANSPARENT | NOACTIVATE y no recibe ni clics ni teclas,
    # y con el atajo de la Fase C no habra terminal. Cargar las dos disuelve el
    # problema en vez de resolverlo: las notas son de 123-195 tokens y el
    # presupuesto es de 1.500, asi que caben nueve.
    #
    # Y no reintroduce el fallo del modelo: esta medido que dos valores rivales
    # en un texto corto se distinguen bien (5/5 con 256 tokens). Lo que rompe al
    # modelo es un valor rival repetido en un documento grande.
    @{ accion = 'cargar-varias'; elegidas = @($p | Select-Object -First 2 | ForEach-Object { $_.memoria }); puntuacion = $p }
}

function Leer-Estado {
    if (Test-Path $ESTADO) { try { return Get-Content $ESTADO -Raw | ConvertFrom-Json } catch { } }
    [pscustomobject]@{ cargadas = @() }
}

function Guardar-Estado($e) { $e | ConvertTo-Json -Depth 6 | Set-Content $ESTADO -Encoding utf8 }

# Descarga la mas vieja hasta caber en el presupuesto. Es lo unico que hace
# falta: con notas de ~150 tokens, el presupuesto da para nueve o diez.
function Descargar($estado, $memorias, [int]$presupuesto) {
    $vivas = @($estado.cargadas)
    while ($vivas.Count) {
        $suma = 0
        foreach ($n in $vivas) {
            $m = $memorias | Where-Object { $_.nombre -eq $n } | Select-Object -First 1
            if ($m) { $suma += $m.tokens }
        }
        if ($suma -le $presupuesto) { break }
        $vivas = @($vivas | Select-Object -Skip 1)   # la mas vieja primero
    }
    $vivas
}

# El bloque que se le pasa al modelo: SIEMPRE los titulares (son ~20 lineas y
# sirven para que sepa que mas podria pedir) y solo el cuerpo de lo cargado.
function Componer($memorias, $cargadas) {
    $t = "MEMORIAS DISPONIBLES (solo los titulares):`n"
    foreach ($m in $memorias) { $t += "- $($m.nombre): $($m.titular)`n" }
    $vivas = @($memorias | Where-Object { $cargadas -contains $_.nombre })
    if ($vivas.Count) {
        $t += "`nMEMORIAS CARGADAS:`n"
        foreach ($m in $vivas) { $t += "`n### $($m.titular)`n$($m.cuerpo)`n" }
    }
    $t
}

# --- conjunto anotado para -Calibrar --------------------------------------
# Que memoria DEBERIA cargar cada pregunta. Sin esto, los dos umbrales serian
# una opinion. Un selector que se equivoca es peor que no tener memoria.
$ANOTADO = @(
    @{ q = 'cuanta RAM reserva llama-server por defecto para la cache?'; esp = 'llama-cache-ram' }
    @{ q = 'por que el modelo de vision cabe entero en la VRAM?';        esp = 'modelo-vision' }
    @{ q = 'como se sacan las coordenadas exactas de un boton?';         esp = 'uia-precision' }
    @{ q = 'por que la IA no ve sus propias flechas en la captura?';     esp = 'overlay-captura' }
    @{ q = 'en que disco estan los modelos y por que?';                  esp = 'discos-modelos' }
    @{ q = 'que hace n-cpu-moe y que valor usamos?';                     esp = 'n-cpu-moe' }
    @{ q = 'cuanto tarda whisper en transcribir?';                       esp = 'voz' }
    @{ q = 'como se le mandan ordenes a DaVinci Resolve?';               esp = 'davinci-puente' }
    @{ q = 'que tiempo hace manana en Lima?';                            esp = $null }
    @{ q = 'escribeme un poema sobre gatos';                             esp = $null }
    @{ q = 'por que el overlay no aparece en la grabacion de shadowplay?'; esp = 'overlay-captura' }
    @{ q = 'que ruta tiene el gguf del modelo de vision?';               esp = 'modelo-vision' }
    @{ q = 'por que se cuelga Resolve al leer un nodo?';                 esp = 'davinci-puente' }
    @{ q = 'que atajo se usa para hablarle?';                            esp = 'voz' }
)

# ---------------------------------------------------------------------------

# Cargado con punto: las funciones ya estan definidas y aqui se acaba.
if ($ComoModulo) { return }

$mem = Leer-Memorias $Dir

if ($Olvidar) {
    Guardar-Estado ([pscustomobject]@{ cargadas = @() })
    Write-Host 'memorias descargadas.'
    return
}

if ($Listar) {
    $e = Leer-Estado
    foreach ($m in $mem) {
        $marca = if ($e.cargadas -contains $m.nombre) { '[cargada]' } else { '         ' }
        "{0} {1,-18} {2,4} tok  {3}" -f $marca, $m.nombre, $m.tokens, $m.titular
    }
    "`ntotal {0} memorias, {1} tokens si se cargaran todas (presupuesto {2})" -f $mem.Count, ($mem | Measure-Object tokens -Sum).Sum, $PresupuestoTokens
    return
}

if ($Calibrar) {
    $bien = 0; $mal = @()
    foreach ($c in $ANOTADO) {
        $d = Elegir $mem $c.q
        # Lo que de verdad acaba en el contexto. Antes de cargar-varias, un
        # empate no contaba ni como acierto ni como fallo; ahora la memoria
        # buena SI entra, asi que es un acierto y hay que contarlo. Si no se
        # cambia esto, el 14/14 mide un comportamiento que el codigo ya no tiene.
        $cargadas = switch ($d.accion) {
            'cargar'        { @($d.elegida.nombre) }
            'cargar-varias' { @($d.elegidas.nombre) }
            default         { @() }
        }
        $ok = if ($null -eq $c.esp) { $cargadas.Count -eq 0 } else { $cargadas -contains $c.esp }
        if ($ok) { $bien++ }
        else { $mal += "{0,-52} -> {1} (esperado {2})" -f $c.q, $(if ($cargadas) { $cargadas -join '+' } else { $d.accion }), $(if ($c.esp) { $c.esp } else { 'nada' }) }
        $p1 = if ($d.puntuacion.Count) { $d.puntuacion[0].puntos } else { 0 }
        $p2 = if ($d.puntuacion.Count -gt 1) { $d.puntuacion[1].puntos } else { 0 }
        # Cargar dos cuando basta una no es gratis: son ~150 fichas de mas. Se
        # marca aparte para poder ver si el umbral de ventaja esta mal puesto.
        $nota = if (-not $ok) { 'MAL' } elseif ($cargadas.Count -gt 1) { 'ok, pero cargo dos' } else { 'ok' }
        "{0,-14} {1,-52} 1a {2,-6} 2a {3,-6} {4}" -f $d.accion, $c.q, $p1, $p2, $nota
    }
    "`nacierto de seleccion: {0}/{1}" -f $bien, $ANOTADO.Count
    if ($mal) { "`nfallos:"; $mal | ForEach-Object { "  $_" } }
    return
}

if (-not $Pregunta -and -not $Forzar) { Write-Host 'falta -Pregunta, o usa -Listar / -Calibrar.'; return }

$d = if ($Forzar) {
    $f = $mem | Where-Object { $_.nombre -eq $Forzar } | Select-Object -First 1
    if (-not $f) { throw "no hay ninguna memoria llamada '$Forzar'. Hay: $(($mem.nombre) -join ', ')" }
    @{ accion = 'cargar'; elegida = $f; puntuacion = @([pscustomobject]@{ memoria = $f; puntos = 'forzada' }) }
} else { Elegir $mem $Pregunta }
$e = Leer-Estado
switch ($d.accion) {
    'cargar' {
        $nuevas = @($e.cargadas | Where-Object { $_ -ne $d.elegida.nombre }) + $d.elegida.nombre
        $e.cargadas = Descargar ([pscustomobject]@{ cargadas = $nuevas }) $mem $PresupuestoTokens
        Guardar-Estado $e
        Write-Host "cargada: $($d.elegida.nombre) ($($d.puntuacion[0].puntos))"
    }
    'cargar-varias' {
        $nuevas = @($e.cargadas | Where-Object { $d.elegidas.nombre -notcontains $_ }) + @($d.elegidas.nombre)
        $e.cargadas = Descargar ([pscustomobject]@{ cargadas = $nuevas }) $mem $PresupuestoTokens
        Guardar-Estado $e
        Write-Host "dudaba, cargadas las dos: $($d.elegidas.nombre -join ' + ')"
    }
    'nada'      { Write-Host 'ninguna memoria se parece lo suficiente' }
}
Componer $mem $e.cargadas
