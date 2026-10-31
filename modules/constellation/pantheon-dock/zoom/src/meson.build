# Copied into the dock's src/Zoom/ by modules/constellation/pantheon-dock/default.nix.
# ZoomMath.vala must not touch GTK: the unit test links only it and runs
# inside the Nix build sandbox.
zoom_core_sources = files(
    'ZoomMath.vala',
)

zoom_sources = zoom_core_sources

zoom_test = executable(
    'zoom-math-test',
    zoom_core_sources + files('tests' / 'ZoomMathTest.vala'),
    dependencies: dependencies,
)

test('zoom-math', zoom_test)
