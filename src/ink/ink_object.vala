using Gtk;

namespace Singularity.Apps.Notes {

    public delegate void HandwritingReplace(string text);

    public class HandwritingCorrection : Object {
        public string text { get; private set; }
        private Gee.ArrayList<Stroke> strokes = new Gee.ArrayList<Stroke>();
        private HandwritingReplace replace;

        public HandwritingCorrection(Gee.List<Stroke> strokes, string text, owned HandwritingReplace replace) {
            foreach (var s in strokes) this.strokes.add(s.copy());
            this.text = text;
            this.replace = (owned) replace;
        }

        public void offer(Widget anchor) {
            var window = anchor.get_root() as Singularity.Widgets.Window;
            if (window == null) return;
            var toast = new Singularity.Widgets.Toast(_("Handwriting converted to text"));
            toast.button_label = _("Correct");
            toast.timeout = 8;
            toast.button_clicked.connect(() => open(anchor));
            window.add_toast(toast);
        }

        public void open(Widget anchor) {
            var app = (Gtk.Application) GLib.Application.get_default();
            var dialog = new Singularity.Widgets.ConfirmDialog(app, _("Correct Recognized Text"), "document-edit-symbolic",
                _("Fix what Notes read. Notes learns your handwriting from each correction."), _("Correct"), Singularity.Widgets.ConfirmDialog.ActionStyle.SUGGESTED);
            dialog.transient_for = anchor.get_root() as Gtk.Window;
            var view = new TextView();
            view.wrap_mode = WrapMode.WORD_CHAR;
            view.buffer.text = text;
            view.set_size_request(360, 96);
            view.add_css_class("notes-correction-text");
            dialog.custom_area.append(view);
            dialog.response.connect((r) => {
                string fixed = view.buffer.text.strip();
                if (r == Singularity.Widgets.ConfirmDialog.Response.PRIMARY && fixed != "") {
                    if (fixed != text) replace(fixed);
                    var recognizer = HandwritingRecognizer.get_default();
                    if (!recognizer.busy) recognizer.learn_text(strokes, fixed);
                    text = fixed;
                }
                dialog.close_dialog();
            });
            dialog.open_dialog();
            view.grab_focus();
        }
    }

    public class InkObject : NoteObject {
        public Block block;
        public InkSurface surface;
        private uint commit_source = 0;
        private HandwritingCorrection? correction = null;
        private int drag_start_h = 0;
        private bool dirty = false;

        public InkObject(Block block) {
            base();
            this.block = block;
            add_css_class("notes-ink-object");
            var doc = InkDoc.load(resolve(block.image));
            surface = new InkSurface(doc);
            surface.set_size_request(-1, doc.height);
            surface.changed.connect(() => {
                dirty = true;
                schedule_commit();
            });
            surface.status.connect((m) => status(m));
            surface.convert_text_requested.connect((strokes) => convert_to_text(strokes));
            surface.convert_math_requested.connect((strokes) => convert_to_math(strokes));
            surface.correct_requested.connect(() => {
                if (correction != null) correction.open(this);
            });
            var frame = new Box(Orientation.VERTICAL, 0);
            frame.add_css_class("notes-ink-frame");
            frame.append(surface);
            append(frame);
            var handle = new Box(Orientation.HORIZONTAL, 0);
            handle.add_css_class("notes-ink-handle");
            handle.set_size_request(80, 8);
            handle.halign = Align.CENTER;
            handle.set_cursor_from_name("ns-resize");
            handle.tooltip_text = _("Drag to make the drawing space taller or shorter");
            var drag = new GestureDrag();
            drag.drag_begin.connect(() => drag_start_h = surface.doc.height);
            drag.drag_update.connect((dx, dy) => {
                surface.doc.height = (int) (drag_start_h + dy).clamp(80, 4000);
                surface.set_size_request(-1, surface.doc.height);
            });
            drag.drag_end.connect(() => {
                dirty = true;
                schedule_commit();
            });
            handle.add_controller(drag);
            append(handle);
            destroy.connect(() => {
                if (commit_source != 0) {
                    Source.remove(commit_source);
                    commit_source = 0;
                    commit();
                }
            });
        }

        public override void set_available_width(int w) {
            base.set_available_width(w);
            surface.doc.width = int.max(surface.doc.width, available_width);
            set_size_request(available_width, -1);
        }

        private void schedule_commit() {
            if (commit_source != 0) Source.remove(commit_source);
            commit_source = Timeout.add(700, () => {
                commit_source = 0;
                commit();
                return Source.REMOVE;
            });
        }

        public void commit() {
            if (!dirty || editor == null || editor.note_id == "") return;
            dirty = false;
            string old = resolve(block.image);
            string fresh = Attachments.new_path(notes_dir(), editor.note_id, "ink-", "svg");
            try {
                surface.doc.save(fresh);
            } catch (Error e) {
                status(_("The drawing could not be saved"));
                return;
            }
            block.image = Attachments.relative(editor.note_id, fresh);
            if (old != fresh && Path.get_basename(old).has_prefix("ink-")) FileUtils.unlink(old);
            changed();
        }

        private HandwritingRecognizer? handwriting() {
            var r = HandwritingRecognizer.get_default();
            if (r.busy) {
                status(_("Still reading the previous handwriting"));
                return null;
            }
            if (editor != null) {
                var sb = new StringBuilder();
                for (int l = 0; l < editor.line_count(); l++) sb.append(editor.line_text(l)).append("\n");
                r.add_text(sb.str);
            }
            return r;
        }

