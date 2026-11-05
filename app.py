"""Небольшой HTTP-сервис для практической работы с Docker Hub."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "1.2"
MESSAGE = (
    "Привет из контейнера!"
    if VERSION == "1.0"
    else f"Привет из контейнера! Версия {VERSION}."
)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = MESSAGE.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-App-Version", VERSION)
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    print(f"lab-app {VERSION}: listening on 0.0.0.0:8000", flush=True)
    ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
