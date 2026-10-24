import subprocess
import unittest
from unittest.mock import patch

import jms_publication as publication


class CommandRuntimeTests(unittest.TestCase):
    def test_standard_runner_executes_requested_tool_without_optional_wrapper(self):
        environment = {'PATH': '/ci/tools'}
        completed = subprocess.CompletedProcess([], 0, stdout=b'public-response', stderr=b'')
        with patch.object(publication.shutil, 'which', return_value=None) as which, patch.object(publication.subprocess, 'run', return_value=completed) as run:
            self.assertEqual(publication.execute(['gh', 'api', 'repos/example/project'], environment=environment, timeout=45), b'public-response')
        which.assert_called_once_with('rtk', path='/ci/tools')
        self.assertEqual(run.call_args.args[0], ['gh', 'api', 'repos/example/project'])
        self.assertEqual(run.call_args.kwargs['env'], environment)
        self.assertEqual(run.call_args.kwargs['timeout'], 45)

    def test_available_wrapper_is_preserved_with_exact_requested_arguments(self):
        completed = subprocess.CompletedProcess([], 0, stdout=b'ok', stderr=b'')
        with patch.object(publication.shutil, 'which', return_value='/ci/tools/rtk'), patch.object(publication.subprocess, 'run', return_value=completed) as run:
            publication.execute(['git', 'show', 'fixed-source:pubspec.yaml'], data=b'fixture')
        self.assertEqual(run.call_args.args[0], ['/ci/tools/rtk', 'proxy', 'git', 'show', 'fixed-source:pubspec.yaml'])
        self.assertEqual(run.call_args.kwargs['input'], b'fixture')

    def test_actual_command_failure_is_never_retried_or_suppressed(self):
        completed = subprocess.CompletedProcess([], 7, stdout=b'', stderr=b'fixture-failure')
        with patch.object(publication.shutil, 'which', return_value=None), patch.object(publication.subprocess, 'run', return_value=completed) as run:
            with self.assertRaisesRegex(publication.ReleaseError, 'exit 7'):
                publication.execute(['gh', 'api', 'repos/example/project'])
        self.assertEqual(run.call_count, 1)


if __name__ == '__main__':
    unittest.main()
