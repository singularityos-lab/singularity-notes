using Gtk;

namespace Singularity.Apps.Notes {

    public class ContainerFrame : Box {
        public Container model;
        public RichEditor editor;
        private Box grip;
        private int drag_x;
        private int drag_y;
        private int drag_w;
        public weak CanvasView canvas;

        public ContainerFrame(CanvasView canvas, Container model, RichEditor editor) {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            this.canvas = canvas;
            this.model = model;
            this.editor = editor;
            add_css_class("notes-container");
            grip = new Box(Orientation.HORIZONTAL, 0);
            grip.add_css_class("notes-container-grip");
            grip.set_size_request(-1, 10);
            grip.set_cursor_from_name("move");
            grip.tooltip_text = _("Drag to move this note container");
            var move = new GestureDrag();
            move.drag_begin.connect(() => {
                drag_x = model.x;
                drag_y = model.y;
            });
            move.drag_update.connect((dx, dy) => {
                model.x = int.max(0, (int) (drag_x + dx));
                model.y = int.max(0, (int) (drag_y + dy));
                canvas.place(this);
            });
            move.drag_end.connect(() => canvas.container_changed());
            grip.add_controller(move);
            Menus.on_secondary(grip, (m) => {
                m.add_item(_("Delete Container"), "edit-delete-symbolic", () => canvas.remove_frame(this));
            });
            append(grip);
            var row = new Box(Orientation.HORIZONTAL, 0);
            editor.view.hexpand = true;
            row.append(editor.view);
            var edge = new Box(Orientation.VERTICAL, 0);
            edge.add_css_class("notes-container-edge");
            edge.set_size_request(8, -1);
            edge.set_cursor_from_name("ew-resize");
            edge.tooltip_text = _("Drag to change the width");
            var resize = new GestureDrag();
            resize.drag_begin.connect(() => drag_w = model.width);
            resize.drag_update.connect((dx, dy) => {
                model.width = (int) (drag_w + dx).clamp(120, 2400);
                set_size_request(model.width, -1);
            });
            resize.drag_end.connect(() => canvas.container_changed());
            edge.add_controller(resize);
            row.append(edge);
            append(row);
            set_size_request(model.width, -1);
            editor.view.buffer.changed.connect(() => schedule_fit());
            editor.view.resized.connect(() => schedule_fit());
            schedule_fit();
        }

        private uint fit_source = 0;
        private int fitted = 0;

        private void schedule_fit() {
            if (fit_source != 0) return;
            fit_source = Timeout.add(60, () => {
                fit_source = 0;
                fit_height();
                return Source.REMOVE;
            });
        }

        private void fit_height() {
            var view = editor.view;
            TextIter end;
            view.buffer.get_end_iter(out end);
            int y, h;
            view.get_line_yrange(end, out y, out h);
            int need = y + h + view.top_margin + view.bottom_margin;
            if (need <= 0 || need == fitted) return;
            fitted = need;
            view.set_size_request(-1, need);
            canvas.place(this);
        }
    }

    public class CanvasView : Box {
        public signal void changed();
        public signal void editor_created(RichEditor editor);

        public string notes_dir = "";
        public string note_id = "";
        public Gee.ArrayList<ContainerFrame> frames = new Gee.ArrayList<ContainerFrame>();
        public InkSurface ink;
        public string ink_path = "";
        private Fixed fixed;
        private Overlay overlay;
        private DrawingArea paper;
        private int width_hint = 1600;
        private int height_hint = 1200;
        public string rule = "";
        private bool ink_dirty = false;
        private uint ink_source = 0;
        private HandwritingCorrection? correction = null;
        private bool page_selected = false;
        private bool selecting_page = false;

