/* Thin ABI bridge: libvorbisfile owns its opaque decoder, Odin owns I/O. */
#define OV_EXCLUDE_STATIC_CALLBACKS
#include <vorbis/vorbisfile.h>
#include <stdlib.h>
#include <stdint.h>

OggVorbis_File *spoti_vorbis_open(void *source, ov_callbacks callbacks) {
	OggVorbis_File *file = calloc(1, sizeof(*file));
	if (!file) return NULL;
	if (ov_open_callbacks(source, file, NULL, 0, callbacks) != 0) {
		free(file);
		return NULL;
	}
	vorbis_info *info = ov_info(file, -1);
	if (ov_streams(file) != 1 || !info || info->rate < 8000 || info->rate > 192000 ||
		info->channels < 1 || info->channels > 2) {
		ov_clear(file);
		free(file);
		return NULL;
	}
	return file;
}

void spoti_vorbis_close(OggVorbis_File *file) {
	ov_clear(file);
	free(file);
}

int spoti_vorbis_rate(OggVorbis_File *file) {
	return (int)ov_info(file, -1)->rate;
}

int spoti_vorbis_read(OggVorbis_File *file, int16_t *pcm, int frames) {
	int channels = ov_info(file, -1)->channels;
	int section;
	long bytes = ov_read(file, (char *)pcm, frames * channels * 2, 0, 2, 1, &section);
	if (bytes < 0) return -1;
	int count = (int)(bytes / (channels * 2));
	if (channels == 1) {
		for (int i = count - 1; i >= 0; --i) {
			pcm[i * 2 + 1] = pcm[i];
			pcm[i * 2] = pcm[i];
		}
	}
	return count;
}
