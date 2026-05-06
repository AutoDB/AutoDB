//
//  TaskPorts.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2026-05-06.
//

extension Task where Failure == Never {
    
    /// On apple platforms of 26 and forward: Create and immediately start running a new detached task in the context of the calling thread/task.
    /// TaskExecutor is also 26, so no point in trying to backport the whole signature
    @inline(__always) @discardableResult
    public static func immediatePort(name: String? = nil, priority: TaskPriority? = nil, operation: sending @escaping @isolated(any) () async -> Success) -> Task<Success, Never> {
        if #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, *) {
            immediate(name: name, priority: priority, operation: operation)
        } else {
            Self(name: name, priority: priority, operation: operation)
        }
    }
}
