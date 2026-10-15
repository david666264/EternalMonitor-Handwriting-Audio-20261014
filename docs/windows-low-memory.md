# Windows NVENC memory allocation

Windows NVENC sessions using software YUV420P input prefer an NVIDIA D3D11VA
device context. This keeps the existing CPU color conversion and encoded stream
parameters, without creating a separate CUDA encode context. A device creation or
encoder-open failure retries the original CUDA path with a fresh codec context.
No hardware-frame upload filter, resolution change, or audio change is involved.

The Windows NVENC input/output surface count defaults to two. B frames and
lookahead remain disabled, and completed frames are returned with `delay=0`.
The control window retains eframe's low-latency swapchain configuration.

Process-local diagnostic overrides (not written to user settings):

- `ETERNAL_NVENC_DEVICE=cuda`: use the previous device API.
- `ETERNAL_NVENC_SURFACES=4`: use the previous four-surface allocation.
- Combine both to compare with the previous NVENC path.
- `ETERNAL_NVENC_DEVICE=auto` or `d3d11`: prefer DirectX on the supported path.
- Surface overrides are limited to 1 through 4; invalid overrides use four.

Other encoder vendors, non-Windows platforms, BGRA input, USB framing, codec
negotiation, saved display selection and audio routing retain their previous
behavior. This is a memory optimization, not a promise of a particular frame rate.

Implementation references: FFmpeg n7.1.1 `libavcodec/nvenc.c`,
`libavutil/hwcontext_d3d11va.c`, and `fftools/ffmpeg_enc.c`.
