// Third-party notices for what the TBD Chat build bundles: which npm packages end up in a bundle, and the licence text
// each one ships beside the app. Pure functions, used by build-tbd.ts and tested by test/third-party-notices.test.ts.
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

/**
 * The package folder of a bundled input path (esbuild metafile input or a rollup module id): the LAST node_modules/ in
 * the path, so a nested install (node_modules/a/node_modules/b) is package b, not a. `null` for our own sources.
 */
export function packageDirOf(input: string): string | null {
  const path = input.replace(/^\0/, '').replace(/\?.*$/, '');
  const marker = 'node_modules/';
  const at = path.lastIndexOf(marker);
  if (at < 0) return null;
  const rest = path.slice(at + marker.length).split('/');
  const name = rest[0].startsWith('@') ? rest.slice(0, 2).join('/') : rest[0];
  if (!name || name === '.bin' || name === '.vite' || (rest[0].startsWith('@') && rest.length < 2)) return null;
  return path.slice(0, at + marker.length) + name;
}

interface Pkg { name: string; version?: string; license?: string; author?: string | { name?: string } }

/** "Copyright (c) <author, without the e-mail or URL>" or "<name> contributors". */
export function copyrightLine(pkg: Pkg): string {
  const author = typeof pkg.author === 'string' ? pkg.author : pkg.author?.name;
  const holder = author?.replace(/<[^>]*>|\([^)]*\)/g, '').trim();
  return `Copyright (c) ${holder || `${pkg.name} contributors`}`;
}

const MIT = (line: string) => `MIT License

${line}

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.`;

const ISC = (line: string) => `ISC License

${line}

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
PERFORMANCE OF THIS SOFTWARE.`;

const BSD_BODY = `Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.
`;
const BSD_TAIL = `
THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.`;
const BSD2 = (line: string) => `BSD 2-Clause License\n\n${line}\n\n${BSD_BODY}${BSD_TAIL}`;
const BSD3 = (line: string) => `BSD 3-Clause License\n\n${line}\n\n${BSD_BODY}
3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.
${BSD_TAIL}`;

const STANDARD: Record<string, (line: string) => string> = { 'MIT': MIT, 'ISC': ISC, 'BSD-2-Clause': BSD2, 'BSD-3-Clause': BSD3 };

/** The licence text of a package: the file it ships, else the standard text for its SPDX id, else a plain note. */
export function licenceText(dir: string): { pkg: Pkg; text: string; source: 'file' | 'standard' | 'note' } {
  const pkg = JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8')) as Pkg;
  const file = readdirSync(dir).find((f) => /^(licen[cs]e|copying)/i.test(f));
  if (file) return { pkg, text: readFileSync(join(dir, file), 'utf8').trim(), source: 'file' };
  const standard = STANDARD[(pkg.license ?? '').trim()];
  if (standard) return { pkg, text: standard(copyrightLine(pkg)), source: 'standard' };
  return { pkg, text: `License: ${pkg.license ?? 'see package'} (no licence file in the package, and no standard text for it here)`, source: 'note' };
}
