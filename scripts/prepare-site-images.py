#!/usr/bin/env python3
"""Generate the website's responsive WebP assets; keep the source PNGs intact.

Run from any directory with Python 3 and Pillow with WebP support:
    python3 scripts/prepare-site-images.py

The allowlist and output directory are fixed. Screenshot encoding is lossless;
cover artwork uses quality 82. Resizing keeps the aspect ratio and alpha channel.
"""

import hashlib
import io
import json
from pathlib import Path

from PIL import Image, __version__ as pillow_version, features


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "site/assets/images"
SOURCES = (
    ("cover", "docs/assets/catunnel-cover-v1.png", (640, 1280, 1920), False),
    ("menu-panel", "docs/assets/screenshots/menu-panel.png", (320, 640), True),
    ("settings", "docs/assets/screenshots/settings.png", (320, 640), True),
    ("server-editor", "docs/assets/screenshots/server-editor.png", (320, 640, 960), True),
    ("getting-started", "docs/assets/screenshots/getting-started.png", (320, 640, 960), True),
)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def write_asset(name, data):
    path = OUTPUT / name
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise RuntimeError(f"Refusing non-file output: {path.relative_to(ROOT)}")
    path.write_bytes(data)


def main():
    if not features.check("webp"):
        raise RuntimeError("Pillow must include WebP support to generate website images.")
    for part in (ROOT / "site", ROOT / "site/assets", OUTPUT):
        if part.is_symlink():
            raise RuntimeError(f"Refusing symlink output directory: {part.relative_to(ROOT)}")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    manifest = {
        "version": 1,
        "generator": "python3 scripts/prepare-site-images.py",
        "encoder": {"pillow": pillow_version, "libwebp": features.version("webp")},
        "images": [],
    }
    for key, relative_source, widths, lossless in SOURCES:
        source = ROOT / relative_source
        original = source.read_bytes()
        with Image.open(io.BytesIO(original)) as loaded:
            loaded.load()
            icc_profile = loaded.info.get("icc_profile")
            image = loaded.convert("RGBA" if "A" in loaded.getbands() else "RGB")
        source_alpha = image.convert("RGBA").getchannel("A").getextrema()
        entry = {
            "key": key,
            "source": relative_source,
            "original": {
                "width": image.width, "height": image.height, "bytes": len(original),
                "sha256": sha256(original), "hasTransparency": source_alpha[0] < 255,
            },
            "encoding": {
                "format": "WebP", "lossless": lossless, "method": 6,
                "sourceColorProfilePreserved": bool(icc_profile),
            },
            "variants": [],
        }
        if not lossless:
            entry["encoding"]["quality"] = 82
        for width in widths:
            if width > image.width:
                continue
            height = round(image.height * width / image.width)
            resized = image.resize((width, height), Image.Resampling.LANCZOS)
            output = io.BytesIO()
            options = {"lossless": lossless, "method": 6, "exact": True}
            if icc_profile:
                options["icc_profile"] = icc_profile
            if not lossless:
                options["quality"] = 82
            resized.save(output, format="WEBP", **options)
            encoded = output.getvalue()
            with Image.open(io.BytesIO(encoded)) as decoded:
                decoded.load()
                assert decoded.size == resized.size, "Encoded dimensions changed"
                assert decoded.info.get("icc_profile") == icc_profile, "Color profile changed"
                assert decoded.convert("RGBA").getchannel("A").tobytes() == resized.convert("RGBA").getchannel("A").tobytes(), "Alpha channel changed"
                if lossless:
                    assert decoded.convert("RGBA").tobytes() == resized.convert("RGBA").tobytes(), "Screenshot encoding lost pixels"
            name = f"{key}-{width}.webp"
            write_asset(name, encoded)
            entry["variants"].append({
                "file": name, "width": width, "height": height, "bytes": len(encoded),
                "sha256": sha256(encoded),
                "reductionPercent": round(100 * (1 - len(encoded) / len(original)), 2),
            })
            print(f"{name}: {width} x {height}, {len(encoded):,} bytes")
        assert source.read_bytes() == original, "Source image changed"
        manifest["images"].append(entry)
    write_asset("manifest.json", (json.dumps(manifest, indent=2) + "\n").encode("utf-8"))


if __name__ == "__main__":
    main()
