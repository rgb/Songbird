# Concurrency — The Swift Programming Language

**Source:** https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/
**Level:** 0 — Foundations

Perform asynchronous operations.

Swift has built-in support for writing asynchronous and parallel code in a structured way. *Asynchronous code* can be suspended and resumed later, although only one piece of the program executes at a time. Suspending and resuming code in your program lets it continue to make progress on short-term operations like updating its UI while continuing to work on long-running operations like fetching data over the network or parsing files. *Parallel code* means multiple pieces of code run simultaneously — for example, a computer with a four-core processor can run four pieces of code at the same time, with each core carrying out one of the tasks.

The additional scheduling flexibility from parallel or asynchronous code also comes with a cost of increased complexity. When you write concurrent code, you don't know ahead of time what code will run at the same time, and you might not always know the order that code will run. A common problem in concurrent code happens when multiple pieces of code try to access some piece of shared mutable state — this is known as a *data race*. When you use the language-level support for concurrency, Swift detects and prevents data races, and most data races produce a compile-time error. Some data races can't be detected until your code is running; these data races terminate code execution. You use actors and isolation to protect against data races, as described in this chapter.

> Note: If you've written concurrent code before, you might be used to working with threads. The concurrency model in Swift is built on top of threads, but you don't interact with them directly. An asynchronous function in Swift can give up the thread that it's running on, which lets another asynchronous function run on that thread while the first function is blocked. When an asynchronous function resumes, Swift doesn't make any guarantee about which thread that function will run on.

Although it's possible to write concurrent code without using Swift's language support, that code tends to be harder to read. For example, the following code downloads a list of photo names, downloads the first photo in that list, and shows that photo to the user:

```swift
listPhotos(inGallery: "Summer Vacation") { photoNames in
    let sortedNames = photoNames.sorted()
    let name = sortedNames[0]
    downloadPhoto(named: name) { photo in
        show(photo)
    }
}
```

Even in this simple case, because the code has to be written as a series of completion handlers, you end up writing nested closures. In this style, more complex code with deep nesting can quickly become unwieldy.

## Defining and Calling Asynchronous Functions

An *asynchronous function* or *asynchronous method* is a special kind of function or method that can be suspended while it's partway through execution. This is in contrast to ordinary, synchronous functions and methods, which either run to completion, throw an error, or never return. An asynchronous function or method still does one of those three things, but it can also pause in the middle when it's waiting for something. Inside the body of an asynchronous function or method, you mark each of these places where execution can be suspended.

To indicate that a function or method is asynchronous, you write the `async` keyword in its declaration after its parameters, similar to how you use `throws` to mark a throwing function. If the function or method returns a value, you write `async` before the return arrow (`->`). For example, here's how you might fetch the names of photos in a gallery:

```swift
func listPhotos(inGallery name: String) async -> [String] {
    let result = // ... some asynchronous networking code ...
    return result
}
```

For a function or method that's both asynchronous and throwing, you write `async` before `throws`.

When calling an asynchronous method, execution suspends until that method returns. You write `await` in front of the call to mark the possible suspension point. This is like writing `try` when calling a throwing function, to mark the possible change to the program's flow if there's an error. Inside an asynchronous method, the flow of execution can be suspended *only* when you call another asynchronous method — suspension is never implicit or preemptive — which means every possible suspension point is marked with `await`. Marking all of the possible suspension points in your code helps make concurrent code easier to read and understand.

For example, the code below fetches the names of all the pictures in a gallery and then shows the first picture:

```swift
let photoNames = await listPhotos(inGallery: "Summer Vacation")
let sortedNames = photoNames.sorted()
let name = sortedNames[0]
let photo = await downloadPhoto(named: name)
show(photo)
```

Because the `listPhotos(inGallery:)` and `downloadPhoto(named:)` functions both need to make network requests, they could take a relatively long time to complete. Making them both asynchronous by writing `async` before the return arrow lets the rest of the app's code keep running while this code waits for the picture to be ready.

