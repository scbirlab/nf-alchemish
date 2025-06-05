FROM mambaorg/micromamba:1.5.6

ENV HOME=/home/micromamba
WORKDIR /home/micromamba
RUN mkdir -p $HOME
ENV MAMBA_ROOT_PREFIX=/opt/conda

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    gcc \
    g++ \
    && rm -rf /var/lib/apt/lists/*
USER 1000

COPY environment.yml /tmp/environment.yml
RUN micromamba create -n env -f /tmp/environment.yml && \
    micromamba clean --all --yes

ENV PATH=/opt/conda/envs/env/bin:$PATH
