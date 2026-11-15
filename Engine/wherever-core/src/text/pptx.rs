use std::collections::{HashMap, HashSet};
use std::io::{Cursor, Read};

use quick_xml::events::{BytesStart, Event};
use quick_xml::{Reader, XmlVersion};

use super::rich::{MAX_PART, OFFICE_PACKAGE};

type Relationships = HashMap<String, (String, String)>;

struct Package<'a> {
    zip: zip::ZipArchive<Cursor<&'a [u8]>>,
    left: u64,
    names: HashMap<String, String>,
}

impl<'a> Package<'a> {
    fn open(bytes: &'a [u8]) -> Option<Self> {
        let zip = zip::ZipArchive::new(Cursor::new(bytes)).ok()?;
        if zip.len() > office_oxide::limits::DEFAULT_MAX_PACKAGE_ENTRIES {
            return None;
        }
        let mut names = HashMap::new();
        for name in zip.file_names() {
            let name = name.ok()?;
            if names.insert(normalized(&name), name.into_owned()).is_some() {
                return None;
            }
        }
        Some(Self {
            zip,
            names,
            left: OFFICE_PACKAGE,
        })
    }

    fn part(&mut self, name: &str) -> Option<Vec<u8>> {
        let name = normalized(name);
        if !name.starts_with("ppt/") || name.starts_with("ppt/media/") {
            return None;
        }
        let file = self
            .zip
            .by_name_with_options(
                self.names.get(&name)?,
                zip::read::ZipReadOptions::new().enforce_header_consistency(true),
            )
            .ok()?;
        let limit = MAX_PART.min(self.left);
        if file.size() > limit {
            return None;
        }
        let mut bytes = Vec::new();
        let result = file.take(limit + 1).read_to_end(&mut bytes);
        let size = bytes.len() as u64;
        if size > limit {
            self.left = 0;
            return None;
        }
        self.left -= size;
        result.ok()?;
        Some(bytes)
    }

    fn relationships(&mut self, name: &str) -> Option<Relationships> {
        let (folder, file) = name.rsplit_once('/')?;
        let name = format!("{folder}/_rels/{file}.rels");
        if !self.names.contains_key(&normalized(&name)) {
            return Some(HashMap::new());
        }
        let bytes = self.part(&name)?;
        let mut rels = HashMap::new();
        xml(&bytes, |event| {
            if let Event::Start(e) | Event::Empty(e) = event
                && e.local_name().as_ref() == "Relationship"
                && attribute(&e, "TargetMode").as_deref() != Some("External")
            {
                let id = attribute(&e, "Id")?;
                let kind = attribute(&e, "Type")?;
                let Some(target) = target(folder, &attribute(&e, "Target")?) else {
                    return Some(());
                };
                if rels.insert(id, (kind, target)).is_some() {
                    return None;
                }
            }
            Some(())
        })?;
        Some(rels)
    }
}

