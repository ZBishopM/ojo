"""La voz Lola en ONNX: la MISMA que Pocket PyTorch, gastando menos CPU.

Lo que la hace sonar igual que la voz de siempre (medido 2026-09-28, escuchas
a ciegas 5 a 7):
- Pesos de spanish_24l en la revision 39592ff, la que fija el Pocket
  instalado. El exportador bajaba la ultima (75cfe24): otro modelo, mas claro
  pero plano, y con otro tokenizador.
- tokenizer.json de esa revision (el tokenizer.model nuevo da otros ids).
- La voz "lola" precalculada por Kyutai (lola.safetensors), no clonada desde
  el mp3: el estado clonado difiere mas que su propio tamano medio.
- El ruido de torch con semilla 42 (ruido_torch42.npy), reiniciado en cada
  frase como hace servidor_voz.py con torch.manual_seed.

La carpeta del paquete (F:\\ai\\tts\\pocket-onnx\\lola-v39) lleva todo eso junto
al grafo de flow_lm_main con la cache que CRECE (voz\\onnx\\export_flow_lm_crece.py).
El runtime es pocket_tts_onnx.py de KevinAHM (HF KevinAHM/pocket-tts-onnx).
"""
import os
import sys
from pathlib import Path

import numpy as np

RUNTIME = Path(r"F:\ai\tts\pocket-onnx")


class _TokJson:
    """tokenizer.json con la interfaz de sentencepiece que usa el runtime."""

    def __init__(self, ruta):
        from tokenizers import Tokenizer
        self.t = Tokenizer.from_file(str(ruta))

    def Encode(self, texto):  # noqa: N802
        return self.t.encode(texto).ids

    def Decode(self, ids):  # noqa: N802
        return self.t.decode(ids)


class LolaOnnx:
    def __init__(self, carpeta=RUNTIME / "lola-v39", hilos=1, temperatura=0.3):
        import onnxruntime as ort
        from safetensors import safe_open
        sys.path.insert(0, str(RUNTIME))
        import pocket_tts_onnx as P

        def opciones(_self):
            o = ort.SessionOptions()
            o.intra_op_num_threads = hilos
            o.inter_op_num_threads = 1
            o.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
            return o

        P.PocketTTSOnnx._make_session_options = opciones
        carpeta = Path(carpeta)
        fp32 = not (carpeta / "flow_lm_main_int8.onnx").exists()
        self.tts = P.PocketTTSOnnx(models_dir=str(carpeta), language=carpeta.name,
                                   precision="fp32" if fp32 else "int8", device="cpu", temperature=temperatura)
        self.tts.tokenizer = _TokJson(carpeta / "tokenizer.json")
        self.sample_rate = self.tts.sample_rate

        # El estado de voz de Kyutai, al formato de nuestro manifiesto.
        f = safe_open(str(carpeta / "lola.safetensors"), "np")
        self.estado = {}
        for e in self.tts.flow_state_manifest:
            if e["key"] == "cache":
                self.estado[e["input_name"]] = f.get_tensor(f"{e['module']}/cache").astype(np.float32)
            elif e["key"] == "step":
                self.estado[e["input_name"]] = f.get_tensor(f"{e['module']}/offset").astype(np.int64).reshape(1)
            else:
                self.estado[e["input_name"]] = np.zeros((0,), np.float32)
        self.tts.prepare_voice_state = lambda _voz: self.tts._clone_state(self.estado)

        self.ruido = np.load(carpeta / "ruido_torch42.npy")
        self.temperatura = temperatura
        self.tts._run_flow_lm_chunk = self._pasos

    # El bucle de generacion, calcado de TTSModel._autoregressive_generation de
    # Pocket, en lugar del del runtime, que difiere en dos cosas que cambian la
    # voz:
    # - PyTorch saca un latente (y gasta un sorteo de ruido) tambien en el
    #   prellenado del texto, asi que el paso 0 usa el SEGUNDO sorteo;
    # - PyTorch ignora el EOS en los 6 primeros pasos (_MIN_FRAMES_BEFORE_EOS).
    MIN_PASOS_ANTES_DE_EOS = 6
    UMBRAL_EOS = -4.0

    def _pasos(self, estado_inicial, text_ids, max_frames, frames_after_eos):
        tts = self.tts
        estado = tts._clone_state(estado_inicial)
        te = tts.text_conditioner.run(None, {"token_ids": text_ids})[0]
        te = te[None] if te.ndim == 2 else te
        vacio_s = np.zeros((1, 0, tts.latent_dim), np.float32)
        vacio_t = np.zeros((1, 0, tts.conditioning_dim), np.float32)
        r = tts.flow_lm_main.run(None, {"sequence": vacio_s, "text_embeddings": te, **estado})
        tts._update_state_from_outputs(estado, r, tts.flow_state_manifest, output_offset=2)
        i = 1  # el sorteo 0 se lo lleva el prellenado
        std = np.float32(np.sqrt(self.temperatura))
        dt = np.float32(1.0 / tts.lsd_steps)
        actual = np.full((1, 1, tts.latent_dim), np.nan, np.float32)
        eos_paso = None
        for paso in range(max_frames or tts._estimate_max_gen_len(text_ids.shape[1])):
            r = tts.flow_lm_main.run(None, {"sequence": actual, "text_embeddings": vacio_t, **estado})
            tts._update_state_from_outputs(estado, r, tts.flow_state_manifest, output_offset=2)
            if r[1][0][0] > self.UMBRAL_EOS and eos_paso is None and paso >= self.MIN_PASOS_ANTES_DE_EOS:
                eos_paso = paso
            if eos_paso is not None and paso >= eos_paso + frames_after_eos:
                break
            x = self.ruido[i % len(self.ruido)][None] * std
            i += 1
            for s, t in tts._st_buffers:
                x = x + tts.flow_lm_flow.run(None, {"c": r[0], "s": s, "t": t, "x": x})[0] * dt
            actual = x.reshape(1, 1, tts.latent_dim).astype(np.float32)
            yield actual

    def generar(self, texto):
        """Una frase -> trozos de audio float32. El ruido empieza de cero en cada
        frase, como torch.manual_seed(42) antes de cada frase en el servidor."""
        for trozo in self.tts.stream(texto, voice="lola"):
            yield np.asarray(trozo, dtype=np.float32).reshape(-1)


if __name__ == "__main__":
    # Comprobacion minima: genera una frase y dice cuanto audio salio.
    import time
    m = LolaOnnx(os.environ.get("LOLA_ONNX", RUNTIME / "lola-v39"))
    t0 = time.perf_counter()
    a = np.concatenate(list(m.generar("¿De verdad vas a comprar botas ahora? Bueno. Tú sabrás.")))
    dur = a.size / m.sample_rate
    assert dur > 2.0, f"solo {dur:.2f} s de audio: el estado de voz no encaja con los pesos"
    print(f"ok: {dur:.2f} s de audio en {time.perf_counter() - t0:.2f} s")
