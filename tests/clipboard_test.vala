using Singularity.Apps.Notes;

private string scratch() {
    try {
        return DirUtils.make_tmp("notes-clip-XXXXXX");
    } catch (FileError e) {
        error("%s", e.message);
    }
}

private void write_png(string path, int w, int h, bool alpha) {
    DirUtils.create_with_parents(Path.get_dirname(path), 0700);
    var s = new Cairo.ImageSurface(alpha ? Cairo.Format.ARGB32 : Cairo.Format.RGB24, w, h);
    var cr = new Cairo.Context(s);
    cr.set_source_rgb(0.2, 0.5, 0.8);
    cr.paint();
    cr.set_source_rgb(1, 0.4, 0);
    cr.rectangle(w / 4, h / 4, w / 2, h / 2);
    cr.fill();
    s.write_to_png(path);
}

private Gdk.Pixbuf decode_uri(string html, int index, out string mime) {
    int start = html.index_of("src=\"data:", index);
    assert(start >= 0);
    start += 10;
    int semi = html.index_of(";base64,", start);
    mime = html.substring(start, semi - start);
    int end = html.index_of("\"", semi);
    var data = Base64.decode(html.substring(semi + 8, end - semi - 8));
    try {
        var loader = new Gdk.PixbufLoader();
        loader.write(data);
        loader.close();
        return loader.get_pixbuf();
    } catch (Error e) {
        error("%s", e.message);
    }
}

private NoteClip clip_of(string dir, string md) {
    return NoteClip.from_markdown(dir, "n1", md);
}

private void test_checkboxes() {
    var c = clip_of(scratch(), "- [ ] buy milk\n- [x] call **Anna**");
    string html = c.html();
    assert(html.has_prefix("<html><head><meta http-equiv=\"content-type\" content=\"text/html; charset=utf-8\">"));
    assert(html.contains("<!--StartFragment-->") && html.contains("<!--EndFragment-->"));
    assert(html.contains("<ul style=\"list-style-type:none\"><li><input type=\"checkbox\" disabled><span class=\"sx-check-fallback\" style=\"display:none\">☐ </span>buy milk</li><li><input type=\"checkbox\" disabled checked><span class=\"sx-check-fallback\" style=\"display:none\">☑ </span>call <b>Anna</b></li></ul>"));
    assert(html.contains("<!--StartFragment--><style>input[type=checkbox] + .sx-check-fallback { display: none }</style>"));
    assert(!clip_of(scratch(), "- one").html().contains("<style>"));
    string plain = c.plain();
    assert(plain == "- [ ] buy milk\n- [x] call Anna");
    var conv = new HtmlConverter();
    conv.heading_shift = 0;
    conv.convert(html, false);
    assert(conv.blocks.size == 2);
    assert(conv.blocks[0].kind == BlockKind.CHECK && !conv.blocks[0].checked);
    assert(conv.blocks[1].kind == BlockKind.CHECK && conv.blocks[1].checked);
    assert(conv.blocks[0].plain_text() == "buy milk");
    assert(conv.blocks[1].plain_text() == "call Anna" && conv.blocks[1].spans[1].bold);
    var stripped = new HtmlConverter();
    stripped.convert("<p>☑ paid rent</p><p>☐ book flights</p>", false);
    assert(stripped.blocks.size == 2);
    assert(stripped.blocks[0].kind == BlockKind.CHECK && stripped.blocks[0].checked && stripped.blocks[0].plain_text() == "paid rent");
    assert(stripped.blocks[1].kind == BlockKind.CHECK && !stripped.blocks[1].checked);
}

private void test_nested_lists() {
    var c = clip_of(scratch(), "- one\n    - two\n        1. three\n        1. four\n- five\n1. six\n1. seven");
    string html = c.html_fragment();
    assert(html == "<ul><li>one<ul><li>two<ol type=\"i\"><li>three</li><li>four</li></ol>\n</li></ul>\n</li><li>five</li></ul>\n<ol><li>six</li><li>seven</li></ol>\n");
    assert(c.plain() == "- one\n    - two\n        i. three\n        ii. four\n- five\n1. six\n2. seven");
    var conv = new HtmlConverter();
    conv.heading_shift = 0;
    conv.convert(c.html(), false);
    string[] kinds = { "BULLET0", "BULLET1", "NUMBERED2", "NUMBERED2", "BULLET0", "NUMBERED0", "NUMBERED0" };
    assert(conv.blocks.size == kinds.length);
    for (int i = 0; i < kinds.length; i++) {
        var b = conv.blocks[i];
        string k = (b.kind == BlockKind.BULLET ? "BULLET" : b.kind == BlockKind.NUMBERED ? "NUMBERED" : "OTHER") + b.indent.to_string();
        if (k != kinds[i]) error("block %d is %s, expected %s", i, k, kinds[i]);
    }
}

