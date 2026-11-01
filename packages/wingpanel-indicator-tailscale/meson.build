project('wingpanel-indicator-tailscale', 'vala', 'c', version: '0.1.0')

add_project_arguments('-DG_LOG_DOMAIN="io.elementary.wingpanel.tailscale"', language: 'c')

glib_dep = dependency('glib-2.0')
gobject_dep = dependency('gobject-2.0')
json_dep = dependency('json-glib-1.0')

test('model', executable(
    'test-model',
    'src/Model.vala',
    'tests/TestModel.vala',
    dependencies: [glib_dep, gobject_dep, json_dep],
))

wingpanel_dep = dependency('wingpanel')

# Linked into the plugin; its generated constructor registers it on load.
resources = import('gnome').compile_resources(
    'tailscale-resources',
    'src/tailscale.gresource.xml',
    source_dir: 'src',
)

shared_module(
    'tailscale-indicator',
    'src/Model.vala',
    'src/LocalApi.vala',
    'src/Indicator.vala',
    resources,
    dependencies: [
        glib_dep,
        gobject_dep,
        json_dep,
        dependency('gio-2.0'),
        dependency('gio-unix-2.0'),
        dependency('libsoup-3.0'),
        dependency('gtk+-3.0'),
        dependency('granite'),
        wingpanel_dep,
    ],
    install: true,
    install_dir: wingpanel_dep.get_variable(
        pkgconfig: 'indicatorsdir',
        pkgconfig_define: ['libdir', get_option('prefix') / get_option('libdir')],
    ),
)
