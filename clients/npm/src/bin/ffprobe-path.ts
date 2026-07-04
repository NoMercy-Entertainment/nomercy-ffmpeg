#!/usr/bin/env node
// -----------------------------------------------------------------------------
//  Copyright (c) NoMercy Entertainment
//
//  Licensed under the MIT License. See LICENSE for details.
//
//  SPDX-License-Identifier: MIT
// -----------------------------------------------------------------------------

import { ensureFfprobe } from '../index.js';

ensureFfprobe()
	.then((path) => {
		process.stdout.write(`${path}\n`);
	})
	.catch((error: unknown) => {
		process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
		process.exit(1);
	});
