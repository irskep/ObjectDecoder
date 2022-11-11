// Copyright (c) 2022 Asana, Inc.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import UIKit

/**
 "Decode" an already-parsed JSON object (dict, array, etc) into a Swift Decodable
 type. Includes special cases for the output of NSJSONSerialization.
 */
open class ObjectDecoder {
  public init() {}

  // decode() takes an Any? instead of an Any because casting `Any? as Any`
  // will make subsequent tests for `== nil` spuriously fail if the value was
  // initially nil.
  //
  // ```
  // let x: Any? = nil
  // let y = x as Any
  // let z: Any? = y // The value of z is Optional<Optional.none>, but the Swift compiler won't admit it
  // print(z == nil) // false 😭
  // ```
  //
  public func decode<T: Decodable>(_ type: T.Type, from object: Any?) throws -> T {
    assert(T.self != URL.self, "URL has special cases in JSON decoding. You should use the URL(string:) initializer instead.")
    return try type.init(from: UntypedDecoder(value: object, codingPath: []))
  }

  public static func decode<T: Decodable>(_ type: T.Type, from anything: Any?) throws -> T? {
    try ObjectDecoder().decode(T.self, from: anything)
  }
}

public enum ObjectDecoderError: Error {
  case arrayOverrun
  case couldNotParseURL(codingPath: [CodingKey], String)
  case notSupported
  case outerObjectMustBeDict
  case wrongKeyType
  case wrongType(codingPath: [CodingKey], value: Any?)
}

// MARK: Implementation

/// Handle various edge cases related to recursing into other Decodable
/// implementations. The most important one is URLs; JSONDecoder special-cases
/// URLs to have them parse directly from strings.
/// https://github.com/apple/swift/blob/e7cd5ab/stdlib/public/Darwin/Foundation/JSONEncoder.swift#L909
private func decodeDecodableWithSpecialUnwraps<T>(_ type: T.Type, codingPath: [CodingKey], untypedValue: Any?) throws -> T
  where T: Decodable {
  if type == URL.self {
    if let stringValue = untypedValue as? String {
      if let url = URL(string: stringValue) {
        return url as! T // we checked the type above
      } else {
        throw ObjectDecoderError.couldNotParseURL(codingPath: codingPath, stringValue)
      }
    } else if let objectValue = untypedValue as? [String: Any] {
      return try T(from: UntypedDecoder(value: objectValue, codingPath: codingPath))
    } else {
      throw ObjectDecoderError.wrongType(codingPath: codingPath, value: untypedValue)
    }
  } else {
    return try T(from: UntypedDecoder(value: untypedValue, codingPath: codingPath))
  }
}

/**
 Decoder of objects whose type we don't know yet. Will try to cast to the
 appropriate container type, or throw an error if the type doesn't match.
 */
private struct UntypedDecoder: Decoder {
  public let codingPath: [CodingKey]
  public let userInfo: [CodingUserInfoKey: Any] = [:]

  private let value: Any?

  public init(value: Any?, codingPath: [CodingKey]) {
    self.value = value
    self.codingPath = codingPath
  }

  public func container<Key>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> where Key: CodingKey {
    if let val = value as? [String: Any?] {
      return KeyedDecodingContainer(DictKeyedByStringsContainer<Key>(dict: val, codingPath: codingPath))
    } else if let val = value as? [Int: Any?] {
      return KeyedDecodingContainer(DictKeyedByIntsContainer<Key>(dict: val, codingPath: codingPath))
    } else {
      throw ObjectDecoderError.wrongType(codingPath: codingPath, value: value)
    }
  }

  public func unkeyedContainer() throws -> UnkeyedDecodingContainer {
    if let val = value as? [Any?] {
      return ArrayObjectContainer(array: val, codingPath: codingPath)
    } else {
      throw ObjectDecoderError.wrongType(codingPath: codingPath, value: value)
    }
  }

  public func singleValueContainer() throws -> SingleValueDecodingContainer {
    if let value = value {
      return SingleValueObjectContainer(value: value, codingPath: codingPath)
    } else {
      return NilValueObjectContainer(codingPath: codingPath)
    }
  }
}

/**
 Handle JSON-style objects. Keys are always strings.
 */
private struct DictKeyedByStringsContainer<K: CodingKey>: KeyedDecodingContainerProtocol {
  public typealias Key = K

