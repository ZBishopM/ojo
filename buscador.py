"""El buscador de Ojo: SearXNG local (F:\\ai\\searxng), solo DuckDuckGo.

Lo lanza el supervisor con el Python embebido de SearXNG. Hace lo mismo que el
start.bat del kit portable-searxng, pero en ESTE proceso y tomando un mutex,
que es como el supervisor sabe si esta vivo (como la voz y el oido).

    F:\\ai\\searxng\\python\\python.exe buscador.py

Puerto 8888 (el 8080 es del 35B del Win+Space). Ojo lo consulta en
http://127.0.0.1:8888/search?q=...&format=json (buscar.ps1).
"""
import ctypes
import os
import runpy
import sys
from ctypes import wintypes

BASE = r"F:\ai\searxng"
PUERTO = "8888"

k32 = ctypes.windll.kernel32
k32.CreateMutexW.restype = wintypes.HANDLE
_MUTEX = k32.CreateMutexW(None, True, r"Global\ojo-buscador")
if ctypes.GetLastError() == 183:  # ERROR_ALREADY_EXISTS
    print(r"ya hay un buscador corriendo (mutex Global\ojo-buscador). Salgo.")
    raise SystemExit(0)

secreto = os.path.join(BASE, "data", "secret_key")
os.environ.update({
    "SEARXNG_SETTINGS_PATH": os.path.join(BASE, "settings.yml"),
    "SEARXNG_PORT": PUERTO,
    "SEARXNG_BIND_ADDRESS": "127.0.0.1",
    "SEARXNG_BASE_URL": f"http://127.0.0.1:{PUERTO}/",
    "SEARXNG_SECRET": open(secreto, encoding="ascii").read().strip(),
})
os.chdir(BASE)
sys.argv = ["searx.webapp"]
runpy.run_module("searx.webapp", run_name="__main__")
