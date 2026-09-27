"""Release Git operations preserve existing JMS commits and never update main."""
import subprocess

from check_jms_git_privacy import load_policy, outgoing_findings, tree_entries, blob_findings


class GitReleaseError(RuntimeError):
    pass


def git(*args):
    result = subprocess.run(['git', *args], capture_output=True)
    if result.returncode:
        raise GitReleaseError('Git release operation refused; inspect local repository state')
    return result.stdout.decode().strip()


def committed_source(expected=None):
    if git('branch', '--show-current') != 'jms':
        raise GitReleaseError('Release requires the jms branch')
    if git('status', '--porcelain', '--untracked-files=all'):
        raise GitReleaseError('Release requires a clean committed worktree and index')
    commit = git('rev-parse', 'HEAD')
    if expected and expected != commit:
        raise GitReleaseError('Release state belongs to another jms commit')
    return commit


def refs(remote):
    return {line.split()[1]: line.split()[0] for line in git('ls-remote', remote).splitlines()}


def check_upstream():
    if git('rev-parse', '--is-shallow-repository') == 'true':
        raise GitReleaseError('Shallow history cannot establish upstream ancestry; complete the selected lineage first')
    # origin is the official upstream in this checkout; names alone are not trusted.
    official = 'https://github.com/DonutWare/Fladder.git'
    remotes = git('remote').splitlines()
    matches = [name for name in remotes if git('remote', 'get-url', name).rstrip('/') == official]
    if len(matches) != 1:
        raise GitReleaseError('Expected one verified official upstream remote')
    remote = matches[0]
    advertised = git('ls-remote', '--symref', remote, 'HEAD')
    branch = next((line.split()[1] for line in advertised.splitlines() if line.startswith('ref: ')), None)
    if not branch or not branch.startswith('refs/heads/'):
        raise GitReleaseError('Upstream default branch is not advertised')
    git('fetch', '--no-tags', remote, branch)
    upstream = git('rev-parse', 'FETCH_HEAD')
    # Missing common ancestry and rewritten histories fail closed. Never auto-merge at publication.
    git('merge-base', 'HEAD', upstream)
    try:
        git('merge-base', '--is-ancestor', upstream, 'HEAD')
    except GitReleaseError:
        raise GitReleaseError('Official default branch has unintegrated commits; review the source branch before release') from None
    return remote, branch, upstream


def push_release(remote, commit, tag, *, git_options=(), environment=None, dry_run=False):
    if 'DonutWare/Fladder' in remote:
        raise GitReleaseError('Official upstream is read-only')
    if not tag.startswith('v') or git('check-ref-format', 'refs/tags/' + tag):
        raise GitReleaseError('Invalid release tag')
    committed_source(commit)
    current = refs(remote)
    branch = current.get('refs/heads/jms')
    tagged = current.get('refs/tags/' + tag)
    if tagged not in (None, commit):
        raise GitReleaseError('Immutable release tag points elsewhere')
    if branch:
        git('fetch', '--no-tags', remote, 'refs/heads/jms')
        git('merge-base', '--is-ancestor', branch, commit)
    domains = load_policy()
    bases = [branch] if branch else []
    # For a new jms branch only an advertised, locally verified main ancestor is trusted.
    if not branch and current.get('refs/heads/main'):
        git('fetch', '--no-tags', remote, 'refs/heads/main')
        git('merge-base', '--is-ancestor', current['refs/heads/main'], commit)
        bases = [current['refs/heads/main']]
    issues = outgoing_findings(commit, bases, domains)
    issues.extend(blob_findings(tree_entries(commit), domains))
    if any(problems for _, problems in issues):
        raise GitReleaseError('Privacy rejected outgoing commits or release tree; run the local checker')
    if dry_run or (branch == commit and tagged == commit):
        return
    result = subprocess.run(['git', *git_options, 'push', '--atomic', remote,
                             commit + ':refs/heads/jms', commit + ':refs/tags/' + tag],
                            env=environment, capture_output=True)
    if result.returncode:
        raise GitReleaseError('Atomic push rejected; no force-push or retag permitted')
    after = refs(remote)
    if after.get('refs/heads/jms') != commit or after.get('refs/tags/' + tag) != commit:
        raise GitReleaseError('Remote branch/tag verification failed')


def verify_build_record(record, commit):
    if record.get('sourceCommit') != commit or record.get('workspaceCommit') != commit:
        raise GitReleaseError('Build record was not created at the selected jms commit')
    if record.get('gitSourceVerified') is not True:
        raise GitReleaseError('Build record lacks clean committed-source evidence; do not rebind old APKs')


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verify-commit', required=True)
    arguments = parser.parse_args()
    committed_source(arguments.verify_commit)