To understand the concurrent nature of the example above, here's one possible order of execution:

1. The code starts running from the first line and runs up to the first `await`. It calls the `listPhotos(inGallery:)` function and suspends execution while it waits for that function to return.
2. While this code's execution is suspended, some other concurrent code in the same program runs. For example, maybe a long-running background task continues updating a list of new photo galleries. That code also runs until the next suspension point, marked by `await`, or until it completes.
3. After `listPhotos(inGallery:)` returns, this code continues execution starting at that point. It assigns the value that was returned to `photoNames`.
4. The lines that define `sortedNames` and `name` are regular, synchronous code. Because nothing is marked `await` on these lines, there aren't any possible suspension points.
5. The next `await` marks the call to the `downloadPhoto(named:)` function. This code pauses execution again until that function returns, giving other concurrent code an opportunity to run.
6. After `downloadPhoto(named:)` returns, its return value is assigned to `photo` and then passed as an argument when calling `show(_:)`.

The possible suspension points in your code marked with `await` indicate that the current piece of code might pause execution while waiting for the asynchronous function or method to return. This is also called *yielding the thread* because, behind the scenes, Swift suspends the execution of your code on the current thread and runs some other code on that thread instead. Because code with `await` needs to be able to suspend execution, only certain places in your program can call asynchronous functions or methods:

- Code in the body of an asynchronous function, method, or property.
- Code in the static `main()` method of a structure, class, or enumeration that's marked with `@main`.
- Code in an unstructured child task.

The `Task.sleep(for:tolerance:clock:)` method is useful when writing simple code to learn how concurrency works. This method suspends the current task for at least the given amount of time. Here's a version of the `listPhotos(inGallery:)` function that uses `sleep(for:tolerance:clock:)` to simulate waiting for a network operation:

```swift
func listPhotos(inGallery name: String) async throws -> [String] {
    try await Task.sleep(for: .seconds(2))
    return ["IMG001", "IMG99", "IMG0404"]
}
```

The version of `listPhotos(inGallery:)` in the code above is both asynchronous and throwing, because the call to `Task.sleep(until:tolerance:clock:)` can throw an error. When you call this version of `listPhotos(inGallery:)`, you write both `try` and `await`:

```swift
let photos = try await listPhotos(inGallery: "A Rainy Weekend")
```

Asynchronous functions have some similarities to throwing functions: When you define an asynchronous or throwing function, you mark it with `async` or `throws`, and you mark calls to that function with `await` or `try`. An asynchronous function can call another asynchronous function, just like a throwing function can call another throwing function.

However, there's a very important difference. You can wrap throwing code in a `do`-`catch` block to handle errors, or use `Result` to store the error for code elsewhere to handle it. These approaches let you call throwing functions from nonthrowing code. For example:

```swift
func availableRainyWeekendPhotos() -> Result<[String], Error> {
    return Result {
        try listDownloadedPhotos(inGallery: "A Rainy Weekend")
    }
}
```

In contrast, there's no safe way to wrap asynchronous code so you can call it from synchronous code and wait for the result. The Swift standard library intentionally omits this unsafe functionality — trying to implement it yourself can lead to problems like subtle races, threading issues, and deadlocks. When adding concurrent code to an existing project, work from the top down. Specifically, start by converting the top-most layer of code to use concurrency, and then start converting the functions and methods that it calls, working through the project's architecture one layer at a time. There's no way to take a bottom-up approach, because synchronous code can't ever call asynchronous code.

## Asynchronous Sequences

The `listPhotos(inGallery:)` function in the previous section asynchronously returns the whole array at once, after all of the array's elements are ready. Another approach is to wait for one element of the collection at a time using an *asynchronous sequence*. Here's what iterating over an asynchronous sequence looks like:

```swift
import Foundation

let handle = FileHandle.standardInput
for try await line in handle.bytes.lines {
    print(line)
}
```

