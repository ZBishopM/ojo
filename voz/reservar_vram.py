"""Reserva N MiB de VRAM y los retiene, como haria LoL (~4.600 MiB), para medir
modelos y voces "con el juego abierto" sin jugar. Se suelta al matar el
proceso (lo mata quien lo lanzo).

    F:\\ai\\tts\\pocket-gpu\\.venv\\Scripts\\python reservar_vram.py 4600
"""
import sys
import threading

import torch

mib = int(sys.argv[1]) if len(sys.argv) > 1 else 4600
bloque = torch.empty(mib * 2**20, dtype=torch.uint8, device="cuda")
bloque.fill_(1)  # tocarla: que el driver la asigne de verdad
torch.cuda.synchronize()
print(f"reservados {mib} MiB", flush=True)
threading.Event().wait()  # hasta que maten el proceso
