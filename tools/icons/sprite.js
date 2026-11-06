const fs = require('fs');
const files = fs.readdirSync('.').filter(f => f.endsWith('.svg'));
const symbols = [];
for (const f of files.sort()) {
  const id = f.replace(/^out_/, 'i-').replace(/^fill_/, 'i-f-').replace(/\.svg$/, '');
  const svg = fs.readFileSync(f, 'utf8');
  const m = svg.match(/<svg[^>]*viewBox="([^"]+)"[^>]*>(.*)<\/svg>/s);
  if (!m) { console.error('no match', f); continue; }
  const body = m[2].replace(/<path /g, '<path fill="currentColor" ');
  symbols.push(`<symbol id="${id}" viewBox="${m[1]}">${body}</symbol>`);
}
fs.writeFileSync('sprite.html', `<svg xmlns="http://www.w3.org/2000/svg" style="display:none" aria-hidden="true">${symbols.join('')}</svg>`);
console.log('symbols:', symbols.length, 'bytes:', fs.statSync('sprite.html').size);
