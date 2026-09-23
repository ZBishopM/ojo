"""Chatterbox Multilingual (GPU) con las frases de frases.txt. Se ejecuta con
el venv de voicebox, que ya lo tiene instalado:

    D:\\2026-projects\\voicebox\\backend\\venv\\Scripts\\python.exe banco_chatterbox.py [referencia.wav]

La voz se clona de una referencia; por defecto, Piper es_MX-claude (acento
latino seguro). Mide igual que banco_voz.py, mas la VRAM de pico.
"""
import json
import sys
import time
from pathlib import Path

import numpy as np
import soundfile as sf
import torch
from chatterbox.mtl_tts import ChatterboxMultilingualTTS

AQUI = Path(__file__).parent
FRASES = [l.strip() for l in (AQUI / "frases.txt").read_text(encoding="utf-8").splitlines() if l.strip()]

ref = Path(sys.argv[1]) if len(sys.argv) > 1 else AQUI / "salida" / "referencia-piper.wav"
if not ref.exists():
    a, sr = sf.read(AQUI / "salida" / "piper" / "1.wav")
    b, _ = sf.read(AQUI / "salida" / "piper" / "4.wav")
    sf.write(ref, np.concatenate([a, np.zeros(int(sr * 0.4)), b]), sr)

out = AQUI / "salida" / "chatterbox"
out.mkdir(parents=True, exist_ok=True)
t0 = time.perf_counter()
m = ChatterboxMultilingualTTS.from_pretrained(torch.device("cuda"))
m.prepare_conditionals(str(ref), exaggeration=0.6)
carga = time.perf_counter() - t0
kw = dict(language_id="es", exaggeration=0.6, cfg_weight=0.4)
m.generate("Hola.", **kw)
torch.cuda.reset_peak_memory_stats()
filas = []
for i, f in enumerate(FRASES, 1):
    primera = f.split(". ")[0]
    t0 = time.perf_counter(); m.generate(primera, **kw); torch.cuda.synchronize(); tp = time.perf_counter() - t0
    t0 = time.perf_counter(); wav = m.generate(f, **kw); torch.cuda.synchronize(); tt = time.perf_counter() - t0
    w = wav.squeeze().cpu().numpy()
    sf.write(out / f"{i}.wav", w, m.sr)
    dur = len(w) / m.sr
    filas.append({"frase": i, "primera_ms": round(tp * 1000), "total_ms": round(tt * 1000), "audio_s": round(dur, 2), "rtf": round(tt / dur, 3)})
r = {"motor": "chatterbox", "carga_ms": round(carga * 1000), "vram_pico_mib": round(torch.cuda.max_memory_reserved() / 2**20),
     "frases": filas, "primera_ms_max": max(x["primera_ms"] for x in filas), "rtf_medio": round(sum(x["rtf"] for x in filas) / len(filas), 3)}
(out / "medida.json").write_text(json.dumps(r, ensure_ascii=False, indent=1), encoding="utf-8")
print(json.dumps({k: v for k, v in r.items() if k != "frases"}, ensure_ascii=False))
