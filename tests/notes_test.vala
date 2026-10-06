using Singularity.Apps.Notes;
using Singularity.Notes;

private string scratch() {
    try {
        return DirUtils.make_tmp("notes-test-XXXXXX");
    } catch (FileError e) {
        error("%s", e.message);
    }
}

private void test_serialize_round_trip() {
    var n = new Note("abc");
    n.folder = "Work/Ideas";
    n.pinned = true;
    n.created = 1790000000;
    n.modified = 1790000100;
    n.body = "# Plan\n\n- [ ] buy milk\n---\nnot a header";
    string text = n.serialize();
    assert(text.has_prefix("---\nfolder: Work/Ideas\npinned: true\ncreated: "));
    var back = Note.parse("abc", text);
    assert(back.folder == "Work/Ideas");
    assert(back.pinned);
    assert(back.created == 1790000000);
    assert(back.modified == 1790000100);
    assert(back.body == n.body);
    assert(back.title == "Plan");
    assert(back.snippet == "buy milk --- not a header");
}

private void test_parse_without_header() {
    var n = Note.parse("x", "Just text\nsecond");
    assert(n.body == "Just text\nsecond");
    assert(n.folder == "");
    assert(!n.pinned);
    var empty = Note.parse("y", "---\n---\nbody");
    assert(empty.body == "body");
}

private void test_title_strips_markup() {
    assert(Note.title_of("\n\n## **Big** *idea*\nrest") == "Big idea");
    assert(Note.title_of("- [x] [Link](https://a.b) done") == "Link done");
    assert(Note.title_of("   ") == "");
}

private void test_store_save_load_search() {
    string dir = scratch();
    var store = new NoteStore(dir);
    store.legacy_data_dir = dir + "/none";
    store.legacy_documents_dir = dir + "/none";
    try {
        var a = store.create("Groceries\n- eggs", "Home");
        var b = store.create("Meeting notes\nquarterly budget", "Work");
        b.pinned = true;
        store.save(b);
        store.add_folder("Empty");
        var again = new NoteStore(dir);
        again.load();
        assert(again.all().size == 2);
        assert(again.all()[0].id == b.id);
        assert(again.lookup(a.id).folder == "Home");
        assert(again.search("budget").size == 1);
        assert(again.search("EGGS").size == 1);
        assert(again.search("", "Work").size == 1);
        var folders = again.folders();
        assert(folders.size == 3);
        assert(folders[0] == "Empty" && folders[1] == "Home" && folders[2] == "Work");
        again.remove(a.id);
        assert(!FileUtils.test(store.path_for(a.id), FileTest.EXISTS));
        again.remove_folder("Work");
        var third = new NoteStore(dir);
        third.load();
        assert(third.lookup(b.id).folder == "");
    } catch (Error e) {
        error("%s", e.message);
    }
}

private void test_invalid_ids_rejected() {
    assert(!NoteStore.valid_id("../evil"));
    assert(!NoteStore.valid_id(".hidden"));
    assert(!NoteStore.valid_id("a/b"));
    assert(NoteStore.valid_id("widget-12ab_3"));
}

private void test_legacy_import() {
    string dir = scratch();
    string data = dir + "/data/singularity";
    string docs = dir + "/Documents";
    DirUtils.create_with_parents(data, 0700);
    DirUtils.create_with_parents(docs, 0700);
    try {
        FileUtils.set_contents(data + "/quick-notes.txt", "Call the plumber\nTuesday");
        FileUtils.set_contents(docs + "/singularity-note-w42.txt", "Sticky from the desktop");
        FileUtils.set_contents(docs + "/singularity-note-empty.txt", "   \n");
        FileUtils.set_contents(docs + "/unrelated.txt", "keep me out");
    } catch (FileError e) {
        error("%s", e.message);
    }
    var store = new NoteStore(dir + "/notes");
    store.legacy_data_dir = data;
    store.legacy_documents_dir = docs;
    assert(store.import_legacy() == 2);
    store.load();
    var quick = store.lookup(NoteStore.QUICK_NOTE_ID);
    assert(quick != null);
    assert(quick.body == "Call the plumber\nTuesday");
    assert(quick.pinned);
    var sticky = store.lookup("widget-w42");
    assert(sticky != null && sticky.body == "Sticky from the desktop");
    assert(store.all().size == 2);
    assert(FileUtils.test(data + "/quick-notes.txt", FileTest.EXISTS));
    assert(store.import_legacy() == 0);
    try {
        store.remove("widget-w42");
    } catch (Error e) {
        error("%s", e.message);
    }
    assert(store.import_legacy() == 0);
    store.load();
    assert(store.lookup("widget-w42") == null);
}

