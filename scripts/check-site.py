#!/usr/bin/env python3
"""Check the buildless GitHub Pages site without third-party dependencies.

Run: python3 scripts/check-site.py
These checks read local files only. Browser interaction and visual review remain
separate checks; no request is made to linked websites.
"""

import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import struct
import sys
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / "site"
MAX_SITE_BYTES = 2_000_000
FILE_BUDGETS = {"index.html": 100_000, "styles.css": 40_000, "app.js": 50_000}


class CheckFailure(Exception):
    pass


def require(condition, message):
    if not condition:
        raise CheckFailure(message)


class Document(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.elements = []
        self.ids = set()
        self.errors = []

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        self.elements.append((tag, attrs))
        if "id" in attrs:
            if not attrs["id"] or attrs["id"] in self.ids:
                self.errors.append("Empty or duplicate element ID: " + str(attrs["id"]))
            self.ids.add(attrs["id"])

    handle_startendtag = handle_starttag


def local_file(value, source, *, resource=False):
    """Resolve a URL as the browser would beneath a project Pages prefix."""
    require(bool(value), f"Empty URL in {source.relative_to(SITE)}")
    parsed = urlsplit(value)
    if parsed.scheme or parsed.netloc:
        if resource and parsed.scheme == "data" and value.startswith("data:image/"):
            return None
        require(not resource, f"External runtime resource: {value}")
        require(parsed.scheme in {"https", "mailto"}, f"Unsupported link scheme: {value}")
        require(parsed.scheme != "https" or bool(parsed.netloc), f"Missing HTTPS host: {value}")
        return None
    require(not parsed.path.startswith("/"), f"Root-relative URL breaks project Pages: {value}")
    path = (source.parent / unquote(parsed.path)).resolve() if parsed.path else source.resolve()
    require(path.is_relative_to(SITE.resolve()), f"URL escapes the published directory: {value}")
    if path.is_dir():
        path /= "index.html"
    require(path.is_file(), f"Missing local target: {value} (from {source.name})")
    if path.suffix.lower() == ".html" and parsed.fragment:
        document = Document()
        document.feed(path.read_text(encoding="utf-8"))
        require(unquote(parsed.fragment) in document.ids, f"Missing fragment: {value}")
    return path


def image_manifest():
    directory = SITE / "assets/images"
    manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    require(manifest.get("version") == 1, "Unknown image manifest version")
    variants = {}
    for image in manifest["images"]:
        source = (ROOT / image["source"]).resolve()
        require(source.is_relative_to((ROOT / "docs/assets").resolve()), "Image source escapes docs/assets")
        original = image["original"]
        data = source.read_bytes()
        require(len(data) == original["bytes"] and hashlib.sha256(data).hexdigest() == original["sha256"],
                f"Source image changed; regenerate WebP assets: {image['source']}")
        require(data[:8] == b"\x89PNG\r\n\x1a\n" and len(data) >= 24, f"Invalid source PNG: {source.name}")
        require(struct.unpack(">II", data[16:24]) == (original["width"], original["height"]),
                f"Source dimensions do not match manifest: {source.name}")
        widths = []
        for variant in image["variants"]:
            name = variant["file"]
            require(Path(name).name == name and name.endswith(".webp"), f"Invalid WebP filename: {name}")
            path = directory / name
            require(path not in variants, f"Duplicate image variant: {name}")
            encoded = path.read_bytes()
            require(len(encoded) == variant["bytes"] and hashlib.sha256(encoded).hexdigest() == variant["sha256"],
                    f"WebP bytes do not match manifest: {name}")
            require(len(encoded) >= 20 and encoded[:4] == b"RIFF" and encoded[8:12] == b"WEBP"
                    and int.from_bytes(encoded[4:8], "little") == len(encoded) - 8, f"Invalid WebP container: {name}")
            width, height = variant["width"], variant["height"]
            require(0 < width <= original["width"] and height == round(original["height"] * width / original["width"]),
                    f"Upscaled or distorted image dimensions: {name}")
            variants[path.resolve()] = variant
            widths.append(width)
        require(widths == sorted(set(widths)) and len(widths) >= 2, f"Missing responsive variants: {image['key']}")
    require(set(directory.glob("*.webp")) == set(variants), "Unlisted or missing WebP assets")
    cover = directory / "cover-1280.webp"
    require(cover.stat().st_size <= 250_000, "The 1280px cover exceeds its 250 KB budget")
    return variants


def check_html(variants):
    path = SITE / "index.html"
    document = Document()
    document.feed(path.read_text(encoding="utf-8"))
    require(not document.errors, "; ".join(document.errors))
    require(any(tag == "html" and attrs.get("lang") in {"zh-CN", "en"} for tag, attrs in document.elements),
            "Set an initial document language")
    require(sum(tag == "h1" for tag, _ in document.elements) == 1, "The page needs one primary heading")
    images, translations, heroes = 0, 0, 0
    for tag, attrs in document.elements:
        require(tag != "base", "A base URL can break the project Pages subpath")
        if "data-en" in attrs:
            require(bool(attrs["data-en"] and attrs["data-en"].strip()), "Empty English translation")
            translations += 1
        if "data-zh" in attrs:
            require(bool(attrs["data-zh"] and attrs["data-zh"].strip()), "Empty Chinese translation")
        if "href" in attrs:
            runtime = tag in {"link", "use"} and attrs.get("rel") != "canonical"
            local_file(attrs["href"], path, resource=runtime)
        for attribute in ("src", "poster", "data-full"):
            if attrs.get(attribute):
                target = local_file(attrs[attribute], path, resource=True)
                require(target is None or target.suffix.lower() != ".png", "Use optimized images instead of source PNGs")
        if tag == "script" and "src" not in attrs:
            require(attrs.get("type") == "application/ld+json", "Keep executable JavaScript in a local deferred file")
        if tag == "script" and "src" in attrs:
            require("defer" in attrs or attrs.get("type") == "module", "Page scripts must not block HTML parsing")
        if tag not in {"img", "source"}:
            continue
        if tag == "img" and not attrs.get("src"):
            require(attrs.get("id"), "A deferred dialog image needs an ID")
            continue
        if tag == "img":
            images += 1
            require("alt" in attrs, "Image alternative text is missing")
            require(all(str(attrs.get(k, "")).isdigit() and int(attrs[k]) > 0 for k in ("width", "height")),
                    "Images must reserve width and height to avoid layout shifts")
            if attrs.get("fetchpriority") == "high":
                heroes += 1
                require(attrs.get("loading") != "lazy", "Do not lazy-load the hero image")
            else:
                require(attrs.get("loading") == "lazy", "Below-fold images should load lazily")
        if attrs.get("srcset"):
            require(bool(attrs.get("sizes")), "A width-based srcset needs sizes")
            widths = []
            for item in attrs["srcset"].split(","):
                parts = item.strip().split()
                require(len(parts) == 2 and re.fullmatch(r"[1-9]\d*w", parts[1]), "Use valid width descriptors in srcset")
                target = local_file(parts[0], path, resource=True)
                width = int(parts[1][:-1])
                require(target in variants and variants[target]["width"] == width, f"Incorrect srcset width: {item.strip()}")
                widths.append(width)
            require(widths == sorted(set(widths)) and len(widths) >= 2, "Provide distinct, ordered responsive image widths")
        elif tag == "img":
            raise CheckFailure("Visible images need responsive srcset and sizes")
    require(images >= 2 and heroes == 1, "Provide one high-priority hero plus lazy screenshot previews")
    require(translations > 0, "Bilingual content is missing")
    return images, translations


def check_styles():
    for path in SITE.rglob("*.css"):
        text = path.read_text(encoding="utf-8")
        require(not re.search(r"@import\b", text, re.IGNORECASE), "Do not add a render-blocking CSS import")
        for match in re.finditer(r"url\(\s*(['\"]?)(.*?)\1\s*\)", text):
            local_file(match.group(2), path, resource=True)


def main():
    require(SITE.is_dir(), "site/ does not exist")
    for path in SITE.rglob("*"):
        require(not path.is_symlink(), f"Published symlink is not allowed: {path.relative_to(SITE)}")
    for name, budget in FILE_BUDGETS.items():
        path = SITE / name
        require(path.is_file() and path.stat().st_size <= budget, f"Missing {name} or exceeds {budget:,}-byte budget")
    size = sum(path.stat().st_size for path in SITE.rglob("*") if path.is_file())
    require(size <= MAX_SITE_BYTES, f"Published directory is {size:,} bytes; budget is {MAX_SITE_BYTES:,}")
    variants = image_manifest()
    images, translations = check_html(variants)
    check_styles()
    print(f"PASS: {images} responsive images, {len(variants)} verified WebP variants, {translations} English translations")
    print(f"PASS: local resources, fragments, image loading hints and Pages-relative paths")
    print(f"PASS: published directory {size:,} / {MAX_SITE_BYTES:,} bytes; no third-party dependencies needed for checks")


if __name__ == "__main__":
    try:
        main()
    except (CheckFailure, OSError, KeyError, TypeError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
