"""Que motor de voz a texto usa Ojo, decidido con numeros.

Por que no se hereda el de voicebox: aquel carga Whisper con transformers y
torch, que es un arranque de varios segundos y ocupa VRAM. Aqui la VRAM ya esta
entera en el modelo de vision (11,4 de 12,28 GB), asi que el STT tiene que vivir
en CPU o no vivir.

Candidatos, los dos por onnxruntime para que la comparacion sea limpia:

  nemo-parakeet-tdt-0.6b-v3   NVIDIA. 25 idiomas, detecta el idioma solo, y las
                              mediciones publicadas lo ponen por encima de
                              whisper large-v3 con un cuarto del tamano y
                              corriendo en CPU.
  whisper-base                Lo que voicebox usa hoy, como linea base. Los
                              300 ms que arrastra el plan salen de ahi.

Se mide con los .wav de F:\\ai\\muletillas, que son voz en espanol de verdad y
de la duracion que tendra una orden hablada.

OJO CON LO QUE ESTO NO MIDE: la precision con SU microfono y SU voz. Estas son
grabaciones ya hechas. Para eso hace falta que el hable, y va aparte.

  python banco-stt.py                velocidad, los dos motores
  python banco-stt.py parakeet       velocidad, uno solo
  python banco-stt.py --frases       precision sobre frases en espanol
"""
import json
import os
import re
import sys
import time
import unicodedata
import wave
from pathlib import Path

os.environ.setdefault("HF_HOME", r"F:\ai\hf")

import onnx_asr  # noqa: E402

# El valor es (nombre, cuantizacion). El repo trae el encoder en fp32 -- 2,3 GB
# de pesos, que son 2,5 GB de RAM en el demonio -- y tambien en int8. Merece la
# pena medir si int8 mantiene la precision, porque ese demonio vive residente
# al lado del modelo de vision.
MOTORES = {
    "parakeet": ("nemo-parakeet-tdt-0.6b-v3", None),
    "parakeet-int8": ("nemo-parakeet-tdt-0.6b-v3", "int8"),
    "whisper-base": ("whisper-base", None),
}


def cargar(entrada):
    nombre, cuant = entrada
    if cuant:
        return onnx_asr.load_model(nombre, quantization=cuant)
    return onnx_asr.load_model(nombre)


def ram_mb() -> int:
    """RAM del proceso, sin depender de psutil."""
    import ctypes
    from ctypes import wintypes

    class PMC(ctypes.Structure):
        _fields_ = [("cb", wintypes.DWORD), ("PageFaultCount", wintypes.DWORD),
                    ("PeakWorkingSetSize", ctypes.c_size_t),
                    ("WorkingSetSize", ctypes.c_size_t),
                    ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                    ("PagefileUsage", ctypes.c_size_t),
                    ("PeakPagefileUsage", ctypes.c_size_t)]

    c = PMC()
    c.cb = ctypes.sizeof(c)
    # K32GetProcessMemoryInfo de kernel32, no GetProcessMemoryInfo de psapi:
    # el segundo existe pero devolvio 0 sin quejarse, y una medida que miente
    # en silencio es peor que no tenerla. Se comprueba el retorno.
    ok = ctypes.windll.kernel32.K32GetProcessMemoryInfo(
        ctypes.windll.kernel32.GetCurrentProcess(), ctypes.byref(c), c.cb)
    if not ok:
        return -1
    return int(c.WorkingSetSize / 1024 / 1024)
AUDIO = Path(r"F:\ai\muletillas")


def duracion(p: Path) -> float:
    with wave.open(str(p)) as w:
        return w.getnframes() / w.getframerate()


def formato(p: Path) -> str:
    with wave.open(str(p)) as w:
        return f"{w.getframerate()} Hz, {w.getnchannels()} canal(es), {w.getsampwidth()*8} bits"