        public CanvasView() {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class("notes-canvas");
            overlay = new Overlay();
            paper = new DrawingArea();
            paper.set_draw_func((area, cr, w, h) => draw_paper(cr, w, h));
            overlay.child = paper;
            fixed = new Fixed();
            overlay.add_overlay(fixed);
            ink = new InkSurface(new InkDoc());
            ink.grow = true;
            ink.halign = Align.START;
            ink.valign = Align.START;
            overlay.add_overlay(ink);
            append(overlay);
            var click = new GestureClick();
            click.released.connect((n, x, y) => {
                if (InkTools.get_default().drawing) return;
                var picked = fixed.pick(x, y, PickFlags.DEFAULT);
                if (picked == fixed || picked == paper || picked == null || picked == overlay) add_container_at((int) x, (int) y);
            });
            fixed.add_controller(click);
            ink.changed.connect(() => {
                ink_dirty = true;
                if (ink_source != 0) Source.remove(ink_source);
                ink_source = Timeout.add(700, () => {
                    ink_source = 0;
                    commit_ink();
                    return Source.REMOVE;
                });
                grow_to_fit();
            });
            ink.convert_text_requested.connect((strokes) => convert_ink(strokes, false));
            ink.convert_math_requested.connect((strokes) => convert_ink(strokes, true));
            ink.correct_requested.connect(() => {
                if (correction != null) correction.open(this);
            });
            InkTools.get_default().notify["tool"].connect(sync_ink_target);
            sync_ink_target();
        }

        private void convert_ink(Gee.List<Stroke> strokes, bool math) {
            var r = HandwritingRecognizer.get_default();
            if (strokes.size == 0) return;
            if (r.busy) {
                ink.status(_("Still reading the previous handwriting"));
                return;
            }
            foreach (var f in frames) r.add_text(f.editor.serialize());
            double x0 = double.MAX, y0 = double.MAX;
            foreach (var s in strokes) {
                double sx0, sy0, sx1, sy1;
                s.bounds(out sx0, out sy0, out sx1, out sy1);
                x0 = double.min(x0, sx0);
                y0 = double.min(y0, sy0);
            }
            ink.status(_("Reading the handwriting…"));
            r.recognize_async.begin(strokes, (o, res) => {
                string text = r.recognize_async.end(res).strip();
                if (text == "") {
                    ink.status(_("No handwriting was recognized"));
                    return;
                }
                if (math) {
                    MathAssistant.open(add_container_at((int) x0, (int) y0), text.replace("\n", " "));
                    return;
                }
                ink.remove_strokes(strokes);
                var ed = add_container_at((int) x0, (int) y0, markdown_of(text));
                changed();
                correction = new HandwritingCorrection(strokes, text, (fixed) => {
                    ed.load(markdown_of(fixed));
                    ed.changed();
                });
                ink.can_correct = true;
                correction.offer(this);
            });
        }

        private static string markdown_of(string text) {
            return text.replace("\n", "\n\n");
        }

        private void sync_ink_target() {
            ink.can_target = InkTools.get_default().drawing;
        }

        private void draw_paper(Cairo.Context cr, int w, int h) {
            if (rule == "") return;
            cr.set_source_rgba(0.48, 0.65, 0.85, 0.35);
            cr.set_line_width(1);
            for (int y = PageBackground.SPACING; y < h; y += PageBackground.SPACING) {
                cr.move_to(0, y + 0.5);
                cr.line_to(w, y + 0.5);
            }
            if (rule == "grid") {
                for (int x = PageBackground.SPACING; x < w; x += PageBackground.SPACING) {
                    cr.move_to(x + 0.5, 0);
                    cr.line_to(x + 0.5, h);
                }
            }
            cr.stroke();
        }

        public void load(PageDoc doc) {
            foreach (var f in frames) fixed.remove(f);
            frames.clear();
            height_hint = int.max(1200, doc.meta.canvas_height);
            ink_path = doc.meta.ink;
            ink.doc = ink_path != "" ? InkDoc.load(Path.build_filename(notes_dir, ink_path)) : new InkDoc();
            rule = doc.meta.rule;
            foreach (var c in doc.containers) add_frame(c, false);
            grow_to_fit();
            ink.queue_draw();
            paper.queue_draw();
        }

        private ContainerFrame add_frame(Container c, bool focus) {
            var ed = new RichEditor(8);
            ed.notes_dir = notes_dir;
            ed.note_id = note_id;
            ed.view.top_margin = 2;
            ed.view.bottom_margin = 4;
            ed.load(c.markdown);
            var frame = new ContainerFrame(this, c, ed);
            ed.changed.connect(() => changed());
            ed.select_page_requested.connect(() => select_page());
            ed.page_cut_requested.connect(() => cut_page());
            ed.page_clip = () => page_selected ? page_clip() : null;
            ed.buffer.mark_set.connect((loc, mark) => {
                if (page_selected && !selecting_page && (mark == ed.buffer.get_insert() || mark == ed.buffer.get_selection_bound())) mark_page(false);
            });
            frames.add(frame);
            fixed.put(frame, c.x, c.y);
            editor_created(ed);
            if (focus) Idle.add(() => {
                ed.view.grab_focus();
                return Source.REMOVE;
            });
            return frame;
        }

