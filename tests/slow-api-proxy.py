#!/usr/bin/env python3
"""Stand in front of the local API and make chosen requests slow.

Hosted CI simulators answer some requests seconds late, which shows up races that never happen
on a fast Mac. This reproduces them: run the API on another port, run this on the port the
iPhone tests use, and name the requests to delay.

    python3 tests/slow-api-proxy.py --listen 8936 --upstream 8937 \
        --delay "GET /api/session=8" --delay "GET /api/drafts/=6"

A rule is "METHOD path-prefix=seconds". Everything else passes straight through.
"""
import argparse
import http.client
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOP_BY_HOP = {"connection", "keep-alive", "transfer-encoding", "upgrade", "proxy-connection"}


def parse_rule(text):
    request, _, seconds = text.rpartition("=")
    method, _, prefix = request.strip().partition(" ")
    if not method or not prefix.startswith("/"):
        raise argparse.ArgumentTypeError(f'"{text}" is not "METHOD /path-prefix=seconds"')
    return method.upper(), prefix, float(seconds)


def handler_for(upstream_port, rules):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def forward(self):
            for method, prefix, seconds in rules:
                if self.command == method and self.path.startswith(prefix):
                    time.sleep(seconds)
                    break
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else None
            upstream = http.client.HTTPConnection("127.0.0.1", upstream_port, timeout=120)
            try:
                headers = [(k, v) for k, v in self.headers.items() if k.lower() not in HOP_BY_HOP]
                upstream.putrequest(self.command, self.path, skip_host=True, skip_accept_encoding=True)
                for name, value in headers:
                    upstream.putheader(name, value)
                upstream.endheaders(body)
                answer = upstream.getresponse()
                data = answer.read()
                self.send_response(answer.status, answer.reason)
                for name, value in answer.getheaders():
                    if name.lower() not in HOP_BY_HOP and name.lower() != "content-length":
                        self.send_header(name, value)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            finally:
                upstream.close()

        do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_OPTIONS = do_HEAD = forward

        def log_message(self, *_):
            pass

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--listen", type=int, default=8936)
    parser.add_argument("--upstream", type=int, default=8937)
    parser.add_argument("--delay", type=parse_rule, action="append", default=[])
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.listen), handler_for(args.upstream, args.delay))
    print(f"Slow proxy on {args.listen} -> {args.upstream}; delaying {args.delay}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
