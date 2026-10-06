namespace Singularity.Apps.Notes {

    public class RecordingMark {
        public double time;
        public string text;

        public RecordingMark(double time, string text) {
            this.time = time;
            this.text = text;
        }
    }

    public class RecordingInfo : Object {
        public string path = "";
        public string? transcript = null;
        public double duration = 0;
        public Gee.ArrayList<RecordingMark> marks = new Gee.ArrayList<RecordingMark>();

        public static string sidecar(string media_path) {
            return media_path + ".json";
        }

        public static RecordingInfo load(string media_path) {
            var info = new RecordingInfo();
            info.path = media_path;
            if (!FileUtils.test(sidecar(media_path), FileTest.EXISTS)) return info;
            try {
                var parser = new Json.Parser();
                parser.load_from_file(sidecar(media_path));
                var o = parser.get_root().get_object();
                if (o.has_member("transcript")) info.transcript = o.get_string_member("transcript");
                if (o.has_member("duration")) info.duration = o.get_double_member("duration");
                if (o.has_member("marks")) {
                    o.get_array_member("marks").foreach_element((a, i, node) => {
                        var mo = node.get_object();
                        info.marks.add(new RecordingMark(mo.get_double_member("t"), mo.get_string_member("text")));
                    });
                }
            } catch (Error e) {
            }
            return info;
        }

        public void save() {
            var o = new Json.Object();
            if (transcript != null) o.set_string_member("transcript", transcript);
            o.set_double_member("duration", duration);
            var arr = new Json.Array();
            foreach (var m in marks) {
                var mo = new Json.Object();
                mo.set_double_member("t", m.time);
                mo.set_string_member("text", m.text);
                arr.add_object_element(mo);
            }
            o.set_array_member("marks", arr);
            var node = new Json.Node(Json.NodeType.OBJECT);
            node.set_object(o);
            try {
                FileUtils.set_contents(sidecar(path), Json.to_string(node, true));
            } catch (FileError e) {
            }
        }

        public void mark(double t, string text) {
            string s = text.strip();
            if (s == "") return;
            foreach (var m in marks) if (m.text == s) return;
            marks.add(new RecordingMark(t, s));
        }

        public double? time_of(string text) {
            string s = text.strip();
            foreach (var m in marks) if (m.text == s) return m.time;
            foreach (var m in marks) if (s.length > 3 && (m.text.has_prefix(s) || s.has_prefix(m.text))) return m.time;
            return null;
        }

        public Gee.List<string> texts_until(double t, double window) {
            var list = new Gee.ArrayList<string>();
            foreach (var m in marks) if (m.time <= t && m.time >= t - window) list.add(m.text);
            return list;
        }
    }

    public class Recorder : Object {
        public signal void stopped(string path, bool ok);
        public bool video { get; construct; }
        public string path { get; construct; }
        public bool running { get; private set; default = false; }
        public int64 started_at = 0;

        private Gst.Element? pipeline = null;

        public Recorder(string path, bool video) {
            Object(path: path, video: video);
        }

        public static bool test_mode {
            get { return Environment.get_variable("NOTES_TEST_MEDIA") == "1"; }
        }

        public static bool can_encode(string element) {
            return Gst.ElementFactory.find(element) != null;
        }

        public static string audio_extension() {
            return can_encode("opusenc") && can_encode("oggmux") ? "ogg" : "wav";
        }

        private string description() {
            string loc = path.replace("\\", "\\\\").replace("\"", "\\\"");
            string asrc = test_mode ? "audiotestsrc is-live=true wave=sine freq=440 volume=0.2" : "autoaudiosrc";
            if (!video) {
                if (path.has_suffix(".ogg")) return "%s ! audioconvert ! audioresample ! audio/x-raw,channels=1 ! opusenc ! oggmux ! filesink location=\"%s\"".printf(asrc, loc);
                return "%s ! audioconvert ! audioresample ! audio/x-raw,format=S16LE,channels=1,rate=22050 ! wavenc ! filesink location=\"%s\"".printf(asrc, loc);
            }
            string vsrc = test_mode ? "videotestsrc is-live=true pattern=ball" : "autovideosrc";
            return ("%s ! videoconvert ! videoscale ! videorate ! video/x-raw,width=640,height=360,framerate=24/1 ! vp8enc deadline=1 cpu-used=8 ! queue ! mux. "
                + "%s ! audioconvert ! audioresample ! audio/x-raw,channels=1 ! vorbisenc ! queue ! mux. webmmux name=mux ! filesink location=\"%s\"").printf(vsrc, asrc, loc);
        }

        public void start() throws Error {
            if (video && !(can_encode("vp8enc") && can_encode("webmmux") && can_encode("vorbisenc"))) {
                throw new IOError.NOT_SUPPORTED(_("Video recording needs the VP8 and WebM GStreamer plugins"));
            }
            pipeline = Gst.parse_launch(description());
            var bus = pipeline.get_bus();
            bus.add_watch(Priority.DEFAULT, (b, msg) => {
                switch (msg.type) {
                    case Gst.MessageType.EOS:
                        finish(true);
                        return false;
                    case Gst.MessageType.ERROR:
                        Error err;
                        string dbg;
                        msg.parse_error(out err, out dbg);
                        warning("notes recorder: %s", err.message);
                        finish(false);
                        return false;
                    default:
                        return true;
                }
            });
            if (pipeline.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE) {
                pipeline.set_state(Gst.State.NULL);
                pipeline = null;
                throw new IOError.FAILED(_("The recording could not start"));
            }
            running = true;
            started_at = get_monotonic_time();
        }

        public double elapsed {
            get { return running ? (get_monotonic_time() - started_at) / 1000000.0 : 0; }
        }

        public void stop() {
            if (pipeline == null) return;
            pipeline.send_event(new Gst.Event.eos());
            Timeout.add(4000, () => {
                if (pipeline != null) finish(true);
                return Source.REMOVE;
            });
        }

        private void finish(bool ok) {
            if (pipeline == null) return;
            pipeline.set_state(Gst.State.NULL);
            pipeline = null;
            running = false;
            stopped(path, ok && FileUtils.test(path, FileTest.EXISTS));
        }
    }

    public class Transcription : Object {
        public const string BUS_NAME = "dev.sinty.Dictation";

        public static async string to_wav(string media, Cancellable? cancellable) throws Error {
            string wav;
            int fd = FileUtils.open_tmp("notes-rec-XXXXXX.wav", out wav);
            FileUtils.close(fd);
            string desc = "filesrc location=\"%s\" ! decodebin ! audioconvert ! audioresample ! audio/x-raw,format=S16LE,channels=1,rate=16000 ! wavenc ! filesink location=\"%s\"".printf(
                media.replace("\"", "\\\""), wav.replace("\"", "\\\""));
            var p = Gst.parse_launch(desc);
            bool done = false;
            string? failure = null;
            var bus = p.get_bus();
            bus.add_watch(Priority.DEFAULT, (b, msg) => {
                if (msg.type == Gst.MessageType.EOS) {
                    done = true;
                    to_wav.callback();
                    return false;
                }
                if (msg.type == Gst.MessageType.ERROR) {
                    Error err;
                    string dbg;
                    msg.parse_error(out err, out dbg);
                    failure = err.message;
                    done = true;
                    to_wav.callback();
                    return false;
                }
                return true;
            });
            p.set_state(Gst.State.PLAYING);
            if (!done) yield;
            p.set_state(Gst.State.NULL);
            if (failure != null) {
                FileUtils.unlink(wav);
                throw new IOError.FAILED(failure);
            }
            return wav;
        }

        public static bool service_present(DBusConnection connection) {
            try {
                var reply = connection.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner",
                    new Variant("(s)", BUS_NAME), new VariantType("(b)"), DBusCallFlags.NONE, 2000, null);
                bool owned;
                reply.get("(b)", out owned);
                if (owned) return true;
                var names = connection.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ListActivatableNames",
                    null, new VariantType("(as)"), DBusCallFlags.NONE, 2000, null).get_child_value(0);
                for (size_t i = 0; i < names.n_children(); i++) if (names.get_child_value(i).get_string() == BUS_NAME) return true;
            } catch (Error e) {
            }
            return false;
        }

        public static string[]? command_from_config() {
            string[] dirs = { Environment.get_user_config_dir() };
            foreach (string dir in Environment.get_system_config_dirs()) dirs += dir;
            foreach (string dir in dirs) {
                string path = Path.build_filename(dir, "singularity", "recorder.conf");
                if (!FileUtils.test(path, FileTest.IS_REGULAR)) continue;
                try {
                    var file = new KeyFile();
                    file.load_from_file(path, KeyFileFlags.NONE);
                    if (!file.has_key("Transcription", "Command")) continue;
                    string[] argv;
                    GLib.Shell.parse_argv(file.get_string("Transcription", "Command"), out argv);
                    if (argv.length > 0) return argv;
                } catch (Error e) {
                }
            }
            return null;
        }

        public static async string transcribe(string media, string language, Cancellable? cancellable) throws Error {
            var connection = yield Bus.get(BusType.SESSION, cancellable);
            string wav = yield to_wav(media, cancellable);
            try {
                if (!service_present(connection)) {
                    string[]? argv = command_from_config();
                    if (argv == null) throw new IOError.NOT_FOUND(_("No speech recognition service is available. Turn on dictation in Settings or install a transcription engine."));
                    string[] command = {};
                    foreach (string arg in argv) command += arg.replace("%f", wav).replace("%l", language == "" ? "auto" : language);
                    var process = new Subprocess.newv(command, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
                    string? output = null;
                    yield process.communicate_utf8_async(null, cancellable, out output, null);
                    if (!process.get_successful()) throw new IOError.FAILED(_("The speech engine stopped unexpectedly"));
                    return (output ?? "").strip();
                }
                var reply = yield connection.call(BUS_NAME, "/dev/sinty/Dictation", "dev.sinty.Dictation", "TranscribeFile",
                    new Variant("(ss)", wav, language), new VariantType("(s)"), DBusCallFlags.NONE, 30 * 60 * 1000, cancellable);
                string text;
                reply.get("(s)", out text);
                return text.strip();
            } catch (Error e) {
                DBusError.strip_remote_error(e);
                throw e;
            } finally {
                FileUtils.unlink(wav);
            }
        }
    }
}
