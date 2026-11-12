# Security and safety reporting

## Supported version

Security and safety fixes are applied to the current `main` branch; older
revisions are not maintained as supported releases.

## Reporting a vulnerability

Do not open a public issue for a vulnerability or a motor-safety failure that
could put users at immediate risk. Use GitHub's private vulnerability-reporting
feature for the repository. If that feature is unavailable, contact the
repository owner privately through the contact method shown on the owner's
GitHub profile.

Include:

- the affected revision and device/iOS version;
- clear reproduction steps;
- the potential impact;
- whether a motor controller was connected and motors were enabled;
- a minimal proof of concept, with personal recordings and identifiers removed;
- any mitigation you have already tested.

Please allow a reasonable period for investigation before public disclosure.
The project cannot promise a particular response time or a bounty.

## Immediate physical risk

If the mount moves unexpectedly, disable motor output and disconnect physical
power before troubleshooting. Do not reconnect the mechanism around people or
equipment until the fault is understood.
