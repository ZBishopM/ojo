"""El oido de Ojo: graba mientras se mantiene el atajo y devuelve el texto.

POR QUE ES UN PROCESO RESIDENTE Y NO UN SCRIPT QUE SE LANZA CADA VEZ:
cargar el modelo cuesta 3,5 s medidos. El presupuesto entero hasta la primera
palabra hablada es de 1,3 s, asi que pagar la carga en cada pregunta es
imposible. Esto se queda vivo con el modelo caliente y transcribe en 234 ms.

QUE MOTOR Y POR QUE, medido en banco-stt.py sobre las mismas ocho frases:

    parakeet       234 ms de mediana   RTF 0,081
    whisper-base   885 ms              RTF 0,297

Los dos aciertan 8/8 con audio limpio, asi que decide la velocidad. Y de paso
desmiente el presupuesto heredado de voicebox: aquellos "300 ms de Whisper" no
se cumplen aqui ni de lejos con whisper-base.

Los dos corren en CPU, que no es una concesion sino un requisito: la VRAM esta
entera en el modelo de vision (11,4 de 12,28 GB) y no cabe nada mas.

    python escuchar.py                  arranca el demonio en el puerto 17494
    python escuchar.py --dispositivos   lista los microfonos y sale
    python escuchar.py --probar 3       graba 3 s y transcribe, para probar

Protocolo, pensado para que AutoHotkey lo pueda llamar con una linea:

    GET /salud      {"ok": true, "grabando": false, "dispositivo": "..."}
    GET /empezar    empieza a grabar (al PULSAR el atajo)
    GET /parar      para, transcribe y devuelve {"texto": "...", "ms": 234}
    GET /cancelar   tira lo grabado sin transcribir (Esc)
"""
import argparse
import ctypes
import json
import os
import queue
import sys
import threading
import time
from ctypes import wintypes
from http.server import BaseHTTPRequestHandler, HTTPServer

os.environ.setdefault("HF_HOME", r"F:\ai\hf")


# ===========================================================================
# EL MUTEX SE TOMA AQUI, ANTES DE IMPORTAR NADA PESADO.
#
# Estaba dentro de main(), o sea DESPUES de `import numpy` y
# `import sounddevice`, que tardan lo suyo. Esa ventana se veia en el arranque
# del equipo: el supervisor lanzaba el oido, miraba el mutex en su siguiente
# vuelta, aun no existia, y lanzaba un segundo. El duplicado se suicidaba solo
# --para eso esta el mutex-- pero era un proceso de mas en cada encendido.
#
# Medido el 2026-09-21: `[ojo-oido] started` a las 10:27:22 y otra vez a las
# 10:27:52, y despues nada en 18 minutos. Carrera, no bucle.
#
# Subirlo aqui cierra la ventana: el mutex existe en los primeros milisegundos
# del proceso, mucho antes de que el supervisor vuelva a mirar.
# ===========================================================================
_MUTEX = None


def tomar_mutex(nombre: str = r"Global\ojo-oido") -> bool:
    """True si somos la primera instancia. El handle se guarda para que viva."""
    global _MUTEX
    k32 = ctypes.windll.kernel32
    k32.CreateMutexW.restype = wintypes.HANDLE
    _MUTEX = k32.CreateMutexW(None, True, nombre)
    # 183 = ERROR_ALREADY_EXISTS. El handle vuelve valido igualmente, asi que
    # hay que mirar el codigo de error y no el handle.
    return k32.GetLastError() != 183


# `--probar` y `--dispositivos` son de usar y tirar: no deben chocar con el
# demonio que este sirviendo, asi que no piden el mutex.
_SUELTO = any(a in sys.argv for a in ("--probar", "--dispositivos", "-h", "--help"))
if not _SUELTO and not tomar_mutex():
    print(r"ya hay un oido corriendo (mutex Global\ojo-oido). Salgo.")
    raise SystemExit(0)

import numpy as np  # noqa: E402
import sounddevice as sd  # noqa: E402

