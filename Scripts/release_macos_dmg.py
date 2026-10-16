#!/usr/bin/env python3
"""Build a signed, CloudKit-enabled, notarized DMG. Publishing belongs to CI."""

import argparse
import base64
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile


REPOSITORY = Path(__file__).resolve().parent.parent
TEAM = "5V8J7476Q9"
BUNDLE = "eu.jinx.jollymqtt"
CONTAINER = "iCloud.eu.jinx.jollymqtt"
SECRET_NAMES = (
    "MACOS_DEVELOPER_ID_P12_BASE64",
    "MACOS_DEVELOPER_ID_P12_PASSWORD",
    "MACOS_DEVELOPER_ID_PROFILE_BASE64",
    "APP_STORE_CONNECT_API_KEY_P8",
    "APP_STORE_CONNECT_API_KEY_ID",
    "APP_STORE_CONNECT_API_ISSUER_ID",
)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def version_from_tag(tag):
    require(re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag),
            "Release tags must be vX.Y.Z, for example v0.2.0 (no prerelease suffix).")
    return tag[1:]


def run(*args, capture=False, check=True):
    # Never echo command arguments: security import/unlock include credentials.
    result = subprocess.run([str(arg) for arg in args], check=False,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None,
                            env={key: value for key, value in os.environ.items() if key not in SECRET_NAMES})
    if check and result.returncode:
        if capture:
            sys.stderr.write(result.stderr.decode(errors="replace"))
        raise RuntimeError("{} failed (exit {}).".format(args[0], result.returncode))
    return result


def output(*args):
    return run(*args, capture=True).stdout.decode().strip()


def read_plist(path):
    with Path(path).open("rb") as stream:
        return plistlib.load(stream)


def decode_secret(name, path):
    try:
        data = base64.b64decode("".join(os.environ[name].split()), validate=True)
    except ValueError as error:
        raise RuntimeError("{} must contain a Base64-encoded file.".format(name)) from error
    require(data, "{} is empty after decoding.".format(name))
    path.write_bytes(data)
    path.chmod(0o600)


def validate_profile(profile, identity=None):
    require(profile.get("TeamIdentifier") == [TEAM], "Provisioning profile belongs to another team.")
    require(profile.get("ProvisionsAllDevices") is True and not profile.get("ProvisionedDevices"),
            "Use a Developer ID distribution profile, not development or App Store provisioning.")
    expiry = profile.get("ExpirationDate")
    require(isinstance(expiry, datetime) and expiry.replace(tzinfo=timezone.utc) > datetime.now(timezone.utc),
            "Provisioning profile is expired or has no expiration date.")
    require(re.fullmatch(r"[A-Fa-f0-9-]{36}", profile.get("UUID", "")), "Profile UUID is missing or invalid.")
    require(profile.get("Name"), "Provisioning profile has no name.")
    entitlements = profile.get("Entitlements", {})
    application_id = entitlements.get("com.apple.application-identifier", entitlements.get("application-identifier"))
    prefixes = profile.get("ApplicationIdentifierPrefix", [])
    require(application_id in [prefix + "." + BUNDLE for prefix in prefixes],
            "Provisioning profile must authorize the exact official bundle ID.")
    require(entitlements.get("com.apple.developer.team-identifier") == TEAM,
            "Provisioning profile has the wrong entitlement team.")
    require(CONTAINER in entitlements.get("com.apple.developer.icloud-container-identifiers", []),
            "Provisioning profile does not authorize the production CloudKit container.")
    require("CloudKit" in entitlements.get("com.apple.developer.icloud-services", []),
            "Provisioning profile does not authorize CloudKit.")
    environments = entitlements.get("com.apple.developer.icloud-container-environment")
    require(environments == "Production" or isinstance(environments, list) and "Production" in environments,
            "Provisioning profile does not authorize Production CloudKit.")
    require(entitlements.get("com.apple.developer.aps-environment") == "production",
            "Provisioning profile must authorize production push notifications.")
    require(not entitlements.get("get-task-allow") and not entitlements.get("com.apple.security.get-task-allow"),
            "Provisioning profile allows debugging.")
    if identity:
        fingerprints = [hashlib.sha1(cert).hexdigest().upper() for cert in profile.get("DeveloperCertificates", [])]
        require(identity.upper() in fingerprints, "Developer ID certificate is not authorized by the profile.")


