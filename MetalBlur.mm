//
//  MetalBlur.mm
//  GoodFeelings — Metal Gaussian Blur for ImGui Background
//
//  Two-pass (H+V) Gaussian blur compute shader.
//  Gaussian math adapted from daprice/Variablur (MIT).
//

#import "MetalBlur.h"
#import <Metal/Metal.h>
#import <UIKit/UIKit.h>
#include "include.h"
#include <vector>

// ─────────────────────────────────────────────────────────────
// Inline Metal Compute Shader — Two-Pass Gaussian Blur
// ─────────────────────────────────────────────────────────────
static NSString *const kBlurShaderSource = @R"(
#include <metal_stdlib>
using namespace metal;

// Gaussian weight for a given distance and sigma
inline half gaussian(half distance, half sigma) {
    const half exponent = -(distance * distance) / (2.0h * sigma * sigma);
    return (1.0h / (2.0h * M_PI_H * sigma * sigma)) * exp(exponent);
}

// Horizontal blur pass
kernel void blurHorizontal(
    texture2d<half, access::read>  inTex   [[texture(0)]],
    texture2d<half, access::write> outTex  [[texture(1)]],
    constant float &radius                 [[buffer(0)]],
    uint2 gid                              [[thread_position_in_grid]])
{
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;

    const half r = half(radius);
    if (r < 1.0h) {
        outTex.write(inTex.read(gid), gid);
        return;
    }

    const half sigma = r / 3.0h;
    const half maxSamples = min(r, 15.0h);
    const half interval = max(1.0h, r / maxSamples);

    half weight0 = gaussian(0.0h, sigma);
    half4 colorSum = half4(inTex.read(gid)) * weight0;
    half totalWeight = weight0;

    for (half d = interval; d <= r; d += interval) {
        half w = gaussian(d, sigma);
        int offset = int(d);

        int posX = int(gid.x) + offset;
        int negX = int(gid.x) - offset;
        int width = int(inTex.get_width());

        if (posX < width) {
            colorSum += half4(inTex.read(uint2(posX, gid.y))) * w;
            totalWeight += w;
        }
        if (negX >= 0) {
            colorSum += half4(inTex.read(uint2(negX, gid.y))) * w;
            totalWeight += w;
        }
    }

    outTex.write(colorSum / totalWeight, gid);
}

// Vertical blur pass
kernel void blurVertical(
    texture2d<half, access::read>  inTex   [[texture(0)]],
    texture2d<half, access::write> outTex  [[texture(1)]],
    constant float &radius                 [[buffer(0)]],
    uint2 gid                              [[thread_position_in_grid]])
{
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;

    const half r = half(radius);
    if (r < 1.0h) {
        outTex.write(inTex.read(gid), gid);
        return;
    }

    const half sigma = r / 3.0h;
    const half maxSamples = min(r, 15.0h);
    const half interval = max(1.0h, r / maxSamples);

    half weight0 = gaussian(0.0h, sigma);
    half4 colorSum = half4(inTex.read(gid)) * weight0;
    half totalWeight = weight0;

    for (half d = interval; d <= r; d += interval) {
        half w = gaussian(d, sigma);
        int offset = int(d);

        int posY = int(gid.y) + offset;
        int negY = int(gid.y) - offset;
        int height = int(inTex.get_height());

        if (posY < height) {
            colorSum += half4(inTex.read(uint2(gid.x, posY))) * w;
            totalWeight += w;
        }
        if (negY >= 0) {
            colorSum += half4(inTex.read(uint2(gid.x, negY))) * w;
            totalWeight += w;
        }
    }

    outTex.write(colorSum / totalWeight, gid);
}
)";

// ─────────────────────────────────────────────────────────────
// MetalBlur Implementation
// ─────────────────────────────────────────────────────────────

@interface MetalBlur ()

@property (nonatomic, strong) id<MTLDevice>              device;
@property (nonatomic, strong) id<MTLComputePipelineState> horizontalPipeline;
@property (nonatomic, strong) id<MTLComputePipelineState> verticalPipeline;
@property (nonatomic, strong) id<MTLTexture>              inputTexture;
@property (nonatomic, strong) id<MTLTexture>              intermediateTexture;
@property (nonatomic, strong) id<MTLTexture>              outputTexture;
@property (nonatomic, assign) int                         frameCounter;
@property (nonatomic, assign) CGSize                      lastCaptureSize;

