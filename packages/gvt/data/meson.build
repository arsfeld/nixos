install_data(
  'io.github.arsfeld.gvt.gschema.xml',
  install_dir: get_option('datadir') / 'glib-2.0' / 'schemas',
)

# gschemas.compiled in the build tree, for the tests (GSETTINGS_SCHEMA_DIR).
import('gnome').compile_schemas(build_by_default: true)
