import hashlib
import json
import pathlib
import shutil
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
destination = root / 'artifacts/subtitles'
destination.mkdir(parents=True, exist_ok=True)
duration_seconds = 360
cycle_seconds = 12
ffmpeg = shutil.which('ffmpeg')
ffprobe = shutil.which('ffprobe')
if not ffmpeg or not ffprobe:
    raise SystemExit('BLOCKED: FFmpeg and ffprobe are required')


def shift_timestamp(timestamp, offset_seconds):
    hours, minutes, seconds = timestamp.split(':')
    whole_seconds, centiseconds = seconds.split('.')
    total = int(hours) * 3600 + int(minutes) * 60 + int(whole_seconds) + offset_seconds
    return f'{total // 3600}:{total // 60 % 60:02d}:{total % 60:02d}.{centiseconds}'


event_counts = {}
for label, name in (('general', 'legacy-traditional.ass'), ('complex', 'representative.ass')):
    lines = (root / 'test/fixtures/subtitles' / name).read_text(encoding='utf-8').splitlines()
    header = [line for line in lines if not line.startswith('Dialogue:')]
    events = [line.split(',', 9) for line in lines if line.startswith('Dialogue:')]
    extended = list(header)
    for offset in range(0, duration_seconds, cycle_seconds):
        for event in events:
            shifted = list(event)
            shifted[1] = shift_timestamp(event[1], offset)
            shifted[2] = shift_timestamp(event[2], offset)
            extended.append(','.join(shifted))
    event_counts[label] = len(extended) - len(header)
    (destination / f'performance-{label}.ass').write_text('\n'.join(extended) + '\n', encoding='utf-8')

output = destination / 'performance-360s.mkv'
arguments = [
    ffmpeg, '-hide_banner', '-y', '-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=24',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000', '-i', str(destination / 'performance-general.ass'),
    '-i', str(destination / 'performance-complex.ass'), '-t', str(duration_seconds),
    '-map', '0:v:0', '-map', '1:a:0', '-map', '2:0', '-map', '3:0',
    '-c:v', 'libx264', '-preset', 'fast', '-crf', '20', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-c:s', 'copy',
    '-metadata:s:s:0', 'title=General Chinese ASS', '-metadata:s:s:1', 'title=Complex bilingual ASS',
    '-metadata:s:s:0', 'language=zho', '-metadata:s:s:1', 'language=zho',
    '-attach', str(root / 'assets/subtitle_fonts/NotoSansCJKtc-Regular.otf'),
    '-metadata:s:t:0', 'mimetype=application/vnd.ms-opentype',
    '-metadata:s:t:0', 'filename=JMS-fallback.otf', str(output),
]
with (destination / 'performance-mux.log').open('w', encoding='utf-8') as log:
    subprocess.run(arguments, stdout=log, stderr=subprocess.STDOUT, check=True)
probe = json.loads(subprocess.check_output([
    ffprobe, '-v', 'error', '-count_packets', '-show_entries',
    'format=duration:stream=codec_type,codec_name,width,height,avg_frame_rate,nb_read_packets', '-of', 'json', str(output),
], text=True))
if abs(float(probe['format']['duration']) - duration_seconds) > 0.15:
    raise SystemExit('FAIL: performance clip duration differs from the declared 360 seconds')
video = next(stream for stream in probe['streams'] if stream['codec_type'] == 'video')
if (video['codec_name'], video['width'], video['height'], video['avg_frame_rate']) != ('h264', 1280, 720, '24/1'):
    raise SystemExit('FAIL: primary video format changed')
if int(video['nb_read_packets']) != duration_seconds * 24:
    raise SystemExit('FAIL: expected exactly 8640 video frames')
if sum(stream['codec_name'] == 'ass' for stream in probe['streams']) != 2:
    raise SystemExit('FAIL: expected two ASS tracks')
report = {
    'fixture_status': 'PASS', 'device_performance': 'BLOCKED: not measured',
    'warmup_seconds': 120, 'measurement_seconds': 180, 'media': probe, 'event_counts': event_counts,
    'sha256': {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
               for path in (output, destination / 'performance-general.ass', destination / 'performance-complex.ass')},
}
(destination / 'performance-manifest.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
print(json.dumps(report, indent=2))