private void check_round_trip(string md) {
    var blocks = RichText.parse(md);
    string back = RichText.render(blocks);
    if (back != md) error("round trip failed:\n[%s]\n[%s]", md, back);
}

private void test_rich_text_round_trip() {
    check_round_trip("# Title\n## Sub\n### Small\nplain **bold** and *italic* and ***both***");
    check_round_trip("- [ ] open\n- [x] done\n- bullet with [a link](https://example.com/x?y=1)");
    check_round_trip("![Photo](attachments/n1/photo.png)\nafter image");
    check_round_trip("price 2 \\* 3 and \\[not a link\\]");
    check_round_trip("\\# not a heading\n\\- not a bullet");
    check_round_trip("");
}

private void test_rich_text_blocks() {
    var blocks = RichText.parse("# Head\n- [x] **Done** thing\n![Cat](a.png)\nsee [site](https://s.t)");
    assert(blocks.size == 4);
    assert(blocks[0].kind == BlockKind.HEADING1 && blocks[0].plain_text() == "Head");
    assert(blocks[1].kind == BlockKind.CHECK && blocks[1].checked);
    assert(blocks[1].spans[0].bold && blocks[1].spans[0].text == "Done");
    assert(!blocks[1].spans[1].bold && blocks[1].spans[1].text == " thing");
    assert(blocks[2].kind == BlockKind.IMAGE && blocks[2].image == "a.png" && blocks[2].alt == "Cat");
    assert(blocks[3].spans[1].href == "https://s.t" && blocks[3].spans[1].text == "site");
    var lone = RichText.parse("a * b");
    assert(lone[0].spans.size == 1 && lone[0].spans[0].text == "a * b");
}

private NoteStore open_store(string dir) {
    var store = new NoteStore(dir);
    store.legacy_data_dir = dir + "/none";
    store.legacy_documents_dir = dir + "/none";
    store.load();
    return store;
}

private void test_concurrent_saves_merge() {
    string dir = scratch();
    var one = open_store(dir);
    var two = open_store(dir);
    try {
        var created = one.create("Plan\nfirst\nsecond\nthird");
        two.load();
        var mine = one.lookup(created.id).copy();
        var theirs = two.lookup(created.id).copy();
        mine.body = "Plan\nFIRST\nsecond\nthird";
        one.save(mine);
        theirs.body = "Plan\nfirst\nsecond\nTHIRD";
        theirs.pinned = true;
        two.save(theirs);
        assert(theirs.body == "Plan\nFIRST\nsecond\nTHIRD");
        mine.folder = "Work";
        one.save(mine);
        assert(mine.body == "Plan\nFIRST\nsecond\nTHIRD");
        assert(mine.pinned);
        assert(mine.folder == "Work");
        var fresh = open_store(dir);
        var back = fresh.lookup(created.id);
        assert(back.body == "Plan\nFIRST\nsecond\nTHIRD" && back.pinned && back.folder == "Work");
        assert(fresh.all().size == 1);
    } catch (Error e) {
        error("%s", e.message);
    }
}

private void test_concurrent_conflict_keeps_both() {
    string dir = scratch();
    var one = open_store(dir);
    var two = open_store(dir);
    try {
        var created = one.create("Plan\nsame line");
        two.load();
        var mine = one.lookup(created.id).copy();
        var theirs = two.lookup(created.id).copy();
        mine.body = "Plan\nmine";
        one.save(mine);
        theirs.body = "Plan\ntheirs";
        two.save(theirs);
        assert(theirs.body == "Plan\ntheirs");
        var fresh = open_store(dir);
        assert(fresh.all().size == 2);
        bool copy_found = false;
        foreach (var n in fresh.all()) {
            if (n.id == created.id) assert(n.body == "Plan\ntheirs");
            else copy_found = n.body == Note.conflicted_copy_body("Plan\nmine") && n.title.has_suffix("(Conflicted Copy)");
        }
        assert(copy_found);
    } catch (Error e) {
        error("%s", e.message);
    }
}

