"""Run in a dedicated venv; export the versioned official YOLO11n checkpoint."""
from pathlib import Path
import shutil
from ultralytics import YOLO

root = Path(__file__).resolve().parents[1]
destination = root / "ISeeYou" / "Models" / "yolo11n.mlpackage"
if destination.exists():
    raise SystemExit(f"Refusing to overwrite {destination}; move it outside the repo before exporting.")
checkpoint = root / "models" / "yolo11n.pt"
output = Path(YOLO(str(checkpoint)).export(format="coreml", imgsz=640, nms=True, half=True))
shutil.copytree(output, destination)
print(f"Exported {destination}. Xcode compiles this package during the next build.")