@contextmanager
def signing_material(temporary):
    """Install into a temporary keychain; restore the search list even on failure."""
    missing = [name for name in SECRET_NAMES if not os.environ.get(name)]
    require(not missing, "Configure these GitHub secrets: " + ", ".join(missing))
    p12 = temporary / "developer-id.p12"
    profile_path = temporary / "developer-id.provisionprofile"
    key_path = temporary / "AuthKey.p8"
    decode_secret(SECRET_NAMES[0], p12)
    decode_secret(SECRET_NAMES[2], profile_path)
    key_path.write_text(os.environ["APP_STORE_CONNECT_API_KEY_P8"])
    key_path.chmod(0o600)
    require("-----BEGIN PRIVATE KEY-----" in key_path.read_text(),
            "APP_STORE_CONNECT_API_KEY_P8 must contain the raw .p8 file, not Base64.")
    profile = plistlib.loads(run("security", "cms", "-D", "-i", profile_path, capture=True).stdout)
    validate_profile(profile)
    previous_keychains = shlex.split(output("security", "list-keychains", "-d", "user"))
    keychain = temporary / "signing.keychain-db"
    password = secrets.token_hex(32)
    installed_profiles = []
    keychain_created = False
    try:
        run("security", "create-keychain", "-p", password, keychain, capture=True)
        keychain_created = True
        run("security", "set-keychain-settings", "-lut", "21600", keychain)
        run("security", "unlock-keychain", "-p", password, keychain, capture=True)
        run("security", "import", p12, "-k", keychain, "-P", os.environ[SECRET_NAMES[1]],
            "-T", "/usr/bin/codesign", "-T", "/usr/bin/security", capture=True)
        run("security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
            "-s", "-k", password, keychain, capture=True)
        run("security", "list-keychains", "-d", "user", "-s", keychain, *previous_keychains)
        identities = re.findall(r'\b([A-Fa-f0-9]{40}) "Developer ID Application: [^"\n]+ \(' + TEAM + r'\)"',
                                output("security", "find-identity", "-v", "-p", "codesigning", keychain))
        require(len(identities) == 1, "The .p12 must contain exactly one valid Developer ID Application identity for " + TEAM)
        identity = identities[0].upper()
        validate_profile(profile, identity)
        # Xcode 16+ uses UserData; the legacy location supports older tooling too.
        for folder in (Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles",
                       Path.home() / "Library/MobileDevice/Provisioning Profiles"):
            folder.mkdir(parents=True, exist_ok=True)
            destination = folder / (profile["UUID"] + ".provisionprofile")
            if destination.exists():
                require(destination.read_bytes() == profile_path.read_bytes(),
                        "Refusing to overwrite an existing provisioning profile: " + str(destination))
            else:
                shutil.copyfile(profile_path, destination)
                destination.chmod(0o600)
                installed_profiles.append(destination)
        yield profile, identity, keychain, key_path
    finally:
        # Run both cleanup commands even if restoring the search list fails.
        restored = run("security", "list-keychains", "-d", "user", "-s", *previous_keychains, check=False)
        deleted = run("security", "delete-keychain", keychain, check=False, capture=True) if keychain_created else None
        for path in installed_profiles:
            path.unlink(missing_ok=True)
        require(restored.returncode == 0 and (deleted is None or deleted.returncode == 0),
                "Temporary signing keychain cleanup failed.")


def validate_app_values(info, entitlements, version, build, profile):
    expected_info = {
        "CFBundleIdentifier": BUNDLE,
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build,
        "JollysMQTTProfileSyncMode": "cloudKit",
        "JollysMQTTCloudKitContainerIdentifier": CONTAINER,
        "JollysMQTTCloudKitZoneName": "EncryptedBrokerProfiles",
    }
    expected_entitlements = {
        "com.apple.security.app-sandbox": True,
        "com.apple.security.network.client": True,
        "com.apple.developer.team-identifier": TEAM,
        "com.apple.developer.icloud-container-environment": "Production",
        "com.apple.developer.icloud-container-identifiers": [CONTAINER],
        "com.apple.developer.icloud-services": ["CloudKit"],
        "com.apple.developer.aps-environment": "production",
    }
    for key, value in expected_info.items():
        require(info.get(key) == value, "App Info.plist has an unexpected " + key)
    for key, value in expected_entitlements.items():
        require(entitlements.get(key) == value, "Signed app has an unexpected or missing " + key)
    for key in ("get-task-allow", "com.apple.security.get-task-allow"):
        require(not entitlements.get(key), "Signed app allows debugging.")
    profile_entitlements = profile["Entitlements"]
    application_id = profile_entitlements.get("com.apple.application-identifier", profile_entitlements.get("application-identifier"))
    require(entitlements.get("com.apple.application-identifier") == application_id,
            "Signed app identifier does not match the provisioning profile.")


