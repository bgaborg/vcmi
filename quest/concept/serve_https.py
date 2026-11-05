"""HTTPS static server for the WebXR concept (self-signed cert, LAN access)."""
import functools
import http.server
import ssl
import sys
from pathlib import Path

here = Path(__file__).parent
port = int(sys.argv[1]) if len(sys.argv) > 1 else 8443

handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(here))
httpd = http.server.ThreadingHTTPServer(("0.0.0.0", port), handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(here / "cert.pem", here / "key.pem")
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
print(f"serving https://0.0.0.0:{port}")
httpd.serve_forever()
