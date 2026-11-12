use std::collections::{HashMap, HashSet, VecDeque};
use std::path::{Component, Path};

pub(super) fn name(raw: &str) -> Option<String> {
    if raw.contains('\0') {
        return None;
    }
    let mut parts = Vec::new();
    for c in Path::new(raw).components() {
        match c {
            Component::Normal(s) => parts.push(s.to_str()?),
            Component::CurDir => {}
            _ => return None,
        }
    }
    (!parts.is_empty()).then(|| parts.join("/"))
}

pub(super) fn target(name: &str, target: &str, links: &HashMap<String, String>) -> Option<String> {
    if target.starts_with('/') || target.contains('\0') {
        return None;
    }
    let mut parts: Vec<String> = name.rsplit_once('/').map_or(Vec::new(), |(p, _)| {
        p.split('/').map(str::to_owned).collect()
    });
    let mut queue: VecDeque<(String, bool)> =
        target.split('/').map(|s| (s.to_owned(), false)).collect();
    let mut seen = HashSet::new();
    while let Some((part, finish)) = queue.pop_front() {
        if finish {
            seen.remove(&part);
            continue;
        }
        match part.as_str() {
            "" | "." => continue,
            ".." => {
                parts.pop()?;
            }
            _ => {
                parts.push(part);
                let key = parts.join("/");
                if let Some(to) = links.get(&key) {
                    if !seen.insert(key.clone()) || to.starts_with('/') || to.contains('\0') {
                        return None;
                    }
                    parts.pop();
                    queue.push_front((key, true));
                    for next in to.split('/').rev() {
                        queue.push_front((next.into(), false));
                    }
                }
            }
        }
    }
    Some(parts.join("/"))
}
