import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
LITELLM = REPO / "shared" / "litellm"
SCRIPTS = LITELLM / "scripts"
for p in (str(SCRIPTS), str(LITELLM)):
    if p not in sys.path:
        sys.path.insert(0, p)
