#Requires -Version 5.1
# La voz actual (SAPI, Sabina Desktop) con las frases de frases.txt: la linea
# base de banco_voz.py. Deja salida\sapi\<n>.wav y medida.json.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Speech
$out = Join-Path $PSScriptRoot 'salida\sapi'
New-Item -ItemType Directory -Force $out | Out-Null
$frases = @([IO.File]::ReadAllLines((Join-Path $PSScriptRoot 'frases.txt'), [Text.Encoding]::UTF8) | Where-Object { $_.Trim() })
$sw = [Diagnostics.Stopwatch]::StartNew()
$s = New-Object System.Speech.Synthesis.SpeechSynthesizer
$s.SelectVoice('Microsoft Sabina Desktop')
$carga = $sw.ElapsedMilliseconds
$filas = for ($i = 0; $i -lt $frases.Count; $i++) {
    $wav = Join-Path $out "$($i + 1).wav"
    $sw.Restart()
    $s.SetOutputToWaveFile($wav); $s.Speak($frases[$i]); $s.SetOutputToNull()
    $ms = $sw.ElapsedMilliseconds
    $dur = ((Get-Item $wav).Length - 44) / (22050 * 2)
    [ordered]@{ frase = $i + 1; total_ms = $ms; audio_s = [math]::Round($dur, 2) }
}
$r = [ordered]@{ motor = 'sapi-sabina'; carga_ms = $carga; frases = @($filas) }
[IO.File]::WriteAllText((Join-Path $out 'medida.json'), ($r | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
"sapi: carga $carga ms; " + (($filas | ForEach-Object { "$($_.total_ms) ms" }) -join ', ')
