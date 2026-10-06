namespace Singularity.Apps.Notes {

    public class OcrIndex : Object {
        private static OcrIndex? instance = null;
        public string last_error { get; private set; default = ""; }
        public signal void indexed(string path);

        private Gee.ArrayList<string> queue = new Gee.ArrayList<string>();
        private bool running = false;
        private Singularity.TextRecognition.Recognizer? recognizer = null;

        public static OcrIndex get_default() {
            if (instance == null) instance = new OcrIndex();
            return instance;
        }

        private Singularity.TextRecognition.Recognizer engine() {
            if (recognizer == null) recognizer = Singularity.TextRecognition.Recognizer.get_default();
            return recognizer;
        }

        public bool available {
            get { return engine().available; }
        }

        public static string cache_path(string file) {
            return Path.build_filename(Path.get_dirname(file), ".%s.ocr.txt".printf(Path.get_basename(file)));
        }

        public static string? cached_text(string file) {
            string text;
            try {
                if (FileUtils.get_contents(cache_path(file), out text)) return text;
            } catch (FileError e) {
            }
            return null;
        }

        public static void store(string file, string text) {
            try {
                FileUtils.set_contents(cache_path(file), text);
            } catch (FileError e) {
            }
        }

        public async string? recognize(string file) {
            var r = engine();
            if (!r.available) {
                last_error = r.install_hint;
                return null;
            }
            try {
                var result = yield r.recognize_file(File.new_for_path(file));
                string text = result.text;
                store(file, text);
                indexed(file);
                return text;
            } catch (Error e) {
                last_error = e.message;
                return null;
            }
        }

        public async string? recognize_surface(Cairo.ImageSurface surface) {
            var r = engine();
            if (!r.available) {
                last_error = r.install_hint;
                return null;
            }
            string path;
            try {
                int fd = FileUtils.open_tmp("notes-ink-XXXXXX.png", out path);
                FileUtils.close(fd);
            } catch (FileError e) {
                last_error = e.message;
                return null;
            }
            surface.write_to_png(path);
            try {
                var result = yield r.recognize_file(File.new_for_path(path));
                return result.text;
            } catch (Error e) {
                last_error = e.message;
                return null;
            } finally {
                FileUtils.unlink(path);
            }
        }

        public void enqueue(string file) {
            if (queue.contains(file) || cached_text(file) != null) return;
            queue.add(file);
            if (!running) run.begin();
        }

        private async void run() {
            if (!engine().available) {
                queue.clear();
                return;
            }
            running = true;
            while (queue.size > 0) {
                string f = queue.remove_at(0);
                if (cached_text(f) != null || !FileUtils.test(f, FileTest.EXISTS)) continue;
                yield recognize(f);
            }
            running = false;
        }

        public void index_note(string notes_dir, string note_id, string body) {
            foreach (string target in NoteAttachments.links(body)) {
                if (!target.has_prefix("attachments/")) continue;
                string path = Path.build_filename(notes_dir, Uri.unescape_string(target) ?? target);
                string name = Path.get_basename(path);
                if (!Attachments.is_image(path) || name.has_prefix("ink-") || name.has_prefix("equation-")) continue;
                enqueue(path);
            }
        }

        public static string media_text(string notes_dir, string body) {
            var sb = new StringBuilder();
            foreach (string target in NoteAttachments.links(body)) {
                if (!target.has_prefix("attachments/")) continue;
                string path = Path.build_filename(notes_dir, Uri.unescape_string(target) ?? target);
                string? t = cached_text(path);
                if (t != null) sb.append(t + "\n");
                string? transcript = RecordingInfo.load(path).transcript;
                if (transcript != null && transcript != "") sb.append(transcript + "\n");
                if (t == null && Attachments.is_pdf(path)) {
                    string pt = Attachments.pdf_text(path);
                    store(path, pt);
                    sb.append(pt + "\n");
                }
            }
            return sb.str;
        }
    }
}
