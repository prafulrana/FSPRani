# FSP Rani - Real-time Ball Tracking iOS App

A high-performance iOS app that uses YOLOv8m for real-time ball detection with Metal-accelerated rendering.

## Features

- **30 FPS Real-time Detection** - Smooth ball tracking without frame drops
- **No Distortion Pipeline** - Full camera view with 1:1 pixel mapping
- **Color-Coded Object Detection** - Visual identification of different object types:
  - 🟢 Sports Ball (Green)
  - 🔵 Person (Blue)
  - 🟡 Chair (Yellow)
  - 🟠 Skateboard (Orange)
  - 🟣 Other Objects (Various colors)

- **Pure Pipeline Architecture** - Every frame processed through YOLO model
- **Metal Shader Rendering** - GPU-accelerated YUV to RGB conversion with detection overlay
- **Full Screen Experience** - Optimized for iPhone with proper letterboxing

## Technical Stack

- **Model**: YOLOv8m (CoreML optimized)
- **Framework**: Vision + Metal
- **Rendering**: Single-pass Metal shader pipeline
- **Performance**: ANE (Apple Neural Engine) accelerated

## Architecture

```
Camera (1080x1920) → Vision/CoreML → YOLO Detection → Metal Rendering → Display
```

- No pixel distortion from camera to display
- Direct passthrough with detection overlay
- Efficient single-blit rendering

## Requirements

- iOS 17.0+
- iPhone with A12 Bionic chip or later
- Camera access permission

## Building

1. Open `FSPRani3.xcodeproj` in Xcode
2. Select your development team
3. Build and run on device (camera required)

## Performance

- Consistent 30 FPS detection rate
- Minimal latency (<50ms)
- Smooth confidence-based fade effects
- Color-coded object identification

## License

MIT

---

Built with YOLOv8 and Metal for optimal iOS performance.