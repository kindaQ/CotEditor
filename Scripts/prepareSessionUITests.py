#!/usr/bin/env python3
"""Prepare the app-owned legacy session before starting the sandboxed UI test runner."""

import argparse
import json
from pathlib import Path
from uuid import uuid4


def prepare(directory):
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)

    def draft(text, title):
        identifier = str(uuid4()).upper()
        (directory / (identifier + ".txt")).write_text(text, encoding="utf-8")
        return {"content": {"draft": {"_0": {
            "id": identifier, "title": title, "encoding": 4,
            "withUTF8BOM": False, "lineEnding": "\n", "syntaxName": "Plain Text",
            "isVerticalText": False,
        }}}}

    first = draft("Legacy window draft A", "Legacy A")
    second = draft("Legacy window draft B", "Legacy B")
    third = draft("Legacy window draft C", "Legacy C")
    file_url = directory / "existing.txt"
    file_url.write_text("Existing file in merged tabs", encoding="utf-8")
    file_tab = {"content": {"file": {"url": file_url.as_uri()}}}
    session = {"windows": [
        {"tabs": [first, file_tab]}, {"tabs": [second]}, {"tabs": [file_tab, third]},
    ]}
    (directory / "session.json").write_text(json.dumps(session), encoding="utf-8")
    print("Prepared legacy session fixture:", directory)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=Path.home() /
                        "Library/Containers/com.coteditor.CotEditor/Data/tmp/SessionUITests-separate-windows")
    prepare(parser.parse_args().directory.resolve())
