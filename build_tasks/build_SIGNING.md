# SSH Code Signing & Verification Guide

This guide details how to generate, configure, and use SSH-based signatures for software release artifacts in the build toolchain, as well as how downstream consumers and CI/CD pipelines verify them.

---

## 1. Why SSH Code Signing?

Modern software distribution increasingly favors **SSH Ed25519 signatures** (`ssh-keygen -Y`) over legacy PGP/GPG:

| Feature | 🔑 SSH Signatures (`ssh-keygen -Y`) | 📜 PGP / GPG |
| :--- | :--- | :--- |
| **Tooling Prerequisite** | **Zero** — Built into 100% of Linux, macOS, and Windows 10/11 | Requires `gnupg`, `gpg-agent`, `pinentry` |
| **Cryptography** | Modern Ed25519 (fast, constant-time, side-channel proof) | Often legacy RSA / complex subkeys |
| **Forge Integration** | Native on **GitHub, Gitea, Forgejo, GitLab** | Native, but complex web-of-trust setup |
| **Public Key Discovery** | Instant via `https://github.com/<user>.keys` | Keyservers (frequently offline or poisoned) |
| **CI / Headless Automation** | Seamless file or environment variable; zero daemons | Requires TTY hacks, daemon loops, passphrase pins |

---

## 2. The Release Artifact Triad

When release packaging and signing are enabled, the build system produces three dedicated, parallel-safe files for every release target in `../distrib/`:

```text
../distrib/
├── checkcert-0.2.1-linux_amd64.tar.xz          <- 1. The release payload
├── checkcert-0.2.1-linux_amd64.tar.xz.sha256   <- 2. Standalone SHA-256 checksum
└── checkcert-0.2.1-linux_amd64.tar.xz.sig      <- 3. Armored SSH cryptographic signature
```

Downstream consumers can:
1. **Verify Integrity & Authenticity in 1 Step**: Verify the `.sig` directly against the `.tar.xz` using `ssh-keygen`.
2. **Verify Checksum**: Fast hash validation with `sha256sum -c` in scripts that don't need signature verification.

---

## 3. Step 1: Generating the Signing Key

You can generate a dedicated Ed25519 signing key pair using the build toolchain or standard OpenSSH.

### Option A: Using the Build Toolchain (Recommended)
From the repository root, run:

```bash
./build_orchestrate.sh --generate-key --identity=mis@criticalsys.net
```
*(Or specify a custom comment: `./build_orchestrate.sh --generate-key --identity=mis@criticalsys.net --comment="Critical Systems Release Signing <mis@criticalsys.net>"`)*
*(Or specify a custom path: `./build_orchestrate.sh --generate-key=~/.ssh/signing/release_key --identity=mis@criticalsys.net`)*

> [!IMPORTANT]
> The `--identity=<email-or-id>` flag is **mandatory** when generating a signing key. It defines your cryptographic principal in `allowed_signers`. By default, a human-readable comment (`Critical Systems Release Signing <<identity>>`) is automatically embedded in the public key, which can also be customized via `--comment="<text>"`.

**Output:**
```text
>> Generating Ed25519 SSH signing key pair at '/home/user/.ssh/signing/release_key'...
   Identity : mis@criticalsys.net
   Comment  : Critical Systems Release Signing <mis@criticalsys.net>
================================================================================
   [OK] SSH Signing Key Pair Created Successfully!
  Identity    : mis@criticalsys.net
  Comment     : Critical Systems Release Signing <mis@criticalsys.net>
  Private Key : /home/user/.ssh/signing/release_key
  Public Key  : /home/user/.ssh/signing/release_key.pub
--------------------------------------------------------------------------------
To configure signature verification, create an 'allowed_signers' file with:
  mis@criticalsys.net namespaces="file" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... Critical Systems Release Signing <mis@criticalsys.net>

To sign builds with this key, pass:
  --sign
================================================================================
```

### Option B: Using `ssh-keygen` Directly
```bash
mkdir -p ~/.ssh/signing
chmod 700 ~/.ssh/signing
ssh-keygen -t ed25519 -N "" -C "Critical Systems Release Signing <mis@criticalsys.net>" -f ~/.ssh/signing/release_key
chmod 600 ~/.ssh/signing/release_key
chmod 644 ~/.ssh/signing/release_key.pub
```

