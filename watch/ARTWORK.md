# Soap bubble artwork

`chime Watch App/Assets.xcassets/SoapBubble.imageset/soap-bubble.png` was generated with the built-in image-generation tool. SwiftUI adds deformation and moving grazing light. This is animated photographic artwork, not a realtime ray-traced simulation.

The bubble is small while idle or muted and expands when the microphone is enabled. Its pulse follows the RMS energy of PCM audio, with a noise floor to prevent quiet input from driving audio pulses. Output metering follows the player’s sample clock rather than incoming network packets. The fixed tap target does not shrink with the artwork. Reduce Motion removes pulses and animated size changes; dimmed, inactive, and offscreen states pause motion.

Listening adds a slow, shallow breath. Speaking adds faster deformation and a
stronger audio pulse. Research slowly orbits the grazing reflection and stretches
the film, based on the gateway's actual work count; speech takes priority while
the agent talks. Input audio still pulses the bubble during research. Muting keeps
the bubble small even when research continues. A light click on Watch, or a soft
impact on iPhone, signals successful microphone startup once per connection.

The center page has no text, scroll container, or Crown-driven movement. Horizontal swipes reveal memory on the left and preferences on the right. The system clock remains visible.

## App icon and widgets

The app icon, voice screen, and full-color widgets all use the same detailed soap
bubble on black. The app icon is the opaque 1024 × 1024 PNG in
`chime Watch App/Assets.xcassets/AppIcon.appiconset/chime-bubble.png` and is already
assigned in the asset catalog. watchOS applies its own circular icon mask.
The iPhone uses an identical copy in `ios/Assets.xcassets/AppIcon.appiconset/`;
its voice artwork is copied into `ios/SharedAssets.xcassets/SoapBubble.imageset/`.
Keep those copies in sync when replacing the original artwork.

The icon is a size-only export of the original artwork. To regenerate it after an
intentional artwork update, run from the repository root:

```bash
sips -z 1024 1024 \
  'chime Watch App/Assets.xcassets/SoapBubble.imageset/soap-bubble.png' \
  --out 'chime Watch App/Assets.xcassets/AppIcon.appiconset/chime-bubble.png'
```

Widgets decode smaller thumbnails to stay within WidgetKit's bitmap limits.
Tinted complications use a bubble outline to stay readable on the selected face.

## Original generation prompt


> Use case: photorealistic-natural. Asset type: square image asset for an Apple Watch voice assistant, not an app mockup. Create an extraordinarily realistic macro photograph of ONE floating soap bubble, perfectly centered, nearly spherical, diameter exactly 84% of the square image, entirely in frame with equal generous black margins. Background is perfectly uniform pure black #000000, no surface, no cast shadow, no horizon. The bubble is a hollow air-filled ultra-thin soap film, NOT a glass marble, pearl, solid ball, planet, or neon orb. Its center is almost optically clear, dark because the background is black. Physically accurate thin-film interference: exquisitely fine curling fluid ribbons of opalescent pale cyan, rose, amber and violet around the outer hemisphere, delicate subtle striations and organic liquid-film swirls, varying thickness, subtle refractive double contours. Large realistic softbox/window reflections arc across upper-left quadrant, secondary curved pale reflection at lower-right; these are highlights in the soap film with realistic falloff and spherical distortion, NOT flat painted white ovals. Reflections should feel like natural studio light, tangible real-life soap bubble, luxurious restrained color, luminous sharp thin rim and photographic detail visible even at small size. Front view, 100mm macro lens, focus stacked, beautiful complex translucent surface. No lettering, logos, interface, extra bubbles, stars, particles, decorative glow, blue filled center, or illustration. Save the completed image as a local file for use as a project asset.
