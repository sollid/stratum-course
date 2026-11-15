// Тест самопроверки установки (/course:start) и ответа /course:next без задания: оба варианта скриптов (PowerShell и sh).
// Запуск: node <путь к этому файлу>. Код выхода 0 — всё прошло. Расклад папок — layout.mjs.
// Настоящий Claude Code подменяется заглушкой `claude` в первой папке PATH: версию и её отсутствие можно задать.
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, existsSync, rmSync, cpSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { course, scripts, bin, win, GIT_BASH, fwd, posix } from './layout.mjs';

let passed = 0; let failed = 0;
const failures = [];
function check(name, cond, detail = '') {
  if (cond) { passed++; console.log(`  ok   ${name}`); } else { failed++; failures.push(name); console.log(`  FAIL ${name}${detail ? ` -- ${detail}` : ''}`); }
}

const tmpRoot = mkdtempSync(join(tmpdir(), 'selfcheck-test-'));
const shimDir = join(tmpRoot, 'shim');
mkdirSync(shimDir);

// Заглушка claude: печатает то, что лежит в переменной FAKE_CLAUDE_OUT
if (win) writeFileSync(join(shimDir, 'claude.cmd'), '@echo off\r\necho %FAKE_CLAUDE_OUT%\r\n');
writeFileSync(join(shimDir, 'claude'), '#!/bin/sh\nprintf "%s\\n" "$FAKE_CLAUDE_OUT"\n');
if (!win) chmodSync(join(shimDir, 'claude'), 0o755);

const SYSTEM_PS_PATH = ['C:\\Windows\\System32\\WindowsPowerShell\\v1.0', 'C:\\Windows\\System32', 'C:\\Windows'].join(';');
const gitDir = win ? dirname(dirname(GIT_BASH)) : '';
const SH_BARE_PATH = win ? [join(gitDir, 'usr', 'bin'), join(gitDir, 'mingw64', 'bin')].join(';') : '/usr/bin:/bin';

function envFor(v, { fake, withShim = true } = {}) {
  const e = { ...process.env };
  for (const k of Object.keys(e)) if (/^(COURSE_SITE_URL|CLAUDE_PLUGIN_DATA|FAKE_CLAUDE_OUT)$/i.test(k)) delete e[k];
  if (fake !== undefined) e.FAKE_CLAUDE_OUT = fake;
  const base = process.env.Path ?? process.env.PATH ?? '';
  if (withShim) {
    if (win) { e.Path = `${shimDir};${base}`; delete e.PATH; } else e.PATH = `${shimDir}:${base}`;
  } else if (win) {
    e.Path = v === 'ps' ? SYSTEM_PS_PATH : SH_BARE_PATH; delete e.PATH;
  } else e.PATH = SH_BARE_PATH;
  return e;
}

// Запуск скрипта: v = 'ps' | 'sh'; root — папка с scripts/
function run(v, root, script, args = [], opts = {}) {
  const env = envFor(v, opts);
  let r;
  if (v === 'ps') {
    r = spawnSync(join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'), ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', join(root, 'scripts', `${script}.ps1`), ...args], { env, encoding: 'utf8' });
  } else if (win) {
    const sh = join(gitDir, 'usr', 'bin', 'sh.exe');
    r = spawnSync(existsSync(sh) ? sh : GIT_BASH, [...(existsSync(sh) ? [] : ['-c', 'sh "$0" "$@"']), fwd(join(root, 'scripts', `${script}.sh`)), ...args], { env, encoding: 'utf8' });
  } else {
    r = spawnSync('sh', [join(root, 'scripts', `${script}.sh`), ...args], { env, encoding: 'utf8' });
  }
  return { code: r.status, out: (r.stdout ?? '').replace(/\r\n/g, '\n'), err: r.stderr ?? '' };
}

const variants = win ? ['ps', 'sh'] : ['sh'];
const norm = (s) => s.replace(/^Оболочка: .*$/m, 'Оболочка: X');
const outs = {};