def verify_app(app, version, build, profile, identity, temporary):
    run("codesign", "--verify", "--strict", app)
    entitlements = plistlib.loads(run("codesign", "--display", "--entitlements", "-", "--xml", app, capture=True).stdout)
    validate_app_values(read_plist(app / "Contents/Info.plist"), entitlements, version, build, profile)
    embedded = plistlib.loads(run("security", "cms", "-D", "-i", app / "Contents/embedded.provisionprofile", capture=True).stdout)
    validate_profile(embedded, identity)
    require(embedded["UUID"] == profile["UUID"], "Export embedded a different provisioning profile.")
    signature = run("codesign", "--display", "--verbose=4", app, capture=True)
    details = (signature.stdout + signature.stderr).decode()
    require(re.search(r"flags=.*\bruntime\b", details), "Signed app does not enable hardened runtime.")
    require("Timestamp=" in details, "Signed app has no secure signing timestamp.")
    certificate_prefix = Path(tempfile.mkdtemp(prefix="app-certificate-", dir=temporary)) / "certificate-"
    run("codesign", "--display", "--extract-certificates=" + str(certificate_prefix), app)
    leaf = Path(str(certificate_prefix) + "0").read_bytes()
    require(hashlib.sha1(leaf).hexdigest().upper() == identity, "App is signed with a different certificate.")
    architectures = set(output("lipo", "-archs", app / "Contents/MacOS/JollysMQTT").split())
    require(architectures == {"arm64", "x86_64"}, "App must contain both arm64 and x86_64.")
    return entitlements


def notarize(path, key_path, report_directory):
    print("Notarizing " + path.name, flush=True)
    authentication = ("--key", key_path, "--key-id", os.environ["APP_STORE_CONNECT_API_KEY_ID"],
                      "--issuer", os.environ["APP_STORE_CONNECT_API_ISSUER_ID"])
    result = run("xcrun", "notarytool", "submit", path, *authentication, "--wait",
                 "--timeout", "30m", "--output-format", "json", capture=True, check=False)
    (report_directory / (path.name + "-submission.json")).write_bytes(result.stdout)
    try:
        submission = json.loads(result.stdout)
    except ValueError as error:
        sys.stderr.write(result.stderr.decode(errors="replace"))
        raise RuntimeError("Notarization returned no JSON result for " + path.name) from error
    if submission.get("id"):
        log = run("xcrun", "notarytool", "log", submission["id"], *authentication, capture=True, check=False)
        (report_directory / (path.name + "-log.json")).write_bytes(log.stdout)
        if log.returncode == 0:
            for issue in json.loads(log.stdout).get("issues") or []:
                print("Notary {}: {} ({})".format(issue.get("severity"), issue.get("message"), issue.get("path")))
    require(result.returncode == 0 and submission.get("status") == "Accepted",
            "Notarization was not Accepted for {} (status {}, submission {}). Nothing may be released."
            .format(path.name, submission.get("status"), submission.get("id")))


def verify_source(commit):
    require(output("git", "-C", REPOSITORY, "rev-parse", "HEAD") == commit, "HEAD changed during the release.")
    require(not output("git", "-C", REPOSITORY, "status", "--porcelain=v1", "--untracked-files=normal"),
            "Release requires a clean committed worktree.")


def verify_dependency_pins(expected, actual):
    def states(path):
        return {pin["identity"]: pin["state"] for pin in json.loads(path.read_text())["pins"]}
    require(states(expected) == states(actual), "Xcode dependency revisions differ from the checked-in Package.resolved.")


