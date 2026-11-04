#!/usr/bin/env python3
"""Embed the reviewed device manager into the importable UFI-TOOLS plugin."""
import base64
from pathlib import Path
root = Path(__file__).resolve().parent.parent
folder = root / "integrations/ufi-tools"
template = (folder / "ashbell-manager.template.html").read_text()
encoded = base64.b64encode((root / "scripts/ashbell-devui.sh").read_bytes()).decode()
content = template.replace("__ASHBELL_MANAGER_BASE64__", encoded)
(folder / "Ashbell桌面管理.html").write_text(content)
(folder / "ashbell-desktop-manager.js").write_text(content)
(folder / "Ashbell桌面管理.txt").write_text(content)
print("Generated integrations/ufi-tools/Ashbell桌面管理.html")
