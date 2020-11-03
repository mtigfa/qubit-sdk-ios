//
//  JSONQuibitSerialization.swift
//  QubitSDK
//
//  Created by Jacek Grygiel on 09/05/2018.
//  Copyright © 2018 Qubit. All rights reserved.
//

// swiftlint:disable all

import Foundation
import CoreFoundation

#if os(OSX) || os(iOS)
    import Darwin
#elseif os(Linux) || CYGWIN
    import Glibc
#endif

extension JSONQubitSerialization {
    public struct ReadingOptions: OptionSet {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        
        public static let mutableContainers = ReadingOptions(rawValue: 1 << 0)
        public static let mutableLeaves = ReadingOptions(rawValue: 1 << 1)
        public static let allowFragments = ReadingOptions(rawValue: 1 << 2)
    }
    
    public struct WritingOptions: OptionSet {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        
        public static let prettyPrinted = WritingOptions(rawValue: 1 << 0)
    }
}

open class JSONQubitSerialization: NSObject {

    open class func isValidJSONObject(_ obj: Any) -> Bool {
        // TODO: - revisit this once bridging story gets fully figured out
        func isValidJSONObjectInternal(_ obj: Any) -> Bool {
            // object is Swift.String, NSNull, Int, Bool, or UInt
            if obj is String || obj is NSNull || obj is Int || obj is Bool || obj is UInt {
                return true
            }
            
            // object is a Double and is not NaN or infinity
            if let number = obj as? Double {
                return number.isFinite
            }
            // object is a Float and is not NaN or infinity
            if let number = obj as? Float {
                return number.isFinite
            }
            
            // object is Swift.Array
            if let array = obj as? [Any] {
                for element in array {
                    guard isValidJSONObjectInternal(element) else {
                        return false
                    }
                }
                return true
            }
            
            // object is Swift.Dictionary
            if let dictionary = obj as? [String: Any] {
                for (_, value) in dictionary {
                    guard isValidJSONObjectInternal(value) else {
                        return false
                    }
                }
                return true
            }
            
            // object is NSNumber and is not NaN or infinity
            // For better performance, this (most expensive) test should be last.
            if let number = qb_SwiftValue.store(obj) as? NSNumber {
                let invalid = number.doubleValue.isInfinite || number.doubleValue.isNaN
                return !invalid
            }
            
            // invalid object
            return false
        }
        
        // top level object must be an Swift.Array or Swift.Dictionary
        guard obj is [Any] || obj is [String: Any] else {
            return false
        }
        
        return isValidJSONObjectInternal(obj)
    }
    
    internal class func qb_data(withJSONObject value: Any, options opt: WritingOptions, stream: Bool) throws -> Data {
        var jsonStr = String()
        
        var writer = JSONWriter(
            pretty: opt.contains(.prettyPrinted),
            writer: { (str: String?) in
                if let str = str {
                    jsonStr.append(str)
                }
        }
        )
        
        if let container = value as? NSArray {
            try writer.serializeJSON(container.qb_bridgeToSwift())
        } else if let container = value as? NSDictionary {
            try writer.serializeJSON(container.qb_bridgeToSwift())
        } else if let container = value as? Array<Any> {
            try writer.serializeJSON(container)
        } else if let container = value as? Dictionary<AnyHashable, Any> {
            try writer.serializeJSON(container)
        } else {
            fatalError("Top-level object was not NSArray or NSDictionary") // This is a fatal error in objective-c too (it is an NSInvalidArgumentException)
        }
        
        let count = jsonStr.lengthOfBytes(using: .utf8)
        let bufferLength = count+1 // Allow space for null terminator
        var utf8: [CChar] = Array<CChar>(repeating: 0, count: bufferLength)
        if !jsonStr.getCString(&utf8, maxLength: bufferLength, encoding: .utf8) {
            fatalError("Failed to generate a CString from a String")
        }
        let rawBytes = UnsafeRawPointer(UnsafePointer(utf8))
        let result = Data(bytes: rawBytes.bindMemory(to: UInt8.self, capacity: count), count: count)
        return result
    }
    
    open class func data(withJSONObject value: Any, options opt: WritingOptions = []) throws -> Data {
        return try qb_data(withJSONObject: value, options: opt, stream: false)
    }
}

