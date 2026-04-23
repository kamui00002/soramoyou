//
//  Phase0RegressionTests.swift
//  SoramoyouTests
//
//  そらよう「画質低下・電線ぶれ」修正 Phase 0 の回帰確認用テスト。
//  修正前はすべて FAIL、修正後はすべて PASS することが期待される。
//
//  配置先:
//    /Users/yoshidometoru/開発/iOSアプリ/そらもよう/Soramoyou/SoramoyouTests/Phase0RegressionTests.swift
//
//  前提: 既存テストが XCTest 主体のため本ファイルも XCTest に揃える
//  （@testable import Soramoyou で内部 API にアクセス）
//

import XCTest
import CoreImage
import ImageIO
import MobileCoreServices
import UniformTypeIdentifiers
@testable import Soramoyou

// MARK: - Helper

/// テスト用のカラー画像を生成する（サイズ可変）
/// - 書き出しテスト (#A) では 4000x3000 など大きめを渡してプレビューが縮小されることを確認
/// - HEIF (#C) / JPEG (#E) テストでは 2000x1500 程度で十分
private func makeTestImage(width: Int, height: Int, color: UIColor = .systemBlue) -> UIImage {
    let size = CGSize(width: width, height: height)
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { ctx in
        color.setFill()
        ctx.fill(CGRect(origin: .zero, size: size))
        // 左上に「電線」を模したシャープな細線を1本描く（ぶれ検出用のハイフリケンシー要素）
        UIColor.black.setStroke()
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0, y: CGFloat(height) * 0.2))
        path.addLine(to: CGPoint(x: CGFloat(width), y: CGFloat(height) * 0.22))
        path.lineWidth = 1.0
        path.stroke()
    }
}

/// テスト用の UIImage を一時 URL に JPEG 保存して返す（renderExport(from:) / renderPreview(from:) 用）
private func writeTempJPEG(_ image: UIImage, quality: CGFloat = 1.0) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("phase0_\(UUID().uuidString)")
        .appendingPathExtension("jpg")
    guard let data = image.jpegData(compressionQuality: quality) else {
        throw NSError(domain: "Phase0Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "JPEG エンコード失敗"])
    }
    try data.write(to: url)
    return url
}

// MARK: - 計測用 CIContext（#D 二重ラスタライズ検出）

/// `createCGImage` 呼び出し回数を計測するためのラッパ。
/// 現行 `PreviewRenderer` は `CIContextPool.shared.ciContext` を直接参照するため、
/// Phase 0 後は DI できるように `context:` 引数 or プロトコル化が必要。
/// ここでは回数計測のみのスパイ実装として残し、DI 化された時点で差し替える。
final class CallCountingCIContext {
    private(set) var createCGImageCallCount = 0
    private let wrapped: CIContext

    init(wrapped: CIContext = CIContext()) {
        self.wrapped = wrapped
    }

    func createCGImage(_ image: CIImage, from rect: CGRect) -> CGImage? {
        createCGImageCallCount += 1
        return wrapped.createCGImage(image, from: rect)
    }
}

// MARK: - StorageService 用 PhotoKitAdapter モック（#E）

/// Phase 0 で新設予定の PhotoKitAdapter プロトコルに準拠したモック。
/// 実装側（Phase 0 後）に `protocol PhotoKitAdapterProtocol` を追加し、
/// `StorageService` がこれを DI で受け取る前提。
protocol PhotoKitAdapterProtocol {
    /// HEIF/JPEG 書き出し。options に `kCGImageDestinationLossyCompressionQuality` などを含む
    func writeJPEGRepresentation(image: CGImage, to url: URL, options: [CFString: Any]) throws
}

final class MockPhotoKitAdapter: PhotoKitAdapterProtocol {
    private(set) var writeJPEGCallCount = 0
    private(set) var capturedOptions: [CFString: Any] = [:]
    private(set) var capturedImageSize: CGSize = .zero

    func writeJPEGRepresentation(image: CGImage, to url: URL, options: [CFString: Any]) throws {
        writeJPEGCallCount += 1
        capturedOptions = options
        capturedImageSize = CGSize(width: image.width, height: image.height)
        // 実ファイルは書き出さない（テスト目的のため）
    }
}

