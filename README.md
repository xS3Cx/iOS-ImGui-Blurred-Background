# ImGui iOS Native UIKit Blur Integration Guide
========================================


This guide demonstrates how to achieve a high-performance, 0-CPU-cost "Glassmorphism" (blurred background) effect for ImGui windows on iOS using Apple's highly optimized native `UIVisualEffectView`.


![IMG_3DA728872478-1](https://github.com/user-attachments/assets/8e708707-f7c2-40e7-9b4e-5128116bdd9e)


This package provides a high-performance "Glassmorphism" (blurred background) effect for ImGui windows on iOS using Metal.


By utilizing the native UIKit compositor, this approach provides superior performance with zero CPU overhead, and completely avoids complex hooks into ImGui's core rendering pipeline.

---

## 1. Zero ImGui Core Modifications
You **do not** need to modify `imgui.cpp` or any core ImGui files to achieve this effect. Everything is handled seamlessly at the iOS View layer.

## 2. Setup `UIVisualEffectView` in your View Hierarchy

In your ImGui rendering setup file (e.g., `ImGuiDrawView.mm`), you need to insert a `UIVisualEffectView` *behind* your `MTKView`.

```objc
@interface ImGuiDrawView () <MTKViewDelegate>
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) MTKView *mtkView;
@end

// Inside your initialization method (like loadView or initWithFrame)
- (void)setupViews {
    // 1. Root view must be a plain UIView
    self.view = [[UIView alloc] initWithFrame:CGRectMake(0, 0, screenW, screenH)];
    self.view.backgroundColor = [UIColor clearColor];

    // 2. Add the native blur view
    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    self.blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    [self.view addSubview:self.blurView];

    // 3. Add the MTKView on top
    self.mtkView = [[MTKView alloc] initWithFrame:self.view.bounds device:device];
    self.mtkView.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.mtkView];
}
```

## 3. Dynamically Sync Blur with ImGui Window

The native blur view sits behind ImGui, so we must dynamically resize and move it to match the active ImGui window's dimensions every frame.

When you render your ImGui menu, capture its position and size:
```cpp
// In your Menu.cpp
extern ImVec2 MenuSize;
extern ImVec2 MenuOrigin;

void Menu::render() {
    ImGui::Begin("My Mod Menu");
    {
        ImGuiWindow* CurrentWindow = ImGui::GetCurrentWindow();
        MenuSize = CurrentWindow->Size;
        MenuOrigin = CurrentWindow->Pos;
        
        // Render UI...
    }
    ImGui::End();
}
```

Inside your Metal `drawInMTKView:` method, update the blur view's frame *after* `Menu::render()` is called:
```objc
if (MenuIsOpen) {
    Menu::render();
    
    // Sync native blur frame to match ImGui window perfectly
    self.blurView.frame = CGRectMake(MenuOrigin.x, MenuOrigin.y, MenuSize.x, MenuSize.y);
    
    // Apply rounded corners to match ImGui styling
    self.blurView.layer.cornerRadius = ImGui::GetStyle().WindowRounding;
    self.blurView.layer.masksToBounds = YES;
}
```

## 4. Visual Styles
For the native UIKit blur to show through your ImGui windows, you must ensure your ImGui `WindowBg` color is semi-transparent!

```cpp
// In your theme setup:
ImVec4* colors = ImGui::GetStyle().Colors;
colors[ImGuiCol_WindowBg] = ImVec4(10/255.f, 17/255.f, 28/255.f, 100/255.f); // Adjust alpha (100) to taste!
```