//MARK: - JSONSerializer
private struct JSONWriter {
    
    var indent = 0
    let pretty: Bool
    let writer: (String?) -> Void
    
    private lazy var _numberformatter: CFNumberFormatter = {
        let formatter: CFNumberFormatter
        formatter = CFNumberFormatterCreate(nil, CFLocaleCopyCurrent(), CFNumberFormatterStyle.noStyle)
        // Decimals should always be 2dp
        CFNumberFormatterSetProperty(formatter, CFNumberFormatterKey.maxFractionDigits, NSNumber(value: 2))
        //[SR-6631] https://bugs.swift.org/browse/SR-6631
        CFNumberFormatterSetProperty(formatter, CFNumberFormatterKey.decimalSeparator, ".".qb_cfObject)
        CFNumberFormatterSetFormat(formatter, "0.##".qb_cfObject)
        return formatter
    }()
    
    init(pretty: Bool = false, writer: @escaping (String?) -> Void) {
        self.pretty = pretty
        self.writer = writer
    }
    
    mutating func serializeJSON(_ obj: Any) throws {
        
        // For better performance, the most expensive conditions to evaluate should be last.
        switch (obj) {
        case let str as String:
            try serializeString(str)
        case let number as NSNumber:
            if isBoolNumber(num: number) {
                serializeBool(number)
            }
            else {
                try serializeNumber(number)
            }
        case let boolValue as Bool:
            serializeBool(boolValue)
        case let array as Array<Any>:
            try serializeArray(array)
        case let dict as Dictionary<AnyHashable, Any>:
            try serializeDictionary(dict)
        case let null as NSNull:
            try serializeNull(null)
        case _ where qb_SwiftValue.store(obj) is NSNumber:
            try serializeNumber(qb_SwiftValue.store(obj) as! NSNumber)
        default:
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.propertyListReadCorrupt.rawValue, userInfo: ["NSDebugDescription" : "Invalid object cannot be serialized"])
        }
    }
    
    func isBoolNumber(num:NSNumber) -> Bool
    {
        let boolID = CFBooleanGetTypeID() // the type ID of CFBoolean
        let numID = CFGetTypeID(num) // the type ID of num
        return numID == boolID
    }
    
    func serializeString(_ str: String) throws {
        writer("\"")
        for scalar in str.prefix(256).unicodeScalars { // limit to 256 characters
            switch scalar {
            case "\"":
                writer("\\\"") // U+0022 quotation mark
            case "\\":
                writer("\\\\") // U+005C reverse solidus
            // U+002F solidus not escaped
            case "\u{8}":
                writer("\\b") // U+0008 backspace
            case "\u{c}":
                writer("\\f") // U+000C form feed
            case "\n":
                writer("\\n") // U+000A line feed
            case "\r":
                writer("\\r") // U+000D carriage return
            case "\t":
                writer("\\t") // U+0009 tab
            case "\u{0}"..."\u{f}":
                writer("\\u000\(String(scalar.value, radix: 16))") // U+0000 to U+000F
            case "\u{10}"..."\u{1f}":
                writer("\\u00\(String(scalar.value, radix: 16))") // U+0010 to U+001F
            default:
                writer(String(scalar))
            }
        }
        writer("\"")
    }
    
    func serializeBool(_ bool: Bool) {
        switch bool {
        case true:
            writer("true")
        case false:
            writer("false")
        }
    }
    
    func serializeBool(_ number: NSNumber) {
        number == 1 ? writer("true") : writer("false")
    }
    
    mutating func serializeNumber(_ num: NSNumber) throws {
        if num.doubleValue.isInfinite || num.doubleValue.isNaN {
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.propertyListReadCorrupt.rawValue, userInfo: ["NSDebugDescription" : "Number cannot be infinity or NaN"])
        }
        
       
//        switch num._objCType {
//        case .Bool:
//            serializeBool(num.boolValue)
//        default:
            writer(_serializationString(for: num))
