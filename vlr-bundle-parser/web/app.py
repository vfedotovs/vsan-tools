"""Web UI for vlr_sbp.sh.

Upload a VLR appliance support bundle (.zip, .tar.gz, .tgz or .tar, up to
1 GiB), run one or all parser sections on it, and download the report as
Markdown. Uploaded bundles are kept per job under DATA_DIR and removed after
JOB_TTL_MIN minutes, or when the user clicks "Delete bundle".
"""
import datetime
import json
import os
import re
import shutil
import subprocess
import tarfile
import time
import uuid
import zipfile
from pathlib import Path

from flask import Flask, abort, jsonify, render_template, request, send_file

GIB = 1024 ** 3
MAX_UPLOAD = int(os.environ.get("MAX_UPLOAD_BYTES", GIB))
MAX_EXTRACT = int(os.environ.get("MAX_EXTRACT_BYTES", 10 * GIB))  # zip bomb guard
JOB_TTL = int(os.environ.get("JOB_TTL_MIN", 120)) * 60
RUN_TIMEOUT = int(os.environ.get("RUN_TIMEOUT_SEC", 1800))
PARSER = os.environ.get("VLR_SBP", "/usr/local/bin/vlr_sbp.sh")
DATA_DIR = Path(os.environ.get("DATA_DIR", "/data"))
JOBS_DIR = DATA_DIR / "jobs"

SECTIONS = ["build", "network", "services", "endpoints", "topology",
            "certificates", "coverage", "health", "workflows"]
ARCHIVE_SUFFIXES = (".zip", ".tar.gz", ".tgz", ".tar")
JOB_ID_RE = re.compile(r"^[0-9a-f]{32}$")
RUN_ID_RE = re.compile(r"^[0-9]{8}-[0-9]{6}-[a-z,]+$")
DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")

app = Flask(__name__)
# multipart overhead on top of the file itself
app.config["MAX_CONTENT_LENGTH"] = MAX_UPLOAD + 1024 * 1024
JOBS_DIR.mkdir(parents=True, exist_ok=True)


class BundleError(Exception):
    pass


def cleanup_old_jobs():
    now = time.time()
    for d in JOBS_DIR.iterdir():
        if d.is_dir() and now - d.stat().st_mtime > JOB_TTL:
            shutil.rmtree(d, ignore_errors=True)


def job_dir(job_id):
    if not JOB_ID_RE.match(job_id):
        abort(404)
    d = JOBS_DIR / job_id
    if not d.is_dir():
        abort(404, "Bundle not found - it may have expired. Upload it again.")
    return d


