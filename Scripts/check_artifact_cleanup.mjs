import assert from 'node:assert/strict';
import { test } from 'node:test';
import maintenance from './cleanup_artifacts.cjs';

const { selectDeletions, cleanup } = maintenance;
const artifact = (id, name = 'test-results', overrides = {}) => ({
  id, name, workflow_run: { id }, expired: false, size_in_bytes: 1024,
  created_at: new Date(Date.UTC(2026, 0, id)).toISOString(), ...overrides
});
const completed = (ids, conclusion = 'failure') => new Map(
  ids.map(id => [id, { status: 'completed', conclusion }])
);
const ids = artifacts => artifacts.map(item => item.id);

test('keeps the newest three completed artifacts independently for each managed name', () => {
  const artifacts = [
    ...[1, 2, 3, 4, 5].map(id => artifact(id)),
    ...[6, 7, 8, 9].map(id => artifact(id, 'ProperWM'))
  ];
  assert.deepEqual(ids(selectDeletions(artifacts, completed(ids(artifacts)))), [1, 2, 6]);
});

test('retains the newest successful report through a series of failed builds', () => {
  const artifacts = [1, 2, 3, 4, 5, 6].map(id => artifact(id));
  const runs = completed(ids(artifacts));
  runs.set(1, { status: 'completed', conclusion: 'success' });
  runs.set(2, { status: 'completed', conclusion: 'success' });
  assert.deepEqual(ids(selectDeletions(artifacts, runs)), [1, 3]);
});

test('never deletes protected runs or runs that are still active', () => {
  const artifacts = [1, 2, 3, 4, 5, 6, 7].map(id => artifact(id));
  const runs = completed(ids(artifacts));
  runs.set(1, { status: 'in_progress', conclusion: null });
  runs.set(2, { status: 'queued', conclusion: null });
  assert.deepEqual(ids(selectDeletions(artifacts, runs, [3])), [4]);
});

test('ignores unrelated artifacts and incomplete or expired metadata', () => {
  const artifacts = [
    artifact(1, 'user-backup'), artifact(2, 'ProperWM-copy'),
    artifact(3, 'test-results', { expired: true }),
    artifact(4, 'test-results', { workflow_run: null }),
    artifact(5, 'test-results', { created_at: 'invalid' }),
    artifact(6), artifact(7), artifact(8)
  ];
  assert.deepEqual(selectDeletions(artifacts, completed(ids(artifacts))), []);
});

test('does not delete artifacts with unknown workflow status', () => {
  const artifacts = [1, 2, 3, 4, 5].map(id => artifact(id));
  assert.deepEqual(selectDeletions(artifacts, completed([3, 4, 5])), []);
});

function fixture({ lookupFailure, deleteFailure } = {}) {
  const artifacts = [1, 2, 3, 4, 5].map(id => artifact(id));
  const deleted = [];
  const lookups = [];
  const repo = { owner: 'example', repo: 'properwm' };
  const action = () => {};
  const github = {
    rest: { actions: {
      listArtifactsForRepo: action,
      getWorkflowRun: async request => {
        assert.equal(request.owner, repo.owner);
        assert.equal(request.repo, repo.repo);
        lookups.push(request.run_id);
        if (lookupFailure) throw Object.assign(new Error('lookup'), { status: lookupFailure });
        return { data: { status: 'completed', conclusion: 'failure' } };
      },
      deleteArtifact: async request => {
        assert.equal(request.owner, repo.owner);
        assert.equal(request.repo, repo.repo);
        assert.equal(lookups.length, artifacts.length);
        deleted.push(request.artifact_id);
        if (deleteFailure) throw Object.assign(new Error('delete'), { status: deleteFailure });
      }
    } },
    paginate: async (method, request) => {
      assert.equal(method, action);
      assert.equal(request.owner, repo.owner);
      assert.equal(request.repo, repo.repo);
      return artifacts;
    }
  };
  const core = { info() {}, warning() {}, summary: { addRaw() { return this; }, async write() {} } };
  const context = { repo, runId: 99, payload: {} };
  return { github, core, context, deleted };
}

test('cleanup scopes deletions to this repository after reading every run status', async () => {
  const input = fixture();
  assert.deepEqual(await cleanup(input), { removed: 2, bytesDeleted: 2048 });
  assert.deepEqual(input.deleted, [1, 2]);
});

test('lookup authorization errors abort before any deletion', async () => {
  const input = fixture({ lookupFailure: 403 });
  await assert.rejects(cleanup(input), /lookup/);
  assert.deepEqual(input.deleted, []);
});

test('missing runs remain protected', async () => {
  const input = fixture({ lookupFailure: 404 });
  assert.deepEqual(await cleanup(input), { removed: 0, bytesDeleted: 0 });
  assert.deepEqual(input.deleted, []);
});

test('artifacts removed concurrently do not count as reclaimed bytes', async () => {
  const input = fixture({ deleteFailure: 404 });
  assert.deepEqual(await cleanup(input), { removed: 0, bytesDeleted: 0 });
});

test('unexpected deletion failures stop cleanup', async () => {
  const input = fixture({ deleteFailure: 403 });
  await assert.rejects(cleanup(input), /delete/);
  assert.deepEqual(input.deleted, [1]);
});
