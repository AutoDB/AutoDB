//
//  Semaphore.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2024-12-05.
//

/**
 Lock free semaphore using Async/Await, it does not guarantee FIFO but tries to.
 Semaphore taken from CommonSwift utility functions
 
 ```
 Use like this:
class Example {
	private let semaphore = Semaphore(value: 1)
	
	private let data: Data?
	func longRunningTask() async -> Data {
		
		// wait until previous work is done, then continue, note that without congestion, this is just incrementing and decrementing an int. Takes basically no extra time.
		await semaphore.wait()
		defer { Task { await semaphore.signal() } }
		
		// if already created, just continue
		if let data { return data }
		
		// Only one will create the data
		let data = ... do the actual work
		self.data = data
		return data
	}
}
```
 
 For reccurring tasks, where you need re-entry to your actor - use a token. If you own a semaphore with a token you can access the restricted area as much as you like.
 There are people who think that this can be done with a NSReccuringLock - that is not the case with async/await with actors. *usually* it will work fine but since an actor may run on different threads it may not (those locks know you own them by checking the currentThread - this is not how you do things with actors).
 
 ```
 class Example {
 
	func reccuringTask(_ token: AutoId? = nil) async {
		
		let token = token ?? AutoId.generateId()
		// wait until previous work is done then continue, unless you are already cleared by the semaphore - then just continue.
		await semaphore.wait(token: token)
		defer { Task { await semaphore.signal(token: token) } }	// signal with token too!
		
		// do whatever work you need to do
		let data = ... do the actual work
		reccuringTask(token)
	}
 }
 ```
 */

public actor Semaphore {
	private var updateWaiters = [() -> ()]()
	private var counter: Int = 0
	private var allowedWorkers: Int
	private var reEntryTokens: [AutoId: Int] = [:]
	
	public init(allowedWorkers: Int = 1) {
		self.allowedWorkers = allowedWorkers
	}
	
	/// prevent entering the same function before previous execution has exited it, unless using the same token that acquired the semaphore. You still must call signal() every time.
	/// This will suspend work until someone wakes it by calling signal()
	public func wait(token: AutoId? = nil) async {
		
		if let token, let myCount = reEntryTokens[token], myCount > 0 {
			// if we have the token we ignore the global count
			reEntryTokens[token] = myCount + 1
			return
		}
		else if counter < allowedWorkers {
			if let token {
				reEntryTokens[token] = reEntryTokens[token] ?? 0 + 1
			}
			counter += 1
			return
		}
		
		await withCheckedContinuation { continuation in
			updateWaiters.append( {
				continuation.resume()
			})
		}
		
		// try taking the semaphore again, it should work this time
		await wait(token: token)
	}
	
	/// wake one waiter
	public func signal(token: AutoId? = nil) {
		if let token, let myCount = reEntryTokens[token] {
			// if there is a token, decreace its count first.
			if myCount > 1 {
				reEntryTokens[token] = myCount - 1
				return
			}
			// the last signal, remove the token and allow others to take the semaphore
			reEntryTokens[token] = nil
		}
		
		counter -= 1
		if updateWaiters.isEmpty || counter > allowedWorkers {
			return
		}
		let waiter = updateWaiters.removeFirst()
		waiter()
	}
}