Instead of using an ordinary `for`-`in` loop, the example above writes `for` with `await` after it. Like when you call an asynchronous function or method, writing `await` indicates a possible suspension point. A `for`-`await`-`in` loop potentially suspends execution at the beginning of each iteration, when it's waiting for the next element to be available.

In the same way that you can use your own types in a `for`-`in` loop by adding conformance to the `Sequence` protocol, you can use your own types in a `for`-`await`-`in` loop by adding conformance to the `AsyncSequence` protocol.

## Calling Asynchronous Functions in Parallel

Calling an asynchronous function with `await` runs only one piece of code at a time. While the asynchronous code is running, the caller waits for that code to finish before moving on to run the next line of code. For example, to fetch the first three photos from a gallery, you could await three calls to the `downloadPhoto(named:)` function as follows:

```swift
let firstPhoto = await downloadPhoto(named: photoNames[0])
let secondPhoto = await downloadPhoto(named: photoNames[1])
let thirdPhoto = await downloadPhoto(named: photoNames[2])

let photos = [firstPhoto, secondPhoto, thirdPhoto]
show(photos)
```

This approach has an important drawback: Although the download is asynchronous and lets other work happen while it progresses, only one call to `downloadPhoto(named:)` runs at a time. Each photo downloads completely before the next one starts downloading. However, there's no need for these operations to wait — each photo can download independently, or even at the same time.

To call an asynchronous function and let it run in parallel with code around it, write `async` in front of `let` when you define a constant, and then write `await` each time you use the constant.

```swift
async let firstPhoto = downloadPhoto(named: photoNames[0])
async let secondPhoto = downloadPhoto(named: photoNames[1])
async let thirdPhoto = downloadPhoto(named: photoNames[2])

let photos = await [firstPhoto, secondPhoto, thirdPhoto]
show(photos)
```

In this example, all three calls to `downloadPhoto(named:)` start without waiting for the previous one to complete. If there are enough system resources available, they can run at the same time. None of these function calls are marked with `await` because the code doesn't suspend to wait for the function's result. Instead, execution continues until the line where `photos` is defined — at that point, the program needs the results from these asynchronous calls, so you write `await` to pause execution until all three photos finish downloading.

Here's how you can think about the differences between these two approaches:

- Call asynchronous functions with `await` when the code on the following lines depends on that function's result. This creates work that is carried out sequentially.
- Call asynchronous functions with `async`-`let` when you don't need the result until later in your code. This creates work that can be carried out in parallel.
- Both `await` and `async`-`let` allow other code to run while they're suspended.
- In both cases, you mark the possible suspension point with `await` to indicate that execution will pause, if needed, until an asynchronous function has returned.

You can also mix both of these approaches in the same code.

## Tasks and Task Groups

A *task* is a unit of work that can be run asynchronously as part of your program. All asynchronous code runs as part of some task. A task itself does only one thing at a time, but when you create multiple tasks, Swift can schedule them to run simultaneously.

The `async`-`let` syntax described in the previous section implicitly creates a child task — this syntax works well when you already know what tasks your program needs to run. You can also create a task group (an instance of `TaskGroup`) and explicitly add child tasks to that group, which gives you more control over priority and cancellation, and lets you create a dynamic number of tasks.

Tasks are arranged in a hierarchy. Each task in a given task group has the same parent task, and each task can have child tasks. Because of the explicit relationship between tasks and task groups, this approach is called *structured concurrency*. The explicit parent-child relationship between tasks has several advantages:

- In a parent task, you can't forget to wait for its child tasks to complete.
- When setting a higher priority on a child task, the parent task's priority is automatically escalated.
- When a parent task is canceled, each of its child tasks is also automatically canceled.
- Task-local values propagate to child tasks efficiently and automatically.

Here's another version of the code to download photos that handles any number of photos:

```swift
await withTaskGroup(of: Data.self) { group in
    let photoNames = await listPhotos(inGallery: "Summer Vacation")
    for name in photoNames {
        group.addTask {
            return await downloadPhoto(named: name)
        }
    }

    for await photo in group {
        show(photo)
    }
}
```