def build_release(tag, destination):
    version = version_from_tag(tag)
    commit = output("git", "-C", REPOSITORY, "rev-parse", "HEAD")
    require(output("git", "-C", REPOSITORY, "rev-parse", "refs/tags/" + tag + "^{commit}") == commit,
            "The version tag must point to the checked-out commit.")
    verify_source(commit)
    require(destination.is_absolute(), "Output directory must be absolute.")
    destination = destination.resolve()
    require(REPOSITORY != destination and REPOSITORY not in destination.parents, "Output must be outside the repository.")
    require(not destination.exists(), "Output directory already exists; previous release evidence will not be overwritten.")
    settings = output(REPOSITORY / "Scripts/xcode_git_version.sh", "--repo", REPOSITORY,
                      "--marketing-version", version, "--require-clean", "--utc", "--format", "xcconfig")
    match = re.search(r"^CURRENT_PROJECT_VERSION = ([0-9]+\.[0-9]+\.[123])$", settings, re.MULTILINE)
    require(match, "Version script did not produce a committed JNX build number.")
    build = match.group(1)
    destination.mkdir(parents=True)
    reports = destination / "notary"
    reports.mkdir()
    # Xcode keeps a separate lockfile from the package. Seed it from the reviewed
    # package lock, let Xcode refresh its root hash, then require identical pins.
    package_lock = REPOSITORY / "JollysMQTTPackage/Package.resolved"
    xcode_lock = REPOSITORY / "JollysMQTT.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    xcode_lock.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(package_lock, xcode_lock)
    run("xcodebuild", "-resolvePackageDependencies", "-project", REPOSITORY / "JollysMQTT.xcodeproj",
        "-scheme", "JollysMQTT", "-derivedDataPath", destination / "DerivedData")
    verify_dependency_pins(package_lock, xcode_lock)
    with tempfile.TemporaryDirectory(prefix="jollysmqtt-signing-") as temporary_name:
        temporary = Path(temporary_name)
        with signing_material(temporary) as (profile, identity, keychain, key_path):
            archive = destination / "JollysMQTT.xcarchive"
            export = destination / "export"
            print("Building JollysMQTT {} ({}) from {}".format(version, build, commit), flush=True)
            run("xcodebuild", "-project", REPOSITORY / "JollysMQTT.xcodeproj", "-scheme", "JollysMQTT",
                "-configuration", "Official Release", "-destination", "generic/platform=macOS",
                "-archivePath", archive, "-derivedDataPath", destination / "DerivedData",
                "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile",
                "CODE_SIGN_STYLE=Manual", "CODE_SIGN_IDENTITY=" + identity, "DEVELOPMENT_TEAM=" + TEAM,
                "PROVISIONING_PROFILE_SPECIFIER=" + profile["Name"],
                "ENABLE_HARDENED_RUNTIME=YES", "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO",
                "OTHER_CODE_SIGN_FLAGS=--timestamp", "ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO",
                "MARKETING_VERSION=" + version, "CURRENT_PROJECT_VERSION=" + build, "archive")
            archived_app = archive / "Products/Applications/JollysMQTT.app"
            before = verify_app(archived_app, version, build, profile, identity, temporary)
            export_options = destination / "DeveloperIDExportOptions.plist"
            with export_options.open("wb") as stream:
                plistlib.dump({"method": "developer-id", "destination": "export", "signingStyle": "manual",
                              "teamID": TEAM, "signingCertificate": identity,
                              "provisioningProfiles": {BUNDLE: profile["UUID"]},
                              "iCloudContainerEnvironment": "Production",
                              "manageAppVersionAndBuildNumber": False}, stream)
            run("xcodebuild", "-exportArchive", "-archivePath", archive, "-exportPath", export,
                "-exportOptionsPlist", export_options)
            app = export / "JollysMQTT.app"
            after = verify_app(app, version, build, profile, identity, temporary)
            require(all(after.get(key) == value for key, value in before.items()), "Export changed archived entitlements.")
            # Staple the app before packaging so a copied app also carries its ticket.
            zipped_app = destination / "JollysMQTT.zip"
            run("ditto", "-c", "-k", "--keepParent", app, zipped_app)
            notarize(zipped_app, key_path, reports)
            run("xcrun", "stapler", "staple", app)
            run("xcrun", "stapler", "validate", app)
            run("spctl", "--assess", "--type", "execute", "--verbose=2", app)
            stage = destination / "dmg-root"
            stage.mkdir()
            run("ditto", app, stage / app.name)
            (stage / "Applications").symlink_to("/Applications")
            # Assets are created only after both notarizations and every check succeed.
            dmg_name = "JollysMQTT-{}-universal.dmg".format(version)
            dmg = destination / dmg_name
            run("hdiutil", "create", "-volname", "JollysMQTT", "-srcfolder", stage,
                "-format", "UDZO", "-fs", "HFS+", dmg)
            run("codesign", "--sign", identity, "--keychain", keychain, "--timestamp", dmg)
            run("codesign", "--verify", "--strict", dmg)
            run("hdiutil", "verify", dmg)
            notarize(dmg, key_path, reports)
            run("xcrun", "stapler", "staple", dmg)
            run("xcrun", "stapler", "validate", dmg)
            run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", dmg)
            verify_dependency_pins(package_lock, xcode_lock)
            verify_source(commit)
        # Keychain cleanup must also succeed before making publishable assets.
        assets = destination / "assets"
        assets.mkdir()
        shutil.move(str(dmg), assets / dmg_name)
        digest = hashlib.sha256((assets / dmg_name).read_bytes()).hexdigest()
        (assets / "SHA256SUMS").write_text("{}  {}\n".format(digest, dmg_name))
    print("Verified release assets: " + str(assets), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True, help="Existing vX.Y.Z tag pointing at HEAD")
    parser.add_argument("--output-dir", type=Path, help="New output directory outside the worktree")
    parser.add_argument("--validate-tag", action="store_true", help="Validate tag syntax without building or using credentials")
    arguments = parser.parse_args()
    try:
        version_from_tag(arguments.tag)
        if arguments.validate_tag:
            return
        require(sys.platform == "darwin", "Building a DMG requires macOS and Xcode.")
        require(arguments.output_dir is not None, "--output-dir is required for a release.")
        build_release(arguments.tag, arguments.output_dir)
    except (RuntimeError, ValueError, OSError) as error:
        parser.exit(1, "error: {}\n".format(error))


if __name__ == "__main__":
    main()
