"""Create SageMaker's required deterministic .tar.gz script-mode source bundle."""
import base64
import gzip
import hashlib
import json
import pathlib
import sys
import tarfile


module = pathlib.Path(__file__).parent
training = module / "training"
output = module / ".terraform" / "training-code.tar.gz"
request = json.load(sys.stdin)
files = sorted(path for path in training.rglob("*") if path.is_file())
source_hash = hashlib.sha256("".join(
    hashlib.sha256(path.read_bytes()).hexdigest() for path in files
).encode()).hexdigest()
if source_hash != request.get("source_hash"):
    raise SystemExit("training source changed while packaging")
output.parent.mkdir(parents=True, exist_ok=True)
with output.open("wb") as compressed:
    with gzip.GzipFile(fileobj=compressed, mode="wb", filename="", mtime=0, compresslevel=9) as gzip_stream:
        with tarfile.open(fileobj=gzip_stream, mode="w") as archive:
            for path in files:
                info = archive.gettarinfo(str(path), arcname=path.relative_to(training).as_posix())
                info.mtime = 0
                info.uid = info.gid = 0
                info.uname = info.gname = ""
                with path.open("rb") as stream:
                    archive.addfile(info, stream)
digest = base64.b64encode(hashlib.sha256(output.read_bytes()).digest()).decode()
json.dump({"path": str(output), "sha256": digest}, sys.stdout)
