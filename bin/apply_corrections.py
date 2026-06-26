#!/usr/bin/env python3
import argparse
from pathlib import Path


def load_rules(path: Path):
    rules = []

    for line_no, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        stripped = line.strip()

        if not stripped or stripped.startswith("#"):
            continue

        if "=>" not in line:
            raise ValueError(f"Invalid rule at line {line_no}: missing '=>'")

        src, dst = line.split("=>", 1)
        src = src.strip()
        dst = dst.strip()

        if not src:
            raise ValueError(f"Invalid rule at line {line_no}: empty source")

        rules.append((src, dst))

    return rules


def main():
    parser = argparse.ArgumentParser(description="Apply basic text corrections to a transcript.")
    parser.add_argument("input", help="Input transcript path")
    parser.add_argument("output", help="Output corrected transcript path")
    parser.add_argument(
        "-r",
        "--rules",
        default="/srv/heimdall/voice/config/corrections.rules",
        help="Correction rules file",
    )

    args = parser.parse_args()

    input_path = Path(args.input)
    output_path = Path(args.output)
    rules_path = Path(args.rules)

    text = input_path.read_text(encoding="utf-8")
    rules = load_rules(rules_path)

    total_replacements = 0

    for src, dst in rules:
        count = text.count(src)
        if count:
            text = text.replace(src, dst)
            total_replacements += count
            print(f"{src} => {dst}: {count}")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(text, encoding="utf-8")

    print(f"total_replacements={total_replacements}")


if __name__ == "__main__":
    main()