@end

@implementation MetalBlur

+ (instancetype)shared {
    static MetalBlur *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[MetalBlur alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _blurRadius = 20.0f;
        _captureScale = 0.25f;
        _frameSkip = 2;
        _frameCounter = 0;
        _lastCaptureSize = CGSizeZero;
    }
    return self;
}

- (void)setupWithDevice:(id<MTLDevice>)device {
    self.device = device;

    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:kBlurShaderSource options:nil error:&error];
    if (!library) {
        NSLog(@"[MetalBlur] Failed to compile blur shader: %@", error);
        return;
    }

    id<MTLFunction> hFunc = [library newFunctionWithName:@"blurHorizontal"];
    id<MTLFunction> vFunc = [library newFunctionWithName:@"blurVertical"];

    self.horizontalPipeline = [device newComputePipelineStateWithFunction:hFunc error:&error];
    if (!self.horizontalPipeline) {
        NSLog(@"[MetalBlur] Failed to create horizontal pipeline: %@", error);
        return;
    }

    self.verticalPipeline = [device newComputePipelineStateWithFunction:vFunc error:&error];
    if (!self.verticalPipeline) {
        NSLog(@"[MetalBlur] Failed to create vertical pipeline: %@", error);
        return;
    }

    NSLog(@"[MetalBlur] Compute pipelines created successfully.");
}

// ─────────────────────────────────────────────────────────────
// Texture Management
// ─────────────────────────────────────────────────────────────

- (void)ensureTexturesForWidth:(NSUInteger)width height:(NSUInteger)height {
    if (self.inputTexture &&
        self.inputTexture.width == width &&
        self.inputTexture.height == height) {
        return; // Already the right size
    }

    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                   width:width
                                                                                  height:height
                                                                               mipmapped:NO];
    desc.storageMode = MTLStorageModeShared;
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;

    self.inputTexture        = [self.device newTextureWithDescriptor:desc];
    self.intermediateTexture  = [self.device newTextureWithDescriptor:desc];
    self.outputTexture       = [self.device newTextureWithDescriptor:desc];

    self.inputTexture.label        = @"BlurInput";
    self.intermediateTexture.label  = @"BlurIntermediate";
    self.outputTexture.label       = @"BlurOutput";

    NSLog(@"[MetalBlur] Textures allocated: %lux%lu", (unsigned long)width, (unsigned long)height);
}

// ─────────────────────────────────────────────────────────────
// Screen Capture
// ─────────────────────────────────────────────────────────────

