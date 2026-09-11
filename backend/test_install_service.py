import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("install_service", Path(__file__).with_name("install-service.py"))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallPlanTests(unittest.TestCase):
    def test_paths_follow_requested_install_directory(self):
        base = Path.home() / "Library/Application Support/IME backend test"
        model = Path.home() / "Models/MiniCPM test"
        paths = installer.locations(base, model)
        self.assertEqual(paths["server"], base / "mlx/server.py")
        self.assertEqual(paths["python"], base / "mlx-runtime/bin/python")
        self.assertEqual(paths["model"], model)
        self.assertEqual(paths["agent"].parent, Path.home() / "Library/LaunchAgents")

    def test_launch_agent_is_inert_until_explicit_enable(self):
        paths = installer.locations(Path.home() / "Library/Rime/ghost")
        agent = installer.launch_agent(paths)
        self.assertTrue(agent["Disabled"])
        self.assertEqual(agent["ProcessType"], "Interactive")
        self.assertEqual(agent["ProgramArguments"][-2:], ["--port", "18081"])
        self.assertEqual(agent["EnvironmentVariables"]["HF_HUB_OFFLINE"], "1")
        self.assertNotIn("/bin/sh", agent["ProgramArguments"])

    def test_running_service_prevents_install_before_any_model_or_file_work(self):
        paths = installer.locations(Path.home() / "Library/Rime/ghost")
        with patch.object(installer.subprocess, "run") as run, \
                patch.object(installer, "verify_model") as verify:
            run.return_value.returncode = 0
            with self.assertRaises(RuntimeError):
                installer.install(paths)
            verify.assert_not_called()
            self.assertEqual(run.call_args.args[0][:2], ["launchctl", "print"])

    def test_model_download_is_pinned_and_data_only(self):
        self.assertEqual(installer.MODEL_ID, "mlx-community/MiniCPM5-1B-4bit")
        self.assertEqual(installer.MODEL_REVISION, "36447e84d28c57588a6e91907675e44afe54ab00")
        self.assertEqual(len(installer.MODEL_SHA256), 64)
        self.assertIn("model.safetensors", installer.MODEL_FILES)
        self.assertFalse(any(name.endswith(".py") for name in installer.MODEL_FILES))


if __name__ == "__main__":
    unittest.main()
