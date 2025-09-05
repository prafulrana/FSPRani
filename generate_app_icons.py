#!/usr/bin/env python3
"""
Generate app icons for FSPRani3
Creates required icon sizes for iOS app submission
"""

from PIL import Image, ImageDraw, ImageFont
import os

def create_base_icon(size=1024):
    """Create a base icon design for FSPRani"""
    # Create a new image with a gradient background
    img = Image.new('RGB', (size, size), color='#1E88E5')
    draw = ImageDraw.Draw(img)
    
    # Create gradient effect
    for i in range(size//2):
        alpha = int(255 * (1 - i/(size//2)))
        color = (30 + i//8, 136 + i//8, 229 - i//4)
        draw.ellipse([i, i, size-i, size-i], fill=color)
    
    # Draw a ball shape in the center
    ball_size = size // 3
    ball_pos = (size//2 - ball_size//2, size//2 - ball_size//2, 
                size//2 + ball_size//2, size//2 + ball_size//2)
    
    # Ball gradient
    draw.ellipse(ball_pos, fill='#FFD54F')
    
    # Add highlight to ball
    highlight_size = ball_size // 3
    highlight_pos = (size//2 - ball_size//3, size//2 - ball_size//3,
                     size//2 - ball_size//3 + highlight_size, 
                     size//2 - ball_size//3 + highlight_size)
    draw.ellipse(highlight_pos, fill='#FFECB3')
    
    # Draw FSP text
    text = "FSP"
    # Try to use a system font, fallback to default if not available
    try:
        font_size = size // 6
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", font_size)
    except:
        font = ImageFont.load_default()
    
    # Get text size
    bbox = draw.textbbox((0, 0), text, font=font)
    text_width = bbox[2] - bbox[0]
    text_height = bbox[3] - bbox[1]
    
    # Position text at bottom
    text_x = (size - text_width) // 2
    text_y = size - size//4
    
    # Draw text with shadow
    draw.text((text_x+3, text_y+3), text, fill='#00000033', font=font)
    draw.text((text_x, text_y), text, fill='white', font=font)
    
    return img

def generate_icons():
    """Generate all required icon sizes"""
    # Create base icon
    base_icon = create_base_icon(1024)
    
    # Define required sizes
    icon_sizes = [
        (20, "Icon-20.png"),
        (29, "Icon-29.png"),
        (40, "Icon-40.png"),
        (58, "Icon-58.png"),
        (60, "Icon-60.png"),
        (76, "Icon-76.png"),
        (80, "Icon-80.png"),
        (87, "Icon-87.png"),
        (120, "Icon-120.png"),  # Required for iPhone
        (152, "Icon-152.png"),  # Required for iPad
        (167, "Icon-167.png"),
        (180, "Icon-180.png"),
        (1024, "Icon-1024.png"),
    ]
    
    # Create icons directory
    icons_dir = "/Volumes/FSP/FSPRani3/FSPRani3App/Assets.xcassets/AppIcon.appiconset"
    os.makedirs(icons_dir, exist_ok=True)
    
    # Generate each size
    for size, filename in icon_sizes:
        resized = base_icon.resize((size, size), Image.Resampling.LANCZOS)
        filepath = os.path.join(icons_dir, filename)
        resized.save(filepath, "PNG")
        print(f"Generated: {filename} ({size}x{size})")
    
    # Create Contents.json for the app icon set
    contents_json = '''
{
  "images" : [
    {
      "filename" : "Icon-40.png",
      "idiom" : "iphone",
      "scale" : "2x",
      "size" : "20x20"
    },
    {
      "filename" : "Icon-60.png",
      "idiom" : "iphone",
      "scale" : "3x",
      "size" : "20x20"
    },
    {
      "filename" : "Icon-58.png",
      "idiom" : "iphone",
      "scale" : "2x",
      "size" : "29x29"
    },
    {
      "filename" : "Icon-87.png",
      "idiom" : "iphone",
      "scale" : "3x",
      "size" : "29x29"
    },
    {
      "filename" : "Icon-80.png",
      "idiom" : "iphone",
      "scale" : "2x",
      "size" : "40x40"
    },
    {
      "filename" : "Icon-120.png",
      "idiom" : "iphone",
      "scale" : "3x",
      "size" : "40x40"
    },
    {
      "filename" : "Icon-120.png",
      "idiom" : "iphone",
      "scale" : "2x",
      "size" : "60x60"
    },
    {
      "filename" : "Icon-180.png",
      "idiom" : "iphone",
      "scale" : "3x",
      "size" : "60x60"
    },
    {
      "filename" : "Icon-20.png",
      "idiom" : "ipad",
      "scale" : "1x",
      "size" : "20x20"
    },
    {
      "filename" : "Icon-40.png",
      "idiom" : "ipad",
      "scale" : "2x",
      "size" : "20x20"
    },
    {
      "filename" : "Icon-29.png",
      "idiom" : "ipad",
      "scale" : "1x",
      "size" : "29x29"
    },
    {
      "filename" : "Icon-58.png",
      "idiom" : "ipad",
      "scale" : "2x",
      "size" : "29x29"
    },
    {
      "filename" : "Icon-40.png",
      "idiom" : "ipad",
      "scale" : "1x",
      "size" : "40x40"
    },
    {
      "filename" : "Icon-80.png",
      "idiom" : "ipad",
      "scale" : "2x",
      "size" : "40x40"
    },
    {
      "filename" : "Icon-76.png",
      "idiom" : "ipad",
      "scale" : "1x",
      "size" : "76x76"
    },
    {
      "filename" : "Icon-152.png",
      "idiom" : "ipad",
      "scale" : "2x",
      "size" : "76x76"
    },
    {
      "filename" : "Icon-167.png",
      "idiom" : "ipad",
      "scale" : "2x",
      "size" : "83.5x83.5"
    },
    {
      "filename" : "Icon-1024.png",
      "idiom" : "ios-marketing",
      "scale" : "1x",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
'''
    
    # Save Contents.json
    contents_path = os.path.join(icons_dir, "Contents.json")
    with open(contents_path, 'w') as f:
        f.write(contents_json.strip())
    print(f"\nGenerated Contents.json")
    
    print(f"\n✅ All icons generated successfully in:\n{icons_dir}")

if __name__ == "__main__":
    generate_icons()