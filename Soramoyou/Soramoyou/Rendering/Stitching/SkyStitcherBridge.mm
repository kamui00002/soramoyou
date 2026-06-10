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
static cv::Mat MatFromUIImage(UIImage *image) {
    CGSize sz = image.size;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.scale = 1; fmt.opaque = YES;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:sz format:fmt];
    UIImage *upright = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [image drawInRect:CGRectMake(0, 0, sz.width, sz.height)];
    }];
    CGImageRef cg = upright.CGImage;
    int w = (int)CGImageGetWidth(cg), h = (int)CGImageGetHeight(cg);
    cv::Mat rgba(h, w, CV_8UC4);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(rgba.data, w, h, 8, rgba.step[0], cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrderDefault);
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
    // 妥当な大きさのときだけ採用（万一の過剰トリミング防止）。
    if (best.width > cols / 3 && best.height > rows / 3) {
        pano = pano(best).clone();
    }
}

// 外周の「完全に黒い余白」だけを落とす控えめなクロップ（面合成=4隅向き）。
// 内接矩形（CropBlackBorders）と違い、十字/L字に張り出した四隅（地上・地平線）の内容を保持する。
// 非黒画素の外接矩形（bounding box）まで縮めるだけ＝内部の黒い隙間は残す（端の情報を捨てない）。
static void CropExteriorBlack(cv::Mat &pano) {
    if (pano.empty()) return;
    cv::Mat gray; cv::cvtColor(pano, gray, cv::COLOR_BGR2GRAY);
    cv::Mat content; cv::threshold(gray, content, 1, 255, cv::THRESH_BINARY);
    // 非黒画素の外接矩形をマスク走査で直接求める（OpenCV版差異のある boundingRect/findNonZero を使わない）。
    int top = -1, bottom = -1, left = content.cols, right = -1;
    for (int r = 0; r < content.rows; ++r) {
        const uchar *cr = content.ptr<uchar>(r);
        int rowLeft = -1, rowRight = -1;
        for (int c = 0; c < content.cols; ++c) {
            if (cr[c]) { if (rowLeft < 0) rowLeft = c; rowRight = c; }
        }
        if (rowLeft >= 0) {
            if (top < 0) top = r;
            bottom = r;
            if (rowLeft < left)  left = rowLeft;
            if (rowRight > right) right = rowRight;
        }
    }
    if (top < 0 || right < 0) return; // 全黒なら何もしない
    cv::Rect bbox(left, top, right - left + 1, bottom - top + 1);
    // 念のためのガード（万一全面が有効なら何もしない＝そのまま）。
    if (bbox.width > 0 && bbox.height > 0 &&
        (bbox.width < pano.cols || bbox.height < pano.rows)) {
        pano = pano(bbox).clone();
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
        std::vector<cv::Mat> mats; mats.reserve(images.count);
        for (UIImage *img in images) {
            cv::Mat m = MatFromUIImage(img);
            // OOM/熱/時間軽減 + 特徴検出安定: 長辺 ~1500px に縮小
            double longSide = std::max(m.cols, m.rows), target = 1500.0;
            if (longSide > target) {
                double s = target / longSide;
                cv::resize(m, m, cv::Size(), s, s, cv::INTER_AREA);
            }
            mats.push_back(m);
        }
        // 空向けチューニング（低テクスチャ対策）
        cv::Ptr<cv::Stitcher> st = cv::Stitcher::create(cv::Stitcher::PANORAMA);
        st->setFeaturesFinder(cv::ORB::create(2000));               // 青空でも縁/雲を多めに拾う
        st->setPanoConfidenceThresh(0.6);                           // 既定1.0は厳しすぎ→緩める
        st->setExposureCompensator(cv::makePtr<cv::detail::BlocksGainCompensator>());
        st->setSeamFinder(cv::makePtr<cv::detail::GraphCutSeamFinder>(
            cv::detail::GraphCutSeamFinderBase::COST_COLOR));
        st->setBlender(cv::makePtr<cv::detail::MultiBandBlender>(false)); // 継ぎ目段差を消す
        // ワープ選択: 0=球面(既定。上下左右の回転に強い=4隅向き), 1=円筒(横パンで地平線が反りにくい), 2=平面(遠景の面合成)
        switch (warper) {
            case 1: st->setWarper(cv::makePtr<cv::CylindricalWarper>()); break;
            case 2: st->setWarper(cv::makePtr<cv::PlaneWarper>());       break;
            default: break; // 0 = 球面(PANORAMA 既定。上書きしない)
        }
        cv::Mat pano;
        cv::Stitcher::Status status = st->stitch(mats, pano);
        result.statusCode = (NSInteger)status;
        if (status == cv::Stitcher::OK && !pano.empty()) {
            // クロップ選択: 0=なし, 1=最大内接矩形(横パン), 2=外周黒のみ, 3=許容85%, 4=許容70%
            switch (crop) {
                case 1: CropBlackBorders(pano);          break;
                case 2: CropExteriorBlack(pano);         break;
                case 3: CropTolerantBorder(pano, 0.85);  break;
                case 4: CropTolerantBorder(pano, 0.70);  break;
                default: break; // 0 = クロップなし
            }
            result.image = UIImageFromMat(pano);
        }
    }
    return result;
}

// 後方互換エントリ: 既定の撮り方（横パン）= 円筒ワープ + 内接矩形クロップ。
+ (SkyStitchBridgeResult *)stitch:(NSArray<UIImage *> *)images {
    return [self stitch:images warper:1 crop:1];
}

#else  // OpenCV 未リンク時スタブ（ビルドを通す）

+ (SkyStitchBridgeResult *)stitch:(NSArray<UIImage *> *)images {
    SkyStitchBridgeResult *result = [SkyStitchBridgeResult new];
    result.statusCode = -999;   // Swift 側 map() が .unavailable へ落とす
    result.image = nil;
    return result;
}

#endif
@end