- (BOOL)captureView:(UIView *)view {
    if (!self.device || !view) return NO;
    
    CGRect region = view.bounds;
    CGFloat scale = self.captureScale;
    CGSize scaledSize = CGSizeMake(region.size.width * scale, region.size.height * scale);

    if (scaledSize.width < 1 || scaledSize.height < 1) return NO;

    NSUInteger texW = (NSUInteger)ceilf(scaledSize.width);
    NSUInteger texH = (NSUInteger)ceilf(scaledSize.height);

    [self ensureTexturesForWidth:texW height:texH];

    // Render the entire game view hierarchy into a bitmap
    UIGraphicsBeginImageContextWithOptions(region.size, YES, scale);
    [view drawViewHierarchyInRect:region afterScreenUpdates:NO];
    UIImage *screenshot = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    if (!screenshot) return NO;

    // Upload pixels to inputTexture
    NSUInteger bytesPerRow = texW * 4;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    uint8_t *pixelData = (uint8_t *)calloc(texH * bytesPerRow, 1);

    CGContextRef ctx = CGBitmapContextCreate(pixelData, texW, texH, 8, bytesPerRow,
                                              colorSpace,
                                              kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextDrawImage(ctx, CGRectMake(0, 0, texW, texH), screenshot.CGImage);
    CGContextRelease(ctx);
    CGColorSpaceRelease(colorSpace);

    [self.inputTexture replaceRegion:MTLRegionMake2D(0, 0, texW, texH)
                          mipmapLevel:0
                            withBytes:pixelData
                          bytesPerRow:bytesPerRow];
    free(pixelData);

    self.lastCaptureSize = CGSizeMake(texW, texH);
    return YES;
}

// ─────────────────────────────────────────────────────────────
// Blur Execution
// ─────────────────────────────────────────────────────────────

- (void)captureAndBlur:(UIView *)gameView
         commandBuffer:(id<MTLCommandBuffer>)commandBuffer {

    if (!self.device || !self.horizontalPipeline || !self.verticalPipeline) return;
    if (!gameView) return;

    // Frame skipping: only re-capture every N frames
    self.frameCounter++;
    if (self.frameCounter % self.frameSkip != 0 && self.outputTexture) {
        _blurredTexture = self.outputTexture;
        return; // Reuse previous blur
    }

    // Capture on main thread
    if (![self captureView:gameView]) {
        _blurredTexture = self.outputTexture; // Keep last valid
        return;
    }

    NSUInteger texW = self.inputTexture.width;
    NSUInteger texH = self.inputTexture.height;

    // Scale blur radius for the lower-res texture
    float scaledRadius = self.blurRadius * self.captureScale;

    // Pass 1: Horizontal blur (input → intermediate)
    id<MTLComputeCommandEncoder> hEncoder = [commandBuffer computeCommandEncoder];
    [hEncoder setLabel:@"Blur Horizontal"];
    [hEncoder setComputePipelineState:self.horizontalPipeline];
    [hEncoder setTexture:self.inputTexture atIndex:0];
    [hEncoder setTexture:self.intermediateTexture atIndex:1];
    [hEncoder setBytes:&scaledRadius length:sizeof(float) atIndex:0];

    MTLSize threadGroupSize = MTLSizeMake(16, 16, 1);
    MTLSize threadGroups = MTLSizeMake((texW + 15) / 16, (texH + 15) / 16, 1);
    [hEncoder dispatchThreadgroups:threadGroups threadsPerThreadgroup:threadGroupSize];
    [hEncoder endEncoding];

    // Pass 2: Vertical blur (intermediate → output)
    id<MTLComputeCommandEncoder> vEncoder = [commandBuffer computeCommandEncoder];
    [vEncoder setLabel:@"Blur Vertical"];
    [vEncoder setComputePipelineState:self.verticalPipeline];
    [vEncoder setTexture:self.intermediateTexture atIndex:0];
    [vEncoder setTexture:self.outputTexture atIndex:1];
    [vEncoder setBytes:&scaledRadius length:sizeof(float) atIndex:0];

    [vEncoder dispatchThreadgroups:threadGroups threadsPerThreadgroup:threadGroupSize];
    [vEncoder endEncoding];

    _blurredTexture = self.outputTexture;
}

// ─────────────────────────────────────────────────────────────
// ImGui Source Integration Bridge
// ─────────────────────────────────────────────────────────────

extern "C" void ImGui_RenderBlurBackground(ImGuiWindow *window) {
    if (!window || (window->Flags & ImGuiWindowFlags_ChildWindow)) return; // Only for main windows/popups
    
    MetalBlur *instance = [MetalBlur shared];
    if (!instance.blurredTexture) return;

    ImVec2 pos = window->Pos;
    ImVec2 size = window->Size;
    ImVec2 screenSize = ImGui::GetIO().DisplaySize;

    if (screenSize.x <= 0 || screenSize.y <= 0) return;

    // Calculate UVs based on window position on screen
    ImVec2 uv0 = ImVec2(pos.x / screenSize.x, pos.y / screenSize.y);
    ImVec2 uv1 = ImVec2((pos.x + size.x) / screenSize.x, (pos.y + size.y) / screenSize.y);

    // Subtle dark tint (180/255) to make it look like a premium glass panel
    // 0.5f overscan to ensure no pixel gaps at the edges
    ImVec2 p_min = ImVec2(pos.x - 0.5f, pos.y - 0.5f);
    ImVec2 p_max = ImVec2(pos.x + size.x + 0.5f, pos.y + size.y + 0.5f);

    window->DrawList->AddImageRounded(
        (__bridge ImTextureID)instance.blurredTexture,
        p_min, p_max,
        uv0, uv1,
        IM_COL32(180, 180, 180, 255),
        window->WindowRounding
    );
}

@end
