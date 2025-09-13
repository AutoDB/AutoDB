//
//  Relation.swift
//  AutoDB
//
//  Created by Olof Andersson-Thorén on 2025-03-10.
//

import Foundation

typealias AnyRelation = (any Relation)

/// to own a relation to one or many AutoModels we only need to be a sendable class.
public typealias Owner = AnyObject & Sendable

/// something handling a relation, one-to-one, one-to-many, or similar.
public protocol Relation: AnyObject, Equatable {
	func setOwner<OwnerType: Owner>(_ owner: OwnerType)
}

public protocol RelationOwner: Sendable {	
	func didChange() async
}
