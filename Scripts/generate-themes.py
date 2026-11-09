#!/usr/bin/env python3
"""Generates Lotion/Design/ThemeCatalog.swift from the VS Code themes bundled in
shiki-swift. Each Lotion theme takes a theme's page colors (background, ink,
links, headings) and derives the rest; its code blocks use the same theme."""
import json, os, sys

import shutil

SHIKI = os.path.join(os.path.dirname(__file__), "../../shiki-swift/Sources")
THEMES = os.path.join(SHIKI, "Shiki/Resources/themes")
# Themes the Shiki product doesn't bundle. Lotion ships their JSON and
# registers it with the highlighter at launch.
EXTRA = os.path.join(SHIKI, "ShikiDiffs/Resources/Themes")
EXTRA_THEMES = ["pierre-light", "pierre-dark"]
SHIPPED = os.path.join(os.path.dirname(__file__), "../Lotion/Themes")
OUT = os.path.join(os.path.dirname(__file__), "../Lotion/Design/ThemeCatalog.swift")

# (id, name, light theme, dark theme) — either side may be None.
CATALOG = [
    ("github-default", "GitHub Default", "github-light-default", "github-dark-default"),
    ("github", "GitHub Classic", "github-light", "github-dark"),
    ("github-high-contrast", "GitHub High Contrast", "github-light-high-contrast", "github-dark-high-contrast"),
    ("github-dimmed", "GitHub Dimmed", None, "github-dark-dimmed"),
    ("pierre", "Pierre", "pierre-light", "pierre-dark"),
    ("vscode", "VS Code", "light-plus", "dark-plus"),
    ("catppuccin", "Catppuccin", "catppuccin-latte", "catppuccin-mocha"),
    ("rose-pine", "Rosé Pine", "rose-pine-dawn", "rose-pine"),
    ("solarized", "Solarized", "solarized-light", "solarized-dark"),
    ("one", "One", "one-light", "one-dark-pro"),
    ("vitesse", "Vitesse", "vitesse-light", "vitesse-dark"),
    ("everforest", "Everforest", "everforest-light", "everforest-dark"),
    ("gruvbox", "Gruvbox", "gruvbox-light-medium", "gruvbox-dark-medium"),
    ("kanagawa", "Kanagawa", "kanagawa-lotus", "kanagawa-wave"),
    ("night-owl", "Night Owl", "night-owl-light", "night-owl"),
    ("material", "Material", "material-theme-lighter", "material-theme-darker"),
    ("ayu", "Ayu", "ayu-light", "ayu-dark"),
    ("min", "Min", "min-light", "min-dark"),
    ("dracula", "Dracula", None, "dracula"),
    ("tokyo-night", "Tokyo Night", None, "tokyo-night"),
    ("palenight", "Palenight", None, "material-theme-palenight"),
    ("poimandres", "Poimandres", None, "poimandres"),
    ("monokai", "Monokai", None, "monokai"),
    ("vesper", "Vesper", None, "vesper"),
    ("houston", "Houston", None, "houston"),
    ("ayu-mirage", "Ayu Mirage", None, "ayu-mirage"),
    ("horizon", "Horizon", "horizon-bright", "horizon"),
    ("slack", "Slack", "slack-ochin", "slack-dark"),
    ("catppuccin-frappe", "Catppuccin Frappé", None, "catppuccin-frappe"),
    ("catppuccin-macchiato", "Catppuccin Macchiato", None, "catppuccin-macchiato"),
    ("rose-pine-moon", "Rosé Pine Moon", None, "rose-pine-moon"),
    ("kanagawa-dragon", "Kanagawa Dragon", None, "kanagawa-dragon"),
    ("material-ocean", "Material Ocean", None, "material-theme-ocean"),
    ("dracula-soft", "Dracula Soft", None, "dracula-soft"),
    ("vitesse-black", "Vitesse Black", None, "vitesse-black"),
    ("synthwave", "Synthwave ’84", None, "synthwave-84"),
    ("laserwave", "Laserwave", None, "laserwave"),
    ("aurora-x", "Aurora X", None, "aurora-x"),
    ("andromeeda", "Andromeeda", None, "andromeeda"),
    ("plastic", "Plastic", None, "plastic"),
    ("red", "Red", None, "red"),
    ("snazzy", "Snazzy Light", "snazzy-light", None),
]

