// Проверка записи плагина набора команды (kit) в общем каталоге .claude-plugin/marketplace.json: запись одна, адрес — релиз этого же репозитория с тегом kit-v<версия>,
// sha256 записи равен архиву, собранному из папки plugin-kit/ без probe/ (так собирается архив выпуска). Без этой проверки подмену или потерю записи никто бы не заметил.
// Если набора в этом дереве нет ни в папке, ни в каталоге, проверка честно пропускается; одно без другого — ошибка.
// Запуск: node tests/kit-catalog-check.mjs   Код выхода 0 — всё прошло.
import { readFileSync, existsSync, cpSync, rmSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildArchive, readManifest } from '../tools/pack.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const kitSrc = join(root, 'plugin-kit');
const catalog = JSON.parse(readFileSync(join(root, '.claude-plugin', 'marketplace.json'), 'utf8'));

let passed = 0; let failed = 0; let skipped = 0;
const failures = [];
function ok(name, cond, detail = '') {
  if (cond) { passed++; console.log(`  ok   ${name}`); } else { failed++; failures.push(name); console.log(`  FAIL ${name}${detail ? ` -- ${detail}` : ''}`); }
}

const entries = (catalog.plugins ?? []).filter((p) => p?.name === 'kit');
const hasDir = existsSync(kitSrc);
if (!hasDir && entries.length === 0) {
  skipped = 1;
  console.log('  пропуск: набора команды (plugin-kit/ и записи kit) в этом дереве нет');
} else {
  ok('папка plugin-kit/ и запись kit в каталоге есть вместе (одно без другого — потеря при выгрузке)', hasDir && entries.length === 1, `папка: ${hasDir}, записей kit: ${entries.length}`);
  if (hasDir && entries.length === 1) {
    const entry = entries[0];
    const manifest = readManifest(kitSrc);
    const course = (catalog.plugins ?? []).find((p) => p?.name === 'course');
    const base = /^(https:\/\/github\.com\/[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+)\/releases\/download\//.exec(entry.source?.url ?? '')?.[1];
    ok('запись kit: имя плагина в манифесте kit, версия и описание записи равны манифесту', manifest.name === 'kit' && entry.version === manifest.version && entry.description === manifest.description, `${manifest.name} ${manifest.version} / ${entry.version}`);
    ok('запись kit: источник archive; адрес — релиз этого же репозитория (как у курса) с тегом kit-v<версия> и архивом stratum-kit-<версия>.zip', entry.source?.source === 'archive' && !!base && (!course?.source?.url || course.source.url.startsWith(`${base}/releases/download/v`)) && entry.source.url === `${base}/releases/download/kit-v${manifest.version}/stratum-kit-${manifest.version}.zip`, entry.source?.url);
    ok('запись kit: тег не совпадает с тегами курса (vX.Y.Z)', /\/download\/kit-v[0-9]/.test(entry.source?.url ?? ''));
    // архив выпуска набора: папка plugin-kit/ без probe/ (в сборку по умолчанию хуки не входят)
    const tmp = mkdtempSync(join(tmpdir(), 'kit-check-'));
    try {
      cpSync(kitSrc, tmp, { recursive: true });
      rmSync(join(tmp, 'probe'), { recursive: true, force: true });
      const a = buildArchive(tmp);
      const b = buildArchive(tmp);
      ok('архив набора собирается повторяемо (два раза один sha256)', a.sha256 === b.sha256);
      ok('sha256 записи kit — 64 шестнадцатеричных знака и равен sha256 архива, собранного из plugin-kit/ без probe/', /^[0-9a-f]{64}$/.test(entry.source?.sha256 ?? '') && entry.source.sha256 === a.sha256, `${entry.source?.sha256} / ${a.sha256}`);
      ok('в архиве набора есть LICENSE и манифест в корне', a.files.some((f) => (f.name ?? f) === 'LICENSE') && a.files.some((f) => (f.name ?? f) === '.claude-plugin/plugin.json'));
    } finally { rmSync(tmp, { recursive: true, force: true }); }
  }
}

console.log(`\nИтого: прошло ${passed}, не прошло ${failed}, пропущено ${skipped}`);
if (failed) { console.log(`Не прошли: ${failures.join('; ')}`); process.exit(1); }
