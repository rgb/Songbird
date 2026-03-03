# Fucking Approachable Swift Concurrency

**Source:** https://fuckingapproachableswiftconcurrency.com/en/
**Level:** 0 — Foundations

A comprehensive guide to understanding Swift's concurrency system through clear mental models and practical examples.

## Core Concepts

### Async/Await

The foundation of Swift concurrency. Functions marked `async` can pause execution, allowing other work to proceed. The `await` keyword marks suspension points.

Instead of callbacks, you write code that looks sequential — it pauses, waits, and resumes.

Use `async let` for parallel operations:

```swift
async let avatar = fetchImage("avatar.jpg")
async let banner = fetchImage("banner.jpg")
let results = await (avatar, banner)
```

### Tasks

Units of async work that bridge synchronous and asynchronous code. Key variants:

- **`Task { }`** — Inherits caller's isolation context
- **`Task.detached { }`** — Starts with no inherited context
- **`TaskGroup`** — Manages multiple parallel child tasks with structured concurrency

This is structured concurrency: work organized in a tree that's easy to reason about and clean up.

### Isolation Domains

Three primary isolation boundaries:

1. **`@MainActor`** — Protects UI framework access on the main thread
2. **`actor`** — Custom isolation boundaries for mutable state
3. **`nonisolated`** — Opts out of actor isolation

Rather than manually dispatching work to threads, you declare boundaries around data.

### Sendable Protocol

Marks types safe to pass across isolation boundaries. Automatically inferred for:
- Value types with Sendable properties
- Actors (always Sendable)
- Immutable reference types

Use `@unchecked Sendable` cautiously for thread-safe types requiring manual verification.

## Approachable Concurrency (Swift 6.2+)

New build settings simplify the model:
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
- `SWIFT_APPROACHABLE_CONCURRENCY = YES`

Result: code inherits MainActor isolation by default. Use `@concurrent` to explicitly run work on background threads.

## The Office Building Analogy

Your app is an office building where isolation domains are private offices:

- **MainActor** = front desk (customer interactions)
- **actor** types = department offices (protected documents)
- **nonisolated** = shared hallways (no private data)

Cross boundaries with `await` (knock and wait for entry).

## Common Mistakes to Avoid

1. **Confusing `async` with background execution** — `async` means "can pause," not "runs in background"
2. **Over-creating actors** — Most code lives fine on `@MainActor`
3. **Unmanaged tasks** — Use `.task` modifier or `TaskGroup` instead of bare `Task { }`
4. **Blocking cooperative threads** — Never use `DispatchSemaphore.wait()` in async code
5. **Unnecessary `MainActor.run`** — Annotate functions `@MainActor` instead

## Quick Reference

| Keyword | Purpose |
|---------|---------|
| `async` | Function can pause |
| `await` | Pause until completion |
| `@MainActor` | Run on main thread |
| `actor` | Isolated mutable state |
| `Sendable` | Safe across boundaries |
| `@concurrent` | Always run on background |
| `async let` | Parallel execution |

## Key Principle

Isolation is inherited by default. With Approachable Concurrency enabled, your app starts on MainActor, and that isolation propagates automatically through function calls, closures, and tasks — unless explicitly opted out.
