# singularity-notes

> [!IMPORTANT]
> Report bugs and request features in the
> [Singularity Desktop tracker](https://github.com/singularityos-lab/singularity-desktop/issues/new/choose).

Notes for the [Singularity Desktop Environment](https://github.com/singularityos-lab): notebooks with pages, drawings, tables, tags and recordings, synced with your accounts.

## Requirements

- [Meson](https://mesonbuild.com/) ≥ 1.0
- [Vala](https://vala.dev/) compiler
- GTK4, libgee-0.8, json-glib-1.0, libsoup-3.0, gstreamer-1.0, poppler-glib, libxml-2.0, zlib, gnutls, pangocairo
- [libsingularity](https://github.com/singularityos-lab/libsingularity)

## Build & Install

```sh
meson setup build
meson compile -C build
meson install -C build
```

## Third-party code

- `tests/onenote_test.vala`: the ink test fixture comes from [onenote.rs](https://github.com/msiemens/onenote.rs), Mozilla Public License 2.0.

## License

GPL-3.0-only - see [LICENSE](LICENSE).

## Use of Generative AI

Maintainers may use generative AI tools as assistants while working on singularity-notes. Non-trivial assisted commits disclose the tool, model, and scope of the work.

AI tools may assist with code comments, documentation, repetitive code, and issue triage. Maintainers make project decisions and review every assisted change before it is merged.

Use these trailers for non-trivial assisted commits:

```plain
Assisted-by: <tool>:<model-version>
AI-Scope: <what the tool generated and the prompt or a short prompt summary>
```

Single-line completions, renames, and formatting changes do not need trailers.

Coding agents must also follow [AGENTS.md](AGENTS.md) before changing files,
creating commits, or opening pull requests.
