import fs from 'fs';

const inputPath = process.argv[2];
if (!inputPath) {
  console.error('Usage: node stringify.js <path-to-json-file>');
  process.exit(1);
}

try {
  const data = fs.readFileSync(inputPath, 'utf8');
  const json = JSON.parse(data);
  const output = JSON.stringify(json);
  console.log(output);
} catch (err) {
  console.error('Error reading or parsing file:', err.message);
  process.exit(1);
}