// Command gosanitize inspects Go ELF (Linux) and PE (Windows) executables
// and strips embedded Go buildinfo metadata in-place or with a backup copy.
package main

import (
	"bytes"
	"debug/buildinfo"
	"debug/elf"
	"debug/pe"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"time"
)

var version = "dev"

var buildInfoMagic = []byte("\xff Go buildinf:")

const (
	buildInfoHeaderSize = 32
	buildInfoFlagMask   = 0x03 // bit 0: big-endian, bit 1: inline varint payload
	buildInfoFlagInline = 0x02
	maxELFBuildInfoSize = 16 * 1024 * 1024 // 16 MiB cap against malformed ELF section headers
)

var errNoBuildInfo = errors.New("no Go buildinfo found")

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	var (
		removeBuildInfo bool
		inplace         bool
		showVersion     bool
		showHelp        bool
	)

	fs := flag.NewFlagSet("gosanitize", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.BoolVar(&removeBuildInfo, "remove-buildinfo", false, "Remove Go buildinfo metadata from the target binary")
	fs.BoolVar(&inplace, "inplace", false, "Modify the binary in place without creating or overwriting a <binary>.buildinfo backup")
	fs.BoolVar(&showVersion, "version", false, "Print version information and exit")
	fs.BoolVar(&showHelp, "help", false, "Show this help message and exit")
	fs.Usage = func() {}

	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			printUsage(fs, stdout)
			return 0
		}
		printUsage(fs, stderr)
		return 2
	}

	if showHelp {
		printUsage(fs, stdout)
		return 0
	}

	if showVersion {
		_, _ = fmt.Fprintf(stdout, "gosanitize %s\n", version)
		return 0
	}

	if !removeBuildInfo {
		_, _ = fmt.Fprintln(stderr, "error: no action specified (use -remove-buildinfo, -version, or -help)")
		printUsage(fs, stderr)
		return 2
	}

	targets := fs.Args()
	if len(targets) == 0 {
		_, _ = fmt.Fprintln(stderr, "error: -remove-buildinfo requires at least one binary path")
		printUsage(fs, stderr)
		return 2
	}

	for _, target := range targets {
		changed, format, err := sanitizeFile(target, inplace)
		if err != nil {
			_, _ = fmt.Fprintf(stderr, "error: %s: %v\n", target, err)
			return 1
		}
		if changed {
			if inplace {
				_, _ = fmt.Fprintf(stdout, "Removed Go buildinfo from %s (%s, in-place)\n", target, format)
			} else {
				_, _ = fmt.Fprintf(stdout, "Removed Go buildinfo from %s (%s, backup: %s.buildinfo)\n", target, format, target)
			}
		} else {
			_, _ = fmt.Fprintf(stdout, "No Go buildinfo found in %s (%s); left unchanged\n", target, format)
		}
	}
	return 0
}

func printUsage(fs *flag.FlagSet, w io.Writer) {
	_, _ = fmt.Fprintln(w, "Usage: gosanitize [options] <binary>...")
	_, _ = fmt.Fprintln(w, "")
	_, _ = fmt.Fprintln(w, "Autodetects Linux (ELF) and Windows (PE) Go binaries and strips Go buildinfo metadata.")
	_, _ = fmt.Fprintln(w, "")
	_, _ = fmt.Fprintln(w, "Options:")
	prev := fs.Output()
	fs.SetOutput(w)
	fs.PrintDefaults()
	fs.SetOutput(prev)
}

