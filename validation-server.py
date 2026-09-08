"""Local-only content-type-correct server for signed updater validation."""

from __future__ import annotations

import http.server
import os


class Handler(http.server.SimpleHTTPRequestHandler):
    def guess_type(self, path: str) -> str:
        if path.endswith((".json", ".json.sig")):
            return "application/json"
        return super().guess_type(path)


os.chdir(os.environ["TOKEN_RANK_VALIDATION_ROOT"])
http.server.ThreadingHTTPServer(("127.0.0.1", 8765), Handler).serve_forever()
