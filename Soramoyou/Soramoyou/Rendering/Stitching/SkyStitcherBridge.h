//  SkyStitcherBridge.h ⭐️
//  bridging header から #import される。C++/OpenCV 型は一切露出しない（純 Obj-C）。

#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN

/// 合成結果。statusCode は cv::Stitcher::Status の生 Int（翻訳は Swift SkyStitcher.map）。
@interface SkyStitchBridgeResult : NSObject
@property (nonatomic, assign) NSInteger statusCode;
@property (nonatomic, strong, nullable) UIImage *image;
@end

@interface SkyStitcherBridge : NSObject
/// 2枚以上の UIImage を cv::Stitcher(PANORAMA) で合成。重い同期処理＝呼び出し側でBG実行。
+ (SkyStitchBridgeResult *)stitch:(NSArray<UIImage *> *)images;
@end

NS_ASSUME_NONNULL_END
