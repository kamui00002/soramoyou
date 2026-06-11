//  SkyStitcherBridge.mm ⭐️
//  OpenCV cv::Stitcher(PANORAMA)。全体を #if で囲み、未リンク時は番兵 -999 を返すスタブ。
//  色空間メモ: OpenCV は色管理を持たない（8bit BGR/sRGB）。入出力は sRGB に収める。
//  → P3 ガモットは stitch を通すと失われる。これは v1 の許容例外。「保持」とは主張しない。

#import "SkyStitcherBridge.h"

#if defined(SORAMOYOU_OPENCV) && __has_include(<opencv2/opencv.hpp>)
  #import <opencv2/opencv.hpp>
  #import <opencv2/stitching.hpp>
  #import <opencv2/stitching/warpers.hpp>
  #import <opencv2/imgproc.hpp>
  #define SKY_OPENCV_AVAILABLE 1
#endif

@implementation SkyStitchBridgeResult
@end

@implementation SkyStitcherBridge

#if SKY_OPENCV_AVAILABLE

// UIImage → cv::Mat（向きを焼き込み、sRGB DeviceRGB で描いて BGR 3ch に）
// メモリ対策: フル解像度で描かず、最初から長辺 maxLongSide 以下へ縮小して描画する。
// （24MP×4枚をフルサイズで Mat 化すると数百MB級の一時ピークになり jetsam リスクがあるため）
// 失敗時（CGImage 取得不可/コンテキスト生成不可）は空 Mat を返す＝呼び出し側で空チェックする。
static cv::Mat MatFromUIImage(UIImage *image, double maxLongSide) {
    CGSize src = image.size;
    double longSide = std::max(src.width, src.height);
    double scale = (longSide > maxLongSide && longSide > 0) ? (maxLongSide / longSide) : 1.0;
    CGSize sz = CGSizeMake(std::max(1.0, std::round(src.width * scale)),
                           std::max(1.0, std::round(src.height * scale)));
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.scale = 1; fmt.opaque = YES;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:sz format:fmt];
    UIImage *upright = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [image drawInRect:CGRectMake(0, 0, sz.width, sz.height)];
    }];
    CGImageRef cg = upright.CGImage;
    if (cg == NULL) return cv::Mat();   // 描画失敗（異常系）
    int w = (int)CGImageGetWidth(cg), h = (int)CGImageGetHeight(cg);
    cv::Mat rgba(h, w, CV_8UC4);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(rgba.data, w, h, 8, rgba.step[0], cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrderDefault);
    if (c == NULL) { CGColorSpaceRelease(cs); return cv::Mat(); }  // コンテキスト生成失敗
    CGContextDrawImage(c, CGRectMake(0, 0, w, h), cg);
    CGContextRelease(c); CGColorSpaceRelease(cs);
    cv::Mat bgr; cv::cvtColor(rgba, bgr, cv::COLOR_RGBA2BGR);
    return bgr;
}

// cv::Mat → UIImage（.up）
static UIImage *UIImageFromMat(const cv::Mat &bgr) {
    cv::Mat rgba; cv::cvtColor(bgr, rgba, cv::COLOR_BGR2RGBA);
    int w = rgba.cols, h = rgba.rows;
    NSData *data = [NSData dataWithBytes:rgba.data length:rgba.total() * rgba.elemSize()];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef p = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGImageRef cg = CGImageCreate(w, h, 8, 32, rgba.step[0], cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrderDefault, p, NULL, false,
        kCGRenderingIntentDefault);
    UIImage *out = [UIImage imageWithCGImage:cg scale:1 orientation:UIImageOrientationUp];
    CGImageRelease(cg); CGDataProviderRelease(p); CGColorSpaceRelease(cs);
    return out;
}