// MARK: - Main Test Case

final class Phase0RegressionTests: XCTestCase {

    // MARK: - #A. previewMaxPixel = 2400

    /// Phase 0: `PreviewRenderer.previewMaxPixel` が 2400 に引き上げられていることを確認。
    /// 現行実装では private static let = 1000 なので、まず internal/public に公開する必要がある。
    func test_A_previewMaxPixel_is2400() {
        // Arrange & Act
        let maxPixel = PreviewRenderer.previewMaxPixel

        // Assert
        XCTAssertEqual(maxPixel, 2400,
                       "Phase 0 で previewMaxPixel を 2400 に変更すること（現行 1000）")
    }

    /// 実画像を渡したプレビューの出力解像度が 2400px 以下に収まることを確認
    func test_A_renderPreview_outputIsWithinMaxPixel() throws {
        // Arrange: 4000x3000 のテスト画像
        let input = makeTestImage(width: 4000, height: 3000)
        let url = try writeTempJPEG(input)
        defer { try? FileManager.default.removeItem(at: url) }
        let recipe = EditRecipe()

        // Act
        let cgImage = try PreviewRenderer.renderPreview(from: url, recipe: recipe)

        // Assert: 長辺 <= 2400
        let longEdge = max(cgImage.width, cgImage.height)
        XCTAssertLessThanOrEqual(longEdge, 2400,
                                 "プレビュー長辺は previewMaxPixel (2400) 以下であるべき")
        XCTAssertGreaterThan(longEdge, 1000,
                             "1000 を超えていること（現行の 1000 で頭打ちになっていないこと）")
    }

    // MARK: - #B. applyRecipeForExport が CIImage を返す（CGImage 経由しない）

    /// Phase 0: `renderExport(from:recipe:)` の返り値が CIImage であるか、
    /// もしくは高ビット深度 CGImage (bitsPerComponent >= 16) であることを確認。
    /// 二重ラスタライズ解消の一環として、CIImage を維持して書き出し側に渡す設計に変更する。
    func test_B_renderExport_returnsHighBitDepthOrCIImage() throws {
        // Arrange
        let input = makeTestImage(width: 2000, height: 1500)
        let url = try writeTempJPEG(input)
        defer { try? FileManager.default.removeItem(at: url) }
        let recipe = EditRecipe()

        // Act: 現行は CGImage 返却だが、Phase 0 後は CIImage も可（分岐で両対応）
        let output = try PreviewRenderer.renderExport(from: url, recipe: recipe)

        // Assert
        // Option 1: CIImage を直接返すようになったら `as? CIImage` で判定
        if let _ = output as? CIImage {
            return // CIImage 返却ならテスト成功（理想形）
        }

        // Option 2: CGImage のままなら最低でも 16bit/component 以上であること
        if let cg = output as? CGImage {
            XCTAssertGreaterThanOrEqual(cg.bitsPerComponent, 16,
                "書き出し用 CGImage は高ビット深度 (>=16bpc) であるべき。現行 RGBA8 (8bpc) は Phase 0 で RGBAh (16bpc) に変更する")
        } else {
            XCTFail("renderExport の返り値が CIImage でも CGImage でもない: \(type(of: output))")
        }
    }

