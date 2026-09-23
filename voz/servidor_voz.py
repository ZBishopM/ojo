"""La voz de Ojo: Supertonic 3 (voz F2) residente, en la GPU.

POR QUE ESTA: gano la escucha a ciegas del 2026-09-23 entre las que empiezan a
sonar en menos de 400 ms (naturalidad 5, pronunciacion 5; ver MEDICIONES.md),
y en GPU empieza en ~300 ms. Residente porque cargarla cuesta ~1,5 s.

Habla FRASE A FRASE: la primera suena mientras se sintetiza la siguiente. El
texto pasa antes por texto_voz.para_decir (numeros en palabras, nombres en
ingles como se dicen).

Se CALLA sola cuando muere el proceso que pregunto: el atajo corta una
respuesta matando hablar.ps1 (Ctrl+Win otra vez, o Esc), y asi no hace falta
tocar el atajo. Se espera al proceso con su handle, no mirando cada tanto.

    GET  /salud     {"ok": true, "motor": "...", "gpu": true, "hablando": false}
    POST /decir     {"texto": "...", "pid": 1234} -> vuelve cuando SUENA la
                    primera frase: {"primera_ms": 290}
    GET  /esperar   vuelve cuando termina de hablar (tope 60 s)
    GET  /callar    corta ya

Puerto 8098 (el modelo esta en el 8099, el oido en el 17494).
"""
import ctypes
import json
import os
import queue
import re
import sys
import threading
import time
from ctypes import wintypes
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PUERTO = 8098
VOZ = "F2"
MODELO = Path(r"F:\ai\voz\supertonic-3")


# El mutex ANTES de los imports pesados, como el oido: asi el supervisor lo ve
# en su primer tick y no lanza un segundo servidor mientras este carga.
def tomar_mutex(nombre=r"Global\ojo-voz"):
    global _MUTEX
    k32 = ctypes.windll.kernel32
    k32.CreateMutexW.restype = wintypes.HANDLE
    _MUTEX = k32.CreateMutexW(None, True, nombre)
    return ctypes.GetLastError() != 183  # ERROR_ALREADY_EXISTS


if "--probar" not in sys.argv and not tomar_mutex():
    print(r"ya hay una voz corriendo (mutex Global\ojo-voz). Salgo.")
    raise SystemExit(0)

import numpy as np  # noqa: E402
import sounddevice as sd  # noqa: E402

sys.path.insert(0, str(Path(__file__).parent))
from texto_voz import para_decir  # noqa: E402


def cargar():
    """El motor, en GPU si se puede. En CPU la primera frase tarda ~1,5 s
    (medido): vale de reserva, no de uso normal."""
    import onnxruntime
    import supertonic.loader
    from supertonic import TTS
    gpu = "CUDAExecutionProvider" in onnxruntime.get_available_providers()
    if gpu:
        # CUDA y cuDNN vienen en paquetes de pip, fuera del PATH.
        onnxruntime.preload_dlls()
        supertonic.loader.DEFAULT_ONNX_PROVIDERS = ["CUDAExecutionProvider", "CPUExecutionProvider"]

        # Memoria justa: arena que crece solo lo pedido y cuDNN sin su
        # workspace maximo. Medido: 707 MiB contra 833 (y 959 tras un rato de
        # uso), a la misma velocidad. El SDK no deja pasar opciones de CUDA,
        # asi que se le da una sesion que las pone (subclase: el SDK comprueba
        # isinstance).
        class Sesion(onnxruntime.InferenceSession):
            def __init__(self, path, sess_options=None, providers=None, **kw):
                super().__init__(path, sess_options=sess_options, providers=supertonic.loader.DEFAULT_ONNX_PROVIDERS,
                                 provider_options=[{"arena_extend_strategy": "kSameAsRequested",
                                                    "cudnn_conv_algo_search": "HEURISTIC",
                                                    "cudnn_conv_use_max_workspace": "0"}, {}])
        supertonic.loader.ort.InferenceSession = Sesion
    t = TTS(model_dir=MODELO)
    estilo = t.get_voice_style(voice_name=VOZ)
    pasos = 8 if gpu else 4

    def sintetizar(texto):
        wav, _ = t.synthesize(texto, voice_style=estilo, lang="es", total_steps=pasos)
        return np.asarray(wav, dtype=np.float32).reshape(-1)
    sintetizar("Hola.")  # en caliente
    return sintetizar, t.sample_rate, gpu


def frases(texto):
    """Troceado por final de frase. La primera, corta: es la que se espera."""
    return [f for f in re.split(r"(?<=[.!?…;:])\s+", texto.strip()) if f]


