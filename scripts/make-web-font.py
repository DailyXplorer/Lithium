#!/usr/bin/env python3
"""Writes Resources/Fonts/DMSans.woff2 from DMSans.ttf: the same font, every glyph, axis and
feature, compressed for web pages, which decode it on every load (Model/PageStyle.swift).
Needs fontTools and brotli: `pip install fonttools brotli`."""
from pathlib import Path

from fontTools.ttLib import TTFont

fonts = Path(__file__).resolve().parent.parent / "Sources/Lithium/Resources/Fonts"
font = TTFont(fonts / "DMSans.ttf")
font.flavor = "woff2"
font.save(fonts / "DMSans.woff2")
print(f"{(fonts / 'DMSans.ttf').stat().st_size} -> {(fonts / 'DMSans.woff2').stat().st_size} bytes")
