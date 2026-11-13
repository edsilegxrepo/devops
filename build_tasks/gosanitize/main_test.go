package main

import (
	"bytes"
	"debug/buildinfo"
	"encoding/binary"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func buildSampleBinary(t *testing.T, targetOS, outName string) string {
	t.Helper()
	modDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(modDir, "go.mod"), []byte("module example.com/sample\n\ngo 1.21\n"), 0o644); err != nil {
		t.Fatalf("write go.mod: %v", err)
	}
	src := "package main\nimport \"fmt\"\nfunc main() { fmt.Println(\"ok-sample\") }\n"
	if err := os.WriteFile(filepath.Join(modDir, "main.go"), []byte(src), 0o644); err != nil {
		t.Fatalf("write main.go: %v", err)
	}

	outPath := filepath.Join(t.TempDir(), outName)
	cmd := exec.Command("go", "build", "-trimpath", "-buildmode=pie", "-buildvcs=false", "-ldflags=-s -w", "-o", outPath, ".")
	cmd.Dir = modDir
	cmd.Env = append(os.Environ(), "CGO_ENABLED=0", "GOOS="+targetOS, "GOARCH=amd64")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("go build (%s): %v\n%s", targetOS, err, string(out))
	}
	return outPath
}

func TestSanitizeWindowsPEBackupAndInplace(t *testing.T) {
	exePath := buildSampleBinary(t, "windows", "sample.exe")

	if _, err := buildinfo.ReadFile(exePath); err != nil {
		t.Fatalf("expected buildinfo before sanitize: %v", err)
	}

	origBytes, err := os.ReadFile(exePath)
	if err != nil {
		t.Fatalf("read original: %v", err)
	}

	// Default mode (inplace=false) creates <binary>.buildinfo backup
	changed, format, err := sanitizeFile(exePath, false)
	if err != nil {
		t.Fatalf("sanitizeFile(backup): %v", err)
	}
	if !changed || format != "PE" {
		t.Fatalf("got changed=%v format=%q, want true PE", changed, format)
	}

	if _, err := buildinfo.ReadFile(exePath); err == nil {
		t.Fatalf("expected buildinfo error after sanitize, got nil")
	}

	backupPath := exePath + ".buildinfo"
	backupBytes, err := os.ReadFile(backupPath)
	if err != nil {
		t.Fatalf("read backup: %v", err)
	}
	if !bytes.Equal(origBytes, backupBytes) {
		t.Fatalf("backup bytes do not match original binary")
	}

	// Re-running should be idempotent and NOT overwrite backup
	changed, _, err = sanitizeFile(exePath, false)
	if err != nil {
		t.Fatalf("sanitizeFile(idempotent): %v", err)
	}
	if changed {
		t.Fatalf("expected changed=false on already-stripped PE binary")
	}
	backupAfter, err := os.ReadFile(backupPath)
	if err != nil || !bytes.Equal(origBytes, backupAfter) {
		t.Fatalf("backup was unexpectedly modified on idempotent run")
	}

	if runtime.GOOS == "windows" {
		out, err := exec.Command(exePath).CombinedOutput()
		if err != nil || string(bytes.TrimSpace(out)) != "ok-sample" {
			t.Fatalf("sanitized windows binary failed to run: err=%v out=%q", err, string(out))
		}
	}

	// Test -inplace mode on a fresh binary (must not create .buildinfo backup)
	exeInplace := buildSampleBinary(t, "windows", "sample_inplace.exe")
	changed, format, err = sanitizeFile(exeInplace, true)
	if err != nil || !changed || format != "PE" {
		t.Fatalf("sanitizeFile(inplace): changed=%v format=%q err=%v", changed, format, err)
	}
	if _, err := os.Stat(exeInplace + ".buildinfo"); !os.IsNotExist(err) {
		t.Fatalf("expected no backup file in inplace mode")
	}
	if _, err := buildinfo.ReadFile(exeInplace); err == nil {
		t.Fatalf("expected buildinfo error after inplace sanitize")
	}
}

