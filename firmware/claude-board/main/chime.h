// chime: a short two-tone sound when something needs the user.
#pragma once

void chime_init(void);
// Non-blocking; ignored if a chime played in the last few seconds.
void chime_play(void);
