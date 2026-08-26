#!/usr/bin/env node
// Copyright (C) 2026 Peter Mosmans [Go Forward]
// SPDX-License-Identifier: GPL-3.0-or-later
'use strict';

const fs = require('fs');
const { execSync } = require('child_process');

const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
const deps = pkg.dependencies;
const packages = Object.keys(deps);
let changed = 0;

for (const pkgName of packages) {
	try {
		const latest = execSync(`npm view ${pkgName} version`, { encoding: 'utf8' }).trim();
		const current = deps[pkgName];
		if (current === 'latest') {
			console.log(`${pkgName}: latest (skipping)`);
		} else if (current !== latest) {
			deps[pkgName] = latest;
			console.log(`Updated: ${pkgName} -> ${latest}`);
			changed++;
		} else {
			console.log(`${pkgName}: up to date (${current})`);
		}
	} catch (e) {
		console.log(`${pkgName}: could not fetch latest version (skipping)`);
	}
}

if (changed > 0) {
	pkg.dependencies = deps;
	fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
	console.log('Done. package.json updated.');
} else {
	console.log('No npm packages need updating.');
}