> [!NOTE]
> **Why `~/.ssh/signing/`?**
> Placing your release signing key in a dedicated subdirectory (`~/.ssh/signing/`) with `chmod 700` isolates it from default SSH authentication. OpenSSH client and `ssh-agent` only search `~/.ssh/` for identity files (`id_*`), ensuring this key is never offered during remote server logins (averting "Too many authentication failures").

> [!TIP]
> The private key is unencrypted (`-N ""`) for non-interactive CI/CD automation. For high-security environments, store the private key in a protected CI secret, or use a hardware security key (`-t ed25519-sk`).

---

## 4. Step 2: Building & Signing Release Artifacts

### Parallel Multi-Module Build with Signing
To compile, package, and sign all 20 modules simultaneously using the default key (`~/.ssh/signing/release_key`):

```bash
./build_orchestrate.sh --exec --parallel --jobs=4 --linux --all --sign
```
*(Or with an explicit path: `./build_orchestrate.sh --exec --parallel --jobs=4 --linux --all --sign=~/.ssh/signing/release_key`)*

### Individual Sub-Project Build with Signing
To build and sign a single project:

```bash
cd private/<module_name>
../../build_go.sh --linux --all --sign
```

### Key Path Resolution
- `--sign` without arguments automatically uses `~/.ssh/signing/release_key`.
- Passing a directory path like `--sign=~/.ssh/signing` automatically resolves to `~/.ssh/signing/release_key`.
- You can pass any custom key file with `--sign=/path/to/custom_key`.

---

## 5. Step 3: Distributing Your Public Key (Public Trust)

Consumers need your **public key** (`.pub`) to verify signatures. You have three standard distribution methods:

### Method A: GitHub / Gitea / Forgejo Profile (.keys endpoint) — *Recommended*

Adding your signing key to your forge profile allows anyone to fetch and trust your public key instantly.

#### Using GitHub CLI (`gh`) — *Fastest*
You can upload the public key directly from your terminal using the official GitHub CLI:

```bash
# Upload public key as a signing key
gh ssh-key add ~/.ssh/signing/release_key.pub --type signing --title "Release Signing Key"

# Verify that the key is registered
gh ssh-key list
```

#### Using the GitHub Web UI
1. Open your profile on **GitHub** (or Gitea/Forgejo):
   - Go to **Settings** → **SSH and GPG keys** → **New SSH Key**.
   - **Key type**: Select **Signing Key** (do not select Authentication Key).
   - **Key**: Paste the content of `~/.ssh/signing/release_key.pub`.
   - Click **Add SSH Key**.

#### The Public Discovery URL
Once added, GitHub automatically exposes your signing keys at:
```text
https://github.com/<your-username>.keys
```
*(On Gitea/Forgejo: `https://<forge-host>/<your-username>.keys`)*

---

### Method B: In-Repository `allowed_signers` File
You can commit an `allowed_signers` file directly into your repository (e.g. `.github/allowed_signers` or `docs/allowed_signers`):

```text
# allowed_signers format: <identity> <namespaces> <public-key>
mis@criticalsys.net namespaces="file" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... mis@criticalsys.net
```

---

### Method C: Release Page Asset
Attach `release_key.pub` directly to the GitHub/Gitea Release along with the `.tar.xz`, `.deb`, and `.rpm` files.

---

## 6. Step 4: Consumer Verification Guide

Consumers can verify releases using standard OpenSSH built into their operating system.

### Scenario 1: One-Step Verification via GitHub Identity

Consumers can fetch your public key directly from GitHub and verify against your identity in one command:

```bash
# 1. Download release assets
curl -LO https://github.com/<org>/<repo>/releases/download/v1.0.0/checkcert-0.2.1-linux_amd64.tar.xz
curl -LO https://github.com/<org>/<repo>/releases/download/v1.0.0/checkcert-0.2.1-linux_amd64.tar.xz.sig

# 2. Fetch the publisher's public key from GitHub into allowed_signers bound to mis@criticalsys.net
curl -s https://github.com/<your-username>.keys | awk '{print "mis@criticalsys.net namespaces=\"file\" " $0}' > allowed_signers

# 3. Verify the release archive signature specifically asserting the identity
ssh-keygen -Y verify -f allowed_signers -I mis@criticalsys.net -n file \
  -s checkcert-0.2.1-linux_amd64.tar.xz.sig \
  < checkcert-0.2.1-linux_amd64.tar.xz
```

