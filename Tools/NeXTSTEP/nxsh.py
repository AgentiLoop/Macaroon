#!/usr/bin/env python3
# Runs a shell script in NeXTSTEP (Previous emulator) from the Mac, as user "me", and prints what it printed:
#   ./nxsh.py [-t seconds] 'cc -v; ls /NextDeveloper'
# The script goes through the shared folder (~/Previous/Shared, /Net/nfs in NeXTSTEP) and is started over
# Previous' telnet redirect (localhost:42323), so NeXTSTEP has to be booted with its network up.
# Exit status: the script's, or 124 when it didn't finish in time (default 120 seconds).
import os, re, socket, sys, time

SHARED = os.path.expanduser("~/Previous/Shared/.nxsh")


def run(script, timeout=120):
    os.makedirs(SHARED, exist_ok=True)
    out = SHARED + "/out"
    with open(SHARED + "/run", "w") as file:
        file.write(script + "\n")
    with open(out, "w"):
        pass
    connection = socket.create_connection(("127.0.0.1", 42323), timeout=10)
    connection.settimeout(1)

    def read(seconds, until):
        end, text = time.time() + seconds, b""
        while time.time() < end and not re.search(until, text):
            try:
                data = connection.recv(4096)
            except socket.timeout:
                continue
            if not data:
                break
            # telnet options: refuse all but echo and suppress-go-ahead from the other side
            for command, option in re.findall(rb"\xff([\xfb\xfd])(.)", data, re.S):
                answer = 252 if command == b"\xfd" else 253 if option in b"\x01\x03" else 254
                connection.sendall(bytes([255, answer]) + option)
            text += re.sub(rb"\xff[\xfb-\xfe].", b"", data, flags=re.S)
        return re.search(until, text)

    try:
        if not read(30, rb"login: ?$"):
            return 124
        connection.sendall(b"me\r")
        read(40, rb"[>%#] ?$")
        connection.sendall(b"sh /Net/nfs/.nxsh/run >& /Net/nfs/.nxsh/out; echo END=$status\r")   # csh
        end = read(timeout, rb"END=(-?\d+)")
    finally:
        connection.close()
    with open(out, errors="replace") as file:
        sys.stdout.write(file.read())
    return int(end[1]) & 255 if end else 124


if __name__ == "__main__":
    arguments = sys.argv[1:]
    seconds = 120
    if arguments[:1] == ["-t"]:
        seconds, arguments = float(arguments[1]), arguments[2:]
    sys.exit(run(" ".join(arguments), seconds))