for (const v of variants) {
  console.log(`\n=== вариант ${v} ===`);
  console.log('- самопроверка');
  const ok = run(v, course, 'selfcheck', [], { fake: '2.1.300 (Claude Code)' });
  check(`[${v}] версия 2.1.300: код 0, «Установка работает.», версия и оболочка названы`, ok.code === 0 && ok.out.startsWith('Установка работает.\n') && ok.out.includes('версия 2.1.300') && /^Оболочка: .+\.$/m.test(ok.out) && ok.out.includes('встроенное правило сработало верно'), `${ok.code} ${ok.out}`);
  check(`[${v}] stderr пуст`, ok.err === '', ok.err.slice(0, 200));
  check(`[${v}] после успеха сказано, что делать дальше (/course:connect)`, ok.out.includes('/course:connect'));
  outs[`selfcheck-${v}`] = ok.out;

  const edge = run(v, course, 'selfcheck', [], { fake: '2.1.287 (Claude Code)' });
  check(`[${v}] версия ровно на границе (2.1.287) принимается`, edge.code === 0 && edge.out.startsWith('Установка работает.'), `${edge.code} ${edge.out}`);

  for (const old of ['2.1.286 (Claude Code)', '2.0.999 (Claude Code)', '1.0.5 (Claude Code)']) {
    const r = run(v, course, 'selfcheck', [], { fake: old });
    check(`[${v}] старая версия «${old}»: код 43, «старше нужной», «Установка работает» нет`, r.code === 43 && r.out.includes('старше нужной') && !r.out.includes('Установка работает') && r.out.includes('Что сделать:'), `${r.code} ${r.out}`);
  }
  const newer = run(v, course, 'selfcheck', [], { fake: '2.10.0 (Claude Code)' });
  check(`[${v}] версия 2.10.0 новее 2.1.287 (сравнение числовое, не по строке)`, newer.code === 0, `${newer.code} ${newer.out}`);

  const junk = run(v, course, 'selfcheck', [], { fake: 'hello' });
  check(`[${v}] версия не распознана: код 42, одно действие`, junk.code === 42 && junk.out.includes('не удалось определить версию') && junk.out.includes('Что сделать:'), `${junk.code} ${junk.out}`);
  const none = run(v, course, 'selfcheck', [], { withShim: false });
  check(`[${v}] команды claude нет в PATH: код 42, без падения`, none.code === 42 && none.out.includes('не удалось определить версию') && none.err === '', `${none.code} ${none.out} ${none.err.slice(0, 120)}`);
  const soft = run(v, course, 'selfcheck', ['--soft'], { fake: '1.0.0' });
  check(`[${v}] --soft: код 0 при отказе, текст отказа тот же`, soft.code === 0 && soft.out.includes('старше нужной'), `${soft.code} ${soft.out}`);

  // сломанное встроенное правило: проверка обязана отказать, а не сказать «работает»
  const broken = join(tmpRoot, `broken-${v}`);
  mkdirSync(broken);
  cpSync(scripts, join(broken, 'scripts'), { recursive: true });
  cpSync(join(course, 'selfcheck'), join(broken, 'selfcheck'), { recursive: true });
  cpSync(join(course, '.claude-plugin'), join(broken, '.claude-plugin'), { recursive: true });
  const rulesText = readFileSync(join(broken, 'selfcheck', 'selfcheck.json'), 'utf8').replace(/"on_fail": "failed"/g, '"on_fail": "almost"');
  writeFileSync(join(broken, 'selfcheck', 'selfcheck.json'), rulesText);
  const bk = run(v, broken, 'selfcheck', [], { fake: '2.1.300' });
  check(`[${v}] правило, у которого пустая папка не «не принято»: код 44, «Установка работает» нет`, bk.code === 44 && !bk.out.includes('Установка работает') && bk.out.includes('встроенная проверка отработала неверно'), `${bk.code} ${bk.out}`);
  writeFileSync(join(broken, 'selfcheck', 'selfcheck.json'), '{ not json');
  const bk2 = run(v, broken, 'selfcheck', [], { fake: '2.1.300' });
  check(`[${v}] битый файл правил: код 44`, bk2.code === 44 && !bk2.out.includes('Установка работает'), `${bk2.code} ${bk2.out}`);

  console.log('- next без задания');
  const d1 = mkdtempSync(join(tmpRoot, 'data-'));
  const n1 = run(v, course, 'next', ['--data', fwd(d1)]);
  check(`[${v}] без привязки: код 40, «задание придёт с сайта», названа /course:connect, не падает`, n1.code === 40 && n1.out.includes('Задание придёт с сайта курса') && n1.out.includes('/course:connect') && n1.err === '', `${n1.code} ${n1.out} ${n1.err.slice(0, 100)}`);
  const n1s = run(v, course, 'next', ['--data', fwd(d1), '--soft']);
  check(`[${v}] без привязки с --soft: код 0, тот же текст`, n1s.code === 0 && n1s.out === n1.out, `${n1s.code}`);
  const SECRET = 'tkn_ZZYYXXWWVVUUTTSSRRQQPPOONNMMLLKK1234';
  writeFileSync(join(d1, 'device-token.txt'), `token=${SECRET}\ndevice_id=abc\nsite=http://localhost\n`);
  const n2 = run(v, course, 'next', ['--data', fwd(d1)]);
  check(`[${v}] с привязкой, но без задания: код 0, честно «задание пока не пришло», версия плагина названа`, n2.code === 0 && n2.out.includes('задание для вашего шага пока не пришло') && /версия плагина \d+\.\d+\.\d+/.test(n2.out) && n2.out.includes('/plugin marketplace update stratum-course'), `${n2.code} ${n2.out}`);
  check(`[${v}] токен не печатается`, !n1.out.includes(SECRET) && !n2.out.includes(SECRET) && !n2.err.includes(SECRET));
  writeFileSync(join(d1, 'device-token.txt'), 'garbage without token\n');
  const n3 = run(v, course, 'next', ['--data', fwd(d1)]);
  check(`[${v}] файл токена без токена считается «не привязано»`, n3.code === 40, `${n3.code} ${n3.out}`);
  outs[`next-${v}`] = [n1.out, n2.out];
}

