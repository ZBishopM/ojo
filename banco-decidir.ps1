#Requires -Version 5.1
<#
Reglas (Decidir-Con-Reglas, en ojo.ps1) contra decisiones tipadas del modelo
local (decidir.ps1, "a lo Jev"), sobre preguntas etiquetadas A MANO.

Criterio escrito ANTES de medir: el modelo sustituye a las reglas solo si
acierta mas Y cuesta menos de 200 ms por pregunta. Si no, se quedan las reglas.

Etiquetas (1 = true) en este orden: lectura sitio web personal aumento
workspaces metricas. Las definiciones son las del prompt de decidir.ps1.

    .\banco-decidir.ps1
#>
$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $MyInvocation.MyCommand.Path

# Las reglas, sacadas del propio ojo.ps1 (se prueba lo que corre).
. "$raiz\memoria.ps1" -ComoModulo
$ast = [Management.Automation.Language.Parser]::ParseFile("$raiz\ojo.ps1", [ref]$null, [ref]$null)
$ast.FindAll({ ($args[0] -is [Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -in 'Pregunta-De-Lectura', 'Pregunta-De-Sitio', 'Decidir-Con-Reglas') -or
               ($args[0] -is [Management.Automation.Language.AssignmentStatementAst] -and $args[0].Left.Extent.Text -eq '$MARCAS_SITIO') }, $true) |
    ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }
. "$raiz\decidir.ps1"

$CASOS = @(
    ,@('¿Qué hora es?',                                          '0000000')
    ,@('¿Qué día es hoy?',                                       '0000000')
    ,@('¿A cuánto está el dólar hoy en Perú?',                   '0010000')
    ,@('¿Quién ganó el último mundial de League of Legends?',    '0010000')
    ,@('¿Qué hora marca el reloj de la barra de arriba?',        '1000000')
    ,@('¿Cuánta VRAM marca la barra de arriba?',                 '1000001')
    ,@('¿Qué dice el último correo que me llegó?',               '1001000')
    ,@('¿Qué tengo abierto en mis workspaces?',                  '0001010')
    ,@('¿Dónde está el botón de guardar?',                       '0100000')
    ,@('Señálame dónde escribo un mensaje',                      '0100000')
    ,@('¿Cuál de estos tres aumentos elijo?',                    '0000100')
    ,@('¿Qué aumento me conviene de estos?',                     '0000100')
    ,@('¿Qué hace el aumento Locomotora?',                       '0000000')
    ,@('¿Cuánta RAM estoy usando?',                              '0001001')
    ,@('¿Qué temperatura tiene la GPU?',                         '0001001')
    ,@('¿Qué clima hace hoy en Lima?',                           '0010000')
    ,@('¿Cuál es la última versión de Windows 11?',              '0010000')
    ,@('¿Qué significa el error que sale en pantalla?',          '1001000')
    ,@('¿Cómo se llama la canción que suena en Spotify?',        '1001000')
    ,@('¿Qué ventanas tengo abiertas?',                          '0001010')
    ,@('¿Qué hay en mi otro monitor?',                           '0001010')
    ,@('¿Cuál es la capital de Australia?',                      '0000000')
    ,@('¿Quién escribió Cien años de soledad?',                  '0000000')
    ,@('¿Cuánto cuesta una RTX 5090 ahora?',                     '0010000')
    ,@('¿Hay noticias de League of Legends esta semana?',        '0010000')
    ,@('¿Qué parche de LoL es el actual?',                       '0010000')
    ,@('Léeme lo que dice este mensaje de Discord',              '1001000')
    ,@('¿Qué número tiene el ticket abierto?',                   '1001000')
    ,@('¿Dónde está la configuración de esta app?',              '0100000')
    ,@('¿En qué parte de la pantalla está el chat?',             '0100000')
    ,@('¿Qué tengo en el escritorio?',                           '0001010')
    ,@('¿Cuánto consume mi PC ahora mismo?',                     '0001001')
    ,@('¿Qué me recomiendas hacer ahora?',                       '0000000')
    ,@('¿Cómo está mi CPU?',                                     '0001001')
    ,@('¿Qué pone en el título de esta ventana?',                '1001000')
    ,@('¿Cuántos mensajes sin leer tengo?',                      '1001000')
    ,@('¿Quién es el presidente actual de Perú?',                '0010000')
    ,@('¿Qué resultado tuvo el último partido de Alianza Lima?', '0010000')
    ,@('¿Cuál es el mejor aumento para Kayn en general?',        '0010000')
    ,@('¿Qué ítem me compro?',                                   '0000000')
    ,@('Muéstrame dónde está el botón de enviar',                '0100000')
    ,@('¿Qué dice la barra de arriba sobre la memoria?',         '1000001')
    ,@('¿Cuánto es 15 por 23?',                                  '0000000')
    ,@('¿Qué versión de Python tengo instalada?',                '0001000')
    ,@('¿Cuándo sale el próximo parche de LoL?',                 '0010000')
    ,@('¿Me conviene este aumento o el otro?',                   '0000100')
    ,@('¿Qué hay en la pestaña de Firefox?',                     '1001000')
    ,@('¿Dónde dejé el archivo del proyecto?',                   '0001000')
    ,@('¿Qué está pasando en el mundo hoy?',                     '0010000')
)

$aciertosR = @{}; $aciertosM = @{}; foreach ($c in $DECIDIR_CAMPOS) { $aciertosR[$c] = 0; $aciertosM[$c] = 0 }
$mal = @()
$ms = @()
$null = Decidir-Con-Modelo 'calentar'   # la primera llamada paga el prompt de sistema
foreach ($caso in $CASOS) {
    $q = $caso[0]; $esp = $caso[1]
    $reg = Decidir-Con-Reglas $q
    $mod = Decidir-Con-Modelo $q
    $ms += $mod.ms
    for ($i = 0; $i -lt $DECIDIR_CAMPOS.Count; $i++) {
        $c = $DECIDIR_CAMPOS[$i]; $e = $esp[$i] -eq '1'
        if ([bool]$reg[$c] -eq $e) { $aciertosR[$c]++ } else { $mal += "REGLAS  $c=$([bool]$reg[$c]) (tocaba $e): $q" }
        if ($mod.valores[$c] -eq $e) { $aciertosM[$c]++ } else { $mal += "MODELO  $c=$($mod.valores[$c]) (tocaba $e, conf $($mod.confianza[$c])): $q" }
    }
}
$n = $CASOS.Count
$totR = ($aciertosR.Values | Measure-Object -Sum).Sum; $totM = ($aciertosM.Values | Measure-Object -Sum).Sum
"{0,-11} {1,8} {2,8}" -f 'decision', 'reglas', 'modelo'
foreach ($c in $DECIDIR_CAMPOS) { "{0,-11} {1,5}/{2} {3,5}/{2}" -f $c, $aciertosR[$c], $n, $aciertosM[$c] }
"{0,-11} {1,5}/{2} {3,5}/{2}" -f 'TOTAL', $totR, ($n * $DECIDIR_CAMPOS.Count), $totM
"modelo: {0} ms de mediana, {1} ms maximo (reglas: ~0)" -f ($ms | Sort-Object)[[int]($ms.Count / 2)], ($ms | Measure-Object -Maximum).Maximum
"`nFALLOS:"; $mal | ForEach-Object { "  $_" }
