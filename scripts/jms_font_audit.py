import hashlib
import json
import pathlib
import sys

from fontTools.ttLib import TTFont

for filename in sys.argv[1:]:
    path = pathlib.Path(filename)
    font = TTFont(path)
    names = {str(key): sorted({item.toUnicode() for item in font['name'].names if item.nameID == key}) for key in (1, 2, 6, 13, 14)}
    cmap = font.getBestCmap()
    sample = '繁體简体中文字幕日本語測試龍龙龜龟こんにちはカラオケ'
    print(json.dumps({'path': filename, 'bytes': path.stat().st_size, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'names': names, 'missing': [character for character in sample if ord(character) not in cmap]}, ensure_ascii=False))