//        }
    }
    
    mutating func serializeArray(_ array: [Any]) throws {
        writer("[")
        if pretty {
            writer("\n")
            incAndWriteIndent()
        }
        
        var first = true
        for elem in array.prefix(10) { // take first 10 only
            if first {
                first = false
            } else if pretty {
                writer(",\n")
                writeIndent()
            } else {
                writer(",")
            }
            try serializeJSON(elem)
        }
        if pretty {
            writer("\n")
            decAndWriteIndent()
        }
        writer("]")
    }
    
    mutating func serializeDictionary(_ dict: Dictionary<AnyHashable, Any>) throws {
        writer("{")
        if pretty {
            writer("\n")
            incAndWriteIndent()
        }
        
        var first = true
        
        for (key, value) in dict {
            if first {
                first = false
            } else if pretty {
                writer(",\n")
                writeIndent()
            } else {
                writer(",")
            }
            
            if key is String {
                try serializeString(key as! String)
            } else {
                throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.propertyListReadCorrupt.rawValue, userInfo: ["NSDebugDescription" : "NSDictionary key must be NSString"])
            }
            pretty ? writer(": ") : writer(":")
            try serializeJSON(value)
        }
        if pretty {
            writer("\n")
            decAndWriteIndent()
        }
        writer("}")
    }
    
    func serializeNull(_ null: NSNull) throws {
        writer("null")
    }
    
    let indentAmount = 2
    
    mutating func incAndWriteIndent() {
        indent += indentAmount
        writeIndent()
    }
    
    mutating func decAndWriteIndent() {
        indent -= indentAmount
        writeIndent()
    }
    
    func writeIndent() {
        for _ in 0..<indent {
            writer(" ")
        }
    }
    
    //[SR-2151] https://bugs.swift.org/browse/SR-2151
    private mutating func _serializationString(for number: NSNumber) -> String {
        return (CFNumberFormatterCreateStringWithNumber(nil, _numberformatter, number.qb_cfObject) as String).qb_swiftObject
    }
}

// MARK: - JSONDeserializer

private struct JSONReader {
    
    static let whitespaceASCII: [UInt8] = [
        0x09, // Horizontal tab
        0x0A, // Line feed or New line
        0x0D, // Carriage return
        0x20, // Space
    ]
    
    struct Structure {
        static let BeginArray: UInt8     = 0x5B // [
        static let EndArray: UInt8       = 0x5D // ]
        static let BeginObject: UInt8    = 0x7B // {
        static let EndObject: UInt8      = 0x7D // }
        static let NameSeparator: UInt8  = 0x3A // :
        static let ValueSeparator: UInt8 = 0x2C // ,
        static let QuotationMark: UInt8  = 0x22 // "
        static let Escape: UInt8         = 0x5C // \
    }
    
    typealias Index = Int
    typealias IndexDistance = Int
    
    struct UnicodeSource {
        let buffer: UnsafeBufferPointer<UInt8>
        let encoding: String.Encoding
        let step: Int
        
        init(buffer: UnsafeBufferPointer<UInt8>, encoding: String.Encoding) {
            self.buffer = buffer
            self.encoding = encoding
            
            self.step = {
                switch encoding {
                case String.Encoding.utf8:
                    return 1
                case String.Encoding.utf16BigEndian, String.Encoding.utf16LittleEndian:
                    return 2
                case String.Encoding.utf32BigEndian, String.Encoding.utf32LittleEndian:
                    return 4
                default:
                    return 1
                }
            }()
        }
        
        func takeASCII(_ input: Index) -> (UInt8, Index)? {
            guard hasNext(input) else {
                return nil
            }
            
            let index: Int
            switch encoding {
            case String.Encoding.utf8:
                index = input
            case String.Encoding.utf16BigEndian where buffer[input] == 0:
                index = input + 1
            case String.Encoding.utf32BigEndian where buffer[input] == 0 && buffer[input+1] == 0 && buffer[input+2] == 0:
                index = input + 3
            case String.Encoding.utf16LittleEndian where buffer[input+1] == 0:
                index = input
            case String.Encoding.utf32LittleEndian where buffer[input+1] == 0 && buffer[input+2] == 0 && buffer[input+3] == 0:
                index = input
            default:
                return nil
            }
            return (buffer[index] < 0x80) ? (buffer[index], input + step) : nil
        }
        
