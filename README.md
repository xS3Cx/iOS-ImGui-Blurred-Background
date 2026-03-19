# ImGui iOS Metal Blur Integration Guide
========================================


![IMG_3DA728872478-1](https://github.com/user-attachments/assets/8e708707-f7c2-40e7-9b4e-5128116bdd9e)


This package provides a high-performance "Glassmorphism" (blurred background) effect for ImGui windows on iOS using Metal.

## Files included:
- `MetalBlur.h`
- `MetalBlur.mm`

---

## 1. Setup Files
Move `MetalBlur.h` and `MetalBlur.mm` into your ImGui source directory (e.g., where `imgui.cpp` is located).

## 2. Modify ImGui Core (`imgui.cpp`)
To automate the blur for every window, you need to add a bridge in your ImGui source code.

1. At the top of `imgui.cpp`, add the bridge declaration:
   ```cpp
   extern "C" void ImGui_RenderBlurBackground(ImGuiWindow* window);
   ```

2. Inside the `RenderWindowDecorations` function, find where the window background is drawn and inject the blur call:
   ```cpp
   // Inside RenderWindowDecorations
   if (!(flags & ImGuiWindowFlags_NoBackground))
   {
       // Inject Metal Blur before standard background
       ImGui_RenderBlurBackground(window);
       
       ImU32 bg_col = GetColorU32(GetWindowBgColorIdx(window));
       ...
   }
   ```

## 3. Integrate in your Render Loop (`ImGuiDrawView.mm`)
The system needs to capture the game screen before drawing ImGui.

1. Import the header in your main rendering file:
   ```objc
   #import "MetalBlur.h"
   ```

2. In your rendering function (e.g., `drawInMTKView:`), directly BEFORE `ImGui::Render()`, call the capture method:
   ```objc
   [[MetalBlur shared] captureAndBlur:gameRootView commandBuffer:commandBuffer];
   ```
   *Note: `gameRootView` is just a variable name for your main game view/window root. It means nothing special, you can name it whatever you want in your code.*

## 4. Visual Styles
For the blur to be visible, ensure your ImGui window background color has some transparency:
```cpp
ImGui::SetNextWindowBgAlpha(0.0f); // Fully transparent background
```

---

