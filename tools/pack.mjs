// Сборка архива плагина (zip, корень плагина в корне архива) и записи каталога marketplace.json с источником archive.
// Повторяемо: одно и то же дерево файлов даёт один и тот же архив и один и тот же sha256 на любой машине:
// файлы идут по алфавиту, время файлов фиксировано, уровень сжатия один, переводы строк в текстовых файлах приводятся к LF,
// режим Unix задаётся по имени (запускаемые файлы bin/ и scripts/*.sh получают 0755), а сам сжимающий код — чистый JavaScript (fflate), а не zlib из Node.
//
// Использование (из корня репозитория):
//   node tools/pack.mjs [--src plugin] [--out ../stratum-course-release] [--catalog .claude-plugin/marketplace.json] [--repo sollid/stratum-course]
//   node tools/pack.mjs --check     собрать архив заново и сверить sha256 с каталогом (код выхода 1 при расхождении)
import { zipSync } from 'fflate';
import { readdirSync, readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join, dirname, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

export const MARKETPLACE_NAME = 'stratum-course';
export const DEFAULT_REPO = 'sollid/stratum-course';
const FIXED_TIME = new Date(2026, 0, 1, 0, 0, 0); // местные части даты: формат zip хранит именно их, поэтому результат не зависит от часового пояса

export function archiveName(version, marketplace = MARKETPLACE_NAME) {
  return `${marketplace}-${version}.zip`;
}

export function archiveUrl(version, repo = DEFAULT_REPO, marketplace = MARKETPLACE_NAME) {
  return `https://github.com/${repo}/releases/download/v${version}/${archiveName(version, marketplace)}`;
}

function walk(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((d) => (d.isDirectory() ? walk(join(dir, d.name)) : [join(dir, d.name)]));
}

// Файлы плагина: относительные пути с «/», по алфавиту (сравнение по кодам, не по языку системы)
export function listFiles(srcDir) {
  return walk(srcDir)
    .map((f) => relative(srcDir, f).split(sep).join('/'))
    .sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
}

const isExec = (rel) => (rel.startsWith('bin/') && !rel.endsWith('.cmd')) || (rel.startsWith('scripts/') && rel.endsWith('.sh'));
const toLf = (buf) => new Uint8Array(Buffer.from(buf.toString('latin1').replace(/\r\n/g, '\n'), 'latin1'));

export function buildArchive(srcDir) {
  const rels = listFiles(srcDir);
  const files = {};
  for (const rel of rels) {
    const mode = isExec(rel) ? 0o100755 : 0o100644;
    files[rel] = [toLf(readFileSync(join(srcDir, rel))), { os: 3, attrs: (mode << 16) >>> 0, level: 6, mtime: FIXED_TIME }];
  }
  const zip = zipSync(files);
  return { zip, files: rels, sha256: createHash('sha256').update(zip).digest('hex') };
}

export function readManifest(srcDir) {
  return JSON.parse(readFileSync(join(srcDir, '.claude-plugin', 'plugin.json'), 'utf8'));
}

export function catalogFor({ manifest, sha256, repo = DEFAULT_REPO, marketplace = MARKETPLACE_NAME }) {
  return {
    name: marketplace,
    description: 'Каталог плагина курса Stratum (тренажёр по Claude Code).',
    owner: { name: 'Stratum' },
    plugins: [
      {
        name: manifest.name,
        description: manifest.description,
        version: manifest.version,
        source: { source: 'archive', url: archiveUrl(manifest.version, repo, marketplace), sha256 },
      },
    ],
  };
}

export function writeCatalog(path, catalog) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, JSON.stringify(catalog, null, 2) + '\n');
}

// Сборка + запись архива в папку выпуска и каталога в дерево. Возвращает сведения для отчёта.
export function pack({ src, out, catalog, repo = DEFAULT_REPO, marketplace = MARKETPLACE_NAME }) {
  const manifest = readManifest(src);
  const built = buildArchive(src);
  mkdirSync(out, { recursive: true });
  const zipPath = join(out, archiveName(manifest.version, marketplace));
  writeFileSync(zipPath, built.zip);
  writeCatalog(catalog, catalogFor({ manifest, sha256: built.sha256, repo, marketplace }));
  return { zipPath, zipBytes: built.zip.length, sha256: built.sha256, files: built.files.length, version: manifest.version, url: archiveUrl(manifest.version, repo, marketplace) };
}

// Каталог в дереве совпадает с заново собранным архивом?
export function check({ src, catalog, repo = DEFAULT_REPO, marketplace = MARKETPLACE_NAME }) {
  const manifest = readManifest(src);
  const built = buildArchive(src);
  const want = catalogFor({ manifest, sha256: built.sha256, repo, marketplace });
  const have = JSON.parse(readFileSync(catalog, 'utf8'));
  const same = JSON.stringify(want) === JSON.stringify(have);
  return { same, sha256: built.sha256, haveSha: have?.plugins?.[0]?.source?.sha256 };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const arg = (name, dflt) => {
    const i = process.argv.indexOf(name);
    return i > 0 ? process.argv[i + 1] : dflt;
  };
  const root = join(dirname(fileURLToPath(import.meta.url)), '..');
  const src = resolve(arg('--src', join(root, 'plugin')));
  const catalog = resolve(arg('--catalog', join(root, '.claude-plugin', 'marketplace.json')));
  const repo = arg('--repo', DEFAULT_REPO);
  if (process.argv.includes('--check')) {
    if (!existsSync(catalog)) { console.error('нет каталога: ' + catalog); process.exit(1); }
    const r = check({ src, catalog, repo });
    console.log(r.same ? `каталог совпадает с архивом, sha256 ${r.sha256}` : `РАСХОЖДЕНИЕ: в каталоге ${r.haveSha}, у свежего архива ${r.sha256}`);
    process.exit(r.same ? 0 : 1);
  }
  const out = resolve(arg('--out', join(root, '..', 'stratum-course-release')));
  console.log(JSON.stringify(pack({ src, out, catalog, repo }), null, 1));
}
