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
/// 2枚以上の UIImage を cv::Stitcher(PANORAMA) で撮り方別チューニング付きで合成する。
/// 重い同期処理＝呼び出し側でBG実行。
/// - warper: 0=球面(既定/上書きなし・上下左右の回転に強い=4隅向き), 1=円筒(横パン向き),
///           2=平面(遠景の面合成向き・現状未使用の将来チューニング候補)
/// - crop:   0=クロップなし, 1=最大内接矩形(横パン向き・四隅の黒帯除去),
///           4=許容70%クロップ(球面4隅向き・content率70%未満の外周行/列を削り黒翼を除去)
+ (SkyStitchBridgeResult *)stitch:(NSArray<UIImage *> *)images
                           warper:(NSInteger)warper
                             crop:(NSInteger)crop;
@end

NS_ASSUME_NONNULL_END
