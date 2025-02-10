//
//  AsyncObserver.swift
//  
//
//  Created by Olof Andersson-Thorén on 2023-01-01.
//

import Foundation

/**
 An async sequence that you use to be notified with future data in a sequence. Use it like an array, all objects appended to it will be sent to the observer.
 It has no memory of what has happend but you get all new changes. Note that leaking can happen if you are careless.
 Example of the regular setup:
 
final class ExampleClass: @unchecked Sendable {
	
	// store the task if you want to cancel observation
	var observerTask: Task<Void, Error>?
	func startListening() async {
		
		let observer = try await TheAutoModelClass.changeObserver()
		observerTask = Task { [weak self] in
			for await change in observer {
				// must be weak inside the observer unless you want to handle cancelling yourself
				try await self?.handleChanges(change.operation, change.id)
			}
		}
	}
	
	func handleChanges(_ operation: SQLiteOperation, _ id: AutoId) async throws {
		...
	}
}

 Example of queuing a series of ints and awaiting them, then cancelling the task to release the object:
let observer = AsyncObserver<Int>()
Task {
	// this task will never quit - it will "leak" until the observer is cancelled.
	for await num in observer {
		print("none-quitter got: \(num)")
	}
	print("This will never happen!")
}
let task = Task { [weak self] in
	// this task can be cancelled without needing to cancel everyone
	for await num in observer {
		print("num was: \(num)")
	}
	print("Finished observing")
}

// somewhere else we are doing work:
for index in 0..<10 {
	await observer.append(index)
	try await Task.sleep(for: .milliseconds(10))
}

// we can stop both by calling: await observer.cancelAll()
// but usually you only want to stop your own observer,
// then the task must be cancelled first and the observer get the cancel message after:
task.cancel()
await observer.cancel()
*/

public struct AsyncObserver<ElementType: Sendable>: AsyncSequence, AsyncIteratorProtocol, Sendable {
	private final class Message: @unchecked Sendable {
		var nilMeansCheckForCancellation: Bool = false
	}
	
    public typealias Element = ElementType
    let nextResource = AwaitResource<Element?>()
	private let message = Message()
    var _isCancelled = false
    
    public init() {}
    
    public var isCancelled: Bool {
		_isCancelled || Task.isCancelled
    }
    
    public func append(_ element: Element) async {
        await nextResource.sendResource(element)
    }
	
	/// Cancel the publisher which ends all for loops currently iterating and you can't start new ones
    public mutating func cancelAll() {
        _isCancelled = true
        Task { [nextResource] in
			await nextResource.sendResource(nil)
        }
    }
	
	/// To cancel an AsyncPublisher you must cancel its surounding Task and send it a message. If your task is cancelled you can either wait for it to happen or trigger this function.
	public func cancel() async {
		await _cancel(nextResource)
	}
	public func cancel() {
		Task {
			await cancel()
		}
	}
	
	func _cancel(_ pub: isolated AwaitResource<Element?>) async {
		message.nilMeansCheckForCancellation = true
		pub.sendResource(nil)
		message.nilMeansCheckForCancellation = false
	}
	
	/// Break all for loops currently iterating
	public func breakAll() async {
		await nextResource.sendResource(nil)
	}
    
	/// In the copied iterator we supply the for-loop by returning next element. Terminate loop with nil.
    public func next() async -> Element? {
        if isCancelled {
            return nil
        }
		return await withTaskCancellationHandler {
			let item = await nextResource.awaitResource()
			if item == nil && message.nilMeansCheckForCancellation {
				// we check if cancelled on the next loop - otherwise wait for the next
				await Task.yield()
				return await next()
			}
			return item
		} onCancel: {
			Task {
				await _cancel(nextResource)
			}
		}
    }
	
	// make a copy of the publisher and start serving from next
	public func makeAsyncIterator() -> Self {
        self
    }
}
