namespace Singularity.Apps.Notes {

    public class PageTemplate : Object {
        public string id { get; construct; }
        public string name { get; construct; }
        public string description { get; construct; }
        public string icon { get; construct; }
        public string body { get; construct; }
        public bool custom { get; construct; }

        public PageTemplate(string id, string name, string description, string icon, string body, bool custom = false) {
            Object(id: id, name: name, description: description, icon: icon, body: body, custom: custom);
        }

        public string instantiate() {
            var now = new DateTime.now_local();
            return body.replace("{date}", now.format("%x")).replace("{time}", now.format("%H:%M")).replace("{weekday}", now.format("%A"));
        }
    }

    public class Templates : Object {
        public string dir { get; construct; }

        public Templates(string notes_dir) {
            Object(dir: Path.build_filename(notes_dir, ".templates"));
        }

        public Gee.List<PageTemplate> builtin() {
            var l = new Gee.ArrayList<PageTemplate>();
            l.add(new PageTemplate("meeting", _("Meeting Notes"), _("Attendees, agenda, decisions and action items"), "x-office-calendar-symbolic",
                "# %s {date}\n## %s\n- \n## %s\n1. \n## %s\n\n## %s\n- [ ] \n".printf(_("Meeting"), _("Attendees"), _("Agenda"), _("Notes"), _("Action Items"))));
            l.add(new PageTemplate("todo", _("To-Do List"), _("Tasks sorted by priority"), "checkbox-checked-symbolic",
                "# %s\n## %s\n- [ ] [!priority-1] \n## %s\n- [ ] \n## %s\n- [ ] \n".printf(_("To Do"), _("Today"), _("This Week"), _("Later"))));
            l.add(new PageTemplate("project", _("Project Overview"), _("Goals, milestones, risks and contacts"), "notes-flag-symbolic",
                "# %s\n## %s\n\n## %s\n| %s | %s | %s |\n| --- | --- | --- |\n|  |  |  |\n|  |  |  |\n## %s\n- [!critical] \n## %s\n- [!contact] \n".printf(
                    _("Project"), _("Goals"), _("Milestones"), _("Milestone"), _("Owner"), _("Due"), _("Risks"), _("Contacts"))));
            l.add(new PageTemplate("lecture", _("Lecture Notes"), _("Cornell layout with cues and a summary"), "accessories-dictionary-symbolic",
                "# %s {date}\n| %s | %s |\n| --- | --- |\n|  |  |\n|  |  |\n|  |  |\n## %s\n\n".printf(_("Lecture"), _("Cues and Questions"), _("Notes"), _("Summary"))));
            l.add(new PageTemplate("journal", _("Journal"), _("A page for today"), "document-edit-symbolic",
                "# {weekday} {date}\n## %s\n- \n## %s\n\n## %s\n- [!idea] \n".printf(_("Grateful For"), _("What Happened"), _("Ideas"))));
            l.add(new PageTemplate("week", _("Weekly Planner"), _("Seven days at a glance"), "x-office-calendar-symbolic",
                "# %s {date}\n| %s | %s |\n| --- | --- |\n| %s |  |\n| %s |  |\n| %s |  |\n| %s |  |\n| %s |  |\n| %s |  |\n| %s |  |\n".printf(
                    _("Week of"), _("Day"), _("Plans"), _("Monday"), _("Tuesday"), _("Wednesday"), _("Thursday"), _("Friday"), _("Saturday"), _("Sunday"))));
            l.add(new PageTemplate("decision", _("Decision"), _("Options, pros and cons, outcome"), "dialog-question-symbolic",
                "# %s\n## %s\n\n## %s\n| %s | %s | %s |\n| --- | --- | --- |\n|  |  |  |\n## %s\n[!important] \n".printf(
                    _("Decision"), _("Question"), _("Options"), _("Option"), _("Pros"), _("Cons"), _("Outcome"))));
            l.add(new PageTemplate("brainstorm", _("Brainstorm"), _("A free-form page to place ideas anywhere"), "notes-canvas-symbolic",
                "# %s\n<!-- block x=\"40\" y=\"24\" w=\"320\" -->\n## %s\n- [!idea] \n<!-- /block -->\n<!-- block x=\"420\" y=\"24\" w=\"320\" -->\n## %s\n- [!question] \n<!-- /block -->\n<!-- page layout=canvas -->".printf(
                    _("Brainstorm"), _("Ideas"), _("Questions"))));
            return l;
        }

        public Gee.List<PageTemplate> custom() {
            var l = new Gee.ArrayList<PageTemplate>();
            try {
                var d = Dir.open(dir);
                string? name;
                while ((name = d.read_name()) != null) {
                    if (!name.has_suffix(".md")) continue;
                    string text;
                    FileUtils.get_contents(Path.build_filename(dir, name), out text);
                    string id = name.substring(0, name.length - 3);
                    string title = PageDoc.title_of(text);
                    l.add(new PageTemplate("custom:" + id, title != "" ? title : id, _("Your template"), "document-new-symbolic", text, true));
                }
            } catch (Error e) {
            }
            l.sort((a, b) => a.name.collate(b.name));
            return l;
        }

        public Gee.List<PageTemplate> all() {
            var l = new Gee.ArrayList<PageTemplate>();
            l.add_all(builtin());
            l.add_all(custom());
            return l;
        }

        public void save(string name, string body) throws Error {
            DirUtils.create_with_parents(dir, 0700);
            FileUtils.set_contents(Path.build_filename(dir, TagCatalog.slug(name) + ".md"), body);
        }

        public void remove(PageTemplate t) {
            if (!t.custom) return;
            FileUtils.unlink(Path.build_filename(dir, t.id.substring(7) + ".md"));
        }
    }
}