def parse(hexstr, over=None):
    h = hexstr.lstrip("#")
    if len(h) in (3, 4): h = "".join(c * 2 for c in h)
    r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
    a = int(h[6:8], 16) / 255 if len(h) == 8 else 1.0
    if a < 1 and over is not None:
        r, g, b = (round(c * a + o * (1 - a)) for c, o in zip((r, g, b), over))
    return (r, g, b)

def mix(a, b, t):  # t of b over a
    return tuple(round(x * (1 - t) + y * t) for x, y in zip(a, b))

def lum(c):
    def ch(v):
        v /= 255
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (ch(v) for v in c)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b

def contrast(a, b):
    la, lb = sorted((lum(a), lum(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)

def token(theme, prefixes):
    for entry in theme.get("tokenColors") or theme.get("settings") or []:
        scopes = entry.get("scope")
        scopes = [scopes] if isinstance(scopes, str) else (scopes or [])
        scopes = [s.strip() for sc in scopes for s in sc.split(",")]
        if any(s.startswith(p) for s in scopes for p in prefixes):
            color = entry.get("settings", {}).get("foreground")
            if color: return color
    return None

def theme_path(name):
    return os.path.join(EXTRA if name in EXTRA_THEMES else THEMES, name + ".json")

def spec(name):
    theme = json.load(open(theme_path(name)))
    colors = theme.get("colors", {})
    dark = theme.get("type", "dark") == "dark"
    bg = parse(colors.get("editor.background") or ("#1e1e1e" if dark else "#ffffff"))
    default_fg = None
    for entry in theme.get("tokenColors") or []:
        if "scope" not in entry and entry.get("settings", {}).get("foreground"):
            default_fg = entry["settings"]["foreground"]
    fg = parse(colors.get("editor.foreground") or default_fg or ("#d4d4d4" if dark else "#333333"), bg)
    def readable(color, minimum):
        return color if color and contrast(color, bg) >= minimum else None
    link = None
    for candidate in [colors.get("textLink.foreground"), token(theme, ["markup.underline.link", "string.other.link"]),
                      colors.get("textLink.activeForeground"), token(theme, ["keyword"]), colors.get("focusBorder")]:
        if candidate:
            link = readable(parse(candidate, bg), 3.0)
            if link: break
    heading = readable(parse(token(theme, ["markup.heading", "entity.name.section"]) or "#000", bg), 3.0) \
        if token(theme, ["markup.heading", "entity.name.section"]) else None
    return {
        "background": bg, "text": fg,
        "secondary": mix(bg, fg, 0.62), "marker": mix(bg, fg, 0.36),
        "accent": link or fg, "heading": heading or fg,
        "codeBackground": mix(bg, fg, 0.045 if dark else 0.035),
        "inlineCode": mix(bg, fg, 0.085 if dark else 0.065),
        "rule": mix(bg, fg, 0.13 if dark else 0.11),
        "shiki": name, "dark": dark,
    }

def hexs(c): return "0x%02X%02X%02X" % c

def swift(s):
    if s is None: return "nil"
    return (f'ThemeSpec(background: {hexs(s["background"])}, text: {hexs(s["text"])}, secondary: {hexs(s["secondary"])}, '
            f'marker: {hexs(s["marker"])}, accent: {hexs(s["accent"])}, codeBackground: {hexs(s["codeBackground"])}, '
            f'inlineCode: {hexs(s["inlineCode"])}, rule: {hexs(s["rule"])}, heading: {hexs(s["heading"])}, '
            f'shikiTheme: "{s["shiki"]}", isDark: {"true" if s["dark"] else "false"})')

lines = ["//", "//  ThemeCatalog.swift", "//  Lotion", "//",
         "//  Generated by Scripts/generate-themes.py from the VS Code themes in",
         "//  shiki-swift. Edit the script, not this file.", "//", "",
         "extension LotionTheme {", "    static let catalog: [LotionTheme] = ["]
for tid, name, light, dark in CATALOG:
    lines.append(f'        LotionTheme(id: "{tid}", name: "{name}",')
    lines.append(f'                   light: {swift(spec(light) if light else None)},')
    lines.append(f'                   dark: {swift(spec(dark) if dark else None)}),')
lines += ["    ]", "}", ""]
open(OUT, "w").write("\n".join(lines))
os.makedirs(SHIPPED, exist_ok=True)
for name in EXTRA_THEMES:
    shutil.copy(theme_path(name), os.path.join(SHIPPED, name + ".json"))
print(f"wrote {len(CATALOG)} themes to {os.path.normpath(OUT)}")
