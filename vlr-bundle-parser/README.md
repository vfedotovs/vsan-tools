# VLR Bundle Parser – web UI

A small web page around `vlr_sbp.sh` (the `vlr_sbp-beta-rc2.sh` release candidate) for VMware Live Recovery 9.0.3–9.0.5 appliance support bundles:

1. **Upload** a support bundle (`.zip`, `.tar.gz`, `.tgz` or `.tar`, up to 1 GiB). A progress bar shows while it uploads, then the server extracts it.
2. **Run** the parser with one button per section (`build`, `network`, `services`, `endpoints`, `topology`, `certificates`, `coverage`, `health`, `workflows`) or **Run all sections**. The optional From/To date, log path regex, Top N and All days fields map to the script's `-f`, `-t`, `-l`, `-n` and `-a` flags.
3. **Download .md**: the report as Markdown. Each section becomes a `##` heading with its output in a text block, and parser warnings (stderr) go at the end.

See [how_to_use.md](../how_to_use.md) for what each section reports.

## Run it

Using the published image (public, linux/amd64 and linux/arm64), from either registry:

```bash
docker run --rm -p 8080:8080 vfedotovsdocker/vlr-bundle-parser:latest     # Docker Hub
docker run --rm -p 8080:8080 ghcr.io/vfedotovs/vlr-bundle-parser:latest   # GitHub Container Registry
# open http://localhost:8080
```

To build it yourself, run this from the folder that holds `vlr_sbp-beta-rc2.sh`:

```bash
docker build -f web/Dockerfile -t vlr-sbp-web .
docker run --rm -p 8080:8080 vlr-sbp-web
```

To use a different parser version, add `--build-arg SCRIPT=vlr_sbp-beta-rc1.sh`.

## Data handling

- The image contains **no support bundles**. Uploaded bundles are extracted to `/data/jobs/<random id>/` inside the container.
- A bundle and its reports are deleted after `JOB_TTL_MIN` minutes (120 by default) or when you click **Delete bundle**. Stopping a `--rm` container removes everything.
- There is no login. Run it on your own machine or on a trusted network, and don't expose it to the internet.

## Settings (environment variables)

| Variable | Default | Meaning |
|---|---|---|
| `MAX_UPLOAD_BYTES` | `1073741824` (1 GiB) | largest accepted upload |
| `MAX_EXTRACT_BYTES` | `10737418240` (10 GiB) | refuse archives that expand to more than this |
| `JOB_TTL_MIN` | `120` | minutes before an unused bundle is deleted |
| `RUN_TIMEOUT_SEC` | `1800` | longest a single parser run may take |