private void test_remove_unchanged_keeps_edited() {
    string dir = scratch();
    var one = open_store(dir);
    var two = open_store(dir);
    try {
        var created = one.create("Quick\ntext");
        two.load();
        var stale = two.lookup(created.id).copy();
        var edit = one.lookup(created.id).copy();
        edit.body = "Quick\ntext\nmore";
        one.save(edit);
        assert(!two.remove_unchanged(stale));
        assert(FileUtils.test(one.path_for(created.id), FileTest.EXISTS));
        assert(two.lookup(created.id).body == "Quick\ntext\nmore");
        assert(one.remove_unchanged(edit));
        assert(!FileUtils.test(one.path_for(created.id), FileTest.EXISTS));
    } catch (Error e) {
        error("%s", e.message);
    }
}

private int run_writer(string dir, string id, string from, string to) {
    var store = open_store(dir);
    var n = store.lookup(id).copy();
    for (int i = 0; i < 40; i++) {
        string[] lines = n.body.split("\n");
        for (int l = 0; l < lines.length; l++) if (lines[l] == "%s%d".printf(from, i)) lines[l] = "%s%d".printf(to, i);
        n.body = string.joinv("\n", lines);
        try {
            store.save(n);
        } catch (Error e) {
            printerr("%s\n", e.message);
            return 1;
        }
        Thread.usleep(Random.int_range(200, 3000));
    }
    return 0;
}

private void test_two_processes_keep_every_edit() {
    string dir = scratch();
    var store = open_store(dir);
    var body = new StringBuilder("Shared");
    for (int i = 0; i < 40; i++) body.append("\na%d".printf(i));
    body.append("\n--");
    for (int i = 0; i < 40; i++) body.append("\nb%d".printf(i));
    Note created;
    try {
        created = store.create(body.str);
        string self = FileUtils.read_link("/proc/self/exe");
        var first = new Subprocess.newv({ self, "--writer", dir, created.id, "a", "A" }, SubprocessFlags.NONE);
        var second = new Subprocess.newv({ self, "--writer", dir, created.id, "b", "B" }, SubprocessFlags.NONE);
        first.wait_check();
        second.wait_check();
    } catch (Error e) {
        error("%s", e.message);
    }
    var fresh = open_store(dir);
    string result = fresh.lookup(created.id).body;
    for (int i = 0; i < 40; i++) {
        if (!("\nA%d\n".printf(i) in result + "\n")) error("lost A%d:\n%s", i, result);
        if (!("\nB%d\n".printf(i) in result + "\n")) error("lost B%d:\n%s", i, result);
    }
    assert(fresh.all().size == 1);
}

public int main(string[] args) {
    if (args.length == 6 && args[1] == "--writer") return run_writer(args[2], args[3], args[4], args[5]);
    Test.init(ref args);
    Test.add_func("/notes/concurrent-saves-merge", test_concurrent_saves_merge);
    Test.add_func("/notes/concurrent-conflict-keeps-both", test_concurrent_conflict_keeps_both);
    Test.add_func("/notes/remove-unchanged-keeps-edited", test_remove_unchanged_keeps_edited);
    Test.add_func("/notes/two-processes-keep-every-edit", test_two_processes_keep_every_edit);
    Test.add_func("/notes/serialize-round-trip", test_serialize_round_trip);
    Test.add_func("/notes/parse-without-header", test_parse_without_header);
    Test.add_func("/notes/title-strips-markup", test_title_strips_markup);
    Test.add_func("/notes/store-save-load-search", test_store_save_load_search);
    Test.add_func("/notes/invalid-ids", test_invalid_ids_rejected);
    Test.add_func("/notes/legacy-import", test_legacy_import);
    Test.add_func("/notes/rich-text-round-trip", test_rich_text_round_trip);
    Test.add_func("/notes/rich-text-blocks", test_rich_text_blocks);
    return Test.run();
}
