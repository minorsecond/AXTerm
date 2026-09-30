import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AXTerm

/// The photo shrinker: a phone photo in, a JPEG that fits a byte budget out,
/// or a clear failure. Never a silent drop, never garbage.
final class ImageShrinkerTests: XCTestCase {

    /// A "phone photo": big enough that no budget here fits it as taken.
    private static let photo: Data = SyntheticPhoto.data(width: 2000, height: 1500, seed: 3)!

    private func shrunk(_ result: Result<ImageShrinker.Outcome, ImageShrinker.Failure>,
                        file: StaticString = #filePath, line: UInt = #line) throws -> ImageShrinker.Shrunk {
        guard case .success(.shrunk(let shrunk)) = result else {
            XCTFail("expected a shrunk image, got \(result)", file: file, line: line)
            throw XCTSkip("no result to inspect")
        }
        return shrunk
    }

    // MARK: - Fitting the budget

    func testTheSyntheticPhotoIsBiggerThanEveryBudgetUsedHere() {
        XCTAssertGreaterThan(Self.photo.count, 200 * 1024, "otherwise the tests below prove nothing")
    }

    func testFitsTheBudgetForSeveralImagesAndBudgets() throws {
        let images: [(Int, Int)] = [(2000, 1500), (1500, 2000), (1800, 900)]
        let budgets = [16 * 1024, 32 * 1024, 48 * 1024, 100 * 1024]
        for (width, height) in images {
            let data = try XCTUnwrap(SyntheticPhoto.data(width: width, height: height, seed: UInt32(width)))
            for budget in budgets {
                let result = ImageShrinker.shrink(data, name: "IMG.jpg",
                                                  options: .init(byteBudget: budget))
                let shrunk = try shrunk(result)
                XCTAssertLessThanOrEqual(shrunk.data.count, budget, "\(width)x\(height) into \(budget)")
                XCTAssertEqual(SyntheticPhoto.typeIdentifier(of: shrunk.data), UTType.jpeg.identifier)
                XCTAssertEqual(shrunk.originalByteCount, data.count)
                XCTAssertNotNil(ImageShrinker.pixelSize(of: shrunk.data), "the result decodes")
            }
        }
    }

    func testABiggerBudgetNeverGivesASmallerPicture() throws {
        let small = try shrunk(ImageShrinker.shrink(Self.photo, name: "a.jpg", options: .init(byteBudget: 16 * 1024)))
        let large = try shrunk(ImageShrinker.shrink(Self.photo, name: "a.jpg", options: .init(byteBudget: 100 * 1024)))
        XCTAssertGreaterThanOrEqual(large.pixelWidth * large.pixelHeight, small.pixelWidth * small.pixelHeight)
    }

    func testTheLongEdgeNeverExceedsTheLimit() throws {
        let result = ImageShrinker.shrink(Self.photo, name: "a.jpg",
                                          options: .init(byteBudget: 400 * 1024, maxLongEdge: 1024))
        let shrunk = try shrunk(result)
        XCTAssertLessThanOrEqual(max(shrunk.pixelWidth, shrunk.pixelHeight), 1024)
    }

    // MARK: - Shape

    func testKeepsTheAspectRatio() throws {
        for (width, height) in [(2000, 1500), (1500, 2000), (1800, 900)] {
            let data = try XCTUnwrap(SyntheticPhoto.data(width: width, height: height))
            let shrunk = try shrunk(ImageShrinker.shrink(data, name: "a.jpg", options: .init(byteBudget: 40 * 1024)))
            let before = Double(width) / Double(height)
            let after = Double(shrunk.pixelWidth) / Double(shrunk.pixelHeight)
            // One pixel of rounding on the short edge is all that is allowed.
            XCTAssertEqual(after, before, accuracy: before / Double(min(shrunk.pixelWidth, shrunk.pixelHeight)) + 0.005,
                           "\(width)x\(height) came out \(shrunk.pixelWidth)x\(shrunk.pixelHeight)")
        }
    }

