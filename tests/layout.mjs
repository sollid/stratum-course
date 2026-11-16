// Расклад папок для тестов: плагин лежит в plugin/, нейтральные правила и образцы — в tests/fixtures.
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

export const root = join(dirname(fileURLToPath(import.meta.url)), '..');
export const open = true;
export const course = join(root, 'plugin');
export const scripts = join(course, 'scripts');
export const bin = join(course, 'bin');
export const rules = join(root, 'tests', 'fixtures', 'readme-check.json');
export const sample = (name) => join(root, 'tests', 'fixtures', 'readmes', name);
export const fixture = (rel) => join(root, 'tests', 'fixtures', ...rel.split('/'));
export const win = process.platform === 'win32';
export const GIT_BASH = process.env.COURSE_TEST_GIT_BASH || 'C:\\Program Files\\Git\\bin\\bash.exe';
export const fwd = (p) => p.replace(/\\/g, '/');
export const posix = (p) => (win ? p.replace(/^([A-Za-z]):/, (_, d) => `/${d.toLowerCase()}`).replace(/\\/g, '/') : p);
