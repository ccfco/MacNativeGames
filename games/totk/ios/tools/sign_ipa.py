#!/usr/bin/env python3
"""Sign an unsigned sideloadable IPA with an Ad Hoc / development provisioning profile.

The build (build_ipa.py) leaves the app unsigned. This wraps the whole bundle: the profile goes in as
embedded.mobileprovision, the profile's entitlements are applied to the app, and every nested code item is signed
before the app itself. The bundle ID must match the profile's application-identifier.

Example (the identity is found through the keychain search list; do not pass --keychain unless that keychain
also holds the Apple root):
  python3 ios/tools/sign_ipa.py --ipa TOTK.ipa --profile /path/to/profile.mobileprovision \
      --identity 'iPhone Distribution: Your Name (TEAMID)' --out TOTK-signed.ipa

A keychain made for signing needs the Apple WWDR intermediate and, in the keychain search list, the system roots:
  security create-keychain -p <password> /tmp/totk-sign.keychain-db
  security unlock-keychain -p <password> /tmp/totk-sign.keychain-db
  security import identity.p12 -k /tmp/totk-sign.keychain-db -P <p12 password> -T /usr/bin/codesign
  security import AppleWWDRCAG3.cer -k /tmp/totk-sign.keychain-db -T /usr/bin/codesign
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <password> /tmp/totk-sign.keychain-db
  security list-keychains -d user -s /tmp/totk-sign.keychain-db \
      /System/Library/Keychains/SystemRootCertificates.keychain /Library/Keychains/System.keychain \
      $(security list-keychains -d user | tr -d '"')
Restore the search list afterwards if the keychain was only for this build. --keychain restricts chain building to
that keychain, so either leave it out (the search list above) or import the Apple root into it as well.
"""
import argparse
import plistlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def run(args, **kwargs):
    print('+', ' '.join(str(x) for x in args))
    subprocess.run([str(x) for x in args], check=True, **kwargs)


def load_profile(profile: Path) -> dict:
    raw = subprocess.check_output(['security', 'cms', '-D', '-i', str(profile)])
    return plistlib.loads(raw)


def sign_item(path: Path, identity: str, keychain: str, entitlements: Path | None = None):
    args = ['codesign', '--force', '--sign', identity, '--timestamp=none', '--generate-entitlement-der']
    if keychain:
        args += ['--keychain', keychain]
    if entitlements:
        args += ['--entitlements', str(entitlements)]
    args.append(str(path))
    run(args)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--ipa', type=Path, required=True, help='the unsigned IPA from build_ipa.py')
    p.add_argument('--profile', type=Path, required=True, help='the .mobileprovision to embed')
    p.add_argument('--identity', required=True, help='codesigning identity, e.g. "iPhone Distribution: Your Name (TEAMID)"')
    p.add_argument('--keychain', default='', help='keychain holding the identity (default: the search list)')
    p.add_argument('--out', type=Path, help='signed IPA (default: <ipa>-signed.ipa)')
    p.add_argument('--keep-work', action='store_true', help='keep the unzipped Payload next to the output')
    a = p.parse_args()

    ipa = a.ipa.resolve()
    out = (a.out or ipa.with_name(ipa.stem + '-signed.ipa')).resolve()
    if not ipa.is_file():
        sys.exit(f'missing IPA: {ipa}')
    if not a.profile.is_file():
        sys.exit(f'missing profile: {a.profile}')
    profile = load_profile(a.profile)
    ent = profile.get('Entitlements', {})
    app_id = ent.get('application-identifier', '')
    if '.' not in app_id:
        sys.exit('the profile has no application-identifier')
    team, wanted_bundle = app_id.split('.', 1)

    work = Path(tempfile.mkdtemp(prefix='totk-sign-', dir=out.parent))
    try:
        run(['ditto', '-x', '-k', ipa, work])
        apps = list((work / 'Payload').glob('*.app'))
        if len(apps) != 1:
            sys.exit(f'expected one .app in Payload, found {len(apps)}')
        app = apps[0]
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        bundle = info.get('CFBundleIdentifier', '')
        if bundle != wanted_bundle:
            sys.exit(f'bundle ID {bundle!r} does not match the profile {wanted_bundle!r}; build with --bundle-id '
                     f'{wanted_bundle} or make a profile for {bundle}')
        if team and not app_id.startswith(team + '.'):
            sys.exit(f'profile application-identifier {app_id!r} is malformed')

        shutil.copy2(a.profile, app / 'embedded.mobileprovision')
        ent_path = work / 'signing-entitlements.plist'
        ent_path.write_bytes(plistlib.dumps(ent))

        # Nested code first: frameworks, dylibs and app extensions, deepest first.
        nested = []
        for root in (app, app / 'Frameworks', app / 'PlugIns'):
            if not root.is_dir():
                continue
            for item in root.rglob('*'):
                if item.is_dir() and item.suffix in ('.framework', '.appex', '.xpc'):
                    nested.append(item)
                elif item.is_file() and item.suffix in ('.dylib',):
                    nested.append(item)
        for item in sorted(set(nested), key=lambda x: len(x.parts), reverse=True):
            # Nested code never carries the app's entitlements: a framework has none, and an app extension needs its
            # own (this script signs the game app, which has neither).
            sign_item(item, a.identity, a.keychain)

        sign_item(app, a.identity, a.keychain, ent_path)
        run(['codesign', '--verify', '--deep', '--strict', '--verbose=2', app])

        if out.exists():
            out.unlink()
        run(['zip', '-qry', '-0', '-y', out, 'Payload'], cwd=work)
        print(f'signed IPA: {out} ({out.stat().st_size / 2**30:.1f} GiB)')
        print(f'signed app: {app}')
        if a.keep_work:
            print(f'work dir kept: {work}')
            work = None
    finally:
        if work and work.exists():
            shutil.rmtree(work, ignore_errors=True)


if __name__ == '__main__':
    main()