func sanitizeFile(path string, inplace bool) (bool, string, error) {
	path = filepath.Clean(path)
	info, err := os.Lstat(path)
	if err != nil {
		return false, "", err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return false, "", errors.New("refusing to sanitize symlink")
	}
	if !info.Mode().IsRegular() {
		return false, "", errors.New("not a regular file")
	}

	// #nosec G304 -- path is the CLI target binary validated above via Lstat.
	f, err := os.Open(path)
	if err != nil {
		return false, "", err
	}
	srcClosed := false
	defer func() {
		if !srcClosed {
			_ = f.Close()
		}
	}()

	openedInfo, err := f.Stat()
	if err != nil {
		return false, "", err
	}
	if !os.SameFile(info, openedInfo) {
		return false, "", errors.New("target file changed during inspection")
	}

	format, offset, length, err := locateBuildInfo(f, openedInfo.Size())
	if err != nil {
		return false, format, err
	}
	if length == 0 {
		return false, format, nil
	}

	mode := openedInfo.Mode().Perm()
	if !inplace {
		backupPath := path + ".buildinfo"
		if err := copyReaderToAtomic(f, backupPath, mode, 0, 0, nil); err != nil {
			return false, format, fmt.Errorf("create backup %s: %w", backupPath, err)
		}
	}

	closeSrc := func() {
		if !srcClosed {
			_ = f.Close()
			srcClosed = true
		}
	}
	if err := copyReaderToAtomic(f, path, mode, offset, length, closeSrc); err != nil {
		return false, format, fmt.Errorf("write sanitized binary: %w", err)
	}
	return true, format, nil
}

// copyReaderToAtomic rewinds src, copies it to a temporary file alongside dstPath,
// optionally overwrites [zeroOffset, zeroOffset+zeroLen) with zeros when zeroLen > 0,
// applies mode, invokes beforeRename (e.g., to release Windows source locks), and
// atomically renames the temp file onto dstPath.
func copyReaderToAtomic(src io.ReadSeeker, dstPath string, mode os.FileMode, zeroOffset, zeroLen int64, beforeRename func()) error {
	if _, err := src.Seek(0, io.SeekStart); err != nil {
		return err
	}

	dir := filepath.Dir(dstPath)
	base := filepath.Base(dstPath)
	tmpFile, err := os.CreateTemp(dir, base+".tmp.*")
	if err != nil {
		return err
	}
	tmpPath := tmpFile.Name()
	cleanup := true
	defer func() {
		if cleanup {
			_ = os.Remove(tmpPath)
		}
	}()

	if _, err := io.Copy(tmpFile, src); err != nil {
		_ = tmpFile.Close()
		return err
	}
	if zeroLen > 0 {
		if err := zeroFileRange(tmpFile, zeroOffset, zeroLen); err != nil {
			_ = tmpFile.Close()
			return err
		}
	}
	if err := tmpFile.Chmod(mode); err != nil {
		_ = tmpFile.Close()
		return err
	}
	if err := tmpFile.Sync(); err != nil {
		_ = tmpFile.Close()
		return err
	}
	if err := tmpFile.Close(); err != nil {
		return err
	}

	if zeroLen > 0 {
		if _, err := buildinfo.ReadFile(tmpPath); err == nil {
			return errors.New("post-scrub verification failed: buildinfo still readable")
		}
	}

	if beforeRename != nil {
		beforeRename()
	}

	if err := renameWithRetry(tmpPath, dstPath); err != nil {
		return err
	}
	cleanup = false
	return nil
}

func renameWithRetry(srcPath, dstPath string) error {
	const (
		maxAttempts = 5
		retryDelay  = 50 * time.Millisecond
	)
	var err error
	attempts := 1
	if runtime.GOOS == "windows" {
		attempts = maxAttempts
	}
	for i := 0; i < attempts; i++ {
		if err = os.Rename(srcPath, dstPath); err == nil {
			return nil
		}
		if i < attempts-1 {
			time.Sleep(retryDelay)
		}
	}
	return err
}

func zeroFileRange(f *os.File, offset, length int64) error {
	if _, err := f.Seek(offset, io.SeekStart); err != nil {
		return err
	}
	var zeros [32 * 1024]byte
	rem := length
	for rem > 0 {
		chunk := rem
		if chunk > int64(len(zeros)) {
			chunk = int64(len(zeros))
		}
		if _, err := f.Write(zeros[:chunk]); err != nil {
			return err
		}
		rem -= chunk
	}
	return nil
}

