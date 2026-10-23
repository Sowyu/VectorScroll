#!/usr/bin/env python3
"""Validate localization coverage and printf argument types (requires macOS plutil)."""
from collections import Counter
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
USAGE_KEYS = {"NSAccessibilityUsageDescription", "NSInputMonitoringUsageDescription"}
LITERAL = re.compile(r'\bL\s*\(\s*"((?:[^"\\]|\\.)*)"')
ESCAPE = re.compile(r'\\(?:u\{([0-9a-fA-F]+)\}|(.))', re.DOTALL)
FORMAT = re.compile(r'%(?:([1-9][0-9]*)\$)?(@|ld|%)')


def swift_string(value):
    escapes = {'0': '\0', 'n': '\n', 'r': '\r', 't': '\t', '"': '"', "'": "'", '\\': '\\'}
    def decode(match):
        if match[1]:
            return chr(int(match[1], 16))
        if match[2] not in escapes:
            raise ValueError(f"Unsupported escape in localization key: {value!r}")
        return escapes[match[2]]
    return ESCAPE.sub(decode, value)


def source_keys():
    keys = set()
    for source in sorted((ROOT / "Sources/VectorScroll").glob("*.swift")):
        # Ignore comments while preserving strings, including escaped quotation marks.
        tokens = re.findall(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:[^"\\]|\\.)*"|[^/"\n]+|.', source.read_text())
        text = ''.join(' ' if token.startswith(('//', '/*')) else token for token in tokens)
        keys.update(swift_string(match[1]) for match in LITERAL.finditer(text))
    return keys


def read_strings(path):
    result = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(path)],
                            capture_output=True, text=True)
    if result.returncode:
        raise ValueError(f"{path.relative_to(ROOT)}: {result.stderr.strip() or result.stdout.strip()}")
    data = json.loads(result.stdout)
    if not isinstance(data, dict) or any(not isinstance(v, str) for v in data.values()):
        raise ValueError(f"{path.relative_to(ROOT)}: expected string keys and values")
    return data


def specifiers(value):
    """Keep argument positions/types and literal percent counts; permit positional reordering."""
    result = Counter()
    position = 1
    for match in FORMAT.finditer(value):
        index, kind = match.groups()
        if kind == '%':
            result[(0, '%')] += 1
        else:
            result[(int(index) if index else position, kind)] += 1
            if not index:
                position += 1
    return result


def check():
    errors = []
    expected = source_keys()
    folders = sorted((ROOT / "Localization").glob("*.lproj"))
    if not (ROOT / "Localization/en.lproj").is_dir():
        errors.append("Missing Localization/en.lproj")
    for folder in folders:
        for filename, keys in [("Localizable.strings", expected), ("InfoPlist.strings", USAGE_KEYS)]:
            path = folder / filename
            try:
                values = read_strings(path)
            except (ValueError, OSError) as error:
                errors.append(str(error))
                continue
            missing = keys - values.keys()
            extra = values.keys() - keys if filename == "Localizable.strings" else set()
            for label, items in [("missing keys", missing), ("extra keys", extra)]:
                if items:
                    errors.append(f"{path.relative_to(ROOT)} {label}:\n" + '\n'.join(f"  {key!r}" for key in sorted(items)))
            for key, value in values.items():
                if not value.strip():
                    errors.append(f"{path.relative_to(ROOT)}: empty value for {key!r}")
                if filename == "Localizable.strings" and specifiers(key) != specifiers(value):
                    errors.append(f"{path.relative_to(ROOT)}: format mismatch for {key!r}: {value!r}")
                if folder.name == 'en.lproj' and filename == 'Localizable.strings' and key != value:
                    errors.append(f"{path.relative_to(ROOT)}: English value must equal source key {key!r}")
    if errors:
        print("Localization validation failed:\n" + '\n'.join(errors), file=sys.stderr)
        return 1
    print(f"PASS: localization coverage, nonempty values, format arguments, and usage descriptions ({len(expected)} keys, {len(folders)} languages)")
    return 0


if __name__ == '__main__':
    sys.exit(check())
