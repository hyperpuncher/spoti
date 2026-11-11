#include "text.h"

void st_free_image(St_Image image) {
	free(image.pixels);
}
