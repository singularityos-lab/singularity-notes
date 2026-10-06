using Singularity.Apps.Notes;
using Singularity.Notes;

private string fixture(string name) {
    return Path.build_filename(Environment.get_variable("NOTES_FIXTURES") ?? "tests/fixtures", "one", name);
}

private string scratch() {
    try {
        return DirUtils.make_tmp("notes-onenote-XXXXXX");
    } catch (FileError e) {
        error("%s", e.message);
    }
}

private NoteStore open_store(string dir) {
    var store = new NoteStore(dir);
    store.legacy_data_dir = dir + "/none";
    store.legacy_documents_dir = dir + "/none";
    store.load();
    return store;
}

private Gee.List<OnePage> pages_of(string name) {
    uint8[] data;
    try {
        FileUtils.get_data(fixture(name), out data);
        return OneNoteImporter.read(data);
    } catch (Error e) {
        error("%s: %s", name, e.message);
    }
}

private OnePage page_titled(Gee.List<OnePage> pages, string title) {
    foreach (var p in pages) if (p.title == title) return p;
    error("page %s missing", title);
}

private string markdown(OnePage p) {
    return RichText.render(p.blocks);
}

private bool has_cell(OnePage p, string text) {
    foreach (var b in p.blocks) {
        if (b.kind != BlockKind.TABLE) continue;
        foreach (var row in b.table.rows) foreach (string c in row) if (c == text) return true;
    }
    return false;
}

private void test_table_cells_plain() {
    int tables = 0;
    foreach (string name in new string[] { "tika1.one", "testOneNote2.one", "onenote-rs-handwriting.one" }) {
        foreach (var p in pages_of(name)) {
            foreach (var b in p.blocks) {
                if (b.kind != BlockKind.TABLE) continue;
                tables++;
                assert(b.table.rows.size > 0 && b.table.columns > 0);
                bool header = false;
                foreach (string c in b.table.rows[0]) if (c != "") header = true;
                assert(header);
                for (int col = 0; col < b.table.columns; col++) {
                    bool used = false;
                    foreach (var row in b.table.rows) if (row[col] != "") used = true;
                    assert(used);
                }
                foreach (var row in b.table.rows) {
                    foreach (string c in row) {
                        assert(!c.contains("](") && !c.contains("<br>") && !c.contains("**") && !c.contains("\n") && !c.contains("<u>") && !c.contains("~~"));
                    }
                }
            }
        }
    }
    assert(tables >= 6);
    OnePage? basics = null;
    foreach (var p in pages_of("tika1.one")) if (p.title == "OneNote Basics") basics = p;
    assert(has_cell(basics, "Remember everything \u25b9Add Tags to any notes \u25b9Make checklists and to-do lists \u25b9Create your own custom tags"));
}

private int count_kind(OnePage p, BlockKind kind) {
    int n = 0;
    foreach (var b in p.blocks) if (b.kind == kind) n++;
    return n;
}

private void assert_loads(Bytes data, string name) {
    var loader = new Gdk.PixbufLoader();
    try {
        loader.write(data.get_data());
        loader.close();
    } catch (Error e) {
        error("%s does not load: %s", name, e.message);
    }
    var pix = loader.get_pixbuf();
    assert(pix != null && pix.width > 0 && pix.height > 0);
}

private void test_first_notebook() {
    var pages = pages_of("tika1.one");
    assert(pages.size == 2);
    assert(pages[0].title == "OneNote: one place for all of your notes");
    assert(pages[1].title == "OneNote Basics");
    var first = pages[0];
    assert(first.created == 1336059427);
    assert(first.modified == 1446572147);
    string md = markdown(first);
    assert(md.contains("Take notes anywhere on the page"));
    assert(md.contains("Write your name here"));
    assert(has_cell(first, "Clip from the web"));
    assert(has_cell(first, "Watch the 2 minute video"));
    assert(count_kind(first, BlockKind.TABLE) >= 2);
    assert(count_kind(first, BlockKind.NUMBERED) >= 1);
    var basics = pages[1].plain_text();
    assert(basics.contains("Remember everything"));
    assert(basics.contains("Convert tables to Excel spreadsheets"));
    int images = 0;
    foreach (var p in pages) {
        foreach (var b in p.blocks) {
            var f = p.files[b];
            if (f == null) continue;
            assert(b.kind == BlockKind.IMAGE);
            assert(!b.alt.contains("\n"));
            assert_loads(f.data, f.name);
            images++;
        }
    }
    assert(images == 36);
}

