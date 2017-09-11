//
//  QBEvent.swift
//  QubitSDK
//
//  Created by Pavlo Davydiuk on 22/08/2017.
//  Copyright © 2017 Qubit. All rights reserved.
//

import Foundation

enum QBEventType: String {
    case session
    case view
    case other
    
    public init(type: String) {
        switch type {
        case "session":
            self = .session
            break
        case "View":
            self = .view
            break
        default:
            self = .other
        }
    }
}

struct QBEventEntity: Codable {
    let type: String
    let eventData: String
    
    var context: QBContextEntity?
    var meta: QBMetaEntity?
    var session: QBSessionEntity?
    
    init(type: String = "", eventData: String = "", context: QBContextEntity? = nil, meta: QBMetaEntity? = nil, session: QBSessionEntity? = nil) {
        self.type = type
        self.eventData = eventData
        self.context = context
        self.meta = meta
        self.session = session
    }
}

// MARK: - Bridges
extension QBEventEntity {
    func fillQBEvent(event: inout QBEvent, context: inout QBContextEvent, meta: inout QBMetaEvent) -> QBEvent {
        event.data = self.eventData
        event.type = self.type
        event.dateAdded = NSDate()
        event.context = self.context?.fillQBContextEvent(context: &context)
        event.meta = self.meta?.fillQBMetaEvent(meta: &meta)
        return event
    }
    
    static func create(with event: QBEvent) -> QBEventEntity? {
        guard let type = event.type, let context = event.context, let meta = event.meta else { return nil }
        guard let contextEntity = QBContextEntity.create(with: context), let metaEntity = QBMetaEntity.create(with: meta) else { return nil }
        let eventEntity = QBEventEntity(type: type, eventData: "", context: contextEntity, meta: metaEntity, session: nil)
        return eventEntity
    }
}

// MARK: - Helpers
extension QBEventEntity {
    static func getEnumEventType(fromString string: String) -> QBEventType {
        return QBEventType(type: string)
    }
}
