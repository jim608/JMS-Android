"""Install or check clone-local JMS hooks without storing private policy in Git."""
import argparse
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    if not args.check:
        subprocess.run(['git', 'config', '--local', 'core.hooksPath', '.githooks'], check=True)
    configured = subprocess.run(['git', 'config', '--get', 'core.hooksPath'], capture_output=True, text=True).stdout.strip()
    hooks = all(Path('.githooks', name).is_file() for name in ('pre-commit', 'commit-msg', 'pre-push'))
    policy = Path(subprocess.check_output(['git', 'rev-parse', '--git-path', 'jms-private-domains'], text=True).strip())
    ready = configured == '.githooks' and hooks and policy.is_file() and bool(policy.read_text(encoding='utf-8').strip())
    print('Hook installation: ' + ('PASS' if ready else 'BLOCKED; configure hooks and nonempty local privacy policy'))
    return 0 if ready else 1


if __name__ == '__main__':
    sys.exit(main())
