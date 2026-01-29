//
//  CappedArray.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import Foundation

enum CappedArray {
    static func append<Element>(_ element: Element, to array: inout [Element], max: Int) {
        array.append(element)
        guard array.count > max else { return }
        array.removeFirst(array.count - max)
    }
}