if (variants.length === 2) {
  console.log('\n=== сравнение вариантов ===');
  check('selfcheck: вывод PowerShell и sh совпадает побайтно, кроме строки об оболочке', norm(outs['selfcheck-ps']) === norm(outs['selfcheck-sh']));
  check('next: вывод PowerShell и sh совпадает побайтно (без привязки и с привязкой)', outs['next-ps'][0] === outs['next-sh'][0] && outs['next-ps'][1] === outs['next-sh'][1]);
}

// Входы для навыков: course-run <selfcheck|next> и отказ на чужом имени
console.log('\n=== входы course-run ===');
const entryEnv = envFor('ps', { fake: '2.1.300 (Claude Code)' });
if (win) {
  const viaCmd = spawnSync('cmd.exe', ['/c', join(bin, 'course-run.cmd'), 'selfcheck', '--soft'], { env: entryEnv, encoding: 'utf8' });
  check('course-run.cmd selfcheck: «Установка работает.»', viaCmd.status === 0 && viaCmd.stdout.startsWith('Установка работает.'), `${viaCmd.status} ${viaCmd.stdout}`);
  const dd = mkdtempSync(join(tmpRoot, 'data-'));
  const viaNext = spawnSync('cmd.exe', ['/c', join(bin, 'course-run.cmd'), 'next', '--data', dd, '--soft'], { env: entryEnv, encoding: 'utf8' });
  check('course-run.cmd next: честный ответ без привязки', viaNext.status === 0 && viaNext.stdout.includes('Задание придёт с сайта курса'), `${viaNext.status} ${viaNext.stdout}`);
  // powershell.exe в рабочей папке процесса не должен запускаться: cmd.exe ищет в текущей папке раньше, чем в PATH
  const decoyDir = mkdtempSync(join(tmpRoot, 'decoy-'));
  cpSync(join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'whoami.exe'), join(decoyDir, 'powershell.exe'));
  const viaDecoy = spawnSync('cmd.exe', ['/c', join(bin, 'course-run.cmd'), 'selfcheck', '--soft'], { env: entryEnv, cwd: decoyDir, encoding: 'utf8' });
  check('course-run.cmd: подложенный powershell.exe в рабочей папке не запускается, работает PowerShell из системной папки', viaDecoy.status === 0 && viaDecoy.stdout.startsWith('Установка работает.'), `${viaDecoy.status} ${viaDecoy.stdout} ${viaDecoy.stderr}`);
  const unknown = spawnSync('cmd.exe', ['/c', join(bin, 'course-run.cmd'), 'rm'], { encoding: 'utf8' });
  check('course-run.cmd: чужое имя отклонено (код 2)', unknown.status === 2, String(unknown.status));
  const viaSh = spawnSync(GIT_BASH, ['-c', `"${posix(join(bin, 'course-run'))}" selfcheck --soft`], { env: entryEnv, encoding: 'utf8' });
  check('course-run (sh) в Git Bash: уходит в PowerShell-вариант, «Установка работает.»', viaSh.status === 0 && viaSh.stdout.includes('Установка работает.') && /Оболочка: PowerShell/.test(viaSh.stdout), `${viaSh.status} ${viaSh.stdout}`);
} else {
  const e = { ...entryEnv };
  const viaSh = spawnSync('sh', [join(bin, 'course-run'), 'selfcheck', '--soft'], { env: e, encoding: 'utf8' });
  check('course-run selfcheck: «Установка работает.»', viaSh.status === 0 && viaSh.stdout.startsWith('Установка работает.'), `${viaSh.status} ${viaSh.stdout}`);
  const unknown = spawnSync('sh', [join(bin, 'course-run'), 'rm'], { encoding: 'utf8' });
  check('course-run: чужое имя отклонено (код 2)', unknown.status === 2, String(unknown.status));
}

// Временные папки самопроверки не остаются
const leftovers = readdirSync(tmpdir()).filter((n) => n.startsWith('course-selfcheck-'));
check('временные папки самопроверки удалены', leftovers.length === 0, leftovers.join(','));

rmSync(tmpRoot, { recursive: true, force: true });
console.log(`\nИтого: прошло ${passed}, не прошло ${failed}, пропущено 0`);
if (failed) { console.log(`Не прошли: ${failures.join('; ')}`); process.exit(1); }
