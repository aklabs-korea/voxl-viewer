#!/usr/bin/env python3
"""For the UI tests (ios/build.sh uitest): passes a dev voxl started with --read-only through, but tells the page it
may send input, so the test log shows what the app's gestures and keys send. The read-only voxl still drops all of
it, so nothing reaches the desktop.

  ios/devproxy.py LISTEN_PORT VOXL_PORT [CONTROL_PORT]      e.g. 6918 6908 6917 (all on 127.0.0.1)

The control port lets a test bend the network the way the app meets it (GET /<command>):
  /delay?s=N   new connections wait N seconds before anything flows (a screen slow to answer); 0 turns it off
  /wide/on     voxl's hello says 5120 wide (another viewer asked for Full); /wide/off
  /drop        closes every connection now (Wi-Fi to cellular)
  /silence     the open connections stay open but carry nothing (a network that drops packets); new ones work
  /resume      they carry again
  /reset       all of it off
"""
import asyncio
import sys
from urllib.parse import parse_qs, urlparse

# voxl's hello says "readOnly":true for a read-only server; null keeps the frame's length.
FIND, PUT = b'"readOnly":true', b'"readOnly":null'
# The dev voxl's screen is 2560 wide; 5120 keeps the frame's length too.
NARROW, WIDE = b'"w":2560', b'"w":5120'

state = {"delay": 0.0, "wide": False}
conns = set()
silent = set()


async def pipe(reader, writer, from_voxl, pair):
    try:
        while data := await reader.read(65536):
            if pair in silent:
                continue
            if from_voxl:
                data = data.replace(FIND, PUT)
                if state["wide"]:
                    data = data.replace(NARROW, WIDE)
            writer.write(data)
            await writer.drain()
    except (ConnectionError, asyncio.CancelledError):
        pass
    finally:
        writer.close()


async def handle(client_r, client_w, port):
    if state["delay"]:
        await asyncio.sleep(state["delay"])
    server_r, server_w = await asyncio.open_connection("127.0.0.1", port)
    pair = (client_w, server_w)
    conns.add(pair)
    try:
        await asyncio.gather(pipe(client_r, server_w, False, pair), pipe(server_r, client_w, True, pair))
    finally:
        conns.discard(pair)
        silent.discard(pair)


async def control(reader, writer):
    line = (await reader.readline()).decode(errors="replace")
    while (await reader.readline()) not in (b"\r\n", b"\n", b""):
        pass
    url = urlparse(line.split(" ")[1] if " " in line else "/")
    cmd = url.path.strip("/")
    if cmd == "delay":
        state["delay"] = float(parse_qs(url.query).get("s", ["0"])[0])
    elif cmd in ("wide/on", "wide/off"):
        state["wide"] = cmd == "wide/on"
    elif cmd == "silence":
        silent.update(conns)
    elif cmd == "resume":
        silent.clear()
    elif cmd == "drop":
        for c, s in list(conns):
            for w in (c, s):
                w.transport.abort()
    elif cmd == "reset":
        state.update(delay=0.0, wide=False)
        silent.clear()
    body = repr(state).encode()
    writer.write(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % (len(body), body))
    await writer.drain()
    writer.close()


async def main(listen, port, ctl):
    servers = [await asyncio.start_server(lambda r, w: handle(r, w, port), "127.0.0.1", listen)]
    if ctl:
        servers.append(await asyncio.start_server(control, "127.0.0.1", ctl))
    await asyncio.gather(*(s.serve_forever() for s in servers))


asyncio.run(main(int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]) if len(sys.argv) > 3 else 0))
