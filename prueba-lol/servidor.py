"""Un Live Client Data API FALSO, para probar Ojo en partida sin jugar.

Sirve por HTTPS en 127.0.0.1:2999, con certificado autofirmado -- igual que el
cliente del juego --, el JSON de `allgamedata.json` en la ruta que usa Riot:

    GET https://127.0.0.1:2999/liveclientdata/allgamedata

Se usa junto con una copia inerte de ping.exe llamada "League of Legends.exe",
para que la puerta de ojo.ps1 (que mira ese proceso) y el supervisor (que cambia
de perfil al verlo) se comporten como con el juego de verdad.

    python servidor.py <cert.pem> <clave.pem> [allgamedata.json]

Cuando haya una muestra real (`lol.ps1 -Crudo > real.json` en una partida),
pasarla como tercer argumento: vale mas que cualquier partida inventada.
"""
import http.server
import pathlib
import ssl
import sys

AQUI = pathlib.Path(__file__).parent
CERT, CLAVE = sys.argv[1], sys.argv[2]
DATOS = pathlib.Path(sys.argv[3]) if len(sys.argv) > 3 else AQUI / "allgamedata.json"


class Api(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split("?")[0] != "/liveclientdata/allgamedata":
            self.send_error(404)
            return
        cuerpo = DATOS.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(cuerpo)))
        self.end_headers()
        self.wfile.write(cuerpo)

    def log_message(self, *a):
        pass


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 2999), Api)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(CERT, CLAVE)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
print(f"API falsa de League en https://127.0.0.1:2999 sirviendo {DATOS.name}", flush=True)
srv.serve_forever()