def medir(clave: str, nombre, wavs: list[Path]) -> dict:
    print(f"\n=== {clave} ({nombre}) ===", flush=True)
    t0 = time.perf_counter()
    modelo = cargar(nombre)
    carga = time.perf_counter() - t0
    print(f"carga  {carga:6.2f} s   RAM {ram_mb()} MB", flush=True)

    # La primera transcripcion incluye el calentamiento de onnxruntime y no
    # representa nada; se hace y se tira.
    modelo.recognize(str(wavs[0]))

    filas, tiempos, rtfs = [], [], []
    for p in wavs:
        d = duracion(p)
        t = time.perf_counter()
        texto = modelo.recognize(str(p))
        ms = (time.perf_counter() - t) * 1000
        tiempos.append(ms)
        rtfs.append((ms / 1000) / d if d else 0)
        filas.append((p.name, d, ms, (texto or "").strip()))

    for n, d, ms, texto in filas:
        print(f"  {n:<16} {d:4.1f} s  {ms:6.0f} ms   {texto[:58]}")
    tiempos.sort()
    med = tiempos[len(tiempos) // 2]
    print(f"  mediana {med:.0f} ms   p95 {tiempos[int(len(tiempos)*0.95)-1]:.0f} ms"
          f"   RTF medio {sum(rtfs)/len(rtfs):.3f}")
    return {"carga_s": carga, "mediana_ms": med, "rtf": sum(rtfs) / len(rtfs), "ram_mb": ram_mb()}


def normalizar(s: str) -> list[str]:
    """Palabras comparables: sin tildes, sin puntuacion, en minusculas.

    La referencia se escribio sin tildes y el motor las pone, asi que sin esto
    'microfono' y 'micrófono' contarian como error y la medida seria ruido.
    """
    d = unicodedata.normalize("NFD", s.lower())
    limpio = "".join(c for c in d if unicodedata.category(c) != "Mn")
    return [w for w in re.split(r"[^a-z0-9]+", limpio) if w]


def wer(ref: list[str], hip: list[str]) -> tuple[int, int]:
    """Errores de palabra por distancia de edicion. Devuelve (errores, palabras)."""
    # Programacion dinamica clasica. Son frases de ocho palabras: no merece
    # una dependencia.
    d = [[0] * (len(hip) + 1) for _ in range(len(ref) + 1)]
    for i in range(len(ref) + 1):
        d[i][0] = i
    for j in range(len(hip) + 1):
        d[0][j] = j
    for i in range(1, len(ref) + 1):
        for j in range(1, len(hip) + 1):
            coste = 0 if ref[i - 1] == hip[j - 1] else 1
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + coste)
    return d[len(ref)][len(hip)], len(ref)


def precision() -> int:
    """Precision sobre frases en espanol con transcripcion conocida."""
    dir_f = Path(__file__).parent / "frases"
    ref_j = dir_f / "referencia.json"
    if not ref_j.exists():
        print(f"faltan las frases. Corre primero: pwsh -File generar-frases.ps1")
        return 1
    refs = json.loads(ref_j.read_text(encoding="utf-8-sig"))

    resumen = {}
    for clave, nombre in MOTORES.items():
        print(f"\n=== {clave} ===", flush=True)
        try:
            modelo = cargar(nombre)
        except Exception as e:  # noqa: BLE001
            print(f"  FALLO al cargar: {type(e).__name__}: {e}")
            continue
        err = pal = 0
        exactas = 0
        for k, esperado in refs.items():
            w = dir_f / f"{k}.wav"
            if not w.exists():
                continue
            dicho = modelo.recognize(str(w)) or ""
            r, h = normalizar(esperado), normalizar(dicho)
            e, n = wer(r, h)
            err += e
            pal += n
            if e == 0:
                exactas += 1
            marca = "ok " if e == 0 else f"{e} err"
            print(f"  {k} {marca:<7} {dicho.strip()[:64]}")
        if pal:
            print(f"  WER {100*err/pal:.1f}%   frases exactas {exactas}/{len(refs)}")
            resumen[clave] = (100 * err / pal, exactas)

    if len(resumen) > 1:
        print("\n=== RESUMEN ===")
        for k, (w_, ex) in resumen.items():
            print(f"{k:<14} WER {w_:5.1f}%   exactas {ex}/{len(refs)}")
    return 0


def main() -> int:
    if "--frases" in sys.argv:
        return precision()
    # Por defecto las muletillas; con --dir, lo que se le diga. Las frases
    # generadas duran 1,5-2,5 s, que es lo que dura una orden hablada de
    # verdad; las muletillas son de medio segundo y no representan el caso.
    carpeta = AUDIO
    if "--dir" in sys.argv:
        carpeta = Path(sys.argv[sys.argv.index("--dir") + 1])
        sys.argv = [a for a in sys.argv if a != "--dir" and a != str(carpeta)]
    wavs = sorted(carpeta.glob("*.wav"))[:12]
    if not wavs:
        print(f"no hay .wav en {AUDIO}")
        return 1
    print(f"{len(wavs)} audios, {formato(wavs[0])}, "
          f"{sum(duracion(p) for p in wavs):.1f} s en total")

    quiere = sys.argv[1:] or list(MOTORES)
    res = {}
    for clave in quiere:
        if clave not in MOTORES:
            print(f"motor desconocido: {clave}. Hay: {', '.join(MOTORES)}")
            return 1
        try:
            res[clave] = medir(clave, MOTORES[clave], wavs)
        except Exception as e:  # noqa: BLE001
            print(f"  FALLO: {type(e).__name__}: {e}")

    if len(res) > 1:
        print("\n=== RESUMEN ===")
        print(f"{'motor':<16}{'carga':>8}{'mediana':>10}{'RTF':>8}{'RAM':>10}")
        for k, v in res.items():
            print(f"{k:<16}{v['carga_s']:7.1f}s{v['mediana_ms']:9.0f}ms{v['rtf']:8.3f}{v['ram_mb']:8d}MB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
