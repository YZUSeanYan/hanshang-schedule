"""Strict validation and path handling for About-page media uploads."""
import os
import re
from pathlib import Path

from fastapi import HTTPException

from app.core.config import get_settings

MAX_MEDIA_BYTES = 5 * 1024 * 1024
_SAFE_NAME = re.compile(r"^[0-9a-f]{32}\.(?:png|jpg|webp)$")


def media_directory(subdir: str = "about") -> Path:
    # 子目录白名单：防路径穿越（avatars 是用户头像目录）
    if subdir not in ("about", "avatars"):
        raise ValueError("unknown media subdir")
    path = Path(get_settings().uploads_dir).resolve() / subdir
    path.mkdir(parents=True, exist_ok=True)
    return path


def media_path(name: str, subdir: str = "about") -> Path:
    if not _SAFE_NAME.fullmatch(name):
        raise HTTPException(status_code=404, detail={"code": 40420, "message": "图片不存在"})
    root = media_directory(subdir)
    path = (root / name).resolve()
    if path.parent != root:
        raise HTTPException(status_code=404, detail={"code": 40420, "message": "图片不存在"})
    return path


def detect_extension(data: bytes) -> str:
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "png"
    if data.startswith(b"\xff\xd8\xff"):
        return "jpg"
    if len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "webp"
    raise HTTPException(
        status_code=415,
        detail={"code": 41520, "message": "只支持真实的 PNG、JPEG 或 WebP 图片"},
    )


def persist_media(data: bytes, extension: str, subdir: str = "about") -> str:
    import secrets

    name = f"{secrets.token_hex(16)}.{extension}"
    target = media_path(name, subdir)
    temporary = target.with_suffix(target.suffix + ".tmp")
    temporary.write_bytes(data)
    os.replace(temporary, target)
    return name
