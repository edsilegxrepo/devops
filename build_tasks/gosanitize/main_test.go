package main

import (
	"bytes"
	"debug/buildinfo"
	"debug/elf"
	"encoding/binary"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func buildSampleBinary(t *testing.T, targetOS, outName string) string {
	t.Helper()
	return buildSampleWithMode(t, targetOS, "pie", outName)
}

func buildSampleWithMode(t *testing.T, targetOS, buildMode, outName string) string {
	t.Helper()
	return buildSampleCustom(t, targetOS, "amd64", buildMode, "-s -w", outName)
}

func buildSampleCustom(t *testing.T, targetOS, targetArch, buildMode, ldflags, outName string) string {
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
	args := []string{"build", "-trimpath", "-buildmode=" + buildMode, "-buildvcs=false"}
	if ldflags != "" {
		args = append(args, "-ldflags="+ldflags)
	}
	args = append(args, "-o", outPath, ".")
	cmd := exec.Command("go", args...)
	cmd.Dir = modDir
	cmd.Env = append(os.Environ(), "CGO_ENABLED=0", "GOOS="+targetOS, "GOARCH="+targetArch)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("go build (%s/%s/%s): %v\n%s", targetOS, targetArch, buildMode, err, string(out))
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

func TestMultiTargetPreflightNoMutation(t *testing.T) {
	validExe := buildSampleBinary(t, "windows", "preflight_valid.exe")
	origBytes, err := os.ReadFile(validExe)
	if err != nil {
		t.Fatalf("read original binary: %v", err)
	}

	tmp := t.TempDir()
	missing := filepath.Join(tmp, "does_not_exist.exe")
	for _, badTarget := range []string{missing, tmp} {
		var out, errBuf bytes.Buffer
		if code := run([]string{"-remove-buildinfo", validExe, badTarget}, &out, &errBuf); code != 1 {
			t.Fatalf("expected exit code 1 when trailing target %q invalid, got %d (out=%q err=%q)", badTarget, code, out.String(), errBuf.String())
		}
		if out.Len() != 0 {
			t.Fatalf("expected empty stdout on preflight failure, got %q", out.String())
		}
		if _, statErr := os.Stat(validExe + ".buildinfo"); !os.IsNotExist(statErr) {
			t.Fatalf("expected no backup written when preflight failed on %q", badTarget)
		}
		afterBytes, readErr := os.ReadFile(validExe)
		if readErr != nil || !bytes.Equal(origBytes, afterBytes) {
			t.Fatalf("valid binary was mutated despite preflight failure on %q (readErr=%v)", badTarget, readErr)
		}
		if _, biErr := buildinfo.ReadFile(validExe); biErr != nil {
			t.Fatalf("expected buildinfo intact after preflight failure: %v", biErr)
		}
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

// buildSampleWithMode now delegates to buildSampleCustom above.

func TestDiagLinuxStaticAndDynamicPIE(t *testing.T) {
	exeBin := buildSampleWithMode(t, "linux", "exe", "sample_exe")
	pieBin := buildSampleWithMode(t, "linux", "pie", "sample_pie")

	dExe, err := inspectBinary(exeBin)
	if err != nil {
		t.Fatalf("inspectBinary(exe): %v", err)
	}
	if dExe.Format != "ELF" || dExe.Class != "ELF64" || dExe.Arch != "x86_64" {
		t.Fatalf("unexpected ELF metadata: %+v", dExe)
	}
	if dExe.Linkage != "static" || !dExe.Static || dExe.PIE || dExe.StaticPIE {
		t.Fatalf("expected static non-PIE ELF, got linkage=%q static=%v pie=%v static_pie=%v", dExe.Linkage, dExe.Static, dExe.PIE, dExe.StaticPIE)
	}
	if !dExe.Stripped || dExe.Go == nil || dExe.Go.BuildInfo != "present" || dExe.Go.BuildMode != "exe" {
		t.Fatalf("unexpected stripped/Go state for static exe: stripped=%v go=%+v", dExe.Stripped, dExe.Go)
	}

	dPie, err := inspectBinary(pieBin)
	if err != nil {
		t.Fatalf("inspectBinary(pie): %v", err)
	}
	if dPie.Linkage != "dynamic-pie" || dPie.Static || !dPie.PIE || dPie.StaticPIE || dPie.Interpreter == "" {
		t.Fatalf("expected dynamic-pie ELF with PT_INTERP, got %+v", dPie)
	}
	if dPie.Go == nil || dPie.Go.BuildMode != "pie" || dPie.Go.Trimpath == nil || !*dPie.Go.Trimpath {
		t.Fatalf("unexpected Go metadata for PIE binary: %+v", dPie.Go)
	}

	// Sanitize and inspect in one CLI invocation with JSON output
	var out, errBuf bytes.Buffer
	if code := run([]string{"-remove-buildinfo", "-inplace", "-diag", "-json", pieBin}, &out, &errBuf); code != 0 {
		t.Fatalf("combined sanitize+diag failed: code=%d err=%q", code, errBuf.String())
	}
	var parsed []BinaryDiag
	if err := json.Unmarshal(out.Bytes(), &parsed); err != nil || len(parsed) != 1 {
		t.Fatalf("unmarshal single -diag -json output: err=%v len=%d\n%s", err, len(parsed), out.String())
	}
	if parsed[0].Go == nil || !parsed[0].Go.Detected || parsed[0].Go.BuildInfo != "stripped" {
		t.Fatalf("expected post-sanitize Go buildinfo=stripped, got %+v", parsed[0].Go)
	}
	if parsed[0].SHA256 == dPie.SHA256 {
		t.Fatalf("expected SHA256 to change after buildinfo removal")
	}
}

func writeSyntheticELF64(t *testing.T, elfType elf.Type, entry uint64, withInterp, withRelro, withBindNow, withPieFlag, execStack, withSoname bool) string {
	t.Helper()
	const (
		ehdrSize = 64
		phdrSize = 56
	)
	var phdrs []elf.Prog64
	payloadOff := uint64(ehdrSize)

	numPhdrs := 1 // PT_LOAD
	if withInterp {
		numPhdrs++
	}
	if withRelro {
		numPhdrs++
	}
	needDyn := withBindNow || withPieFlag || withSoname
	if needDyn {
		numPhdrs++
	}
	if execStack {
		numPhdrs++
	}
	payloadOff += uint64(numPhdrs * phdrSize)

	var body []byte
	interpOff := payloadOff
	if withInterp {
		s := "/lib64/ld-linux-x86-64.so.2\x00"
		body = append(body, s...)
		phdrs = append(phdrs, elf.Prog64{
			Type:   uint32(elf.PT_INTERP),
			Flags:  uint32(elf.PF_R),
			Off:    interpOff,
			Vaddr:  0x400000 + interpOff,
			Paddr:  0x400000 + interpOff,
			Filesz: uint64(len(s)),
			Memsz:  uint64(len(s)),
			Align:  1,
		})
	}

	if needDyn {
		for len(body)%8 != 0 {
			body = append(body, 0)
		}
		dynstrOff := payloadOff + uint64(len(body))
		dynstr := []byte("\x00libdemo.so.1\x00")
		dynstrSize := uint64(len(dynstr))
		body = append(body, dynstr...)

		for len(body)%8 != 0 {
			body = append(body, 0)
		}
		dynOff := payloadOff + uint64(len(body))
		addDyn := func(tag int64, val uint64) {
			var ent [16]byte
			binary.LittleEndian.PutUint64(ent[0:8], uint64(tag))
			binary.LittleEndian.PutUint64(ent[8:16], val)
			body = append(body, ent[:]...)
		}
		addDyn(int64(elf.DT_STRTAB), 0x400000+dynstrOff)
		addDyn(int64(elf.DT_STRSZ), dynstrSize)
		if withSoname {
			addDyn(int64(elf.DT_SONAME), 1)
		}
		if withBindNow {
			addDyn(int64(elf.DT_BIND_NOW), 0)
		}
		if withPieFlag {
			addDyn(int64(elf.DT_FLAGS_1), elfFlag1PIE)
		}
		addDyn(int64(elf.DT_NULL), 0)
		dynSize := payloadOff + uint64(len(body)) - dynOff
		phdrs = append(phdrs, elf.Prog64{
			Type:   uint32(elf.PT_DYNAMIC),
			Flags:  uint32(elf.PF_R | elf.PF_W),
			Off:    dynOff,
			Vaddr:  0x400000 + dynOff,
			Paddr:  0x400000 + dynOff,
			Filesz: dynSize,
			Memsz:  dynSize,
			Align:  8,
		})
	}

	if withRelro {
		phdrs = append(phdrs, elf.Prog64{
			Type:   uint32(elf.PT_GNU_RELRO),
			Flags:  uint32(elf.PF_R),
			Off:    0,
			Vaddr:  0x400000,
			Paddr:  0x400000,
			Filesz: 64,
			Memsz:  64,
			Align:  1,
		})
	}
	if execStack {
		phdrs = append(phdrs, elf.Prog64{
			Type:  uint32(elf.PT_GNU_STACK),
			Flags: uint32(elf.PF_R | elf.PF_W | elf.PF_X),
			Align: 16,
		})
	}

	totalSize := payloadOff + uint64(len(body))
	loadPhdr := elf.Prog64{
		Type:   uint32(elf.PT_LOAD),
		Flags:  uint32(elf.PF_R | elf.PF_X),
		Off:    0,
		Vaddr:  0x400000,
		Paddr:  0x400000,
		Filesz: totalSize,
		Memsz:  totalSize,
		Align:  0x1000,
	}
	phdrs = append([]elf.Prog64{loadPhdr}, phdrs...)

	ehdr := elf.Header64{
		Ident:     [elf.EI_NIDENT]byte{0x7f, 'E', 'L', 'F', byte(elf.ELFCLASS64), byte(elf.ELFDATA2LSB), byte(elf.EV_CURRENT)},
		Type:      uint16(elfType),
		Machine:   uint16(elf.EM_X86_64),
		Version:   uint32(elf.EV_CURRENT),
		Entry:     entry,
		Phoff:     ehdrSize,
		Ehsize:    ehdrSize,
		Phentsize: phdrSize,
		Phnum:     uint16(len(phdrs)),
	}

	var buf bytes.Buffer
	_ = binary.Write(&buf, binary.LittleEndian, &ehdr)
	for _, ph := range phdrs {
		_ = binary.Write(&buf, binary.LittleEndian, &ph)
	}
	buf.Write(body)

	out := filepath.Join(t.TempDir(), "synth_elf")
	if err := os.WriteFile(out, buf.Bytes(), 0o755); err != nil {
		t.Fatalf("write synthetic ELF: %v", err)
	}
	return out
}

func TestDiagSyntheticELFVariants(t *testing.T) {
	staticPie := writeSyntheticELF64(t, elf.ET_DYN, 0x1234, false, true, true, true, true, false)
	dStaticPie, err := inspectBinary(staticPie)
	if err != nil {
		t.Fatalf("inspectBinary(static-pie): %v", err)
	}
	if dStaticPie.Linkage != "static-pie" || !dStaticPie.Static || !dStaticPie.PIE || !dStaticPie.StaticPIE {
		t.Fatalf("expected static-pie, got %+v", dStaticPie)
	}
	if dStaticPie.RELRO != "full" || dStaticPie.NX == nil || *dStaticPie.NX {
		t.Fatalf("expected RELRO=full and NX=false, got relro=%q nx=%v", dStaticPie.RELRO, dStaticPie.NX)
	}

	dynExec := writeSyntheticELF64(t, elf.ET_EXEC, 0x1000, true, false, false, false, false, false)
	dDyn, err := inspectBinary(dynExec)
	if err != nil {
		t.Fatalf("inspectBinary(dynamic): %v", err)
	}
	if dDyn.Linkage != "dynamic" || dDyn.Static || dDyn.PIE || dDyn.RELRO != "none" {
		t.Fatalf("expected non-PIE dynamic with RELRO=none, got %+v", dDyn)
	}

	sharedObj := writeSyntheticELF64(t, elf.ET_DYN, 0, false, true, false, false, false, true)
	dSo, err := inspectBinary(sharedObj)
	if err != nil {
		t.Fatalf("inspectBinary(shared-object): %v", err)
	}
	if dSo.Linkage != "shared-object" || dSo.Static || dSo.PIE || dSo.RELRO != "partial" {
		t.Fatalf("expected shared-object with RELRO=partial, got %+v", dSo)
	}

	// Append DT_NEEDED in sectionless ELF path (via writeSyntheticELF64 extension? tested in TestDiagSectionlessELFNeededLibs).
	if relObj := writeSyntheticELF64(t, elf.ET_REL, 0, false, false, false, false, false, false); relObj != "" {
		dRel, err := inspectBinary(relObj)
		if err != nil {
			t.Fatalf("inspectBinary(relocatable): %v", err)
		}
		if dRel.Linkage != "relocatable" || dRel.Static || dRel.PIE || dRel.StaticPIE {
			t.Fatalf("expected relocatable ELF, got %+v", dRel)
		}
	}
}

func TestDiagSectionlessELFNeededLibs(t *testing.T) {
	// Section-header-stripped ELF (Shnum=0) with PT_LOAD + PT_INTERP + PT_DYNAMIC(DT_NEEDED, DT_STRTAB)
	const (
		ehdrSize = 64
		phdrSize = 56
		numPhdrs = 3 // PT_LOAD, PT_INTERP, PT_DYNAMIC
	)
	payloadOff := uint64(ehdrSize + numPhdrs*phdrSize)
	interpStr := []byte("/lib64/ld-linux-x86-64.so.2\x00")
	dynstr := []byte("\x00libcustom.so.1\x00libm.so.6\x00")

	interpOff := payloadOff
	dynstrOff := interpOff + uint64(len(interpStr))
	for dynstrOff%8 != 0 {
		dynstrOff++
	}
	dynOff := dynstrOff + uint64(len(dynstr))
	for dynOff%8 != 0 {
		dynOff++
	}

	var dynBuf bytes.Buffer
	addDyn := func(tag int64, val uint64) {
		_ = binary.Write(&dynBuf, binary.LittleEndian, tag)
		_ = binary.Write(&dynBuf, binary.LittleEndian, val)
	}
	addDyn(int64(elf.DT_STRTAB), 0x400000+dynstrOff)
	addDyn(int64(elf.DT_STRSZ), uint64(len(dynstr)))
	addDyn(int64(elf.DT_NEEDED), 1)
	addDyn(int64(elf.DT_NEEDED), 16)
	addDyn(int64(elf.DT_NULL), 0)

	totalSize := dynOff + uint64(dynBuf.Len())
	ehdr := elf.Header64{
		Ident:     [elf.EI_NIDENT]byte{0x7f, 'E', 'L', 'F', byte(elf.ELFCLASS64), byte(elf.ELFDATA2LSB), byte(elf.EV_CURRENT)},
		Type:      uint16(elf.ET_DYN),
		Machine:   uint16(elf.EM_X86_64),
		Version:   uint32(elf.EV_CURRENT),
		Entry:     0x401000,
		Phoff:     ehdrSize,
		Ehsize:    ehdrSize,
		Phentsize: phdrSize,
		Phnum:     numPhdrs,
	}
	phdrs := []elf.Prog64{
		{Type: uint32(elf.PT_LOAD), Flags: uint32(elf.PF_R | elf.PF_X), Off: 0, Vaddr: 0x400000, Paddr: 0x400000, Filesz: totalSize, Memsz: totalSize, Align: 0x1000},
		{Type: uint32(elf.PT_INTERP), Flags: uint32(elf.PF_R), Off: interpOff, Vaddr: 0x400000 + interpOff, Paddr: 0x400000 + interpOff, Filesz: uint64(len(interpStr)), Memsz: uint64(len(interpStr)), Align: 1},
		{Type: uint32(elf.PT_DYNAMIC), Flags: uint32(elf.PF_R | elf.PF_W), Off: dynOff, Vaddr: 0x400000 + dynOff, Paddr: 0x400000 + dynOff, Filesz: uint64(dynBuf.Len()), Memsz: uint64(dynBuf.Len()), Align: 8},
	}

	buf := make([]byte, totalSize)
	var hdr bytes.Buffer
	_ = binary.Write(&hdr, binary.LittleEndian, &ehdr)
	for _, ph := range phdrs {
		_ = binary.Write(&hdr, binary.LittleEndian, &ph)
	}
	copy(buf[0:], hdr.Bytes())
	copy(buf[interpOff:], interpStr)
	copy(buf[dynstrOff:], dynstr)
	copy(buf[dynOff:], dynBuf.Bytes())

	p := filepath.Join(t.TempDir(), "sectionless_elf")
	if err := os.WriteFile(p, buf, 0o755); err != nil {
		t.Fatalf("write sectionless_elf: %v", err)
	}
	d, err := inspectBinary(p)
	if err != nil {
		t.Fatalf("inspectBinary(sectionless_elf): %v", err)
	}
	if d.Linkage != "dynamic-pie" || len(d.NeededLibs) != 2 || d.NeededLibs[0] != "libcustom.so.1" || d.NeededLibs[1] != "libm.so.6" {
		t.Fatalf("expected DT_NEEDED parsed via PT_DYNAMIC, got %+v", d)
	}
}

func TestDiagELFDynamicSectionsAndNeededLibs(t *testing.T) {
	// Construct an ELF64 with SHT_DYNAMIC, SHT_STRTAB (.dynstr), and .shstrtab so ef.ImportedLibraries() runs.
	const (
		ehdrSize = 64
		phdrSize = 56
		shdrSize = 64
		numPhdrs = 3 // PT_LOAD, PT_INTERP, PT_GNU_RELRO
		numShdrs = 4 // NULL, .shstrtab, .dynstr, .dynamic
	)
	shstrtab := []byte("\x00.shstrtab\x00.dynstr\x00.dynamic\x00")
	// Offsets inside shstrtab: ".shstrtab"=1, ".dynstr"=11, ".dynamic"=19
	dynstr := []byte("\x00libc.so.6\x00libz.so.1\x00")
	// Offsets inside dynstr: "libc.so.6"=1, "libz.so.1"=11

	interpStr := []byte("/lib64/ld-linux-x86-64.so.2\x00")
	interpOff := uint64(ehdrSize + numPhdrs*phdrSize)
	shstrOff := interpOff + uint64(len(interpStr))
	dynstrOff := shstrOff + uint64(len(shstrtab))
	for dynstrOff%8 != 0 {
		dynstrOff++
	}
	dynOff := dynstrOff + uint64(len(dynstr))
	for dynOff%8 != 0 {
		dynOff++
	}

	var dynBuf bytes.Buffer
	addDyn := func(tag int64, val uint64) {
		_ = binary.Write(&dynBuf, binary.LittleEndian, tag)
		_ = binary.Write(&dynBuf, binary.LittleEndian, val)
	}
	addDyn(int64(elf.DT_NEEDED), 1)
	addDyn(int64(elf.DT_NEEDED), 11)
	addDyn(int64(elf.DT_FLAGS), uint64(elf.DF_BIND_NOW))
	addDyn(int64(elf.DT_FLAGS_1), uint64(elf.DF_1_NOW))
	addDyn(int64(elf.DT_NULL), 0)

	shoff := dynOff + uint64(dynBuf.Len())
	for shoff%8 != 0 {
		shoff++
	}

	ehdr := elf.Header64{
		Ident:     [elf.EI_NIDENT]byte{0x7f, 'E', 'L', 'F', byte(elf.ELFCLASS64), byte(elf.ELFDATA2LSB), byte(elf.EV_CURRENT)},
		Type:      uint16(elf.ET_DYN),
		Machine:   uint16(elf.EM_X86_64),
		Version:   uint32(elf.EV_CURRENT),
		Entry:     0x1040,
		Phoff:     ehdrSize,
		Shoff:     shoff,
		Ehsize:    ehdrSize,
		Phentsize: phdrSize,
		Phnum:     numPhdrs,
		Shentsize: shdrSize,
		Shnum:     numShdrs,
		Shstrndx:  1,
	}
	phdrs := []elf.Prog64{
		{Type: uint32(elf.PT_LOAD), Flags: uint32(elf.PF_R | elf.PF_X), Filesz: shoff, Memsz: shoff, Align: 0x1000},
		{Type: uint32(elf.PT_INTERP), Flags: uint32(elf.PF_R), Off: interpOff, Vaddr: interpOff, Paddr: interpOff, Filesz: uint64(len(interpStr)), Memsz: uint64(len(interpStr)), Align: 1},
		{Type: uint32(elf.PT_GNU_RELRO), Flags: uint32(elf.PF_R), Filesz: 64, Memsz: 64, Align: 1},
	}
	shdrs := []elf.Section64{
		{},
		{Name: 1, Type: uint32(elf.SHT_STRTAB), Off: shstrOff, Size: uint64(len(shstrtab)), Addralign: 1},
		{Name: 11, Type: uint32(elf.SHT_STRTAB), Flags: uint64(elf.SHF_ALLOC), Addr: dynstrOff, Off: dynstrOff, Size: uint64(len(dynstr)), Addralign: 1},
		{Name: 19, Type: uint32(elf.SHT_DYNAMIC), Flags: uint64(elf.SHF_ALLOC | elf.SHF_WRITE), Addr: dynOff, Off: dynOff, Size: uint64(dynBuf.Len()), Link: 2, Addralign: 8, Entsize: 16},
	}

	buf := make([]byte, shoff+uint64(numShdrs*shdrSize))
	var hdr bytes.Buffer
	_ = binary.Write(&hdr, binary.LittleEndian, &ehdr)
	for _, ph := range phdrs {
		_ = binary.Write(&hdr, binary.LittleEndian, &ph)
	}
	copy(buf[0:], hdr.Bytes())
	copy(buf[interpOff:], interpStr)
	copy(buf[shstrOff:], shstrtab)
	copy(buf[dynstrOff:], dynstr)
	copy(buf[dynOff:], dynBuf.Bytes())
	var shBytes bytes.Buffer
	for _, sh := range shdrs {
		_ = binary.Write(&shBytes, binary.LittleEndian, &sh)
	}
	copy(buf[shoff:], shBytes.Bytes())

	p := filepath.Join(t.TempDir(), "dyn_sections_elf")
	if err := os.WriteFile(p, buf, 0o755); err != nil {
		t.Fatalf("write dyn_sections_elf: %v", err)
	}

	d, err := inspectBinary(p)
	if err != nil {
		t.Fatalf("inspectBinary(dyn_sections_elf): %v", err)
	}
	if d.Linkage != "dynamic-pie" || d.RELRO != "full" {
		t.Fatalf("expected dynamic-pie with RELRO=full, got %+v", d)
	}
	if len(d.NeededLibs) != 2 || d.NeededLibs[0] != "libc.so.6" || d.NeededLibs[1] != "libz.so.1" {
		t.Fatalf("expected NeededLibs=[libc.so.6 libz.so.1], got %v", d.NeededLibs)
	}
}

func TestDiagRealZigCCBinaries(t *testing.T) {
	zigBin, err := exec.LookPath("zig")
	if err != nil {
		t.Skipf("zig not installed in PATH; skipping real C binary diag test: %v", err)
	}

	tmp := t.TempDir()
	cSrc := filepath.Join(tmp, "sample.c")
	cLib := filepath.Join(tmp, "lib.c")
	cDynWinSrc := filepath.Join(tmp, "use_lib.c")
	if err := os.WriteFile(cSrc, []byte("#include <stdio.h>\nint main(void) { puts(\"ok\"); return 0; }\n"), 0o644); err != nil {
		t.Fatalf("write sample.c: %v", err)
	}
	if err := os.WriteFile(cLib, []byte("#ifdef _WIN32\n__declspec(dllexport)\n#endif\nint add_two(int a, int b) { return a + b; }\n"), 0o644); err != nil {
		t.Fatalf("write lib.c: %v", err)
	}
	if err := os.WriteFile(cDynWinSrc, []byte("__declspec(dllimport) int add_two(int a, int b);\nint main(void) { return add_two(1, 2) == 3 ? 0 : 1; }\n"), 0o644); err != nil {
		t.Fatalf("write use_lib.c: %v", err)
	}

	depDLL := filepath.Join(tmp, "dep_test.dll")
	depImpLib := filepath.Join(tmp, "libdep_test.dll.a")
	depCmd := exec.Command(zigBin, "cc", "-target", "x86_64-windows-gnu", "-shared", cLib, "-Wl,--out-implib,"+depImpLib, "-o", depDLL)
	if out, err := depCmd.CombinedOutput(); err != nil {
		t.Fatalf("zig cc dep_test.dll failed: %v\n%s", err, string(out))
	}

	cases := []struct {
		name          string
		args          []string
		outFile       string
		format        string
		linkage       string
		static        bool
		pie           bool
		staticPIE     bool
		wantNonSysDLL string
	}{
		{
			name:    "linux_musl_static",
			args:    []string{"cc", "-target", "x86_64-linux-musl", "-static", cSrc},
			outFile: filepath.Join(tmp, "app_static"),
			format:  "ELF", linkage: "static", static: true, pie: false, staticPIE: false,
		},
		{
			name:    "linux_musl_static_pie",
			args:    []string{"cc", "-target", "x86_64-linux-musl", "-fPIE", "-pie", cSrc},
			outFile: filepath.Join(tmp, "app_static_pie"),
			format:  "ELF", linkage: "static-pie", static: true, pie: true, staticPIE: true,
		},
		{
			name:    "linux_gnu_dynamic",
			args:    []string{"cc", "-target", "x86_64-linux-gnu", cSrc},
			outFile: filepath.Join(tmp, "app_dynamic"),
			format:  "ELF", linkage: "dynamic", static: false, pie: false, staticPIE: false,
		},
		{
			name:    "linux_gnu_so",
			args:    []string{"cc", "-target", "x86_64-linux-gnu", "-shared", "-fPIC", cLib},
			outFile: filepath.Join(tmp, "libtest.so"),
			format:  "ELF", linkage: "shared-object", static: false, pie: false, staticPIE: false,
		},
		{
			name:    "windows_gnu_static_exe",
			args:    []string{"cc", "-target", "x86_64-windows-gnu", cSrc},
			outFile: filepath.Join(tmp, "app_win.exe"),
			format:  "PE", linkage: "static", static: true, pie: true, staticPIE: false,
		},
		{
			name:    "windows_gnu_dynamic_exe",
			args:    []string{"cc", "-target", "x86_64-windows-gnu", cDynWinSrc, depImpLib},
			outFile: filepath.Join(tmp, "app_win_dyn.exe"),
			format:  "PE", linkage: "dynamic", static: false, pie: true, staticPIE: false,
			wantNonSysDLL: "dep_test.dll",
		},
		{
			name:    "windows_gnu_dll",
			args:    []string{"cc", "-target", "x86_64-windows-gnu", "-shared", cLib},
			outFile: filepath.Join(tmp, "libtest.dll"),
			format:  "PE", linkage: "dll", static: false, pie: true, staticPIE: false,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cmdArgs := append(append([]string{}, tc.args...), "-o", tc.outFile)
			cmd := exec.Command(zigBin, cmdArgs...)
			if out, err := cmd.CombinedOutput(); err != nil {
				t.Fatalf("zig %v failed: %v\n%s", cmdArgs, err, string(out))
			}
			d, err := inspectBinary(tc.outFile)
			if err != nil {
				t.Fatalf("inspectBinary(%s): %v", tc.outFile, err)
			}
			if d.Format != tc.format || d.Linkage != tc.linkage || d.Static != tc.static || d.PIE != tc.pie || d.StaticPIE != tc.staticPIE {
				t.Fatalf("got format=%s linkage=%s static=%t pie=%t static_pie=%t, want format=%s linkage=%s static=%t pie=%t static_pie=%t (%+v)",
					d.Format, d.Linkage, d.Static, d.PIE, d.StaticPIE, tc.format, tc.linkage, tc.static, tc.pie, tc.staticPIE, d)
			}
			if d.Go == nil || d.Go.Detected || d.Go.BuildInfo != "absent" {
				t.Fatalf("expected non-Go C binary to have go.detected=false buildinfo=absent, got %+v", d.Go)
			}
			if tc.wantNonSysDLL != "" {
				found := false
				for _, dll := range d.NonSysDLLs {
					if strings.EqualFold(dll, tc.wantNonSysDLL) {
						found = true
						break
					}
				}
				if !found {
					t.Fatalf("expected NonSysDLLs to include %q, got %v", tc.wantNonSysDLL, d.NonSysDLLs)
				}
			}
		})
	}
}

func TestDiagWindowsPEAndCLIOptions(t *testing.T) {
	pePath := buildSampleBinary(t, "windows", "diag_win.exe")
	d, err := inspectBinary(pePath)
	if err != nil {
		t.Fatalf("inspectBinary(PE): %v", err)
	}
	if d.Format != "PE" || d.Class != "PE32+" || d.Arch != "x86_64" || d.Linkage != "static" || !d.Static || !d.PIE {
		t.Fatalf("unexpected PE diag: %+v", d)
	}
	if d.NX == nil || !*d.NX || d.HighEntASLR == nil || !*d.HighEntASLR || d.Signed == nil || *d.Signed || len(d.NonSysDLLs) != 0 {
		t.Fatalf("unexpected PE hardening/DLL state: %+v", d)
	}
	if !isWindowsSystemDLL("KERNEL32.dll") || !isWindowsSystemDLL("api-ms-win-crt-runtime-l1-1-0.dll") {
		t.Fatalf("expected Windows OS DLLs to be recognized")
	}
	if isWindowsSystemDLL("libwinpthread-1.dll") || isWindowsSystemDLL("vcruntime140.dll") {
		t.Fatalf("expected non-system runtime DLLs not to match OS allowlist")
	}

	// Test multi-target -diag -json array output
	elfPath := buildSampleWithMode(t, "linux", "exe", "diag_lnx")
	var out, errBuf bytes.Buffer
	if code := run([]string{"-diag", "-json", pePath, elfPath}, &out, &errBuf); code != 0 {
		t.Fatalf("-diag -json multi failed: code=%d err=%q", code, errBuf.String())
	}
	var arr []BinaryDiag
	if err := json.Unmarshal(out.Bytes(), &arr); err != nil || len(arr) != 2 {
		t.Fatalf("expected JSON array of 2 items, err=%v out=%s", err, out.String())
	}

	// Test CLI usage guards for -diag / -json
	out.Reset()
	errBuf.Reset()
	if code := run([]string{"-json", pePath}, &out, &errBuf); code != 2 {
		t.Fatalf("-json without -diag got code=%d, want 2", code)
	}
	out.Reset()
	errBuf.Reset()
	if code := run([]string{"-diag"}, &out, &errBuf); code != 2 {
		t.Fatalf("-diag without target got code=%d, want 2", code)
	}
	out.Reset()
	errBuf.Reset()
	if code := run([]string{"-diag", pePath}, &out, &errBuf); code != 0 || !strings.Contains(out.String(), "Linkage       : static") {
		t.Fatalf("-diag text output unexpected: code=%d out=%q err=%q", code, out.String(), errBuf.String())
	}
}

func TestDiagUnstrippedAnd32Bit(t *testing.T) {
	elf32 := buildSampleCustom(t, "linux", "386", "exe", "", "sample_386")
	dELF, err := inspectBinary(elf32)
	if err != nil {
		t.Fatalf("inspectBinary(linux/386): %v", err)
	}
	if dELF.Class != "ELF32" || dELF.Arch != "x86" || !dELF.HasSymtab || dELF.Stripped {
		t.Fatalf("expected unstripped ELF32/x86 with symtab, got %+v", dELF)
	}
	var text bytes.Buffer
	formatBinaryDiag(&text, dELF)
	if !strings.Contains(text.String(), "ELF32, x86, little-endian") {
		t.Fatalf("unexpected formatted text: %s", text.String())
	}

	pe32 := buildSampleCustom(t, "windows", "386", "exe", "-s -w", "sample32.exe")
	dPE, err := inspectBinary(pe32)
	if err != nil {
		t.Fatalf("inspectBinary(windows/386): %v", err)
	}
	if dPE.Class != "PE32" || dPE.Arch != "x86" || dPE.HighEntASLR == nil || *dPE.HighEntASLR {
		t.Fatalf("expected PE32/x86 without HighEntASLR, got %+v", dPE)
	}
}

func TestDiagSyntheticELF32BigEndian(t *testing.T) {
	const (
		ehdrSize = 52
		phdrSize = 32
		numPhdrs = 4 // PT_LOAD, PT_DYNAMIC, PT_GNU_RELRO, PT_GNU_STACK
	)
	payloadOff := uint32(ehdrSize + numPhdrs*phdrSize)
	var body bytes.Buffer
	addDyn := func(tag uint32, val uint32) {
		_ = binary.Write(&body, binary.BigEndian, tag)
		_ = binary.Write(&body, binary.BigEndian, val)
	}
	addDyn(uint32(elf.DT_FLAGS), uint32(elf.DF_BIND_NOW))
	addDyn(uint32(elf.DT_FLAGS_1), elfFlag1PIE)
	addDyn(uint32(elf.DT_NULL), 0)

	totalSize := payloadOff + uint32(body.Len())
	ehdr := elf.Header32{
		Ident:     [elf.EI_NIDENT]byte{0x7f, 'E', 'L', 'F', byte(elf.ELFCLASS32), byte(elf.ELFDATA2MSB), byte(elf.EV_CURRENT)},
		Type:      uint16(elf.ET_DYN),
		Machine:   uint16(elf.EM_386),
		Version:   uint32(elf.EV_CURRENT),
		Entry:     0x1000,
		Phoff:     ehdrSize,
		Ehsize:    ehdrSize,
		Phentsize: phdrSize,
		Phnum:     numPhdrs,
	}
	phdrs := []elf.Prog32{
		{Type: uint32(elf.PT_LOAD), Flags: uint32(elf.PF_R | elf.PF_X), Filesz: totalSize, Memsz: totalSize, Align: 0x1000},
		{Type: uint32(elf.PT_DYNAMIC), Flags: uint32(elf.PF_R | elf.PF_W), Off: payloadOff, Vaddr: payloadOff, Paddr: payloadOff, Filesz: uint32(body.Len()), Memsz: uint32(body.Len()), Align: 4},
		{Type: uint32(elf.PT_GNU_RELRO), Flags: uint32(elf.PF_R), Filesz: 32, Memsz: 32, Align: 1},
		{Type: uint32(elf.PT_GNU_STACK), Flags: uint32(elf.PF_R | elf.PF_W), Align: 8},
	}

	var raw bytes.Buffer
	_ = binary.Write(&raw, binary.BigEndian, &ehdr)
	for _, ph := range phdrs {
		_ = binary.Write(&raw, binary.BigEndian, &ph)
	}
	raw.Write(body.Bytes())

	p := filepath.Join(t.TempDir(), "elf32_be")
	if err := os.WriteFile(p, raw.Bytes(), 0o755); err != nil {
		t.Fatalf("write elf32_be: %v", err)
	}
	d, err := inspectBinary(p)
	if err != nil {
		t.Fatalf("inspectBinary(elf32_be): %v", err)
	}
	if d.Class != "ELF32" || d.Endianness != "big" || d.Linkage != "static-pie" || d.RELRO != "full" || d.NX == nil || !*d.NX {
		t.Fatalf("unexpected ELF32 big-endian diag: %+v", d)
	}
}

func TestDiagPEHardeningDLLAndNonSysImport(t *testing.T) {
	pePath := buildSampleBinary(t, "windows", "hardened.exe")
	b, err := os.ReadFile(pePath)
	if err != nil {
		t.Fatalf("read sample PE: %v", err)
	}
	peOff := int(binary.LittleEndian.Uint32(b[0x3c:0x40]))
	coffOff := peOff + 4
	optOff := coffOff + 20

	// 1. Patch Characteristics |= IMAGE_FILE_DLL | IMAGE_FILE_RELOCS_STRIPPED, DllCharacteristics |= GUARD_CF, and Authenticode dir.
	chars := binary.LittleEndian.Uint16(b[coffOff+18 : coffOff+20])
	binary.LittleEndian.PutUint16(b[coffOff+18:coffOff+20], chars|peFileDLL|peFileRelocsStripped)
	dllChars := binary.LittleEndian.Uint16(b[optOff+70 : optOff+72])
	binary.LittleEndian.PutUint16(b[optOff+70:optOff+72], dllChars|peDllCharsGuardCF)
	secDirOff := optOff + 112 + 4*8
	binary.LittleEndian.PutUint32(b[secDirOff:secDirOff+4], uint32(len(b)))
	binary.LittleEndian.PutUint32(b[secDirOff+4:secDirOff+8], 64)
	b = append(b, make([]byte, 64)...)

	// Replace all ASCII case variants of kernel32.dll\0 (exact 13-byte length, preserving offsets).
	const needle = "kernel32.dll\x00"
	replaced := 0
	for i := 0; i+len(needle) <= len(b); i++ {
		if (b[i] == 'k' || b[i] == 'K') && b[i+len(needle)-1] == 0 && strings.EqualFold(string(b[i:i+len(needle)]), needle) {
			copy(b[i:], "customrt.dll\x00")
			replaced++
		}
	}
	if replaced == 0 {
		t.Fatalf("expected kernel32.dll import string in PE")
	}

	modPE := filepath.Join(t.TempDir(), "mod.dll")
	if err := os.WriteFile(modPE, b, 0o644); err != nil {
		t.Fatalf("write mod.dll: %v", err)
	}

	d, err := inspectBinary(modPE)
	if err != nil {
		t.Fatalf("inspectBinary(mod.dll): %v", err)
	}
	if d.Linkage != "dll" || d.Static || d.PIE || d.CFG == nil || !*d.CFG || d.Signed == nil || !*d.Signed {
		t.Fatalf("unexpected modified PE diag: %+v", d)
	}
	if len(d.NonSysDLLs) == 0 || !strings.EqualFold(d.NonSysDLLs[0], "customrt.dll") {
		t.Fatalf("expected customrt.dll in NonSysDLLs, got %v", d.NonSysDLLs)
	}

	// Clear IMAGE_FILE_DLL while keeping non-system DLL -> Linkage must be "dynamic"
	binary.LittleEndian.PutUint16(b[coffOff+18:coffOff+20], chars|peFileRelocsStripped)
	dynPE := filepath.Join(t.TempDir(), "dyn.exe")
	if err := os.WriteFile(dynPE, b, 0o644); err != nil {
		t.Fatalf("write dyn.exe: %v", err)
	}
	dDyn, err := inspectBinary(dynPE)
	if err != nil {
		t.Fatalf("inspectBinary(dyn.exe): %v", err)
	}
	if dDyn.Linkage != "dynamic" || dDyn.Static || dDyn.PIE {
		t.Fatalf("expected dynamic non-PIE PE, got %+v", dDyn)
	}
}

func TestDiagNegativeInputs(t *testing.T) {
	tmp := t.TempDir()
	missing := filepath.Join(tmp, "missing")
	plain := filepath.Join(tmp, "plain.txt")
	if err := os.WriteFile(plain, []byte("plain"), 0o644); err != nil {
		t.Fatalf("write plain: %v", err)
	}

	for _, target := range []string{tmp, missing, plain} {
		var out, errBuf bytes.Buffer
		if code := run([]string{"-diag", target}, &out, &errBuf); code != 1 {
			t.Fatalf("run(-diag %s) got code=%d, want 1 (err=%q)", target, code, errBuf.String())
		}
	}
}

func TestE2ECompiledCLI(t *testing.T) {
	exeExt := ""
	if runtime.GOOS == "windows" {
		exeExt = ".exe"
	}
	cliBin := filepath.Join(t.TempDir(), "gosanitize"+exeExt)
	buildCmd := exec.Command("go", "build", "-trimpath", "-buildmode=pie", "-buildvcs=false", "-ldflags=-s -w", "-o", cliBin, ".")
	buildCmd.Env = append(os.Environ(), "CGO_ENABLED=0")
	if out, err := buildCmd.CombinedOutput(); err != nil {
		t.Fatalf("build gosanitize CLI: %v\n%s", err, string(out))
	}

	winSample := buildSampleBinary(t, "windows", "e2e_win.exe")
	lnxSample := buildSampleWithMode(t, "linux", "exe", "e2e_lnx")

	// Multi-target -diag -json as real OS subprocess
	cmd := exec.Command(cliBin, "-diag", "-json", winSample, lnxSample)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("compiled -diag -json failed: %v\nstderr=%s", err, stderr.String())
	}
	if stderr.Len() != 0 {
		t.Fatalf("expected clean stderr for -diag -json, got %q", stderr.String())
	}
	var items []BinaryDiag
	if err := json.Unmarshal(stdout.Bytes(), &items); err != nil || len(items) != 2 {
		t.Fatalf("unexpected E2E JSON output: err=%v out=%s", err, stdout.String())
	}
	if items[0].Format != "PE" || items[1].Format != "ELF" || items[1].Linkage != "static" {
		t.Fatalf("unexpected E2E items: %+v", items)
	}

	// Sanitize + diagnose in-place across Windows PE and Linux ELF, confirming host execution succeeds
	verifySanitizeAndRun := func(samplePath, targetGOOS string) {
		t.Helper()
		stdout.Reset()
		stderr.Reset()
		cmdRun := exec.Command(cliBin, "-remove-buildinfo", "-inplace", "-diag", "-json", samplePath)
		cmdRun.Stdout = &stdout
		cmdRun.Stderr = &stderr
		if err := cmdRun.Run(); err != nil {
			t.Fatalf("compiled sanitize+diag (%s) failed: %v\nstderr=%s", targetGOOS, err, stderr.String())
		}
		var after []BinaryDiag
		if err := json.Unmarshal(stdout.Bytes(), &after); err != nil || len(after) != 1 {
			t.Fatalf("unmarshal post-sanitize JSON (%s): err=%v len=%d", targetGOOS, err, len(after))
		}
		if after[0].Go == nil || !after[0].Go.Detected || after[0].Go.BuildInfo != "stripped" {
			t.Fatalf("expected post-sanitize Go (%s) buildinfo=stripped, got %+v", targetGOOS, after[0].Go)
		}
		if _, err := buildinfo.ReadFile(samplePath); err == nil {
			t.Fatalf("expected buildinfo unreadable after E2E sanitize (%s)", targetGOOS)
		}
		if runtime.GOOS == targetGOOS {
			out, err := exec.Command(samplePath).CombinedOutput()
			if err != nil || strings.TrimSpace(string(out)) != "ok-sample" {
				t.Fatalf("E2E sanitized binary (%s) failed to run: err=%v out=%q", targetGOOS, err, string(out))
			}
		}
	}
	verifySanitizeAndRun(winSample, "windows")
	verifySanitizeAndRun(lnxSample, "linux")

	// Invalid usage exits with code 2
	cmdErr := exec.Command(cliBin, "-json")
	if err := cmdErr.Run(); err == nil {
		t.Fatalf("expected exit code 2 for -json without -diag")
	} else if exitErr, ok := err.(*exec.ExitError); !ok || exitErr.ExitCode() != 2 {
		t.Fatalf("expected ExitError(2), got %v", err)
	}
}