The code above creates a new task group, and then creates child tasks to download each photo in the gallery. Swift runs as many of these tasks concurrently as conditions allow. As soon as a child task finishes downloading a photo, that photo is displayed. There's no guarantee about the order that child tasks complete, so the photos from this gallery can be shown in any order.

In the code listing above, each photo is downloaded and then displayed, so the task group doesn't return any results. For a task group that returns a result, you add code that accumulates its result inside the closure you pass to `withTaskGroup(of:returning:body:)`.

```swift
let photos = await withTaskGroup(of: Data.self) { group in
    let photoNames = await listPhotos(inGallery: "Summer Vacation")
    for name in photoNames {
        group.addTask {
            return await downloadPhoto(named: name)
        }
    }

    var results: [Data] = []
    for await photo in group {
        results.append(photo)
    }

    return results
}
```

### Task Cancellation

Swift concurrency uses a cooperative cancellation model. Each task checks whether it has been canceled at the appropriate points in its execution, and responds to cancellation appropriately. Depending on what work the task is doing, responding to cancellation usually means one of the following:

- Throwing an error like `CancellationError`
- Returning `nil` or an empty collection
- Returning the partially completed work

Downloading pictures could take a long time if the pictures are large or the network is slow. To let the user stop this work, without waiting for all of the tasks to complete, the tasks need to check for cancellation and stop running if they are canceled. There are two ways a task can do this: by calling the `Task.checkCancellation()` type method, or by reading the `Task.isCancelled` type property. Calling `checkCancellation()` throws an error if the task is canceled; a throwing task can propagate the error out of the task, stopping all of the task's work. This has the advantage of being simple to implement and understand. For more flexibility, use the `isCancelled` property, which lets you perform clean-up work as part of stopping the task, like closing network connections and deleting temporary files.

```swift
let photos = await withTaskGroup { group in
    let photoNames = await listPhotos(inGallery: "Summer Vacation")
    for name in photoNames {
        let added = group.addTaskUnlessCancelled {
            Task.isCancelled ? nil : await downloadPhoto(named: name)
        }
        guard added else { break }
    }

    var results: [Data] = []
    for await photo in group {
        if let photo { results.append(photo) }
    }
    return results
}
```

The code above makes several changes from the previous version:

- Each task is added using the `TaskGroup.addTaskUnlessCancelled(priority:operation:)` method, to avoid starting new work after cancellation.
- After each call to `addTaskUnlessCancelled(priority:operation:)`, the code confirms that the new child task was added. If the group is canceled, the value of `added` is `false` — in that case, the code stops trying to download additional photos.
- Each task checks for cancellation before starting to download the photo. If it has been canceled, the task returns `nil`.
- At the end, the task group skips `nil` values when collecting the results. Handling cancellation by returning `nil` means the task group can return a partial result — the photos that were already downloaded at the time of cancellation — instead of discarding that completed work.

For work that needs immediate notification of cancellation, use the `Task.withTaskCancellationHandler(operation:onCancel:isolation:)` method. For example:

```swift
let task = await Task.withTaskCancellationHandler {
    // ...
} onCancel: {
    print("Canceled!")
}

// ... some time later...
task.cancel()  // Prints "Canceled!"
```

When using a cancellation handler, task cancellation is still cooperative: The task either runs to completion or checks for cancellation and stops early. Because the task is still running when the cancellation handler starts, avoid sharing state between the task and its cancellation handler, which could create a race condition.

### Unstructured Concurrency

In addition to the structured approaches to concurrency described in the previous sections, Swift also supports unstructured concurrency. Unlike tasks that are part of a task group, an *unstructured task* doesn't have a parent task. You have complete flexibility to manage unstructured tasks in whatever way your program needs, but you're also completely responsible for their correctness.

To create an unstructured task that runs similarly to the surrounding code, call the `Task.init(name:priority:operation:)` initializer. The new task defaults to running with the same actor isolation, priority, and task-local state as the current task. To create an unstructured task that's more independent from the surrounding code, known more specifically as a *detached task*, call the `Task.detached(name:priority:operation:)` static method. The new task defaults to running without any actor isolation and doesn't inherit the current task's priority or task-local state. Both of these operations return a task that you can interact with — for example, to wait for its result or to cancel it.

