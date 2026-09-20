import pathlib
import xml.etree.ElementTree as xml

from PIL import Image, ImageDraw

root = pathlib.Path(__file__).resolve().parents[1]
folder = root / 'icons/jms'
source = xml.parse(folder / 'mark.svg').getroot()
paths = []
for element in source.iter('{http://www.w3.org/2000/svg}polyline'):
    paths.append([tuple(map(float, point.split(','))) for point in element.attrib['points'].split()])


def mark(size, opaque=True):
    target_size = size
    size = max(1024, size)
    scale = size / 1024
    image = Image.new('RGBA', (size, size), '#101827' if opaque else (0, 0, 0, 0))
    canvas = ImageDraw.Draw(image)
    if opaque:
        for row in range(size):
            amount = row / size
            canvas.line((0, row, size, row), fill=(int(12 + 12 * amount), int(64 - 40 * amount), int(78 - 24 * amount), 255))
    width = round(48 * scale)
    radius = width / 2
    for points in paths:
        scaled = [(horizontal * scale, vertical * scale) for horizontal, vertical in points]
        canvas.line(scaled, fill='white', width=width, joint='curve')
        for horizontal, vertical in scaled:
            canvas.ellipse((horizontal-radius, vertical-radius, horizontal+radius, vertical+radius), fill='white')
    return image.resize((target_size, target_size), Image.Resampling.LANCZOS)


mark(1024).save(folder / 'icon.png')
mark(1024, False).save(folder / 'foreground.png')
mark(1024, False).save(folder / 'monochrome.png')
mark(256).save(folder / 'icon.ico', sizes=[(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
banner = Image.new('RGB', (320, 180), '#101827')
banner.paste(mark(180).convert('RGB'), (70, 0))
for path in (root / 'android/app/src').rglob('app_banner.png'):
    banner.save(path)
for path in (root / 'android/app/src/main/res').rglob('*.png'):
    if path.name not in {'ic_launcher_foreground.png', 'ic_launcher_monochrome.png'}:
        continue
    with Image.open(path) as existing:
        dimensions = existing.size
    mark(1024, False).resize(dimensions, Image.Resampling.LANCZOS).save(path)
installer = root / 'assets/windows-installer'
for multiplier in (100, 125, 150):
    width, height = round(164 * multiplier / 100), round(314 * multiplier / 100)
    image = Image.new('RGB', (width, height), '#101827')
    image.paste(mark(width).convert('RGB'), (0, (height-width)//2))
    image.save(installer / f'jms-installer-{multiplier}.bmp')
sheet = Image.new('RGB', (720, 480), '#eef2f6')
for position, size in enumerate((192, 96, 48, 32)):
    icon = mark(size)
    horizontal = (24, 240, 408, 560)[position]
    sheet.paste(icon, (horizontal, 24), icon)
    mask = Image.new('L', (size, size))
    ImageDraw.Draw(mask).ellipse((0, 0, size-1, size-1), fill=255)
    sheet.paste(icon, (horizontal, 260), mask)
sheet.save(root / 'artifacts/checks/brand-icons.png')
print('Generated JMS artwork from icons/jms/mark.svg')