// ワープ後の黒い余白（四隅の黒帯）を、黒を一切含まない「最大の内接長方形」で切り落とす。
// 合成された中身は削らず、空いた黒部分だけをトリミングするので品質は落ちない。
static void CropBlackBorders(cv::Mat &pano) {
    if (pano.empty()) return;
    cv::Mat gray; cv::cvtColor(pano, gray, cv::COLOR_BGR2GRAY);
    // ワープ余白はちょうど黒(0)。実写の暗部(屋根/影)は >1 なので有効として残る。
    cv::Mat content; cv::threshold(gray, content, 1, 255, cv::THRESH_BINARY);
    // 継ぎ目や小さな暗部による穴で内接矩形が痩せないよう、小さな穴を閉じる。
    cv::morphologyEx(content, content, cv::MORPH_CLOSE,
                     cv::getStructuringElement(cv::MORPH_RECT, cv::Size(7, 7)));

    // 各列で「上方向に連続する有効画素数」をヒストグラムにし、行ごとに最大長方形を求める（O(W*H)）。
    const int rows = content.rows, cols = content.cols;
    std::vector<int> height(cols, 0), stk;
    stk.reserve(cols + 1);
    long bestArea = 0;
    cv::Rect best(0, 0, 0, 0);
    for (int r = 0; r < rows; ++r) {
        const uchar *cr = content.ptr<uchar>(r);
        for (int c = 0; c < cols; ++c) height[c] = cr[c] ? height[c] + 1 : 0;
        stk.clear();
        for (int c = 0; c <= cols; ++c) {
            const int curr = (c == cols) ? 0 : height[c];
            while (!stk.empty() && curr < height[stk.back()]) {
                const int hh = height[stk.back()]; stk.pop_back();
                const int left = stk.empty() ? 0 : stk.back() + 1;
                const long area = (long)hh * (c - left);
                if (area > bestArea) { bestArea = area; best = cv::Rect(left, r - hh + 1, c - left, hh); }
            }
            stk.push_back(c);
        }
    }
    // 黒を含まない最大の長方形が見つかれば必ず採用する（黒ゼロ優先）。
    // ※以前は best が canvas の 1/3 未満だとクロップを諦める過剰トリミング防止ガードがあったが、
    //   十字(プラス)型の4隅合成では内接矩形が 1/3 未満になり「クロップ不発→全黒」になっていた
    //   （しかも RANSAC の非決定性で出る回と出ない回があった）。ガードを外し常にクロップする。
    //   退化した細い帯は後段のガード3（クロップ後 aspect>8 で失敗扱い）が受け止める。
    if (best.width > 0 && best.height > 0) {
        pano = pano(best).clone();
    }
}

// 外周から「content 率が閾値未満の行/列」を反復的に削る中間クロップ（球面の4隅向き）。
// 内接矩形(0%許容=切りすぎ)と外周黒のみ(黒翼が残る)の中間。各辺が minFrac 以上 content になるまで縮める。
static void CropTolerantBorder(cv::Mat &pano, double minFrac) {
    if (pano.empty()) return;
    cv::Mat gray; cv::cvtColor(pano, gray, cv::COLOR_BGR2GRAY);
    cv::Mat content; cv::threshold(gray, content, 1, 255, cv::THRESH_BINARY);
    int top = 0, bottom = content.rows - 1, left = 0, right = content.cols - 1;
    auto rowFrac = [&](int r) {
        int n = 0; const uchar *p = content.ptr<uchar>(r);
        for (int c = left; c <= right; ++c) if (p[c]) ++n;
        return (double)n / std::max(1, right - left + 1);
    };
    auto colFrac = [&](int c) {
        int n = 0;
        for (int r = top; r <= bottom; ++r) if (content.at<uchar>(r, c)) ++n;
        return (double)n / std::max(1, bottom - top + 1);
    };
    bool changed = true;
    while (changed && (right - left) > 10 && (bottom - top) > 10) {
        changed = false;
        if (rowFrac(top)    < minFrac) { ++top;    changed = true; }
        if (rowFrac(bottom) < minFrac) { --bottom; changed = true; }
        if (colFrac(left)   < minFrac) { ++left;   changed = true; }
        if (colFrac(right)  < minFrac) { --right;  changed = true; }
    }
    cv::Rect bbox(left, top, right - left + 1, bottom - top + 1);
    if (bbox.width > 0 && bbox.height > 0 &&
        (bbox.width < pano.cols || bbox.height < pano.rows)) {
        pano = pano(bbox).clone();
    }
}

