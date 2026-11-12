use std::cell::Cell;
use std::collections::HashSet;
use std::io::{Cursor, Read};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Once;

use office_oxide::{Document, DocumentFormat};
use quick_xml::Reader;
use quick_xml::events::Event;

use super::scope::CHUNK;
use super::{pptx, rtf};

const PDF_LOAD: usize = 16 << 20;
const PDF_PAGE: usize = 8 << 20;
const PDF_OBJECTS: usize = 8 << 20;
pub(super) const MAX_PART: u64 = 64 << 20;
pub(super) const OFFICE_PACKAGE: u64 = 256 << 20;
const CUT_HEAD: &str = "[output truncated: ";
const CUT_TAIL: &str = "(office_oxide::limits::set_max_text_chars)]";

#[cfg(test)]
pub(crate) const PANIC: &[u8] = b"%WHEREVER-TEST-PANIC";

#[derive(Clone, Copy)]
enum Kind {
    Pdf,
    Docx,
    Pptx,
    Odt,
    Rtf,
    Office(DocumentFormat),
}

fn kind(ext: &[u8]) -> Option<Kind> {
    let mut buf = [0u8; 4];
    let low = buf.get_mut(..ext.len())?;
    low.copy_from_slice(ext);
    low.make_ascii_lowercase();
    Some(match &*low {
        b"pdf" => Kind::Pdf,
        b"docx" | b"docm" | b"dotx" | b"dotm" => Kind::Docx,
        b"odt" | b"ods" | b"odp" | b"ott" | b"ots" | b"otp" => Kind::Odt,
        b"rtf" => Kind::Rtf,
        b"doc" | b"dot" => Kind::Office(DocumentFormat::Doc),
        b"xlsx" | b"xlsm" | b"xltx" | b"xltm" => Kind::Office(DocumentFormat::Xlsx),
        b"xls" | b"xlt" => Kind::Office(DocumentFormat::Xls),
        b"pptx" | b"pptm" | b"potx" | b"ppsx" | b"ppsm" => Kind::Pptx,
        b"ppt" | b"pot" | b"pps" => Kind::Office(DocumentFormat::Ppt),
        _ => return None,
    })
}

pub(crate) fn is(ext: &[u8]) -> bool {
    kind(ext).is_some()
}

pub(crate) fn read(ext: &[u8], bytes: Vec<u8>, seen: &mut dyn FnMut(&str) -> bool) -> bool {
    let Some(kind) = kind(ext) else {
        return false;
    };
    catch_unwind(AssertUnwindSafe(move || {
        #[cfg(test)]
        if bytes.starts_with(PANIC) {
            panic!("a test document that panics");
        }
        let whole = match kind {
            Kind::Pdf => return pdf(&bytes, seen),
            Kind::Docx => xml_part(&bytes, true),
            Kind::Pptx => pptx::text(&bytes),
            Kind::Odt => xml_part(&bytes, false),
            Kind::Rtf => rtf::text(&bytes),
            Kind::Office(format) => office(bytes, format),
        };
        let Some(text) = whole else {
            return false;
        };
        let mut rest = text.as_str();
        while !rest.is_empty() {
            let (piece, after) = rest.split_at(rest.floor_char_boundary(CHUNK));
            if seen(piece) {
                break;
            }
            rest = after;
        }
        true
    }))
    .unwrap_or(false)
}

#[cfg(test)]
pub(crate) fn text(ext: &[u8], bytes: Vec<u8>) -> Option<String> {
    let mut out = String::new();
    let read = read(ext, bytes, &mut |t| {
        out.push_str(t);
        false
    });
    (read && !out.trim().is_empty()).then_some(out)
}

fn pdf(b: &[u8], seen: &mut dyn FnMut(&str) -> bool) -> bool {
    pdf_capped(b, PDF_OBJECTS, seen)
}

thread_local! {
    static LOADED: Cell<(usize, usize, bool)> = const { Cell::new((0, 0, false)) };
}

fn pdf_capped(b: &[u8], cap: usize, seen: &mut dyn FnMut(&str) -> bool) -> bool {
    LOADED.set((0, cap, false));
    let options = lopdf::LoadOptions {
        filter: Some(kept),
        ..lopdf::LoadOptions::with_max_decompressed_size(PDF_LOAD)
    };
    let Ok(mut doc) = lopdf::Document::load_mem_with_options(b, options) else {
        return false;
    };
    let mut once = HashSet::new();
    let pages: Vec<_> = doc.page_iter().filter(|&id| once.insert(id)).collect();
    let root = doc.add_object(lopdf::dictionary! { "Type" => "Pages" });
    let Ok(catalog) = doc.catalog_mut() else {
        return false;
    };
    catalog.set("Pages", root);
    let mut read = false;
    for id in pages {
        let Ok(tree) = doc.get_dictionary_mut(root) else {
            return read;
        };
        tree.set("Kids", vec![lopdf::Object::Reference(id)]);
        #[cfg(test)]
        tests::WALKED.set(tests::WALKED.get() + doc.get_pages().len());
        if let Ok(t) = doc.extract_text_with_limit(&[1], PDF_PAGE) {
            read = true;
            let mut page = unligate(&t);
            page.push('\n');
            if seen(&page) {
                break;
            }
        }
    }
    read
}

fn kept(
    id: lopdf::ObjectId,
    object: &mut lopdf::Object,
) -> Option<(lopdf::ObjectId, lopdf::Object)> {
    let (count, cap, streams) = LOADED.get();
    let count = count.saturating_add(objects(object));
    let streams =
        streams || matches!(object, lopdf::Object::Stream(s) if s.dict.has_type(b"ObjStm"));
    LOADED.set((count, cap, streams));
    if count > cap {
        None
    } else if !streams || matches!(object, lopdf::Object::Stream(_)) {
        Some((id, lopdf::Object::Null))
    } else {
        Some((id, object.clone()))
    }
}

fn objects(object: &lopdf::Object) -> usize {
    1 + match object {
        lopdf::Object::Array(items) => items.iter().map(objects).sum(),
        lopdf::Object::Dictionary(d) => d.iter().map(|(_, v)| objects(v)).sum(),
        lopdf::Object::Stream(s) => s.dict.iter().map(|(_, v)| objects(v)).sum(),
        _ => 0,
    }
}

fn unligate(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '\u{FB00}' => out.push_str("ff"),
            '\u{FB01}' => out.push_str("fi"),
            '\u{FB02}' => out.push_str("fl"),
            '\u{FB03}' => out.push_str("ffi"),
            '\u{FB04}' => out.push_str("ffl"),
            '\u{FB05}' | '\u{FB06}' => out.push_str("st"),
            c => out.push(c),
        }
    }
    out
}

fn xml_part(b: &[u8], docx: bool) -> Option<String> {
    let body = if docx {
        "word/document.xml"
    } else {
        "content.xml"
    };
    let mut zip = zip::ZipArchive::new(Cursor::new(b)).ok()?;
    let mut left = OFFICE_PACKAGE;
    let mut out = part_text(&zip_part(&mut zip, body, &mut left)?, docx);
    if !docx {
        return Some(out);
    }
    let mut more: Vec<String> = (zip.file_names().flatten())
        .filter(|n| word_part(n))
        .map(|n| n.into_owned())
        .collect();
    more.sort();
    for name in more {
        if left == 0 {
            break;
        }
        if let Some(xml) = zip_part(&mut zip, &name, &mut left) {
            out.push('\n');
            out.push_str(&part_text(&xml, true));
        }
    }
    Some(out)
}

fn zip_part(
    zip: &mut zip::ZipArchive<Cursor<&[u8]>>,
    name: &str,
    left: &mut u64,
) -> Option<Vec<u8>> {
    let mut xml = Vec::new();
    (zip.by_name(name).ok()?)
        .take(MAX_PART.min(*left))
        .read_to_end(&mut xml)
        .ok()?;
    *left -= xml.len() as u64;
    Some(xml)
}