private void test_formatting_and_tables() {
    var c = clip_of(scratch(), "## Title\n**b** *i* <u>u</u> ~~s~~ <span style=\"color:#e01b24\">red</span> ==mark== [web](https://example.org) [page](note:abc)\n> quoted\n<!-- table shading=\"1:1:#d0ebff\" -->\n| A | B |\n| --- | --- |\n| 1 | 2 |\n---");
    string html = c.html_fragment();
    assert(html.contains("<h2>Title</h2>"));
    assert(html.contains("<b>b</b>") && html.contains("<i>i</i>") && html.contains("<u>u</u>") && html.contains("<s>s</s>"));
    assert(html.contains("<span style=\"color:#e01b24;\">red</span>"));
    assert(html.contains("background-color:#ffe066;"));
    assert(html.contains("<a href=\"https://example.org\">web</a>"));
    assert(!html.contains("note:abc") && html.contains("page"));
    assert(html.contains("<blockquote>quoted</blockquote>"));
    assert(html.contains("<th style=\"border:1px solid #c0bfbc;padding:4px 8px;\">A</th>"));
    assert(html.contains("background-color:#d0ebff;\">2</td>"));
    assert(html.contains("<hr>"));
    var conv = new HtmlConverter();
    conv.heading_shift = 0;
    conv.convert(c.html(), false);
    assert(conv.blocks[0].kind == BlockKind.HEADING2);
    bool red = false, hl = false;
    foreach (var s in conv.blocks[1].spans) {
        if (s.text == "red" && s.color == "#e01b24") red = true;
        if (s.text == "mark" && s.highlight == "yellow") hl = true;
    }
    assert(red && hl);
    bool table = false;
    foreach (var b in conv.blocks) {
        if (b.kind != BlockKind.TABLE) continue;
        table = b.table.cell(1, 1) == "2" && b.table.shade(1, 1) == "#d0ebff" && b.table.shade(0, 0) == "";
    }
    assert(table);
    var aligned = clip_of(scratch(), "| A | B |\n| --- | ---: |\n| 1 | 2 |");
    assert(aligned.plain() == "| A | B |\n| --- | ---: |\n| 1 | 2 |");
    var aconv = new HtmlConverter();
    aconv.convert(aligned.html(), false);
    assert(aconv.blocks[0].kind == BlockKind.TABLE && aconv.blocks[0].table.aligns[1] == "right");
    var shaded = clip_of(scratch(), "<!-- table shading=\"0:0:#d0ebff\" -->\n| A | B |\n| --- | --- |\n| 1 | 2 |");
    assert(!shaded.plain().contains("<!--"));
    var inline_clip = clip_of(scratch(), "plain **bold** words");
    inline_clip.inline = true;
    assert(inline_clip.html_fragment() == "plain <b>bold</b> words");
    assert(inline_clip.plain() == "plain bold words");
}

private void test_images() {
    string dir = scratch();
    write_png(Path.build_filename(dir, "attachments", "n1", "photo.png"), 300, 200, false);
    write_png(Path.build_filename(dir, "attachments", "n1", "huge.png"), 3200, 1800, false);
    var c = clip_of(dir, "![A photo](attachments/n1/photo.png)\n<img src=\"attachments/n1/photo.png\" alt=\"small\" width=\"150\">\n![Huge](attachments/n1/huge.png)\n[report.pdf](attachments/n1/report.pdf)");
    string html = c.html();
    string mime;
    var first = decode_uri(html, 0, out mime);
    assert(mime == "image/png" && first.width == 300 && first.height == 200);
    assert(html.contains("alt=\"A photo\" width=\"300\" height=\"200\""));
    assert(html.contains("alt=\"small\" width=\"150\" height=\"100\""));
    int huge_at = html.index_of("alt=\"Huge\"");
    int src_at = html.substring(0, huge_at).last_index_of("src=\"data:");
    var huge = decode_uri(html, src_at, out mime);
    assert(huge.width == NoteClip.MAX_SIDE && huge.height == 900);
    assert(html.contains("alt=\"Huge\" width=\"680\" height=\"383\""));
    assert(html.contains("<a href=\"file://") && html.contains("report.pdf</a>"));
    assert(c.plain().contains("![A photo]") && c.plain().contains("[report.pdf]"));
    var single = clip_of(dir, "![A photo](attachments/n1/photo.png)");
    var png = single.single_png();
    assert(png != null);
    uint8[] sig = png.get_data()[0:4];
    assert(sig[0] == 0x89 && sig[1] == 'P' && sig[2] == 'N' && sig[3] == 'G');
    assert(c.single_png() == null);
    var conv = new HtmlConverter();
    conv.heading_shift = 0;
    conv.convert(html, false);
    int images = 0;
    foreach (var b in conv.blocks) if (b.kind == BlockKind.IMAGE && b.image.has_prefix("data:image/")) images++;
    assert(images == 3);
}

