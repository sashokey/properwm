const managedNames = new Set(['ProperWM', 'test-results', 'xcodebuild-test-log']);

function selectDeletions(artifacts, runs, protectedRunIDs = []) {
  const protectedIDs = new Set(protectedRunIDs.filter(Number.isInteger));
  const groups = new Map();
  for (const artifact of artifacts) {
    const runID = artifact.workflow_run?.id;
    if (!managedNames.has(artifact.name) || artifact.expired
        || !Number.isInteger(artifact.id) || !Number.isInteger(runID)
        || !Number.isFinite(Date.parse(artifact.created_at))
        || protectedIDs.has(runID) || runs.get(runID)?.status !== 'completed') continue;
    const group = groups.get(artifact.name) ?? [];
    group.push(artifact);
    groups.set(artifact.name, group);
  }

  const deletions = [];
  for (const group of groups.values()) {
    group.sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at) || b.id - a.id);
    const keep = new Set(group.slice(0, 3).map(artifact => artifact.id));
    const successful = group.find(artifact => runs.get(artifact.workflow_run.id)?.conclusion === 'success');
    if (successful) keep.add(successful.id);
    deletions.push(...group.filter(artifact => !keep.has(artifact.id)));
  }
  return deletions.sort((a, b) => Date.parse(a.created_at) - Date.parse(b.created_at) || a.id - b.id);
}

async function cleanup({ github, context, core }) {
  const artifacts = await github.paginate(github.rest.actions.listArtifactsForRepo, {
    ...context.repo, per_page: 100
  });
  const runIDs = [...new Set(artifacts
    .filter(artifact => managedNames.has(artifact.name) && !artifact.expired)
    .map(artifact => artifact.workflow_run?.id)
    .filter(Number.isInteger))];
  const runs = new Map();
  for (let offset = 0; offset < runIDs.length; offset += 10) {
    await Promise.all(runIDs.slice(offset, offset + 10).map(async runID => {
      try {
        const { data } = await github.rest.actions.getWorkflowRun({ ...context.repo, run_id: runID });
        runs.set(runID, data);
      } catch (error) {
        if (error.status !== 404) throw error;
        core.warning('Keeping artifacts whose workflow run cannot be found: ' + runID);
      }
    }));
  }

  const candidates = selectDeletions(artifacts, runs, [
    Number(context.runId), context.payload.workflow_run?.id
  ]);
  let removed = 0;
  let bytesDeleted = 0;
  for (const artifact of candidates) {
    try {
      await github.rest.actions.deleteArtifact({ ...context.repo, artifact_id: artifact.id });
      removed += 1;
      bytesDeleted += artifact.size_in_bytes;
      core.info('Removed ' + artifact.name + ' artifact ' + artifact.id);
    } catch (error) {
      if (error.status !== 404) throw error;
      core.info('Artifact already expired or removed: ' + artifact.id);
    }
  }
  const summary = 'Removed ' + removed + ' old build/test artifacts ('
    + (bytesDeleted / 1048576).toFixed(1) + ' MiB).';
  core.info(summary);
  await core.summary.addRaw(summary).write();
  return { removed, bytesDeleted };
}

module.exports = { selectDeletions, cleanup };
