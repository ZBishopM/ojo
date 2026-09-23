"""El texto principal de varias paginas HTML, con Trafilatura, en un solo proceso.

Lo llama buscar.ps1 (si $BUSCAR_EXTRACTOR = 'trafilatura'). Una llamada para
todas las paginas: arrancar Python cuesta ~200 ms y no se paga por pagina.

    python extraer.py pagina0.html pagina1.html ...   -> JSON: ["texto0", "texto1", ...]
"""
import json
import sys
from pathlib import Path

import trafilatura

salida = []
for p in sys.argv[1:]:
    try:
        html = Path(p).read_text(encoding="utf-8", errors="replace")
        t = trafilatura.extract(html, include_comments=False, include_tables=True, favor_recall=True) or ""
    except Exception:
        t = ""
    salida.append(t)
sys.stdout.reconfigure(encoding="utf-8")
print(json.dumps(salida, ensure_ascii=False))
