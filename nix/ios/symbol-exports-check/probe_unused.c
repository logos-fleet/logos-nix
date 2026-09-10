/* Its own translation unit, and nothing in the app references it -- exactly
   the shape of a Qt symbol only a dlopened Bare module will ever call. The
   linker leaves this archive member out unless -u names it. */
int logos_probe_unused(void) { return 2; }
