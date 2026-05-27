//
//  AX25Fuzzer.swift
//  AXTermTests
//
//  A deterministic generative fuzzer for AX.25 frames.
//  Injects pathological bit flips, truncations, and invalid 
//  KISS escapes into a stream of frames.
//

import Foundation
@testable import AXTerm

struct AX25Fuzzer {
    var seed: UInt64
    private var rng: SplitMix64
    
    init(seed: UInt64 = 42) {
        self.seed = seed
        self.rng = SplitMix64(seed: seed)
    }
    
    /// Random number generator state
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { self.state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9e3779b97f4a7c15
            var z = state
            z = (z ^ (z &>> 30)) &* 0xbf58476d1ce4e5b9
            z = (z ^ (z &>> 27)) &* 0x94d049bb133111eb
            return z ^ (z &>> 31)
        }
    }
    
    mutating func nextDouble() -> Double {
        return Double(rng.next() >> 11) * (1.0 / 9007199254740992.0)
    }
    
    mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        let delta = UInt64(range.upperBound - range.lowerBound)
        let rand = rng.next() % (delta + 1)
        return range.lowerBound + Int(rand)
    }
    
    mutating func nextBytes(count: Int) -> Data {
        var data = Data(capacity: count)
        for _ in 0..<count {
            data.append(UInt8(rng.next() & 0xFF))
        }
        return data
    }
    
    // MARK: - Mutations
    
    mutating func mutate(frameData: Data) -> Data {
        var mutated = frameData
        guard !mutated.isEmpty else { return mutated }
        
        let mutationType = nextInt(in: 0...5)
        
        switch mutationType {
        case 0:
            // Bit flip
            let byteIdx = nextInt(in: 0...(mutated.count - 1))
            let bitIdx = nextInt(in: 0...7)
            mutated[byteIdx] ^= (1 << bitIdx)
            
        case 1:
            // Truncation
            let newLength = nextInt(in: 1...(mutated.count - 1))
            mutated = mutated.prefix(newLength)
            
        case 2:
            // Append garbage
            mutated.append(nextBytes(count: nextInt(in: 1...50)))
            
        case 3:
            // Control byte scramble (assuming standard AX.25 address length of 14)
            if mutated.count > 14 {
                mutated[14] = UInt8(rng.next() & 0xFF)
            }
            
        case 4:
            // Invalid KISS escape
            let kissFESC: UInt8 = 0xDB
            // Insert FESC without TFEND or TFESC
            let insertPos = nextInt(in: 0...(mutated.count - 1))
            mutated.insert(kissFESC, at: insertPos)
            mutated.insert(0x00, at: insertPos + 1) // Invalid following char
            
        case 5:
            // Duplicate address extension bits (break parsing loop)
            if mutated.count >= 7 {
                mutated[6] &= 0xFE // Clear the end-of-address bit
            }
            
        default:
            break
        }
        
        return mutated
    }
    
    /// Generates completely random garbage frames
    mutating func generateGarbageFrame(maxLength: Int = 256) -> Data {
        let length = nextInt(in: 1...maxLength)
        return nextBytes(count: length)
    }
}
