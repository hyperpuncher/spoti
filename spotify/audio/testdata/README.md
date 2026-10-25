# audio fixtures

`mono-96.ogg` contains 45 seconds of generated mono pink noise at 32 kHz,
encoded as Vorbis at 96 kbps. it has no Spotify or recorded audio.

it tests encrypted reads across multiple 64 KiB ranges, mono-to-stereo output,
and exact seeks after short/long block transitions. an early push decoder
returned the wrong samples after some seeks because it trusted the sample
position before the first decoded page had ended.

created with FFmpeg n9.0.2:

```sh
ffmpeg -f lavfi \
	-i 'anoisesrc=color=pink:sample_rate=32000:duration=45:seed=31' \
	-c:a libvorbis -b:a 96k spotify/audio/testdata/mono-96.ogg
```

`tone.ogg` is the existing short stereo fixture. it also tests page scanning
at EOF when no later page provides lookahead bytes.
