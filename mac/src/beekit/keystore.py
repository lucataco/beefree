"""Per-device pairing tokens, stored locally (default ~/.config/beekit/secrets.json, mode 0600).

The token holds the audio key, so it lives outside the project tree and never gets committed.
"""

from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass
from pathlib import Path

from .protocol import SealedToken

DEFAULT_PATH = Path(os.environ.get("BEEKIT_SECRETS", "~/.config/beekit/secrets.json")).expanduser()


@dataclass(frozen=True)
class DeviceSecret:
    token: SealedToken
    source: str
    saved_at: str


def load_all(path: Path = DEFAULT_PATH) -> dict[str, DeviceSecret]:
    if not path.exists():
        return {}
    devices = json.loads(path.read_text()).get("devices", {})
    return {
        device_id: DeviceSecret(SealedToken.parse(bytes.fromhex(d["token_hex"])), d["source"], d["saved_at"])
        for device_id, d in devices.items()
    }


def load(device_id: str, path: Path = DEFAULT_PATH) -> DeviceSecret | None:
    return load_all(path).get(device_id)


def save(token: SealedToken, source: str, path: Path = DEFAULT_PATH) -> Path:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    data = json.loads(path.read_text()) if path.exists() else {"devices": {}}
    data["devices"][token.device_id] = {
        "token_hex": token.raw.hex(),
        "source": source,
        "saved_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    }
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2)
    os.chmod(path, 0o600)
    return path
