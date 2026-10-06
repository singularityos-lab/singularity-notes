namespace Singularity.Apps.Notes {

    public class Attachments {
        public static string dir_for(string notes_dir, string note_id) {
            return Path.build_filename(notes_dir, "attachments", note_id);
        }

        public static string clean_name(string name) {
            string n = name.replace(" ", "-").replace("(", "").replace(")", "").replace("[", "").replace("]", "")
                .replace("<", "").replace(">", "").replace("\"", "").replace("|", "").replace("#", "").replace("%", "");
            if (n.has_prefix(".")) n = "file" + n;
            return n != "" ? n : "file";
        }

        public static string unique_path(string dir, string name) {
            string clean = clean_name(name);
            string target = Path.build_filename(dir, clean);
            int n = 2;
            while (FileUtils.test(target, FileTest.EXISTS)) target = Path.build_filename(dir, "%d-%s".printf(n++, clean));
            return target;
        }

        public static string relative(string note_id, string path) {
            return "attachments/%s/%s".printf(note_id, Path.get_basename(path));
        }

        public static string import_file(string notes_dir, string note_id, File file, string? prefix = null) throws Error {
            string dir = dir_for(notes_dir, note_id);
            DirUtils.create_with_parents(dir, 0700);
            string name = file.get_basename() ?? "file";
            if (prefix != null && !name.has_prefix(prefix)) name = prefix + name;
            string target = unique_path(dir, name);
            file.copy(File.new_for_path(target), FileCopyFlags.NONE);
            FileUtils.chmod(target, 0600);
            return relative(note_id, target);
        }

        public static string save_texture(string notes_dir, string note_id, Gdk.Texture texture, string stem = "pasted") throws Error {
            string dir = dir_for(notes_dir, note_id);
            DirUtils.create_with_parents(dir, 0700);
            string target = unique_path(dir, "%s-%s.png".printf(stem, new DateTime.now_local().format("%Y%m%d-%H%M%S")));
            if (!texture.save_to_png(target)) throw new IOError.FAILED(_("The picture could not be saved"));
            return relative(note_id, target);
        }

        public static string new_path(string notes_dir, string note_id, string prefix, string ext) {
            string dir = dir_for(notes_dir, note_id);
            DirUtils.create_with_parents(dir, 0700);
            return Path.build_filename(dir, "%s%s.%s".printf(prefix, Uuid.string_random().substring(0, 8), ext));
        }

        public static bool is_image(string path) {
            string p = path.down();
            return p.has_suffix(".png") || p.has_suffix(".jpg") || p.has_suffix(".jpeg") || p.has_suffix(".gif")
                || p.has_suffix(".webp") || p.has_suffix(".svg") || p.has_suffix(".bmp") || p.has_suffix(".tif") || p.has_suffix(".tiff");
        }

        public static bool is_pdf(string path) {
            return path.down().has_suffix(".pdf");
        }

        public static Gee.List<string> pdf_printout(string notes_dir, string note_id, string pdf_path, double dpi = 110) throws Error {
            var pages = new Gee.ArrayList<string>();
            var doc = new Poppler.Document.from_gfile(File.new_for_path(pdf_path), null, null);
            string dir = dir_for(notes_dir, note_id);
            DirUtils.create_with_parents(dir, 0700);
            string base_name = clean_name(Path.get_basename(pdf_path));
            if (base_name.down().has_suffix(".pdf")) base_name = base_name.substring(0, base_name.length - 4);
            int count = int.min(doc.get_n_pages(), 200);
            double scale = dpi / 72.0;
            for (int i = 0; i < count; i++) {
                var page = doc.get_page(i);
                double w, h;
                page.get_size(out w, out h);
                var surface = new Cairo.ImageSurface(Cairo.Format.RGB24, (int) (w * scale), (int) (h * scale));
                var cr = new Cairo.Context(surface);
                cr.set_source_rgb(1, 1, 1);
                cr.paint();
                cr.scale(scale, scale);
                page.render_for_printing(cr);
                string target = unique_path(dir, "printout-%s-%d.png".printf(base_name, i + 1));
                surface.write_to_png(target);
                pages.add(relative(note_id, target));
            }
            return pages;
        }

        public static bool is_document(string path) {
            string p = path.down();
            return p.has_suffix(".docx") || p.has_suffix(".odt") || p.has_suffix(".md") || p.has_suffix(".markdown")
                || p.has_suffix(".txt") || p.has_suffix(".html") || p.has_suffix(".htm");
        }

        public static Gee.List<string> document_printout(string notes_dir, string note_id, string doc_path) throws Error {
            string work = DirUtils.make_tmp("notes-printout-XXXXXX");
            try {
                uint8[] data;
                FileUtils.get_data(doc_path, out data);
                string p = doc_path.down();
                string md;
                if (p.has_suffix(".docx")) md = Importer.docx_to_markdown(data, work, "doc");
                else if (p.has_suffix(".odt")) md = Importer.odt_to_markdown(data, work, "doc");
                else if (p.has_suffix(".html") || p.has_suffix(".htm")) md = HtmlConverter.to_markdown(((string) data).make_valid((ssize_t) data.length), File.new_for_path(doc_path).get_uri(), false);
                else md = ((string) data).make_valid((ssize_t) data.length);
                var renderer = new NoteRenderer(work);
                string name = clean_name(Path.get_basename(doc_path));
                int dot = name.last_index_of(".");
                string stem = dot > 0 ? name.substring(0, dot) : name;
                renderer.pages.add(new ExportPage("doc", stem, 0, md));
                string dir = dir_for(notes_dir, note_id);
                DirUtils.create_with_parents(dir, 0700);
                var pages = new Gee.ArrayList<string>();
                var files = renderer.write_png(Path.build_filename(work, "page.png"), 1.6);
                int n = 1;
                foreach (string f in files) {
                    string target = unique_path(dir, "printout-%s-%d.png".printf(stem, n++));
                    File.new_for_path(f).copy(File.new_for_path(target), FileCopyFlags.OVERWRITE);
                    pages.add(relative(note_id, target));
                }
                return pages;
            } finally {
                Trash.remove_tree(work);
            }
        }

        public static string pdf_text(string pdf_path) {
            var sb = new StringBuilder();
            try {
                var doc = new Poppler.Document.from_gfile(File.new_for_path(pdf_path), null, null);
                for (int i = 0; i < int.min(doc.get_n_pages(), 200); i++) {
                    string? t = doc.get_page(i).get_text();
                    if (t != null) sb.append(t + "\n");
                }
            } catch (Error e) {
            }
            return sb.str;
        }
    }
}