    /// A phone held upright stores a landscape sensor image and an
    /// orientation tag. The result has the rotation baked in, so it displays
    /// upright in clients that ignore the tag.
    func testTheOrientationTagIsAppliedToThePixels() throws {
        let data = try XCTUnwrap(SyntheticPhoto.data(width: 2000, height: 1500, orientation: 6))
        let size = try XCTUnwrap(ImageShrinker.pixelSize(of: data))
        XCTAssertLessThan(size.width, size.height, "pixelSize reports the displayed shape")
        let shrunk = try shrunk(ImageShrinker.shrink(data, name: "a.jpg", options: .init(byteBudget: 40 * 1024)))
        XCTAssertLessThan(shrunk.pixelWidth, shrunk.pixelHeight, "portrait in, portrait out")
        let orientation = SyntheticPhoto.properties(of: shrunk.data)[kCGImagePropertyOrientation] as? Int
        XCTAssertTrue(orientation == nil || orientation == 1, "no rotation left for the viewer to apply")
    }

    // MARK: - Location

    func testStripsTheGPSPositionByDefault() throws {
        let data = try XCTUnwrap(SyntheticPhoto.data(width: 2000, height: 1500, gps: SyntheticPhoto.gps))
        XCTAssertTrue(ImageShrinker.containsLocation(data))
        let shrunk = try shrunk(ImageShrinker.shrink(data, name: "a.jpg", options: .init(byteBudget: 40 * 1024)))
        XCTAssertFalse(ImageShrinker.containsLocation(shrunk.data))
        XCTAssertNil(SyntheticPhoto.properties(of: shrunk.data)[kCGImagePropertyGPSDictionary])
    }

    func testKeepsTheGPSPositionWhenAsked() throws {
        let data = try XCTUnwrap(SyntheticPhoto.data(width: 2000, height: 1500, gps: SyntheticPhoto.gps))
        let shrunk = try shrunk(ImageShrinker.shrink(data, name: "a.jpg",
                                                     options: .init(byteBudget: 40 * 1024, keepsLocation: true)))
        let gps = try XCTUnwrap(SyntheticPhoto.properties(of: shrunk.data)[kCGImagePropertyGPSDictionary] as? [CFString: Any])
        XCTAssertEqual(gps[kCGImagePropertyGPSLatitude] as? Double ?? 0, 39.7392, accuracy: 0.0001)
    }

    /// A photo that already fits keeps its pixels exactly; only the position
    /// comes out.
    func testASmallPhotoWithALocationLosesOnlyTheLocation() throws {
        let data = try XCTUnwrap(SyntheticPhoto.data(width: 300, height: 200, quality: 0.5, gps: SyntheticPhoto.gps))
        guard case .success(.locationRemoved(let stripped)) = ImageShrinker.shrink(
            data, name: "a.jpg", options: .init(byteBudget: 200 * 1024)) else {
            return XCTFail("expected the location to be removed")
        }
        XCTAssertFalse(ImageShrinker.containsLocation(stripped))
        XCTAssertEqual(ImageShrinker.pixelSize(of: stripped)?.width, 300)
        XCTAssertEqual(SyntheticPhoto.typeIdentifier(of: stripped), UTType.jpeg.identifier, "still the same format")
    }

    func testRemovingLocationFromAnImageWithoutOneStillWorks() throws {
        let data = try XCTUnwrap(SyntheticPhoto.data(width: 200, height: 100))
        let stripped = try XCTUnwrap(ImageShrinker.removingLocation(from: data))
        XCTAssertFalse(ImageShrinker.containsLocation(stripped))
    }

    // MARK: - Formats

    func testHEICInJPEGOut() throws {
        guard let heic = SyntheticPhoto.data(width: 2000, height: 1500, type: .heic, quality: 0.95) else {
            throw XCTSkip("this machine cannot encode HEIC")
        }
        XCTAssertEqual(SyntheticPhoto.typeIdentifier(of: heic), UTType.heic.identifier)
        let result = ImageShrinker.shrink(heic, name: "IMG_0042.HEIC", options: .init(byteBudget: 30 * 1024))
        let shrunk = try shrunk(result)
        XCTAssertEqual(SyntheticPhoto.typeIdentifier(of: shrunk.data), UTType.jpeg.identifier)
        XCTAssertEqual(shrunk.name, "IMG_0042.jpg")
        XCTAssertLessThanOrEqual(shrunk.data.count, 30 * 1024)
    }

    func testPNGInJPEGOut() throws {
        let png = try XCTUnwrap(SyntheticPhoto.data(width: 1600, height: 1200, type: .png))
        let shrunk = try shrunk(ImageShrinker.shrink(png, name: "screenshot.png", options: .init(byteBudget: 48 * 1024)))
        XCTAssertEqual(SyntheticPhoto.typeIdentifier(of: shrunk.data), UTType.jpeg.identifier)
        XCTAssertEqual(shrunk.name, "screenshot.jpg")
    }

