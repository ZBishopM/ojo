#Requires AutoHotkey v2.0
#SingleInstance Force

; ------------------------------------------------------------
; Ojo: Ctrl+Win MANTENIDO para hablarle, como un walkie.
;
; Se habla mientras se mantiene y se suelta al acabar. Eso elimina el detector
; de fin de frase entero: el sistema sabe exactamente cuando empiezas y cuando
; acabas, sin adivinar silencios.
;
; POR QUE UN ARCHIVO APARTE y no dentro de wezterm-hotkey.ahk: ese script lleva
; el latido, el interruptor de la barra y los atajos que ya funcionan. Si esto
; se cuelga, que se cuelgue solo. Se lanza a mano mientras se prueba; cuando
; este asentado, va a la carpeta de Inicio como el otro.
;
; DOS CUIDADOS DE ESTA MAQUINA, los dos aprendidos a base de romperlos:
;
;   1. AltSnap vigila la tecla Windows (sus Hotkeys son 5B 5C) y lleva su
;      propia cuenta de si esta pulsada. Aqui NO se sintetiza ninguna
;      pulsacion de Win -- eso es lo que lo desincroniza y acaba comiendose la
;      barra espaciadora. Solo se leen eventos.
;
;   2. El orden de las teclas importa. Si se pulsa Win y luego Ctrl, el que
;      dispara es LWin; si se pulsa Ctrl y luego Win, es el otro. Por eso hay
;      DOS atajos que hacen lo mismo, y un cerrojo para que no cuenten dos
;      veces.
;
; Ctrl+Win esta libre: no hay ningun binding con ctrl+lwin en GlazeWM,
; comprobado, y wezterm-hotkey.ahk solo usa LWin a secas.
; ------------------------------------------------------------

; Mutex de instancia unica, ADEMAS de #SingleInstance Force.
;
; No es redundante: el supervisor del rice necesita poder preguntar "esto esta
; vivo?" desde fuera, y por nombre de proceso no puede -- este es un
; AutoHotkey64 y wezterm-hotkey tambien. Con el mutex la pregunta tiene
; respuesta exacta. Mismo patron que `dwindle`.
DllCall('CreateMutexW', 'Ptr', 0, 'Int', 1, 'Str', 'Global\ojo-hotkey', 'Ptr')

global OjoRaiz    := 'D:\2026-projects\ojo'
global OjoPuerto  := 17494
global OjoHablando := false

; Peticion al oido. Sincrona a proposito: es localhost y tarda milisegundos,
; y hacerla asincrona obligaria a llevar estado para algo que no lo necesita.
OjoPedir(ruta) {
    try {
        req := ComObject('WinHttp.WinHttpRequest.5.1')
        req.Open('GET', 'http://127.0.0.1:' . OjoPuerto . '/' . ruta, false)
        req.SetTimeouts(1000, 1000, 1000, 3000)
        req.Send()
        return req.ResponseText
    } catch as e {
        return ''
    }
}

; Avisar por la ISLA de la barra, que ya existe y la lee glaze-bar.
;
; Hace falta porque el overlay solo vive MIENTRAS se responde: lo lanza
; ojo.ps1 al soltar la tecla. Mientras hablas no hay nada en pantalla, y sin
; senal no sabes si te esta oyendo -- lo dijiste en la primera sesion.
;
; Se reutiliza el mismo archivo que usa rice-llm.ps1 en vez de inventar otro
; canal: un JSON de cuatro campos y la barra lo pinta.
OjoIsla(titulo, cuerpo, acento) {
    f := EnvGet('USERPROFILE') . '\.config\island.json'
    txt := '{"icon":"","title":"' . titulo . '","body":"' . cuerpo . '","accent":"' . acento . '"}'
    try FileDelete(f)
    try FileAppend(txt, f, 'UTF-8')
}

