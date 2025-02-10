//
//  AwaitResource.swift
//  
//
//  Created by Olof Andersson-Thorén on 2022-12-06.
//

import Foundation

/**
 Await something that will be created in the future. A basic queue with a producer that sends resources, and consumers that awaits them.
 */
public actor AwaitResource<T: Sendable> {
	var updateWaiters = [(T) -> ()]()
    public init() {}
    
	/// await a resource that can never exists beforehand, e.g when building a queue.
	/// This will suspend work until someone wakes it by calling wakeOne() or sendResource()
    public func awaitResource() async -> T  {
		await withCheckedContinuation(isolation: self, { continuation in
            updateWaiters.append({ value in
                continuation.resume(returning: value)
            })
        })
    }
    
    /// wake all waiters and send them the resource, a nil resource ends loop
    public func sendResource(_ resource: T) {
        
        let waitersCopy = updateWaiters
        updateWaiters.removeAll()
        for waiter in waitersCopy {
            waiter(resource)
        }
    }
}
