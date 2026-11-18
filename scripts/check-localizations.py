#!/usr/bin/env python3
"""Check translation coverage and format arguments before packaging."""
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parent.parent
tables = {}
for language in ("en", "ru"):
    content = (root / "Resources" / f"{language}.lproj" / "Localizable.strings").read_text()
    pairs = re.findall(r'("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*");', content)
    table = {json.loads(key): json.loads(value) for key, value in pairs}
    assert len(table) == len(pairs), f"Duplicate keys: {language}"
    assert table and all(table.values()), f"Empty translations: {language}"
    tables[language] = table
assert tables["en"].keys() == tables["ru"].keys(), "Translation keys differ"
for key in tables["en"]:
    placeholders = lambda text: re.findall(r'%(?:l)?[d@]', text)
    assert placeholders(tables["en"][key]) == placeholders(tables["ru"][key]), key
source = "\n".join(path.read_text() for path in (root / "Sources").glob("*.swift"))
used = set(re.findall(r'L10n\.text\("([^"]+)"', source))
assert used <= tables["en"].keys(), f"Missing keys: {used - tables['en'].keys()}"
print(f"PASS: {len(tables['en'])} EN/RU translations, matching format arguments, source coverage")