        private void convert_to_text(Gee.List<Stroke> strokes) {
            var r = handwriting();
            if (r == null) return;
            status(_("Reading the handwriting…"));
            r.recognize_async.begin(strokes, (o, res) => {
                string text = r.recognize_async.end(res).strip();
                if (text == "") {
                    status(_("No handwriting was recognized"));
                    return;
                }
                surface.remove_strokes(strokes);
                if (editor == null) return;
                int line = editor.object_line(this);
                editor.insert_text_after_object(this, text);
                TextIter from, start, end;
                if (line < 0) return;
                if (!editor.buffer.get_iter_at_line(out from, line)) return;
                if (!from.forward_search(text, TextSearchFlags.TEXT_ONLY, out start, out end, null)) return;
                var first = editor.buffer.create_mark(null, start, true);
                var last = editor.buffer.create_mark(null, end, false);
                correction = new HandwritingCorrection(strokes, text, (fixed) => {
                    if (editor == null || first.get_deleted() || last.get_deleted()) return;
                    TextIter a, b;
                    editor.buffer.get_iter_at_mark(out a, first);
                    editor.buffer.get_iter_at_mark(out b, last);
                    editor.buffer.delete(ref a, ref b);
                    editor.buffer.get_iter_at_mark(out a, first);
                    editor.buffer.insert(ref a, fixed, -1);
                    editor.changed();
                });
                surface.can_correct = true;
                correction.offer(this);
            });
        }

        private void convert_to_math(Gee.List<Stroke> strokes) {
            var r = handwriting();
            if (r == null) return;
            status(_("Reading the handwriting…"));
            r.recognize_async.begin(strokes, (o, res) => {
                string text = r.recognize_async.end(res).strip();
                if (text != "") {
                    if (editor != null) MathAssistant.open(editor, text.replace("\n", " "));
                    return;
                }
                double ox, oy;
                var png = surface.doc.render(strokes, 2.0, out ox, out oy);
                OcrIndex.get_default().recognize_surface.begin(png, (o2, r2) => {
                    string? ocr = OcrIndex.get_default().recognize_surface.end(r2);
                    if (ocr == null) {
                        status(OcrIndex.get_default().last_error);
                        return;
                    }
                    if (editor != null) MathAssistant.open(editor, ocr.strip().replace("\n", " "));
                });
            });
        }

        public override Block to_block() {
            if (commit_source != 0) {
                Source.remove(commit_source);
                commit_source = 0;
                commit();
            }
            var b = RichText.image_block(block.alt != "" ? block.alt : _("Drawing"), block.image, 0);
            b.anchor = block.anchor;
            return b;
        }

        public static Block create_new(string notes_dir, string note_id, int width) throws Error {
            var doc = new InkDoc();
            doc.width = width;
            doc.height = 240;
            string path = Attachments.new_path(notes_dir, note_id, "ink-", "svg");
            doc.save(path);
            return RichText.image_block(_("Drawing"), Attachments.relative(note_id, path), 0);
        }
    }

    public class EquationObject : ImageObject {
        public EquationObject(Block block) {
            base(block);
            add_css_class("notes-equation");
            var click = new GestureClick();
            click.pressed.connect((n) => {
                if (n == 2) edit();
            });
            add_controller(click);
            var eq = EquationFiles.load(resolve(block.image), block.alt);
            tooltip_text = _("Double-click to edit the equation");
            update_property(Gtk.AccessibleProperty.LABEL, eq.speech != "" ? eq.speech : block.alt);
        }

        public string latex() {
            var eq = EquationFiles.load(resolve(block.image), block.alt);
            return eq.latex != "" ? eq.latex : block.alt;
        }

        protected override void build_menu(Singularity.Widgets.ContextMenu m) {
            m.add_item(_("Edit Equation"), "document-edit-symbolic", () => edit());
            m.add_item(_("Solve with Math Assistant"), "applications-science-symbolic", () => {
                if (editor != null) MathAssistant.open(editor, latex());
            });
            m.add_item(_("Copy Equation"), "edit-copy-symbolic", () => {
                var eq = EquationFiles.load(resolve(block.image), block.alt);
                get_clipboard().set_content(eq.content_provider());
                status(_("Equation copied"));
            });
            m.add_separator();
            m.add_item(_("Remove Equation"), "edit-delete-symbolic", () => remove_requested());
        }

        public void edit() {
            if (editor == null) return;
            var eq = EquationFiles.load(resolve(block.image), block.alt);
            EquationFiles.edit_and_save.begin(eq, editor.notes_dir, editor.note_id, get_root() as Gtk.Window, (o, r) => {
                string? rel = EquationFiles.edit_and_save.end(r);
                if (rel == null) {
                    if (EquationFiles.last_error != "") status(EquationFiles.last_error);
                    return;
                }
                block.image = rel;
                block.alt = eq.latex != "" ? eq.latex : eq.speech;
                changed();
                if (editor != null) editor.changed();
            });
        }

        public override Block to_block() {
            var b = RichText.image_block(block.alt, block.image, block.width);
            b.anchor = block.anchor;
            return b;
        }
    }
}
