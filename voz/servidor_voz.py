"""La voz de Ojo, residente. Dos motores (--motor):

  pocket  (por defecto) Pocket TTS de Kyutai, espanol de 24 capas, voz "lola",
          en CPU con 2 hilos. Gano la escucha a ciegas 3 del 2026-09-24
          (naturalidad 5, personalidad 5, pronunciacion 4; la F2 saco 3/2/1).
          Medido: primer audio ~180 ms, RTF ~0,61, 0 de VRAM (la F2 ocupaba
          ~811 MiB). Corre en su venv: F:\\ai\\tts\\pocket\\.venv.
  f2      Supertonic 3, voz F2, en la GPU (la de antes; reserva). voz\\.venv.

Habla EN STREAMING: cada trozo de audio suena en cuanto sale, y cada frase
empieza mientras se genera la siguiente. El texto pasa antes por
texto_voz.para_decir (numeros en palabras, nombres en ingles como se dicen).

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
MOTOR = sys.argv[sys.argv.index("--motor") + 1] if "--motor" in sys.argv else "pocket"
VOZ = "F2"
MODELO = Path(r"F:\ai\voz\supertonic-3")
POCKET_VOZ = "lola"
POCKET_LENGUA = "spanish_24l"
POCKET_HILOS = 2  # 4 hilos fue mas lento (RTF 0,66 contra 0,61) y ocupaba 7 nucleos
SEG_POR_LETRA = 0.058  # lola habla ~17 letras/s (medido: 6,4 s para 110 letras)
# El tono: Pocket sortea la entonacion en cada frase (el espanol no fija
# temperatura: 0,7). Escucha a ciegas 4 (2026-09-28): gano temp 0,3 con
# semilla 42, "desganada, molestada pero expresiva". Con otras semillas la
# misma temperatura saco 1/5: el caracter lo da la semilla.
POCKET_TEMP = 0.3
POCKET_SEMILLA = 42
# Sin afinidad fija: probado 2026-09-28 fijarla a los nucleos 8 y 10 subio el
# RTF bajo carga de 1,3-1,6 a ~1,95 (sus hermanos de hyperthreading seguian
# ocupados, y sin fijar Windows la mueve al nucleo mas libre).
CARGA_COLCHON = 60  # % de CPU total por encima del cual hace falta colchon


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


def cargar_pocket():
    """Pocket TTS en CPU. generar(texto) va soltando trozos de audio."""
    import torch
    from pocket_tts import TTSModel
    torch.set_num_threads(POCKET_HILOS)
    m = TTSModel.load_model(language=POCKET_LENGUA, quantize=True)
    m.temp = POCKET_TEMP
    estado = m.get_state_for_audio_prompt(POCKET_VOZ)

    def generar(texto):
        torch.manual_seed(POCKET_SEMILLA)  # misma frase, mismo tono
        for trozo in m.generate_audio_stream(estado, texto):
            yield trozo.numpy().astype(np.float32).reshape(-1)
    for _ in generar("Hola."):  # en caliente
        pass
    return generar, m.sample_rate, False


def cargar():
    """Supertonic F2, en GPU si se puede. En CPU la primera frase tarda ~1,5 s
    (medido): vale de reserva, no de uso normal. generar(texto) suelta la
    frase entera de una vez."""
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

    def generar(texto):
        wav, _ = t.synthesize(texto, voice_style=estilo, lang="es", total_steps=pasos)
        yield np.asarray(wav, dtype=np.float32).reshape(-1)
    for _ in generar("Hola."):  # en caliente
        pass
    return generar, t.sample_rate, gpu


def escribir_log(linea):
    with open(Path(__file__).parent / "voz.log", "a", encoding="utf-8") as f:
        f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {linea}\n")


def cpu_ahora():
    """Uso de CPU total en los ultimos 50 ms (0-100). Sin psutil, 0."""
    try:
        import psutil
        return psutil.cpu_percent(interval=0.05)
    except ImportError:
        return 0.0


def rtf_para_carga(carga):
    """RTF esperado de Pocket con prioridad alta segun la carga total.
    Medido: libre ~0,7; con 8 procesos quemando (~80 % de CPU) 1,3-1,6, y la
    pregunta real del 2026-09-27 22:02, 1,40. Por debajo de CARGA_COLCHON no
    hace falta colchon."""
    if carga < CARGA_COLCHON:
        return 0.9
    return 1.4 if carga < 85 else 1.6


def hay_partida():
    """LoL en marcha: la CPU va ocupada y la voz necesita colchon."""
    try:
        import psutil
        return any(p.info["name"] == "League of Legends.exe" for p in psutil.process_iter(["name"]))
    except ImportError:
        return False


def frases(texto):
    """Troceado por final de frase. La primera, corta: es la que se espera."""
    return [f for f in re.split(r"(?<=[.!?…;:])\s+", texto.strip()) if f]


class Voz:
    def __init__(self):
        self.generar, self.sr, self.gpu = cargar_pocket() if MOTOR == "pocket" else cargar()
        self.ultimo_rtf = None  # de la ultima respuesta: >1 es que se entrecorta (CPU ocupada)
        self.huecos = 0         # bloques de ~21 ms en que el altavoz se quedo sin audio a media respuesta
        self.retener = threading.Event(); self.retener.set()  # clear = esperar el colchon
        # El chivato: el primer hueco de cada respuesta despierta a este hilo,
        # que apunta quien se esta comiendo la CPU. Nada lento en el callback.
        self.hubo_hueco = threading.Event()
        threading.Thread(target=self._chivato, daemon=True).start()
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
        while i < n and self.retener.is_set():
            if not len(self.actual):
                try:
                    turno, trozo = self.trozos.get_nowait()
                except queue.Empty:
                    if self.sonando.is_set() and not self.callado.is_set():
                        self.huecos += 1
                        if self.huecos == 1:
                            self.hubo_hueco.set()
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

    def _chivato(self):
        import psutil
        while True:
            self.hubo_hueco.wait()
            self.hubo_hueco.clear()
            procs = list(psutil.process_iter(["name"]))
            psutil.cpu_percent(None)  # abre la ventana del total tambien
            for p in procs:
                try:
                    p.cpu_percent(None)
                except psutil.Error:
                    pass
            time.sleep(0.3)  # la ventana de medida, no un sondeo
            uso = []
            for p in procs:
                try:
                    uso.append((p.cpu_percent(None), p.info["name"], p.pid))
                except psutil.Error:
                    pass
            top = ", ".join(f"{n}:{c:.0f}%" for c, n, _ in sorted(uso, reverse=True)[:5])
            escribir_log(f"hueco: cpu total {psutil.cpu_percent(None):.0f}% | {top}")

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
            self.huecos = 0
            # Con la CPU ocupada se genera mas lento de lo que suena (RTF > 1)
            # y salen huecos: voz robotica. Entonces se retiene el audio justo
            # para que lo que queda por generar llegue a tiempo:
            # colchon = total * (1 - 1/RTF), con el total estimado por letras.
            # Se decide con la carga de AHORA, no con el RTF de la respuesta
            # anterior (podia ser de hace horas y retrasaba 1,5 s sin motivo).
            carga = cpu_ahora()
            r = rtf_para_carga(carga)
            if hay_partida():
                r = max(r, 1.1)
            colchon = r > 1
            (self.retener.clear if colchon else self.retener.set)()
        t0 = time.perf_counter()
        dicho = para_decir(texto)
        partes = frases(dicho)
        colchon_s = len(dicho) * SEG_POR_LETRA * (1 - 1 / r) * 1.2 if colchon else 0
        primer_trozo = threading.Event()
        marca = {}

        def producir():
            muestras = 0
            for p in partes:
                for trozo in self.generar(p):
                    if turno != self.turno:  # otra pregunta o Esc: se deja de generar
                        return
                    self.trozos.put((turno, trozo))
                    muestras += len(trozo)
                    if not primer_trozo.is_set() and muestras / self.sr >= colchon_s:
                        self.retener.set()
                        marca["ms"] = round((time.perf_counter() - t0) * 1000)
                        primer_trozo.set()
            dur = muestras / self.sr
            if dur:
                self.ultimo_rtf = round((time.perf_counter() - t0) / dur, 3)
            self.trozos.put((turno, None))
            primer_trozo.set()
            if turno == self.turno:
                self.retener.set()
                self.callado.wait(60)
            escribir_log(f"rtf={self.ultimo_rtf} primera_ms={marca.get('ms')} huecos={self.huecos} "
                         f"cpu={carga:.0f}% colchon={colchon_s:.1f}s audio_s={dur:.1f}")
        threading.Thread(target=producir, daemon=True).start()
        if pid:
            threading.Thread(target=self._vigilar, args=(int(pid), turno), daemon=True).start()
        primer_trozo.wait(10)
        self.sonando.wait(2)
        return marca.get("ms")

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
                motor = f"pocket {POCKET_LENGUA} {POCKET_VOZ}" if MOTOR == "pocket" else f"supertonic-3 {VOZ}"
                self.responder({"ok": True, "motor": motor, "gpu": voz.gpu,
                                "hablando": not voz.callado.is_set(), "ultimo_rtf": voz.ultimo_rtf})
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
    # Prioridad alta: con la CPU cargada (8 hilos quemando) el RTF pasa de
    # 1,3-2,3 a ~1,05 (medido 2026-09-27). Solo compite mientras habla.
    try:
        import psutil
        psutil.Process().nice(psutil.HIGH_PRIORITY_CLASS)
    except ImportError:
        pass
    v = Voz()
    if "--probar" in sys.argv:
        ms = v.decir("Vas 0/7/2 contra Jax AP. Impresionante. Para el otro equipo.")
        print(f"primera frase sonando en {ms} ms")
        v.callado.wait(30)
        raise SystemExit(0)
    servir(v)
