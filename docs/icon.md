# Иконка приложения

Исходник: `Assets/AppIcon.png`. Создан встроенным ImageGen; сторонние страницы манги в генерацию не передавались. Внешний фон прозрачный. Название и буквы в иконке отсутствуют, поэтому переименование не требует новой графики.

`scripts/build-icon.sh` создаёт размеры 16–1024 px и упаковывает их в `bin/AppIcon.icns`. Основная сборка копирует иконку в `Contents/Resources` и указывает `CFBundleIconFile` в `Info.plist`, согласно [документации Apple](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CoreFoundationKeys.html#//apple_ref/doc/uid/TP40009249-SW10).

## Промпт генерации

Use case: logo-brand. Create one finished macOS application icon for a local manga dialogue extraction app, name not yet decided. No text or letters. A beautifully crafted off-white manga page with a few bold black panel dividers, and one large sculptural white speech balloon hovering in front, containing three short black horizontal text strokes. One restrained electric blue accent suggesting text selection. Premium native macOS icon design, softly rounded square dark ink-blue base, subtle ceramic-paper material, gentle bevel and convincing soft lighting, clean high-contrast silhouette that remains legible at 32px. Front view, centered, no perspective tilt. Single icon only, no collage, no mockup desktop, no border captions, no brand names, no recognizable manga characters, no magnifying glass, no tiny details. Square 1024x1024 canvas; icon occupies about 84% of canvas with a genuinely transparent outside margin and transparent corners. Keep all artwork inside the rounded square silhouette, no external shadow outside the icon.
