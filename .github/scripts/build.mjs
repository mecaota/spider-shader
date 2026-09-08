// Builds the VPM repository listing (index.json) and the landing page (index.html)
// from the GitHub Releases of this repository and the root README.md.
//
// Environment variables:
//   GITHUB_REPOSITORY  owner/name of the repository (set automatically on GitHub Actions)
//   GITHUB_TOKEN       token used for the GitHub API (optional, raises the rate limit)
//   PACKAGE_NAME       VPM package id shown on the landing page, e.g. com.mecaota.restraint
//   LISTING_URL        public URL of index.json (default: https://<owner>.github.io/<repo>/index.json)
//   SITE_DIR           output directory relative to the repository root (default: _site)
//   DEFAULT_BRANCH     branch used to resolve relative links in README.md (default: main)

import { createHash } from 'node:crypto';
import { cpSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { unzipSync } from 'fflate';
import { marked } from 'marked';
import { gfmHeadingId } from 'marked-gfm-heading-id';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const repo = requireEnv('GITHUB_REPOSITORY');
const [owner, repoName] = repo.split('/');
const packageName = process.env.PACKAGE_NAME || '';
const listingUrl = process.env.LISTING_URL || `https://${owner}.github.io/${repoName}/index.json`;
const siteDir = path.resolve(root, process.env.SITE_DIR || '_site');
const defaultBranch = process.env.DEFAULT_BRANCH || 'main';
const token = process.env.GITHUB_TOKEN || process.env.GH_TOKEN || '';

const websiteDir = path.join(root, 'Website');
const readmePath = path.join(root, 'README.md');
const repoUrl = `https://github.com/${repo}`;

main().catch((error) => {
  console.error(error);
  process.exit(1);
});

async function main() {
  console.log(`Repository: ${repo}`);
  console.log(`Listing URL: ${listingUrl}`);

  const releases = await fetchReleases();
  console.log(`Found ${releases.length} release(s)`);

  const manifests = await collectManifests(releases);
  if (manifests.length === 0) {
    console.warn('No package zip with a package.json was found in the releases.');
  }

  const primary = pickPrimaryManifest(manifests);
  const listing = buildListing(manifests, primary);

  mkdirSync(siteDir, { recursive: true });
  cpSync(websiteDir, siteDir, { recursive: true });
  writeFileSync(path.join(siteDir, 'index.json'), `${JSON.stringify(listing, null, 2)}\n`);
  writeFileSync(path.join(siteDir, 'index.html'), renderIndexHtml(primary));

  for (const manifest of manifests) {
    console.log(`  ${manifest.name}@${manifest.version}  ${manifest.url}`);
  }
  console.log(`Wrote ${path.relative(root, siteDir)}/index.json and index.html`);
}

function requireEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Environment variable ${name} is required`);
  }
  return value;
}

async function fetchReleases() {
  const headers = {
    Accept: 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': 'spider-shader-site-build',
  };
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }

  const releases = [];
  for (let page = 1; ; page += 1) {
    const url = `https://api.github.com/repos/${repo}/releases?per_page=100&page=${page}`;
    const response = await fetch(url, { headers });
    if (!response.ok) {
      throw new Error(`GitHub API request failed: ${response.status} ${response.statusText} (${url})`);
    }
    const batch = await response.json();
    releases.push(...batch);
    if (batch.length < 100) {
      break;
    }
  }
  return releases.filter((release) => !release.draft);
}

async function collectManifests(releases) {
  const manifests = [];
  for (const release of releases) {
    for (const asset of release.assets ?? []) {
      if (!asset.name.endsWith('.zip')) {
        continue;
      }
      const manifest = await readManifestFromZip(asset.browser_download_url);
      if (!manifest) {
        console.warn(`Skipping ${asset.name} from release ${release.tag_name}: no valid package.json inside`);
        continue;
      }
      manifests.push(manifest);
    }
  }
  return manifests;
}

async function readManifestFromZip(url) {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`Could not download ${url}: ${response.status} ${response.statusText}`);
  }
  const bytes = new Uint8Array(await response.arrayBuffer());

  // A broken asset must not take the whole listing down, so zip/JSON errors only skip this asset.
  let manifest;
  try {
    const entries = unzipSync(bytes, { filter: (file) => file.name === 'package.json' });
    const entry = entries['package.json'];
    if (!entry) {
      return null;
    }
    manifest = JSON.parse(new TextDecoder('utf-8').decode(entry));
  } catch (error) {
    console.warn(`Could not read package.json from ${url}: ${error.message}`);
    return null;
  }
  if (typeof manifest.name !== 'string' || typeof manifest.version !== 'string') {
    return null;
  }
  manifest.url = url;
  manifest.zipSHA256 = createHash('sha256').update(bytes).digest('hex');
  return manifest;
}

// The manifest that drives the landing page: display metadata (name, description,
// license, author) follows the package.json in the repository so it matches the
// README on the same branch, while the version is the latest release.
function pickPrimaryManifest(manifests) {
  const latest = pickLatestRelease(manifests);
  const local = readLocalManifest();
  if (!latest && !local) {
    throw new Error('Could not determine the package to show. Set PACKAGE_NAME or publish a release.');
  }
  if (!latest) {
    console.warn(`No release found for ${packageName}; using the repository package.json for the landing page`);
    return local;
  }
  return local ? { ...latest, ...local, version: latest.version } : latest;
}