func locateBuildInfo(r io.ReaderAt, fileSize int64) (string, int64, int64, error) {
	var magic [4]byte
	n, err := r.ReadAt(magic[:], 0)
	if err != nil && !errors.Is(err, io.EOF) {
		return "unknown", 0, 0, err
	}
	switch {
	case n >= 4 && bytes.Equal(magic[:4], []byte("\x7fELF")):
		off, length, err := locateELFBuildInfo(r, fileSize)
		return "ELF", off, length, err
	case n >= 2 && bytes.Equal(magic[:2], []byte("MZ")):
		off, length, err := locatePEBuildInfo(r, fileSize)
		return "PE", off, length, err
	default:
		return "unknown", 0, 0, errors.New("unsupported binary format (expected ELF or PE)")
	}
}

func locateELFBuildInfo(r io.ReaderAt, fileSize int64) (int64, int64, error) {
	f, err := elf.NewFile(r)
	if err != nil {
		return 0, 0, fmt.Errorf("parse ELF: %w", err)
	}
	defer func() { _ = f.Close() }()

	sec := f.Section(".go.buildinfo")
	if sec == nil || sec.Size == 0 || sec.Type == elf.SHT_NOBITS {
		return 0, 0, nil
	}
	if fileSize < 0 || sec.Offset > uint64(fileSize) || sec.Size > uint64(fileSize)-sec.Offset {
		return 0, 0, errors.New("ELF .go.buildinfo section extends beyond file bounds")
	}
	if sec.Size > maxELFBuildInfoSize {
		return 0, 0, fmt.Errorf("ELF .go.buildinfo section size %d exceeds %d-byte limit", sec.Size, maxELFBuildInfoSize)
	}
	if sec.Offset > math.MaxInt64 || sec.Size > math.MaxInt64 {
		return 0, 0, errors.New("ELF .go.buildinfo offset or size overflows int64")
	}

	data, err := sec.Data()
	if err != nil {
		return 0, 0, fmt.Errorf("read ELF .go.buildinfo: %w", err)
	}
	if isAllZero(data) {
		return 0, 0, nil
	}
	return int64(sec.Offset), int64(sec.Size), nil
}

func locatePEBuildInfo(r io.ReaderAt, fileSize int64) (int64, int64, error) {
	f, err := pe.NewFile(r)
	if err != nil {
		return 0, 0, fmt.Errorf("parse PE: %w", err)
	}
	defer func() { _ = f.Close() }()

	if hasPEAuthenticode(f) {
		return 0, 0, errors.New("refusing to modify Authenticode-signed PE binary (would invalidate signature)")
	}

	// Scan .data first (Go places runtime.buildinfo there on PE), then .rdata, then remaining sections.
	for _, sec := range prioritizePESections(f.Sections) {
		if sec.Size == 0 || sec.Offset == 0 || fileSize <= 0 {
			continue
		}
		start := int64(sec.Offset)
		if start >= fileSize {
			continue
		}
		size := int64(sec.Size)
		if size > fileSize-start {
			size = fileSize - start
		}

		off, length, err := scanPESection(r, start, size)
		if errors.Is(err, errNoBuildInfo) {
			continue
		}
		if err != nil {
			return 0, 0, fmt.Errorf("scan PE section %s: %w", sec.Name, err)
		}
		return off, length, nil
	}
	return 0, 0, nil
}

func scanPESection(r io.ReaderAt, start, size int64) (int64, int64, error) {
	const (
		chunkSize = 4 * 1024 * 1024
		overlap   = 1 * 1024 * 1024
		step      = chunkSize - overlap // 3 MiB, divisible by 8 to preserve pointer alignment
	)
	if size <= chunkSize {
		buf := make([]byte, size)
		if _, err := r.ReadAt(buf, start); err != nil && !errors.Is(err, io.EOF) {
			return 0, 0, err
		}
		off, length, err := findPEBuildInfoRange(buf)
		if err != nil {
			return 0, 0, err
		}
		return start + int64(off), int64(length), nil
	}

	buf := make([]byte, chunkSize)
	for offset := int64(0); offset < size; offset += step {
		readLen := size - offset
		if readLen > chunkSize {
			readLen = chunkSize
		}
		n, err := r.ReadAt(buf[:readLen], start+offset)
		if err != nil && !errors.Is(err, io.EOF) {
			return 0, 0, err
		}
		if n == 0 {
			break
		}
		off, length, err := findPEBuildInfoRange(buf[:n])
		if err == nil {
			return start + offset + int64(off), int64(length), nil
		}
		if !errors.Is(err, errNoBuildInfo) {
			return 0, 0, err
		}
		if offset+int64(n) >= size {
			break
		}
	}
	return 0, 0, errNoBuildInfo
}