MODELO = "nemo-parakeet-tdt-0.6b-v3"
# int8 por defecto, y medido: misma velocidad (235 contra 234 ms), las mismas
# ocho frases exactas, y el encoder pasa de 2,3 GB de pesos a una fraccion.
# Importa porque este proceso vive RESIDENTE al lado del modelo de vision.
CUANT = "int8"
FRECUENCIA = 16000  # lo que el modelo espera; remuestrear despues costaria mas
PUERTO = 17494      # voicebox usa 17493; este va al lado
MAX_SEGUNDOS = 30   # un atajo atascado no debe comerse la RAM

# NUNCA los AirPods. Cuando Windows los usa como entrada, el perfil manos
# libres hunde la calidad de TODA la salida de audio, y ya paso: "la calidad de
# audio empeoro un monton". Ademas declaran Formats = 0 en WASAPI y eso cuelga
# a DaVinci. Si son el dispositivo por defecto, esto se niega y lo dice.
PROHIBIDOS = ("airpod", "hands-free", "manos libres", "headset earphone")


# Por que MUTEX y no nombre de proceso, que es lo que el supervisor hace por
# defecto: este es un `python.exe` y el backend de voicebox tambien. Veria uno
# vivo y daria por bueno el otro. `dwindle` ya resuelve lo mismo asi.
#
# `Global\` y no `Local\`: es lo que usa el resto del rice, y esta comprobado
# que se puede crear sin ser administrador en esta maquina.
#
# La funcion esta arriba del todo, antes de los imports pesados. Ver el comento
# de alli.


def elegir_dispositivo(preferido: str | None) -> tuple[int | None, str]:
    disps = sd.query_devices()
    entradas = [(i, d) for i, d in enumerate(disps) if d["max_input_channels"] > 0]
    if preferido:
        for i, d in entradas:
            if preferido.lower() in d["name"].lower():
                return i, d["name"]
        raise SystemExit(f"no hay ningun microfono que contenga '{preferido}'")

    por_defecto = sd.query_devices(kind="input")
    nombre = por_defecto["name"]
    if any(p in nombre.lower() for p in PROHIBIDOS):
        # Se niega en vez de elegir otro por su cuenta: cambiar el microfono a
        # espaldas del usuario es peor que parar y decirlo.
        otros = [d["name"] for _, d in entradas
                 if not any(p in d["name"].lower() for p in PROHIBIDOS)]
        raise SystemExit(
            f"el microfono por defecto es '{nombre}' y esos estan vetados en este equipo:\n"
            f"  hunden la calidad de todo el audio y cuelgan DaVinci.\n"
            f"  Cambialo en Windows, o arranca con --dispositivo <nombre>.\n"
            f"  Hay: {', '.join(otros) or '(ninguno mas)'}")
    return None, nombre


