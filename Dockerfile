# Minimal Linux build of EditorLean. This file contains NO download locations:
# the person building supplies every source (and, optionally, its SHA-256),
# taken from the upstream projects themselves. The build stops if one is missing.
#
#   docker build -t editorlean-build \
#     --build-arg BASE_IMAGE=<Debian 12 image> \
#     --build-arg LEAN_URL=<Lean 4.35.0-rc3 linux .tar.zst>  [--build-arg LEAN_SHA256=<sha256>] \
#     --build-arg TCL_URL=<tcl9.0.4-src.tar.gz>             [--build-arg TCL_SHA256=<sha256>] \
#     --build-arg TK_URL=<tk9.0.4-src.tar.gz>               [--build-arg TK_SHA256=<sha256>] \
#     .
#   id=$(docker create editorlean-build)
#   docker cp "$id":/src/dist/EditorLean-linux-x86_64.tar.gz .
#   docker rm "$id"
#
# Versions the sources expect: Lean 4.35.0-rc3, Tcl 9.0.4, Tk 9.0.4, Debian 12.
#
# Stages: `toolchain` holds Lean and Tcl/Tk but no EditorLean source; the last
# stage builds EditorLean on top of it. VeriStore builds `--target toolchain`,
# publishes that image by digest, and runs build.py in it on a git checkout
# (see veriapps.toml), so anyone can repeat the build in the same environment.

ARG BASE_IMAGE
FROM ${BASE_IMAGE:?set_--build-arg_BASE_IMAGE} AS toolchain

# 1. Build tools and X11 headers, from the base image's own package sources.
RUN apt-get update && apt-get install -y \
    curl ca-certificates zstd gcc make python3 libx11-dev libxft-dev

# Download "$1" to file "$2"; verify against "$3" when a checksum was given.
RUN printf '%s\n' '#!/bin/sh' 'set -eu' \
      '[ -n "$1" ] || { echo "missing source URL for $2 (pass --build-arg)"; exit 1; }' \
      'curl -sSfL -o "$2" "$1"' \
      'if [ -n "${3:-}" ]; then echo "$3  $2" | sha256sum -c; else echo "WARNING: $2 not checksum-verified"; fi' \
      > /usr/local/bin/fetch && chmod +x /usr/local/bin/fetch

# 2. Lean toolchain, unpacked to /opt/lean.
ARG LEAN_URL
ARG LEAN_SHA256
RUN fetch "$LEAN_URL" /tmp/lean.tar.zst "$LEAN_SHA256" \
 && mkdir /opt/lean && tar --zstd -xf /tmp/lean.tar.zst -C /opt/lean --strip-components=1 \
 && /opt/lean/bin/lean --version

# 3. Tcl/Tk from source, installed into /opt/tcltk.
ARG TCL_URL
ARG TCL_SHA256
ARG TK_URL
ARG TK_SHA256
WORKDIR /tmp
RUN fetch "$TCL_URL" tcl.tar.gz "$TCL_SHA256" && fetch "$TK_URL" tk.tar.gz "$TK_SHA256" \
 && mkdir tcl tk && tar -xzf tcl.tar.gz -C tcl --strip-components=1 && tar -xzf tk.tar.gz -C tk --strip-components=1
RUN rm -rf tcl/pkgs/* \
 && cd tcl/unix \
 && ./configure --prefix=/opt/tcltk --disable-zipfs --without-system-libtommath \
 && make && make install
RUN cd tk/unix \
 && ./configure --prefix=/opt/tcltk --with-tcl=/opt/tcltk/lib --disable-zipfs --enable-xft \
 && make && make install

# 4. Build EditorLean; build.py also runs the native self-tests.
FROM toolchain AS editorlean
WORKDIR /src
COPY editor_lean/ editor_lean/
RUN python3 editor_lean/build.py --toolchain /opt/lean --tk-bundle /opt/tcltk
