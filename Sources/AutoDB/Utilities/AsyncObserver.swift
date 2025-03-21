//
//  AsyncObserver.swift
//  
//
//  Created by Olof Andersson-Thorén on 2023-01-01.
//

import Foundation

/**
 TODO: update this outdated doc:
 
 An async sequence that you use to be notified with future data in a sequence. Use it like an array, all objects appended to it will be sent to the observer.
 It has no memory of what has happend but you get all new changes. Note that leaking can happen if you are careless.
 Example of the regular setup:
 
final class ExampleClass: @unchecked Sendable {
	
	// store the task if you want to cancel observation
	var observerTask: Task<Void, Error>?
	func startListening() async {
		
		let observer = try await TheModelClass.changeObserver()
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

public struct AsyncObserver<Element: Sendable>: AsyncSequence, AsyncIteratorProtocol, Sendable {
	
	/// The sender-actor is shared by all observers to have one entry-point for to add new items
    fileprivate let globalSender = Sender()
	/// each await-loop (a copy) has its own task-queue, that stores all incoming values and allows the listener to hande each returned result in its own time
	private var queue: Queue?
    
	var _isCancelled = false
    public var isCancelled: Bool {
		_isCancelled || Task.isCancelled //  || queue?.isCancelled == true
    }
	
	public init() {}
	
	// if you want to wait while this is delivered (usually has no impact)
	public func appendWait(_ element: Element) async {
		await globalSender.sendResource(element)
	}
	
	// if you only want scheduling, to continue with other tasks before this is delivered
    public func append(_ element: Element) {
		Task {
			await globalSender.sendResource(element)
		}
    }
	
	/// To cancel an AsyncObserver you must cancel its surounding Task and send it a message.
	/// To cancel ALL listeners to this Observer which ends all for-loops currently iterating (and you can't start new ones) cancelAll is here for you.
	/// Why would anyone ever use this?
	public mutating func cancelAll() async {
        _isCancelled = true
		await globalSender.cancel()
    }
	
	/// In the copied iterator we supply the for-loop by returning next element. Terminate loop with nil.
    public func next() async -> Element? {
        if isCancelled {
            return nil
        }
		
		return await withTaskCancellationHandler {
			
			return await queue?.next()
			
		} onCancel: {
			Task {
				await queue?.cancel()
			}
		}
    }
	
	// make a copy of the Observer and start enquing incoming values
	public func makeAsyncIterator() -> Self {
        var copy = self
		let queue = Queue()
		copy.queue = queue
		Task {
			// start listening at once and build the queue of incoming values,
			await copy.globalSender.addObserver(queue)
				
		}
		return copy
    }
	
	/// Each async-loop has one queue with items, and picks from it or wait inside for the next item.
	fileprivate actor Queue {
		
		var isCancelled = false
		var waitQueue = [Element]()
		var continuation: CheckedContinuation<Void, Error>?
		
		init() {
		}
		
		func next() async -> Element? {
			if waitQueue.isEmpty == false {
				return waitQueue.removeFirst()
			}
			do {
				try await withCheckedThrowingContinuation { closure in
					continuation = closure
				}
				if waitQueue.isEmpty == false {
					return waitQueue.removeFirst()
				}
				// nil means the queue has run out
				return nil
			} catch {
				// cancellation error is thrown
				return nil
			}
		}
		
		func notify(_ value: Element?) async {
			guard let value else {
				await cancel()
				return
			}
			waitQueue.append(value)
			
			//wake the observer if sleeping
			continuation?.resume()
			continuation = nil
		}
		
		func cancel() async {
			isCancelled = true
			continuation?.resume(throwing: CancellationError())
			continuation = nil
		}
	}
	
	/**
	 Await something that will be created in the future. A basic queue with a producer that sends resources, and consumers that awaits them.
	 */
	fileprivate actor Sender {
		
		var isCancelled = false
		var observers = WeakArray<Queue>([])	// figure out this type-error: 'WeakArray' requires that 'any AsyncObserverObject' be a class type (which it is...)
		init() {}
		
		func addObserver(_ observer: Queue) {
			if isCancelled { return }
			observers.append(observer)
		}
		
		/// send to each registered observer
		func sendResource(_ resource: Element?) async {
			observers.cleanup()
			for observer in observers {
				await observer?.notify(resource)
			}
		}
		
		func cancel() async {
			isCancelled = true
			await sendResource(nil)
			observers.removeAll()
		}
	}

}

