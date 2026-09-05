//! Standalone allocation regression test for the streaming markdown hot path.
//! Run without GPUI: rustc --edition=2024 --test scripts/check-markdown-allocations.rs -o /tmp/shidou-mend-tests && /tmp/shidou-mend-tests --exact marker_free_streaming_tails_do_not_allocate --nocapture
//! The ordinary Cargo suite owns mend's unit tests; this command runs only the allocation check.

#[path = "../src/md/mend.rs"]
mod mend;

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;

struct CountingAllocator;

thread_local! {
    static ALLOCATIONS: Cell<Option<(usize, usize)>> = const { Cell::new(None) };
}

fn record_allocation(bytes: usize) {
    let _ = ALLOCATIONS.try_with(|counts| {
        if let Some((calls, total)) = counts.get() {
            counts.set(Some((calls + 1, total + bytes)));
        }
    });
}

unsafe impl GlobalAlloc for CountingAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        record_allocation(layout.size());
        unsafe { System.alloc(layout) }
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        record_allocation(layout.size());
        unsafe { System.alloc_zeroed(layout) }
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, size: usize) -> *mut u8 {
        record_allocation(size);
        unsafe { System.realloc(ptr, layout, size) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) }
    }
}

#[global_allocator]
static ALLOCATOR: CountingAllocator = CountingAllocator;

#[test]
fn marker_free_streaming_tails_do_not_allocate() {
    let mut total_calls = 0;
    for unit in [
        "Plain reasoning about the next step. ",
        "日本語の考察と café 🎉. ",
    ] {
        let text = unit.repeat(2048);
        // Count only the production call, not fixture construction or reporting.
        ALLOCATIONS.with(|counts| counts.set(Some((0, 0))));
        for chunk in 1..=128 {
            let end = unit.len() * 16 * chunk;
            assert_eq!(
                mend::close_hanging(std::hint::black_box(&text[..end])),
                None
            );
        }
        let (calls, bytes) = ALLOCATIONS.with(|counts| counts.replace(None).unwrap());
        eprintln!(
            "128 growing tails, {} final bytes: {calls} allocation/reallocation calls, {bytes} requested bytes",
            text.len()
        );
        total_calls += calls;
    }
    assert_eq!(total_calls, 0);
}
