namespace Singularity.Apps.Notes {

    public class EquationFiles {
        public static string last_error = "";

        public static string stem(string png) {
            int dot = png.last_index_of(".");
            return dot > 0 ? png.substring(0, dot) : png;
        }

        public static Singularity.Equations.Equation load(string png, string alt) {
            string text;
            try {
                if (FileUtils.get_contents(stem(png) + ".mml", out text) && text.strip() != "") return new Singularity.Equations.Equation.from_mathml(text);
            } catch (FileError e) {
            }
            try {
                if (FileUtils.get_contents(stem(png) + ".tex", out text) && text.strip() != "") return new Singularity.Equations.Equation.from_latex(text.strip());
            } catch (FileError e) {
            }
            return new Singularity.Equations.Equation.from_latex(alt);
        }

        public static async string? save(Singularity.Equations.Equation eq, string notes_dir, string note_id) {
            string target = Attachments.new_path(notes_dir, note_id, "equation-", "png");
            if (!(yield eq.render(16, 2.0)) || eq.texture == null) {
                last_error = _("The equation could not be drawn. Install the Formula app.");
                return null;
            }
            if (!eq.texture.save_to_png(target)) return null;
            try {
                FileUtils.set_contents(stem(target) + ".mml", eq.mathml);
                if (eq.latex != "") FileUtils.set_contents(stem(target) + ".tex", eq.latex);
            } catch (FileError e) {
            }
            return Attachments.relative(note_id, target);
        }

        public static async string? edit_and_save(Singularity.Equations.Equation eq, string notes_dir, string note_id, Gtk.Window? parent) {
            last_error = "";
            if (!Singularity.Equations.Equation.editor_available()) {
                last_error = _("Install the Formula app to write equations");
                return null;
            }
            bool changed = yield eq.edit(parent);
            if (!changed) return null;
            return yield save(eq, notes_dir, note_id);
        }
    }
}