```swift
let newPhoto = // ... some photo data ...
let handle = Task {
    return await add(newPhoto, toGalleryNamed: "Spring Adventures")
}
let result = await handle.value
```

## Isolation

The previous sections discuss approaches for splitting up concurrent work. That work can involve changing shared data, such as an app's UI. If different parts of your code can modify the same data at the same time, that risks creating a data race. Swift protects you from data races in your code: Whenever you read or modify a piece of data, Swift ensures that no other code is modifying it concurrently. This guarantee is called *data isolation*. There are three main ways to isolate data:

1. **Immutable data** is always isolated. Because you can't modify a constant, there's no risk of other code modifying a constant at the same time you're reading it.
2. **Data that's referenced by only the current task** is always isolated. A local variable is safe to read and write because no code outside the task has a reference to that memory, so no other code can modify that data.
3. **Data that's protected by an actor** is isolated if the code accessing that data is also isolated to the actor.

## The Main Actor

An actor is an object that protects access to mutable data by forcing code to take turns accessing that data. The most important actor in many programs is the *main actor*. In an app, the main actor protects all of the data that's used to show the UI.

Before you start using concurrency in your code, everything runs on the main actor. As you identify long-running or resource-intensive code, you can move this work off the main actor in a way that's still safe and correct.

> Note: The main actor is closely related to the main thread, but they're not the same thing. The main actor has private mutable state, and the main thread serializes access to that state. When you run code on the main actor, Swift executes that code on the main thread. Because of this connection, you might see these two terms used interchangeably. Your code interacts with the main actor; the main thread is a lower-level implementation detail.

There are several ways to run work on the main actor. To ensure a function always runs on the main actor, mark it with the `@MainActor` attribute:

```swift
@MainActor
func show(_: Data) {
    // ... UI code to display the photo ...
}
```

In the code above, the `@MainActor` attribute on the `show(_:)` function requires this function to run only on the main actor. Within other code that's running on the main actor, you can call `show(_:)` as a synchronous function. However, to call `show(_:)` from code that isn't running on the main actor, you have to include `await` and call it as an asynchronous function because switching to the main actor introduces a potential suspension point.

```swift
func downloadAndShowPhoto(named name: String) async {
    let photo = await downloadPhoto(named: name)
    await show(photo)
}
```

You can also write `@MainActor` on a structure, class, or enumeration to ensure all of its methods and all access to its properties run on the main actor:

```swift
@MainActor
struct PhotoGallery {
    var photoNames: [String]
    func drawUI() { /* ... */ }
}
```

When you're building on top of a framework, that framework's protocols and base classes are typically already marked `@MainActor`, so you don't usually write `@MainActor` on your own types in that case:

```swift
@MainActor
protocol View { /* ... */ }

// Implicitly @MainActor
struct PhotoGalleryView: View { /* ... */ }
```

For more fine-grained control, you can write `@MainActor` on just the properties or methods that need it:

```swift
struct PhotoGallery {
    @MainActor var photoNames: [String]
    var hasCachedPhotos = false

    @MainActor func drawUI() { /* ... UI code ... */ }
    func cachePhotos() { /* ... networking code ... */ }
}
```

## Actors

Swift provides the main actor for you — you can also define your own actors. Actors let you safely share information between concurrent code.

Like classes, actors are reference types. Unlike classes, actors allow only one task to access their mutable state at a time, which makes it safe for code in multiple tasks to interact with the same instance of an actor. For example, here's an actor that records temperatures:

```swift
actor TemperatureLogger {
    let label: String
    var measurements: [Int]
    private(set) var max: Int

    init(label: String, measurement: Int) {
        self.label = label
        self.measurements = [measurement]
        self.max = measurement
    }
}
```

