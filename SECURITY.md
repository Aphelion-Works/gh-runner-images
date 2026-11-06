# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately through
[GitHub's private vulnerability reporting](https://github.com/Aphelion-Works/gh-runner-images/security/advisories/new),
not in a public issue.

Useful reports include:
- the image tag, or its digest
- what an attacker can do
- steps to reproduce

## What's in scope

- **The entrypoint**, especially anything that lets a job see the registration
  token, or that lets a job escape the runner user other than through the
  `sudo` access it's intentionally given.
- **The build:** how the runner, Docker Engine and tools are downloaded and
  checked.
- **The published images and their attestations.**

## What's out of scope

- **Ubuntu packages with known CVEs that Ubuntu hasn't fixed yet.** The images
  are rebuilt weekly with Ubuntu's latest packages. Fixable HIGH and CRITICAL
  findings are reported in this repo's code scanning alerts.
- **The privileges a single-use runner is given by design:** root through `sudo`
  inside its own container, and a privileged container for its Docker daemon.
  Runners are meant for trusted workflows only.
