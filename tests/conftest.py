import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
LITELLM = REPO / "shared" / "litellm"
SCRIPTS = LITELLM / "scripts"
for p in (str(SCRIPTS), str(LITELLM)):
    if p not in sys.path:
        sys.path.insert(0, p)


def pytest_configure(config):
    # Test categories for the Windows installer work (docs/specs/windows-package.md).
    for name, text in (("spec", "example-based tests written from the spec"),
                       ("property", "property-based (Hypothesis) tests"),
                       ("metamorphic", "metamorphic relations between runs")):
        config.addinivalue_line("markers", f"{name}: {text}")
