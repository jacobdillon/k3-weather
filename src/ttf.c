// Thin C shim over stb_truetype so the Zig side only deals with plain ints.
#define STB_TRUETYPE_IMPLEMENTATION
#define STBTT_STATIC
#include "stb_truetype.h"

#define MAX_FONTS 4
static stbtt_fontinfo fonts[MAX_FONTS];

int ttf_init(int idx, const unsigned char *data) {
    if (idx < 0 || idx >= MAX_FONTS) return 0;
    return stbtt_InitFont(&fonts[idx], data, stbtt_GetFontOffsetForIndex(data, 0));
}

float ttf_scale(int idx, float px) {
    return stbtt_ScaleForPixelHeight(&fonts[idx], px);
}

void ttf_vmetrics(int idx, int *ascent, int *descent, int *line_gap) {
    stbtt_GetFontVMetrics(&fonts[idx], ascent, descent, line_gap);
}

void ttf_hmetrics(int idx, int cp, int *advance, int *lsb) {
    stbtt_GetCodepointHMetrics(&fonts[idx], cp, advance, lsb);
}

int ttf_kern(int idx, int a, int b) {
    return stbtt_GetCodepointKernAdvance(&fonts[idx], a, b);
}

void ttf_box(int idx, int cp, float scale, int *x0, int *y0, int *x1, int *y1) {
    stbtt_GetCodepointBitmapBox(&fonts[idx], cp, scale, scale, x0, y0, x1, y1);
}

void ttf_render(int idx, unsigned char *out, int w, int h, int stride, float scale, int cp) {
    stbtt_MakeCodepointBitmap(&fonts[idx], out, w, h, stride, scale, scale, cp);
}
