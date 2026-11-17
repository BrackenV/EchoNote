#include <stdint.h>
#include <stddef.h>
void *lr_open(const char *path, uint32_t rate);
int32_t lr_write(void *rec, const float *samples, size_t count);
float lr_level(const void *rec);
int32_t lr_close(void *rec);
