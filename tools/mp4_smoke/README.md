# MP4 smoke test

`mp4_smoke` exercises the full native pipeline:

1. It synthesises a moving gradient with a bright square, plus a sine tone
   (440/880 Hz).
2. It writes an MP4 through `video`.
3. It reads the file back sequentially, with six `frame_at` lookups, and
   reads all the audio.
4. It reports PSNR and SNR, the frame indices, the sample counts and the
   throughput.
5. When `ffprobe` is on `PATH`, it prints ffprobe's stream report. FFmpeg is
   only an oracle here.

```sh
odin build tools/mp4_smoke -o:speed -out:/tmp/mp4_smoke
/tmp/mp4_smoke /tmp/smoke.mp4                       # 640x360, 90 frames, H.264, automatic backend
/tmp/mp4_smoke /tmp/smoke265.mp4 --codec h265 --native --frames 30
/tmp/mp4_smoke /tmp/ntsc.mp4 --fps 30000/1001 --size 1280x720 --no-faststart
```

Options: `--frames N`, `--size WxH` (even), `--fps NUM/DEN`,
`--codec h264|h265`, `--qp N`, `--gop N`, `--native` or `--hardware`,
`--no-faststart` and `--no-audio`. The tool exits non-zero when any of these
checks fail:

- a frame index mismatch
- a `frame_at` PSNR below 30 dB
- an audio length different from the input
- an audio SNR below 12 dB
