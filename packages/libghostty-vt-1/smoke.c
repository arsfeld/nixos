#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <ghostty/vt.h>

int main(void) {
#if GHOSTTY_VT_VERSION_MAJOR != 1
#error "expected libghostty-vt 1.x"
#endif

  GhosttyTerminal terminal;
  if (ghostty_terminal_new(NULL, &terminal, 80, 24) != GHOSTTY_SUCCESS)
    return 1;

  const char *text = "hello\x1b]2;smoke\x07";
  ghostty_terminal_vt_write(terminal, (const uint8_t *)text, strlen(text));

  uint16_t x = 0;
  if (ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_X, &x) !=
          GHOSTTY_SUCCESS ||
      x != 5) {
    fprintf(stderr, "cursor x = %u, expected 5\n", x);
    return 2;
  }

  GhosttyString title = {0};
  if (ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TITLE, &title) !=
          GHOSTTY_SUCCESS ||
      title.len != 5 || memcmp(title.ptr, "smoke", 5) != 0) {
    fprintf(stderr, "unexpected title\n");
    return 3;
  }

  ghostty_terminal_free(terminal);
  puts("ok");
  return 0;
}
