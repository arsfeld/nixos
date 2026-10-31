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

wingpanel_dep = dependency('wingpanel')

shared_module(
    'gamemode-indicator',
    'src/Names.vala',
    'src/Client.vala',
    'src/Indicator.vala',
    dependencies: [
        glib_dep,
        gobject_dep,
        dependency('gio-2.0'),
        dependency('gtk+-3.0'),
        wingpanel_dep,
    ],
    install: true,
    install_dir: wingpanel_dep.get_variable(
        pkgconfig: 'indicatorsdir',
        pkgconfig_define: ['libdir', get_option('prefix') / get_option('libdir')],
    ),
)
