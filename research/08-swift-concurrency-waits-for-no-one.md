# Swift Concurrency Waits for No One

**Source:** https://saagarjha.com/blog/2023/12/22/swift-concurrency-waits-for-no-one/
**Author:** Saagar Jha
**Date:** December 22, 2023
**Level:** 2 — Design Principles

Explores forward progress guarantees as a foundational design principle of Swift Concurrency. Essential reading for understanding why certain patterns are dangerous.

## Background

Swift Concurrency offers modern approaches to async programming but introduces complex rules that differ fundamentally from older APIs like Grand Central Dispatch and POSIX threads. While the compiler enforces many requirements, others depend on runtime behavior and developer understanding. This article focuses on "forward progress" — a critical but often misunderstood concept.

## Concurrency vs. Parallelism

- **Concurrency** allows multiple tasks in progress simultaneously
- **Parallelism** enables simultaneous execution on multiple cores

The cooperative thread pool underlying Swift Concurrency is an implementation detail, but understanding its constraints proves essential for writing correct code.

## The Forward Progress Problem

The central rule: **all tasks on the cooperative thread pool must make forward progress.** Blocking operations like `DispatchSemaphore.wait()` violate this guarantee, potentially causing deadlocks — even if all semaphore calls appear balanced.

A thread pool with a single thread cannot make progress if that thread blocks waiting for work that must run on the same pool.

## Real-World Deadlock Scenarios

### Example 1: Simple Semaphore Lock

A seemingly straightforward `Lock` actor using `DispatchSemaphore` deadlocks when multiple threads simultaneously call `lock()`, starving the cooperative pool.

### Example 2: Bridging Async and Sync

A more insidious case: calling `async` work from a synchronous delegate method:

```swift
func shouldLend(_ book: Book) -> Bool {
    class Unreserved: @unchecked Sendable { var value: Bool! }
    let unreserved = Unreserved()

    let semaphore = DispatchSemaphore(value: 0)
    Task {
        let holds = await holdManager.holds(on: book)
        unreserved.value = holds.isEmpty
        semaphore.signal()
    }
    semaphore.wait()

    let account = library.lookupAccount(forCardNumber: cardNumber)
    return !account.hasFines && unreserved.value
}
```

This code deadlocks because `shouldLend(_:)` can be called from the cooperative thread pool itself (via async contexts in the call stack). The blocking semaphore prevents the spawned `Task` from executing.

## Why Legacy Code Survives

Pre-Swift Concurrency libraries using semaphores generally work safely because they don't spawn Tasks. Their async operations run on different subsystems (network, dispatch queues, XPC), not the cooperative pool. However, this safety disappears if implementation details change — for example, if asynchronous work transitions to using Swift Concurrency internally.

## Key Takeaways

1. Forward progress violations cause deadlocks that are difficult to debug and reproduce
2. Blocking operations are "all but impossible to use safely" from Swift Concurrency
3. The cooperative thread pool's scheduling decisions can be affected by code you don't control
4. Some legacy code cannot be safely bridged; rewriting may be necessary
5. Forward progress analysis should inform whether Swift Concurrency suits a project

The article concludes that while Swift Concurrency benefits many projects, understanding its forward progress requirements is essential before adoption.
