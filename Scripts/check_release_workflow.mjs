import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

const workflow = await readFile(new URL('../.github/workflows/release.yml', import.meta.url), 'utf8');
const lines = workflow.split('\n');
const scripts = [];
for (let i = 0; i < lines.length; i++) {
  if (lines[i].trim() !== 'script: |') continue;
  const indent = lines[i].length - lines[i].trimStart().length + 2;
  const body = [];
  for (i++; i < lines.length; i++) {
    if (lines[i].trim() && lines[i].search(/\S/) < indent) {
      i--;
      break;
    }
    body.push(lines[i].slice(indent));
  }
  scripts.push(body.join('\n'));
}
assert.equal(scripts.length, 2);
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const compile = body => new AsyncFunction('github', 'context', 'core', 'require', 'process', body);
const validate = compile(scripts[0]);
const publish = compile(scripts[1]);
const validationCore = { setOutput() {} };
const context = { eventName: 'workflow_dispatch', ref: 'refs/heads/master', repo: { owner: 'example', repo: 'properwm' }, sha: 'a'.repeat(40) };

test('version validation rejects malformed input before accessing GitHub', async () => {
  for (const version of ['v1.0.0', '1.0', '../1.0.0', '1.0.0\n', '1.0.0; echo bad']) {
    let called = false;
    const github = { request: async () => { called = true; } };
    await assert.rejects(validate(github, context, validationCore, null, { env: { RELEASE_VERSION: version } }));
    assert.equal(called, false);
  }
});

test('new version is accepted only when the tag lookup returns 404', async () => {
  for (const status of [404, 403, 500]) {
    const github = { request: async (route, request) => {
      assert.equal(route, 'GET /repos/{owner}/{repo}/git/ref/tags/{tag}');
      assert.equal(request.tag, 'v0.1.0');
      throw Object.assign(new Error('lookup'), { status });
    } };
    const action = validate(github, context, validationCore, null, { env: { RELEASE_VERSION: '0.1.0' } });
    if (status === 404) await action;
    else await assert.rejects(action);
  }
  await assert.rejects(validate(
    { request: async () => ({}) }, context, validationCore, null,
    { env: { RELEASE_VERSION: '0.1.0' } }), /already has a tag/);
});

function fixture({ draft = true, corrupt = false, failUpload = false, notes, conflictingTag = false, moveAfterUpload = false, existingAsset, sourceSHA = context.sha, metadataTarget = sourceSHA, encodedLookupBroken = false } = {}) {
  const names = ['ProperWM-0.1.0.zip'];
  const files = new Map(names.map((name, i) => ['dist/' + name, Buffer.from('archive-' + i)]));
  const sums = names.map(name => createHash('sha256').update(files.get('dist/' + name)).digest('hex')
    + '  ' + name).join('\n') + '\n';
  files.set('dist/SHA256SUMS.txt', Buffer.from(sums));
  if (corrupt) files.set('dist/' + names[0], Buffer.from('changed'));
  const calls = [];
  let tagExists = existingAsset !== undefined;
  let uploaded = 0;
  let release = existingAsset === undefined ? null : {
    id: 7, tag_name: 'v0.1.0', target_commitish: metadataTarget,
    draft: true, prerelease: true, html_url: 'https://example.test/release',
    assets: existingAsset === 'none' ? [] : [{
      id: 9, name: 'ProperWM-0.1.0.zip',
      state: existingAsset === 'starter' ? 'starter' : 'uploaded',
      size: existingAsset === 'starter' ? 0 : 9,
      digest: existingAsset === 'starter' ? null : 'sha256:' + (existingAsset === 'invalid' ? '0'.repeat(64)
        : createHash('sha256').update(Buffer.from('archive-0')).digest('hex'))
    }]
  };
  const readTag = async () => {
    if (!tagExists && !conflictingTag) throw Object.assign(new Error('missing'), { status: 404 });
    return { data: { object: { type: 'commit', sha: conflictingTag || (moveAfterUpload && uploaded > 0) ? 'b'.repeat(40) : sourceSHA } } };
  };
  const github = { rest: { git: {
    getRef: async () => {
      if (encodedLookupBroken) throw Object.assign(new Error('encoded route missing'), { status: 404 });
      return readTag();
    },
    createRef: async request => {
      assert.equal(request.sha, sourceSHA);
      assert.equal(request.ref, 'refs/tags/v0.1.0');
      tagExists = true;
      return { data: { object: { type: 'commit', sha: context.sha } } };
    }
  }, repos: {
    listReleases: async () => ({ data: release ? [release] : [] }),
    createRelease: async request => {
      if (release) throw Object.assign(new Error('release already exists'), { status: 422 });
      calls.push(['create', request]);
      release = { ...request, id: 7, assets: [], html_url: 'https://example.test/release' };
      return { data: release };
    },
    uploadReleaseAsset: async request => {
      calls.push(['upload', request]);
      uploaded++;
      if (failUpload && request.name === 'ProperWM-0.1.0.zip') throw new Error('upload failed');
    },
    deleteReleaseAsset: async request => { calls.push(['delete-starter', request]); },
    updateRelease: async request => { calls.push(['publish', request]); release.draft = request.draft; return { data: release }; }
  } } };
  github.request = async (route, request) => {
    assert.equal(route, 'GET /repos/{owner}/{repo}/git/ref/tags/{tag}');
    assert.equal(request.tag, 'v0.1.0');
    return readTag();
  };
  github.paginate = async (method, request) => (await method(request)).data;
  const core = { summary: { addLink() {}, async write() {} } };
  const require = name => {
    if (name === 'node:crypto') return { createHash };
    assert.equal(name, 'node:fs/promises');
    return { async readFile(path, encoding) {
      assert.ok(files.has(path));
      return encoding ? files.get(path).toString(encoding) : files.get(path);
    } };
  };
  const process = { env: {
    RELEASE_VERSION: '0.1.0', RELEASE_DRAFT: String(draft), RELEASE_PRERELEASE: 'true', RELEASE_NOTES: notes,
    RELEASE_SOURCE_SHA: sourceSHA
  } };
  return { calls, run: () => publish(github, context, core, require, process) };
}