        func takeString(_ begin: Index, end: Index) throws -> String {
            let byteLength = begin.distance(to: end)
            
            guard let chunk = String(data: Data(bytes: buffer.baseAddress!.advanced(by: begin), count: byteLength), encoding: encoding) else {
                throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.propertyListReadCorrupt.rawValue, userInfo: [
                    "NSDebugDescription" : "Unable to convert data to a string using the detected encoding. The data may be corrupt."
                    ])
            }
            return chunk
        }
        
        func hasNext(_ input: Index) -> Bool {
            return input + step <= buffer.endIndex
        }
        
        func distanceFromStart(_ index: Index) -> IndexDistance {
            return buffer.startIndex.distance(to: index) / step
        }
    }
    
    let source: UnicodeSource
    
    func consumeWhitespace(_ input: Index) -> Index? {
        var index = input
        while let (char, nextIndex) = source.takeASCII(index), JSONReader.whitespaceASCII.contains(char) {
            index = nextIndex
        }
        return index
    }
    
    func consumeStructure(_ ascii: UInt8, input: Index) throws -> Index? {
        return try consumeWhitespace(input).flatMap(consumeASCII(ascii)).flatMap(consumeWhitespace)
    }
    
    func consumeASCII(_ ascii: UInt8) -> (Index) throws -> Index? {
        return { (input: Index) throws -> Index? in
            switch self.source.takeASCII(input) {
            case .none:
                throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.propertyListReadCorrupt.rawValue, userInfo: [
                    "NSDebugDescription" : "Unexpected end of file during JSON parse."
                    ])
            case let (taken, index)? where taken == ascii:
                return index
            default:
                return nil
            }
        }
    }
    
    func consumeASCIISequence(_ sequence: String, input: Index) throws -> Index? {
        var index = input
        for scalar in sequence.unicodeScalars {
            guard let nextIndex = try consumeASCII(UInt8(scalar.value))(index) else {
                return nil
            }
            index = nextIndex
        }
        return index
    }
    
    func takeMatching(_ match: @escaping (UInt8) -> Bool) -> ([Character], Index) -> ([Character], Index)? {
        return { input, index in
            guard let (byte, index) = self.source.takeASCII(index), match(byte) else {
                return nil
            }
            return (input + [Character(UnicodeScalar(byte))], index)
        }
    }
    
    //MARK: - String Parsing
    
    func parseString(_ input: Index) throws -> (String, Index)? {
        guard let beginIndex = try consumeWhitespace(input).flatMap(consumeASCII(Structure.QuotationMark)) else {
            return nil
        }
        var chunkIndex: Int = beginIndex
        var currentIndex: Int = chunkIndex
        
        var output: String = ""
        while source.hasNext(currentIndex) {
            guard let (ascii, index) = source.takeASCII(currentIndex) else {
                currentIndex += source.step
                continue
            }
            switch ascii {
            case Structure.QuotationMark:
                output += try source.takeString(chunkIndex, end: currentIndex)
                return (output, index)
            case Structure.Escape:
                output += try source.takeString(chunkIndex, end: currentIndex)
                if let (escaped, nextIndex) = try parseEscapeSequence(index) {
                    output += escaped
                    chunkIndex = nextIndex
                    currentIndex = nextIndex
                    continue
                }
                else {
                    throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.propertyListReadCorrupt.rawValue, userInfo: [
                        "NSDebugDescription" : "Invalid escape sequence at position \(source.distanceFromStart(currentIndex))"
                        ])
                }
            default:
                currentIndex = index
            }
        }
        throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.propertyListReadCorrupt.rawValue, userInfo: [
            "NSDebugDescription" : "Unexpected end of file during string parse."
            ])
    }
    
    func parseEscapeSequence(_ input: Index) throws -> (String, Index)? {
        guard let (byte, index) = source.takeASCII(input) else {
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.propertyListReadCorrupt.rawValue, userInfo: [
                "NSDebugDescription" : "Early end of unicode escape sequence around character"
                ])
        }
        let output: String
        switch byte {
        case 0x22: output = "\""
        case 0x5C: output = "\\"
        case 0x2F: output = "/"
        case 0x62: output = "\u{08}" // \b
        case 0x66: output = "\u{0C}" // \f
        case 0x6E: output = "\u{0A}" // \n
        case 0x72: output = "\u{0D}" // \r
        case 0x74: output = "\u{09}" // \t
        case 0x75: return try parseUnicodeSequence(index)
        default: return nil
        }
        return (output, index)
    }
    
    func parseUnicodeSequence(_ input: Index) throws -> (String, Index)? {
        
        guard let (codeUnit, index) = parseCodeUnit(input) else {
            return nil
        }
        
        if !UTF16.isLeadSurrogate(codeUnit) {
            return (String(UnicodeScalar(codeUnit)!), index)
        }
        
        guard let (trailCodeUnit, finalIndex) = try consumeASCIISequence("\\u", input: index).flatMap(parseCodeUnit) , UTF16.isTrailSurrogate(trailCodeUnit) else {
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.propertyListReadCorrupt.rawValue, userInfo: [
                "NSDebugDescription" : "Unable to convert unicode escape sequence (no low-surrogate code point) to UTF8-encoded character at position \(source.distanceFromStart(input))"
                ])
        }
        
        let highValue = (UInt32(codeUnit  - 0xD800) << 10)
        let lowValue  =  UInt32(trailCodeUnit - 0xDC00)
        return (String(UnicodeScalar(highValue + lowValue + 0x10000)!), finalIndex)
    }
    
    func isHexChr(_ byte: UInt8) -> Bool {
        return (byte >= 0x30 && byte <= 0x39)
            || (byte >= 0x41 && byte <= 0x46)
            || (byte >= 0x61 && byte <= 0x66)
    }
    func parseCodeUnit(_ input: Index) -> (UTF16.CodeUnit, Index)? {
        let hexParser = takeMatching(isHexChr)
        guard let (result, index) = hexParser([], input).flatMap(hexParser).flatMap(hexParser).flatMap(hexParser),
            let value = Int(String(result), radix: 16) else {
                return nil
        }
        return (UTF16.CodeUnit(value), index)
    }
    
    //MARK: - Number parsing
    static let numberCodePoints: [UInt8] = [
        0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, // 0...9
        0x2E, 0x2D, 0x2B, 0x45, 0x65, // . - + E e
    ]
    func parseNumber(_ input: Index) throws -> (Any, Index)? {
        func parseTypedNumber(_ address: UnsafePointer<UInt8>, count: Int) -> (Any, IndexDistance)? {
            let temp_buffer_size = 64
            var temp_buffer = [Int8](repeating: 0, count: temp_buffer_size)
            return temp_buffer.withUnsafeMutableBufferPointer { (buffer: inout UnsafeMutableBufferPointer<Int8>) -> (Any, IndexDistance)? in
                memcpy(buffer.baseAddress!, address, min(count, temp_buffer_size - 1)) // ensure null termination
                
                let startPointer = buffer.baseAddress!
                let intEndPointer = UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>.allocate(capacity: 1)
                defer { intEndPointer.deallocate() }
                let doubleEndPointer = UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>.allocate(capacity: 1)
                defer { doubleEndPointer.deallocate() }
                
                let intResult = strtol(startPointer, intEndPointer, 10)
                let intDistance = startPointer.distance(to: intEndPointer[0]!)
                let doubleResult = strtod(startPointer, doubleEndPointer)
                let doubleDistance = startPointer.distance(to: doubleEndPointer[0]!)
                
                guard intDistance > 0 || doubleDistance > 0 else {
                    return nil
                }
                
                if intDistance == doubleDistance {
                    return (intResult, intDistance)
                }
                guard doubleDistance > 0 else {
                    return nil
                }
                return (doubleResult, doubleDistance)
            }
        }
        
        if source.encoding == String.Encoding.utf8 {
            
            return parseTypedNumber(source.buffer.baseAddress!.advanced(by: input), count: source.buffer.count - input).map { return ($0.0, input + $0.1) }
        }
        else {
            var numberCharacters = [UInt8]()
            var index = input
            while let (ascii, nextIndex) = source.takeASCII(index), JSONReader.numberCodePoints.contains(ascii) {
                numberCharacters.append(ascii)
                index = nextIndex
            }
            
            numberCharacters.append(0)
            
            return numberCharacters.withUnsafeBufferPointer {
                parseTypedNumber($0.baseAddress!, count: $0.count)
                }.map { return ($0.0, index) }
        }
    }
    
    //MARK: - Value parsing
    func parseValue(_ input: Index) throws -> (Any, Index)? {
        if let (value, parser) = try parseString(input) {
            return (value, parser)
        }
        else if let parser = try consumeASCIISequence("true", input: input) {
            return (true, parser)
        }
        else if let parser = try consumeASCIISequence("false", input: input) {
            return (false, parser)
        }
        else if let parser = try consumeASCIISequence("null", input: input) {
            return (NSNull(), parser)
        }
        else if let (object, parser) = try parseObject(input) {
            return (object, parser)
        }
        else if let (array, parser) = try parseArray(input) {
            return (array, parser)
        }
        else if let (number, parser) = try parseNumber(input) {
            return (number, parser)
        }
        return nil
    }
    
    //MARK: - Object parsing
    func parseObject(_ input: Index) throws -> ([String: Any], Index)? {
        guard let beginIndex = try consumeStructure(Structure.BeginObject, input: input) else {
            return nil
        }
        var index = beginIndex
        var output: [String: Any] = [:]
        while true {
            if let finalIndex = try consumeStructure(Structure.EndObject, input: index) {
                return (output, finalIndex)
            }
            
            if let (key, value, nextIndex) = try parseObjectMember(index) {
                output[key] = value
                
                if let finalParser = try consumeStructure(Structure.EndObject, input: nextIndex) {
                    return (output, finalParser)
                }
                else if let nextIndex = try consumeStructure(Structure.ValueSeparator, input: nextIndex) {
                    index = nextIndex
                    continue
                }
                else {
                    return nil
                }
            }
            return nil
        }
    }
    
    func parseObjectMember(_ input: Index) throws -> (String, Any, Index)? {
        guard let (name, index) = try parseString(input) else {
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.propertyListReadCorrupt.rawValue, userInfo: [
                "NSDebugDescription" : "Missing object key at location \(source.distanceFromStart(input))"
                ])
        }
        guard let separatorIndex = try consumeStructure(Structure.NameSeparator, input: index) else {
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.propertyListReadCorrupt.rawValue, userInfo: [
                "NSDebugDescription" : "Invalid separator at location \(source.distanceFromStart(index))"
                ])
        }
        guard let (value, finalIndex) = try parseValue(separatorIndex) else {
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.propertyListReadCorrupt.rawValue, userInfo: [
                "NSDebugDescription" : "Invalid value at location \(source.distanceFromStart(separatorIndex))"
                ])
        }
        
        return (name, value, finalIndex)
    }
    
    //MARK: - Array parsing
    func parseArray(_ input: Index) throws -> ([Any], Index)? {
        guard let beginIndex = try consumeStructure(Structure.BeginArray, input: input) else {
            return nil
        }
        var index = beginIndex
        var output: [Any] = []
        while true {
            if let finalIndex = try consumeStructure(Structure.EndArray, input: index) {
                return (output, finalIndex)
            }
            
            if let (value, nextIndex) = try parseValue(index) {
                output.append(value)
                
                if let finalIndex = try consumeStructure(Structure.EndArray, input: nextIndex) {
                    return (output, finalIndex)
                }
                else if let nextIndex = try consumeStructure(Structure.ValueSeparator, input: nextIndex) {
                    index = nextIndex
                    continue
                }
            }
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.propertyListReadCorrupt.rawValue, userInfo: [
                "NSDebugDescription" : "Badly formed array at location \(source.distanceFromStart(index))"
                ])
        }
    }
}

