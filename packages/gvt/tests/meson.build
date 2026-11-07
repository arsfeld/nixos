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
