//
//  StructuralSimilarityTests.swift
//  AXTermTests
//
//  The measure the photo shrinker aims at (2026-10-11): how alike two
//  pictures look, as structural similarity. It has to rank a rougher
//  encoding below a finer one, and a smaller picture viewed at full size
//  below the full-size picture, or the shrinker's searches choose wrong.
//

import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AXTerm

final class StructuralSimilarityTests: XCTestCase {

    private static let image = SyntheticPhoto.image(width: 640, height: 480, seed: 5)

    private func luma(_ image: CGImage, width: Int? = nil, height: Int? = nil) throws -> StructuralSimilarity.Luma {
        try XCTUnwrap(StructuralSimilarity.Luma(image, width: width, height: height))
    }

    func testAPictureIsIdenticalToItself() throws {
        let reference = try luma(Self.image)
        XCTAssertEqual(try XCTUnwrap(StructuralSimilarity.index(reference, reference)), 1, accuracy: 1e-6)
    }

    func testARougherEncodingScoresLower() throws {
        let reference = try luma(Self.image)
        let fine = try XCTUnwrap(SyntheticPhoto.encode(Self.image, type: .jpeg, quality: 0.9))
        let rough = try XCTUnwrap(SyntheticPhoto.encode(Self.image, type: .jpeg, quality: 0.2))
        let fineScore = try XCTUnwrap(StructuralSimilarity.index(of: fine, against: reference))
        let roughScore = try XCTUnwrap(StructuralSimilarity.index(of: rough, against: reference))
        XCTAssertLessThan(fineScore, 1)
        XCTAssertLessThan(roughScore, fineScore)
    }

    /// A quarter-size copy viewed at full size has lost its fine detail.
    func testASmallerPictureViewedAtFullSizeScoresLower() throws {
        let reference = try luma(Self.image)
        let small = try XCTUnwrap(SyntheticPhoto.encode(
            try XCTUnwrap(PhotoPreview.image(from: XCTUnwrap(SyntheticPhoto.encode(Self.image, type: .png)),
                                             longEdge: 160)),
            type: .png))
        let score = try XCTUnwrap(StructuralSimilarity.index(of: small, against: reference))
        XCTAssertLessThan(score, 0.9)
    }

    func testPicturesOfDifferentSizesAreNotCompared() throws {
        XCTAssertNil(StructuralSimilarity.index(try luma(Self.image), try luma(Self.image, width: 320, height: 240)))
    }

    /// The paper's window: 11 Gaussian taps, σ = 1.5, summing to 1.
    func testTheWindowIsThePapers() {
        let window = StructuralSimilarity.window
        XCTAssertEqual(window.count, 11)
        XCTAssertEqual(Double(window.reduce(0, +)), 1, accuracy: 1e-5)
        XCTAssertEqual(Double(window[5] / window[4]), exp(1 / (2 * 1.5 * 1.5)), accuracy: 1e-4)
    }
}
