import argparse
import ctypes
import json
import os
import time
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("library", type=Path)
    parser.add_argument("media", type=Path)
    args = parser.parse_args()
    with os.add_dll_directory(str(args.library.resolve().parent)):
        library = ctypes.CDLL(str(args.library.resolve()))
        library.mpv_create.restype = ctypes.c_void_p
        library.mpv_set_option_string.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
        library.mpv_initialize.argtypes = [ctypes.c_void_p]
        library.mpv_get_property_string.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        library.mpv_get_property_string.restype = ctypes.c_void_p
        library.mpv_free.argtypes = [ctypes.c_void_p]
        library.mpv_command.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_char_p)]
        library.mpv_terminate_destroy.argtypes = [ctypes.c_void_p]
        player = library.mpv_create()
        if not player:
            raise RuntimeError("mpv_create failed")

        def read(name):
            pointer = library.mpv_get_property_string(player, name.encode())
            if not pointer:
                return None
            try:
                return ctypes.string_at(pointer).decode("utf-8")
            finally:
                library.mpv_free(pointer)

        try:
            for name, value in {"config": "no", "terminal": "no", "load-scripts": "no", "ytdl": "no", "vo": "null", "ao": "null", "hwdec": "no", "pause": "yes"}.items():
                if library.mpv_set_option_string(player, name.encode(), value.encode()) < 0:
                    raise RuntimeError("Unsupported smoke option: " + name)
            if library.mpv_initialize(player) < 0:
                raise RuntimeError("mpv_initialize failed")
            command = (ctypes.c_char_p * 3)(b"loadfile", str(args.media.resolve()).encode(), None)
            if library.mpv_command(player, command) < 0:
                raise RuntimeError("loadfile failed")
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline and not read("video-codec"):
                time.sleep(0.1)
            tracks = json.loads(read("track-list") or "[]")
            selected_subtitles = [track.get("codec") for track in tracks if track.get("type") == "sub" and track.get("selected")]
            result = {"mpvVersion": read("mpv-version"), "ffmpegVersion": read("ffmpeg-version"), "videoCodec": read("video-codec"), "selectedSubtitleCodecs": selected_subtitles, "rendering": "headless; visual effects and GPU not verified"}
            print(json.dumps(result, indent=2))
            if not result["videoCodec"] or "ass" not in selected_subtitles:
                raise RuntimeError("Video and ASS fixture did not load")
        finally:
            library.mpv_terminate_destroy(player)


if __name__ == "__main__":
    main()