def safe_extract_zip(archive, dest):
    with zipfile.ZipFile(archive) as zf:
        members = zf.infolist()
        if sum(m.file_size for m in members) > MAX_EXTRACT:
            raise BundleError("bundle expands to more than %d GiB" % (MAX_EXTRACT // GIB))
        for m in members:
            target = (dest / m.filename).resolve()
            if not target.is_relative_to(dest):
                raise BundleError("unsafe path in archive: %s" % m.filename)
        zf.extractall(dest)


def safe_extract_tar(archive, dest):
    with tarfile.open(archive) as tf:
        members = tf.getmembers()
        if sum(m.size for m in members if m.isfile()) > MAX_EXTRACT:
            raise BundleError("bundle expands to more than %d GiB" % (MAX_EXTRACT // GIB))
        # "data" filter rejects absolute paths, .. and links pointing outside dest
        tf.extractall(dest, filter="data")


def find_bundle_root(extracted):
    """The bundle root is the shallowest folder that holds var/ or opt/."""
    candidates = [extracted] + sorted(
        (p for p in extracted.rglob("*") if p.is_dir()),
        key=lambda p: len(p.parts))
    for p in candidates:
        if (p / "var").is_dir() or (p / "opt").is_dir():
            return p
    raise BundleError("no var/ or opt/ folder found - is this a VLR appliance support bundle?")


def bundle_size(path):
    return sum(f.stat().st_size for f in path.rglob("*") if f.is_file())


def fence_for(text):
    longest = max((len(m) for m in re.findall(r"`+", text)), default=0)
    return "`" * max(3, longest + 1)


def to_markdown(meta, args, stdout, stderr, rc, started):
    """Turn the parser's plain-text output into Markdown: each
    'Title' + '=====' pair becomes a heading, the body a text block."""
    lines = stdout.splitlines()
    blocks, title, body = [], None, []
    i = 0
    while i < len(lines):
        if i + 1 < len(lines) and lines[i].strip() and re.fullmatch(r"=+", lines[i + 1].strip()):
            if title or any(l.strip() for l in body):
                blocks.append((title, body))
            title, body = lines[i].strip(), []
            i += 2
            continue
        body.append(lines[i])
        i += 1
    if title or any(l.strip() for l in body):
        blocks.append((title, body))

    out = ["# VLR support bundle report", "",
           "| | |", "|---|---|",
           "| Bundle | `%s` |" % meta["filename"],
           "| Generated | %s UTC |" % started.strftime("%Y-%m-%d %H:%M:%S"),
           "| Command | `%s` |" % " ".join(["vlr_sbp.sh", *args, "<bundle>"]),
           "| Exit code | %d |" % rc, ""]
    for t, body in blocks:
        text = "\n".join(body).strip("\n")
        if t:
            out += ["## " + t, ""]
        if text:
            f = fence_for(text)
            out += [f + "text", text, f, ""]
    if stderr.strip():
        f = fence_for(stderr)
        out += ["## Warnings (stderr)", "", f + "text", stderr.rstrip(), f, ""]
    return "\n".join(out)


@app.errorhandler(413)
def too_large(_e):
    return jsonify(error="File is larger than %d MiB." % (MAX_UPLOAD // 1024 ** 2)), 413


@app.errorhandler(404)
def not_found(e):
    return jsonify(error=getattr(e, "description", "Not found")), 404


@app.get("/")
def index():
    return render_template("index.html", sections=SECTIONS,
                           max_upload_mb=MAX_UPLOAD // 1024 ** 2)


@app.get("/healthz")
def healthz():
    return "ok"


@app.post("/upload")
def upload():
    cleanup_old_jobs()
    f = request.files.get("bundle")
    if not f or not f.filename:
        return jsonify(error="No file selected."), 400
    name = os.path.basename(f.filename)
    if not name.lower().endswith(ARCHIVE_SUFFIXES):
        return jsonify(error="Upload a .zip, .tar.gz, .tgz or .tar support bundle."), 400

    job_id = uuid.uuid4().hex
    d = JOBS_DIR / job_id
    extracted = d / "bundle"
    extracted.mkdir(parents=True)
    archive = d / ("upload" + "".join(Path(name).suffixes[-2:]))
    try:
        f.save(archive)
        if zipfile.is_zipfile(archive):
            safe_extract_zip(archive, extracted.resolve())
        elif tarfile.is_tarfile(archive):
            safe_extract_tar(archive, extracted.resolve())
        else:
            raise BundleError("not a readable zip or tar archive")
        root = find_bundle_root(extracted)
    except (BundleError, zipfile.BadZipFile, tarfile.TarError, OSError) as e:
        shutil.rmtree(d, ignore_errors=True)
        return jsonify(error="Could not open bundle: %s" % e), 400
    finally:
        archive.unlink(missing_ok=True)

    meta = {"filename": name, "root": str(root.relative_to(d)),
            "size_mb": round(bundle_size(extracted) / 1024 ** 2, 1)}
    (d / "meta.json").write_text(json.dumps(meta))
    return jsonify(job=job_id, **meta)


@app.post("/jobs/<job_id>/run")
def run(job_id):
    d = job_dir(job_id)
    meta = json.loads((d / "meta.json").read_text())
    form = request.get_json(silent=True) or {}

    section = form.get("section", "all")
    if section != "all" and section not in SECTIONS:
        return jsonify(error="Unknown section."), 400
    args = [] if section == "all" else ["-s", section]
    for key, flag in (("from", "-f"), ("to", "-t")):
        v = (form.get(key) or "").strip()
        if v:
            if not DATE_RE.match(v):
                return jsonify(error="Dates must be YYYY-MM-DD."), 400
            args += [flag, v]
    log_re = (form.get("log") or "").strip()
    if log_re:
        args += ["-l", log_re]
    top = str(form.get("top") or "").strip()
    if top:
        if not top.isdigit() or int(top) < 1:
            return jsonify(error="Top N must be a positive number."), 400
        args += ["-n", top]
    if form.get("all_days"):
        args.append("-a")

    started = datetime.datetime.now(datetime.timezone.utc)
    try:
        p = subprocess.run([PARSER, *args, "--", str(d / meta["root"])],
                           capture_output=True, text=True, errors="replace",
                           timeout=RUN_TIMEOUT)
        stdout, stderr, rc = p.stdout, p.stderr, p.returncode
    except subprocess.TimeoutExpired:
        return jsonify(error="Parser timed out after %d s." % RUN_TIMEOUT), 504

    os.utime(d)  # keep the bundle alive while it is being used
    run_id = started.strftime("%Y%m%d-%H%M%S-") + section
    (d / (run_id + ".md")).write_text(to_markdown(meta, args, stdout, stderr, rc, started))
    return jsonify(run=run_id, rc=rc, stdout=stdout, stderr=stderr,
                   md_url="/jobs/%s/report/%s.md" % (job_id, run_id))


@app.get("/jobs/<job_id>/report/<run_id>.md")
def report(job_id, run_id):
    d = job_dir(job_id)
    if not RUN_ID_RE.match(run_id) or not (d / (run_id + ".md")).is_file():
        abort(404, "Report not found.")
    meta = json.loads((d / "meta.json").read_text())
    stem = re.sub(r"\.(zip|tar\.gz|tgz|tar)$", "", meta["filename"], flags=re.I)
    return send_file(d / (run_id + ".md"), mimetype="text/markdown",
                     as_attachment=True,
                     download_name="%s-%s.md" % (stem, run_id.split("-", 2)[2]))


@app.delete("/jobs/<job_id>")
def delete(job_id):
    shutil.rmtree(job_dir(job_id), ignore_errors=True)
    return jsonify(deleted=job_id)