fn word_part(name: &str) -> bool {
    let name = name.to_ascii_lowercase();
    let Some(file) = name.strip_prefix("word/") else {
        return false;
    };
    matches!(file, "footnotes.xml" | "endnotes.xml" | "comments.xml")
        || (!file.contains('/')
            && file.ends_with(".xml")
            && (file.starts_with("header") || file.starts_with("footer")))
}

fn part_text(xml: &[u8], docx: bool) -> String {
    let mut r = Reader::from_reader(xml);
    let config = r.config_mut();
    config.check_end_names = false;
    config.allow_dangling_amp = true;
    config.allow_unmatched_ends = true;
    let (mut out, mut in_run, mut depth) = (String::new(), false, 0usize);
    while let Ok(event) = r.read_event() {
        match event {
            Event::Start(e) => match (docx, e.name().as_ref()) {
                (true, "w:t") => in_run = true,
                (false, "text:p" | "text:h") => depth += 1,
                (docx, name) => out.push_str(spacing(docx, name)),
            },
            Event::Empty(e) => out.push_str(spacing(docx, e.name().as_ref())),
            Event::End(e) => match (docx, e.name().as_ref()) {
                (true, "w:t") => in_run = false,
                (true, "w:p") => out.push('\n'),
                (false, "text:p" | "text:h") => {
                    depth = depth.saturating_sub(1);
                    out.push('\n');
                }
                _ => {}
            },
            Event::Text(t) if in_run || depth > 0 => out.push_str(&t),
            Event::GeneralRef(g) if in_run || depth > 0 => match &*g {
                "amp" => out.push('&'),
                "lt" => out.push('<'),
                "gt" => out.push('>'),
                "quot" => out.push('"'),
                "apos" => out.push('\''),
                _ => {
                    if let Ok(Some(c)) = g.resolve_char_ref() {
                        out.push(c);
                    }
                }
            },
            Event::Eof => break,
            _ => {}
        }
    }
    out
}

fn spacing(docx: bool, name: &str) -> &'static str {
    match (docx, name) {
        (true, "w:tab") | (false, "text:tab") => "\t",
        (true, "w:br" | "w:cr") | (false, "text:line-break") => "\n",
        (false, "text:s") => " ",
        _ => "",
    }
}

fn office(bytes: Vec<u8>, format: DocumentFormat) -> Option<String> {
    office_limits();
    let text = Document::from_reader(Cursor::new(bytes), format)
        .ok()?
        .plain_text();
    Some(without_cut_line(text))
}

fn office_limits() {
    static LIMITS: Once = Once::new();
    LIMITS.call_once(|| {
        office_oxide::limits::set_max_package_bytes(OFFICE_PACKAGE);
    });
}