  private let dict: [String: Any?]
  public let codingPath: [CodingKey]
  public var allKeys: [K] { dict.keys.compactMap { K(stringValue: $0) } }

  public init(dict: [String: Any?], codingPath: [CodingKey]) {
    self.dict = dict
    self.codingPath = codingPath
  }

  public func contains(_ key: K) -> Bool { dict.keys.contains(key.stringValue) && (dict[key.stringValue] as? NSNull) != NSNull() }

  public func decodeNil(forKey key: K) throws -> Bool {
    // The ! is safe because we check dict.keys.contains immediately before.
    // It's important to fully unwrap nested optionals before doing a nil check,
    // otherwise it will incorrectly evaluate as false.
    dict.keys.contains(key.stringValue) && dict[key.stringValue]! == nil
  }

  /**
   Decodes a simple type (Int, String, etc) by doing a type cast
   */
  private func decodeGeneric<T>(_ key: K) throws -> T {
    guard contains(key), let untypedValue = dict[key.stringValue] else {
      throw DecodingError.keyNotFound(
        key,
        DecodingError.Context(codingPath: codingPath + [key], debugDescription: String(describing: key)))
    }

    if let val = untypedValue as? T {
      return val
    } else if (untypedValue as? NSNull) == NSNull() {
      throw DecodingError.keyNotFound(
        key,
        DecodingError.Context(codingPath: codingPath + [key], debugDescription: String(describing: key)))
    } else {
      throw ObjectDecoderError.wrongType(codingPath: codingPath + [key], value: dict[key.stringValue] as Any?)
    }
  }

  public func decode(_ type: Bool.Type, forKey key: K) throws -> Bool { try decodeGeneric(key) }
  public func decode(_ type: String.Type, forKey key: K) throws -> String { try decodeGeneric(key) }
  public func decode(_ type: Double.Type, forKey key: K) throws -> Double { try decodeGeneric(key) }
  public func decode(_ type: Float.Type, forKey key: K) throws -> Float { try decodeGeneric(key) }
  public func decode(_ type: Int.Type, forKey key: K) throws -> Int { try decodeGeneric(key) }
  public func decode(_ type: Int8.Type, forKey key: K) throws -> Int8 { try decodeGeneric(key) }
  public func decode(_ type: Int16.Type, forKey key: K) throws -> Int16 { try decodeGeneric(key) }
  public func decode(_ type: Int32.Type, forKey key: K) throws -> Int32 { try decodeGeneric(key) }
  public func decode(_ type: Int64.Type, forKey key: K) throws -> Int64 { try decodeGeneric(key) }
  public func decode(_ type: UInt.Type, forKey key: K) throws -> UInt { try decodeGeneric(key) }
  public func decode(_ type: UInt8.Type, forKey key: K) throws -> UInt8 { try decodeGeneric(key) }
  public func decode(_ type: UInt16.Type, forKey key: K) throws -> UInt16 { try decodeGeneric(key) }
  public func decode(_ type: UInt32.Type, forKey key: K) throws -> UInt32 { try decodeGeneric(key) }
  public func decode(_ type: UInt64.Type, forKey key: K) throws -> UInt64 { try decodeGeneric(key) }

  public func decode<T>(_ type: T.Type, forKey key: K) throws -> T where T: Decodable {
    if let untypedValue = dict[key.stringValue] {
      return try decodeDecodableWithSpecialUnwraps(T.self, codingPath: codingPath + [key], untypedValue: untypedValue)
    } else {
      throw ObjectDecoderError.wrongType(codingPath: codingPath + [key], value: dict[key.stringValue] ?? nil)
    }
  }

  public func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type, forKey key: K) throws -> KeyedDecodingContainer<NestedKey>
    where NestedKey: CodingKey {
    if let value = dict[key.stringValue] {
      return try UntypedDecoder(value: value, codingPath: codingPath + [key]).container(keyedBy: NestedKey.self)
    } else {
      throw DecodingError.keyNotFound(
        key,
        DecodingError.Context(codingPath: codingPath + [key], debugDescription: key.stringValue))
    }
  }

  public func nestedUnkeyedContainer(forKey key: K) throws -> UnkeyedDecodingContainer {
    if let val = dict[key.stringValue] as? [Any?] {
      return ArrayObjectContainer(array: val, codingPath: codingPath + [key])
    } else {
      throw ObjectDecoderError.wrongType(codingPath: codingPath + [key], value: dict[key.stringValue] as Any?)
    }
  }

  // We currently have no use cases for superDecoder(), so none of the superDecoder()
  // methods are implemented.
  public func superDecoder() throws -> Decoder { throw ObjectDecoderError.notSupported }
  public func superDecoder(forKey key: K) throws -> Decoder { throw ObjectDecoderError.notSupported }
}