private void test_ink_rendering() {
    string dir = scratch();
    var doc = new InkDoc();
    var s = new Stroke();
    s.color = "#e01b24";
    s.width = 4;
    s.points.add(new InkPoint(100, 50));
    s.points.add(new InkPoint(200, 100));
    s.points.add(new InkPoint(300, 150));
    doc.strokes.add(s);
    var r = new Stroke();
    r.shape = "rect";
    r.color = "#1c71d8";
    r.width = 2;
    r.points.add(new InkPoint(120, 120));
    r.points.add(new InkPoint(180, 160));
    doc.strokes.add(r);
    string path = Path.build_filename(dir, "attachments", "n1", "ink-abc.svg");
    try {
        doc.save(path);
    } catch (Error e) {
        error("%s", e.message);
    }
    int w, h;
    var png = NoteClip.ink_png(InkDoc.load(path), 1.0, out w, out h);
    assert(png != null);
    assert(w > 200 && w < 240 && h > 100 && h < 140);
    Gdk.Pixbuf pb;
    try {
        var loader = new Gdk.PixbufLoader();
        loader.write(png.get_data());
        loader.close();
        pb = loader.get_pixbuf();
    } catch (Error e) {
        error("%s", e.message);
    }
    assert(pb.width == w && pb.height == h && pb.has_alpha);
    unowned uint8[] px = pb.get_pixels_with_length();
    int stride = pb.rowstride;
    assert(px[3] == 0);
    int red = 0, blue = 0;
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            uint8* p = (uint8*) px + y * stride + x * 4;
            if (p[3] > 200 && p[0] > 180 && p[2] < 80) red++;
            if (p[3] > 200 && p[2] > 180 && p[0] < 80) blue++;
        }
    }
    assert(red > 300 && blue > 100);
    var c = clip_of(dir, "Before\n![Drawing](attachments/n1/ink-abc.svg)");
    string html = c.html();
    assert(html.contains("alt=\"Drawing\" width=\"%d\" height=\"%d\"".printf(w, h)));
    string mime;
    var shown = decode_uri(html, 0, out mime);
    assert(mime == "image/png" && shown.width == w * 2 && shown.height == h * 2);
    var single = clip_of(dir, "![Drawing](attachments/n1/ink-abc.svg)");
    assert(single.single_png() != null);
}

private void test_native_and_import() {
    string dir = scratch();
    string src = Path.build_filename(dir, "attachments", "n1", "voice.ogg");
    write_png(Path.build_filename(dir, "attachments", "n1", "photo.png"), 40, 30, true);
    try {
        FileUtils.set_contents(src, "OggS");
        FileUtils.set_contents(src + ".json", "{\"transcript\":\"hello there\"}");
    } catch (Error e) {
        error("%s", e.message);
    }
    string md = "# Head <a id=\"p-1\"></a>\n- [x] done\n![Photo](attachments/n1/photo.png)\n[Audio recording](attachments/n1/voice.ogg)";
    var c = clip_of(dir, md);
    assert(c.html().contains("<blockquote>hello there</blockquote>"));
    var back = NoteClip.parse_native(c.native());
    assert(back != null && back.notes_dir == dir && back.note_id == "n1" && !back.inline);
    assert(RichText.render(back.blocks) == RichText.render(c.blocks));
    var frag = clip_of(dir, "a **b**");
    frag.inline = true;
    var fb = NoteClip.parse_native(frag.native());
    assert(fb.inline && fb.blocks.size == 1 && fb.blocks[0].spans[1].bold);
    back.import_into(dir, "n2");
    assert(back.blocks[0].anchor == "");
    assert(back.blocks[2].image == "attachments/n2/photo.png");
    assert(back.blocks[3].image == "attachments/n2/voice.ogg");
    assert(FileUtils.test(Path.build_filename(dir, "attachments", "n2", "photo.png"), FileTest.IS_REGULAR));
    assert(FileUtils.test(Path.build_filename(dir, "attachments", "n2", "voice.ogg.json"), FileTest.IS_REGULAR));
    var again = NoteClip.parse_native(c.native());
    again.import_into(dir, "n2");
    assert(again.blocks[2].image == "attachments/n2/2-photo.png");
    var same = NoteClip.parse_native(c.native());
    same.import_into(dir, "n1");
    assert(same.blocks[2].image == "attachments/n1/photo.png");
}

public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/clipboard/checkboxes", test_checkboxes);
    Test.add_func("/clipboard/nested-lists", test_nested_lists);
    Test.add_func("/clipboard/formatting-tables", test_formatting_and_tables);
    Test.add_func("/clipboard/images", test_images);
    Test.add_func("/clipboard/ink", test_ink_rendering);
    Test.add_func("/clipboard/native-import", test_native_and_import);
    return Test.run();
}
