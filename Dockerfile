FROM mambaorg/micromamba:1.5.6

COPY environment.yml /tmp/environment.yml
RUN micromamba create -n env -f /tmp/environment.yml && \
    micromamba clean --all --yes

ENV PATH=/opt/conda/envs/env/bin:$PATH