/// Identical to DictKeyedByStringsContainer except we use key.intValue instead
/// of key.stringValue. This is illegal in JSON but legal in Swift.
private struct DictKeyedByIntsContainer<K: CodingKey>: KeyedDecodingContainerProtocol {
  public typealias Key = K

  private let dict: [Int: Any?]
  public let codingPath: [CodingKey]
  public var allKeys: [K] { dict.keys.compactMap { K(intValue: $0) } }

  public init(dict: [Int: Any?], codingPath: [CodingKey]) {
    self.dict = dict
    self.codingPath = codingPath
  }

  public func contains(_ key: K) -> Bool {
    guard let intKey = key.intValue else { return false }
    return dict.keys.contains(intKey)
  }

  public func decodeNil(forKey key: K) throws -> Bool {
    guard let intKey = key.intValue else { throw ObjectDecoderError.wrongKeyType }
    return dict.keys.contains(intKey) && dict[intKey]! == nil
  }

  private func decodeGeneric<T>(_ key: K) throws -> T {
    guard let intKey = key.intValue else { throw ObjectDecoderError.wrongKeyType }
    if !contains(key) {
      throw DecodingError.keyNotFound(
        key,
        DecodingError.Context(codingPath: codingPath, debugDescription: String(describing: key)))
    }
    if let val = dict[intKey] as? T {
      return val
    } else {
      throw ObjectDecoderError.wrongType(codingPath: codingPath + [key], value: dict[intKey] ?? nil)
    }
  }

  public func decode(_ type: Bool.Type, forKey key: K) throws -> Bool { try decodeGeneric(key) }
  public func decode(_ type: String.Type, forKey key: K) throws -> String { try decodeGeneric(key) }
  public func decode(_ type: Double.Type, forKey key: K) throws -> Double { try decodeGeneric(key) }
  public func decode(_ type: Float.Type, forKey key: K) throws -> Float { try decodeGeneric(key) }
  public func decode(_ type: Int.Type, forKey key: K) throws -> Int { try decodeGeneric(key) }
  public func decode(_ type: Int8.Type, forKey key: K) throws -> Int8 { try decodeGeneric(key) }
  public func decode(_ type: Int16.Type, forKey key: K) throws -> Int16 { try decodeGeneric(key) }
  public func decode(_ type: Int32.Type, forKey key: K) throws -> Int32 { try decodeGeneric(key) }
  public func decode(_ type: Int64.Type, forKey key: K) throws -> Int64 { try decodeGeneric(key) }
  public func decode(_ type: UInt.Type, forKey key: K) throws -> UInt { try decodeGeneric(key) }
  public func decode(_ type: UInt8.Type, forKey key: K) throws -> UInt8 { try decodeGeneric(key) }
  public func decode(_ type: UInt16.Type, forKey key: K) throws -> UInt16 { try decodeGeneric(key) }
  public func decode(_ type: UInt32.Type, forKey key: K) throws -> UInt32 { try decodeGeneric(key) }
  public func decode(_ type: UInt64.Type, forKey key: K) throws -> UInt64 { try decodeGeneric(key) }

  public func decode<T>(_ type: T.Type, forKey key: K) throws -> T where T: Decodable {
    guard let intKey = key.intValue else { throw ObjectDecoderError.wrongKeyType }
    if let untypedValue = dict[intKey] {
      return try decodeDecodableWithSpecialUnwraps(T.self, codingPath: codingPath + [key], untypedValue: untypedValue)
    } else {
      throw ObjectDecoderError.wrongType(codingPath: codingPath + [key], value: dict[intKey] ?? nil)
    }
  }

