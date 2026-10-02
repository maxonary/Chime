# CI and opt-in internal TestFlight

`.github/workflows/chime-ci.yml` adds validation to every pull request and push to
`main`. Signing and upload are **off by default**. Merging this configuration alone
does not create Apple credentials, provision apps/devices, deploy the gateway,
or upload a build. This pipeline does not add the Watch dot client from draft PR #21.

## What runs

| Change | Validation | App upload on main, once enabled |
| --- | --- | --- |
| Gateway code/config/dependencies | Pipeline tests, workflow lint, gateway typecheck and unit tests | No |
| iPhone/Watch/widgets/project/assets | Pipeline tests, workflow lint, Watch Swift tests, iPhone + Watch simulator builds, unsigned Release archive verification | Yes |
| Mixed gateway and app changes | Both sets | Yes |
| CI/release scripts or workflow | Both sets | No, unless app files also changed |
| Watch tests or `scripts/check-watch.sh` | Apple checks | No |
| Documentation only | Pipeline tests and workflow lint | No |

Classification uses the full local git diff, including deletions and both sides of
renames, without GitHub's changed-file API pagination or workflow path-filter limits.
PR validation builds GitHub's merge commit; the main push validates and uploads
its exact `github.sha`. The always-present **Validated commit** job requires every
applicable job to succeed, so skipped path-specific jobs do not leave a required
check pending. Make this the required branch check during authorized setup.

The Apple job uses GitHub's official `xcode-27` hosted preview runner and explicitly
selects `/Applications/Xcode_27.0.app`. This matches the installed compiler used
for local validation. That hosted image is currently preview; availability and
queue time are outside this repository. If the image or pinned app path changes,
update the workflow through review, run the same checks and revalidate signing.
Do not silently fall back to a different Xcode or use a self-hosted runner for PRs.

`Chime` is the shared archive scheme. It embeds:

- iPhone: `maxonary.chime`
- Watch: `maxonary.chime.watchkitapp`
- Watch widgets: `maxonary.chime.watchkitapp.widgets`

All targets currently require iOS/watchOS 26.5+, use team `Q37KAF726J`, and have
marketing version 1.0. The checked-in build number is not changed by CI.

## Release boundary

The release job requires all of the following:

1. A `push` to `main` in `maxonary/Chime`, with application changes.
2. Successful applicable validation jobs in **the same workflow run**.
3. Repository variable `TESTFLIGHT_UPLOAD_ENABLED` set to the exact string `true`.
4. Access to the protected `internal-testflight` environment and complete signing
   configuration. When enabled but configuration is missing, the job fails before
   opening a keychain or attempting an upload.
5. The checkout SHA matching the event SHA and current remote `main`, checked both
   before signing and immediately before upload. Stale queued/retried commits fail.

There is no `pull_request_target`, `workflow_run`, manual dispatch bypass, download
of a PR-produced archive, privileged PR job, external tester API, or App Store
submission step. The upload script additionally refuses local, fork, PR,
self-hosted, disabled and mismatched-commit invocations.

Release jobs share one concurrency group with cancellation disabled for a running
upload. GitHub may replace an older pending job when newer pushes arrive; intermediate
main commits are therefore not guaranteed a build. New commits arriving during an
already-started upload do not cancel it. Each uploaded archive still comes from
its own successfully validated commit.

## Build-number allocation

Set `TESTFLIGHT_BUILD_OFFSET` to a positive integer reserved for this workflow,
above the highest existing build-number major component in App Store Connect.
The pipeline uses:

```text
(OFFSET + github.run_number).github.run_attempt.0
```

For example, offset `1000`, workflow run `12`, attempt `1` gives `1012.1.0`;
a retry gives `1012.2.0`; run `13` gives `1013.1.0`. The workflow run counter
increases for every new run; retries increment the attempt. Main-only serial
uploads and stale-main checks prevent an older commit's late rerun from being
uploaded after a newer main release. Gaps caused by PRs and skipped runs are fine.

The same value is written to **all six Debug/Release target configurations** in
the ephemeral runner checkout. Archive verification checks the iPhone, embedded
Watch and widgets have matching versions and the allocated build number.
`manageAppVersionAndBuildNumber=false` prevents Xcode changing it during export.

Do not decrease the offset, recreate/rename the workflow counter, force-push main
backwards, or upload manual builds into this reserved number space. If changing
the workflow identity or sharing the app with another uploader, first inspect the
latest App Store Connect builds and reserve a new, higher offset. The helper fails
closed above major 9999 or attempt 99; allocation changes need review. This is a
repository-owned monotonic namespace, not a cross-uploader reservation service.

## Setup — requires a separate authorized operator action

No settings or secrets in this section are configured by the PR.

1. A repository administrator reviews/merges the pipeline and enables GitHub Actions
   only if necessary. Configure main protection: require **Validated commit**, review
   workflow/signing-script changes, and disallow force pushes. Do not enable uploads yet.
2. Create the **`internal-testflight`** environment. Restrict deployment branches to
   `main` only. Require an appropriate reviewer and prevent self-review where your
   GitHub plan supports it. Environment controls are essential: job conditions alone
   cannot prevent a malicious same-repository PR from editing its workflow. If your
   plan cannot provide the needed protection, keep upload disabled.