test('draft upload attaches only the verified application archive to the exact commit', async () => {
  const f = fixture();
  await f.run();
  assert.deepEqual(f.calls.map(call => call[0]), ['create', 'upload']);
  assert.equal(f.calls[0][1].draft, true);
  assert.equal(f.calls[0][1].prerelease, true);
  assert.equal(f.calls[0][1].tag_name, 'v0.1.0');
  assert.equal(Object.hasOwn(f.calls[0][1], 'target_commitish'), false);
  assert.deepEqual(f.calls.slice(1).map(call => call[1].name),
    ['ProperWM-0.1.0.zip']);
  assert.deepEqual(f.calls[1][1].data, Buffer.from('archive-0'));
});

test('publication happens only after all uploads succeed', async () => {
  const f = fixture({ draft: false });
  await f.run();
  assert.deepEqual(f.calls.map(call => call[0]), ['create', 'upload', 'publish']);
  assert.equal(f.calls.at(-1)[1].draft, false);
});

test('checksum mismatch prevents release creation', async () => {
  const f = fixture({ corrupt: true });
  await assert.rejects(f.run(), /Checksum mismatch/);
  assert.deepEqual(f.calls, []);
});

test('failed asset upload keeps the release as a draft', async () => {
  const f = fixture({ draft: false, failUpload: true });
  await assert.rejects(f.run(), /upload failed/);
  assert.ok(f.calls.every(call => call[0] !== 'publish'));
});

function manifestFixture(request, ref = 'refs/heads/master') {
  const outputs = {};
  let checkedTag = null;
  const github = { request: async (route, { tag }) => {
    assert.equal(route, 'GET /repos/{owner}/{repo}/git/ref/tags/{tag}');
    checkedTag = 'tags/' + tag;
    throw Object.assign(new Error('not found'), { status: 404 });
  } };
  const core = { setOutput(key, value) { outputs[key] = value; } };
  const require = name => {
    assert.equal(name, 'node:fs/promises');
    return { async readFile(path, encoding) {
      assert.equal(path, '.github/release.json');
      assert.equal(encoding, 'utf8');
      return JSON.stringify(request);
    } };
  };
  return {
    outputs,
    tag: () => checkedTag,
    run: () => validate(github, { ...context, eventName: 'push', ref }, core, require, { env: {} })
  };
}

test('committed request carries version and publication flags into the release jobs', async () => {
  const f = manifestFixture({ version: '0.1.0', draft: false, prerelease: true });
  await f.run();
  assert.equal(f.tag(), 'tags/v0.1.0');
  assert.deepEqual(f.outputs, { version: '0.1.0', draft: 'false', prerelease: 'true' });
});

