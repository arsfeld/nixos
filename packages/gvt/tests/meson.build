# Each test compiles the sources it covers directly, since they are internal
# to the library.
test(
  'engine-test',
  executable(
    'engine-test',
    'engine-test.vala',
    gvt_sources,
    dependencies: gvt_deps,
  ),
  args: ['--tap'],
  protocol: 'tap',
  env: ['G_TEST_SRCDIR=' + meson.current_source_dir()],
)

test(
  'pty-test',
  executable(
    'pty-test',
    'pty-test.vala',
    gvt_sources,
    dependencies: gvt_deps,
  ),
  args: ['--tap'],
  protocol: 'tap',
)

# The widget tests draw with the cairo renderer, whose output is the same on
# every machine, and with the fonts.conf monospace package.nix provides. The
# sandbox has no session bus, so accessibility and portals, which want one,
# are off. Every terminal reads the clipboard-read key, so they all use a
# memory GSettings backend (the sandbox has no writable home), in which
# selection-test also flips it.
foreach name : ['terminal-test', 'renderer-test', 'input-test', 'selection-test',
             'search-test']
  test(
    name,
    executable(
      name,
      name + '.vala',
      'widget-helpers.vala',
      gvt_sources,
      dependencies: gvt_deps,
    ),
    args: ['--tap'],
    protocol: 'tap',
    env: ['GSK_RENDERER=cairo', 'GTK_A11Y=none', 'GDK_DEBUG=no-portals',
          'GSETTINGS_BACKEND=memory'],
  )
endforeach
