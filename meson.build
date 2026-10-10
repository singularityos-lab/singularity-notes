project('singularity-notes', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0'
)

i18n = import('i18n')
add_project_arguments('-DGETTEXT_PACKAGE="singularity-notes"', language: 'c')
subdir('po')

gtk_dep  = dependency('gtk4')
gee_dep  = dependency('gee-0.8')
gio_dep  = dependency('gio-2.0')
json_dep = dependency('json-glib-1.0')
soup_dep = dependency('libsoup-3.0')
gst_dep  = dependency('gstreamer-1.0')
poppler_dep = dependency('poppler-glib')
xml_dep  = dependency('libxml-2.0')
zlib_dep = dependency('zlib')
gnutls_dep = dependency('gnutls', version: '>= 3.6.13')
pangocairo_dep = dependency('pangocairo')
m_dep = meson.get_compiler('c').find_library('m', required: false)

libsingularity_dep = dependency('singularity-1.0',
  fallback: ['libsingularity', 'libsingularity_dep']
)

if not meson.is_subproject() and libsingularity_dep.type_name() == 'internal'
  libsingularity_vapi_dir = join_paths(meson.project_build_root(), 'subprojects', 'libsingularity')
  add_project_arguments(['--vapidir=' + libsingularity_vapi_dir], language: 'vala')
endif

add_project_arguments(['--vapidir', meson.current_source_dir() / 'src' / 'crypto', '--pkg', 'notes-crypto', '--pkg', 'zlib'], language: 'vala')
crypto_inc = include_directories('src/crypto')

gnome = import('gnome')
resources = gnome.compile_resources(
  'singularity-notes-resources',
  'resources/dev.sinty.notes.gresource.xml',
  source_dir: meson.current_source_dir() / 'data' / 'icons',
)

model_sources = files(
  'src/rich_text.vala',
  'src/page_doc.vala',
  'src/notebook.vala',
  'src/sync_merge.vala',
  'src/sync_remote.vala',
  'src/sync_engine.vala',
)

core_sources = files(
  'src/tags.vala',
  'src/history.vala',
  'src/templates.vala',
  'src/lock.vala',
  'src/attachments.vala',
  'src/ocr_index.vala',
  'src/ink/ink.vala',
  'src/media/recording.vala',
  'src/math/math.vala',
  'src/math/equation_files.vala',
  'src/io/zip.vala',
  'src/io/render.vala',
  'src/io/export.vala',
  'src/io/html_md.vala',
  'src/io/clipboard.vala',
  'src/io/import.vala',
  'src/io/onenote.vala',
  'src/ink/handwriting.vala',
  'src/ink/hw_net.vala',
  'src/collab/collab.vala',
  'src/collab/web_access.vala',
  'src/crypto/notes_crypto.c',
)

ui_sources = files(
  'src/editor/objects.vala',
  'src/ink/ink_surface.vala',
  'src/math/math_assistant.vala',
  'src/editor/table_object.vala',
  'src/editor/rich_editor.vala',
  'src/ink/ink_object.vala',
  'src/media/media.vala',
  'src/canvas.vala',
  'src/page_view.vala',
  'src/ribbon.vala',
  'src/dialogs.vala',
  'src/services.vala',
  'src/notes_bus.vala',
    'src/collab.vala',
)

notes_deps = [gtk_dep, gee_dep, gio_dep, json_dep, soup_dep, gst_dep, poppler_dep, xml_dep, zlib_dep, gnutls_dep, pangocairo_dep, m_dep, libsingularity_dep]

executable('singularity-notes',
  model_sources + core_sources + ui_sources + files(
    'src/sync_controller.vala',
    'src/window.vala',
    'src/search.vala',
    'src/app.vala',
  ) + [resources],
  dependencies: notes_deps,
  include_directories: crypto_inc,
  install: true
)