You introduce an actor with the `actor` keyword, followed by its definition in a pair of braces. When you access a property or method of an actor, you use `await` to mark the potential suspension point:

```swift
let logger = TemperatureLogger(label: "Outdoors", measurement: 25)
print(await logger.max)
// Prints "25"
```

In contrast, code that's part of the actor doesn't write `await` when accessing the actor's properties:

```swift
extension TemperatureLogger {
    func update(with measurement: Int) {
        measurements.append(measurement)
        if measurement > max {
            max = measurement
        }
    }
}
```

The `update(with:)` method is already running on the actor, so it doesn't mark its access to properties like `max` with `await`. This method also shows one of the reasons why actors allow only one task at a time to interact with their mutable state: Some updates to an actor's state temporarily break invariants. Preventing multiple tasks from interacting with the same instance simultaneously prevents problems like reading data in a temporarily invalid state.

Because `update(with:)` doesn't contain any suspension points, no other code can access the data in the middle of an update.

If code outside the actor tries to access those properties directly, you'll get a compile-time error:

```swift
print(logger.max)  // Error
```

Accessing `logger.max` without writing `await` fails because the properties of an actor are part of that actor's isolated local state. This guarantee is known as *actor isolation*.

The following aspects of the Swift concurrency model work together to make it easier to reason about shared mutable state:

- Code in between possible suspension points runs sequentially, without the possibility of interruption from other concurrent code.
- Code that interacts with an actor's local state runs only on that actor.
- An actor runs only one piece of code at a time.

A synchronous method on an actor is guaranteed to *never* contain potential suspension points, which encapsulates code that temporarily makes the data model inconsistent and ensures no other code can run before data consistency is restored.

## Global Actors

The main actor is a global singleton instance of the `MainActor` type. An actor can normally have multiple instances, each of which provides independent isolation. However, because `MainActor` is a singleton — there is only ever a single instance of this type — the type alone is sufficient to identify the actor, allowing you to mark main-actor isolation using just an attribute.

You can define your own singleton global actors using the `@globalActor` attribute.

## Sendable Types

Tasks and actors let you divide a program into pieces that can safely run concurrently. Inside of a task or an instance of an actor, the part of a program that contains mutable state, like variables and properties, is called a *concurrency domain*. Some kinds of data can't be shared between concurrency domains, because that data contains mutable state, but it doesn't protect against overlapping access.

A type that can be shared from one concurrency domain to another is known as a *sendable* type. You mark a type as being sendable by declaring conformance to the `Sendable` protocol. That protocol doesn't have any code requirements, but it does have semantic requirements that Swift enforces. In general, there are three ways for a type to be sendable:

- The type is a value type, and its mutable state is made up of other sendable data — for example, a structure with stored properties that are sendable or an enumeration with associated values that are sendable.
- The type doesn't have any mutable state, and its immutable state is made up of other sendable data — for example, a structure or class that has only read-only properties.
- The type has code that ensures the safety of its mutable state, like a class that's marked `@MainActor` or a class that serializes access to its properties on a particular thread or queue.

Some types are always sendable, like structures that have only sendable properties and enumerations that have only sendable associated values:

```swift
struct TemperatureReading: Sendable {
    var measurement: Int
}

extension TemperatureLogger {
    func addReading(from reading: TemperatureReading) {
        measurements.append(reading.measurement)
    }
}

let logger = TemperatureLogger(label: "Tea kettle", measurement: 85)
let reading = TemperatureReading(measurement: 45)
await logger.addReading(from: reading)
```

Because `TemperatureReading` is a structure that has only sendable properties, and the structure isn't marked `public` or `@usableFromInline`, it's implicitly sendable. Here's a version of the structure where conformance to the `Sendable` protocol is implied:

```swift
struct TemperatureReading {
    var measurement: Int
}
```

To explicitly mark a type as not being sendable, write an unavailable conformance to `Sendable`:

```swift
struct FileDescriptor {
    let rawValue: Int
}

@available(*, unavailable)
extension FileDescriptor: Sendable {}
```
