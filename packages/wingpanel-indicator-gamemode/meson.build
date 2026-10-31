project('wingpanel-indicator-gamemode', 'vala', 'c', version: '0.1.0')

add_project_arguments('-DG_LOG_DOMAIN="io.elementary.wingpanel.gamemode"', language: 'c')

glib_dep = dependency('glib-2.0')
gobject_dep = dependency('gobject-2.0')

test('names', executable(
    'test-names',
    'src/Names.vala',
    'tests/TestNames.vala',
    dependencies: [glib_dep, gobject_dep],
))