  public func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type, forKey key: K) throws -> KeyedDecodingContainer<NestedKey>
    where NestedKey: CodingKey {
    guard let intKey = key.intValue else { throw ObjectDecoderError.wrongKeyType }
    if let value = dict[intKey] {
      return try UntypedDecoder(value: value, codingPath: codingPath + [key]).container(keyedBy: NestedKey.self)
    } else {
      throw ObjectDecoderError.wrongType(codingPath: codingPath + [key], value: dict[intKey] ?? nil)
    }
  }

  public func nestedUnkeyedContainer(forKey key: K) throws -> UnkeyedDecodingContainer {
    guard let intKey = key.intValue else { throw ObjectDecoderError.wrongKeyType }
    if let val = dict[intKey] as? [Any?] {
      return ArrayObjectContainer(array: val, codingPath: codingPath + [key])
    } else {
      throw ObjectDecoderError.wrongType(codingPath: codingPath + [key], value: dict[intKey] as Any?)
    }
  }

  public func superDecoder() throws -> Decoder { throw ObjectDecoderError.notSupported }
  public func superDecoder(forKey key: K) throws -> Decoder { throw ObjectDecoderError.notSupported }
}

/**
 Decode any non-nil single value by doing a simple type cast and throwing an error
 if it fails.

 It's possible to unify this with NilValueObjectContainer, but debugging ObjectDecoder
 is simpler when we guarantee an object's non-nil-ness at the container level.
 */
private struct SingleValueObjectContainer: SingleValueDecodingContainer {
  private let value: Any
  public let codingPath: [CodingKey]

  public init(value: Any, codingPath: [CodingKey]) {
    self.value = value
    self.codingPath = codingPath
  }

  private func decodeGeneric<T>() throws -> T {
    if let val = value as? T {
      return val
    } else {
      throw ObjectDecoderError.wrongType(codingPath: codingPath, value: value)
    }
  }

  public func decodeNil() -> Bool {
    false
  }

  public func decode(_ type: Bool.Type) throws -> Bool { try decodeGeneric() }
  public func decode(_ type: String.Type) throws -> String { try decodeGeneric() }
  public func decode(_ type: Double.Type) throws -> Double { try decodeGeneric() }
  public func decode(_ type: Float.Type) throws -> Float { try decodeGeneric() }
  public func decode(_ type: Int.Type) throws -> Int { try decodeGeneric() }
  public func decode(_ type: Int8.Type) throws -> Int8 { try decodeGeneric() }
  public func decode(_ type: Int16.Type) throws -> Int16 { try decodeGeneric() }
  public func decode(_ type: Int32.Type) throws -> Int32 { try decodeGeneric() }
  public func decode(_ type: Int64.Type) throws -> Int64 { try decodeGeneric() }
  public func decode(_ type: UInt.Type) throws -> UInt { try decodeGeneric() }
  public func decode(_ type: UInt8.Type) throws -> UInt8 { try decodeGeneric() }
  public func decode(_ type: UInt16.Type) throws -> UInt16 { try decodeGeneric() }
  public func decode(_ type: UInt32.Type) throws -> UInt32 { try decodeGeneric() }
  public func decode(_ type: UInt64.Type) throws -> UInt64 { try decodeGeneric() }

  public func decode<T>(_ type: T.Type) throws -> T where T: Decodable {
    try decodeDecodableWithSpecialUnwraps(T.self, codingPath: codingPath, untypedValue: value)
  }

  public func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey>
    where NestedKey: CodingKey {
    try UntypedDecoder(value: value, codingPath: codingPath).container(keyedBy: NestedKey.self)
  }

  public func superDecoder() throws -> Decoder { throw ObjectDecoderError.notSupported }
}

/**
 Throws errors on every method except the nil check
 */
private struct NilValueObjectContainer: SingleValueDecodingContainer {
  public let codingPath: [CodingKey]

  public init(codingPath: [CodingKey]) {
    self.codingPath = codingPath
  }

  public func decodeNil() -> Bool {
    true
  }

