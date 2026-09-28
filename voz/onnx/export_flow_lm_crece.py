"""FlowLM con cache de atencion que CRECE (concat) en vez de un tensor fijo de
1000 posiciones reescrito entero con ScatterND en cada paso.

Medido con el export original en un i5-11400F, 1 hilo, por paso de 80 ms de
audio: ScatterND 30,6 ms + Gather 18,8 ms, frente a 19,4 ms del calculo real
(DynamicQuantizeMatMul). Aqui la cache entra con longitud T y sale con T+t:
solo se mueve lo ocupado.

Uso (desde la raiz del repo, PYTHONPATH=.):
  python scripts/export_flow_lm_crece.py --language spanish_24l --output_dir <dir>
"""
import argparse
import json
import os
import sys

import numpy as np
import onnxruntime as ort
import torch

sys.path.insert(0, os.path.dirname(__file__))
import export_flow_lm as base  # noqa: E402  (aplica sus parches al importarse)
from onnx_export.export_utils import flatten_state, get_state_structure  # noqa: E402
from pocket_tts.models.tts_model import TTSModel  # noqa: E402
from pocket_tts.modules.stateful_module import init_states  # noqa: E402
from pocket_tts.modules.transformer import StreamingMultiheadAttention  # noqa: E402


def init_state_crece(self, batch_size: int, sequence_length: int):
    d = self.embed_dim // self.num_heads
    w = self.in_proj.weight
    return dict(
        step=torch.tensor([0], dtype=torch.long, device=w.device),
        current_end=torch.zeros((0,)).to(w.device),
        cache=torch.zeros((2, batch_size, sequence_length, self.num_heads, d), device=w.device, dtype=w.dtype),
    )


def complete_kv_crece(self, k, v, state):
    nueva = torch.cat([state["cache"], torch.stack([k, v])], dim=2)
    state["cache"] = nueva
    return nueva[0], nueva[1]


StreamingMultiheadAttention.init_state = init_state_crece
StreamingMultiheadAttention._complete_kv = complete_kv_crece


def main():
    torch.manual_seed(42)
    ap = argparse.ArgumentParser()
    ap.add_argument("--output_dir", "-o", required=True)
    ap.add_argument("--language", default="spanish_24l")
    a = ap.parse_args()
    os.makedirs(a.output_dir, exist_ok=True)

    tts = TTSModel.load_model(language=a.language).cpu().eval()
    # Para trazar hace falta una cache con algo dentro (4 posiciones); el eje
    # se declara dinamico y el runtime arranca con longitud 0.
    TRAZA = 4
    state = init_states(tts.flow_lm, batch_size=1, sequence_length=TRAZA)
    for mod in state.values():
        if "step" in mod:
            mod["step"] = torch.tensor([TRAZA], dtype=torch.long)
    structure = get_state_structure(state)
    flat = flatten_state(state)

    # Que tensores planos son caches (para el eje dinamico) y su manifiesto.
    rutas = []
    def recorrer(s, pre=""):
        for k, v in sorted(s.items()):
            if isinstance(v, dict):
                recorrer(v, f"{pre}{k}/")
            else:
                rutas.append(f"{pre}{k}")
    recorrer(structure)
    assert len(rutas) == len(flat)
    ins = [f"state_{i}" for i in range(len(flat))]
    outs = [f"out_state_{i}" for i in range(len(flat))]
    dyn = {"sequence": {1: "seq_len"}, "text_embeddings": {1: "text_len"}}
    for i, r in enumerate(rutas):
        if r.endswith("/cache"):
            dyn[ins[i]] = {2: f"cache_in_{i}"}
            dyn[outs[i]] = {2: f"cache_out_{i}"}

    wrapper = base.FlowLMMainWrapper(tts.flow_lm, structure)
    dummy_seq = torch.randn(1, 1, tts.flow_lm.ldim)
    dummy_text = torch.randn(1, 1, tts.flow_lm.dim)
    ruta = os.path.join(a.output_dir, "flow_lm_main.onnx")
    torch.onnx.export(wrapper, (dummy_seq, dummy_text, flat), ruta,
                      input_names=["sequence", "text_embeddings"] + ins,
                      output_names=["conditioning", "eos_logit"] + outs,
                      dynamic_axes=dyn, opset_version=17, dynamo=False)
    print("exportado", ruta, flush=True)

    # Comprobacion: mismos numeros que PyTorch, con una cache de 7 posiciones.
    st = init_states(tts.flow_lm, batch_size=1, sequence_length=7)
    for mod in st.values():
        if "step" in mod:
            mod["step"] = torch.tensor([7], dtype=torch.long)
        if "cache" in mod:
            mod["cache"] = torch.randn_like(mod["cache"])
    fl = flatten_state(st)
    seq, txt = torch.randn(1, 1, tts.flow_lm.ldim), torch.randn(1, 2, tts.flow_lm.dim)
    with torch.no_grad():
        pt = wrapper(seq, txt, [t.clone() for t in fl])
    s = ort.InferenceSession(ruta, providers=["CPUExecutionProvider"])
    ox = s.run(None, {"sequence": seq.numpy(), "text_embeddings": txt.numpy(), **{n: t.numpy() for n, t in zip(ins, fl)}})
    for nombre, p, o in [("conditioning", pt[0], ox[0]), ("eos", pt[1], ox[1])]:
        np.testing.assert_allclose(p.numpy(), o, rtol=1e-4, atol=1e-4)
        print(f"{nombre} coincide", flush=True)
    for i, r in enumerate(rutas):
        if r.endswith("/cache"):
            assert ox[2 + i].shape[2] == 7 + 3, ox[2 + i].shape
    print("caches crecen 7 -> 10: bien", flush=True)

    # Manifiesto para el runtime: las caches empiezan vacias (longitud 0).
    man = []
    for i, (r, t) in enumerate(zip(rutas, flat)):
        shape = list(t.shape)
        fill = "zeros"
        if r.endswith("/cache"):
            shape[2] = 0
        elif r.endswith("/current_end"):
            fill = "empty"
        elif r.endswith("/step"):
            shape = [1]
        modulo, clave = r.rsplit("/", 1)
        man.append({"dtype": str(t.dtype).replace("torch.", ""), "fill": fill, "index": i,
                    "input_name": ins[i], "key": clave, "module": modulo,
                    "output_name": outs[i], "path": r, "shape": shape})
    with open(os.path.join(a.output_dir, "flow_lm_state_manifest.json"), "w") as f:
        json.dump(man, f, indent=1)
    print("manifiesto escrito", flush=True)


if __name__ == "__main__":
    main()