function pickLatestRelease(manifests) {
  let candidates = packageName ? manifests.filter((m) => m.name === packageName) : manifests;
  const stable = candidates.filter((m) => !parseVersion(m.version)?.prerelease);
  if (stable.length > 0) {
    candidates = stable;
  }
  if (candidates.length === 0) {
    return null;
  }
  return candidates.slice().sort((a, b) => compareVersions(b.version, a.version))[0];
}

function readLocalManifest() {
  if (!packageName) {
    return null;
  }
  const localPath = path.join(root, 'Packages', packageName, 'package.json');
  if (!existsSync(localPath)) {
    return null;
  }
  return JSON.parse(stripBom(readFileSync(localPath, 'utf8')));
}

// Unity and Windows editors tend to save UTF-8 files with a byte order mark.
function stripBom(text) {
  return text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
}

function buildListing(manifests, primary) {
  const packages = {};
  for (const manifest of manifests) {
    packages[manifest.name] ??= { versions: {} };
    packages[manifest.name].versions[manifest.version] = manifest;
  }
  return {
    name: `${primary.displayName || primary.name} Listing`,
    id: `${primary.name}.listing`,
    author: primary.author?.name || owner,
    url: listingUrl,
    packages,
  };
}

function renderIndexHtml(primary) {
  const template = readFileSync(path.join(websiteDir, 'index.html'), 'utf8');
  const values = {
    DISPLAY_NAME: primary.displayName || primary.name,
    DESCRIPTION: primary.description || '',
    VERSION: primary.version || '',
    PACKAGE_NAME: primary.name,
    LICENSE: primary.license || '',
    AUTHOR_NAME: primary.author?.name || owner,
    AUTHOR_URL: primary.author?.url || `https://github.com/${owner}`,
    LISTING_URL: listingUrl,
    VCC_URL: `vcc://vpm/addRepo?url=${encodeURIComponent(listingUrl)}`,
    REPO_URL: repoUrl,
    RELEASES_URL: `${repoUrl}/releases`,
  };

  return template.replace(/\{\{\s*([A-Z_]+)\s*\}\}/g, (match, key) => {
    if (key === 'README_HTML') {
      return renderReadme();
    }
    if (!(key in values)) {
      throw new Error(`Unknown placeholder ${match} in Website/index.html`);
    }
    return escapeHtml(values[key]);
  });
}

function renderReadme() {
  if (!existsSync(readmePath)) {
    return '';
  }
  let markdown = stripBom(readFileSync(readmePath, 'utf8'));
  // The page header already shows the package name, so drop the leading H1.
  markdown = markdown.replace(/^\s*#\s[^\n]*\n/, '');

  marked.use(gfmHeadingId(), {
    gfm: true,
    walkTokens(token) {
      if (token.type === 'link' || token.type === 'image') {
        token.href = absolutizeLink(token.href, token.type === 'image');
      }
    },
  });
  return marked.parse(markdown);
}

// Relative links in README.md point at files in the repository, not at the website.
function absolutizeLink(href, isImage) {
  if (!href || /^(?:[a-z][a-z0-9+.-]*:|\/\/|#)/i.test(href)) {
    return href;
  }
  const filePath = href.replace(/^(?:\.\/|\/)+/, '');
  return isImage
    ? `https://raw.githubusercontent.com/${repo}/${defaultBranch}/${filePath}`
    : `${repoUrl}/blob/${defaultBranch}/${filePath}`;
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function parseVersion(version) {
  const match = /^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?/.exec(version ?? '');
  if (!match) {
    return null;
  }
  return {
    main: [Number(match[1]), Number(match[2]), Number(match[3])],
    prerelease: match[4] ? match[4].split('.') : null,
  };
}

function compareVersions(a, b) {
  const pa = parseVersion(a);
  const pb = parseVersion(b);
  if (!pa || !pb) {
    return String(a).localeCompare(String(b));
  }
  for (let i = 0; i < 3; i += 1) {
    if (pa.main[i] !== pb.main[i]) {
      return pa.main[i] - pb.main[i];
    }
  }
  if (!pa.prerelease && !pb.prerelease) return 0;
  if (!pa.prerelease) return 1;
  if (!pb.prerelease) return -1;
  const length = Math.max(pa.prerelease.length, pb.prerelease.length);
  for (let i = 0; i < length; i += 1) {
    const x = pa.prerelease[i];
    const y = pb.prerelease[i];
    if (x === undefined) return -1;
    if (y === undefined) return 1;
    const xNumeric = /^\d+$/.test(x);
    const yNumeric = /^\d+$/.test(y);
    if (xNumeric && yNumeric) {
      if (Number(x) !== Number(y)) return Number(x) - Number(y);
    } else if (xNumeric) {
      return -1;
    } else if (yNumeric) {
      return 1;
    } else if (x !== y) {
      return x < y ? -1 : 1;
    }
  }
  return 0;
}