class Oido:
    def __init__(self, dispositivo, nombre):
        self.dispositivo = dispositivo
        self.nombre = nombre
        self.trozos: queue.Queue = queue.Queue()
        self.stream = None
        self.t0 = 0.0
        self.lock = threading.Lock()
        print(f"cargando {MODELO} ({CUANT or 'fp32'})...", flush=True)
        t = time.perf_counter()
        import onnx_asr
        self.modelo = onnx_asr.load_model(MODELO, quantization=CUANT) if CUANT else onnx_asr.load_model(MODELO)
        # Calentamiento: la primera inferencia de onnxruntime paga la
        # construccion del grafo. Sin esto, la PRIMERA pregunta del dia seria
        # la lenta, que es justo la que se recuerda.
        self.modelo.recognize(np.zeros(FRECUENCIA, dtype=np.float32), sample_rate=FRECUENCIA)
        print(f"listo en {time.perf_counter()-t:.1f} s   microfono: {nombre}", flush=True)

    @property
    def grabando(self) -> bool:
        return self.stream is not None

    def empezar(self):
        with self.lock:
            if self.stream:
                return
            while not self.trozos.empty():
                self.trozos.get_nowait()

            def entra(datos, cuadros, tiempo, estado):  # noqa: ARG001
                # `estado` trae xruns. Se anotan y no se aborta: perder unos
                # milisegundos es mejor que perder la frase entera.
                if estado:
                    print(f"  aviso de audio: {estado}", file=sys.stderr)
                self.trozos.put(datos.copy())

            self.stream = sd.InputStream(
                samplerate=FRECUENCIA, channels=1, dtype="float32",
                device=self.dispositivo, callback=entra, blocksize=0)
            self.stream.start()
            self.t0 = time.perf_counter()

    def _recoger(self) -> np.ndarray | None:
        with self.lock:
            if not self.stream:
                return None
            self.stream.stop()
            self.stream.close()
            self.stream = None
        partes = []
        while not self.trozos.empty():
            partes.append(self.trozos.get_nowait())
        if not partes:
            return None
        return np.concatenate(partes, axis=0).flatten()

    def cancelar(self) -> bool:
        return self._recoger() is not None

    def parar(self) -> dict:
        audio = self._recoger()
        if audio is None or len(audio) < FRECUENCIA // 10:
            # Menos de 100 ms es un roce de tecla, no una frase.
            return {"texto": "", "ms": 0, "segundos": 0.0, "motivo": "demasiado corto"}
        seg = len(audio) / FRECUENCIA
        if seg > MAX_SEGUNDOS:
            audio = audio[-MAX_SEGUNDOS * FRECUENCIA:]
            seg = MAX_SEGUNDOS
        t = time.perf_counter()
        texto = self.modelo.recognize(audio, sample_rate=FRECUENCIA) or ""
        return {"texto": texto.strip(), "ms": round((time.perf_counter() - t) * 1000),
                "segundos": round(seg, 2)}


def servir(oido: Oido, puerto: int):
    class Mango(BaseHTTPRequestHandler):
        def responder(self, obj, codigo=200):
            cuerpo = json.dumps(obj, ensure_ascii=False).encode("utf-8")
            self.send_response(codigo)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(cuerpo)))
            self.end_headers()
            self.wfile.write(cuerpo)

        def do_GET(self):  # noqa: N802
            ruta = self.path.split("?")[0].rstrip("/")
            if ruta in ("", "/salud"):
                self.responder({"ok": True, "grabando": oido.grabando,
                                "dispositivo": oido.nombre, "motor": f"{MODELO} {CUANT or 'fp32'}"})
            elif ruta == "/empezar":
                oido.empezar()
                self.responder({"ok": True, "grabando": True})
            elif ruta == "/parar":
                self.responder(oido.parar())
            elif ruta == "/cancelar":
                self.responder({"ok": oido.cancelar()})
            else:
                self.responder({"error": "no existe"}, 404)

        def log_message(self, *a):  # silencio; el log util lo imprime Oido
            pass

    s = HTTPServer(("127.0.0.1", puerto), Mango)
    print(f"escuchando en http://127.0.0.1:{puerto}", flush=True)
    s.serve_forever()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--puerto", type=int, default=PUERTO)
    ap.add_argument("--dispositivo", help="parte del nombre del microfono")
    ap.add_argument("--dispositivos", action="store_true")
    ap.add_argument("--probar", type=float, metavar="SEGUNDOS",
                    help="graba tantos segundos y transcribe, sin servidor")
    a = ap.parse_args()

    if a.dispositivos:
        for i, d in enumerate(sd.query_devices()):
            if d["max_input_channels"] > 0:
                veto = " [VETADO]" if any(p in d["name"].lower() for p in PROHIBIDOS) else ""
                print(f"{i:3}  {d['name']}{veto}")
        print(f"\npor defecto: {sd.query_devices(kind='input')['name']}")
        return 0

    # El mutex ya se tomo arriba del todo, antes de los imports pesados, para
    # que el supervisor lo vea en el primer tick. Aqui no queda nada que hacer.

    disp, nombre = elegir_dispositivo(a.dispositivo)
    oido = Oido(disp, nombre)

    if a.probar:
        print(f"habla ahora, {a.probar:g} s...", flush=True)
        oido.empezar()
        time.sleep(a.probar)
        r = oido.parar()
        print(json.dumps(r, ensure_ascii=False, indent=2))
        return 0

    servir(oido, a.puerto)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