    /// `applyRecipeForPreview` と `applyRecipeForExport` の両メソッドが存在することを確認。
    /// シグネチャ: `static func applyRecipeForPreview(_:to:) -> CIImage`
    ///            `static func applyRecipeForExport(_:to:) -> CIImage`
    ///
    /// 現行は private な `applyRecipe(_:to:)` しかない。Phase 0 で 2 メソッドに分離し internal 公開する。
    func test_B_applyRecipeForPreview_andExport_bothExist() {
        // このテストはコンパイルが通れば成功。メソッドが存在しなければビルドエラー。
        let dummy = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 10, height: 10))
        let recipe = EditRecipe()

        let previewResult: CIImage = PreviewRenderer.applyRecipeForPreview(recipe, to: dummy)
        let exportResult: CIImage = PreviewRenderer.applyRecipeForExport(recipe, to: dummy)

        XCTAssertNotNil(previewResult, "applyRecipeForPreview が存在すること")
        XCTAssertNotNil(exportResult, "applyRecipeForExport が存在すること")
    }

    // MARK: - #C. HEIF 書き出しが .RGBAh (10bit+)

    /// HEIF 書き出し → ImageIO で読み戻して BitDepth が 10 以上であることを確認。
    /// iOS 17+ で `kCGImagePropertyDepth` が利用可能。
    func test_C_HEIFExport_bitDepthIs10OrMore() throws {
        // Arrange: RGBAh 形式で CGImage を作成（本来は PreviewRenderer.renderExport がこれを返す）
        let input = makeTestImage(width: 1024, height: 768)
        let url = try writeTempJPEG(input)
        defer { try? FileManager.default.removeItem(at: url) }
        let recipe = EditRecipe()
        let output = try PreviewRenderer.renderExport(from: url, recipe: recipe)

        // output は Phase 0 後 CIImage or 16bpc CGImage を想定
        let cgImage: CGImage
        if let ci = output as? CIImage {
            let ctx = CIContext()
            guard let rendered = ctx.createCGImage(ci, from: ci.extent, format: .RGBAh, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)) else {
                XCTFail("RGBAh CGImage 変換に失敗")
                return
            }
            cgImage = rendered
        } else if let cg = output as? CGImage {
            cgImage = cg
        } else {
            XCTFail("renderExport の返り値が想定外")
            return
        }

        // Act: HEIF として書き出し
        let heifURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase0_heif_\(UUID().uuidString)")
            .appendingPathExtension("heic")
        defer { try? FileManager.default.removeItem(at: heifURL) }

        let type: CFString = UTType.heic.identifier as CFString
        guard let dest = CGImageDestinationCreateWithURL(heifURL as CFURL, type, 1, nil) else {
            XCTFail("CGImageDestination の生成に失敗（HEIF 未対応デバイス）")
            return
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest), "HEIF 書き出しに失敗")

        // Assert: 書き戻しして BitDepth 確認
        guard let source = CGImageSourceCreateWithURL(heifURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            XCTFail("HEIF プロパティ取得失敗")
            return
        }

        let depth = props[kCGImagePropertyDepth] as? Int ?? 0
        XCTAssertGreaterThanOrEqual(depth, 10,
                                    "HEIF の BitDepth は 10bit 以上であるべき（現行 8bit → Phase 0 で 10bit）")
    }

    // MARK: - #D. 二重ラスタライズ解消

    /// 書き出しルートで `CIContext.createCGImage` が 1 回しか呼ばれないことを確認。
    /// 現行実装は `renderExport` → CGImage 化 → 保存ルートで再度 CGImage 化、と 2 回呼ばれている疑い。
    ///
    /// このテストは Phase 0 で `PreviewRenderer` が CIContext を DI で受け取るよう改修された前提。
    /// 現状は `CIContextPool.shared.ciContext` 直接参照のため、テスト対象 API が整うまで保留（skip 可）。
    func test_D_saveEdit_createCGImage_calledOnce() throws {
        // Phase 0 後: PreviewRenderer が CIContext を受け取るメソッドを提供している前提
        //   例: static func renderExport(from url: URL, recipe: EditRecipe, context: CIContext) throws -> CIImage
        // 現状ではその API がないためスキップメッセージを出す
        //
        // 実装後に有効化する想定コード:
        //
        //   let counter = CallCountingCIContext()
        //   let input = makeTestImage(width: 1500, height: 1000)
        //   let url = try writeTempJPEG(input)
        //   defer { try? FileManager.default.removeItem(at: url) }
        //
        //   let ciImage = try PreviewRenderer.renderExport(from: url, recipe: EditRecipe())
        //   // 書き出しは 1 回だけの createCGImage に集約
        //   _ = counter.createCGImage(ciImage, from: ciImage.extent)
        //
        //   XCTAssertEqual(counter.createCGImageCallCount, 1,
        //                  "書き出しルートで createCGImage は 1 回のみ呼ばれるべき（二重ラスタライズ解消）")

        throw XCTSkip("Phase 0 で PreviewRenderer に CIContext DI が追加されるまで保留")
    }

    // MARK: - #E. JPEG 圧縮品質 0.95

    /// `PhotoKitAdapter.writeJPEGRepresentation` に渡される options が
    /// `kCGImageDestinationLossyCompressionQuality = 0.95` を含むことを確認。
    ///
    /// Phase 0 で StorageService は PhotoKitAdapterProtocol を DI で受け取るよう改修される前提。
    /// 現状は `image.jpegData(compressionQuality:)` を内部で呼んでいる疑いがあるため、
    /// まずは ImageIO 経由（PhotoKitAdapter）に切り替え、品質を一元管理する。
    func test_E_uploadImage_usesJPEGQuality_0_95() async throws {
        // Phase 0 後: StorageService が PhotoKitAdapter を DI で受け取る前提
        //   例: init(storage: Storage, photoKitAdapter: PhotoKitAdapterProtocol)
        //
        // 実装後に有効化する想定コード:
        //
        //   let mockAdapter = MockPhotoKitAdapter()
        //   let service = StorageService(storage: Storage.storage(), photoKitAdapter: mockAdapter)
        //   let image = makeTestImage(width: 1024, height: 768)
        //
        //   // Firestore には接続しないが、書き出し options だけ検証したいので
        //   // prepareJPEGData のような公開メソッドを経由する
        //   _ = try await service.prepareJPEGData(image, path: "test.jpg")
        //
        //   XCTAssertEqual(mockAdapter.writeJPEGCallCount, 1)
        //   let quality = mockAdapter.capturedOptions[kCGImageDestinationLossyCompressionQuality] as? Double
        //   XCTAssertEqual(quality, 0.95, accuracy: 0.001,
        //                  "JPEG 圧縮品質は 0.95 で統一されるべき")

        throw XCTSkip("Phase 0 で PhotoKitAdapter が追加され、StorageService が DI を受け取るまで保留")
    }

    /// 最低限、ImageIO 経由で 0.95 品質を付けた JPEG がアップロード想定 Data と一致するかを単体で検証。
    /// これは PhotoKitAdapter のユニットテストとして Phase 0 後も残す価値がある。
    func test_E_imageIO_JPEGQuality_0_95_produces_correctOptions() throws {
        // Arrange
        let input = makeTestImage(width: 1024, height: 768)
        guard let cg = input.cgImage else {
            XCTFail("cgImage 取得失敗"); return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase0_jpeg_\(UUID().uuidString)")
            .appendingPathExtension("jpg")
        defer { try? FileManager.default.removeItem(at: url) }

        let type: CFString = UTType.jpeg.identifier as CFString
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            XCTFail("JPEG CGImageDestination の生成に失敗"); return
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.95
        ]

        // Act
        CGImageDestinationAddImage(dest, cg, options as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest), "JPEG 書き出し失敗")

        // Assert: 書き戻して品質プロパティは取れないが、ファイルサイズが
        // 0.90 で書いたときと 0.95 で書いたときで有意に違うことは検証可能
        let size95 = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size95, 0, "0.95 品質の JPEG が生成されていること")

        // 参考: 0.90 で同画像を書き出してサイズ差を見る
        let url90 = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase0_jpeg90_\(UUID().uuidString)")
            .appendingPathExtension("jpg")
        defer { try? FileManager.default.removeItem(at: url90) }
        if let dest90 = CGImageDestinationCreateWithURL(url90 as CFURL, type, 1, nil) {
            CGImageDestinationAddImage(dest90, cg, [kCGImageDestinationLossyCompressionQuality: 0.90] as CFDictionary)
            _ = CGImageDestinationFinalize(dest90)
            let size90 = (try FileManager.default.attributesOfItem(atPath: url90.path)[.size] as? Int) ?? 0
            XCTAssertGreaterThan(size95, size90, "0.95 は 0.90 よりファイルサイズが大きい（品質が高い）")
        }
    }
}
