const fs = require('fs');
try {
    const data = JSON.parse(fs.readFileSync('manifest.json', 'utf8'));
    console.log('manifest.json is valid JSON');
    console.log('Name:', data.name);
    console.log('Icons count:', (data.icons || []).length);
} catch(e) {
    console.error('Invalid JSON:', e.message);
    process.exit(1);
}