    func testAnAlreadySmallImageIsUntouched() throws {
        let data = try XCTUnwrap(SyntheticPhoto.data(width: 320, height: 240, quality: 0.6))
        XCTAssertLessThan(data.count, 48 * 1024)
        XCTAssertEqual(ImageShrinker.shrink(data, name: "a.jpg", options: .init(byteBudget: 48 * 1024)),
                       .success(.unchanged))
    }

    func testASmallImageWithALocationIsUntouchedWhenTheLocationIsKept() throws {
        let data = try XCTUnwrap(SyntheticPhoto.data(width: 320, height: 240, quality: 0.6, gps: SyntheticPhoto.gps))
        XCTAssertEqual(ImageShrinker.shrink(data, name: "a.jpg",
                                            options: .init(byteBudget: 48 * 1024, keepsLocation: true)),
                       .success(.unchanged))
    }

    // MARK: - Failures

    func testABudgetItCannotMeetIsReportedNotFaked() throws {
        let result = ImageShrinker.shrink(Self.photo, name: "a.jpg", options: .init(byteBudget: 600))
        guard case .failure(.cannotMeetBudget(let smallest)) = result else {
            return XCTFail("expected cannotMeetBudget, got \(result)")
        }
        XCTAssertGreaterThan(smallest, 600, "the smallest attempt is reported, and it did not fit")
    }

    func testBytesThatAreNotAnImageFail() {
        let text = Data(String(repeating: "not a picture ", count: 500).utf8)
        XCTAssertEqual(ImageShrinker.shrink(text, name: "a.jpg", options: .init(byteBudget: 1024)),
                       .failure(.notAnImage))
        XCTAssertFalse(ImageShrinker.isImage(text))
    }

    func testAnAnimatedGIFIsRefusedRatherThanFlattened() {
        let gif = SyntheticPhoto.animatedGIF(width: 400, height: 300)
        XCTAssertEqual(ImageShrinker.shrink(gif, name: "loop.gif", options: .init(byteBudget: 1024)),
                       .failure(.animated))
    }

    // MARK: - Determinism

    func testTheSamePhotoAlwaysShrinksToTheSameBytes() throws {
        let options = ImageShrinker.Options(byteBudget: 32 * 1024)
        let first = try shrunk(ImageShrinker.shrink(Self.photo, name: "a.jpg", options: options))
        let second = try shrunk(ImageShrinker.shrink(Self.photo, name: "a.jpg", options: options))
        XCTAssertEqual(first, second)
    }

    // MARK: - Pieces

    func testTheEdgeLadderStepsDownToTheFloor() {
        let ladder = ImageShrinker.edgeLadder(startingAt: 4032, maxLongEdge: 1600, minLongEdge: 320)
        XCTAssertEqual(ladder.first, 1600)
        XCTAssertEqual(ladder.last, 320)
        XCTAssertEqual(ladder, ladder.sorted(by: >), "largest first")
        XCTAssertEqual(Set(ladder).count, ladder.count, "no size tried twice")
    }

    func testTheEdgeLadderForASmallImageIsJustItsOwnSize() {
        XCTAssertEqual(ImageShrinker.edgeLadder(startingAt: 200, maxLongEdge: 1600, minLongEdge: 320), [200])
    }

    func testTheResultIsNamedAsAJPEG() {
        XCTAssertEqual(ImageShrinker.jpegName(for: "IMG_1234.HEIC"), "IMG_1234.jpg")
        XCTAssertEqual(ImageShrinker.jpegName(for: "chart.v2.png"), "chart.v2.jpg")
        XCTAssertEqual(ImageShrinker.jpegName(for: "noext"), "noext.jpg")
    }

    func testImagesAreRecognizedByName() {
        for name in ["a.jpg", "a.JPEG", "a.png", "a.heic", "a.HEIF", "a.gif", "a.tiff", "a.webp"] {
            XCTAssertTrue(ImageShrinker.isImage(named: name), name)
        }
        for name in ["a.txt", "a.pdf", "a.zip", "a.xml", "noext", "a.geojson"] {
            XCTAssertFalse(ImageShrinker.isImage(named: name), name)
        }
    }
}
