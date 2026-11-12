use std::collections::HashMap;
use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::path::PathBuf;
use std::sync::Arc;

use crate::EngineError;
use crate::crawl::{Crawl, Listing, NONE};
use crate::index::Index;
use crate::rank::{Place, Places};

pub(crate) struct Folder {
    pub path: PathBuf,
    pub place: Place,
    pub listing: Listing,
}

#[derive(Clone)]
pub(crate) struct Snapshot {
    pub base: Arc<Index>,
    pub batches: Vec<Arc<Vec<Folder>>>,
    pub excluded: Vec<PathBuf>,
}

pub(crate) struct Partial {
    snapshot: Snapshot,
    paths: HashMap<u32, (PathBuf, Place)>,
    places: Places,
}

impl Partial {
    pub fn new(root: PathBuf, home: &std::path::Path, boot: bool) -> Result<Self, EngineError> {
        let places = Places::new(home);
        let place = places.root(&root, boot);
        let base = Arc::new(Index::build_until(
            Crawl::default(),
            root.clone(),
            &[],
            0,
            0,
            &|| false,
        )?);
        Ok(Self {
            snapshot: Snapshot {
                base,
                batches: Vec::new(),
                excluded: Vec::new(),
            },
            paths: HashMap::from([(0, (root, place))]),
            places,
        })
    }

    pub fn snapshot(&self) -> Snapshot {
        self.snapshot.clone()
    }

    pub fn push(&mut self, listings: &[Listing]) {
        let mut batch = Vec::with_capacity(listings.len());
        for listing in listings {
            let Some((path, place)) = self.paths.remove(&listing.id) else {
                continue;
            };
            for entry in &listing.ents {
                if entry.child != NONE {
                    let name = listing.name(entry);
                    self.paths.insert(
                        entry.child,
                        (
                            path.join(OsStr::from_bytes(name)),
                            self.places.step(&place, name, entry.hidden),
                        ),
                    );
                }
            }
            batch.push(Folder {
                path,
                place,
                listing: listing.clone(),
            });
        }
        self.snapshot.batches.push(Arc::new(batch));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crawl::tests::{TempTree, crawl};
    use std::collections::HashSet;

    #[test]
    fn partial_listings_are_not_copied() {
        let tree = TempTree::new("partial-shared");
        for i in 0..20 {
            std::fs::write(tree.0.join(format!("{}", 20 - i)), b"").unwrap();
        }
        let mut crawl = crawl(&tree, &[], false);
        assert!(crawl.listings.len() > 1);
        assert!(crawl.listings.iter().all(|l| !l.ents.is_empty()));
        let ready = crawl.listings.iter().all(|l| {
            l.ents.is_sorted_by(|a, b| l.name(a) <= l.name(b)) && l.ents.capacity() == l.ents.len()
        });
        let mut partial = Partial::new(tree.0.clone(), &tree.0, false).unwrap();
        partial.push(&crawl.listings);
        for listing in &mut crawl.listings {
            listing.sort();
        }
        let snapshot = partial.snapshot();
        let shared: Vec<&Listing> = snapshot
            .batches
            .iter()
            .flat_map(|batch| batch.iter().map(|folder| &folder.listing))
            .collect();
        assert_eq!(
            shared.iter().map(|l| l.id).collect::<Vec<_>>(),
            crawl.listings.iter().map(|l| l.id).collect::<Vec<_>>()
        );
        let held = |l: &Listing| (l.ents.as_ptr(), l.name(&l.ents[0]).as_ptr());
        let buffers: HashSet<_> = crawl.listings.iter().chain(shared).map(held).collect();
        assert_eq!(buffers.len(), crawl.listings.len());
        assert!(ready);
    }
}
