"""Create the pinned Noto Sans TC static UI weights used by Flutter.

Flutter 3.35 does not select a variable font's wght axis from fontWeight. Static
instances let ordinary TextStyle.copyWith(fontWeight=...) select real outlines.
Obtain the two inputs from SOURCE_URL and LICENSE_URL below, then run this file
with --source-font and --license-file. Requires fontTools 4.59.1.
"""

import argparse
import hashlib
import json
from pathlib import Path

import fontTools
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont


SOURCE_COMMIT = "3be1884c48c3e45b52ecc725676a08f87776373e"
SOURCE_URL = (
    f"https://raw.githubusercontent.com/google/fonts/{SOURCE_COMMIT}"
    "/ofl/notosanstc/NotoSansTC%5Bwght%5D.ttf"
)
LICENSE_URL = (
    f"https://raw.githubusercontent.com/google/fonts/{SOURCE_COMMIT}"
    "/ofl/notosanstc/OFL.txt"
)
SOURCE_SHA256 = "864727d210d54f2537bbe23b3a839436c3992af72de9322af5270897246bd44f"
LICENSE_SHA256 = "1c05c68c34f9708415aada51f17e1b0092d2cea709bf4a94cd38114f9e73d7d9"
FONTTOOLS_VERSION = "4.59.1"
WEIGHTS = {400: "Regular", 500: "Medium", 600: "SemiBold", 700: "Bold"}


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def checked_input(path, expected):
    if sha256(path) != expected:
        raise ValueError(f"Input does not match its pinned source: {path.name}")


def generate(source_font, license_file, output_directory):
    if fontTools.__version__ != FONTTOOLS_VERSION:
        raise RuntimeError(f"Use fontTools {FONTTOOLS_VERSION} for reproducible output")
    checked_input(source_font, SOURCE_SHA256)
    checked_input(license_file, LICENSE_SHA256)
    output_directory.mkdir(parents=True, exist_ok=True)
    (output_directory / "OFL.txt").write_bytes(license_file.read_bytes())
    derived = {}
    for weight, style in WEIGHTS.items():
        with TTFont(source_font, recalcTimestamp=False) as source:
            source_coverage = set(source.getBestCmap())
            instance = instantiateVariableFont(
                source, {"wght": weight}, inplace=True, updateFontNames=True
            )
            instance.recalcTimestamp = False
            if "fvar" in instance or instance["OS/2"].usWeightClass != weight:
                raise ValueError(f"Invalid static instance metadata for {style}")
            if set(instance.getBestCmap()) != source_coverage:
                raise ValueError(f"Character coverage changed for {style}")
            destination = output_directory / f"NotoSansTC-{style}.ttf"
            instance.save(destination)
        with TTFont(destination, recalcTimestamp=False) as saved:
            derived[destination.name] = {
                "weight": weight,
                "bytes": destination.stat().st_size,
                "sha256": sha256(destination),
                "family": saved["name"].getDebugName(16) or saved["name"].getDebugName(1),
                "style": saved["name"].getDebugName(17) or saved["name"].getDebugName(2),
                "static": "fvar" not in saved,
                "unicodeCodepoints": len(saved.getBestCmap()),
            }
    return {
        "repository": "https://github.com/google/fonts",
        "commit": SOURCE_COMMIT,
        "source": {"url": SOURCE_URL, "sha256": SOURCE_SHA256},
        "license": {"url": LICENSE_URL, "sha256": LICENSE_SHA256},
        "derivation": {
            "generator": "scripts/generate_jms_ui_fonts.py",
            "tool": "fontTools.varLib.instancer",
            "version": FONTTOOLS_VERSION,
            "axis": "wght",
            "updateFontNames": True,
            "recalcTimestamp": False,
            "unicodeCoveragePreserved": True,
        },
        "derived": derived,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-font", required=True, type=Path)
    parser.add_argument("--license-file", required=True, type=Path)
    parser.add_argument(
        "--output-directory", type=Path,
        default=Path(__file__).resolve().parents[1] / "assets/fonts/notosanstc",
    )
    parser.add_argument("--provenance", type=Path)
    args = parser.parse_args()
    report = generate(args.source_font, args.license_file, args.output_directory)
    if args.provenance:
        args.provenance.parent.mkdir(parents=True, exist_ok=True)
        args.provenance.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
