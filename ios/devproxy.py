#!/usr/bin/env python3
"""For the gesture test (ios/build.sh uitest): passes a dev voxl started with --read-only through, but tells the
page it may send input, so the test log shows what the app's gestures and keys send. The read-only voxl still
drops all of it, so nothing reaches the desktop.

  ios/devproxy.py LISTEN_PORT VOXL_PORT      e.g. 6918 6908 (both on 127.0.0.1)
"""
import asyncio
import sys

# voxl's hello says "readOnly":true for a read-only server; null keeps the frame's length.
FIND, PUT = b'"readOnly":true', b'"readOnly":null'


async def pipe(reader, writer, rewrite):
    try:
        while data := await reader.read(65536):
            writer.write(data.replace(FIND, PUT) if rewrite else data)
            await writer.drain()
    except ConnectionError:
        pass
    finally:
        writer.close()


async def handle(client_r, client_w, port):
    server_r, server_w = await asyncio.open_connection("127.0.0.1", port)
    await asyncio.gather(pipe(client_r, server_w, False), pipe(server_r, client_w, True))


async def main(listen, port):
    server = await asyncio.start_server(lambda r, w: handle(r, w, port), "127.0.0.1", listen)
    async with server:
        await server.serve_forever()


asyncio.run(main(int(sys.argv[1]), int(sys.argv[2])))
