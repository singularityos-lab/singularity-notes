using Gtk;

namespace Singularity.Apps.Notes {

    public class RecordingObject : NoteObject {
        public Block block;
        private Gtk.MediaFile? media = null;
        private Label time_label;
        private Button play_button;
        private Scale seek;
        private Label transcript_label;
        private uint tick = 0;
        private RecordingInfo info;

        public RecordingObject(Block block) {
            base();
            this.block = block;
            add_css_class("notes-recording");
            string path = resolve(block.image);
            info = RecordingInfo.load(path);
            bool is_video = path.has_suffix(".webm") || path.has_suffix(".mp4") || path.has_suffix(".mkv");
            var row = new Box(Orientation.HORIZONTAL, 8);
            var icon = new Image.from_icon_name(is_video ? "camera-web-symbolic" : "audio-x-generic-symbolic");
            icon.pixel_size = 20;
            row.append(icon);
            play_button = new Button.from_icon_name("media-playback-start-symbolic");
            play_button.add_css_class("flat");
            play_button.add_css_class("circular");
            play_button.tooltip_text = _("Play");
            play_button.clicked.connect(() => toggle_play());
            row.append(play_button);
            var name = new Label(block.alt != "" ? block.alt : Path.get_basename(path));
            name.ellipsize = Pango.EllipsizeMode.END;
            name.xalign = 0;
            name.add_css_class("notes-file-name");
            name.width_chars = 16;
            name.max_width_chars = 40;
            row.append(name);
            seek = new Scale.with_range(Orientation.HORIZONTAL, 0, 1, 0.01);
            seek.draw_value = false;
            seek.hexpand = true;
            seek.set_size_request(160, -1);
            seek.change_value.connect((scroll, value) => {
                if (media != null && media.duration > 0) media.seek((int64) (value * media.duration));
                return false;
            });
            row.append(seek);
            time_label = new Label("0:00");
            time_label.add_css_class("numeric");
            time_label.add_css_class("dim-label");
            row.append(time_label);
            append(row);
            if (is_video) {
                var video = new Video();
                video.set_size_request(320, 180);
                video.autoplay = false;
                ensure_media();
                video.media_stream = media;
                video.halign = Align.START;
                append(video);
            }
            transcript_label = new Label("");
            transcript_label.wrap = true;
            transcript_label.xalign = 0;
            transcript_label.selectable = true;
            transcript_label.add_css_class("notes-transcript");
            transcript_label.visible = false;
            append(transcript_label);
            update_transcript();
            Menus.on_secondary(row, (m) => {
                m.add_item(_("Transcribe"), "audio-input-microphone-symbolic", () => transcribe());
                if (info.transcript != null && info.transcript != "" && editor != null) {
                    m.add_item(_("Insert Transcript in Page"), "insert-text-symbolic", () => editor.insert_text_after_object(this, info.transcript));
                }
                m.add_item(_("Open"), "document-open-symbolic", () => ImageObject.open_external(path, window()));
                m.add_separator();
                m.add_item(_("Remove Recording"), "edit-delete-symbolic", () => remove_requested());
            });
            destroy.connect(() => {
                if (tick != 0) Source.remove(tick);
                tick = 0;
                if (media != null) media.pause();
            });
        }

        private void update_transcript() {
            bool has = info.transcript != null && info.transcript != "";
            transcript_label.visible = has;
            if (has) transcript_label.label = info.transcript;
        }

        private void ensure_media() {
            if (media != null) return;
            media = Gtk.MediaFile.for_filename(resolve(block.image));
            media.notify["playing"].connect(() => {
                play_button.icon_name = media.playing ? "media-playback-pause-symbolic" : "media-playback-start-symbolic";
                play_button.tooltip_text = media.playing ? _("Pause") : _("Play");
                if (media.playing && tick == 0) tick = Timeout.add(250, on_tick);
                if (!media.playing && editor != null) editor.highlight_lines(new Gee.ArrayList<int>());
            });
        }

        public void toggle_play() {
            ensure_media();
            if (media.playing) media.pause();
            else media.play();
        }

        public void play_from(double seconds) {
            ensure_media();
            media.play();
            Timeout.add(150, () => {
                media.seek((int64) (seconds * 1000000));
                return Source.REMOVE;
            });
        }

        public double? time_for_text(string text) {
            return info.time_of(text);
        }

        private bool on_tick() {
            if (media == null || !media.playing) {
                tick = 0;
                return Source.REMOVE;
            }
            double t = media.timestamp / 1000000.0;
            time_label.label = format_time(t);
            if (media.duration > 0) seek.set_value((double) media.timestamp / media.duration);
            if (editor != null && info.marks.size > 0) {
                var texts = info.texts_until(t, 6);
                var lines = new Gee.ArrayList<int>();
                for (int l = 0; l < editor.line_count(); l++) {
                    string lt = editor.line_text(l);
                    if (lt != "" && texts.contains(lt)) lines.add(l);
                }
                editor.highlight_lines(lines);
            }
            return Source.CONTINUE;
        }

        public static string format_time(double s) {
            int total = (int) s;
            if (total >= 3600) return "%d:%02d:%02d".printf(total / 3600, (total / 60) % 60, total % 60);
            return "%d:%02d".printf(total / 60, total % 60);
        }

        public void transcribe() {
            status(_("Transcribing the recording…"));
            string path = resolve(block.image);
            string lang = Intl.get_language_names()[0].split("_")[0];
            if (lang == "C") lang = "";
            Transcription.transcribe.begin(path, lang, null, (o, r) => {
                try {
                    string text = Transcription.transcribe.end(r);
                    info.transcript = text;
                    info.save();
                    update_transcript();
                    status(text != "" ? _("Transcript ready") : _("No speech was recognized"));
                    changed();
                } catch (Error e) {
                    status(_("Transcription is not available: %s").printf(e.message));
                }
            });
        }

        public override Block to_block() {
            var b = new Block(BlockKind.RECORDING);
            b.alt = block.alt;
            b.image = block.image;
            b.anchor = block.anchor;
            return b;
        }

        public override string search_text() {
            return (block.alt + " " + (info.transcript ?? "")).strip();
        }
    }
}