fn without_cut_line(text: String) -> String {
    if !text.contains(CUT_HEAD) {
        return text;
    }
    text.lines()
        .filter(|l| !(l.starts_with(CUT_HEAD) && l.ends_with(CUT_TAIL)))
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::crawl::tests::TempTree;
    use crate::crawl::{Pool, TEXT_STACK};
    use crate::engine::tests::{start_with, text_config, texts};
    use crate::engine::timing::Rng;
    use crate::text::scope;
    use lopdf::{Dictionary, Object, Stream, dictionary};
    use std::fs;
    use std::io::Write;
    use std::path::{Path, PathBuf};
    use std::process::Command;

    thread_local! {
        pub(crate) static WALKED: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
    }

    pub(crate) fn page(words: &str) -> Vec<u8> {
        format!("BT /F1 12 Tf 50 700 Td ({words}) Tj ET").into_bytes()
    }

    fn pdf_with(
        font: impl FnOnce(&mut lopdf::Document) -> Dictionary,
        pages: &[Vec<u8>],
    ) -> Vec<u8> {
        let mut doc = lopdf::Document::with_version("1.5");
        let pages_id = doc.new_object_id();
        let font = font(&mut doc);
        let font = doc.add_object(font);
        let resources = doc.add_object(dictionary! { "Font" => dictionary! { "F1" => font } });
        let kids: Vec<Object> = pages
            .iter()
            .map(|content| {
                let contents = doc.add_object(Stream::new(dictionary! {}, content.clone()));
                doc.add_object(dictionary! {
                    "Type" => "Page",
                    "Parent" => pages_id,
                    "Contents" => contents,
                    "Resources" => resources,
                    "MediaBox" => vec![0.into(), 0.into(), 595.into(), 842.into()],
                })
                .into()
            })
            .collect();
        let count = kids.len() as i64;
        doc.objects.insert(
            pages_id,
            Object::Dictionary(dictionary! { "Type" => "Pages", "Kids" => kids, "Count" => count }),
        );
        let catalog = doc.add_object(dictionary! { "Type" => "Catalog", "Pages" => pages_id });
        doc.trailer.set("Root", catalog);
        let mut out = Vec::new();
        doc.save_to(&mut out).unwrap();
        out
    }

    pub(crate) fn pdf(pages: &[Vec<u8>]) -> Vec<u8> {
        pdf_with(
            |_| dictionary! { "Type" => "Font", "Subtype" => "Type1", "BaseFont" => "Courier" },
            pages,
        )
    }

    fn zipped(parts: &[(&str, &str)]) -> Vec<u8> {
        let mut z = zip::ZipWriter::new(Cursor::new(Vec::new()));
        for (name, data) in parts {
            z.start_file(*name, zip::write::SimpleFileOptions::default())
                .unwrap();
            z.write_all(data.as_bytes()).unwrap();
        }
        z.finish().unwrap().into_inner()
    }

    const H: &str = r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#;
    const RT: &str = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";

    fn rels(items: &[(&str, &str, &str)]) -> String {
        let items: String = items
            .iter()
            .map(|(id, kind, target)| {
                format!(r#"<Relationship Id="{id}" Type="{RT}/{kind}" Target="{target}"/>"#)
            })
            .collect();
        format!(
            r#"{H}<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">{items}</Relationships>"#
        )
    }

    fn types(overrides: &[(&str, &str)]) -> String {
        let items: String = overrides
            .iter()
            .map(|(part, kind)| {
                format!(
                    r#"<Override PartName="{part}" ContentType="application/vnd.openxmlformats-officedocument.{kind}+xml"/>"#
                )
            })
            .collect();
        format!(
            r#"{H}<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>{items}</Types>"#
        )
    }

    pub(crate) fn docx(text: &str) -> Vec<u8> {
        let doc = format!(
            r#"{H}<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t xml:space="preserve">{text}</w:t></w:r></w:p></w:body></w:document>"#
        );
        zipped(&[
            (
                "[Content_Types].xml",
                &types(&[("/word/document.xml", "wordprocessingml.document.main")]),
            ),
            (
                "_rels/.rels",
                &rels(&[("rId1", "officeDocument", "word/document.xml")]),
            ),
            ("word/document.xml", &doc),
        ])
    }

    pub(crate) fn xlsx(shared: &[String], rows: usize, inline: &str) -> Vec<u8> {
        let si: String = shared
            .iter()
            .map(|s| format!(r#"<si><t xml:space="preserve">{s}</t></si>"#))
            .collect();
        let sst = format!(
            r#"{H}<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="{rows}" uniqueCount="{}">{si}</sst>"#,
            shared.len()
        );
        let mut cells: String = (0..rows)
            .map(|i| {
                format!(
                    r#"<row r="{n}"><c r="A{n}" t="s"><v>{}</v></c></row>"#,
                    i % shared.len(),
                    n = i + 1
                )
            })
            .collect();
        let n = rows + 1;
        cells.push_str(&format!(
            r#"<row r="{n}"><c r="A{n}" t="inlineStr"><is><t>{inline}</t></is></c></row>"#
        ));
        let sheet = format!(
            r#"{H}<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>{cells}</sheetData></worksheet>"#
        );
        let book = format!(
            r#"{H}<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="{RT}"><sheets><sheet name="Data" sheetId="1" r:id="rId1"/></sheets></workbook>"#
        );
        zipped(&[
            (
                "[Content_Types].xml",
                &types(&[
                    ("/xl/workbook.xml", "spreadsheetml.sheet.main"),
                    ("/xl/worksheets/sheet1.xml", "spreadsheetml.worksheet"),
                    ("/xl/sharedStrings.xml", "spreadsheetml.sharedStrings"),
                ]),
            ),
            (
                "_rels/.rels",
                &rels(&[("rId1", "officeDocument", "xl/workbook.xml")]),
            ),
            ("xl/workbook.xml", &book),
            (
                "xl/_rels/workbook.xml.rels",
                &rels(&[
                    ("rId1", "worksheet", "worksheets/sheet1.xml"),
                    ("rId2", "sharedStrings", "sharedStrings.xml"),
                ]),
            ),
            ("xl/sharedStrings.xml", &sst),
            ("xl/worksheets/sheet1.xml", &sheet),
        ])
    }

    pub(crate) fn pptx(text: &str) -> Vec<u8> {
        let ns = r#"xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main""#;
        let tree = r#"<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>"#;
        let slide = format!(
            r#"{H}<p:sld {ns}><p:cSld><p:spTree>{tree}<p:sp><p:nvSpPr><p:cNvPr id="2" name="T2"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang="en-US"/><a:t>{text}</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>"#
        );
        let pres = format!(
            r#"{H}<p:presentation {ns}><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst><p:sldId id="256" r:id="rId10"/></p:sldIdLst><p:sldSz cx="9144000" cy="6858000"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>"#
        );
        let master = format!(
            r#"{H}<p:sldMaster {ns}><p:cSld><p:spTree>{tree}</p:spTree></p:cSld><p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/><p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst></p:sldMaster>"#
        );
        let layout = format!(
            r#"{H}<p:sldLayout {ns} type="blank"><p:cSld name="Blank"><p:spTree>{tree}</p:spTree></p:cSld></p:sldLayout>"#
        );
        zipped(&[
            (
                "[Content_Types].xml",
                &types(&[
                    ("/ppt/presentation.xml", "presentationml.presentation.main"),
                    (
                        "/ppt/slideMasters/slideMaster1.xml",
                        "presentationml.slideMaster",
                    ),
                    (
                        "/ppt/slideLayouts/slideLayout1.xml",
                        "presentationml.slideLayout",
                    ),
                    ("/ppt/slides/slide1.xml", "presentationml.slide"),
                ]),
            ),
            (
                "_rels/.rels",
                &rels(&[("rId1", "officeDocument", "ppt/presentation.xml")]),
            ),
            ("ppt/presentation.xml", &pres),
            (
                "ppt/_rels/presentation.xml.rels",
                &rels(&[
                    ("rId1", "slideMaster", "slideMasters/slideMaster1.xml"),
                    ("rId10", "slide", "slides/slide1.xml"),
                ]),
            ),
            ("ppt/slideMasters/slideMaster1.xml", &master),
            (
                "ppt/slideMasters/_rels/slideMaster1.xml.rels",
                &rels(&[("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml")]),
            ),
            ("ppt/slideLayouts/slideLayout1.xml", &layout),
            (
                "ppt/slideLayouts/_rels/slideLayout1.xml.rels",
                &rels(&[("rId1", "slideMaster", "../slideMasters/slideMaster1.xml")]),
            ),
            ("ppt/slides/slide1.xml", &slide),
            (
                "ppt/slides/_rels/slide1.xml.rels",
                &rels(&[("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml")]),
            ),
        ])
    }

    pub(crate) fn textutil(format: &str, text: &str, dir: &Path) -> Vec<u8> {
        let src = dir.join(format!("textutil-{format}.txt"));
        let out = dir.join(format!("textutil-out.{format}"));
        fs::write(&src, text).unwrap();
        let status = Command::new("/usr/bin/textutil")
            .args(["-convert", format, "-output"])
            .arg(&out)
            .arg(&src)
            .status()
            .unwrap();
        assert!(status.success(), "textutil -convert {format}");
        let bytes = fs::read(&out).unwrap();
        fs::remove_file(&src).unwrap();
        fs::remove_file(&out).unwrap();
        bytes
    }

    fn scratch(name: &str) -> TempTree {
        TempTree::new(&format!("rich-scratch-{name}"))
    }

    fn put(tree: &TempTree, name: &str, bytes: &[u8]) {
        let path = tree.0.join(name);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, bytes).unwrap();
    }

    #[test]
    fn a_pdf_is_found_by_its_text() {
        let tree = TempTree::new("rich-pdf");
        put(&tree, "report.pdf", &pdf(&[page("zyqgranite ledger")]));
        put(&tree, "other.pdf", &pdf(&[page("basalt")]));
        let (engine, _listener, rx) = start_with(text_config(&tree), None);
        assert_eq!(texts(&engine, &rx, "text:zyqgranite"), ["report.pdf"]);
        assert_eq!(texts(&engine, &rx, "text:basalt"), ["other.pdf"]);
    }

    #[test]
    fn a_ligature_reads_as_its_letters() {
        let cmap = "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n1 beginbfchar\n<0001> <FB01>\nendbfchar\n1 beginbfrange\n<0020> <007E> <0020>\nendbfrange\nendcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n";
        let codes: String = std::iter::once(1)
            .chain("ndzyq".bytes().map(u16::from))
            .map(|c| format!("{c:04X}"))
            .collect();
        let font = |doc: &mut lopdf::Document| {
            let to_unicode = doc.add_object(Stream::new(dictionary! {}, cmap.as_bytes().to_vec()));
            dictionary! {
                "Type" => "Font",
                "Subtype" => "Type0",
                "BaseFont" => "DummyFont",
                "Encoding" => "Identity-H",
                "ToUnicode" => to_unicode,
            }
        };
        let content = format!("BT /F1 12 Tf 50 700 Td <{codes}> Tj ET").into_bytes();
        let bytes = pdf_with(font, &[content]);
        let text = text(b"pdf", bytes.clone()).unwrap();
        assert!(text.contains("findzyq"), "{text:?}");
        assert!(!text.contains('\u{FB01}'));
        let tree = TempTree::new("rich-ligature");
        put(&tree, "lig.pdf", &bytes);
        let (engine, _listener, rx) = start_with(text_config(&tree), None);
        assert_eq!(texts(&engine, &rx, "text:findzyq"), ["lig.pdf"]);
    }

    #[test]
    fn word_and_odt_are_found_by_their_text() {
        let dir = scratch("word");
        let tree = TempTree::new("rich-word");
        for format in ["docx", "odt", "doc"] {
            let made = textutil(format, &format!("zyq{format}made words"), &dir.0);
            put(&tree, &format!("made.{format}"), &made);
        }
        put(&tree, "zipped.docx", &docx("zyqzipped words"));
        let (engine, _listener, rx) = start_with(text_config(&tree), None);
        assert_eq!(texts(&engine, &rx, "text:zyqdocxmade"), ["made.docx"]);
        assert_eq!(texts(&engine, &rx, "text:zyqodtmade"), ["made.odt"]);
        assert_eq!(texts(&engine, &rx, "text:zyqdocmade"), ["made.doc"]);
        assert_eq!(texts(&engine, &rx, "text:zyqzipped"), ["zipped.docx"]);
        assert_eq!(texts(&engine, &rx, "text:words").len(), 4);
    }

    const W: &str = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";

    fn word_xml(root: &str, item: Option<&str>, text: &str) -> String {
        let run = format!("<w:p><w:r><w:t>{text}</w:t></w:r></w:p>");
        let body = match item {
            Some(item) => format!(r#"<w:{item} w:id="1">{run}</w:{item}>"#),
            None => run,
        };
        format!(r#"{H}<w:{root} xmlns:w="{W}">{body}</w:{root}>"#)
    }

    fn word_with(parts: &[(&str, String)]) -> Vec<u8> {
        let mut all = vec![(
            "word/document.xml",
            word_xml("document", Some("body"), "zyqbody"),
        )];
        all.extend(parts.iter().cloned());
        let all: Vec<(&str, &str)> = all.iter().map(|(n, x)| (*n, x.as_str())).collect();
        zipped(&all)
    }

    #[test]
    fn word_reads_its_notes_comments_headers_and_footers() {
        let bytes = word_with(&[
            (
                "word/footnotes.xml",
                word_xml("footnotes", Some("footnote"), "zyqfootnote"),
            ),
            (
                "word/endnotes.xml",
                word_xml("endnotes", Some("endnote"), "zyqendnote"),
            ),
            (
                "word/comments.xml",
                word_xml("comments", Some("comment"), "zyqcomment"),
            ),
            ("word/header1.xml", word_xml("hdr", None, "zyqheader")),
            ("word/header2.xml", word_xml("hdr", None, "zyqsecondheader")),
            ("word/footer1.xml", word_xml("ftr", None, "zyqfooter")),
            ("word/Footer2.xml", word_xml("ftr", None, "zyqcasedfooter")),
            ("word/media/header9.xml", word_xml("hdr", None, "zyqmedia")),
            (
                "word/_rels/header1.xml.rels",
                word_xml("hdr", None, "zyqrels"),
            ),
            (
                "word/settings.xml",
                word_xml("settings", None, "zyqsettings"),
            ),
        ]);
        for ext in ["docx", "docm", "dotx", "dotm", "DOCX"] {
            let words = text(ext.as_bytes(), bytes.clone()).unwrap();
            for token in [
                "zyqbody",
                "zyqfootnote",
                "zyqendnote",
                "zyqcomment",
                "zyqheader",
                "zyqsecondheader",
                "zyqfooter",
                "zyqcasedfooter",
            ] {
                assert!(words.contains(token), "{ext} {token}: {words:?}");
            }
            for token in ["zyqmedia", "zyqrels", "zyqsettings"] {
                assert!(!words.contains(token), "{ext} {token}: {words:?}");
            }
        }
        let body = text(b"docx", word_with(&[])).unwrap();
        assert_eq!(body, "zyqbody\n");
        assert_eq!(
            text(b"docx", zipped(&[("word/footnotes.xml", "<w:t>zyq</w:t>")])),
            None
        );
        let odt = zipped(&[
            (
                "content.xml",
                r#"<office:document-content><text:p>zyqodtbody</text:p></office:document-content>"#,
            ),
            (
                "word/footnotes.xml",
                &word_xml("footnotes", Some("footnote"), "zyqfootnote"),
            ),
        ]);
        assert_eq!(text(b"odt", odt).unwrap(), "zyqodtbody\n");
    }

    #[test]
    fn a_word_footnote_is_found_by_search_content() {
        let tree = TempTree::new("rich-word-parts");
        let footnote = word_xml("footnotes", Some("footnote"), "zyqcitation 12");
        let header = word_xml("hdr", None, "zyqclient name");
        put(
            &tree,
            "contract.docx",
            &word_with(&[("word/footnotes.xml", footnote)]),
        );
        put(
            &tree,
            "letter.dotm",
            &word_with(&[("word/header1.xml", header)]),
        );
        put(&tree, "plain.docx", &docx("zyqother words"));
        let (engine, _listener, rx) = start_with(text_config(&tree), None);
        assert_eq!(texts(&engine, &rx, "text:zyqcitation"), ["contract.docx"]);
        assert_eq!(texts(&engine, &rx, "text:zyqclient"), ["letter.dotm"]);
        assert_eq!(texts(&engine, &rx, "text:zyqother"), ["plain.docx"]);
        assert_eq!(texts(&engine, &rx, "text:zyqbody").len(), 2);
    }

    #[test]
    fn word_parts_share_one_package_budget() {
        let bytes = word_with(&[("word/header1.xml", word_xml("hdr", None, "zyqheader"))]);
        let mut zip = zip::ZipArchive::new(Cursor::new(&bytes[..])).unwrap();
        let mut left = 40;
        let body = zip_part(&mut zip, "word/document.xml", &mut left).unwrap();
        assert_eq!((body.len(), left), (40, 0));
        assert_eq!(
            zip_part(&mut zip, "word/header1.xml", &mut left),
            Some(Vec::new())
        );
        assert_eq!(zip_part(&mut zip, "word/missing.xml", &mut left), None);
        let mut left = OFFICE_PACKAGE;
        let header = zip_part(&mut zip, "word/header1.xml", &mut left).unwrap();
        assert_eq!(left, OFFICE_PACKAGE - header.len() as u64);
    }

    #[test]
    fn sheets_and_slides_are_found_by_their_text() {
        let tree = TempTree::new("rich-office");
        put(
            &tree,
            "book.xlsx",
            &xlsx(&["zyqshared cell".to_owned()], 1, "zyqinline cell"),
        );
        put(&tree, "deck.pptx", &pptx("zyqslide words"));
        let (engine, _listener, rx) = start_with(text_config(&tree), None);
        assert_eq!(texts(&engine, &rx, "text:zyqshared"), ["book.xlsx"]);
        assert_eq!(texts(&engine, &rx, "text:zyqinline"), ["book.xlsx"]);
        assert_eq!(texts(&engine, &rx, "text:zyqslide"), ["deck.pptx"]);
    }

    fn pptx_parts(parts: &[(&str, String)], pictures: bool) -> Vec<u8> {
        let original = pptx("zyqfirst");
        let mut archive = zip::ZipArchive::new(Cursor::new(original)).unwrap();
        let mut writer = zip::ZipWriter::new(Cursor::new(Vec::new()));
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);
        for i in 0..archive.len() {
            let entry = archive.by_index(i).unwrap();
            if !parts.iter().any(|(name, _)| *name == entry.name().unwrap()) {
                writer.raw_copy_file(entry).unwrap();
            }
        }
        for (name, value) in parts {
            writer.start_file(*name, options).unwrap();
            writer.write_all(value.as_bytes()).unwrap();
        }
        if pictures {
            let zeros = [0; 64 << 10];
            for power in (10..=27).rev() {
                writer
                    .start_file(format!("ppt/media/image{power}.png"), options)
                    .unwrap();
                let mut left = 1usize << power;
                while left > 0 {
                    let count = left.min(zeros.len());
                    writer.write_all(&zeros[..count]).unwrap();
                    left -= count;
                }
            }
        }
        writer.finish().unwrap().into_inner()
    }

    fn pptx_verdict(bytes: &[u8], term: &str) -> crate::text::search::Verdict {
        use crate::text::{Terms, search};
        let tree = TempTree::new("rich-pptx");
        let path = PathBuf::from(tree.real()).join("deck.pptx");
        fs::write(&path, bytes).unwrap();
        search::holds(
            &path,
            bytes.len() as u64,
            &Terms {
                terms: vec![(term.to_owned(), None)],
                all: true,
            },
            &mut || true,
            || Some(()),
        )
        .unwrap()
    }

    #[test]
    fn pictures_cannot_spend_the_last_slides_text_budget() {
        let original = pptx("zyqlast");
        let mut archive = zip::ZipArchive::new(Cursor::new(original)).unwrap();
        let mut slide = String::new();
        archive
            .by_name("ppt/slides/slide1.xml")
            .unwrap()
            .read_to_string(&mut slide)
            .unwrap();
        slide = slide.replace("zyqlast", &format!("zyqlast {}", "padding ".repeat(2048)));
        let mut presentation = String::new();
        archive
            .by_name("ppt/presentation.xml")
            .unwrap()
            .read_to_string(&mut presentation)
            .unwrap();
        presentation = presentation.replace(
            "</p:sldIdLst>",
            r#"<p:sldId id="257" r:id="rId11"/></p:sldIdLst>"#,
        );
        let images: Vec<_> = (10..=27)
            .rev()
            .map(|p| (format!("image{p}"), format!("../media/image{p}.png")))
            .collect();
        let image_rels: Vec<_> = images
            .iter()
            .map(|(id, target)| (id.as_str(), "image", target.as_str()))
            .collect();
        let bytes = pptx_parts(
            &[
                ("ppt/presentation.xml", presentation),
                (
                    "ppt/_rels/presentation.xml.rels",
                    rels(&[
                        ("rId10", "slide", "slides/slide1.xml"),
                        ("rId11", "slide", "slides/slide2.xml"),
                    ]),
                ),
                ("ppt/slides/_rels/slide1.xml.rels", rels(&image_rels)),
                ("ppt/slides/slide2.xml", slide),
            ],
            true,
        );
        assert_eq!(
            pptx_verdict(&bytes, "zyqlast"),
            crate::text::search::Verdict::Holds
        );
    }

    #[test]
    fn powerpoints_notes_are_searchable() {
        let notes = format!(
            r#"{H}<p:notes xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><p:cSld><p:spTree><p:sp><p:nvSpPr><p:cNvPr id="2" name="Notes"/><p:cNvSpPr/><p:nvPr><p:ph type="body"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>zyqnote</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:notes>"#
        );
        let bytes = pptx_parts(
            &[
                (
                    "ppt/slides/_rels/slide1.xml.rels",
                    rels(&[
                        ("notes", "notesSlide", "../notesSlides/notesSlide1.xml"),
                        ("link", "hyperlink", "#slide1"),
                    ]),
                ),
                ("ppt/notesSlides/notesSlide1.xml", notes),
            ],
            false,
        );
        assert_eq!(
            pptx_verdict(&bytes, "zyqnote"),
            crate::text::search::Verdict::Holds
        );
    }

    #[test]
    fn powerpoint_slide_order_runs_and_entities_survive() {
        let bytes = pptx_parts(&[
            ("ppt/presentation.xml", format!(r#"{H}<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="{RT}"><p:sldIdLst><p:sldId id="257" r:id="second"/><p:sldId id="256" r:id="first"/></p:sldIdLst></p:presentation>"#)),
            ("ppt/_rels/presentation.xml.rels", rels(&[("first", "slide", "/ppt/slides/slide1.xml"), ("second", "slide", "slides/../slides/slide2.xml")])),
            ("ppt/slides/slide2.xml", r#"<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>zyqsecond &amp; &#xE9;</a:t></a:r><a:r><a:t><![CDATA[<run>]]></a:t></a:r></a:p><a:p><a:r><a:t>zyqparagraph</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>"#.into()),
        ], false);
        let words = text(b"pptx", bytes).unwrap();
        assert!(
            words.contains("zyqsecond & é<run>\nzyqparagraph"),
            "{words}"
        );
        assert!(words.find("zyqsecond").unwrap() < words.find("zyqfirst").unwrap());
    }

    #[test]
    fn powerpoint_related_text_survives_without_media() {
        let original = pptx("zyqfirst");
        let mut zip = zip::ZipArchive::new(Cursor::new(original)).unwrap();
        let mut slide = String::new();
        zip.by_name("ppt/slides/slide1.xml")
            .unwrap()
            .read_to_string(&mut slide)
            .unwrap();
        slide = slide.replace("</p:spTree>", r#"<p:pic><p:nvPicPr><p:cNvPr id="3" name="Picture" descr="zyqdescription"/></p:nvPicPr></p:pic></p:spTree>"#);
        let layout = r#"<p:sldLayout xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>zyqlayout</a:t></a:r></a:p></p:txBody></p:sp><p:sp><p:nvSpPr><p:nvPr><p:ph/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>zyqprompt</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sldLayout>"#;
        let parts = [
            ("ppt/slides/slide1.xml", slide),
            ("ppt/slides/_rels/slide1.xml.rels", rels(&[("layout", "slideLayout", "../slideLayouts/slideLayout1.xml"), ("chart", "chart", "../charts/chart1.xml"), ("diagram", "diagramData", "../diagrams/data1.xml"), ("comment", "comments", "../comments/comment1.xml"), ("image", "chart", "../media/image.xml")])),
            ("ppt/slideLayouts/slideLayout1.xml", layout.into()),
            ("ppt/charts/chart1.xml", r#"<c:chart xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart"><c:ser><c:tx><c:v>zyqchart</c:v></c:tx></c:ser></c:chart>"#.into()),
            ("ppt/diagrams/data1.xml", r#"<dgm:dataModel xmlns:dgm="http://schemas.openxmlformats.org/drawingml/2006/diagram" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><dgm:t><a:p><a:r><a:t>zyqdiagram</a:t></a:r></a:p></dgm:t></dgm:dataModel>"#.into()),
            ("ppt/comments/comment1.xml", r#"<p:cmLst xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cm><p:text>zyqcomment</p:text></p:cm></p:cmLst>"#.into()),
            ("ppt/media/image.xml", "<a:t>zyqmedia</a:t>".into()),
        ];
        let words = text(b"pptx", pptx_parts(&parts, false)).unwrap();
        for term in [
            "zyqfirst",
            "zyqdescription",
            "zyqlayout",
            "zyqchart",
            "zyqdiagram",
            "zyqcomment",
        ] {
            assert!(words.contains(term), "{term}: {words}");
        }
        assert!(!words.contains("zyqprompt"));
        assert!(!words.contains("zyqmedia"));
        let mut hidden = parts;
        hidden[0].1 = hidden[0]
            .1
            .replace("<p:sld ", r#"<p:sld showMasterSp="0" "#);
        assert!(
            !text(b"pptx", pptx_parts(&hidden, false))
                .unwrap()
                .contains("zyqlayout")
        );
    }

    #[test]
    fn a_missing_slide_link_does_not_hide_healthy_slides() {
        let bytes = pptx_parts(
            &[(
                "ppt/presentation.xml",
                format!(
                    r#"{H}<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="{RT}"><p:sldIdLst><p:sldId id="257" r:id="missing"/><p:sldId id="256" r:id="rId10"/></p:sldIdLst></p:presentation>"#
                ),
            )],
            false,
        );
        assert_eq!(
            pptx_verdict(&bytes, "zyqfirst"),
            crate::text::search::Verdict::Holds
        );
    }

    #[test]
    fn duplicate_powerpoint_zip_entries_are_rejected() {
        let mut bytes = pptx("zyqduplicate");
        let end = bytes.windows(4).rposition(|b| b == b"PK\x05\x06").unwrap();
        let directory = u32::from_le_bytes(bytes[end + 16..end + 20].try_into().unwrap()) as usize;
        let record_size = 46
            + [28, 30, 32]
                .into_iter()
                .map(|offset| {
                    u16::from_le_bytes(
                        bytes[directory + offset..directory + offset + 2]
                            .try_into()
                            .unwrap(),
                    ) as usize
                })
                .sum::<usize>();
        let record = bytes[directory..directory + record_size].to_vec();
        let count = u16::from_le_bytes(bytes[end + 10..end + 12].try_into().unwrap()) + 1;
        let size =
            u32::from_le_bytes(bytes[end + 12..end + 16].try_into().unwrap()) + record_size as u32;
        bytes.splice(end..end, record);
        let end = end + record_size;
        bytes[end + 8..end + 10].copy_from_slice(&count.to_le_bytes());
        bytes[end + 10..end + 12].copy_from_slice(&count.to_le_bytes());
        bytes[end + 12..end + 16].copy_from_slice(&size.to_le_bytes());
        assert!(text(b"pptx", bytes).is_none());
    }

    #[test]
    fn a_damaged_powerpoint_keeps_the_lacks_verdict() {
        let mut bytes = pptx("zyqdamage");
        bytes.truncate(bytes.len() / 2);
        assert_eq!(
            pptx_verdict(&bytes, "zyqdamage"),
            crate::text::search::Verdict::Lacks
        );
    }

    #[test]
    fn office_variants_are_found_by_their_text() {
        use crate::text::Terms;
        use crate::text::search::{self, Verdict};

        let tree = TempTree::new("rich-variants");
        let terms = Terms {
            terms: vec![("zyqmacro".to_owned(), None)],
            all: true,
        };
        for (extensions, bytes) in [
            (&["docm", "dotx", "dotm"][..], docx("zyqmacro")),
            (&["xlsm", "xltx", "xltm"][..], xlsx(&[], 0, "zyqmacro")),
            (&["pptm", "potx", "ppsx", "ppsm"][..], pptx("zyqmacro")),
            (
                &["ods", "odp", "ott", "ots", "otp"][..],
                zipped(&[(
                    "content.xml",
                    "<office:document><text:p>zyqmacro</text:p></office:document>",
                )]),
            ),
        ] {
            for extension in extensions {
                for extension in [extension.to_string(), extension.to_ascii_uppercase()] {
                    let path = PathBuf::from(tree.real()).join(format!("file.{extension}"));
                    fs::write(&path, &bytes).unwrap();
                    assert_eq!(
                        search::holds(&path, bytes.len() as u64, &terms, &mut || true, || Some(())),
                        Ok(Verdict::Holds),
                        "{extension}"
                    );
                }
            }
        }
        for (extension, format) in [
            (b"dot", DocumentFormat::Doc),
            (b"xlt", DocumentFormat::Xls),
            (b"pot", DocumentFormat::Ppt),
            (b"pps", DocumentFormat::Ppt),
        ] {
            assert!(matches!(kind(extension), Some(Kind::Office(actual)) if actual == format));
        }
    }

    #[test]
    fn a_legacy_office_name_reaches_office_oxide() {
        let dir = scratch("legacy");
        let doc = textutil("doc", "zyqlegacy words", &dir.0);
        let tree = TempTree::new("rich-legacy");
        put(&tree, "sheet.xls", &doc);
        put(&tree, "slides.ppt", &doc);
        put(&tree, "sheet.xlsb", &doc);
        let (engine, _listener, rx) = start_with(text_config(&tree), None);
        assert_eq!(
            texts(&engine, &rx, "text:zyqlegacy"),
            ["sheet.xls", "slides.ppt"]
        );
    }

    #[test]
    fn a_cut_office_text_drops_the_budget_line() {
        let shared: Vec<String> = (0..160)
            .map(|i| {
                let head = if i == 0 { "zyqfirst phrase " } else { "" };
                format!("{head}{}", "lorem ipsum ".repeat((32 << 10) / 12))
            })
            .collect();
        let bytes = xlsx(&shared, 8_500, "zyqlast phrase");
        office_limits();
        let raw = Document::from_reader(Cursor::new(bytes.clone()), DocumentFormat::Xlsx)
            .unwrap()
            .plain_text();
        let cut = raw.contains(CUT_HEAD) && raw.contains("budget");
        drop(raw);
        assert!(cut, "the fixture is never cut");
        let read = text(b"xlsx", bytes.clone()).unwrap();
        assert!(read.contains("zyqfirst phrase"));
        assert!(!read.contains("truncated") && !read.contains("budget"));
        drop(read);
        let tree = TempTree::new("rich-cut");
        put(&tree, "big.xlsx", &bytes);
        let (engine, _listener, rx) = start_with(text_config(&tree), None);
        assert_eq!(texts(&engine, &rx, "text:zyqfirst"), ["big.xlsx"]);
        assert!(texts(&engine, &rx, "anytext:budget anytext:truncated").is_empty());
    }

    #[test]
    fn a_panicking_reader_is_not_text() {
        let mut boom = PANIC.to_vec();
        boom.extend(pdf(&[page("zyqboom")]));
        assert_eq!(text(b"pdf", boom.clone()), None);
        let tree = TempTree::new("rich-panic");
        put(&tree, "boom.pdf", &boom);
        put(&tree, "fine.pdf", &pdf(&[page("zyqfine zyqboom")]));
        let (engine, _listener, rx) = start_with(text_config(&tree), None);
        assert_eq!(texts(&engine, &rx, "text:zyqboom"), ["fine.pdf"]);
        assert_eq!(texts(&engine, &rx, "text:zyqfine"), ["fine.pdf"]);
    }

    #[test]
    fn a_reader_thread_has_a_16_mib_stack() {
        let pool = Pool::text(1).unwrap();
        let size = pool.install(|| unsafe { libc::pthread_get_stacksize_np(libc::pthread_self()) });
        assert!(size >= TEXT_STACK, "{size} bytes");
    }

    #[test]
    fn damaged_copies_never_escape() {
        let dir = scratch("damaged");
        let fixtures: Vec<(&[u8], Vec<u8>)> = vec![
            (b"pdf", pdf(&[page("zyqdamage words"), page("second page")])),
            (b"docx", docx("zyqdamage words")),
            (b"odt", textutil("odt", "zyqdamage words", &dir.0)),
            (b"doc", textutil("doc", "zyqdamage words", &dir.0)),
            (b"xlsx", xlsx(&["zyqdamage words".to_owned()], 3, "inline")),
            (b"pptx", pptx("zyqdamage words")),
        ];
        let done = std::thread::Builder::new()
            .stack_size(TEXT_STACK)
            .spawn(move || {
                let mut rng = Rng(20261019);
                let mut calls = 0;
                for (ext, good) in &fixtures {
                    assert!(
                        text(ext, good.clone()).is_some_and(|t| t.contains("zyqdamage")),
                        "{} reads nothing undamaged",
                        String::from_utf8_lossy(ext)
                    );
                    for _ in 0..300 {
                        let _ = text(ext, damaged(good, &mut rng));
                        calls += 1;
                    }
                }
                calls
            })
            .unwrap()
            .join()
            .unwrap();
        assert_eq!(done, 1800);
    }

    fn damaged(good: &[u8], rng: &mut Rng) -> Vec<u8> {
        let mut b = good.to_vec();
        match rng.below(4) {
            0 | 1 => {
                for _ in 0..1 + rng.below(16) {
                    let at = rng.below(b.len());
                    b[at] = rng.next() as u8;
                }
            }
            2 => {
                let at = rng.below(b.len());
                let end = (at + 1 + rng.below(256)).min(b.len());
                b[at..end].fill(0);
            }
            _ => b.truncate(rng.below(b.len())),
        }
        b
    }

    #[test]
    fn a_pdf_page_over_the_limit_is_skipped() {
        let mut big = b"BT /F1 12 Tf 50 700 Td (zyqbigpage) Tj ".to_vec();
        while big.len() <= 9 << 20 {
            big.extend_from_slice(b"(padding words) Tj ");
        }
        big.extend_from_slice(b"ET");
        let read = text(b"pdf", pdf(&[big, page("zyqsmallpage")])).unwrap();
        assert!(read.contains("zyqsmallpage"));
        assert!(!read.contains("zyqbigpage"));
    }

    #[test]
    fn a_fan_out_sheet_stops_at_its_budget() {
        let budget = office_oxide::limits::DEFAULT_MAX_TEXT_CHARS;
        let shared = format!("zyqfan {}", "x".repeat((32 << 10) - 7));
        let rows = budget / shared.len() + 1;
        assert!(rows * shared.len() > budget);
        let bytes = xlsx(&[shared], rows, "zyqfanlast");
        office_limits();
        let raw = Document::from_reader(Cursor::new(bytes.clone()), DocumentFormat::Xlsx)
            .unwrap()
            .plain_text();
        assert!(raw.contains(CUT_HEAD));
        let chars = raw.chars().count();
        drop(raw);
        assert!(chars <= budget + (128 << 10), "{chars} characters");
        let read = text(b"xlsx", bytes).unwrap();
        assert!(read.contains("zyqfan "));
        assert!(!read.contains("zyqfanlast"));
    }

    #[test]
    fn a_document_over_32_mebibytes_is_read() {
        let tree = TempTree::new("rich-big");
        let path = Path::new(&tree.real()).join("big.docx");
        let small = docx("zyqbigdoc words");
        let mut parts = zip::ZipArchive::new(Cursor::new(&small[..])).unwrap();
        let mut z = zip::ZipWriter::new(Cursor::new(Vec::new()));
        for i in 0..parts.len() {
            z.raw_copy_file(parts.by_index(i).unwrap()).unwrap();
        }
        let stored = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Stored);
        z.start_file("word/media/image1.png", stored).unwrap();
        z.write_all(&vec![0x5A; 40 << 20]).unwrap();
        fs::write(&path, z.finish().unwrap().into_inner()).unwrap();
        assert!(fs::metadata(&path).unwrap().len() > 40 << 20);
        let (read, peak) = crate::alloc::count::peak_of(|| scope::tests::read(&path));
        println!("40 MiB DOCX read: peak {} MiB", peak >> 20);
        assert!(read.is_some_and(|t| t.contains("zyqbigdoc")));
    }

    #[test]
    fn an_empty_run_opens_nothing() {
        let doc = format!(
            r#"{H}<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t/></w:r><w:r><w:instrText>zyqfield</w:instrText></w:r><w:r><w:t>zyqreal</w:t></w:r></w:p></w:body></w:document>"#
        );
        let read = text(b"docx", zipped(&[("word/document.xml", &doc)])).unwrap();
        assert!(read.contains("zyqreal"));
        assert!(!read.contains("zyqfield"), "{read:?}");
    }

    #[test]
    fn extracted_text_past_4_mib_is_kept() {
        let filler = "lorem ipsum ".repeat((5 << 20) / 12);
        let read = text(b"docx", docx(&format!("zyqbefore {filler} zyqafter"))).unwrap();
        assert!(read.len() > 5 << 20);
        assert!(read.contains("zyqbefore"));
        assert!(read.contains("zyqafter"));
    }

    #[test]
    fn an_object_bomb_stops_at_the_cap() {
        let mut doc = lopdf::Document::load_mem(&pdf(&[page("zyqbomb")])).unwrap();
        for _ in 0..16 {
            doc.add_object(Object::Array(vec![Object::Integer(0); 100_000]));
        }
        let options = lopdf::SaveOptions::builder()
            .use_object_streams(true)
            .use_xref_streams(true)
            .max_objects_per_stream(1)
            .build();
        let mut bytes = Vec::new();
        doc.save_with_options(&mut bytes, options).unwrap();
        drop(doc);
        assert!(bytes.windows(7).filter(|w| w == b"/ObjStm").count() >= 16);
        let mut found = false;
        let (read, peak) = crate::alloc::count::peak_of(|| {
            super::pdf_capped(&bytes, 200_000, &mut |t| {
                found |= t.contains("zyqbomb");
                false
            })
        });
        assert!(peak < 64 << 20, "{peak} bytes");
        assert!(read && found);
        assert!(LOADED.get().0 > 200_000, "the cap never cut the load");
    }

    #[test]
    #[ignore = "reads the PDFs under WHEREVER_PDF_CORPUS"]
    fn pdf_object_peak() {
        let corpus = std::env::var_os("WHEREVER_PDF_CORPUS").expect("WHEREVER_PDF_CORPUS is unset");
        let (read, high, cut, bytes_read, spent, slowest) = std::thread::Builder::new()
            .stack_size(TEXT_STACK)
            .spawn(move || {
                let (mut dirs, mut read, mut high, mut cut) =
                    (vec![PathBuf::from(corpus)], 0, 0, 0);
                let (mut bytes_read, mut spent) = (0u64, std::time::Duration::ZERO);
                let mut slowest = (std::time::Duration::ZERO, PathBuf::new());
                while let Some(dir) = dirs.pop() {
                    let Ok(entries) = fs::read_dir(&dir) else {
                        continue;
                    };
                    for entry in entries.flatten() {
                        let path = entry.path();
                        if entry.file_type().is_ok_and(|t| t.is_dir()) {
                            dirs.push(path);
                            continue;
                        }
                        if !path
                            .extension()
                            .is_some_and(|e| e.eq_ignore_ascii_case("pdf"))
                        {
                            continue;
                        }
                        let Ok(bytes) = fs::read(&path) else { continue };
                        bytes_read += bytes.len() as u64;
                        let began = std::time::Instant::now();
                        let _ = text(b"pdf", bytes);
                        let took = began.elapsed();
                        spent += took;
                        if took > slowest.0 {
                            slowest = (took, path.clone());
                        }
                        let (count, cap, _) = LOADED.get();
                        let over = count > cap;
                        println!(
                            "{count:>12} {} {}",
                            if over { "cut " } else { "kept" },
                            path.display()
                        );
                        (read, high, cut) = (read + 1, high.max(count), cut + usize::from(over));
                    }
                }
                (read, high, cut, bytes_read, spent, slowest)
            })
            .unwrap()
            .join()
            .unwrap();
        println!("{read} PDFs, highest {high} objects, {cut} cut at PDF_OBJECTS {PDF_OBJECTS}");
        let mib = bytes_read as f64 / (1 << 20) as f64;
        let ms = spent.as_secs_f64() * 1000.0;
        println!(
            "pdf speed: {read} PDFs, {mib:.1} MiB in {ms:.0} ms, {:.2} MiB/s, slowest {:.0} ms {}",
            mib / spent.as_secs_f64().max(f64::EPSILON),
            slowest.0.as_secs_f64() * 1000.0,
            slowest.1.display()
        );
        assert!(read > 0, "no PDF read");
    }

    #[test]
    fn each_pdf_page_walks_a_tree_of_one() {
        let mut pages = vec![Vec::new(); 4000];
        pages[0] = page("zyqfirst");
        pages[3999] = page("zyqlast");
        let bytes = pdf(&pages);
        WALKED.set(0);
        let read = text(b"pdf", bytes.clone()).unwrap();
        assert_eq!(WALKED.get(), 4000);
        assert!(read.contains("zyqfirst") && read.contains("zyqlast"));
        WALKED.set(0);
        assert!(super::pdf(&bytes, &mut |t| t.contains("zyqfirst")));
        assert_eq!(WALKED.get(), 1);
    }

    #[test]
    fn pdf_pages_read_as_they_did_one_tree_walk_each() {
        for n in [10, 1500] {
            let pages: Vec<_> = (0..n).map(|i| page(&format!("zyqpage{i} words"))).collect();
            let bytes = pdf(&pages);
            let doc = lopdf::Document::load_mem(&bytes).unwrap();
            let mut before = String::new();
            for &number in doc.get_pages().keys() {
                before.push_str(&doc.extract_text_with_limit(&[number], PDF_PAGE).unwrap());
                before.push('\n');
            }
            assert!(before.contains(&format!("zyqpage{} words", n - 1)));
            assert_eq!(text(b"pdf", bytes), Some(unligate(&before)), "{n} pages");
        }
    }

    #[test]
    fn a_bad_docx_tag_keeps_the_words_after_it() {
        let doc = format!(
            r#"{H}<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>zyqfirst</w:t></w:r></w:p><w:p></w:x><w:p><w:r><w:t>zyqafter</w:t></w:r></w:p></w:body></w:document>"#
        );
        let read = text(b"docx", zipped(&[("word/document.xml", &doc)])).unwrap();
        assert!(
            read.contains("zyqfirst") && read.contains("zyqafter"),
            "{read:?}"
        );
        assert_eq!(text(b"docx", zipped(&[("word/document.xml", "")])), None);
    }

    fn rtf(head: &str, body: &str) -> Vec<u8> {
        format!(r"{{\rtf1\ansi{head}{{\colortbl;\red0\green0\blue0;}}{body}\par}}").into_bytes()
    }

    #[test]
    fn rtf_reads_its_text_not_its_markup() {
        let doc = rtf(
            r"\deff0{\fonttbl{\f0\fnil\fcharset0 Helvetica;}}",
            r"\f0\fs24 zyqbody \b words\b0\par {\*\generator zyqgen;}{\pict\wmetafile8 zyqpict}",
        );
        let read = text(b"rtf", doc.clone()).unwrap();
        assert_eq!(read.trim(), "zyqbody words");
        let tree = TempTree::new("rich-rtf");
        put(&tree, "doc.rtf", &doc);
        put(&tree, "other.rtf", &rtf("", "basalt"));
        let (engine, _listener, rx) = start_with(text_config(&tree), None);
        assert_eq!(texts(&engine, &rx, "text:zyqbody"), ["doc.rtf"]);
        for markup in ["fonttbl", "Helvetica", "colortbl", "zyqgen", "zyqpict"] {
            assert!(
                texts(&engine, &rx, &format!("text:{markup}")).is_empty(),
                "{markup}"
            );
        }
        assert_eq!(text(b"txt", doc), None);
        assert_eq!(text(b"rtf", b"plain zyqwords".to_vec()), None);
    }

    #[test]
    fn a_japanese_rtf_decodes_by_its_code_page() {
        let doc = rtf(
            r"\ansicpg932\deff0{\fonttbl{\f0 MS Mincho;}}",
            r"\f0 zyqjp \'93\'8c\'8b\'9e",
        );
        assert!(text(b"rtf", doc.clone()).unwrap().contains("zyqjp 東京"));
        let tree = TempTree::new("rich-rtf-jp");
        put(&tree, "jp.rtf", &doc);
        put(&tree, "latin.rtf", &rtf("", r"zyqjp \'93\'8c\'8b\'9e"));
        let (engine, _listener, rx) = start_with(text_config(&tree), None);
        assert_eq!(texts(&engine, &rx, "text:東京"), ["jp.rtf"]);
    }

    #[test]
    fn a_czech_rtf_decodes_by_its_font_charset() {
        let doc = rtf(
            r"\ansicpg1252\deff0{\fonttbl{\f0\fcharset238 Arial;}{\f1\fcharset0 Arial;}}",
            r"\f0 zyq\'e8aj \f1 zyq\'e8aj",
        );
        let read = text(b"rtf", doc.clone()).unwrap();
        assert!(
            read.contains("zyqčaj ") && read.contains("zyqèaj"),
            "{read:?}"
        );
        let tree = TempTree::new("rich-rtf-cz");
        put(&tree, "cz.rtf", &doc);
        let (engine, _listener, rx) = start_with(text_config(&tree), None);
        assert_eq!(texts(&engine, &rx, "text:zyqčaj"), ["cz.rtf"]);
    }

    #[test]
    fn unicode_escapes_skip_their_fallback() {
        let read = |body: &str| text(b"rtf", rtf("", body)).unwrap();
        let one = read(r"\uc1\u9800? zyqa");
        assert_eq!(one.trim(), "♈ zyqa");
        let two = read(r"\uc2\u9800\'3f\'3f zyqb");
        assert_eq!(two.trim(), "♈ zyqb");
        let none = read(r"\uc0\u9800 zyqc");
        assert_eq!(none.trim(), "♈zyqc");
        let pair = read(r"\uc1\u-10179?\u-8704? zyqd");
        assert_eq!(pair.trim(), "😀 zyqd");
    }

    #[test]
    fn a_hostile_rtf_ends() {
        let mut deep = b"{\\rtf1 zyqdeep".to_vec();
        deep.extend(std::iter::repeat_n(b'{', 1_000_000));
        deep.extend(std::iter::repeat_n(b'}', 1_100_000));
        deep.extend_from_slice(b" zyqafter");
        let read = text(b"rtf", deep).unwrap();
        assert!(read.contains("zyqdeep") && read.contains("zyqafter"));
        for tail in [
            r"\bin99999999999999999999 zyqlost".to_owned(),
            r"\bin5 12345zyqkept".to_owned(),
            r"\bin-7 zyqneg".to_owned(),
            r"\u-1 \u99999999999999999999 \u-99999999999999999999x".to_owned(),
            r"\uc99999999999999999999\u65 zyqa".to_owned(),
            r"\f99999999999999999999 \fcharset-5 zyqb\".to_owned(),
            r"zyqcut\'".to_owned(),
            r"zyqcut\'9".to_owned(),
            r"\'zz\'9z zyqhex".to_owned(),
        ] {
            let _ = text(b"rtf", format!(r"{{\rtf1 {tail}").into_bytes());
        }
        let kept = text(b"rtf", br"{\rtf1 \bin5 12345zyqkept}".to_vec()).unwrap();
        assert_eq!(kept.trim(), "zyqkept");
        let lost = text(
            b"rtf",
            br"{\rtf1 \bin99999999999999999999 zyqlost}".to_vec(),
        );
        assert!(lost.is_none_or(|t| !t.contains("zyqlost")));
        let cut = text(b"rtf", br"{\rtf1 zyqcut\'".to_vec()).unwrap();
        assert_eq!(cut.trim(), "zyqcut");
    }

    #[test]
    fn damaged_rtf_copies_never_escape() {
        let good = rtf(
            r"\ansicpg932\deff0{\fonttbl{\f0\fcharset128 MS Mincho;}{\f1\fcharset238 Arial;}}",
            r"\f0 zyqdamage \'93\'8c\uc1\u9800? words\par {\*\generator zyqgen;}\f1 \'e8 {\pict\bin4 abcd}\line end",
        );
        let done = std::thread::Builder::new()
            .stack_size(TEXT_STACK)
            .spawn(move || {
                assert!(text(b"rtf", good.clone()).is_some_and(|t| t.contains("zyqdamage 東")));
                let mut rng = Rng(20261019);
                for _ in 0..300 {
                    let _ = text(b"rtf", damaged(&good, &mut rng));
                }
                300
            })
            .unwrap()
            .join()
            .unwrap();
        assert_eq!(done, 300);
    }

    #[test]
    fn a_textutil_rtf_is_found() {
        let dir = scratch("rtf");
        let made = textutil("rtf", "zyqrtfmade words\nsecond zyqline", &dir.0);
        assert!(made.starts_with(b"{\\rtf"));
        let tree = TempTree::new("rich-textutil-rtf");
        put(&tree, "note.rtf", &made);
        let (engine, _listener, rx) = start_with(text_config(&tree), None);
        assert_eq!(texts(&engine, &rx, "text:zyqrtfmade"), ["note.rtf"]);
        assert_eq!(texts(&engine, &rx, "text:zyqline"), ["note.rtf"]);
        assert!(texts(&engine, &rx, "text:fonttbl").is_empty());
        assert!(texts(&engine, &rx, "text:Helvetica").is_empty());
    }
}