OjoEmpezar() {
    global OjoHablando
    if OjoHablando
        return                      ; el auto-repeat de la tecla no cuenta
    OjoHablando := true

    ; Grabar PRIMERO. Lo demas es adorno y no debe retrasar el microfono: si el
    ; overlay tarda 200 ms en abrir, esos 200 ms de voz se pierden.
    OjoPedir('empezar')

    ; La senal de "te escucho" va A LA ALTURA DE LOS SUBTITULOS, no en la barra.
    ; Es donde ya estan los ojos mientras hablas.
    ;
    ; `--escena` y no `--servir`: servir lee de stdin y se cierra al cerrarse la
    ; tuberia, asi que aparece y desaparece. Esta instancia la mata `ojo.ps1`
    ; al arrancar la suya.
    ; Se guarda el PID: QUIEN LO ABRE LO CIERRA.
    ;
    ; La primera version confiaba en que `ojo.ps1` lo matara al arrancar. Pero
    ; si la transcripcion sale vacia -- un roce de tecla, un "What" suelto --
    ; `hablar.ps1` sale ANTES de llamar a ojo.ps1, y el overlay se queda vivo
    ; pintando a pantalla completa a 60 fps. En la sesion del 2026-09-22 se
    ; acumularon varios y la latencia del modelo paso de 2,5 s a 222 s, con la
    ; GPU al 99% y 343 W. Es el peor fallo que he metido en este proyecto.
    global OjoPidOverlay := 0
    try {
        Run('"' . OjoRaiz . '\overlay\target\release\ojo-overlay.exe" --escena '
            . '"{""estado"":""escuchando"",""dice"":""te escucho...""}" --segundos 60'
            , , 'Hide', &pid)
        OjoPidOverlay := pid
    }

    ; La isla de la barra se queda igualmente: sirve cuando el overlay esta
    ; tapado por una ventana a pantalla completa.
    OjoIsla('Ojo', 'escuchando...', '#8fbf6f')
}

OjoParar() {
    global OjoHablando
    if !OjoHablando
        return
    OjoHablando := false

    ; Cerrar NUESTRO overlay de escucha antes de nada. `ojo.ps1` abrira el suyo
    ; enseguida con "Dejame ver...", asi que no queda hueco visual -- y si
    ; ojo.ps1 no llega a correr, aqui ya esta cerrado igualmente.
    global OjoPidOverlay
    if OjoPidOverlay {
        try ProcessClose(OjoPidOverlay)
        OjoPidOverlay := 0
    }
    OjoIsla('Ojo', 'pensando...', '#e0a35c')
    ; El /parar y todo lo que viene detras -- transcribir, capturar, preguntar
    ; al modelo -- se hace FUERA de aqui. Bloquear el bucle de mensajes de AHK
    ; mientras el modelo piensa dejaria el teclado sordo varios segundos.
    ;
    ; `powershell` (5.1) y no `pwsh` (7): hablar.ps1 ejecuta ojo.ps1 DENTRO de
    ; su propio proceso, y ojo.ps1 esta hecho para 5.1. Medido el 2026-09-22,
    ; de soltar a dibujo, mediana de 10: dos procesos 2.614 ms, uno en 7
    ; 2.312, uno en 5.1 2.091. 5.1 arranca en 165 ms; 7 en 289.
    Run('powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' . OjoRaiz . '\hablar.ps1"', , 'Hide')
}

; ------------------------------------------------------------
; UNA pulsacion = UN disparo, con KeyWait.
;
; La version anterior tenia un atajo para bajar y otro para subir. Mantener la
; tecla genera auto-repeat del teclado, y CADA repeticion disparaba el atajo:
; en la prueba del 2026-09-21 AutoHotkey aviso de "71 hotkeys en los ultimos
; 1422 ms" y pregunto si continuar. La frase se perdio y la grabacion se fue a
; los 30 segundos de tope.
;
; Con KeyWait el manejador se queda dentro hasta que sueltas, y como
; #MaxThreadsPerHotkey vale 1 por defecto, las repeticiones que llegan mientras
; tanto se descartan solas. Un disparo por pulsacion fisica.
;
; El limite se sube igualmente: las repeticiones descartadas siguen contando
; para el contador de AHK, y un aviso modal a media frase es peor que el ruido.
; En AHK v2 esto es una VARIABLE, no una directiva: `#MaxHotkeysPerInterval`
; era de la v1 y aqui da "This line does not contain a recognized action".
; El nombre correcto es el que aparece en su propia ayuda, `A_MaxHotkeysPerInterval`.
A_MaxHotkeysPerInterval := 200
A_HotkeyInterval := 2000

; Los dos ordenes de pulsacion -- Ctrl primero o Win primero disparan atajos
; distintos. `~` deja pasar la tecla para que GlazeWM y AltSnap sigan viendo lo
; que esperan.
~^LWin:: {
    OjoEmpezar()
    KeyWait 'LWin'          ; aqui se queda mientras hablas
    OjoParar()
}

~#LControl:: {
    OjoEmpezar()
    KeyWait 'LControl'
    OjoParar()
}

; Esc aborta sin transcribir, mientras se esta hablando.
#HotIf OjoHablando
Esc:: {
    global OjoHablando := false
    OjoPedir('cancelar')
}
#HotIf
