# Publishing this prepared tree

Commit the contents of this directory as the repository root. Do not commit its
sibling `github-releases` directory: those archives are GitHub Release assets,
not source files. Publish release assets separately from the source commit.

1. Run `python3 scripts/audit-public-export.py .` before adding source files.
2. Build the desired packages using the commands in README.md.
3. Run the scanner on the release directory and verify each `.sha256` file.
4. Create a version tag and GitHub Release in your repository, then upload the
   archives and matching checksum files. Copy the prepared release notes and
   state the platform test limits.

Desktop executable payloads are unchanged. The native Linux desktop archive was repackaged to replace an absolute Qt license symlink with actual license files; its checksums were regenerated. The other two desktop archives are unchanged copies of the tested packages. The supplied
legacy server archives were repackaged to remove the operator VPN profile,
replace the TOML with the public default (`autostart = false`), and regenerate
all checksums. Their executable payloads were not rebuilt during export.

The credential scanner checks archive contents, not just compressed bytes.
The source-only fixture allowlist pins hashes of public upstream TLS test keys
and the upstream network-test fixtures. These are published test fixtures, not
operator credentials; none are included in runtime archives. Removing or
changing a fixture requires reviewing and updating its allowlist entry.

Keep your own local secrets outside this tree or in ignored local files.
The public server packager never copies an operator VPN profile into a release.
