"""Run in a dedicated venv; downloads official YOLO11n weights, then exports Core ML."""
from pathlib import Path
import shutil
from ultralytics import YOLO

output = Path(YOLO("yolo11n.pt").export(format="coreml", imgsz=640, nms=True, half=True))
destination = Path(__file__).resolve().parents[1] / "ISeeYou" / "Models" / "yolo11n.mlpackage"
if destination.exists():
    raise SystemExit(f"Refusing to overwrite {destination}")
shutil.copytree(output, destination)
print(f"Exported {destination}. Regenerate the Xcode project with xcodegen generate.")