func hasPEAuthenticode(f *pe.File) bool {
	switch oh := f.OptionalHeader.(type) {
	case *pe.OptionalHeader64:
		return int(oh.NumberOfRvaAndSizes) > pe.IMAGE_DIRECTORY_ENTRY_SECURITY &&
			oh.DataDirectory[pe.IMAGE_DIRECTORY_ENTRY_SECURITY].Size > 0
	case *pe.OptionalHeader32:
		return int(oh.NumberOfRvaAndSizes) > pe.IMAGE_DIRECTORY_ENTRY_SECURITY &&
			oh.DataDirectory[pe.IMAGE_DIRECTORY_ENTRY_SECURITY].Size > 0
	default:
		return false
	}
}

func prioritizePESections(sections []*pe.Section) []*pe.Section {
	var dataSecs, rdataSecs, otherSecs []*pe.Section
	for _, s := range sections {
		switch s.Name {
		case ".data":
			dataSecs = append(dataSecs, s)
		case ".rdata":
			rdataSecs = append(rdataSecs, s)
		default:
			otherSecs = append(otherSecs, s)
		}
	}
	ordered := make([]*pe.Section, 0, len(sections))
	ordered = append(ordered, dataSecs...)
	ordered = append(ordered, rdataSecs...)
	ordered = append(ordered, otherSecs...)
	return ordered
}

func findPEBuildInfoRange(secBytes []byte) (int, int, error) {
	searchFrom := 0
	for {
		rel := bytes.Index(secBytes[searchFrom:], buildInfoMagic)
		if rel < 0 {
			return 0, 0, errNoBuildInfo
		}
		idx := searchFrom + rel
		next := idx + len(buildInfoMagic)
		if idx+16 > len(secBytes) {
			return 0, 0, errNoBuildInfo
		}

		ptrSize := int(secBytes[idx+14])
		flags := secBytes[idx+15]
		if (ptrSize != 4 && ptrSize != 8) || flags&^buildInfoFlagMask != 0 || idx%ptrSize != 0 {
			searchFrom = next
			continue
		}

		if flags&buildInfoFlagInline != 0 {
			if idx+buildInfoHeaderSize > len(secBytes) {
				searchFrom = next
				continue
			}
			pos, ok := advanceUvarintPayload(secBytes, idx+buildInfoHeaderSize)
			if !ok {
				searchFrom = next
				continue
			}
			pos, ok = advanceUvarintPayload(secBytes, pos)
			if !ok {
				searchFrom = next
				continue
			}
			return idx, pos - idx, nil
		}

		legacyHeaderLen := 16 + 2*ptrSize
		if idx+legacyHeaderLen > len(secBytes) {
			searchFrom = next
			continue
		}
		return idx, legacyHeaderLen, nil
	}
}

func advanceUvarintPayload(buf []byte, pos int) (int, bool) {
	if pos < 0 || pos >= len(buf) {
		return 0, false
	}
	payloadLen, n := binary.Uvarint(buf[pos:])
	if n <= 0 {
		return 0, false
	}
	rem := len(buf) - pos - n
	if rem < 0 || payloadLen > math.MaxInt || int(payloadLen) > rem {
		return 0, false
	}
	return pos + n + int(payloadLen), true
}

func isAllZero(b []byte) bool {
	for _, v := range b {
		if v != 0 {
			return false
		}
	}
	return true
}