func TestSanitizeSelfWithRdataDecoyMagic(t *testing.T) {
	// Build gosanitize itself (which embeds buildInfoMagic as a literal in .rdata)
	// and verify sanitizing it strips .data buildinfo without breaking execution.
	selfBin := filepath.Join(t.TempDir(), "gosanitize_self.exe")
	cmd := exec.Command("go", "build", "-trimpath", "-buildmode=pie", "-buildvcs=false", "-ldflags=-s -w", "-o", selfBin, ".")
	cmd.Env = append(os.Environ(), "CGO_ENABLED=0", "GOOS=windows", "GOARCH=amd64")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("build self binary: %v\n%s", err, string(out))
	}

	if _, err := buildinfo.ReadFile(selfBin); err != nil {
		t.Fatalf("expected buildinfo before self-sanitize: %v", err)
	}
	changed, format, err := sanitizeFile(selfBin, true)
	if err != nil || !changed || format != "PE" {
		t.Fatalf("self-sanitize failed: changed=%v format=%q err=%v", changed, format, err)
	}
	if _, err := buildinfo.ReadFile(selfBin); err == nil {
		t.Fatalf("expected buildinfo removed after self-sanitize")
	}
	if runtime.GOOS == "windows" {
		out, err := exec.Command(selfBin, "-version").CombinedOutput()
		if err != nil || !strings.HasPrefix(string(out), "gosanitize ") {
			t.Fatalf("self-sanitized binary failed -version: err=%v out=%q", err, string(out))
		}
	}
}

func TestSanitizeLinuxELF(t *testing.T) {
	elfPath := buildSampleBinary(t, "linux", "sample_linux")

	if _, err := buildinfo.ReadFile(elfPath); err != nil {
		t.Fatalf("expected buildinfo before sanitize: %v", err)
	}

	changed, format, err := sanitizeFile(elfPath, true)
	if err != nil {
		t.Fatalf("sanitizeFile(ELF): %v", err)
	}
	if !changed || format != "ELF" {
		t.Fatalf("got changed=%v format=%q, want true ELF", changed, format)
	}

	if _, err := buildinfo.ReadFile(elfPath); err == nil {
		t.Fatalf("expected buildinfo error after ELF sanitize, got nil")
	}

	changed, _, err = sanitizeFile(elfPath, true)
	if err != nil {
		t.Fatalf("sanitizeFile(ELF idempotent): %v", err)
	}
	if changed {
		t.Fatalf("expected changed=false on already-stripped ELF binary")
	}

	if runtime.GOOS == "linux" {
		out, err := exec.Command(elfPath).CombinedOutput()
		if err != nil || string(bytes.TrimSpace(out)) != "ok-sample" {
			t.Fatalf("sanitized linux binary failed to run: err=%v out=%q", err, string(out))
		}
	}
}

func TestFindPEBuildInfoRangeIgnoresDecoys(t *testing.T) {
	// Place a decoy magic near the end of buffer (truncated) followed by valid inline header?
	// Construct: [16-byte aligned decoy with invalid flags] + [valid inline header]
	buf := make([]byte, 128)
	// Decoy at offset 16 with ptrSize=8, flags=0xff (invalid)
	copy(buf[16:], buildInfoMagic)
	buf[16+14] = 8
	buf[16+15] = 0xff

	// Valid inline buildinfo at offset 48
	copy(buf[48:], buildInfoMagic)
	buf[48+14] = 8
	buf[48+15] = buildInfoFlagInline
	pos := 48 + buildInfoHeaderSize
	buf[pos] = 3
	copy(buf[pos+1:], "1.2")
	pos += 4
	buf[pos] = 2
	copy(buf[pos+1:], "ok")
	pos += 3

	off, length, err := findPEBuildInfoRange(buf)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if off != 48 || length != pos-48 {
		t.Fatalf("got (%d, %d), want (48, %d)", off, length, pos-48)
	}
}

func TestScanPESectionAcrossChunkBoundary(t *testing.T) {
	// Place valid inline buildinfo straddling the 4 MiB chunk boundary to verify overlap scanning.
	const secStart = int64(512)
	const secSize = 5 * 1024 * 1024
	const targetRel = 4*1024*1024 - 16 // header crosses 4 MiB boundary (pointer-aligned by 8)

	data := make([]byte, secStart+secSize)
	absOff := int(secStart) + targetRel
	copy(data[absOff:], buildInfoMagic)
	data[absOff+14] = 8
	data[absOff+15] = buildInfoFlagInline
	pos := absOff + buildInfoHeaderSize
	data[pos] = 4
	copy(data[pos+1:], "1.27")
	pos += 5
	data[pos] = 3
	copy(data[pos+1:], "mod")
	pos += 4

	off, length, err := scanPESection(bytes.NewReader(data), secStart, secSize)
	if err != nil {
		t.Fatalf("scanPESection failed: %v", err)
	}
	if off != int64(absOff) || length != int64(pos-absOff) {
		t.Fatalf("got (%d, %d), want (%d, %d)", off, length, absOff, pos-absOff)
	}
}

