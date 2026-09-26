#!/usr/bin/env node
// Bundles uBlock Origin's own scriptlets and its +js() argument parser into
// Sources/Lithium/Resources/Scripts/scriptlets.ubo.json, so uBO's rules run with uBO's code.
// Usage: node scripts/update-ubo-scriptlets.mjs [tag]

import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const tag = process.argv[2] ?? '1.75.0';
const repo = join(root, '.tools', `uBlock-${tag}`);

if (!existsSync(repo)) {
    mkdirSync(dirname(repo), { recursive: true });
    execFileSync('git', ['clone', '--quiet', '--depth', '1', '--branch', tag, 'https://github.com/gorhill/uBlock.git', repo], { stdio: 'inherit' });
}

const { builtinScriptlets } = await import(join(repo, 'src/js/resources/scriptlets.js'));
const resources = {};
const aliases = {};
for (const { name, fn, dependencies = [], aliases: names = [], priority } of builtinScriptlets) {
    resources[name] = { code: fn.toString(), dependencies, ...(priority ? { priority } : {}) };
    for (const alias of names) aliases[alias] = name;
}

const argumentParser = readFileSync(join(repo, 'src/js/arglist-parser.js'), 'utf8').replace(/^export\s+/m, '');
const output = join(root, 'Sources/Lithium/Resources/Scripts/scriptlets.ubo.json');
writeFileSync(output, JSON.stringify({ version: tag, argumentParser, aliases, resources }) + '\n');
console.error(`${Object.keys(resources).length} uBO resources (${tag}) -> ${output}`);
