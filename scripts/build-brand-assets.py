#!/usr/bin/env python3
"""Regenerate Wallmotion's static macOS brand assets (build-time tools only)."""
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BRAND = ROOT / "resources" / "branding"


def render(renderer: str, source: Path, output: Path, size: int) -> None:
    subprocess.run([renderer, "--width", str(size), "--height", str(size),
                    "--output", str(output), str(source)], check=True)


def main() -> None:
    renderer = shutil.which("rsvg-convert")
    iconutil = shutil.which("iconutil")
    if not renderer or not iconutil:
        raise SystemExit("Requires macOS iconutil and rsvg-convert (brew install librsvg).")
    # All intermediate files stay in a private temporary directory and are removed on exit.
    with tempfile.TemporaryDirectory(prefix="wallmotion-brand-") as directory:
        temporary = Path(directory)
        iconset = temporary / "AppIcon.iconset"
        iconset.mkdir()
        source = BRAND / "wallmotion-icon.svg"
        small_source = temporary / "small.svg"
        small = ET.parse(source)
        # Keep the monitor silhouette and all three broad waves at 16px;
        # remove detail below a pixel and strengthen the small display bezel.
        for identifier in ("fineDetails", "screenRim", "powerLight", "tileRim"):
            element = small.find(f".//*[@id='{identifier}']")
            if element is not None:
                for parent in small.iter():
                    if element in list(parent):
                        parent.remove(element)
                        break
        for element in small.iter():
            element.attrib.pop("filter", None)
        bezel = small.find(".//*[@id='monitorBezel']")
        if bezel is None:
            raise SystemExit("Missing monitor bezel in canonical SVG.")
        bezel.set("x", "160")
        bezel.set("y", "222")
        bezel.set("width", "704")
        bezel.set("height", "486")
        small.write(small_source, encoding="utf-8", xml_declaration=True)
        for points in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                pixels = points * scale
                suffix = "@2x" if scale == 2 else ""
                render(renderer, small_source if pixels <= 16 else source,
                       iconset / f"icon_{points}x{points}{suffix}.png", pixels)
        generated = temporary / "AppIcon.icns"
        subprocess.run([iconutil, "--convert", "icns", "--output", str(generated), str(iconset)], check=True)
        # Do not publish partial renders if a tool fails; all generation completes first.
        preview = temporary / "wallmotion-icon.png"
        render(renderer, source, preview, 1024)
        menu = BRAND / "wallmotion-menubar-template.svg"
        for scale in (1, 2):
            render(renderer, menu, temporary / f"menu-{scale}.png", 22 * scale)
        shutil.copyfile(generated, ROOT / "resources" / "AppIcon.icns")
        shutil.copyfile(generated, BRAND / "AppIcon.icns")
        shutil.copyfile(preview, BRAND / "wallmotion-icon.png")
        shutil.copyfile(temporary / "menu-1.png", BRAND / "wallmotion-menubar-template.png")
        shutil.copyfile(temporary / "menu-2.png", BRAND / "wallmotion-menubar-template@2x.png")
    print("Generated AppIcon.icns, preview and alpha-only menu templates.")


if __name__ == "__main__":
    main()
