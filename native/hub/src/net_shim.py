# Boot script for local Python runs that may use the network. WASI has no sockets, so the standard
# HTTP client is replaced by one that asks the host: a request is written to stdout as one marked
# line, the answer comes back on stdin as one JSON line. The user's program is sys.argv[1].
import base64
import http.client
import io
import json
import sys

_Base = http.client.HTTPConnection
_MARK = "\x01FLUTE-NET "
_user = sys.argv.pop(1)


def _rpc(req):
    sys.stdout.write(_MARK + json.dumps(req) + "\n")
    sys.stdout.flush()
    line = sys.stdin.buffer.readline()
    if not line:
        raise OSError("network is not available")
    reply = json.loads(line)
    if reply.get("error"):
        raise OSError(reply["error"])
    return reply


class _Sock:
    def __init__(self, raw):
        self._raw = raw

    def makefile(self, *args, **kwargs):
        return io.BytesIO(self._raw)

    def close(self):
        pass


class _Conn(_Base):
    _scheme = "http"
    default_port = 80

    def __init__(self, host, port=None, timeout=None, source_address=None, blocksize=8192, **kwargs):
        _Base.__init__(self, host, port, blocksize=blocksize)
        self._reply = None

    def connect(self):
        pass

    def close(self):
        self._reply = None

    def request(self, method, url, body=None, headers=None, *, encode_chunked=False):
        # The whole exchange happens here, like a real connection that fails while connecting, so
        # urllib turns a failure into URLError.
        if body is not None and not isinstance(body, (bytes, bytearray)):
            if isinstance(body, str):
                body = body.encode("utf-8")
            elif hasattr(body, "read"):
                body = body.read()
            else:
                body = b"".join(body)
        if url.startswith("http://") or url.startswith("https://"):
            full = url
        else:
            host = self.host
            if self.port != self.default_port:
                host = "%s:%d" % (host, self.port)
            full = "%s://%s%s" % (self._scheme, host, url)
        self._method = method
        self._reply = _rpc({
            "m": method,
            "u": full,
            "h": dict(headers or {}),
            "b": base64.b64encode(bytes(body or b"")).decode(),
        })

    def getresponse(self):
        reply = self._reply
        data = base64.b64decode(reply.get("body", ""))
        head = "HTTP/1.1 %d %s\r\n" % (reply["status"], reply.get("reason", ""))
        for key, value in reply.get("headers", {}).items():
            if key.lower() in ("content-length", "transfer-encoding", "content-encoding", "connection"):
                continue
            head += "%s: %s\r\n" % (key, value)
        head += "Content-Length: %d\r\nConnection: close\r\n\r\n" % len(data)
        response = http.client.HTTPResponse(_Sock(head.encode("latin-1", "replace") + data), method=self._method)
        response.begin()
        return response


class _SecureConn(_Conn):
    _scheme = "https"
    default_port = 443


# WASI Python has no ssl module, so urllib would not even offer https. Setting this before
# urllib.request is imported makes it define its https handler.
http.client.HTTPConnection = _Conn
http.client.HTTPSConnection = _SecureConn
# urllib's https handler asks http.client for a TLS context; there is none, and none is needed
# because the host makes the secure connection.
http.client._create_https_context = lambda http_version: None

exec(compile(_user, "<sandbox>", "exec"), {"__name__": "__main__"})
