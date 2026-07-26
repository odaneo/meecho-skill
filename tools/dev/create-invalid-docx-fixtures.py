#!/usr/bin/env python3
"""生成 Meecho 任务 7 使用的合成异常文档 fixture。"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

from msoffcrypto.format.ooxml import OOXMLFile


REPO_ROOT = Path(__file__).resolve().parents[2]
SOURCE_DOCX = REPO_ROOT / "evals" / "fixtures" / "docx" / "basic.docx"
OUTPUT_ROOT = REPO_ROOT / "evals" / "fixtures" / "docx" / "invalid"
PASSWORD = "Meecho-Task7-Only"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def write_macro_enabled_docm(destination: Path) -> None:
    ordinary_main_type = (
        b"application/vnd.openxmlformats-officedocument."
        b"wordprocessingml.document.main+xml"
    )
    macro_main_type = (
        b"application/vnd.ms-word.document.macroEnabled.main+xml"
    )

    with ZipFile(SOURCE_DOCX, "r") as source_archive:
        with ZipFile(destination, "w", compression=ZIP_DEFLATED) as output:
            for entry in source_archive.infolist():
                data = source_archive.read(entry.filename)
                if entry.filename == "[Content_Types].xml":
                    if ordinary_main_type not in data:
                        raise RuntimeError(
                            "basic.docx 缺少普通 Word 主内容类型。"
                        )
                    data = data.replace(ordinary_main_type, macro_main_type)
                output.writestr(entry, data)


def write_encrypted_docx(destination: Path) -> None:
    with SOURCE_DOCX.open("rb") as source:
        document = OOXMLFile(source)
        with destination.open("wb") as output:
            document.encrypt(PASSWORD, output)


def build_manifest(files: list[tuple[str, str]]) -> dict[str, object]:
    descriptions = {
        "unsupported-doc": "V1 不支持 .doc",
        "macro-enabled-docm": "V1 不支持 .docm",
        "corrupt-docx": "ZIP 中央目录损坏",
        "encrypted-docx": "密码加密的 Office CFB 容器",
        "disguised-docx": "RTF 内容伪装成 .docx",
    }
    return {
        "schema": 1,
        "classification": "synthetic",
        "ordinary_user_runtime_required": False,
        "cases": [
            {
                "kind": kind,
                "file": filename,
                "sha256": sha256(OUTPUT_ROOT / filename),
                "description": descriptions[kind],
            }
            for kind, filename in files
        ],
    }


def main() -> None:
    if not SOURCE_DOCX.is_file():
        raise FileNotFoundError(SOURCE_DOCX)

    source_hash_before = sha256(SOURCE_DOCX)
    OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)

    cases = [
        ("unsupported-doc", "unsupported.doc"),
        ("macro-enabled-docm", "macro-enabled.docm"),
        ("corrupt-docx", "corrupt.docx"),
        ("encrypted-docx", "encrypted.docx"),
        ("disguised-docx", "disguised.docx"),
    ]

    (OUTPUT_ROOT / "unsupported.doc").write_bytes(
        b"MEECHO SYNTHETIC UNSUPPORTED DOC FIXTURE\r\n"
    )
    write_macro_enabled_docm(OUTPUT_ROOT / "macro-enabled.docm")

    source_bytes = SOURCE_DOCX.read_bytes()
    (OUTPUT_ROOT / "corrupt.docx").write_bytes(source_bytes[:256])

    write_encrypted_docx(OUTPUT_ROOT / "encrypted.docx")

    (OUTPUT_ROOT / "disguised.docx").write_bytes(
        b"{\\rtf1\\ansi MEECHO SYNTHETIC DISGUISED DOCX FIXTURE}"
    )

    manifest = build_manifest(cases)
    (OUTPUT_ROOT / "invalid.expected.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    source_hash_after = sha256(SOURCE_DOCX)
    if source_hash_before != source_hash_after:
        raise RuntimeError("生成 fixture 时修改了 basic.docx。")

    print(f"output_root={OUTPUT_ROOT}")
    print(f"source_docx_sha256={source_hash_after}")
    for kind, filename in cases:
        path = OUTPUT_ROOT / filename
        print(f"{kind}|{filename}|{sha256(path)}|{path.stat().st_size}")


if __name__ == "__main__":
    main()
