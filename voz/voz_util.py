"""Cuanto de cada clip es voz y cuanto silencio (para cazar clips que se alargan
con silencio o con balbuceo al final).

    <venv>\\python voz_util.py salida\\ligeras\\*.wav
"""
import glob
import sys

import numpy as np
import soundfile as sf

for patron in sys.argv[1:]:
    for f in sorted(glob.glob(patron)):
        a, sr = sf.read(f, dtype="float32")
        if a.ndim > 1:
            a = a.mean(axis=1)
        v = 0.02 * 1  # ventana de 20 ms
        n = int(sr * v)
        rms = np.sqrt(np.mean(a[: len(a) // n * n].reshape(-1, n) ** 2, axis=1))
        voz = rms > max(0.01, rms.max() * 0.05)
        idx = np.nonzero(voz)[0]
        cola = (len(voz) - 1 - idx[-1]) * v if len(idx) else len(voz) * v
        print(f"{f}: {len(a) / sr:.2f} s, voz {voz.sum() * v:.2f} s, silencio final {cola:.2f} s")
