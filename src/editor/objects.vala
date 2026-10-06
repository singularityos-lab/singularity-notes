using Gtk;

namespace Singularity.Apps.Notes {

    public class MenuHook : Object {
        public Menus.Opener open;

        public MenuHook(owned Menus.Opener open) {
            this.open = (owned) open;
        }
    }

    public class Menus {
        public delegate void Build(Singularity.Widgets.ContextMenu menu);
        public delegate void Opener(Widget w, double x, double y);

        public static void register(Widget w, owned Opener open) {
            w.set_data<MenuHook>("notes-menu", new MenuHook((owned) open));
            w.destroy.connect((d) => d.set_data<MenuHook>("notes-menu", null));
        }

        public static bool open_at(Widget view, double x, double y) {
            var w = view.pick(x, y, PickFlags.DEFAULT);
            while (w != null && w != view) {
                var hook = w.get_data<MenuHook>("notes-menu");
                Graphene.Point p = Graphene.Point().init(0, 0);
                if (hook != null && view.compute_point(w, Graphene.Point().init((float) x, (float) y), out p)) {
                    hook.open(w, p.x, p.y);
                    return true;
                }
                w = w.get_parent();
            }
            return false;
        }

        public static void popup(Widget parent, double x, double y, Build build) {
            Widget host = parent;
            double hx = x;
            double hy = y;
            Widget? view = null;
            if (!(parent is TextView)) view = parent.get_ancestor(typeof(TextView));
            Graphene.Point p = Graphene.Point().init(0, 0);
            if (view != null && parent.compute_point(view, Graphene.Point().init((float) x, (float) y), out p)) {
                host = view;
                hx = p.x;
                hy = p.y;
            }
            var menu = new Singularity.Widgets.ContextMenu(host);
            build(menu);
            var rect = Gdk.Rectangle();
            rect.x = (int) hx;
            rect.y = (int) hy;
            rect.width = 1;
            rect.height = 1;
            menu.set_pointing_to(rect);
            menu.closed.connect(() => {
                Idle.add(() => {
                    if (menu.get_parent() != null) menu.unparent();
                    return Source.REMOVE;
                });
            });
            menu.popup();
        }

        public static void on_secondary(Widget w, owned Build build) {
            var click = new GestureClick();
            click.button = Gdk.BUTTON_SECONDARY;
            click.pressed.connect((n, x, y) => {
                click.set_state(EventSequenceState.CLAIMED);
                popup(w, x, y, build);
            });
            w.add_controller(click);
            register(w, (target, x, y) => popup(target, x, y, build));
        }

        public static void route_secondary(Widget view) {
            var click = new GestureClick();
            click.button = Gdk.BUTTON_SECONDARY;
            click.propagation_phase = PropagationPhase.CAPTURE;
            click.pressed.connect((n, x, y) => {
                if (open_at(view, x, y)) click.set_state(EventSequenceState.CLAIMED);
            });
            view.add_controller(click);
        }
    }

    public abstract class NoteObject : Box {
        public signal void changed();
        public signal void status(string message);
        public signal void remove_requested();

        public weak RichEditor? editor = null;
        protected int available_width = 600;
        public static weak RichEditor? building = null;

        protected NoteObject() {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            editor = building;
            add_css_class("notes-object");
            margin_top = 4;
            margin_bottom = 4;
        }

        public abstract Block to_block();

        public virtual void set_available_width(int w) {
            available_width = int.max(120, w);
        }

        public virtual string search_text() {
            return "";
        }

        public string notes_dir() {
            return editor != null ? editor.notes_dir : "";
        }

        public string resolve(string path) {
            if (Path.is_absolute(path)) return path;
            if (path.has_prefix("file://")) return File.new_for_uri(path).get_path() ?? path;
            return Path.build_filename(notes_dir(), Uri.unescape_string(path) ?? path);
        }

        protected Gtk.Window? window() {
            return get_root() as Gtk.Window;
        }
    }

    public class RuleObject : NoteObject {
        public RuleObject() {
            base();
            var sep = new Separator(Orientation.HORIZONTAL);
            sep.margin_top = 8;
            sep.margin_bottom = 8;
            append(sep);
            Menus.on_secondary(this, (m) => m.add_item(_("Remove Line"), "edit-delete-symbolic", () => remove_requested()));
        }

        public override void set_available_width(int w) {
            base.set_available_width(w);
            set_size_request(available_width, -1);
        }

        public override Block to_block() {
            return new Block(BlockKind.RULE);
        }
    }

    public class ImageObject : NoteObject {
        public Block block;
        private Picture picture;
        private Overlay overlay;
        private int natural_w = 0;
        private int natural_h = 0;
        private int drag_start_w = 0;
        private string ocr_text = "";

