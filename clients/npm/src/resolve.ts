// -----------------------------------------------------------------------------
//  Copyright (c) NoMercy Entertainment
//
//  Licensed under the MIT License. See LICENSE for details.
//
//  SPDX-License-Identifier: MIT
// -----------------------------------------------------------------------------

import type { PlatformTarget } from './platform.js';
import { spawnSync } from 'node:child_process';
import { createWriteStream, existsSync, mkdirSync, rmSync } from 'node:fs';
import { chmod } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { resolvePlatformTarget } from './platform.js';
import { FFMPEG_VERSION, FORK_VERSION, REPO } from './version.js';

/** Which fork tool to resolve. */
export type Tool = 'ffmpeg' | 'ffprobe';

/** Options accepted by every resolver. Defaults derive from env + platform. */
export interface ResolveOptions {
	/** Override platform detection (mainly for tests). */
	platform?: string;
	/** Override arch detection (mainly for tests). */
	arch?: string;
	/** Override the cache root. Defaults to `<tmpdir>/nomercy-ffmpeg-static`. */
	cacheDir?: string;
}

/**
 * Cache root for downloaded binaries, keyed by fork version so a version bump
 * never collides with an old cached binary. Lives under the OS temp dir by
 * default, which survives across runs within a CI job and on a dev machine.
 */
function cacheRootFor(options: ResolveOptions): string {
	const base = options.cacheDir ?? join(tmpdir(), 'nomercy-ffmpeg-static');
	return join(base, FORK_VERSION);
}

/** Confirms a path is a binary that actually runs and reports the right tool. */
function isRunnable(binaryPath: string, tool: Tool): boolean {
	if (!existsSync(binaryPath))
		return false;
	const probe = spawnSync(binaryPath, ['-version'], { encoding: 'utf8' });
	const banner = new RegExp(`${tool} version`, 'i');
	return probe.status === 0 && banner.test(probe.stdout ?? '');
}

/** Builds the public download URL for a target's archive. */
export function assetUrl(target: PlatformTarget): string {
	const assetName = `ffmpeg-${FFMPEG_VERSION}-${target.slug}-${FORK_VERSION}.${target.ext}`;
	return `https://github.com/${REPO}/releases/download/${FORK_VERSION}/${assetName}`;
}

async function downloadArchive(url: string, archivePath: string): Promise<void> {
	const response = await fetch(url, { redirect: 'follow' });
	if (!response.ok || !response.body)
		throw new Error(`Download failed (${response.status}) for ${url}`);
	await pipeline(Readable.fromWeb(response.body), createWriteStream(archivePath));
}

function extractArchive(archivePath: string, target: PlatformTarget, destination: string): void {
	if (target.ext === 'zip') {
		// PowerShell Expand-Archive ships with every supported Windows runner.
		const result = spawnSync(
			'powershell',
			['-NoProfile', '-Command', `Expand-Archive -Path '${archivePath}' -DestinationPath '${destination}' -Force`],
			{ encoding: 'utf8' },
		);
		if (result.status !== 0)
			throw new Error(`Expand-Archive failed: ${result.stderr ?? result.error?.message}`);
		return;
	}
	const result = spawnSync('tar', ['-xzf', archivePath, '-C', destination], { encoding: 'utf8' });
	if (result.status !== 0)
		throw new Error(`tar extraction failed: ${result.stderr ?? result.error?.message}`);
}

/**
 * Resolves an absolute path to a runnable NoMercy fork binary for the requested
 * tool, downloading the platform artifact on first use.
 *
 * Resolution order:
 *   1. `NOMERCY_FFMPEG` (for ffmpeg) / `NOMERCY_FFPROBE` (for ffprobe) env var
 *      pointing at an existing runnable binary — a CI cache or the mediaserver's
 *      bundled copy.
 *   2. A binary already cached from a previous run.
 *   3. The matching platform artifact from the fork's GitHub release: download,
 *      extract, cache, clean the archive.
 */
export async function resolveBinary(tool: Tool, options: ResolveOptions = {}): Promise<string> {
	const envKey = tool === 'ffmpeg' ? 'NOMERCY_FFMPEG' : 'NOMERCY_FFPROBE';
	const fromEnv = process.env[envKey];
	if (fromEnv && isRunnable(fromEnv, tool))
		return fromEnv;

	const target = resolvePlatformTarget(options.platform, options.arch);
	const cacheDir = cacheRootFor(options);
	const binaryName = tool === 'ffmpeg' ? target.ffmpeg : target.ffprobe;
	const binaryPath = join(cacheDir, binaryName);
	if (isRunnable(binaryPath, tool))
		return binaryPath;

	mkdirSync(cacheDir, { recursive: true });
	const archivePath = join(cacheDir, `archive.${target.ext}`);
	await downloadArchive(assetUrl(target), archivePath);
	extractArchive(archivePath, target, cacheDir);
	rmSync(archivePath, { force: true });

	if (!binaryName.endsWith('.exe')) {
		await chmod(binaryPath, 0o755).catch(() => {});
		// The companion tool ships in the same archive; make it executable too.
		const companion = join(cacheDir, tool === 'ffmpeg' ? target.ffprobe : target.ffmpeg);
		if (existsSync(companion))
			await chmod(companion, 0o755).catch(() => {});
	}

	if (!isRunnable(binaryPath, tool))
		throw new Error(`Extracted ${tool} at ${binaryPath} is not runnable.`);
	return binaryPath;
}
