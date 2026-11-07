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
# are off.
foreach name : ['terminal-test', 'renderer-test']
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
    env: ['GSK_RENDERER=cairo', 'GTK_A11Y=none', 'GDK_DEBUG=no-portals'],
  )
endforeach
