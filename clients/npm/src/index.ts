// -----------------------------------------------------------------------------
//  Copyright (c) NoMercy Entertainment
//
//  Licensed under the MIT License. See LICENSE for details.
//
//  SPDX-License-Identifier: MIT
// -----------------------------------------------------------------------------

import type { ResolveOptions } from './resolve.js';
import { resolveBinary } from './resolve.js';

export type { PlatformTarget } from './platform.js';
export { resolvePlatformTarget } from './platform.js';
export type { ResolveOptions, Tool } from './resolve.js';
export { assetUrl } from './resolve.js';
export { FFMPEG_VERSION, FORK_VERSION, REPO } from './version.js';

/**
 * Resolves an absolute path to a runnable NoMercy fork `ffmpeg`, downloading the
 * platform artifact on first use. Honors `NOMERCY_FFMPEG` for a pre-supplied
 * binary. This is the NoMercy fork (custom muxers, AACS/BD+ decrypt, libass),
 * not stock ffmpeg.
 */
export async function ensureFfmpeg(options?: ResolveOptions): Promise<string> {
	return resolveBinary('ffmpeg', options);
}

/** Alias for {@link ensureFfmpeg} — resolves the `ffmpeg` binary path. */
export async function ffmpegPath(options?: ResolveOptions): Promise<string> {
	return resolveBinary('ffmpeg', options);
}

/**
 * Resolves an absolute path to a runnable NoMercy fork `ffprobe`, downloading
 * the platform artifact on first use. Honors `NOMERCY_FFPROBE` for a
 * pre-supplied binary.
 */
export async function ensureFfprobe(options?: ResolveOptions): Promise<string> {
	return resolveBinary('ffprobe', options);
}

/** Alias for {@link ensureFfprobe} — resolves the `ffprobe` binary path. */
export async function ffprobePath(options?: ResolveOptions): Promise<string> {
	return resolveBinary('ffprobe', options);
}
