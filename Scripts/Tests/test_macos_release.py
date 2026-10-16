"""Release gates use synthetic profiles and subprocess mocks, never Apple accounts."""

import base64
from contextlib import contextmanager
from copy import deepcopy
from datetime import datetime, timedelta
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("release", Path(__file__).resolve().parents[1] / "release_macos_dmg.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

CERTIFICATE = b"synthetic certificate, not signing material"
IDENTITY = hashlib.sha1(CERTIFICATE).hexdigest().upper()


def fixture_profile():
    return {
        "TeamIdentifier": [release.TEAM],
        "ApplicationIdentifierPrefix": [release.TEAM],
        "UUID": "00000000-0000-0000-0000-000000000001",
        "Name": "Synthetic Developer ID",
        "ProvisionsAllDevices": True,
        "ExpirationDate": datetime.utcnow() + timedelta(days=30),
        "DeveloperCertificates": [CERTIFICATE],
        "Entitlements": {
            "com.apple.application-identifier": release.TEAM + "." + release.BUNDLE,
            "com.apple.developer.team-identifier": release.TEAM,
            "com.apple.developer.icloud-container-identifiers": [release.CONTAINER],
            "com.apple.developer.icloud-services": ["CloudKit"],
            "com.apple.developer.icloud-container-environment": "Production",
            "com.apple.developer.aps-environment": "production",
        },
    }


def fixture_app():
    info = {"CFBundleIdentifier": release.BUNDLE, "CFBundleShortVersionString": "0.2.0",
            "CFBundleVersion": "20261016.120000.1", "JollysMQTTProfileSyncMode": "cloudKit",
            "JollysMQTTCloudKitContainerIdentifier": release.CONTAINER,
            "JollysMQTTCloudKitZoneName": "EncryptedBrokerProfiles"}
    entitlements = deepcopy(fixture_profile()["Entitlements"])
    entitlements.update({"com.apple.security.app-sandbox": True, "com.apple.security.network.client": True})
    return info, entitlements


class ReleaseTests(unittest.TestCase):
    def test_version_tags(self):
        self.assertEqual(release.version_from_tag("v0.2.0"), "0.2.0")
        for value in ("0.2.0", "v1.2", "v01.2.3", "v1.2.3-rc.1", "v1.2.3\n", "v1.2.3;echo bad"):
            with self.subTest(tag=value), self.assertRaises(RuntimeError):
                release.version_from_tag(value)

    def test_profile_rejects_wrong_team_capabilities_certificate_and_distribution(self):
        release.validate_profile(fixture_profile(), IDENTITY)
        cases = (
            ("TeamIdentifier", ["OTHERTEAM1"]), ("ProvisionsAllDevices", False),
            ("ProvisionedDevices", ["a-device"]), ("ExpirationDate", datetime(2000, 1, 1)),
            ("DeveloperCertificates", [b"different certificate"]),
        )
        for key, value in cases:
            profile = fixture_profile()
            profile[key] = value
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                release.validate_profile(profile, IDENTITY)
        for key in fixture_profile()["Entitlements"]:
            profile = fixture_profile()
            del profile["Entitlements"][key]
            with self.subTest(missing=key), self.assertRaises(RuntimeError):
                release.validate_profile(profile, IDENTITY)
        profile = fixture_profile()
        profile["Entitlements"]["com.apple.application-identifier"] = release.TEAM + ".*"
        with self.assertRaises(RuntimeError):
            release.validate_profile(profile, IDENTITY)

    def test_signed_app_cannot_fall_back_to_local_or_development_cloudkit(self):
        info, entitlements = fixture_app()
        release.validate_app_values(info, entitlements, "0.2.0", "20261016.120000.1", fixture_profile())
        for key in entitlements:
            changed = deepcopy(entitlements)
            del changed[key]
            with self.subTest(missing=key), self.assertRaises(RuntimeError):
                release.validate_app_values(info, changed, "0.2.0", "20261016.120000.1", fixture_profile())
        for key, value in (("JollysMQTTProfileSyncMode", "localOnly"), ("CFBundleShortVersionString", "0.1.0")):
            changed = dict(info, **{key: value})
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                release.validate_app_values(changed, entitlements, "0.2.0", "20261016.120000.1", fixture_profile())
        for key, value in (("com.apple.developer.icloud-container-environment", "Development"),
                           ("com.apple.security.get-task-allow", True)):
            changed = dict(entitlements, **{key: value})
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                release.validate_app_values(info, changed, "0.2.0", "20261016.120000.1", fixture_profile())

    def test_dependency_drift_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            first, second = [Path(directory) / name for name in ("expected.json", "actual.json")]
            lock = {"pins": [{"identity": "mqtt-nio", "state": {"revision": "reviewed"}}]}
            first.write_text(json.dumps(lock))
            second.write_text(json.dumps(lock))
            release.verify_dependency_pins(first, second)
            lock["pins"][0]["state"]["revision"] = "unreviewed"
            second.write_text(json.dumps(lock))
            with self.assertRaises(RuntimeError):
                release.verify_dependency_pins(first, second)

    def test_actual_signature_and_architecture_gates(self):
        info, entitlements = fixture_app()
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            app = temporary / "JollysMQTT.app"
            (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))

            for signature, architectures, valid in (
                (b"flags=0x10000(runtime)\nTimestamp=fixture\n", "arm64 x86_64", True),
                (b"flags=0x0(none)\nTimestamp=fixture\n", "arm64 x86_64", False),
                (b"flags=0x10000(runtime)\n", "arm64 x86_64", False),
                (b"flags=0x10000(runtime)\nTimestamp=fixture\n", "arm64", False),
            ):
                def fake_run(*args, **kwargs):
                    data = b""
                    if args[:3] == ("codesign", "--display", "--entitlements"):
                        data = plistlib.dumps(entitlements)
                    elif args[:3] == ("codesign", "--display", "--verbose=4"):
                        data = signature
                    elif args[:2] == ("security", "cms"):
                        data = plistlib.dumps(fixture_profile())
                    elif args[:2] == ("codesign", "--display"):
                        Path(str(args[2]).split("=", 1)[1] + "0").write_bytes(CERTIFICATE)
                    return subprocess.CompletedProcess(args, 0, data, b"")

                with self.subTest(signature=signature, architectures=architectures), \
                        patch.object(release, "run", side_effect=fake_run), \
                        patch.object(release, "output", return_value=architectures):
                    if valid:
                        release.verify_app(app, "0.2.0", "20261016.120000.1", fixture_profile(), IDENTITY, temporary)
                    else:
                        with self.assertRaises(RuntimeError):
                            release.verify_app(app, "0.2.0", "20261016.120000.1", fixture_profile(), IDENTITY, temporary)

    def test_subprocesses_do_not_inherit_release_secrets(self):
        with patch.dict(os.environ, {name: "synthetic secret" for name in release.SECRET_NAMES}), \
                patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as command:
            release.run("fixture")
            for name in release.SECRET_NAMES:
                self.assertNotIn(name, command.call_args.kwargs["env"])

    def test_notary_exit_zero_still_requires_accepted_status(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {
            "APP_STORE_CONNECT_API_KEY_ID": "fixture", "APP_STORE_CONNECT_API_ISSUER_ID": "fixture"
        }):
            for status, code in (("Accepted", 0), ("Invalid", 0), ("In Progress", 0), ("Accepted", 1)):
                response = subprocess.CompletedProcess([], code, json.dumps({"id": "fixture", "status": status}).encode(), b"")
                log = subprocess.CompletedProcess([], 0, b'{"issues":[]}', b"")
                with self.subTest(status=status, code=code), patch.object(release, "run", side_effect=[response, log]):
                    if status == "Accepted" and code == 0:
                        release.notarize(Path("fixture.dmg"), Path("fixture.p8"), Path(directory))
                    else:
                        with self.assertRaisesRegex(RuntimeError, "not Accepted"):
                            release.notarize(Path("fixture.dmg"), Path("fixture.p8"), Path(directory))

    def test_signing_credentials_are_removed_after_failure(self):
        encoded = base64.b64encode(b"synthetic file").decode()
        environment = {name: encoded for name in release.SECRET_NAMES}
        environment["APP_STORE_CONNECT_API_KEY_P8"] = "-----BEGIN PRIVATE KEY-----\nfixture\n-----END PRIVATE KEY-----"
        commands = []

        def fake_run(*args, **kwargs):
            commands.append(tuple(str(arg) for arg in args))
            stdout = plistlib.dumps(fixture_profile()) if args[:2] == ("security", "cms") else b""
            return subprocess.CompletedProcess(args, 0, stdout, b"")

        def fake_output(*args):
            if args[1] == "list-keychains":
                return '"/original/login.keychain-db"'
            return '1) {} "Developer ID Application: Synthetic ({})"'.format(IDENTITY, release.TEAM)

        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, environment), \
                patch.object(release, "run", side_effect=fake_run), patch.object(release, "output", side_effect=fake_output), \
                patch.object(Path, "home", return_value=Path(directory) / "home"):
            with self.assertRaisesRegex(RuntimeError, "synthetic failure"):
                with release.signing_material(Path(directory)):
                    raise RuntimeError("synthetic failure")
            self.assertFalse(list((Path(directory) / "home").rglob("*.provisionprofile")))
            self.assertIn(("security", "list-keychains", "-d", "user", "-s", "/original/login.keychain-db"), commands)
            self.assertTrue(any(command[:2] == ("security", "delete-keychain") for command in commands))

    def test_release_pipeline_never_creates_assets_after_failed_gate(self):
        """Exercise orchestration through notarization with no signing or network."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo = root / "repo"
            (repo / "JollysMQTTPackage").mkdir(parents=True)
            (repo / "JollysMQTTPackage/Package.resolved").write_text('{"pins":[]}')

            @contextmanager
            def material(_temporary):
                yield fixture_profile(), IDENTITY, root / "keychain", root / "key.p8"

            def fake_output(*args):
                if str(args[0]).endswith("xcode_git_version.sh"):
                    return "CURRENT_PROJECT_VERSION = 20261016.120000.1"
                return "commit"

            def fake_run(*args, **kwargs):
                if args[:2] == ("hdiutil", "create"):
                    Path(args[-1]).write_bytes(b"synthetic dmg")
                return subprocess.CompletedProcess(args, 0, b"", b"")

            for failed_round in (1, 2, None):
                destination = root / ("output-" + str(failed_round))
                responses = [None, None]
                if failed_round:
                    responses[failed_round - 1] = RuntimeError("synthetic notarization failure")
                with self.subTest(failed_round=failed_round), patch.object(release, "REPOSITORY", repo), \
                        patch.object(release, "output", side_effect=fake_output), patch.object(release, "run", side_effect=fake_run), \
                        patch.object(release, "signing_material", material), patch.object(release, "verify_source"), \
                        patch.object(release, "verify_app", return_value=fixture_app()[1]), \
                        patch.object(release, "notarize", side_effect=responses):
                    if failed_round:
                        with self.assertRaisesRegex(RuntimeError, "synthetic notarization failure"):
                            release.build_release("v0.2.0", destination)
                        self.assertFalse((destination / "assets").exists())
                    else:
                        release.build_release("v0.2.0", destination)
                        checksum = (destination / "assets/SHA256SUMS").read_text()
                        self.assertEqual(checksum, hashlib.sha256(b"synthetic dmg").hexdigest() + "  JollysMQTT-0.2.0-universal.dmg\n")


if __name__ == "__main__":
    unittest.main()