pub(super) fn text(bytes: &[u8]) -> Option<String> {
    let mut package = Package::open(bytes)?;
    let presentation = package.part("ppt/presentation.xml")?;
    let rels = package.relationships("ppt/presentation.xml")?;
    let mut slides = Vec::new();
    xml(&presentation, |event| {
        if let Event::Start(e) | Event::Empty(e) = event
            && e.local_name().as_ref() == "sldId"
        {
            let id = e.attributes().find_map(|a| {
                let a = a.ok()?;
                (a.key.local_name().as_ref() == "id" && a.key.as_ref().contains(':')).then(
                    || {
                        a.normalized_value(XmlVersion::Implicit1_0)
                            .ok()
                            .map(|s| s.into_owned())
                    },
                )?
            });
            if let Some((kind, part)) = id.as_ref().and_then(|id| rels.get(id))
                && kind.ends_with("/slide")
            {
                slides.push(part.clone());
            }
        }
        Some(())
    })?;
    let mut authors = HashMap::new();
    for (kind, part) in rels.values() {
        if (kind.ends_with("/commentAuthors") || kind.ends_with("/authors"))
            && let Some(bytes) = package.part(part)
        {
            let _ = xml(&bytes, |event| {
                if let Event::Start(e) | Event::Empty(e) = event
                    && matches!(e.local_name().as_ref(), "cmAuthor" | "author")
                {
                    authors.insert(attribute(&e, "id")?, attribute(&e, "name")?);
                }
                Some(())
            });
        }
    }
    let mut out = String::new();
    let mut visited = HashSet::new();
    let mut read = false;
    for slide in slides {
        let mut parts = vec![("slide".to_owned(), slide)];
        while let Some((kind, part)) = parts.pop() {
            if !visited.insert(part.clone()) {
                continue;
            }
            let Some(bytes) = package.part(&part) else {
                continue;
            };
            let Some((words, show_master)) = runs(&bytes, &kind, &authors) else {
                continue;
            };
            read |= kind == "slide";
            out.push_str(&words);
            out.push('\n');
            for (kind, target) in package
                .relationships(&part)
                .unwrap_or_default()
                .into_values()
            {
                let kind = kind.rsplit('/').next()?;
                if matches!(kind, "notesSlide" | "comments" | "chart" | "diagramData")
                    || (show_master && matches!(kind, "slideLayout" | "slideMaster"))
                {
                    parts.push((kind.to_owned(), target));
                }
            }
        }
    }
    read.then_some(out)
}

fn target(folder: &str, target: &str) -> Option<String> {
    if target.contains(['\\', ':', '?', '#']) {
        return None;
    }
    let mut parts: Vec<_> = if target.starts_with('/') {
        Vec::new()
    } else {
        folder.split('/').collect()
    };
    for part in target.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                parts.pop()?;
            }
            _ => parts.push(part),
        }
    }
    Some(normalized(&parts.join("/")))
}

fn normalized(name: &str) -> String {
    name.trim_start_matches('/')
        .replace('\\', "/")
        .to_ascii_lowercase()
}

fn attribute(e: &BytesStart<'_>, name: &str) -> Option<String> {
    e.try_get_attribute(name)
        .ok()??
        .normalized_value(XmlVersion::Implicit1_0)
        .ok()
        .map(|s| s.into_owned())
}

