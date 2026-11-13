// Generate PWA icons from the official logo
// Usage: node generate-icons.js

const fs = require('fs');
const path = require('path');
const sharp = require('sharp');

const ROOT = __dirname;
const LOGO_SRC = path.join(ROOT, 'logo elima negro marketplace.png');
const OUTPUT_DIR = ROOT;

// Icon configurations
const ICONS = [
    { name: 'favicon-16.png', size: 16, bg: null },
    { name: 'favicon-32.png', size: 32, bg: null },
    { name: 'apple-touch-icon.png', size: 180, bg: '#000000' },
    { name: 'icon-192.png', size: 192, bg: null },
    { name: 'icon-512.png', size: 512, bg: null },
    { name: 'icon-maskable-512.png', size: 512, bg: null }
];

async function generateIcon(config) {
    const { name, size, bg } = config;
    const outputPath = path.join(OUTPUT_DIR, name);
    
    try {
        // Load the logo and resize to fit within the target size
        const logoBuffer = await sharp(LOGO_SRC)
            .resize(size, size, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
            .toBuffer();
        
        if (bg) {
            // Get logo dimensions after resize
            const logoMeta = await sharp(logoBuffer).metadata();
            const offsetX = Math.floor((size - logoMeta.width) / 2);
            const offsetY = Math.floor((size - logoMeta.height) / 2);
            
            // Create a black background and composite the logo centered
            await sharp({
                create: {
                    width: size,
                    height: size,
                    channels: 4,
                    background: { r: 0, g: 0, b: 0, alpha: 1 }
                }
            })
            .composite([{ input: logoBuffer, top: offsetY, left: offsetX }])
            .png({ compressionLevel: 9 })
            .toFile(outputPath);
        } else {
            // Just save the resized logo
            await sharp(logoBuffer)
                .png({ compressionLevel: 9 })
                .toFile(outputPath);
        }
        
        console.log(`✓ Generado: ${name} (${size}x${size})${bg ? ' (fondo negro)' : ''}`);
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