private void test_sections_with_history() {
    var two = pages_of("testOneNote2.one");
    assert(two.size == 2);
    var s1 = page_titled(two, "Section1HeaderTitle");
    string t1 = s1.plain_text();
    assert(t1.contains("wow this is neat"));
    assert(t1.contains("Section1TextArea1"));
    assert(t1.contains("Section1TextArea2"));
    assert(t1.contains("tubular"));
    assert(!t1.contains("Section1HeaderTitle"));
    assert(count_kind(s1, BlockKind.IMAGE) == 1);
    page_titled(two, "OneNote Basics");

    var three = pages_of("testOneNote3.one");
    assert(three.size == 1);
    var s2 = three[0];
    assert(s2.title == "Section2HeaderTitle");
    assert(s2.modified == 1574426624);
    string md = markdown(s2);
    assert(md.contains("Section2TextArea1"));
    assert(md.contains("Section2TextArea2"));
    assert(md.contains("neat info about **totally killin it bro**"));
    assert(!md.contains("Friday, November 22, 2019"));
}

private void test_onenote_2016() {
    var pages = pages_of("testOneNote2016.one");
    assert(pages.size == 1);
    assert(pages[0].title == "So good");
    assert(pages[0].plain_text().contains("This is one note 2016"));
    assert(pages[0].modified == 1576107480);
}

private void test_embedded_word_document() {
    var pages = pages_of("testOneNoteEmbeddedWordDoc.one");
    assert(pages.size == 1);
    var p = pages[0];
    assert(p.title == "Embedded doc sheet");
    OneFile? doc = null;
    foreach (var b in p.blocks) {
        if (b.kind != BlockKind.FILE) continue;
        doc = p.files[b];
        assert(b.alt == "Dude this is a super cool embedded doc.docx");
    }
    assert(doc != null);
    assert(doc.name.has_suffix(".docx"));
    unowned uint8[] raw = doc.data.get_data();
    assert(raw.length > 1000 && raw[0] == 'P' && raw[1] == 'K');
    try {
        string dir = scratch();
        string md = Importer.docx_to_markdown(raw, dir, "probe");
        assert(md.strip() != "");
    } catch (Error e) {
        error("%s", e.message);
    }
}

private void test_office365_package() {
    foreach (string name in new string[] { "testOneNoteFromOffice365.one", "testOneNoteFromOffice365-2.one" }) {
        var pages = pages_of(name);
        assert(pages.size == 2);
        assert(pages[0].title == "Section1Page1");
        assert(pages[1].title == "Section1Page2");
        assert(pages[0].plain_text().contains("Section1Page1Content"));
        assert(pages[1].plain_text().contains("Section1Page2Content"));
        assert(pages[0].created > 0 && pages[1].modified >= pages[1].created);
    }
    assert(pages_of("testOneNoteFromOffice365.one")[1].modified == 1636621448);
}

private void test_import_into_store() {
    string dir = scratch();
    var store = open_store(dir);
    assert(Importer.supported("/x/Section.ONE"));
    var loop = new MainLoop();
    Gee.List<ImportedNote>? got = null;
    Error? err = null;
    Importer.import_file.begin(File.new_for_path(fixture("tika1.one")), store, "OneNote", (o, r) => {
        try {
            got = Importer.import_file.end(r);
        } catch (Error e) {
            err = e;
        }
        loop.quit();
    });
    loop.run();
    if (err != null) error("%s", err.message);
    assert(got.size == 2);
    var again = open_store(dir);
    Note? first = null;
    int notes = 0;
    foreach (var n in again.all()) {
        if (n.folder != "OneNote") continue;
        notes++;
        if (PageDoc.title_of(n.body) == "OneNote: one place for all of your notes") first = n;
    }
    assert(notes == 2);
    assert(first != null);
    assert(first.created == 1336059427);
    assert(first.modified == 1446572147);
    string prefix = "attachments/" + first.id + "/";
    assert(first.body.contains(prefix));
    var blocks = RichText.parse(PageDoc.parse(first.body).body);
    int loaded = 0;
    foreach (var b in blocks) {
        if (b.kind != BlockKind.IMAGE) continue;
        assert(b.image.has_prefix(prefix));
        string path = Path.build_filename(dir, b.image);
        try {
            var pix = new Gdk.Pixbuf.from_file(path);
            assert(pix.width > 0);
        } catch (Error e) {
            error("%s: %s", path, e.message);
        }
        loaded++;
    }
    assert(loaded == 16);
    bool table = false;
    foreach (var b in blocks) if (b.kind == BlockKind.TABLE) table = true;
    assert(table);

    Gee.List<ImportedNote>? word = null;
    var loop2 = new MainLoop();
    Importer.import_file.begin(File.new_for_path(fixture("testOneNoteEmbeddedWordDoc.one")), store, "OneNote", (o, r) => {
        try {
            word = Importer.import_file.end(r);
        } catch (Error e) {
            err = e;
        }
        loop2.quit();
    });
    loop2.run();
    if (err != null) error("%s", err.message);
    assert(word.size == 1);
    assert(word[0].body.contains("[Dude this is a super cool embedded doc.docx](attachments/"));
}

