//
//  MetalBlur.h
//  GoodFeelings — Metal Gaussian Blur for ImGui Background
//
//  Provides a two-pass (horizontal + vertical) Gaussian blur
//  that captures the game view behind the ImGui menu and produces
//  a blurred MTLTexture suitable for use with ImGui::AddImage().
//

#import <Metal/Metal.h>
#import <UIKit/UIKit.h>

@interface MetalBlur : NSObject

@property (nonatomic, readonly) id<MTLTexture> blurredTexture;
@property (nonatomic, assign) float blurRadius;   // Default 20.0
@property (nonatomic, assign) float captureScale; // Default 0.25 (1/4 res for performance)
@property (nonatomic, assign) int   frameSkip;    // Default 2 (blur every 3rd frame)

+ (instancetype)shared;

/// Call once with the Metal device used by ImGui
- (void)setupWithDevice:(id<MTLDevice>)device;

// Captures and blurs the entire game view
/// Call this each frame in drawInMTKView BEFORE ImGui::Render().
/// @param gameView  The root UIView of the game (below the ImGui overlay)
/// @param commandBuffer  The current Metal command buffer
- (void)captureAndBlur:(UIView *)gameView
         commandBuffer:(id<MTLCommandBuffer>)commandBuffer;

// Helper to draw the blurred background for the current ImGui window
+ (void)drawBackgroundBlur;

@end