  public func decode(_ type: Bool.Type) throws -> Bool { throw ObjectDecoderError.notSupported }
  public func decode(_ type: String.Type) throws -> String { throw ObjectDecoderError.notSupported }
  public func decode(_ type: Double.Type) throws -> Double { throw ObjectDecoderError.notSupported }
  public func decode(_ type: Float.Type) throws -> Float { throw ObjectDecoderError.notSupported }
  public func decode(_ type: Int.Type) throws -> Int { throw ObjectDecoderError.notSupported }
  public func decode(_ type: Int8.Type) throws -> Int8 { throw ObjectDecoderError.notSupported }
  public func decode(_ type: Int16.Type) throws -> Int16 { throw ObjectDecoderError.notSupported }
  public func decode(_ type: Int32.Type) throws -> Int32 { throw ObjectDecoderError.notSupported }
  public func decode(_ type: Int64.Type) throws -> Int64 { throw ObjectDecoderError.notSupported }
  public func decode(_ type: UInt.Type) throws -> UInt { throw ObjectDecoderError.notSupported }
  public func decode(_ type: UInt8.Type) throws -> UInt8 { throw ObjectDecoderError.notSupported }
  public func decode(_ type: UInt16.Type) throws -> UInt16 { throw ObjectDecoderError.notSupported }
  public func decode(_ type: UInt32.Type) throws -> UInt32 { throw ObjectDecoderError.notSupported }
  public func decode(_ type: UInt64.Type) throws -> UInt64 { throw ObjectDecoderError.notSupported }
  public func decode<T>(_ type: T.Type) throws -> T where T: Decodable { throw ObjectDecoderError.notSupported }

  public func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey>
    where NestedKey: CodingKey {
    throw ObjectDecoderError.notSupported // I am nil!
  }

  public func superDecoder() throws -> Decoder { throw ObjectDecoderError.notSupported }
}

private struct ArrayObjectContainer: UnkeyedDecodingContainer {
  private let array: [Any?]
  public let codingPath: [CodingKey]

  public private(set) var currentIndex = 0

  public init(array: [Any?], codingPath: [CodingKey]) {
    self.array = array
    self.codingPath = codingPath
  }

  public var count: Int? { array.count }

  public var isAtEnd: Bool {
    currentIndex >= array.count
  }

  public mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
    throw ObjectDecoderError.notSupported
  }

  private mutating func decodeGeneric<T>() throws -> T {
    guard !isAtEnd else { throw ObjectDecoderError.arrayOverrun }
    if let value = array[currentIndex] as? T {
      currentIndex += 1
      return value
    } else {
      throw ObjectDecoderError.wrongType(codingPath: codingPath, value: array[currentIndex])
    }
  }

  public mutating func decodeNil() throws -> Bool {
    guard !isAtEnd else { throw ObjectDecoderError.arrayOverrun }
    if array[currentIndex] == nil {
      currentIndex += 1
      return true
    } else {
      return false
    }
  }

  public mutating func decode(_ type: Bool.Type) throws -> Bool { try decodeGeneric() }
  public mutating func decode(_ type: String.Type) throws -> String { try decodeGeneric() }
  public mutating func decode(_ type: Double.Type) throws -> Double { try decodeGeneric() }
  public mutating func decode(_ type: Float.Type) throws -> Float { try decodeGeneric() }
  public mutating func decode(_ type: Int.Type) throws -> Int { try decodeGeneric() }
  public mutating func decode(_ type: Int8.Type) throws -> Int8 { try decodeGeneric() }
  public mutating func decode(_ type: Int16.Type) throws -> Int16 { try decodeGeneric() }
  public mutating func decode(_ type: Int32.Type) throws -> Int32 { try decodeGeneric() }
  public mutating func decode(_ type: Int64.Type) throws -> Int64 { try decodeGeneric() }
  public mutating func decode(_ type: UInt.Type) throws -> UInt { try decodeGeneric() }
  public mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try decodeGeneric() }
  public mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try decodeGeneric() }
  public mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try decodeGeneric() }
  public mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try decodeGeneric() }

  public mutating func decode<T>(_ type: T.Type) throws -> T where T: Decodable {
    guard !isAtEnd else { throw ObjectDecoderError.arrayOverrun }
    let value = array[currentIndex]
    currentIndex += 1
    return try decodeDecodableWithSpecialUnwraps(T.self, codingPath: codingPath, untypedValue: value)
  }

  public mutating func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey>
    where NestedKey: CodingKey {
    guard !isAtEnd else { throw ObjectDecoderError.arrayOverrun }
    let value = array[currentIndex]
    currentIndex += 1
    return try UntypedDecoder(value: value, codingPath: codingPath).container(keyedBy: NestedKey.self)
  }

  public func superDecoder() throws -> Decoder {
    throw ObjectDecoderError.notSupported
  }
}