private void test_damaged_input() {
    uint8[] data;
    try {
        FileUtils.get_data(fixture("testOneNote3.one"), out data);
    } catch (Error e) {
        error("%s", e.message);
    }
    foreach (int cut in new int[] { 0, 100, 2000, 9000, data.length / 2 }) {
        try {
            OneNoteImporter.read(data[0:cut]);
        } catch (Error e) {
        }
    }
    var noise = new uint8[4096];
    for (int i = 0; i < noise.length; i++) noise[i] = (uint8) Random.int_range(0, 256);
    bool rejected = false;
    try {
        OneNoteImporter.read(noise);
    } catch (Error e) {
        rejected = true;
    }
    assert(rejected);
    uint8[] flipped = data;
    for (int i = 1024; i < flipped.length; i += 97) flipped[i] ^= 0x5a;
    try {
        OneNoteImporter.read(flipped);
    } catch (Error e) {
    }
}

private const string INK_FIXTURE_LICENSE = "Mozilla Public License 2.0, from msiemens/onenote.rs, https://mozilla.org/MPL/2.0/";
private const string INK_SOURCE = "https://github.com/msiemens/onenote.rs/blob/master/crates/parser/tests/samples/handwriting_recognition.one";
private const string SCALED_INK_SOURCE = "https://github.com/msiemens/onenote.rs/blob/master/crates/parser/tests/samples/joplin/scaled_ink.one";

private void assert_ink_in_range(InkDoc doc) {
    foreach (var s in doc.strokes) {
        assert(s.points.size > 0);
        foreach (var p in s.points) assert(p.x >= 0 && p.y >= 0 && p.x <= doc.width && p.y <= doc.height);
    }
}

private OnePage handwriting_page() {
    var pages = pages_of("onenote-rs-handwriting.one");
    foreach (var p in pages) if (p.inks.size > 0) return p;
    error("no ink in %s (%s)", INK_SOURCE, INK_FIXTURE_LICENSE);
}

private void test_ink_sample() {
    var p = handwriting_page();
    assert(p.title == "Test Page");
    assert(count_kind(p, BlockKind.INK) == 1);
    assert(p.plain_text().contains("Lorem ipsum dolor sit amet"));
    Block? ink_block = null;
    foreach (var b in p.blocks) if (b.kind == BlockKind.INK) ink_block = b;
    var doc = p.inks[ink_block];
    assert(doc.strokes.size == 62);
    assert(doc.width == 638 && doc.height == 608);
    assert(ink_block.width == doc.width);
    assert_ink_in_range(doc);
    int points = 0;
    foreach (var s in doc.strokes) {
        assert(s.color == "#000000");
        assert(s.tool == "pen" && s.opacity == 1);
        assert(s.width > 0.4 && s.width < 20);
        points += s.points.size;
    }
    assert(points == 4145);
    assert(p.recognized_text() == "Hello World\nHello World");
    assert(p.recognized.size == 2);
    var first = p.recognized[0];
    assert(first.size == 2);
    assert(string.joinv("|", first[0].to_array()) == "Hello|Hallo|Hell|HellO|Hella");
    assert(string.joinv("|", first[1].to_array()) == "World|world|Worlds|Word|World.");
    assert(string.joinv("|", p.recognized[1][1].to_array()) == "World|world|Worlds|Word|Would");

    var scaled = pages_of("onenote-rs-scaled-ink.one");
    if (scaled.size != 1) error("unexpected page count in %s", SCALED_INK_SOURCE);
    assert(scaled[0].title == "Scaled");
    InkDoc? sdoc = null;
    foreach (var e in scaled[0].inks.entries) sdoc = e.value;
    assert(sdoc != null && sdoc.strokes.size == 2);
    assert(sdoc.height > sdoc.width);
    assert_ink_in_range(sdoc);
    var colors = new Gee.HashSet<string>();
    foreach (var s in sdoc.strokes) colors.add(s.color);
    assert(colors.size == 2 && colors.contains("#000000"));
}

