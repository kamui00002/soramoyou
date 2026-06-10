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
/// 既定の撮り方（横パン）= warper:1(円筒) crop:1(内接矩形) で合成する後方互換エントリ。
+ (SkyStitchBridgeResult *)stitch:(NSArray<UIImage *> *)images;

/// 撮り方別チューニングを指定して合成する。
/// - warper: 0=球面(既定/上書きなし・上下左右の回転に強い), 1=円筒(横パン向き), 2=平面(遠景の面合成向き)
/// - crop:   0=クロップなし, 1=最大内接矩形(横パン向き・四隅の黒帯除去), 2=外周黒のみ除去(面合成向き・端の内容を残す)
+ (SkyStitchBridgeResult *)stitch:(NSArray<UIImage *> *)images
                           warper:(NSInteger)warper
                             crop:(NSInteger)crop;
@end

NS_ASSUME_NONNULL_END
