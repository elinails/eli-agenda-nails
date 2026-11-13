from PIL import Image
import os

# Abrir el logo original (webp)
logo_path = "logo elima negro marketplace.png"
img = Image.open(logo_path)
print(f"Original: {img.size}, mode={img.mode}")

# Convertir a RGBA si es necesario
if img.mode != 'RGBA':
    img = img.convert('RGBA')

# Crear icono 192x192
icon192 = img.resize((192, 192), Image.LANCZOS)
icon192.save("icon-192.png", "PNG", optimize=True)
print(f"icon-192.png generado: {icon192.size}")

# Crear icono 512x512
icon512 = img.resize((512, 512), Image.LANCZOS)
icon512.save("icon-512.png", "PNG", optimize=True)
print(f"icon-512.png generado: {icon512.size}")

# Crear maskable 512x512 con padding seguro (zonas seguras 40% central)
maskable = Image.new('RGBA', (512, 512), (0, 0, 0, 0))
# El logo se escala a 80% del tamaño (zona segura 40% = 204.8px cada lado)
logo_size = int(512 * 0.8)
logo_for_maskable = img.resize((logo_size, logo_size), Image.LANCZOS)
# Centrar
pos = (512 - logo_size) // 2
maskable.paste(logo_for_maskable, (pos, pos), logo_for_maskable)
maskable.save("icon-maskable-512.png", "PNG", optimize=True)
print(f"icon-maskable-512.png generado: {maskable.size}")

# Generar también apple-touch-icon 180x180
apple_touch = img.resize((180, 180), Image.LANCZOS)
apple_touch.save("apple-touch-icon.png", "PNG", optimize=True)
print(f"apple-touch-icon.png generado: {apple_touch.size}")

# Generar favicon 32x32
favicon32 = img.resize((32, 32), Image.LANCZOS)
favicon32.save("favicon-32.png", "PNG", optimize=True)
print(f"favicon-32.png generado: {favicon32.size}")

print("\nTodos los íconos generados correctamente!")