func TestCLIRunAndMalformedInputs(t *testing.T) {
	var out, errBuf bytes.Buffer
	if code := run([]string{"-version"}, &out, &errBuf); code != 0 || !strings.Contains(out.String(), "gosanitize ") {
		t.Fatalf("-version got code=%d out=%q err=%q", code, out.String(), errBuf.String())
	}

	out.Reset()
	errBuf.Reset()
	if code := run([]string{"-help"}, &out, &errBuf); code != 0 || !strings.Contains(out.String(), "-remove-buildinfo") || errBuf.Len() != 0 {
		t.Fatalf("-help got code=%d out=%q err=%q", code, out.String(), errBuf.String())
	}

	out.Reset()
	errBuf.Reset()
	if code := run([]string{"-h"}, &out, &errBuf); code != 0 || !strings.Contains(out.String(), "-remove-buildinfo") || errBuf.Len() != 0 {
		t.Fatalf("-h got code=%d out=%q err=%q", code, out.String(), errBuf.String())
	}

	out.Reset()
	errBuf.Reset()
	if code := run(nil, &out, &errBuf); code != 2 {
		t.Fatalf("empty args got code=%d, want 2", code)
	}

	out.Reset()
	errBuf.Reset()
	if code := run([]string{"-remove-buildinfo"}, &out, &errBuf); code != 2 {
		t.Fatalf("missing target got code=%d, want 2", code)
	}

	out.Reset()
	errBuf.Reset()
	if code := run([]string{"-unknown-flag"}, &out, &errBuf); code != 2 {
		t.Fatalf("unknown flag got code=%d, want 2", code)
	}

	// Malformed ELF and PE headers should return error exit code 1
	tmp := t.TempDir()
	badELF := filepath.Join(tmp, "bad_elf")
	if err := os.WriteFile(badELF, []byte("\x7fELFcorrupt"), 0o644); err != nil {
		t.Fatalf("write badELF: %v", err)
	}
	badPE := filepath.Join(tmp, "bad_pe.exe")
	if err := os.WriteFile(badPE, []byte("MZcorrupt"), 0o644); err != nil {
		t.Fatalf("write badPE: %v", err)
	}
	plain := filepath.Join(tmp, "plain.txt")
	if err := os.WriteFile(plain, []byte("not a binary"), 0o644); err != nil {
		t.Fatalf("write plain: %v", err)
	}

	for _, p := range []string{badELF, badPE, plain} {
		out.Reset()
		errBuf.Reset()
		if code := run([]string{"-remove-buildinfo", "-inplace", p}, &out, &errBuf); code != 1 {
			t.Fatalf("run(%s) got code=%d, want 1 (err=%q)", p, code, errBuf.String())
		}
	}

	// Valid CLI run with backup
	exePath := buildSampleBinary(t, "windows", "cli_sample.exe")
	out.Reset()
	errBuf.Reset()
	if code := run([]string{"-remove-buildinfo", exePath}, &out, &errBuf); code != 0 {
		t.Fatalf("run(valid) got code=%d out=%q err=%q", code, out.String(), errBuf.String())
	}
	if _, err := os.Stat(exePath + ".buildinfo"); err != nil {
		t.Fatalf("expected backup after CLI run: %v", err)
	}
}

func TestRejectSymlink(t *testing.T) {
	target := buildSampleBinary(t, "windows", "real.exe")
	linkPath := filepath.Join(t.TempDir(), "link.exe")
	if err := os.Symlink(target, linkPath); err != nil {
		t.Skipf("symlinks unavailable in this environment: %v", err)
	}

	if _, _, err := sanitizeFile(linkPath, true); err == nil || !strings.Contains(err.Error(), "symlink") {
		t.Fatalf("expected symlink rejection error, got: %v", err)
	}
}

func TestRejectSignedPE(t *testing.T) {
	exePath := buildSampleBinary(t, "windows", "signed.exe")
	b, err := os.ReadFile(exePath)
	if err != nil {
		t.Fatalf("read sample: %v", err)
	}

	// Patch IMAGE_DIRECTORY_ENTRY_SECURITY (index 4 in OptionalHeader64 DataDirectory)
	peOff := int(binary.LittleEndian.Uint32(b[0x3c:0x40]))
	secDirOff := peOff + 4 + 20 + 112 + 4*8
	binary.LittleEndian.PutUint32(b[secDirOff:secDirOff+4], uint32(len(b)))
	binary.LittleEndian.PutUint32(b[secDirOff+4:secDirOff+8], 128)
	b = append(b, make([]byte, 128)...)
	if err := os.WriteFile(exePath, b, 0o644); err != nil {
		t.Fatalf("write signed sample: %v", err)
	}

	if _, _, err := sanitizeFile(exePath, true); err == nil || !strings.Contains(err.Error(), "Authenticode") {
		t.Fatalf("expected Authenticode rejection error, got: %v", err)
	}
}