//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2016 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

// Support protocols for casting
protocol qb_ObjectBridgeable {
    func qb_bridgeToAnyObject() -> AnyObject
}

protocol qb_StructBridgeable {
    func qb_bridgeToAny() -> Any
}

/// - Note: This is a similar interface to the _ObjectiveCBridgeable protocol
protocol qb_ObjectTypeBridgeable : qb_ObjectBridgeable {
    associatedtype qb_ObjectType : AnyObject
    
    func qb_bridgeToObjectiveC() -> qb_ObjectType
    
    static func qb_forceBridgeFromObjectiveC(_ source: qb_ObjectType, result: inout Self?)
    
    @discardableResult
    static func qb_conditionallyBridgeFromObjectiveC(_ source: qb_ObjectType, result: inout Self?) -> Bool
    
    static func qb_unconditionallyBridgeFromObjectiveC(_ source: qb_ObjectType?) -> Self
}

/// - Note: This does not exist currently on Darwin but it is the inverse correlation to the bridge types such that a
/// reference type can be converted via a callout to a conversion method.
protocol qb_StructTypeBridgeable : qb_StructBridgeable {
    associatedtype qb_StructType
    
    func qb_bridgeToSwift() -> qb_StructType
}

// Default adoption of the type specific variants to the Any variant
extension qb_ObjectTypeBridgeable {
    func qb_bridgeToAnyObject() -> AnyObject {
        return qb_bridgeToObjectiveC()
    }
}

