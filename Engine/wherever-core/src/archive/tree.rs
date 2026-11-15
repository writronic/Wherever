use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use super::{Entry, Failure};
use crate::EngineKind;
use crate::crawl::{Attrs, Crawl, Listing, NONE};
use crate::index::Index;
use crate::live::{Found, Live};
use crate::query::{Hit, Scanned};

pub(super) struct Tree {
    pub live: Live,
    pub folders: HashMap<String, usize>,
}

impl Tree {
    pub fn build(
        entries: &mut Vec<Entry>,
        shown_as: &str,
        cancelled: &impl Fn() -> bool,
    ) -> Result<Self, Failure> {
        let mut dirs = HashMap::from([(String::new(), 0u32)]);
        let mut folder_attrs = HashMap::new();
        let mut listings = vec![Listing::default()];
        for e in entries
            .iter()
            .filter(|e| e.attrs.kind == EngineKind::Folder)
        {
            folder_attrs.insert(e.path.clone(), e.clone());
        }
        let mut virtuals = Vec::new();
        for e in entries.iter() {
            if cancelled() {
                return Err(Failure::Stopped);
            }
            let parts: Vec<_> = e.path.split('/').collect();
            let count = parts.len() - usize::from(e.attrs.kind != EngineKind::Folder);
            let mut parent = 0;
            let mut path = String::new();
            for part in &parts[..count] {
                if !path.is_empty() {
                    path.push('/');
                }
                path.push_str(part);
                let id = if let Some(id) = dirs.get(&path) {
                    *id
                } else {
                    let id = u32::try_from(listings.len())
                        .map_err(|_| super::ArchiveProblem::Damaged)?;
                    let known = folder_attrs.get(&path).cloned();
                    let listed = known.is_some();
                    let folder = known.unwrap_or_else(|| Entry {
                        path: path.clone(),
                        index: None,
                        attrs: Attrs {
                            kind: EngineKind::Folder,
                            size: 0,
                            mtime: 0,
                            created: 0,
                            opened: 0,
                            mount: false,
                            hidden: super::hidden(&path),
                        },
                        mode: 0o755,
                        target: None,
                        encrypted: false,
                        sized: true,
                        disk: None,
                    });
                    listings[parent as usize].push(part.as_bytes(), folder.attrs, id);
                    let mut listing = Listing::default();
                    listing.id = id;
                    listings.push(listing);
                    dirs.insert(path.clone(), id);
                    if !listed {
                        virtuals.push(folder);
                    }
                    id
                };
                parent = id;
            }
            if e.attrs.kind != EngineKind::Folder {
                listings[parent as usize].push(parts.last().unwrap().as_bytes(), e.attrs, NONE);
            }
        }
        entries.extend(virtuals);
        let index = Arc::new(
            Index::build_until(
                Crawl {
                    listings,
                    failed: Vec::new(),
                },
                PathBuf::from(shown_as),
                &[],
                0,
                0,
                cancelled,
            )
            .map_err(|e| match e {
                crate::EngineError::Stopped => Failure::Stopped,
                _ => super::ArchiveProblem::Damaged.into(),
            })?,
        );
        let mut folders = HashMap::new();
        for i in 0..index.folders() {
            if cancelled() {
                return Err(Failure::Stopped);
            }
            folders.insert(
                index
                    .folder(i)
                    .strip_prefix(Path::new(shown_as))
                    .unwrap()
                    .to_string_lossy()
                    .into_owned(),
                i,
            );
        }
        Ok(Self {
            live: Live::new(index),
            folders,
        })
    }

    pub fn list(&self, folder: &str, hide: bool) -> Scanned {
        let index = &self.live.base;
        let entries: Vec<u32> = self.folders.get(folder).map_or_else(Vec::new, |id| {
            index
                .block(*id)
                .filter(|&e| !(hide && index.attrs(e).hidden))
                .map(|e| e as u32)
                .collect()
        });
        let hits = entries
            .iter()
            .map(|e| Hit {
                score: 0,
                file: index.attrs(*e as usize).kind != EngineKind::Folder,
            })
            .collect();
        vec![(
            Found {
                index: index.clone(),
                hits: entries,
                updated: Default::default(),
                added: Vec::new(),
                new_dirs: Vec::new(),
                listed: Vec::new(),
                listed_dirs: Vec::new(),
                partial: None,
                seen: None,
            },
            hits,
        )]
    }
}
