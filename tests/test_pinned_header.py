#!/usr/bin/env python3
"""Exercise pinned-header cache updates with an isolated pattern renderer."""
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]

PROBE = r'''
#define main devui_application_main
#include "@SOURCE@"
#undef main
#include <assert.h>

static int draw_calls;
static int draw_failure;
static int renderer_scroll = 531;
static int renderer_width = 320, renderer_height = 480;
static int document_revision = 17;

static uint16_t logical_pixel(int theme, int x, int y)
{
    return (uint16_t)((theme ? 0x8000 : 0x2000) ^ (y * 331) ^ x);
}

/* The real adapter draws the current DOM without changing layout or scroll.
 * The fake keeps those state sentinels and exposes exact pixel orientation. */
int html_view_draw_current_tall(uint16_t *buffer, int height)
{
    assert(height == PINNED_HEADER_TOP + PINNED_HEADER_H);
    assert(renderer_width == 320 && renderer_height == 480);
    draw_calls++;
    if (draw_failure) {
        buffer[0] = 0xffff;  /* A failed partial draw must not poison the cache. */
        return -1;
    }
    for (int y = 0; y < height; y++)
        for (int x = 0; x < 320; x++)
            buffer[(size_t)y * 320 + x] = logical_pixel(g_theme, x, y);
    return 1200;
}

/* Catch a future cache refresh that starts reparsing or changing scroll. */
int html_view_render_html(const char *html)
{
    (void)html;
    document_revision++;
    return 1200;
}
void html_view_set_scroll(int scroll) { renderer_scroll = scroll; }

static void assert_current_layout_unchanged(void)
{
    assert(g_scroll == 531);
    assert(renderer_scroll == 531);
    assert(renderer_width == 320 && renderer_height == 480);
    assert(document_revision == 17);
}

static void assert_rotated_cache(int theme)
{
    assert(g_pinned_header_valid);
    for (int y = 0; y < PINNED_HEADER_H; y++)
        for (int x = 0; x < 320; x++)
            assert(g_pinned_header[(size_t)y * 320 + x] ==
                   logical_pixel(theme, 319 - x, PINNED_HEADER_TOP + y));
}

static void test_repaint_uses_current_layout(void)
{
    g_theme = 1;
    g_scroll = 531;
    memset(g_pinned_header, 0x5a, sizeof g_pinned_header);
    g_pinned_header_valid = 0;
    assert(pinned_header_repaint());
    assert(draw_calls == 1 && !g_pinned_header_valid);
    for (int y = 0; y < PINNED_HEADER_TOP + PINNED_HEADER_H; y++)
        for (int x = 0; x < 320; x++)
            assert(g_header_scratch[(size_t)y * 320 + x] == logical_pixel(1, x, y));
    for (size_t i = 0; i < sizeof g_pinned_header / sizeof *g_pinned_header; i++)
        assert(g_pinned_header[i] == 0x5a5a);
    assert_current_layout_unchanged();
}

static void test_refresh_replaces_theme_and_rotates_rows(void)
{
    g_scroll = 531;
    g_theme = 0;
    pinned_header_refresh();
    assert_rotated_cache(0);
    uint16_t dark_corner = g_pinned_header[0];
    g_theme = 1;
    pinned_headers_invalidate();
    assert(!g_pinned_header_valid);
    pinned_header_refresh();
    assert_rotated_cache(1);
    assert(g_pinned_header[0] != dark_corner && draw_calls == 2);
    assert_current_layout_unchanged();
}

static void test_failed_refresh_preserves_cache_and_validity(void)
{
    static uint16_t previous[320 * PINNED_HEADER_H];
    g_scroll = 531;
    pinned_header_refresh();
    memcpy(previous, g_pinned_header, sizeof previous);
    draw_failure = 1;
    g_theme = !g_theme;
    pinned_header_refresh();
    assert(g_pinned_header_valid);
    assert(!memcmp(previous, g_pinned_header, sizeof previous));
    pinned_headers_invalidate();
    pinned_header_refresh();
    assert(!g_pinned_header_valid);
    assert(!memcmp(previous, g_pinned_header, sizeof previous));
    assert(draw_calls == 3);
    assert_current_layout_unchanged();
}

static void test_invalidates_all_navigation_headers(void)
{
    g_scroll = 531;
    g_quick_previous_scroll = 246;
    g_nav_depth = NAV_DEPTH;
    g_pinned_header_valid = g_quick_previous_header_valid = 1;
    for (int i = 0; i < NAV_DEPTH; i++) {
        g_nav_stack[i].header_valid = 1;
        g_nav_stack[i].scroll = 100 + i;
        snprintf(g_nav_stack[i].path, sizeof g_nav_stack[i].path, "page-%d", i);
        g_nav_stack[i].header[0] = (uint16_t)(0x3000 + i);
    }
    pinned_headers_invalidate();
    assert(!g_pinned_header_valid && !g_quick_previous_header_valid);
    assert(g_nav_depth == NAV_DEPTH && g_quick_previous_scroll == 246);
    for (int i = 0; i < NAV_DEPTH; i++) {
        char expected[24]; snprintf(expected, sizeof expected, "page-%d", i);
        assert(!g_nav_stack[i].header_valid);
        assert(g_nav_stack[i].scroll == 100 + i);
        assert(!strcmp(g_nav_stack[i].path, expected));
        assert(g_nav_stack[i].header[0] == (uint16_t)(0x3000 + i));
    }
    assert_current_layout_unchanged();
}

static void test_cache_draw_respects_rotation_pitch_and_strip(void)
{
    enum { PITCH = 328, HEIGHT = 480 };
    static uint16_t frame[PITCH * HEIGHT];
    drm_disp_t display;
    memset(&display, 0, sizeof display);
    display.fb = frame; display.width = 320; display.height = HEIGHT;
    display.pitch_px = PITCH;
    for (size_t i = 0; i < sizeof frame / sizeof *frame; i++) frame[i] = 0xa55a;
    g_theme = 1; g_scroll = 531;
    pinned_header_refresh();
    pinned_header_draw(&display);
    for (int physical_y = 0; physical_y < HEIGHT; physical_y++) {
        int logical_y = HEIGHT - 1 - physical_y;
        for (int x = 0; x < PITCH; x++) {
            uint16_t expected = 0xa55a;
            if (x < 320 && logical_y >= PINNED_HEADER_TOP &&
                logical_y < PINNED_HEADER_TOP + PINNED_HEADER_H)
                expected = logical_pixel(1, 319 - x, logical_y);
            assert(frame[(size_t)physical_y * PITCH + x] == expected);
        }
    }
    memset(g_pinned_header, 0, sizeof g_pinned_header);
    g_pinned_header_valid = 0;
    pinned_header_capture(&display);
    assert_rotated_cache(1);
    assert_current_layout_unchanged();
}

static void test_invalid_cache_is_not_drawn(void)
{
    static uint16_t frame[320 * 480];
    drm_disp_t display;
    memset(&display, 0, sizeof display);
    display.fb = frame; display.width = 320; display.height = 480;
    display.pitch_px = 320;
    for (size_t i = 0; i < sizeof frame / sizeof *frame; i++) frame[i] = 0x6b4d;
    g_pinned_header_valid = 0;
    pinned_header_draw(&display);
    for (size_t i = 0; i < sizeof frame / sizeof *frame; i++) assert(frame[i] == 0x6b4d);
}

int main(int argc, char **argv)
{
    assert(argc == 2);
    if (!strcmp(argv[1], "repaint")) test_repaint_uses_current_layout();
    else if (!strcmp(argv[1], "theme")) test_refresh_replaces_theme_and_rotates_rows();
    else if (!strcmp(argv[1], "failure")) test_failed_refresh_preserves_cache_and_validity();
    else if (!strcmp(argv[1], "invalidate")) test_invalidates_all_navigation_headers();
    else if (!strcmp(argv[1], "roundtrip")) test_cache_draw_respects_rotation_pitch_and_strip();
    else if (!strcmp(argv[1], "invalid-draw")) test_invalid_cache_is_not_drawn();
    else return 2;
    return 0;
}
'''


class PinnedHeaderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="devui-pinned-header-")
        cls.addClassCleanup(cls.temporary.cleanup)
        base = Path(cls.temporary.name)
        probe = base / "probe.c"
        probe.write_text(PROBE.replace("@SOURCE@", str(ROOT / "src/htmlmain.c")))
        cls.binary = base / "probe"
        flags = ["-std=c11", "-D_GNU_SOURCE", "-ffunction-sections", "-fdata-sections",
                 "-I", str(ROOT / "include"), "-I", str(ROOT / "third_party/stb")]
        if sys.platform == "darwin":
            flags += ["-Dst_mtim=st_mtimespec", "-Wl,-dead_strip"]
        else:
            flags += ["-Wl,--gc-sections"]
        command = shlex.split(os.environ.get("CC", "cc")) + flags + [
            str(probe), "-pthread", "-lm", "-o", str(cls.binary)]
        subprocess.run(command, check=True)

    def run_case(self, name):
        subprocess.run([str(self.binary), name], check=True, timeout=5)

    def test_repaint_uses_current_layout_without_changing_scroll(self):
        self.run_case("repaint")

    def test_refresh_replaces_theme_with_correct_rotated_pixels(self):
        self.run_case("theme")

    def test_failed_refresh_preserves_previous_cache(self):
        self.run_case("failure")

    def test_theme_invalidation_clears_current_quick_and_navigation_caches(self):
        self.run_case("invalidate")

    def test_capture_and_draw_roundtrip_with_framebuffer_padding(self):
        self.run_case("roundtrip")

    def test_invalid_cached_pixels_are_never_drawn(self):
        self.run_case("invalid-draw")


if __name__ == "__main__":
    unittest.main()
