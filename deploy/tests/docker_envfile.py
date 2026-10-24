#!/usr/bin/env python3
"""Read a file the way `docker run --env-file` does and print one variable.

A port of parseKeyValueFile() in docker/cli (opts/file.go): leading
whitespace is trimmed, blank lines and lines starting with '#' are skipped,
the line is split at the first '=', and the value is taken literally (no
quote removal, no escapes, no variable expansion). A line with only a name
takes the value from the caller's environment.

Usage: docker_envfile.py <file> <NAME>     exits 1 if NAME is not set
"""
import os
import sys

WHITESPACE = " \t"


def parse(path):
    out = {}
    with open(path, "rb") as fh:
        data = fh.read()
    for n, raw in enumerate(data.split(b"\n")):
        if raw.endswith(b"\r"):            # bufio.ScanLines drops a trailing \r
            raw = raw[:-1]
        if n == 0 and raw.startswith(b"\xef\xbb\xbf"):
            raw = raw[3:]
        line = raw.decode("utf-8").lstrip()   # strings.TrimLeftFunc(unicode.IsSpace)
        if not line or line.startswith("#"):
            continue
        name, sep, value = line.partition("=")
        name = name.lstrip(WHITESPACE)
        if any(c in name for c in WHITESPACE):
            raise ValueError("variable %r contains whitespaces" % name)
        if not name:
            raise ValueError("no variable name on line %d" % (n + 1))
        if sep:
            out[name] = value
        elif name in os.environ:
            out[name] = os.environ[name]
    return out


if __name__ == "__main__":
    env = parse(sys.argv[1])
    if sys.argv[2] not in env:
        sys.exit(1)
    sys.stdout.write(env[sys.argv[2]])