        public ImageObject(Block block) {
            base();
            this.block = block;
            add_css_class("notes-image-object");
            overlay = new Overlay();
            picture = new Picture();
            picture.can_shrink = true;
            picture.content_fit = ContentFit.CONTAIN;
            picture.add_css_class("notes-image");
            picture.alternative_text = block.alt;
            overlay.child = picture;
            var handle = new Box(Orientation.HORIZONTAL, 0);
            handle.add_css_class("notes-resize-handle");
            handle.set_size_request(14, 14);
            handle.halign = Align.END;
            handle.valign = Align.END;
            handle.set_cursor_from_name("se-resize");
            handle.tooltip_text = _("Drag to resize");
            var drag = new GestureDrag();
            drag.drag_begin.connect(() => drag_start_w = current_width());
            drag.drag_update.connect((dx, dy) => {
                block.width = (int) (drag_start_w + dx).clamp(48, available_width);
                apply_size();
            });
            drag.drag_end.connect(() => changed());
            handle.add_controller(drag);
            overlay.add_overlay(handle);
            append(overlay);
            load_file();
            Menus.on_secondary(picture, (m) => build_menu(m));
        }

        private void load_file() {
            string file = resolve(block.image);
            if (FileUtils.test(file, FileTest.EXISTS)) {
                try {
                    var texture = Gdk.Texture.from_filename(file);
                    picture.paintable = texture;
                    natural_w = texture.get_width();
                    natural_h = texture.get_height();
                } catch (Error e) {
                    picture.set_filename(file);
                    var p = picture.paintable;
                    natural_w = p != null ? p.get_intrinsic_width() : 0;
                    natural_h = p != null ? p.get_intrinsic_height() : 0;
                }
            }
            string cached = OcrIndex.cached_text(file);
            if (cached != null) ocr_text = cached;
            apply_size();
        }

        private int current_width() {
            if (block.width > 0) return int.min(block.width, available_width);
            int w = natural_w > 0 ? natural_w : 360;
            if (block.kind == BlockKind.EQUATION) w = natural_w > 0 ? natural_w / 2 : 200;
            return int.min(w, int.min(available_width, 640));
        }

        private void apply_size() {
            int w = current_width();
            int h = natural_w > 0 ? (int) ((double) natural_h * w / natural_w) : 60;
            picture.set_size_request(w, h);
            overlay.set_size_request(w, h);
            overlay.halign = Align.START;
        }

        public override void set_available_width(int w) {
            base.set_available_width(w);
            apply_size();
        }

        public override Block to_block() {
            var b = RichText.image_block(block.alt, block.image, block.width);
            b.anchor = block.anchor;
            return b;
        }

        public override string search_text() {
            return ocr_text;
        }

        protected virtual void build_menu(Singularity.Widgets.ContextMenu m) {
            m.add_item(_("Copy Text from Picture"), "edit-copy-symbolic", () => recognize(false));
            m.add_item(_("Insert Text from Picture"), "insert-text-symbolic", () => recognize(true));
            m.add_separator();
            m.add_item(_("Rotate Left"), "object-rotate-left-symbolic", () => rotate(false));
            m.add_item(_("Rotate Right"), "object-rotate-right-symbolic", () => rotate(true));
            if (block.width > 0) m.add_item(_("Original Size"), "zoom-original-symbolic", () => {
                block.width = 0;
                apply_size();
                changed();
            });
            m.add_item(_("Alt Text…"), "document-edit-symbolic", () => edit_alt());
            m.add_separator();
            m.add_item(_("Open"), "document-open-symbolic", () => open_external(resolve(block.image), window()));
            m.add_item(_("Remove Picture"), "edit-delete-symbolic", () => remove_requested());
        }

        public static void open_external(string path, Gtk.Window? parent) {
            var launcher = new FileLauncher(File.new_for_path(path));
            launcher.launch.begin(parent, null, (o, r) => {
                try {
                    launcher.launch.end(r);
                } catch (Error e) {
                }
            });
        }

        private void recognize(bool insert) {
            string file = resolve(block.image);
            status(_("Reading the text in the picture…"));
            OcrIndex.get_default().recognize.begin(file, (o, r) => {
                string? text = OcrIndex.get_default().recognize.end(r);
                if (text == null) {
                    status(OcrIndex.get_default().last_error);
                    return;
                }
                ocr_text = text;
                if (text.strip() == "") {
                    status(_("No text was found in the picture"));
                    return;
                }
                if (insert && editor != null) {
                    editor.insert_text_after_object(this, text.strip());
                } else {
                    get_clipboard().set_text(text.strip());
                    status(_("Text copied"));
                }
            });
        }