fn xml(bytes: &[u8], mut visit: impl FnMut(Event<'_>) -> Option<()>) -> Option<()> {
    let mut reader = Reader::from_reader(bytes);
    let (mut depth, mut roots) = (0usize, 0);
    loop {
        let event = reader.read_event().ok()?;
        match &event {
            Event::Start(_) | Event::Empty(_) => {
                if depth == 0 {
                    roots += 1;
                }
                if matches!(event, Event::Start(_)) {
                    depth += 1;
                }
            }
            Event::End(_) => depth = depth.checked_sub(1)?,
            Event::Eof => return (depth == 0 && roots == 1).then_some(()),
            _ => {}
        }
        visit(event)?;
    }
}

fn runs(bytes: &[u8], kind: &str, authors: &HashMap<String, String>) -> Option<(String, bool)> {
    let inherited = matches!(kind, "slideLayout" | "slideMaster");
    let (mut out, mut in_run, mut picture, mut show_master) = (String::new(), false, false, true);
    let (mut shape, mut placeholder) = (None, false);
    xml(bytes, |event| {
        match event {
            Event::Start(ref e) | Event::Empty(ref e) => {
                let empty = matches!(event, Event::Empty(_));
                let name = e.local_name();
                match name.as_ref() {
                    "sld" | "sldLayout" => {
                        show_master =
                            !matches!(attribute(e, "showMasterSp").as_deref(), Some("0" | "false"))
                    }
                    "sp" if inherited => {
                        shape = Some(out.len());
                        placeholder = false;
                    }
                    "ph" if inherited => placeholder = true,
                    "pic" => picture = true,
                    "cNvPr" if picture && !inherited => {
                        if let Some(alt) = attribute(e, "descr") {
                            out.push_str(&alt);
                            out.push('\n');
                        }
                    }
                    "cm" | "reply" => {
                        if let Some(author) =
                            attribute(e, "authorId").and_then(|id| authors.get(&id))
                        {
                            out.push_str(author);
                            out.push('\n');
                        }
                    }
                    "t" | "text" | "v" => in_run = !empty && (!inherited || shape.is_some()),
                    "br" => out.push('\n'),
                    "tab" => out.push('\t'),
                    _ => {}
                }
            }
            Event::End(e) => match e.local_name().as_ref() {
                "t" => in_run = false,
                "text" | "v" => {
                    in_run = false;
                    out.push('\n');
                }
                "p" => out.push('\n'),
                "pic" => picture = false,
                "sp" if inherited => {
                    if let Some(start) = shape.take()
                        && placeholder
                    {
                        out.truncate(start);
                    }
                }
                _ => {}
            },
            Event::Text(t) if in_run => out.push_str(&t),
            Event::CData(t) if in_run => out.push_str(&t),
            Event::GeneralRef(g) if in_run => {
                if let Some(c) = g.resolve_char_ref().ok()? {
                    out.push(c);
                } else {
                    out.push_str(quick_xml::escape::resolve_predefined_entity(&g)?);
                }
            }
            _ => {}
        }
        Some(())
    })?;
    Some((out, show_master))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn failed_reads_still_spend_the_budget_and_media_is_never_opened() {
        let mut writer = zip::ZipWriter::new(Cursor::new(Vec::new()));
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Stored);
        for name in ["ppt/slides/slide.xml", "ppt/media/image.xml"] {
            writer.start_file(name, options).unwrap();
            writer.write_all(b"zyqbytes").unwrap();
        }
        let mut bytes = writer.finish().unwrap().into_inner();
        let mut package = Package::open(&bytes).unwrap();
        package.left = 8;
        assert!(package.part("ppt/media/image.xml").is_none());
        assert_eq!(package.left, 8);
        package.left = 7;
        assert!(package.part("ppt/slides/slide.xml").is_none());
        assert_eq!(package.left, 7);
        package.left = 8;
        assert_eq!(package.part("ppt/slides/slide.xml").unwrap(), b"zyqbytes");
        assert_eq!(package.left, 0);
        assert!(package.part("ppt/slides/slide.xml").is_none());
        drop(package);
        let central = bytes.windows(4).position(|b| b == b"PK\x01\x02").unwrap();
        for at in [22, central + 24] {
            bytes[at..at + 4].copy_from_slice(&((MAX_PART + 1) as u32).to_le_bytes());
        }
        let mut package = Package::open(&bytes).unwrap();
        assert!(package.part("ppt/slides/slide.xml").is_none());
        assert_eq!(package.left, OFFICE_PACKAGE);
        drop(package);
        for at in [22, central + 24] {
            bytes[at..at + 4].copy_from_slice(&8u32.to_le_bytes());
        }
        let at = bytes.windows(8).position(|b| b == b"zyqbytes").unwrap();
        bytes[at] = b'x';
        let mut package = Package::open(&bytes).unwrap();
        package.left = 8;
        assert!(package.part("ppt/slides/slide.xml").is_none());
        assert_eq!(package.left, 0);
    }

    #[test]
    fn the_zip_entry_count_has_a_hard_limit() {
        let mut writer = zip::ZipWriter::new(Cursor::new(Vec::new()));
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Stored);
        for i in 0..office_oxide::limits::DEFAULT_MAX_PACKAGE_ENTRIES {
            writer
                .start_file(format!("ppt/empty/{i}"), options)
                .unwrap();
        }
        let bytes = writer.finish().unwrap().into_inner();
        assert!(Package::open(&bytes).is_some());
        let mut writer = zip::ZipWriter::new_append(Cursor::new(bytes)).unwrap();
        writer.start_file("ppt/empty/extra", options).unwrap();
        let bytes = writer.finish().unwrap().into_inner();
        assert!(Package::open(&bytes).is_none());
    }
}
