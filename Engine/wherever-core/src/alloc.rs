use std::alloc::{GlobalAlloc, Layout, System};
use std::ptr;

const BIG: usize = 1 << 20;
const PAGE_ALIGN: usize = 4096;

pub(crate) struct BigAlloc;

fn big(layout: Layout) -> bool {
    layout.size() >= BIG && layout.align() <= PAGE_ALIGN
}

unsafe fn map(size: usize) -> *mut u8 {
    let p = unsafe {
        libc::mmap(
            ptr::null_mut(),
            size,
            libc::PROT_READ | libc::PROT_WRITE,
            libc::MAP_PRIVATE | libc::MAP_ANON,
            -1,
            0,
        )
    };
    if p == libc::MAP_FAILED {
        ptr::null_mut()
    } else {
        p.cast()
    }
}

unsafe fn unmap(p: *mut u8, size: usize) {
    unsafe { libc::munmap(p.cast(), size) };
}

unsafe impl GlobalAlloc for BigAlloc {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        #[cfg(test)]
        count::add(layout.size() as isize, 1);
        if big(layout) {
            unsafe { map(layout.size()) }
        } else {
            unsafe { System.alloc(layout) }
        }
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        #[cfg(test)]
        count::add(layout.size() as isize, 1);
        if big(layout) {
            unsafe { map(layout.size()) }
        } else {
            unsafe { System.alloc_zeroed(layout) }
        }
    }

    unsafe fn dealloc(&self, p: *mut u8, layout: Layout) {
        #[cfg(test)]
        count::add(-(layout.size() as isize), -1);
        if big(layout) {
            unsafe { unmap(p, layout.size()) }
        } else {
            unsafe { System.dealloc(p, layout) }
        }
    }

    unsafe fn realloc(&self, p: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        let new = unsafe { Layout::from_size_align_unchecked(new_size, layout.align()) };
        if !big(layout) && !big(new) {
            #[cfg(test)]
            count::add(new_size as isize - layout.size() as isize, 0);
            return unsafe { System.realloc(p, layout, new_size) };
        }
        let q = unsafe { self.alloc(new) };
        if !q.is_null() {
            unsafe {
                ptr::copy_nonoverlapping(p, q, layout.size().min(new_size));
                self.dealloc(p, layout);
            }
        }
        q
    }
}

#[cfg(test)]
pub(crate) mod count {
    use std::cell::Cell;

    thread_local! {
        static NOW: Cell<[isize; 3]> = const { Cell::new([0; 3]) };
    }

    pub(super) fn add(bytes: isize, blocks: isize) {
        let _ = NOW.try_with(|c| {
            let [b, n, peak] = c.get();
            let b = b.wrapping_add(bytes);
            c.set([b, n.wrapping_add(blocks), peak.max(b)]);
        });
    }

    pub(crate) fn live() -> (isize, isize) {
        let [b, n, _] = NOW.with(Cell::get);
        (b, n)
    }

    pub(crate) fn peak_of<T>(f: impl FnOnce() -> T) -> (T, isize) {
        let [b, n, _] = NOW.with(Cell::get);
        NOW.with(|c| c.set([b, n, b]));
        let out = f();
        (out, NOW.with(Cell::get)[2] - b)
    }
}

#[cfg(test)]
mod tests {
    use super::count;
    use std::alloc::{Layout, alloc, dealloc};

    #[test]
    fn the_counter_follows_this_threads_blocks() {
        let before = count::live();
        let (v, peak) = count::peak_of(|| {
            let mut v: Vec<u8> = Vec::with_capacity(1000);
            v.push(1);
            v
        });
        assert_eq!(peak, 1000);
        assert_eq!(count::live(), (before.0 + 1000, before.1 + 1));
        drop(v);
        assert_eq!(count::live(), before);
        let (_, peak) = count::peak_of(|| {
            let mut v: Vec<u8> = Vec::with_capacity(1 << 20);
            v.reserve_exact(1 << 21);
            assert_eq!(count::live(), (before.0 + (1 << 21), before.1 + 1));
        });
        assert_eq!(peak, 3 << 20);
        assert_eq!(count::live(), before);
    }

    #[test]
    fn big_blocks_go_back_at_free() {
        let out = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "--ignored", "--test-threads=1", CHILD])
            .output()
            .unwrap();
        let text = String::from_utf8_lossy(&out.stdout);
        assert!(
            out.status.success() && text.contains("1 passed"),
            "{}{}",
            text,
            String::from_utf8_lossy(&out.stderr)
        );
    }

    const CHILD: &str = "alloc::tests::freed_block_is_unmapped";

    #[test]
    #[ignore = "run alone by big_blocks_go_back_at_free"]
    fn freed_block_is_unmapped() {
        let size = (64 << 20) + (16 << 10);
        let layout = Layout::from_size_align(size, 8).unwrap();
        let mut pages: Vec<libc::c_char> = vec![0; size.div_ceil(4096)];
        let p = unsafe { alloc(layout) };
        assert!(!p.is_null());
        unsafe {
            p.write_bytes(1, size);
            dealloc(p, layout);
        }
        let r = unsafe { libc::mincore(p.cast(), size, pages.as_mut_ptr()) };
        let resident = pages
            .iter()
            .filter(|&&f| f as libc::c_int & libc::MINCORE_INCORE != 0)
            .count();
        assert!(
            r == -1 || resident == 0,
            "{resident} pages of the freed block are still resident"
        );
    }
}
