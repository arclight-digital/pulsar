# Render environment for assets/shaders/pulsar.frag.
#
# Pinned to python 3.12 on purpose: moderngl's glcontext extension has no
# wheels for 3.14 and fails to build there, which is what the Fedora toolbox
# ships. libgl-dev is not a mistake either -- glcontext dlopens the
# UNVERSIONED libGL.so, and Debian only ships libGL.so.1 in the runtime
# package, so without the -dev package the EGL context dies with
# "libGL.so not loaded".
#
# Mesa's llvmpipe does the rasterising; no GPU is involved, which is why this
# works identically on a CI runner and on a laptop.
FROM docker.io/library/python:3.12-slim

RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends \
      libegl1 libgl1 libgl-dev libgl1-mesa-dri libglvnd0 && \
    rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir moderngl numpy pillow

WORKDIR /repo
ENTRYPOINT ["python3", "scripts/render-wallpapers.py"]
