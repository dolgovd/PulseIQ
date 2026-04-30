import os
import subprocess

# Paths
source_img = "/Users/dima/.gemini/antigravity/brain/5627459e-2de5-4624-bec9-c7beeea89840/pulseiq_large_heart_icon_1777565055785.png"
assets_dir = "/Users/dima/Documents/Work/PulseIQ/PulseIQ/Assets.xcassets/AppIcon.appiconset"

# Icon sizes needed by macOS & iOS
sizes = [
    ("icon_16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512.png", 512),
    ("icon_512x512@2x.png", 1024),
    ("icon_1024.png", 1024)
]

print("Starting CLEAN icon generation...")
for filename, size in sizes:
    target_path = os.path.join(assets_dir, filename)
    print(f"Generating {filename} ({size}x{size})...")
    # Use macOS built-in sips tool to resize and convert to png
    subprocess.run(["sips", "-z", str(size), str(size), "-s", "format", "png", source_img, "--out", target_path], check=True, capture_output=True)

print("\nSuccess! All App Icons have been replaced with the new, watermark-free image.")
print("Please clean your Xcode build folder (Shift + Cmd + K) and rebuild to see the new icon!")
