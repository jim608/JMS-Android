"""Identify a mapped JMS product window without relying on its title."""
import argparse
import json
from pathlib import Path
import re
import subprocess


def product_windows(tree):
    pattern = re.compile(r'^\s*(0x[0-9a-f]+)\s+.*?:\s+\("jms"\s+"jms"\)\s+(\d+)x(\d+)[+-]\d+[+-]\d+', re.I | re.M)
    return [match.group(1) for match in pattern.finditer(tree)
            if int(match.group(2)) >= 320 and int(match.group(3)) >= 180]


def mapped_product_window(tree):
    for window in product_windows(tree):
        result = subprocess.run(['xwininfo', '-id', window], capture_output=True,
                                text=True, timeout=5, check=False)
        if result.returncode == 0 and re.search(r'^\s*Map State:\s+IsViewable\s*$', result.stdout, re.M):
            return window
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tree', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    window = mapped_product_window(args.tree.read_text(encoding='utf-8'))
    if window is None:
        return 1
    args.output.write_text(json.dumps({'windowId': window, 'wmClass': ['jms', 'Jms'],
                                      'minimumSize': [320, 180], 'mapped': True}) + '\n', encoding='utf-8')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