        private void rotate(bool clockwise) {
            string file = resolve(block.image);
            try {
                var pix = new Gdk.Pixbuf.from_file(file);
                var rotated = pix.rotate_simple(clockwise ? Gdk.PixbufRotation.CLOCKWISE : Gdk.PixbufRotation.COUNTERCLOCKWISE);
                string dir = Path.get_dirname(file);
                string name = Path.get_basename(file);
                int dot = name.last_index_of(".");
                string stem = dot > 0 ? name.substring(0, dot) : name;
                if (stem.contains("-r")) stem = stem.substring(0, stem.last_index_of("-r"));
                string target = Path.build_filename(dir, "%s-r%s.png".printf(stem, Uuid.string_random().substring(0, 6)));
                rotated.savev(target, "png", {}, {});
                block.image = Path.build_filename(Path.get_dirname(block.image), Path.get_basename(target));
                if (block.width > 0 && natural_w > 0) block.width = (int) ((double) block.width * natural_h / natural_w);
                load_file();
                changed();
            } catch (Error e) {
                status(_("The picture could not be rotated"));
            }
        }

        private void edit_alt() {
            var app = (Gtk.Application) GLib.Application.get_default();
            var dialog = new Singularity.Widgets.ConfirmDialog(app, _("Alt Text"), "insert-image",
                _("Describe the picture for people who cannot see it."), _("Save"), Singularity.Widgets.ConfirmDialog.ActionStyle.SUGGESTED);
            dialog.transient_for = window();
            var entry = new Entry();
            entry.text = block.alt;
            dialog.custom_area.append(entry);
            entry.activate.connect(() => dialog.response(Singularity.Widgets.ConfirmDialog.Response.PRIMARY));
            dialog.response.connect((r) => {
                if (r == Singularity.Widgets.ConfirmDialog.Response.PRIMARY) {
                    block.alt = entry.text.strip();
                    picture.alternative_text = block.alt;
                    changed();
                }
                dialog.close_dialog();
            });
            dialog.open_dialog();
        }
    }

    public class FileObject : NoteObject {
        public Block block;
        private Label name_label;

        public FileObject(Block block) {
            base();
            this.block = block;
            add_css_class("notes-file-object");
            var row = new Box(Orientation.HORIZONTAL, 10);
            row.add_css_class("notes-file");
            string path = resolve(block.image);
            bool uncertain;
            string type = ContentType.guess(path, null, out uncertain);
            var icon = new Image.from_gicon(ContentType.get_icon(type));
            icon.pixel_size = 32;
            row.append(icon);
            var labels = new Box(Orientation.VERTICAL, 0);
            labels.valign = Align.CENTER;
            name_label = new Label(block.alt != "" ? block.alt : Path.get_basename(path));
            name_label.xalign = 0;
            name_label.ellipsize = Pango.EllipsizeMode.MIDDLE;
            name_label.add_css_class("notes-file-name");
            labels.append(name_label);
            string detail = ContentType.get_description(type);
            try {
                var info = File.new_for_path(path).query_info(FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
                detail = "%s, %s".printf(detail, format_size(info.get_size()));
            } catch (Error e) {
                detail = _("File not found");
            }
            var sub = new Label(detail);
            sub.xalign = 0;
            sub.add_css_class("dim-label");
            sub.add_css_class("caption");
            labels.append(sub);
            row.append(labels);
            var click = new GestureClick();
            click.pressed.connect((n) => {
                if (n == 2) ImageObject.open_external(path, window());
            });
            row.add_controller(click);
            row.tooltip_text = _("Double-click to open");
            append(row);
            halign = Align.START;
            Menus.on_secondary(row, (m) => {
                m.add_item(_("Open"), "document-open-symbolic", () => ImageObject.open_external(path, window()));
                m.add_item(_("Save a Copy…"), "document-save-as-symbolic", () => save_copy(path));
                if ((Attachments.is_pdf(path) || Attachments.is_document(path)) && editor != null) {
                    m.add_item(_("Insert as Printout"), "document-print-symbolic", () => editor.insert_printout_after(this, path));
                }
                m.add_separator();
                m.add_item(_("Remove Attachment"), "edit-delete-symbolic", () => remove_requested());
            });
        }

        private void save_copy(string path) {
            var dialog = new FileDialog();
            dialog.initial_name = Path.get_basename(path);
            dialog.save.begin(window(), null, (o, r) => {
                try {
                    var target = dialog.save.end(r);
                    if (target != null) File.new_for_path(path).copy(target, FileCopyFlags.OVERWRITE);
                } catch (Error e) {
                }
            });
        }

        public override Block to_block() {
            var b = new Block(block.kind);
            b.alt = block.alt;
            b.image = block.image;
            b.anchor = block.anchor;
            return b;
        }

        public override string search_text() {
            return block.alt;
        }
    }
}
