// Generate PWA icons from the official logo
// Safe-zone: 80% scale to avoid mask cutoffs on Android/iOS
// Usage: node generate-icons.js

const fs = require('fs');
const path = require('path');
const sharp = require('sharp');

const ROOT = __dirname;
// Try multiple possible names for the official logo
const LOGO_NAMES = [
    'Elima Hub para app instalada.png',
    'logo elima negro marketplace.png',
    'logo eli png 1.png',
    'logo eli png 2.png'
];
const LOGO_SRC = LOGO_NAMES.map(name => path.join(ROOT, name)).find(f => fs.existsSync(f)) || path.join(ROOT, 'Elima Hub para app instalada.png');

const OUTPUT_DIR = ROOT;

// Safe-zone percentage (80% = 0.8 means logo takes 80% of icon size)
const SAFE_ZONE = 0.8;

// Icon configurations
const ICONS = [
    { name: 'favicon-16.png', size: 16, bg: null, safeZone: 0.75 },
    { name: 'favicon-32.png', size: 32, bg: null, safeZone: 0.8 },
    { name: 'apple-touch-icon.png', size: 180, bg: '#000000', safeZone: 0.8 },
    { name: 'icon-192.png', size: 192, bg: null, safeZone: 0.8 },
    { name: 'icon-512.png', size: 512, bg: null, safeZone: 0.85 },
    { name: 'icon-maskable-512.png', size: 512, bg: '#000000', safeZone: 0.8 }
];

async function generateIcon(config) {
    const { name, size, bg, safeZone } = config;
    const outputPath = path.join(OUTPUT_DIR, name);
    
    try {
        // Load the logo
        const logoBuffer = await sharp(LOGO_SRC).toBuffer();
        
        // First, resize the logo to fit within safe-zone
        const logoSafeSize = Math.round(size * safeZone);
        const resizedLogo = await sharp(logoBuffer)
            .resize(logoSafeSize, logoSafeSize, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
            .toBuffer();
        
        // Get the resized logo dimensions
        const resizedMeta = await sharp(resizedLogo).metadata();
        const offsetX = Math.floor((size - resizedMeta.width) / 2);
        const offsetY = Math.floor((size - resizedMeta.height) / 2);
        
        if (bg) {
            // Create a colored background (for maskable icons)
            const bgImage = {
                create: {
                    width: size,
                    height: size,
                    channels: 4,
                    background: { r: 0, g: 0, b: 0, alpha: 1 }
                }
            };
            
            // Composite the resized logo on the background
            await sharp(bgImage)
                .composite([{
                    input: resizedLogo,
                    top: offsetY,
                    left: offsetX
                }])
                .png({ compressionLevel: 9 })
                .toFile(outputPath);
        } else {
            // Just save the resized logo
            await sharp(resizedLogo)
                .png({ compressionLevel: 9 })
                .toFile(outputPath);
        }
        
        console.log(`✓ Generado: ${name} (${size}x${size})${bg ? ' (fondo negro, safe-zone ' + Math.round(safeZone * 100) + '%)' : ''}`);
        return true;
    } catch (e) {
        console.error(`ERROR generando ${name}:`, e.message);
        return false;
    }
}

async function main() {
    console.log('Generando iconos PWA desde:', LOGO_SRC);
    console.log('Salida en:', OUTPUT_DIR);
    console.log('---');
    
    if (!fs.existsSync(LOGO_SRC)) {
        console.error(`ERROR: El archivo ${LOGO_SRC} no existe.`);
        process.exit(1);
    }
    
    let success = true;
    for (const icon of ICONS) {
        const ok = await generateIcon(icon);
        if (!ok) success = false;
    }
    
    console.log('---');
    if (success) {
        console.log('¡Todos los iconos generados correctamente!');
    } else {
        console.log('Algunos iconos no se pudieron generar.');
        process.exit(1);
    }
}

main();