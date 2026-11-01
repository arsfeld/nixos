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