extension qb_StructTypeBridgeable {
    func qb_bridgeToAny() -> Any {
        return qb_bridgeToSwift()
    }
}

// slated for removal, these are the swift-corelibs-only variant of the _ObjectiveCBridgeable
internal protocol qb_CFBridgeable {
    associatedtype CFType
    var qb_cfObject: CFType { get }
}

extension NSNumber {
    typealias CFType = CFNumber
    // This layout MUST be the same as CFNumber so that they are bridgeable
    internal var qb_cfObject: CFType {
        return unsafeBitCast(self, to: CFType.self)
    }
}
internal protocol qb_SwiftBridgeable {
    associatedtype SwiftType
    var qb_swiftObject: SwiftType { get }
}

internal protocol qb_NSBridgeable {
    associatedtype NSType
    var qb_nsObject: NSType { get }
}


/// - Note: This is an internal boxing value for containing abstract structures
internal final class qb_SwiftValue : NSObject, NSCopying {
    internal private(set) var value: Any
    
    static func fetch(_ object: AnyObject?) -> Any? {
        if let obj = object {
            return fetch(nonOptional: obj)
        }
        return nil
    }
    
    static func fetch(nonOptional object: AnyObject) -> Any {
        if let container = object as? qb_SwiftValue {
            return container.value
        } else if let val = object as? qb_StructBridgeable {
            return val.qb_bridgeToAny()
        } else {
            return object
        }
    }
    
