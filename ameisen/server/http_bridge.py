"""HTTP front-end for AmeisenNavigation Server 1.8.3.2.

Sylvanas Lua can only call core.http_get / core.http_post. The official
1.8.3.2 server speaks AnTCP (int32 size | uint8 type | payload). This
bridge listens on 127.0.0.1:47110 and forwards to 127.0.0.1:47111 using
only the opcodes that 1.8.3.2 registers.

Responses match AmeisenNav/anav/query.lua (plain-text ok/err lines).
"""

from __future__ import annotations

import socket
import struct
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

TCP_HOST = "127.0.0.1"
TCP_PORT = 47111
HTTP_HOST = "127.0.0.1"
HTTP_PORT = 47110
TCP_TIMEOUT = 30.0

MSG_PATH = 0
MSG_MOVE_ALONG_SURFACE = 1
MSG_RANDOM_POINT = 2
MSG_RANDOM_POINT_AROUND = 3
MSG_CAST_RAY = 4
MSG_RANDOM_PATH = 5

_lock = threading.Lock()
_sock: socket.socket | None = None


def _is_zero(x: float, y: float, z: float) -> bool:
    return x == 0.0 and y == 0.0 and z == 0.0


def _read_exact(sock: socket.socket, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("AmeisenNavigation TCP connection closed")
        buf.extend(chunk)
    return bytes(buf)


def _connect() -> socket.socket:
    sock = socket.create_connection((TCP_HOST, TCP_PORT), timeout=5.0)
    sock.settimeout(TCP_TIMEOUT)
    return sock


def _ensure_sock() -> socket.socket:
    global _sock
    if _sock is not None:
        return _sock
    _sock = _connect()
    return _sock


def _drop_sock() -> None:
    global _sock
    if _sock is not None:
        try:
            _sock.close()
        except OSError:
            pass
        _sock = None


def _rpc(msg_type: int, payload: bytes) -> bytes:
    packet = struct.pack("<i", len(payload) + 1) + bytes([msg_type]) + payload
    with _lock:
        last_error: Exception | None = None
        for _attempt in range(2):
            try:
                sock = _ensure_sock()
                sock.sendall(packet)
                size = struct.unpack("<i", _read_exact(sock, 4))[0]
                if size < 1 or size > 1024 * 1024:
                    raise ValueError(f"invalid AnTCP size {size}")
                body = _read_exact(sock, size)
                return body[1:]
            except (OSError, ConnectionError, TimeoutError, ValueError, struct.error) as exc:
                last_error = exc
                _drop_sock()
        raise ConnectionError(str(last_error) if last_error else "TCP request failed")


def _unpack_points(payload: bytes) -> list[tuple[float, float, float]]:
    if len(payload) % 12 != 0:
        raise ValueError(f"payload length {len(payload)} is not a multiple of 12")
    points = []
    for i in range(0, len(payload), 12):
        points.append(struct.unpack_from("<3f", payload, i))
    return points


def _qfloat(qs: dict[str, list[str]], key: str) -> float | None:
    values = qs.get(key)
    if not values:
        return None
    try:
        return float(values[0])
    except ValueError:
        return None


def _qint(qs: dict[str, list[str]], key: str, default: int | None = None) -> int | None:
    values = qs.get(key)
    if not values:
        return default
    try:
        return int(float(values[0]))
    except ValueError:
        return default


def _path_text(points: list[tuple[float, float, float]]) -> str:
    if not points or (len(points) == 1 and _is_zero(*points[0])):
        return "err no_path\n"
    lines = [f"ok {len(points)} complete"]
    lines.extend(f"{x:.6f} {y:.6f} {z:.6f}" for x, y, z in points)
    return "\n".join(lines) + "\n"


def _point_text(points: list[tuple[float, float, float]]) -> str:
    if not points or _is_zero(*points[0]):
        return "err no_path\n"
    x, y, z = points[0]
    return f"ok {x:.6f} {y:.6f} {z:.6f}\n"


def _do_path(map_id: int, sx: float, sy: float, sz: float, ex: float, ey: float, ez: float, flags: int, randomize: bool) -> str:
    payload = struct.pack("<ii3f3f", map_id, flags, sx, sy, sz, ex, ey, ez)
    msg = MSG_RANDOM_PATH if randomize else MSG_PATH
    return _path_text(_unpack_points(_rpc(msg, payload)))


def _do_move(map_id: int, sx: float, sy: float, sz: float, ex: float, ey: float, ez: float) -> str:
    payload = struct.pack("<i3f3f", map_id, sx, sy, sz, ex, ey, ez)
    return _point_text(_unpack_points(_rpc(MSG_MOVE_ALONG_SURFACE, payload)))


def _do_raycast(map_id: int, sx: float, sy: float, sz: float, ex: float, ey: float, ez: float) -> str:
    payload = struct.pack("<i3f3f", map_id, sx, sy, sz, ex, ey, ez)
    points = _unpack_points(_rpc(MSG_CAST_RAY, payload))
    if not points or _is_zero(*points[0]):
        return "ok hit 0 0 0\n"
    return "ok clear\n"


def _do_random(map_id: int, x: float | None, y: float | None, z: float | None, radius: float | None) -> str:
    if x is not None and y is not None and z is not None and radius is not None and radius > 0:
        payload = struct.pack("<i3ff", map_id, x, y, z, radius)
        return _point_text(_unpack_points(_rpc(MSG_RANDOM_POINT_AROUND, payload)))
    payload = struct.pack("<i", map_id)
    return _point_text(_unpack_points(_rpc(MSG_RANDOM_POINT, payload)))


def _tcp_up() -> bool:
    try:
        with _lock:
            _ensure_sock()
        return True
    except OSError:
        _drop_sock()
        return False


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:
        print(f"[http] {self.address_string()} {fmt % args}")

    def _send(self, code: int, body: str) -> None:
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def _read_body(self) -> str:
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0:
            return ""
        return self.rfile.read(length).decode("utf-8", errors="replace")

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query, keep_blank_values=True)
        route = parsed.path.rstrip("/") or "/"
        try:
            if route == "/health":
                if _tcp_up():
                    self._send(200, "ok ameisennav 1.8.3.2 format=tc335a tcp=127.0.0.1:47111\n")
                else:
                    self._send(503, "err server_down AmeisenNavigationServer is not listening on 127.0.0.1:47111\n")
                return
            if route == "/path":
                map_id = _qint(qs, "map")
                sx, sy, sz = _qfloat(qs, "sx"), _qfloat(qs, "sy"), _qfloat(qs, "sz")
                ex, ey, ez = _qfloat(qs, "ex"), _qfloat(qs, "ey"), _qfloat(qs, "ez")
                if map_id is None or None in (sx, sy, sz, ex, ey, ez):
                    self._send(200, "err bad_request missing map or coordinates\n")
                    return
                flags = _qint(qs, "flags", 0) or 0
                randomize = qs.get("random", ["0"])[0] in ("1", "true", "yes")
                self._send(200, _do_path(map_id, sx, sy, sz, ex, ey, ez, flags, randomize))
                return
            if route == "/move":
                map_id = _qint(qs, "map")
                sx, sy, sz = _qfloat(qs, "sx"), _qfloat(qs, "sy"), _qfloat(qs, "sz")
                ex, ey, ez = _qfloat(qs, "ex"), _qfloat(qs, "ey"), _qfloat(qs, "ez")
                if map_id is None or None in (sx, sy, sz, ex, ey, ez):
                    self._send(200, "err bad_request missing map or coordinates\n")
                    return
                self._send(200, _do_move(map_id, sx, sy, sz, ex, ey, ez))
                return
            if route == "/raycast":
                map_id = _qint(qs, "map")
                sx, sy, sz = _qfloat(qs, "sx"), _qfloat(qs, "sy"), _qfloat(qs, "sz")
                ex, ey, ez = _qfloat(qs, "ex"), _qfloat(qs, "ey"), _qfloat(qs, "ez")
                if map_id is None or None in (sx, sy, sz, ex, ey, ez):
                    self._send(200, "err bad_request missing map or coordinates\n")
                    return
                self._send(200, _do_raycast(map_id, sx, sy, sz, ex, ey, ez))
                return
            if route == "/random":
                map_id = _qint(qs, "map")
                if map_id is None:
                    self._send(200, "err bad_request missing map\n")
                    return
                self._send(200, _do_random(map_id, _qfloat(qs, "x"), _qfloat(qs, "y"), _qfloat(qs, "z"), _qfloat(qs, "r")))
                return
            if route == "/height":
                self._send(200, "err no_path height is not supported by AmeisenNavigation 1.8.3.2\n")
                return
            self._send(404, "err bad_request unknown route\n")
        except (OSError, ConnectionError, TimeoutError, ValueError, struct.error) as exc:
            self._send(200, f"err server_down {exc}\n")

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        route = parsed.path.rstrip("/") or "/"
        try:
            if route == "/log":
                self._read_body()
                self._send(200, "ok\n")
                return
            if route == "/paths":
                body = self._read_body()
                chunks: list[str] = []
                for index, raw in enumerate(body.splitlines()):
                    line = raw.strip()
                    if not line:
                        continue
                    parts = line.split()
                    if len(parts) < 7:
                        chunks.append(f"#{index} err bad_request malformed line")
                        continue
                    try:
                        map_id = int(float(parts[0]))
                        sx, sy, sz = float(parts[1]), float(parts[2]), float(parts[3])
                        ex, ey, ez = float(parts[4]), float(parts[5]), float(parts[6])
                        flags = int(float(parts[7])) if len(parts) > 7 else 0
                    except ValueError:
                        chunks.append(f"#{index} err bad_request malformed line")
                        continue
                    result = _do_path(map_id, sx, sy, sz, ex, ey, ez, flags, False)
                    first, _, rest = result.strip().partition("\n")
                    if rest:
                        chunks.append(f"#{index} {first}\n{rest}")
                    else:
                        chunks.append(f"#{index} {first}")
                self._send(200, ("\n".join(chunks) + "\n") if chunks else "ok\n")
                return
            self._send(404, "err bad_request unknown route\n")
        except (OSError, ConnectionError, TimeoutError, ValueError, struct.error) as exc:
            self._send(200, f"err server_down {exc}\n")


def main() -> None:
    server = ThreadingHTTPServer((HTTP_HOST, HTTP_PORT), Handler)
    print(f"HTTP API listening on http://{HTTP_HOST}:{HTTP_PORT}")
    print(f"Forwarding AnTCP to {TCP_HOST}:{TCP_PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("Stopped HTTP bridge")
    finally:
        server.server_close()
        _drop_sock()


if __name__ == "__main__":
    main()