test('manifest flags must be booleans and version must be a clean string', async () => {
  for (const request of [
    { version: '0.1.0', draft: 'false', prerelease: true },
    { version: '0.1.0', draft: false },
    { version: 1, draft: false, prerelease: true },
    { version: '0.1.0\n', draft: false, prerelease: true }
  ]) {
    const f = manifestFixture(request);
    await assert.rejects(f.run());
    assert.equal(f.tag(), null);
    assert.deepEqual(f.outputs, {});
  }
});

test('push requests outside master cannot publish', async () => {
  const f = manifestFixture({ version: '0.1.0', draft: false, prerelease: true }, 'refs/heads/feature');
  await assert.rejects(f.run(), /Unsupported release event/);
  assert.equal(f.tag(), null);
});

test('manual release inputs preserve draft and stable-release choices', async () => {
  const outputs = {};
  const github = { request: async () => {
    throw Object.assign(new Error('not found'), { status: 404 });
  } };
  await validate(github, context, { setOutput(key, value) { outputs[key] = value; } }, null,
    { env: { RELEASE_VERSION: '0.2.0', RELEASE_DRAFT: 'true', RELEASE_PRERELEASE: 'false' } });
  assert.deepEqual(outputs, { version: '0.2.0', draft: 'true', prerelease: 'false' });
});


test('committed release notes reach the created release unchanged', async () => {
  const notes = '## Fixed\n\n- Keep `window` geometry.\n- Literal ${{ text }} and $(text).';
  const manifest = manifestFixture({ version: '0.1.0', draft: false, prerelease: false, notes });
  await manifest.run();
  assert.equal(manifest.outputs.notes, notes);
  const release = fixture({ notes: manifest.outputs.notes });
  await release.run();
  assert.ok(release.calls[0][1].body.startsWith(notes + '\n\n'));
  assert.ok(release.calls[0][1].body.includes('Apple Silicon'));
});

test('non-text release notes fail before any tag lookup or publication', async () => {
  for (const notes of [null, false, 42, ['change'], { change: 'fixed' }]) {
    const f = manifestFixture({ version: '0.1.0', draft: false, prerelease: false, notes });
    await assert.rejects(f.run(), /notes must be a string/);
    assert.equal(f.tag(), null);
    assert.deepEqual(f.outputs, {});
  }
});


test('a concurrently created tag for another commit blocks release creation', async () => {
  const f = fixture({ draft: false, conflictingTag: true });
  await assert.rejects(f.run(), /tag.*commit/i);
  assert.deepEqual(f.calls, []);
});

test('a tag moved during uploads keeps the release unpublished', async () => {
  const f = fixture({ draft: false, moveAfterUpload: true });
  await assert.rejects(f.run(), /tag.*commit/i);
  assert.ok(f.calls.some(call => call[0] === 'create'));
  assert.ok(f.calls.every(call => call[0] !== 'publish'));
});


test('retry after completed upload publishes the existing draft without another release or ZIP', async () => {
  const f = fixture({ draft: false, existingAsset: 'valid' });
  await f.run();
  assert.deepEqual(f.calls.map(call => call[0]), ['publish']);
  assert.equal(f.calls[0][1].release_id, 7);
});

test('retry after interrupted upload attaches the missing ZIP to the existing draft', async () => {
  const f = fixture({ draft: false, existingAsset: 'none' });
  await f.run();
  assert.deepEqual(f.calls.map(call => call[0]), ['upload', 'publish']);
  assert.equal(f.calls[0][1].release_id, 7);
});

test('existing ZIP with a different digest blocks publication without replacement', async () => {
  const f = fixture({ draft: false, existingAsset: 'invalid' });
  await assert.rejects(f.run(), /asset.*match|checksum/i);
  assert.deepEqual(f.calls, []);
});

test('retry replaces a zero-length starter on a draft before publishing', async () => {
  const f = fixture({ draft: false, existingAsset: 'starter' });
  await f.run();
  assert.deepEqual(f.calls.map(call => call[0]), ['delete-starter', 'upload', 'publish']);
  assert.equal(f.calls[0][1].asset_id, 9);
});

test('the release workflow queues pending requests', () => {
  assert.match(workflow, /^concurrency:\n  group: release\n  cancel-in-progress: false\n  queue: max$/m);
});

