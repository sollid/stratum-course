// Проверка архива и каталога: архив собирается повторяемо (тот же sha256 при каждой сборке и в любом часовом поясе),
// каталог .claude-plugin/marketplace.json совпадает со свежей сборкой и укладывается в требования формата Claude Code.
// Запуск: node tests/pack-check.mjs   Код выхода 0 — всё прошло.
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { unzipSync } from 'fflate';
import { buildArchive, listFiles, readManifest, check, archiveName, MARKETPLACE_NAME } from '../tools/pack.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const src = join(root, 'plugin');
const catalogPath = join(root, '.claude-plugin', 'marketplace.json');

let passed = 0; let failed = 0;
const failures = [];
function ok(name, cond, detail = '') {
  if (cond) { passed++; console.log(`  ok   ${name}`); } else { failed++; failures.push(name); console.log(`  FAIL ${name}${detail ? ` -- ${detail}` : ''}`); }
}

const a = buildArchive(src);
const b = buildArchive(src);
ok('две сборки подряд дают один и тот же sha256', a.sha256 === b.sha256, `${a.sha256} / ${b.sha256}`);

// Другой часовой пояс в отдельном процессе: время файлов в zip не должно зависеть от пояса
const packUrl = new URL('../tools/pack.mjs', import.meta.url).href;
const zones = ['Pacific/Auckland', 'America/Los_Angeles', 'UTC'];
const shas = zones.map((tz) => {
  const r = spawnSync(process.execPath, ['--input-type=module', '-e', `import { buildArchive } from ${JSON.stringify(packUrl)}; console.log(buildArchive(${JSON.stringify(src)}).sha256 + ' ' + new Date(2026, 0, 1).getTimezoneOffset());`], { env: { ...process.env, TZ: tz }, encoding: 'utf8' });
  return (r.stdout || '').trim();
});
ok(`сборка в трёх часовых поясах (${zones.join(', ')}) даёт тот же sha256`, shas.every((s) => s.split(' ')[0] === a.sha256), shas.join(' | '));

const manifest = readManifest(src);
const catalog = JSON.parse(readFileSync(catalogPath, 'utf8'));
const entry = catalog.plugins?.[0];
ok('каталог: имя каталога и плагина, один плагин', catalog.name === MARKETPLACE_NAME && catalog.plugins.length === 1 && entry.name === manifest.name && !!catalog.owner?.name);
ok('каталог: источник archive, адрес https на github.com, имя файла по версии', entry.source?.source === 'archive' && /^https:\/\/github\.com\/[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+\/releases\/download\/v[0-9][0-9A-Za-z.+-]*\/[A-Za-z0-9._-]+\.zip$/.test(entry.source.url) && entry.source.url.endsWith(`/v${manifest.version}/${archiveName(manifest.version)}`), entry.source?.url);
ok('каталог: sha256 — 64 шестнадцатеричных знака и равен sha256 свежего архива', /^[0-9a-f]{64}$/.test(entry.source.sha256) && entry.source.sha256 === a.sha256, `${entry.source.sha256} / ${a.sha256}`);
ok('каталог: версия в записи равна версии в манифесте плагина', entry.version === manifest.version);
const c = check({ src, catalog: catalogPath });
ok('каталог целиком совпадает с тем, что собирает tools/pack.mjs', c.same);

// Состав архива
const files = unzipSync(a.zip);
const names = Object.keys(files).sort();
ok('в архиве те же файлы, что в папке plugin/, манифест в корне архива', JSON.stringify(names) === JSON.stringify(listFiles(src)) && names.includes('.claude-plugin/plugin.json'), names.join(','));
ok(`архив невелик (${a.zip.length} байт: лимит загрузки у Claude Code 256 МиБ)`, a.zip.length < 5 * 1024 * 1024);
const total = Object.values(files).reduce((n, f) => n + f.length, 0);
ok('соотношение распаковки к архиву меньше 50 (лимит Claude Code)', total / a.zip.length < 50, `${total}/${a.zip.length}`);
ok('в текстовых файлах архива нет CRLF', Object.entries(files).every(([, f]) => !Buffer.from(f).includes(Buffer.from('\r\n'))));
ok('в архиве нет исполняемых файлов и картинок (только текст)', names.every((n) => !/\.(exe|dll|dylib|so|png|jpg|zip)$/i.test(n)));

// Режим Unix в архиве: запускаемые файлы получают бит исполнения (по записи в центральном каталоге zip)
const zipBuf = Buffer.from(a.zip);
const modes = {};
for (let i = zipBuf.length - 22; i >= 0; i--) {
  if (zipBuf.readUInt32LE(i) !== 0x06054b50) continue;
  let p = zipBuf.readUInt32LE(i + 16);
  const n = zipBuf.readUInt16LE(i + 10);
  for (let k = 0; k < n; k++) {
    const nameLen = zipBuf.readUInt16LE(p + 28); const extraLen = zipBuf.readUInt16LE(p + 30); const commentLen = zipBuf.readUInt16LE(p + 32);
    const os = zipBuf.readUInt8(p + 5);
    const attrs = zipBuf.readUInt32LE(p + 38);
    modes[zipBuf.toString('utf8', p + 46, p + 46 + nameLen)] = { os, mode: (attrs >>> 16) & 0o7777 };
    p += 46 + nameLen + extraLen + commentLen;
  }
  break;
}
const execNames = names.filter((n) => (n.startsWith('bin/') && !n.endsWith('.cmd')) || (n.startsWith('scripts/') && n.endsWith('.sh')));
ok(`запускаемые файлы (${execNames.length}) в архиве с режимом 0755, система создания — Unix`, execNames.length > 0 && execNames.every((n) => modes[n]?.mode === 0o755 && modes[n]?.os === 3), JSON.stringify(execNames.map((n) => [n, modes[n]])));
ok('остальные файлы — 0644', names.filter((n) => !execNames.includes(n)).every((n) => modes[n]?.mode === 0o644));

console.log(`\nИтого: прошло ${passed}, не прошло ${failed}, пропущено 0`);
if (failed) { console.log(`Не прошли: ${failures.join('; ')}`); process.exit(1); }
