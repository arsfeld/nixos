# Copied into the dock's src/Stacks/ by modules/constellation/pantheon-dock.nix.
# Core files must not touch widgets that need a display: the unit test links
# only them and runs inside the Nix build sandbox.
stacks_core_sources = files(
    'StackConfig.vala',
    'StackEntry.vala',
    'StackSource.vala',
)

stacks_sources = stacks_core_sources + files(
    'GridPopover.vala',
    'StackItem.vala',
    'StackStore.vala',
)

stacks_test = executable(
    'stacks-test',
    stacks_core_sources + files('tests' / 'StackTests.vala'),
    dependencies: dependencies,
)

test('stacks', stacks_test)