    static func store(_ value: Any?) -> NSObject? {
        if let val = value {
            return store(val)
        }
        return nil
    }
    
    static func store(_ value: Any) -> NSObject {
        if let val = value as? NSObject {
            return val
        } else if let val = value as? qb_ObjectBridgeable {
            return val.qb_bridgeToAnyObject() as! NSObject
        } else {
            return qb_SwiftValue(value)
        }
    }
    
    init(_ value: Any) {
        self.value = value
    }
    
    override var hash: Int {
        if let hashable = value as? AnyHashable {
            return hashable.hashValue
        }
        return ObjectIdentifier(self).hashValue
    }
    
    override func isEqual(_ value: Any?) -> Bool {
        if let other = value as? qb_SwiftValue {
            if self === other {
                return true
            }
            if let otherHashable = other.value as? AnyHashable,
                let hashable = self.value as? AnyHashable {
                return otherHashable == hashable
            }
            
        } else if let otherHashable = value as? AnyHashable,
            let hashable = self.value as? AnyHashable {
            return otherHashable == hashable
        }
        return false
    }
    
    func copy(with zone: NSZone?) -> Any {
        return qb_SwiftValue(value)
    }
}


extension NSArray : qb_StructTypeBridgeable {
    typealias qb_StructType = Array<Any>
    
    func qb_bridgeToSwift() -> qb_StructType {
        return qb_StructType._unconditionallyBridgeFromObjectiveC(self)
    }
}

extension NSDictionary : qb_StructTypeBridgeable {
    typealias qb_StructType = Dictionary<AnyHashable,Any>
    
    func qb_bridgeToSwift() -> qb_StructType {
        return qb_StructType._unconditionallyBridgeFromObjectiveC(self)
    }
}

extension NSString : qb_CFBridgeable, qb_SwiftBridgeable {
    typealias SwiftType = String
    internal var qb_cfObject: CFString { return unsafeBitCast(self, to: CFString.self) }
    internal var qb_swiftObject: String { return String._unconditionallyBridgeFromObjectiveC(self) }
}

extension Bool : qb_CFBridgeable {
    typealias CFType = CFBoolean
    var qb_cfObject: CFType {
        return self ? kCFBooleanTrue : kCFBooleanFalse
    }
}

// swiftlint:enable all
