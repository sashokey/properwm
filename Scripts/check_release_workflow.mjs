import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
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
    const github = { rest: { git: { getRef: async () => { called = true; } } } };
    await assert.rejects(validate(github, context, validationCore, null, { env: { RELEASE_VERSION: version } }));
    assert.equal(called, false);
  }
});

test('new version is accepted only when the tag lookup returns 404', async () => {
  for (const status of [404, 403, 500]) {
    const github = { rest: { git: { getRef: async request => {
      assert.equal(request.ref, 'tags/v0.1.0');
      throw Object.assign(new Error('lookup'), { status });
    } } } };
    const action = validate(github, context, validationCore, null, { env: { RELEASE_VERSION: '0.1.0' } });
    if (status === 404) await action;
    else await assert.rejects(action);
  }
  await assert.rejects(validate(
    { rest: { git: { getRef: async () => ({}) } } }, context, validationCore, null,
    { env: { RELEASE_VERSION: '0.1.0' } }), /already has a tag/);
});

function fixture({ draft = true, corrupt = false, failUpload = false } = {}) {
  const names = ['ProperWM-0.1.0.zip', 'ProperWM-0.1.0-source.zip'];
  const files = new Map(names.map((name, i) => ['dist/' + name, Buffer.from('archive-' + i)]));
  const sums = names.map(name => createHash('sha256').update(files.get('dist/' + name)).digest('hex')
    + '  ' + name).join('\n') + '\n';
  files.set('dist/SHA256SUMS.txt', Buffer.from(sums));
  if (corrupt) files.set('dist/' + names[0], Buffer.from('changed'));
  const calls = [];
  const github = { rest: { repos: {
    createRelease: async request => {
      calls.push(['create', request]);
      return { data: { id: 7, html_url: 'https://example.test/release' } };
    },
    uploadReleaseAsset: async request => {
      calls.push(['upload', request]);
      if (failUpload && request.name.endsWith('-source.zip')) throw new Error('upload failed');
    },
    updateRelease: async request => { calls.push(['publish', request]); }
  } } };
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
    RELEASE_VERSION: '0.1.0', RELEASE_DRAFT: String(draft), RELEASE_PRERELEASE: 'true'
  } };
  return { calls, run: () => publish(github, context, core, require, process) };
}

test('draft upload attaches app, matching source, and checksums to the exact commit', async () => {
  const f = fixture();
  await f.run();
  assert.deepEqual(f.calls.map(call => call[0]), ['create', 'upload', 'upload', 'upload']);
  assert.equal(f.calls[0][1].draft, true);
  assert.equal(f.calls[0][1].prerelease, true);
  assert.equal(f.calls[0][1].target_commitish, context.sha);
  assert.deepEqual(f.calls.slice(1).map(call => call[1].name),
    ['ProperWM-0.1.0.zip', 'ProperWM-0.1.0-source.zip', 'SHA256SUMS.txt']);
});

test('publication happens only after all uploads succeed', async () => {
  const f = fixture({ draft: false });
  await f.run();
  assert.deepEqual(f.calls.map(call => call[0]), ['create', 'upload', 'upload', 'upload', 'publish']);
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
  const github = { rest: { git: { getRef: async ({ ref }) => {
    checkedTag = ref;
    throw Object.assign(new Error('not found'), { status: 404 });
  } } } };
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
  const github = { rest: { git: { getRef: async () => {
    throw Object.assign(new Error('not found'), { status: 404 });
  } } } };
  await validate(github, context, { setOutput(key, value) { outputs[key] = value; } }, null,
    { env: { RELEASE_VERSION: '0.2.0', RELEASE_DRAFT: 'true', RELEASE_PRERELEASE: 'false' } });
  assert.deepEqual(outputs, { version: '0.2.0', draft: 'true', prerelease: 'false' });
});