**Expected Successful Output:**
```text
Good "file" signature for mis@criticalsys.net with ED25519 key SHA256:xoaftA6QGyqSJuABGRcDYJBlYrAzYDdjt3ryxZY6abY
```

---

### Scenario 2: Verification using a Local Public Key File

If the user downloaded `release_key.pub`:

```bash
# 1. Populate allowed_signers binding the key to the publisher identity
echo "mis@criticalsys.net namespaces=\"file\" $(cat release_key.pub)" > allowed_signers

# 2. Verify signature directly on the archive asserting the identity
ssh-keygen -Y verify -f allowed_signers -I mis@criticalsys.net -n file \
  -s checkcert-0.2.1-linux_amd64.tar.xz.sig \
  < checkcert-0.2.1-linux_amd64.tar.xz
```

---

### Scenario 3: Checksum Validation (No SSH Keys Needed)

If a user or automated Dockerfile only requires hash validation:

```bash
sha256sum -c checkcert-0.2.1-linux_amd64.tar.xz.sha256
```

---

## 7. CI/CD Automation (GitHub Actions / Forgejo Runner)

To automate signed releases in GitHub Actions:

### 1. Store the Private Key in Secrets
1. Go to repository **Settings** → **Secrets and variables** → **Actions**.
2. Create a repository secret named `RELEASE_SIGNING_KEY`.
3. Paste the entire content of `release_key`.

### 2. GitHub Actions Workflow Step
```yaml
name: Release

on:
  push:
    tags:
      - 'v*'

jobs:
  build-and-sign:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up Go
        uses: actions/setup-go@v5
        with:
          go-version: '1.24'

      - name: Install Packaging Tools
        run: |
          sudo apt-get update
          sudo apt-get install -y rpm dpkg-dev xz-utils zip

      - name: Setup Signing Key
        run: |
          mkdir -p ~/.ssh/signing
          chmod 700 ~/.ssh/signing
          echo "${{ secrets.RELEASE_SIGNING_KEY }}" > ~/.ssh/signing/release_key
          chmod 600 ~/.ssh/signing/release_key

      - name: Build and Sign All Modules
        run: |
          ./build_orchestrate.sh --exec --parallel --jobs=4 --linux --all --sign

      - name: Publish Release Assets
        uses: softprops/action-gh-release@v2
        with:
          files: ../distrib/*
```

---

## 8. Security Best Practices

1. **Keep Private Keys Out of Version Control**:
   `SOURCE_EXCLUDES` in [`build_go.sh`](build_go.sh) strictly excludes `*.key`, `*.pem`, `*.token`, and `.env*` files to ensure signing keys are never bundled into `-src.tar.xz` or `-src.zip`.
2. **Key Rotation**:
   To rotate your signing key, run `./build_orchestrate.sh --generate-key=<new_key_path> --identity=mis@criticalsys.net`, upload the new public key to your forge profile, and keep the old public key in your `allowed_signers` file with appropriate date/version annotations.
3. **Namespace Isolation**:
   The `-n file` flag enforces that this SSH key is only recognized for signing file payloads, preventing signature cross-protocol re-use (e.g. Git commit signatures or SSH login handshakes).
4. **SSH Client & Agent Isolation**:
   Always store signing keys inside `~/.ssh/signing/` rather than the `~/.ssh/` root directory. This ensures that SSH authentication agents (`ssh-agent`) and client connections never load or offer the signing key for network logins, preventing authentication noise or account lockout risks.
5. **Identity & Principal Binding**:
   Always specify explicit identity principals (e.g. `mis@criticalsys.net`) in `allowed_signers` and `-I <identity>` checks rather than wildcard `*`. This cryptographically asserts the exact publisher identity and rejects keys signed by unapproved identities.