class Voz:
    def __init__(self):
        self.sintetizar, self.sr, self.gpu = cargar()
        self.trozos = queue.Queue()
        self.actual = np.zeros(0, dtype=np.float32)
        self.turno = 0                  # cada /decir abre un turno; el viejo se descarta
        self.sonando = threading.Event()
        self.callado = threading.Event(); self.callado.set()
        self.lock = threading.Lock()
        # Un flujo SIEMPRE abierto: abrirlo en cada respuesta suma latencia.
        # En silencio escribe ceros.
        self.flujo = sd.OutputStream(samplerate=self.sr, channels=1, dtype="float32",
                                     blocksize=1024, callback=self._llenar)
        self.flujo.start()

    def _llenar(self, out, n, _t, _st):
        i = 0
        while i < n:
            if not len(self.actual):
                try:
                    turno, trozo = self.trozos.get_nowait()
                except queue.Empty:
                    break
                if turno != self.turno:
                    continue
                if trozo is None:            # fin del turno
                    self.callado.set()
                    continue
                self.actual = trozo
                self.sonando.set()
            k = min(n - i, len(self.actual))
            out[i:i + k, 0] = self.actual[:k]
            self.actual = self.actual[k:]
            i += k
        out[i:, 0] = 0

    def callar(self):
        with self.lock:
            self.turno += 1
            self.actual = np.zeros(0, dtype=np.float32)
            self.callado.set()

    def decir(self, texto, pid=None):
        with self.lock:
            self.turno += 1
            turno = self.turno
            self.actual = np.zeros(0, dtype=np.float32)
            self.sonando.clear(); self.callado.clear()
        t0 = time.perf_counter()
        partes = frases(para_decir(texto))
        primera = self.sintetizar(partes[0]) if partes else np.zeros(0, dtype=np.float32)
        self.trozos.put((turno, primera))
        primera_ms = round((time.perf_counter() - t0) * 1000)

        def resto():
            for p in partes[1:]:
                if turno != self.turno:
                    return
                self.trozos.put((turno, self.sintetizar(p)))
            self.trozos.put((turno, None))
        threading.Thread(target=resto, daemon=True).start()
        if pid:
            threading.Thread(target=self._vigilar, args=(int(pid), turno), daemon=True).start()
        self.sonando.wait(2)
        return primera_ms

    def _vigilar(self, pid, turno):
        """Cuando muere quien pregunto, se calla. Espera al HANDLE del
        proceso: sin sondeo."""
        k32 = ctypes.windll.kernel32
        k32.OpenProcess.restype = wintypes.HANDLE
        h = k32.OpenProcess(0x00100000, False, pid)  # SYNCHRONIZE
        if not h:
            return
        try:
            while not self.callado.is_set() and turno == self.turno:
                # 0 = el proceso termino; 258 = sigue (tope para mirar si ya
                # acabamos de hablar por nuestra cuenta).
                if k32.WaitForSingleObject(h, 1000) == 0:
                    if turno == self.turno:
                        self.callar()
                    return
        finally:
            k32.CloseHandle(h)


def servir(voz):
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
                self.responder({"ok": True, "motor": f"supertonic-3 {VOZ}", "gpu": voz.gpu,
                                "hablando": not voz.callado.is_set()})
            elif ruta == "/esperar":
                voz.callado.wait(60)
                self.responder({"ok": True})
            elif ruta == "/callar":
                voz.callar()
                self.responder({"ok": True})
            else:
                self.responder({"error": "ruta desconocida"}, 404)

        def do_POST(self):  # noqa: N802
            if self.path.rstrip("/") != "/decir":
                return self.responder({"error": "ruta desconocida"}, 404)
            n = int(self.headers.get("Content-Length", 0))
            d = json.loads(self.rfile.read(n).decode("utf-8"))
            self.responder({"ok": True, "primera_ms": voz.decir(d.get("texto", ""), d.get("pid"))})

        def log_message(self, *a):
            pass

    s = ThreadingHTTPServer(("127.0.0.1", PUERTO), Mango)
    print(f"voz en http://127.0.0.1:{PUERTO} (gpu={voz.gpu})", flush=True)
    s.serve_forever()


if __name__ == "__main__":
    os.chdir(Path(__file__).parent)
    v = Voz()
    if "--probar" in sys.argv:
        ms = v.decir("Vas 0/7/2 contra Jax AP. Impresionante. Para el otro equipo.")
        print(f"primera frase sonando en {ms} ms")
        v.callado.wait(30)
        raise SystemExit(0)
    servir(v)
