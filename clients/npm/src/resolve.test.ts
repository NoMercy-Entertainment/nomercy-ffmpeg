// -----------------------------------------------------------------------------
//  Copyright (c) NoMercy Entertainment
//
//  Licensed under the MIT License. See LICENSE for details.
//
//  SPDX-License-Identifier: MIT
// -----------------------------------------------------------------------------

import { existsSync } from 'node:fs';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { ensureFfmpeg, ensureFfprobe } from './index.js';

const CACHED_FFMPEG = 'C:/Projects/NoMercy/packages/nomercy-music-player/.cache/ffmpeg/v1.0.36/ffmpeg.exe';

describe('env override', () => {
	const saved = process.env['NOMERCY_FFMPEG'];

	beforeEach(() => {
		delete process.env['NOMERCY_FFMPEG'];
		delete process.env['NOMERCY_FFPROBE'];
	});

	afterEach(() => {
		if (saved === undefined)
			delete process.env['NOMERCY_FFMPEG'];
		else
			process.env['NOMERCY_FFMPEG'] = saved;
		delete process.env['NOMERCY_FFPROBE'];
	});

	it.runIf(existsSync(CACHED_FFMPEG))('returns the NOMERCY_FFMPEG binary when it is runnable', async () => {
		process.env['NOMERCY_FFMPEG'] = CACHED_FFMPEG;
		const resolved = await ensureFfmpeg();
		expect(resolved).toBe(CACHED_FFMPEG);
	});

	it('falls through env when the override points at a non-runnable path', async () => {
		process.env['NOMERCY_FFMPEG'] = 'C:/does/not/exist/ffmpeg.exe';
		process.env['NOMERCY_FFPROBE'] = '/also/missing/ffprobe';
		// With no cache and no network in this test, resolution proceeds past the
		// bogus env var and into platform detection, so we assert it does NOT
		// short-circuit to the bad path.
		await expect(ensureFfprobe({ platform: 'sunos', arch: 'sparc' }))
			.rejects
			.toThrow(/No NoMercy ffmpeg artifact/);
	});
});