3. Obtain separately authorized access to the existing Apple team and
   [Chime — Voice Bubble, app 6814462529](https://appstoreconnect.apple.com/apps/6814462529/testflight).
   Have an authorized Apple administrator supply **existing approved** distribution
   material. This workflow does not create or renew certificates, profiles, IDs,
   devices or API keys and does not pass `-allowProvisioningUpdates`.
4. Add the following **environment secrets**, never repository-wide secrets or files
   in git. Use the minimum App Store Connect API role that permits uploads to this
   app; no Admin role is required by the script. Confirm the key's actual app access
   and organizational policy with the Apple account administrator. The team API-key
   issuer/key-ID contract is used; interactive Apple-ID/2FA sessions are not used.

| Environment secret | Value |
| --- | --- |
| `APPLE_DISTRIBUTION_P12_BASE64` | Single-line base64 of a password-protected P12 containing one Apple Distribution certificate and its private key |
| `APPLE_DISTRIBUTION_P12_PASSWORD` | Nonempty P12 password |
| `IPHONE_PROFILE_BASE64` | App Store distribution mobileprovision for `maxonary.chime` |
| `WATCH_PROFILE_BASE64` | App Store distribution mobileprovision for `maxonary.chime.watchkitapp` |
| `WIDGET_PROFILE_BASE64` | App Store distribution mobileprovision for `maxonary.chime.watchkitapp.widgets` |
| `ASC_PRIVATE_KEY_BASE64` | Single-line base64 of the approved App Store Connect API `.p8` private key |
| `ASC_KEY_ID` | Its ten-character key ID |
| `ASC_ISSUER_ID` | Its issuer UUID |

All profiles must be unexpired, belong to `Q37KAF726J`, match their exact bundle ID,
and authorize the imported distribution certificate. Development, ad-hoc and
enterprise profiles are rejected. The script creates an ephemeral private keychain,
installs only these profiles, and selects their UUIDs per Release target in a
runner-local XML project copy. It verifies the signed archive and restores the
keychain search list/removes profiles and temporary material on exit. A hard-killed
hosted VM is discarded; do not switch this job to a persistent runner. No signing
material, archive, IPA, or export log is published as a workflow artifact.

5. Inspect current App Store Connect build numbers and set repository variable
   `TESTFLIGHT_BUILD_OFFSET` as described above. Do not assume checked-in build 8 is
   the latest uploaded build.
6. In App Store Connect, select/create an **internal** TestFlight group and configure
   its authorized internal testers. Enable automatic distribution of new eligible
   builds if desired. The pipeline uploads; it does not create groups or invite people.
7. Only after the protections and credentials are reviewed, explicitly set repository
   variable `TESTFLIGHT_UPLOAD_ENABLED=true`. The next eligible main app change can
   release after checks and environment approval. Setting the variable alone does
   not start a run. A controlled rerun is possible only while that commit remains
   main, was an app-changing push, and passes this pipeline's gates.

## Upload, processing and rollback

The script archives the shared `Chime` Release scheme, then runs native
`xcodebuild -exportArchive` with manual signing, `destination=upload`, and
**`testFlightInternalTestingOnly=true`**. Apple documents that this flag prevents
external TestFlight and App Store distribution for the uploaded build. External
beta testing or an App Store release requires a separately reviewed pipeline and
explicit authorization; changing group settings cannot turn this artifact into
an App Store candidate.

A green upload means Xcode reported upload success, not that Apple has finished
processing or that a tester installed it. Inspect App Store Connect processing,
export-compliance status and the internal group's availability before announcing
it ready. Install through TestFlight on iPhone, then install the embedded Watch app.
Hardware microphone, WatchConnectivity and routing checks remain necessary.

If Apple accepted an upload but the runner lost the response, inspect App Store
Connect before retrying. A rerun uses a new attempt number and may create another
internal build. There is no automatic retry loop around upload.

To stop future releases, remove or set `TESTFLIGHT_UPLOAD_ENABLED=false`. Cancel an
in-progress job separately; it may already have uploaded. Removing a variable does
not revoke a build already in TestFlight. Stop testing that build in App Store Connect
as a separate authorized action. Roll back app code through a new reviewed commit
and a higher-numbered build, never by reusing/decreasing a build number.

Gateway deployment is entirely separate. This workflow neither reads gateway
production secrets nor changes Render/Fly/other hosting settings.

## Local checks without secrets

```sh
python3 -m unittest discover -s scripts/ci/tests -v
bash -n scripts/ci/apple-checks.sh
# actionlint v1.7.7, if installed:
actionlint
(cd gateway && npm ci && npm run typecheck && npm test)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/ci/apple-checks.sh
```

The Apple command runs Swift checks, unsigned iPhone/Watch simulator builds and an
unsigned Release archive, then checks its embedded products and version consistency.
It does not use signing accounts or upload. The release helpers have fixture tests
for filters, large diffs, build numbers, signing mappings, provisioning validation,
archive contents, stale commits, and secret/trigger guards. Real signing, Apple
API permissions, upload and internal-group distribution remain unverified until
separately authorized setup; this PR creates no real build in App Store Connect.

## Primary references

- [Apple distribution modes](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)
- [Apple build-version format](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleversion)
- Local Xcode 27.0 `xcodebuild -help`: `testFlightInternalTestingOnly`, `manageAppVersionAndBuildNumber`, `provisioningProfiles`, signing and authentication options.
- [GitHub environment protections](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)
- [GitHub rerun semantics](https://docs.github.com/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs)
- [Official Xcode 27 hosted image announcement](https://github.com/actions/runner-images/issues/14404)

Reviewed 2026-10-02. Hosted runner images, account permissions and Apple validation
requirements can change; verify them when enabling uploads.