// 合成の中核。warper / crop を指定して撮り方別にチューニングする。
+ (SkyStitchBridgeResult *)stitch:(NSArray<UIImage *> *)images
                           warper:(NSInteger)warper
                             crop:(NSInteger)crop {
    SkyStitchBridgeResult *result = [SkyStitchBridgeResult new];
    @autoreleasepool {
        // OpenCV は status 返却の他に cv::Exception を throw する経路（CV_Assert/OOM 等）があり、
        // ObjC++ で未捕捉の C++ 例外は std::terminate（クラッシュ）になる。必ず捕捉して失敗扱いに落とす。
        try {
            std::vector<cv::Mat> mats; mats.reserve(images.count);
            for (UIImage *img in images) {
                // 1枚ごとに pool を切り、変換途中の UIImage/中間バッファを即時解放する（4枚分の滞留防止）。
                @autoreleasepool {
                    // OOM/熱/時間軽減 + 特徴検出安定: 最初から長辺 ~1500px へ縮小して描画→Mat 化
                    cv::Mat m = MatFromUIImage(img, 1500.0);
                    if (m.empty()) {
                        // 画像変換失敗（CGImage 不可等の異常系）。-1 は Swift 側 map() で .failed に落ちる。
                        result.statusCode = -1;
                        return result;
                    }
                    mats.push_back(m);
                }
            }
            // 空向けチューニング（低テクスチャ対策）
            cv::Ptr<cv::Stitcher> st = cv::Stitcher::create(cv::Stitcher::PANORAMA);
            st->setFeaturesFinder(cv::ORB::create(2000));               // 青空でも縁/雲を多めに拾う
            st->setPanoConfidenceThresh(0.6);                           // 既定1.0は厳しすぎ→緩める
            st->setExposureCompensator(cv::makePtr<cv::detail::BlocksGainCompensator>());
            st->setSeamFinder(cv::makePtr<cv::detail::GraphCutSeamFinder>(
                cv::detail::GraphCutSeamFinderBase::COST_COLOR));
            st->setBlender(cv::makePtr<cv::detail::MultiBandBlender>(false)); // 継ぎ目段差を消す
            // ワープ選択: 0=球面(既定。天頂を圧縮しワイドに仕上がる＝現行は両モードこれ)。
            // 1=円筒(縦の視野を保存=縦長になる)・2=平面 は現状 Swift から渡されない将来チューニング候補として温存。
            switch (warper) {
                case 1: st->setWarper(cv::makePtr<cv::CylindricalWarper>()); break;
                case 2: st->setWarper(cv::makePtr<cv::PlaneWarper>());       break;
                default: break; // 0 = 球面(PANORAMA 既定。上書きしない)
            }
            cv::Mat pano;
            cv::Stitcher::Status status = st->stitch(mats, pano);
            result.statusCode = (NSInteger)status;
            if (status == cv::Stitcher::OK && !pano.empty()) {
                // 実際に合成へ使われた枚数（残りは特徴不足で黙って捨てられる）。
                const NSInteger usedCount = (NSInteger)st->component().size();
                const double longSide  = std::max(pano.cols, pano.rows);
                const double shortSide = std::max(1, std::min(pano.cols, pano.rows));
                const double aspect    = longSide / shortSide;
                // フィールドの「1部屋になる/細い帯」報告を診断できるよう1行だけ残す（合成は稀な操作＝ログ過多にならない）。
                NSLog(@"SKYSTITCH used=%ld/%lu out=%dx%d aspect=%.2f warper=%ld crop=%ld",
                      (long)usedCount, (unsigned long)mats.size(), pano.cols, pano.rows, aspect, (long)warper, (long)crop);

                // ガード1【写真ドロップ】: 入力の一部しか繋げられなかった（部屋の境目の白壁等で特徴が一致しない）。
                // 黙って部分結果（例: 4枚中の1部屋だけ）を出さず、「重ねて撮り直す」誘導へ落とす。
                if (usedCount < (NSInteger)mats.size()) {
                    result.statusCode = (NSInteger)cv::Stitcher::ERR_NEED_MORE_IMGS; // 1 → needMoreImages
                }
                // ガード2【異常出力】: 比率/サイズが破綻（円筒ワープ暴走の 26:1 帯など）。破綻として弾く。
                else if (aspect > 8.0 || longSide > 8000.0) {
                    result.statusCode = (NSInteger)cv::Stitcher::ERR_CAMERA_PARAMS_ADJUST_FAIL; // 3
                }
                // 正常: クロップ選択して画像確定。0=なし, 1=最大内接矩形(横パン), 4=許容70%(球面4隅)
                else {
                    switch (crop) {
                        case 1: CropBlackBorders(pano);          break;
                        case 4: CropTolerantBorder(pano, 0.70);  break;
                        default: break; // 0 = クロップなし
                    }
                    // ガード3【クロップ後の再検査】: クロップは行/列を削るため、ガード2を通った画像でも
                    // クロップ後に細い帯へ縮みうる。実際に表示・投稿される最終画像で破綻を再確認する。
                    const double croppedLong  = std::max(pano.cols, pano.rows);
                    const double croppedShort = std::max(1, std::min(pano.cols, pano.rows));
                    if (pano.empty() || (croppedLong / croppedShort) > 8.0 || croppedLong > 8000.0) {
                        result.statusCode = (NSInteger)cv::Stitcher::ERR_CAMERA_PARAMS_ADJUST_FAIL; // 3
                    } else {
                        result.image = UIImageFromMat(pano);
                    }
                }
            }
        } catch (const cv::Exception &e) {
            NSLog(@"SKYSTITCH cv::Exception: %s", e.what());
            result.statusCode = (NSInteger)cv::Stitcher::ERR_CAMERA_PARAMS_ADJUST_FAIL; // 3 → 撮り直し誘導
            result.image = nil;
        } catch (const std::exception &e) {
            NSLog(@"SKYSTITCH std::exception: %s", e.what());
            result.statusCode = (NSInteger)cv::Stitcher::ERR_CAMERA_PARAMS_ADJUST_FAIL; // 3 → 撮り直し誘導
            result.image = nil;
        }
    }
    return result;
}

#else  // OpenCV 未リンク時スタブ（ビルドを通す）

// Swift 側（SORAMOYOU_OPENCV 有効のままパッケージ未解決になった構成ドリフト時）が呼ぶのはこの3引数版。
// 番兵 -999 を返して Swift map() が .unavailable へ落とす＝unrecognized selector クラッシュを防ぐ契約。
+ (SkyStitchBridgeResult *)stitch:(NSArray<UIImage *> *)images
                           warper:(NSInteger)warper
                             crop:(NSInteger)crop {
    SkyStitchBridgeResult *result = [SkyStitchBridgeResult new];
    result.statusCode = -999;   // Swift 側 map() が .unavailable へ落とす
    result.image = nil;
    return result;
}

#endif
@end
