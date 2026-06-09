//  SkyStitcherBridge.mm ⭐️
//  OpenCV cv::Stitcher(PANORAMA)。全体を #if で囲み、未リンク時は番兵 -999 を返すスタブ。
//  色空間メモ: OpenCV は色管理を持たない（8bit BGR/sRGB）。入出力は sRGB に収める。
//  → P3 ガモットは stitch を通すと失われる。これは v1 の許容例外。「保持」とは主張しない。

#import "SkyStitcherBridge.h"

#if defined(SORAMOYOU_OPENCV) && __has_include(<opencv2/opencv.hpp>)
  #import <opencv2/opencv.hpp>
  #import <opencv2/stitching.hpp>
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

+ (SkyStitchBridgeResult *)stitch:(NSArray<UIImage *> *)images {
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
        cv::Mat pano;
        cv::Stitcher::Status status = st->stitch(mats, pano);
        result.statusCode = (NSInteger)status;
        if (status == cv::Stitcher::OK && !pano.empty()) result.image = UIImageFromMat(pano);
    }
    return result;
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
