import hashlib
import json
import pathlib
import shutil
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
destination = root / 'artifacts/subtitles'
destination.mkdir(parents=True, exist_ok=True)
ffmpeg = shutil.which('ffmpeg')
if not ffmpeg:
    raise SystemExit('BLOCKED: ffmpeg is required')
source = root / 'test/fixtures/subtitles/representative.ass'
text = source.read_text(encoding='utf-8')
for encoding in ('utf-8-sig', 'gb18030'):
    (destination / f'representative-{encoding}.ass').write_bytes(text.encode(encoding))
traditional = (root / 'test/fixtures/subtitles/legacy-traditional.ass').read_text(encoding='utf-8')
for encoding in ('big5', 'cp950'):
    (destination / f'traditional-{encoding}.ass').write_bytes(traditional.encode(encoding))


def run(arguments, name):
    with (destination / (name + '.log')).open('w', encoding='utf-8') as output:
        subprocess.run([ffmpeg, '-hide_banner', '-y', *arguments], cwd=root, stdout=output, stderr=subprocess.STDOUT, check=True)


run(['-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=24', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000', '-t', '12', '-c:v', 'libx264', '-preset', 'fast', '-crf', '20', '-pix_fmt', 'yuv420p', '-c:a', 'aac', 'artifacts/subtitles/source.mp4'], 'source')
run(['-i', 'artifacts/subtitles/source.mp4', '-i', str(source.relative_to(root)), '-i', 'test/fixtures/subtitles/traditional.srt', '-map', '0:v', '-map', '0:a', '-map', '1:0', '-map', '2:0', '-c', 'copy', '-metadata:s:s:0', 'language=zho', '-attach', 'assets/subtitle_fonts/NotoSansCJKtc-Regular.otf', '-metadata:s:t:0', 'mimetype=application/vnd.ms-opentype', '-metadata:s:t:0', 'filename=JMS-fallback.otf', 'artifacts/subtitles/embedded-ass-font.mkv'], 'mux')
for moment in (1, 3, 5, 7, 9, 11):
    run(['-i', 'artifacts/subtitles/source.mp4', '-vf', 'ass=test/fixtures/subtitles/representative.ass:fontsdir=assets/subtitle_fonts', '-ss', str(moment), '-frames:v', '1', f'artifacts/subtitles/reference-{moment:02d}.png'], f'reference-{moment:02d}')
for extension in ('ssa', 'srt'):
    run(['-i', 'artifacts/subtitles/source.mp4', '-vf', f'subtitles=test/fixtures/subtitles/traditional.{extension}:fontsdir=assets/subtitle_fonts', '-ss', '1', '-frames:v', '1', f'artifacts/subtitles/reference-{extension}.png'], f'reference-{extension}')
manifest = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in destination.iterdir()
            if path.is_file() and path.suffix != '.log' and path.name != 'sha256.json'}
(destination / 'sha256.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
print('Generated original fixtures and FFmpeg/libass reference frames; these do not prove Android rendering.')
