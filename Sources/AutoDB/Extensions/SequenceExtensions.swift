//
//  SequenceExtensions.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2025-04-18.
//

public extension Sequence where Element: Hashable {
	func set() -> Set<Element> {
		Set(self)
	}
}