test('publication is stopped when the workflow is cancelled', () => {
  assert.match(workflow, /^  publish:\n    if: >-\n      !cancelled\(\) &&/m);
});

test('the binary gate rejects every registered Debug-only switch', async () => {
  const registry = await readFile(new URL('../Core/Support/DebugSwitch.swift', import.meta.url), 'utf8');
  const debugCases = registry.match(/#if DEBUG\n([\s\S]*?)#endif/)[1];
  const flags = [...debugCases.matchAll(/case \w+ = "(DOCK_\w+)"/g)].map(match => match[1]);
  assert.ok(flags.length > 0);
  const script = fileURLToPath(new URL('lib/release_binary.sh', import.meta.url));
  const check = flag => spawnSync('/bin/bash', ['-c', [
    'source "$1"',
    'literal="$2"',
    'nm() { :; }',
    'strings() { printf "%s\\n" "$literal"; }',
    'verify_release_diagnostics fixture',
  ].join('\n'), 'release-scan', script, flag], { encoding: 'utf8' });
  for (const flag of flags) {
    const result = check(flag);
    assert.equal(result.status, 1, flag);
    assert.match(result.stderr, /contains diagnostic settings/, flag);
  }
  assert.equal(check('DOCK_RECONCILE_SKIP').status, 0);
});

test('publication uses the documented tag namespace path instead of an encoded slash', async () => {
  const f = fixture({ draft: false, encodedLookupBroken: true });
  await f.run();
  assert.deepEqual(f.calls.map(call => call[0]), ['create', 'upload', 'publish']);
});

test('resumed publication keeps the original tested source SHA instead of the workflow repair SHA', async () => {
  const f = fixture({ draft: false, existingAsset: 'valid', sourceSHA: 'c'.repeat(40) });
  await f.run();
  assert.deepEqual(f.calls.map(call => call[0]), ['publish']);
});

test('resume uses the verified tag even when release metadata names the default branch', async () => {
  const f = fixture({ draft: false, existingAsset: 'valid', sourceSHA: 'c'.repeat(40), metadataTarget: 'master' });
  await f.run();
  assert.deepEqual(f.calls.map(call => call[0]), ['publish']);
});

function releaseJobs(validate, build, publish, uploadMinute = '20') {
  return [
    { name: 'validate', status: 'completed', conclusion: validate },
    { name: 'build / Build and test', status: 'completed', conclusion: build, steps: [{
      name: 'Upload ProperWM', status: 'completed', conclusion: 'success',
      started_at: `2026-11-17T12:${uploadMinute}:30Z`, completed_at: `2026-11-17T12:${uploadMinute}:35Z`
    }] },
    { name: 'publish', status: 'completed', conclusion: publish }
  ];
}

const artifactDigest = 'sha256:' + 'a'.repeat(64);
const verifiedArtifact = {
  id: 71, name: 'ProperWM', expired: false, created_at: '2026-11-17T12:20:32Z', digest: artifactDigest
};

function resumeFixture({
  buildConclusion = 'success', sourceVersion = '0.1.0', sourceBranch = 'master',
  sourcePath = '.github/workflows/release.yml', sourceTagSHA = 'c'.repeat(40), runStatus = 'completed',
  latestJobs = releaseJobs('success', buildConclusion, 'failure'), earlierAttempts = [],
  artifacts = [verifiedArtifact]
} = {}) {
  const outputs = {};
  const requestedAttempts = [];
  const request = { version: '0.1.0', draft: false, prerelease: true, resume_run_id: 123 };
  const github = { rest: { actions: {
    getWorkflowRun: async args => {
      assert.equal(args.run_id, 123);
      return { data: { id: 123, run_attempt: earlierAttempts.length + 1, head_sha: 'c'.repeat(40), head_branch: sourceBranch, event: 'push',
        path: sourcePath, status: runStatus, conclusion: 'failure', head_repository: { full_name: 'example/properwm' } } };
    },
    listJobsForWorkflowRun: async args => {
      assert.equal(args.run_id, 123);
      assert.equal(args.filter, 'latest');
      return { data: { jobs: latestJobs } };
    },
    listJobsForWorkflowRunAttempt: async args => {
      assert.equal(args.run_id, 123);
      const jobs = earlierAttempts[args.attempt_number - 1];
      assert.ok(jobs);
      requestedAttempts.push(args.attempt_number);
      return { data: { jobs } };
    },
    listWorkflowRunArtifacts: async args => {
      assert.equal(args.run_id, 123);
      assert.equal(args.name, 'ProperWM');
      return { data: { artifacts } };
    }
  }, repos: {
    getContent: async args => {
      assert.equal(args.ref, 'c'.repeat(40));
      assert.equal(args.path, '.github/release.json');
      return { data: { encoding: 'base64', content: Buffer.from(JSON.stringify({
        version: sourceVersion, draft: false, prerelease: true
      })).toString('base64') } };
    }
  }, git: {
    getRef: async () => ({ data: { object: { type: 'commit', sha: sourceTagSHA } } })
  } } };
  github.request = async (route, args) => {
    assert.equal(route, 'GET /repos/{owner}/{repo}/git/ref/tags/{tag}');
    assert.equal(args.tag, 'v0.1.0');
    return { data: { object: { type: 'commit', sha: sourceTagSHA } } };
  };
  github.paginate = async (method, args) => {
    const { data } = await method(args);
    return data.jobs ?? data.artifacts;
  };
  const require = () => ({ readFile: async () => JSON.stringify(request) });
  return { outputs, requestedAttempts, run: () => validate(github, { ...context, eventName: 'push' },
    { setOutput(key, value) { outputs[key] = value; } }, require, { env: {} }) };
}

test('resume accepts the original release run only after its versioned build passed', async () => {
  const f = resumeFixture();
  await f.run();
  assert.equal(f.outputs.source_sha, 'c'.repeat(40));
  assert.equal(f.outputs.resume_artifact_id, '71');
  assert.equal(f.outputs.resume_artifact_digest, artifactDigest);
  assert.equal(f.outputs.version, '0.1.0');
});

test('resume finds the successful package after full reruns fail validation on the existing tag', async () => {
  const blocked = releaseJobs('failure', 'skipped', 'skipped');
  const f = resumeFixture({
    latestJobs: blocked,
    earlierAttempts: [releaseJobs('success', 'failure', 'skipped'), releaseJobs('success', 'success', 'failure'), blocked]
  });
  await f.run();
  assert.equal(f.outputs.source_sha, 'c'.repeat(40));
  assert.equal(f.outputs.resume_artifact_id, '71');
  assert.deepEqual(f.requestedAttempts, [3, 2]);
});

test('resume can use carried jobs from a failed-only rerun without querying earlier attempts', async () => {
  const f = resumeFixture({
    earlierAttempts: [releaseJobs('success', 'success', 'failure')]
  });
  await f.run();
  assert.equal(f.outputs.resume_artifact_id, '71');
  assert.deepEqual(f.requestedAttempts, []);
});

test('resume rejects build success and publication failure from separate attempts', async () => {
  const f = resumeFixture({
    latestJobs: releaseJobs('failure', 'skipped', 'skipped'),
    earlierAttempts: [releaseJobs('success', 'success', 'cancelled'), releaseJobs('success', 'failure', 'failure')]
  });
  await assert.rejects(f.run(), /successful versioned build and a failed publication/);
  assert.deepEqual(f.outputs, {});
});

test('resume accepts a release workflow path qualified by a ref', async () => {
  const f = resumeFixture({ sourcePath: '.github/workflows/release.yml@master' });
  await f.run();
  assert.equal(f.outputs.resume_artifact_id, '71');
});

test('resume selects the verified upload even when a newer build fails after uploading the same name', async () => {
  const f = resumeFixture({
    latestJobs: releaseJobs('success', 'failure', 'skipped', '45'),
    earlierAttempts: [releaseJobs('success', 'success', 'failure')],
    artifacts: [
      { ...verifiedArtifact, id: 98, created_at: '2026-11-17T12:45:32Z', digest: 'sha256:' + 'b'.repeat(64) },
      verifiedArtifact,
      { ...verifiedArtifact, id: 65, created_at: '2026-11-17T12:02:32Z' }
    ]
  });
  await f.run();
  assert.deepEqual(f.requestedAttempts, [1]);
  assert.equal(f.outputs.resume_artifact_id, '71');
  assert.equal(f.outputs.resume_artifact_digest, artifactDigest);
});

test('resume stops when the verified upload is absent, expired or ambiguous', async () => {
  for (const artifacts of [
    [],
    [{ ...verifiedArtifact, id: 98, created_at: '2026-11-17T12:45:32Z' }],
    [{ ...verifiedArtifact, expired: true }],
    [verifiedArtifact, { ...verifiedArtifact, id: 75 }]
  ]) {
    const f = resumeFixture({ artifacts });
    await assert.rejects(f.run(), /verified ProperWM artifact/);
    assert.deepEqual(f.outputs, {});
  }
});

test('resume requires a successful upload step with a valid interval', async () => {
  for (const step of [[], [{ conclusion: 'failure' }], [{ started_at: null }], [{ completed_at: '2026-11-17T12:20:29Z' }]]) {
    const latestJobs = releaseJobs('success', 'success', 'failure');
    latestJobs[1].steps = step.map(overrides => ({ ...latestJobs[1].steps[0], ...overrides }));
    const f = resumeFixture({ latestJobs });
    await assert.rejects(f.run(), /successful ProperWM upload/);
    assert.deepEqual(f.outputs, {});
  }
});

async function downloadFixture(t, wrongDigest = false) {
  const download = workflow.match(/^      - name: Download verified release artifact\n((?: {8}.*\n)+)/m);
  assert.ok(download);
  assert.match(download[1], /if: needs\.validate\.outputs\.resume_artifact_id != ''/);
  assert.match(download[1], /RELEASE_ARTIFACT_ID: \$\{\{ needs\.validate\.outputs\.resume_artifact_id \}\}/);
  assert.match(download[1], /RELEASE_ARTIFACT_DIGEST: \$\{\{ needs\.validate\.outputs\.resume_artifact_digest \}\}/);
  const script = download[1].split('        run: |\n')[1].replace(/^ {10}/gm, '');
  const directory = await mkdtemp(join(tmpdir(), 'properwm-release-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const packageName = 'ProperWM-0.1.0.zip';
  const packageContents = 'verified payload';
  await writeFile(join(directory, packageName), packageContents);
  const fixtureZip = join(directory, 'fixture.zip');
  const zip = spawnSync('zip', ['-q', fixtureZip, packageName], { cwd: directory, encoding: 'utf8' });
  assert.equal(zip.status, 0, zip.stderr);
  const digest = 'sha256:' + createHash('sha256').update(await readFile(fixtureZip)).digest('hex');
  const curl = [
    'curl() {',
    '  [[ "${@: -1}" == "https://api.example.test/repos/example/properwm/actions/artifacts/71/zip" ]] || return 2',
    '  while [[ $# -gt 1 && "$1" != --output ]]; do shift; done',
    '  [[ "$1" == --output ]] || return 2',
    '  cp "$FIXTURE_ZIP" "$2"',
    '}'
  ].join('\n');
  const result = spawnSync('/bin/bash', ['-eo', 'pipefail', '-c', curl + '\n' + script], {
    cwd: directory, encoding: 'utf8', env: {
      PATH: process.env.PATH, GITHUB_TOKEN: 'example', GITHUB_API_URL: 'https://api.example.test',
      GITHUB_REPOSITORY: 'example/properwm', RELEASE_ARTIFACT_ID: '71',
      RELEASE_ARTIFACT_DIGEST: wrongDigest ? artifactDigest : digest, RUNNER_TEMP: directory, FIXTURE_ZIP: fixtureZip
    }
  });
  return { result, payload: () => readFile(join(directory, 'dist', packageName), 'utf8') };
}

test('resumed publication extracts the package from the exact REST artifact ID', async t => {
  const fixture = await downloadFixture(t);
  assert.equal(fixture.result.status, 0, fixture.result.stderr);
  assert.equal(await fixture.payload(), 'verified payload');
});

test('resumed publication rejects an archive whose digest differs from GitHub metadata', async t => {
  const fixture = await downloadFixture(t, true);
  assert.equal(fixture.result.status, 1);
  await assert.rejects(fixture.payload(), { code: 'ENOENT' });
});

test('resume rejects failed builds, mismatched versions, moved tags and untrusted source runs', async () => {
  for (const options of [
    { buildConclusion: 'failure' }, { sourceVersion: '0.2.0' }, { sourceBranch: 'feature' },
    { sourcePath: '.github/workflows/other.yml' }, { sourcePath: '.github/workflows/release.yml.bak@master' },
    { sourceTagSHA: 'b'.repeat(40) },
    { runStatus: 'in_progress' }
  ]) {
    const f = resumeFixture(options);
    await assert.rejects(f.run());
    assert.deepEqual(f.outputs, {});
  }
});
