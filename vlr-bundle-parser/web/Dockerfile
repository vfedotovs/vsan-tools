# Web UI for vlr_sbp.sh. Build from the rc-scripts folder:
#   docker build -f web/Dockerfile -t vlr-sbp-web .
#   docker run --rm -p 8080:8080 vlr-sbp-web      # then open http://localhost:8080
# No support bundle is baked in: bundles are uploaded at run time.
FROM fedora:44

ARG SCRIPT=vlr_sbp-beta-rc2.sh

# Parser tools (grep sed awk sort uniq column xargs zcat cksum openssl) + the web app
RUN dnf -y install \
        bash coreutils grep sed gawk findutils util-linux gzip openssl \
        python3 python3-flask python3-gunicorn \
    && dnf clean all

COPY --chmod=0755 ${SCRIPT} /usr/local/bin/vlr_sbp.sh
COPY web/app.py /app/app.py
COPY web/templates /app/templates

RUN useradd --system --create-home --home-dir /data vlr
USER vlr
WORKDIR /app
ENV DATA_DIR=/data TMPDIR=/data
EXPOSE 8080
VOLUME /data

# gthread workers so a long upload or parse doesn't trip the worker timeout.
# One worker: jobs live on disk, but one process keeps cleanup simple.
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "1", "--worker-class", "gthread", \
     "--threads", "8", "--timeout", "0", "--access-logfile", "-", "app:app"]