private void test_ink_import_round_trip() {
    string dir = scratch();
    var store = open_store(dir);
    var loop = new MainLoop();
    Error? err = null;
    Importer.import_file.begin(File.new_for_path(fixture("onenote-rs-handwriting.one")), store, "Ink", (o, r) => {
        try {
            Importer.import_file.end(r);
        } catch (Error e) {
            err = e;
        }
        loop.quit();
    });
    loop.run();
    if (err != null) error("%s", err.message);
    Note? note = null;
    foreach (var n in open_store(dir).all()) if (n.folder == "Ink" && n.body.contains("ink-")) note = n;
    assert(note != null);
    var blocks = RichText.parse(PageDoc.parse(note.body).body);
    Block? ink = null;
    foreach (var b in blocks) if (b.kind == BlockKind.INK) ink = b;
    assert(ink != null);
    assert(ink.image.has_prefix("attachments/" + note.id + "/ink-") && ink.image.has_suffix(".svg"));
    var original = handwriting_page();
    InkDoc? source = null;
    foreach (var e in original.inks.entries) source = e.value;
    var doc = InkDoc.load(Path.build_filename(dir, ink.image));
    assert(doc.strokes.size == 62);
    assert(doc.width == 638 && doc.height == 608);
    assert_ink_in_range(doc);
    for (int i = 0; i < doc.strokes.size; i++) {
        var a = source.strokes[i];
        var b = doc.strokes[i];
        assert(a.points.size == b.points.size && a.color == b.color);
        assert(Math.fabs(a.points[0].x - b.points[0].x) <= 0.051 && Math.fabs(a.points[0].y - b.points[0].y) <= 0.051);
    }
    try {
        var pix = new Gdk.Pixbuf.from_file(Path.build_filename(dir, ink.image));
        assert(pix.width > 0);
    } catch (Error e) {
        error("%s", e.message);
    }
}

private void test_ink_path_encoding() {
    uint8[] raw = { 0x06, 0x0a, 0x07, 0xd8, 0x04 };
    var values = OneInk.decode_signed(raw);
    assert(values.length == 3 && values[0] == 5 && values[1] == -3 && values[2] == 300);
    int64[] path = { 2540, 0, 2540, -127, 0, 5080, 0, 254 };
    var encoded = OneInk.encode_signed(path);
    var back = OneInk.decode_signed(encoded);
    assert(back.length == path.length);
    for (int i = 0; i < path.length; i++) assert(back[i] == path[i]);
    string[] dims = { "598a6a8f-52c0-4ba0-93af-af357411a561", "b53f9f75-04e0-4498-a7ee-c30dbb5a9011" };
    var pts = OneInk.path(back, dims, 1, 1);
    assert(pts.size == 4);
    assert(Math.fabs(pts[0].x - 96) < 0.01 && Math.fabs(pts[0].y) < 0.01);
    assert(Math.fabs(pts[1].x - 96) < 0.01 && Math.fabs(pts[1].y - 192) < 0.01);
    assert(Math.fabs(pts[2].x - 192) < 0.01 && Math.fabs(pts[2].y - 192) < 0.01);
    assert(Math.fabs(pts[3].x - 187.2) < 0.01 && Math.fabs(pts[3].y - 201.6) < 0.01);
    var swapped = OneInk.path(back, { dims[1], dims[0] }, 2, 1);
    assert(Math.fabs(swapped[0].y - 96) < 0.01 && Math.fabs(swapped[0].x) < 0.01);
    assert(Math.fabs(swapped[1].x - 384) < 0.01 && Math.fabs(swapped[1].y - 96) < 0.01);
    assert(OneInk.color(0x073a8c) == "#8c3a07");
}

public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/onenote/first-notebook", test_first_notebook);
    Test.add_func("/onenote/sections", test_sections_with_history);
    Test.add_func("/onenote/onenote-2016", test_onenote_2016);
    Test.add_func("/onenote/embedded-word", test_embedded_word_document);
    Test.add_func("/onenote/office365-package", test_office365_package);
    Test.add_func("/onenote/import-into-store", test_import_into_store);
    Test.add_func("/onenote/damaged", test_damaged_input);
    Test.add_func("/onenote/table-cells-plain", test_table_cells_plain);
    Test.add_func("/onenote/ink-sample", test_ink_sample);
    Test.add_func("/onenote/ink-import", test_ink_import_round_trip);
    Test.add_func("/onenote/ink-path-encoding", test_ink_path_encoding);
    return Test.run();
}