notes_test = executable('notes-test',
  model_sources + core_sources + files('tests/notes_test.vala'),
  dependencies: notes_deps,
  include_directories: crypto_inc,
)
test('notes', notes_test, env: ['TMPDIR=' + meson.current_build_dir(), 'GSETTINGS_BACKEND=memory'])

sync_test = executable('notes-sync-test',
  model_sources + core_sources + files('tests/sync_test.vala'),
  dependencies: notes_deps,
  include_directories: crypto_inc,
)
test('notes-sync', sync_test, env: ['TMPDIR=' + meson.current_build_dir()])

foreach t : ['onenote', 'handwriting', 'collab', 'clipboard']
  t_exe = executable('notes-' + t + '-test',
    model_sources + core_sources + files('tests/' + t + '_test.vala'),
    dependencies: notes_deps,
    include_directories: crypto_inc,
  )
  test('notes-' + t, t_exe, env: ['TMPDIR=' + meson.current_build_dir(), 'XDG_RUNTIME_DIR=' + meson.current_build_dir(), 'GSETTINGS_BACKEND=memory', 'NOTES_FIXTURES=' + meson.current_source_dir() / 'tests' / 'fixtures', 'NOTES_HANDWRITING_DATA=' + meson.current_source_dir() / 'data' / 'handwriting' / 'letters.json', 'NOTES_HANDWRITING_MODEL=' + meson.current_source_dir() / 'data' / 'handwriting' / 'words.shwn'], timeout: 300)
endforeach

executable('notes-sync-e2e',
  model_sources + core_sources + files('tests/sync_e2e.vala'),
  dependencies: notes_deps,
  include_directories: crypto_inc,
)

format_test = executable('notes-format-test',
  model_sources + core_sources + files('tests/format_test.vala'),
  dependencies: notes_deps,
  include_directories: crypto_inc,
)
test('notes-format', format_test, env: ['TMPDIR=' + meson.current_build_dir(), 'XDG_RUNTIME_DIR=' + meson.current_build_dir(), 'NOTES_FIXTURES=' + meson.current_source_dir() / 'tests' / 'fixtures'])

shared_module('singularity-notes-widget',
  files('widget/pinned_widget.vala'),
  dependencies: [gtk_dep, gee_dep, libsingularity_dep],
  install: true,
  install_dir: get_option('libdir') / 'singularity' / 'widgets'
)
install_data('widget/dev.sinty.notes.pinned.widget',
  install_dir: get_option('datadir') / 'singularity' / 'widgets'
)

install_data('data/capabilities/dev.sinty.Collab.Note1.ini',
  install_dir: get_option('datadir') / 'singularity' / 'capabilities')
install_data('data/capabilities/dev.sinty.Notes1.ini',
  install_dir: get_option('datadir') / 'singularity' / 'capabilities'
)

install_data('data/share-targets/dev.sinty.notes.clip.ini',
  install_dir: get_option('datadir') / 'singularity' / 'share-targets'
)

install_data('data/search-providers/dev.sinty.notes.ini',
  install_dir: get_option('datadir') / 'singularity' / 'search-providers'
)

service_conf = configuration_data()
service_conf.set('bindir', get_option('prefix') / get_option('bindir'))
configure_file(
  input: 'data/dev.sinty.notes.service.in',
  output: 'dev.sinty.notes.service',
  configuration: service_conf,
  install: true,
  install_dir: get_option('datadir') / 'dbus-1' / 'services'
)

install_data('data/dev.sinty.notes.desktop',
  install_dir: get_option('datadir') / 'applications'
)

install_data('data/dev.sinty.notes.gschema.xml',
  install_dir: get_option('datadir') / 'glib-2.0' / 'schemas'
)

install_data('data/handwriting/letters.json', 'data/handwriting/words.shwn',
  install_dir: get_option('datadir') / 'singularity-notes' / 'handwriting'
)

install_data('data/dev.sinty.notes.json',
  install_dir: get_option('datadir') / 'singularity' / 'app-settings'
)

install_data('data/icons/dev.sinty.notes.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps'
)
