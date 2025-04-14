//
//  CharacterSet+Extension.swift
//  GoogleCloudLogging
//
//  Created by Alexandru Solomon on 14.04.2025.
//

import Foundation

extension CharacterSet {
  static let asciiDigits = CharacterSet(charactersIn: "0" ... "9")

  static let uppercaseLatinAlphabet = CharacterSet(charactersIn: "A" ... "Z")

  static let lowercaseLatinAlphabet = CharacterSet(charactersIn: "a" ... "z")

  static let logIdSymbols = CharacterSet(charactersIn: "-._")
    .union(.asciiDigits)
    .union(.uppercaseLatinAlphabet)
    .union(.lowercaseLatinAlphabet)
}