        public RichEditor add_container_at(int x, int y, string markdown = "") {
            var c = new Container(x, y, 480, markdown);
            var f = add_frame(c, true);
            grow_to_fit();
            return f.editor;
        }

        public void place(ContainerFrame f) {
            fixed.move(f, f.model.x, f.model.y);
            grow_to_fit();
        }

        public void container_changed() {
            grow_to_fit();
            changed();
        }

        public void remove_frame(ContainerFrame f) {
            fixed.remove(f);
            frames.remove(f);
            changed();
        }

        private void grow_to_fit() {
            int w = 1400;
            int h = height_hint;
            foreach (var f in frames) {
                int fh = f.get_height() > 0 ? f.get_height() : 200;
                w = int.max(w, f.model.x + f.model.width + 200);
                h = int.max(h, f.model.y + fh + 400);
            }
            int iw, ih;
            ink.doc.extent(out iw, out ih);
            w = int.max(w, iw + 200);
            h = int.max(h, ih + 400);
            width_hint = w;
            ink.doc.width = w;
            ink.doc.height = h;
            paper.set_size_request(w, h);
            ink.queue_resize();
        }

        public int canvas_height {
            get { return height_hint; }
        }

        private void commit_ink() {
            if (!ink_dirty || note_id == "") return;
            ink_dirty = false;
            string old = ink_path != "" ? Path.build_filename(notes_dir, ink_path) : "";
            if (ink.doc.strokes.size == 0) {
                if (old != "") FileUtils.unlink(old);
                ink_path = "";
                changed();
                return;
            }
            string fresh = Attachments.new_path(notes_dir, note_id, "ink-", "svg");
            try {
                ink.doc.save(fresh);
            } catch (Error e) {
                return;
            }
            ink_path = Attachments.relative(note_id, fresh);
            if (old != "" && old != fresh) FileUtils.unlink(old);
            changed();
        }

        public void flush_ink() {
            if (ink_source != 0) {
                Source.remove(ink_source);
                ink_source = 0;
                commit_ink();
            }
        }

        public void fill(PageDoc doc) {
            flush_ink();
            doc.containers.clear();
            foreach (var f in frames) {
                f.model.markdown = f.editor.serialize();
                doc.containers.add(f.model);
            }
            doc.meta.ink = ink_path;
            doc.meta.canvas_height = 0;
        }

        public void select_page() {
            selecting_page = true;
            foreach (var f in frames) f.editor.select_everything();
            selecting_page = false;
            mark_page(true);
        }

        private void mark_page(bool on) {
            page_selected = on;
            foreach (var f in frames) {
                if (on) f.add_css_class("page-selected");
                else f.remove_css_class("page-selected");
            }
        }

        public NoteClip page_clip() {
            flush_ink();
            var clip = new NoteClip(notes_dir, note_id);
            var sorted = new Gee.ArrayList<ContainerFrame>();
            sorted.add_all(frames);
            sorted.sort((a, b) => a.model.y != b.model.y ? a.model.y - b.model.y : a.model.x - b.model.x);
            foreach (var f in sorted) {
                string md = f.editor.serialize();
                if (md.strip() == "") continue;
                clip.blocks.add_all(RichText.parse(md));
            }
            if (ink_path != "") clip.blocks.add(RichText.image_block(_("Drawing"), ink_path, 0));
            return clip;
        }

        private void cut_page() {
            mark_page(false);
            foreach (var f in frames) fixed.remove(f);
            frames.clear();
            ink.doc.strokes.clear();
            ink_dirty = true;
            commit_ink();
            ink.queue_draw();
            changed();
        }

        public Gee.List<RichEditor> editors() {
            var list = new Gee.ArrayList<RichEditor>();
            foreach (var f in frames) list.add(f.editor);
            return list;
        }
    }
}
