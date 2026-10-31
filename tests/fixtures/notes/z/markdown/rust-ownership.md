---
title: Rust Ownership
aliases: [Ownership]
tags: [rust, lang]
date: 2026-10-30
---

# Rust Ownership ##

Ownership rules keep memory safe without a garbage collector.

## Borrowing {#borrow}

References let you use a value without taking it.

### Mutable references

Only one at a time, and no shared ones while it lives.

Lifetimes
---------

A reference must not outlive the value it points to.

```rust
# not a heading
fn main() {}
```

Notes: written by an assistant, kept for reference.
