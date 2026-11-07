project('gvt', 'vala', 'c', version: '0.1.0', meson_version: '>= 1.0')

api_version = '1'
gvt_name = 'gvt-' + api_version

add_project_arguments('-DG_LOG_DOMAIN="Gvt"', language: 'c')

vapi_dir = meson.current_source_dir() / 'vapi'
add_project_arguments(['--vapidir', vapi_dir, '--pkg', 'posix'], language: 'vala')

glib_dep = dependency('glib-2.0')
gobject_dep = dependency('gobject-2.0')
gio_dep = dependency('gio-2.0')
gtk_dep = dependency('gtk4')
pango_dep = dependency('pango')
# Meson passes valac `--pkg libghostty-vt`, which finds the handwritten
# binding vapi/libghostty-vt.vapi through --vapidir.
ghostty_dep = dependency('libghostty-vt')

# Math.round () and friends.
m_dep = meson.get_compiler('c').find_library('m', required: false)

gvt_deps = [glib_dep, gobject_dep, gio_dep, gtk_dep, pango_dep, ghostty_dep, m_dep]

# Engine is the only file that may call the libghostty C API.
gvt_sources = files(
  'src/Clipboard.vala',
  'src/Engine.vala',
  'src/Enums.vala',
  'src/Input.vala',
  'src/Keymap.vala',
  'src/Pty.vala',
  'src/Regex.vala',
  'src/Renderer.vala',
  'src/Search.vala',
  'src/Selection.vala',
  'src/Terminal.vala',
  'vapi/posix-extra.vapi',
)

gvt_lib = library(
  gvt_name,
  gvt_sources,
  dependencies: gvt_deps,
  vala_vapi: gvt_name + '.vapi',
  vala_header: 'gvt.h',
  version: meson.project_version(),
  install: true,
  install_dir: [true, get_option('includedir') / gvt_name, true],
)

# Vala packages a consumer of gvt-1.vapi needs.
install_data('gvt-1.deps', install_dir: get_option('datadir') / 'vala' / 'vapi')

import('pkgconfig').generate(
  gvt_lib,
  name: gvt_name,
  description: 'GTK4 terminal widget on libghostty-vt',
  subdirs: gvt_name,
  requires: ['glib-2.0', 'gobject-2.0', 'gio-2.0', 'gtk4', 'pango'],
  requires_private: ['libghostty-vt'],
)

subdir('data')

if get_option('tests')
  subdir('tests')
endif
