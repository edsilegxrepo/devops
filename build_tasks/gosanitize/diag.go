package main

import (
	"bytes"
	"crypto/sha256"
	"debug/buildinfo"
	"debug/elf"
	"debug/pe"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const (
	elfFlag1PIE             = 0x08000000
	maxELFDynamicSize       = 16 * 1024 * 1024
	peDirImport             = 1
	peDirBaseReloc          = 5
	peDirDebug              = 6
	peSubsystemWindowsGUI   = 2
	peSubsystemWindowsCUI   = 3
	peSubsystemNative       = 1
	peDllCharsHighEntropyVA = 0x0020
	peDllCharsDynamicBase   = 0x0040
	peDllCharsNXCompat      = 0x0100
	peDllCharsGuardCF       = 0x4000
	peFileRelocsStripped    = 0x0001
	peFileDLL               = 0x2000
	maxInterpLen            = 4096
)

// BinaryDiag summarizes structural, linkage, hardening, and Go metadata properties of an ELF or PE binary.
type BinaryDiag struct {
	Path        string   `json:"path"`
	Format      string   `json:"format"`
	Class       string   `json:"class"`
	Arch        string   `json:"arch"`
	Endianness  string   `json:"endianness"`
	SizeBytes   int64    `json:"size_bytes"`
	SHA256      string   `json:"sha256"`
	Linkage     string   `json:"linkage"`
	Static      bool     `json:"static"`
	PIE         bool     `json:"pie"`
	StaticPIE   bool     `json:"static_pie"`
	EntryPoint  string   `json:"entry_point,omitempty"`
	Interpreter string   `json:"interpreter,omitempty"`
	NeededLibs  []string `json:"needed_libs,omitempty"`
	NonSysDLLs  []string `json:"non_system_dlls,omitempty"`
	NX          *bool    `json:"nx,omitempty"`
	RELRO       string   `json:"relro,omitempty"`
	HighEntASLR *bool    `json:"high_entropy_aslr,omitempty"`
	CFG         *bool    `json:"cfg,omitempty"`
	Subsystem   string   `json:"subsystem,omitempty"`
	Signed      *bool    `json:"signed,omitempty"`
	HasSymtab   bool     `json:"has_symtab"`
	HasDebug    bool     `json:"has_debug"`
	Stripped    bool     `json:"stripped"`
	Go          *GoDiag  `json:"go,omitempty"`
}

// GoDiag captures Go buildinfo presence and toolchain/hardening settings embedded in a binary.
type GoDiag struct {
	Detected   bool   `json:"detected"`
	BuildInfo  string `json:"buildinfo"`
	GoVersion  string `json:"go_version,omitempty"`
	ModulePath string `json:"module_path,omitempty"`
	ModuleVer  string `json:"module_version,omitempty"`
	CGOEnabled string `json:"cgo_enabled,omitempty"`
	BuildMode  string `json:"buildmode,omitempty"`
	Trimpath   *bool  `json:"trimpath,omitempty"`
	VCSPresent bool   `json:"vcs_present,omitempty"`
}

type readerAtSeeker interface {
	io.ReaderAt
	io.ReadSeeker
}

type peOptSummary struct {
	class       string
	entryPoint  uint64
	subsystem   uint16
	dllChars    uint16
	importDir   pe.DataDirectory
	hasRelocDir bool
	hasDebugDir bool
}

var windowsSystemDLLs = map[string]struct{}{
	"advapi32.dll":         {},
	"authz.dll":            {},
	"bcrypt.dll":           {},
	"bcryptprimitives.dll": {},
	"cabinet.dll":          {},
	"cfgmgr32.dll":         {},
	"comctl32.dll":         {},
	"comdlg32.dll":         {},
	"credui.dll":           {},
	"crypt32.dll":          {},
	"cryptui.dll":          {},
	"dbghelp.dll":          {},
	"dnsapi.dll":           {},
	"dwmapi.dll":           {},
	"gdi32.dll":            {},
	"imm32.dll":            {},
	"iphlpapi.dll":         {},
	"kernel32.dll":         {},
	"kernelbase.dll":       {},
	"mpr.dll":              {},
	"msvcrt.dll":           {},
	"ncrypt.dll":           {},
	"netapi32.dll":         {},
	"normaliz.dll":         {},
	"ntdll.dll":            {},
	"ole32.dll":            {},
	"oleaut32.dll":         {},
	"pdh.dll":              {},
	"powrprof.dll":         {},
	"psapi.dll":            {},
	"rpcrt4.dll":           {},
	"secur32.dll":          {},
	"setupapi.dll":         {},
	"shell32.dll":          {},
	"shlwapi.dll":          {},
	"ucrtbase.dll":         {},
	"user32.dll":           {},
	"userenv.dll":          {},
	"uxtheme.dll":          {},
	"version.dll":          {},
	"wevtapi.dll":          {},
	"winhttp.dll":          {},
	"wininet.dll":          {},
	"winmm.dll":            {},
	"winspool.drv":         {},
	"wintrust.dll":         {},
	"ws2_32.dll":           {},
	"wsock32.dll":          {},
}

func inspectBinary(path string) (*BinaryDiag, error) {
	path = filepath.Clean(path)
	info, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() {
		return nil, errors.New("not a regular file")
	}

	// #nosec G304 -- path is the CLI target binary validated above via Stat.
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer func() { _ = f.Close() }()

	openedInfo, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if !os.SameFile(info, openedInfo) {
		return nil, errors.New("target file changed during inspection")
	}

	sum, err := computeSHA256(f)
	if err != nil {
		return nil, fmt.Errorf("hash binary: %w", err)
	}

	var magic [4]byte
	n, err := f.ReadAt(magic[:], 0)
	if err != nil && !errors.Is(err, io.EOF) {
		return nil, err
	}

	diag := &BinaryDiag{
		Path:      path,
		SizeBytes: openedInfo.Size(),
		SHA256:    sum,
	}

	switch {
	case n >= 4 && bytes.Equal(magic[:4], []byte("\x7fELF")):
		if err := inspectELF(f, diag); err != nil {
			return nil, err
		}
	case n >= 2 && bytes.Equal(magic[:2], []byte("MZ")):
		if err := inspectPE(f, diag); err != nil {
			return nil, err
		}
	default:
		return nil, errors.New("unsupported binary format (expected ELF or PE)")
	}

	return diag, nil
}

func computeSHA256(r io.ReadSeeker) (string, error) {
	if _, err := r.Seek(0, io.SeekStart); err != nil {
		return "", err
	}
	h := sha256.New()
	if _, err := io.Copy(h, r); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func inspectELF(r readerAtSeeker, diag *BinaryDiag) error {
	ef, err := elf.NewFile(r)
	if err != nil {
		return fmt.Errorf("parse ELF: %w", err)
	}
	defer func() { _ = ef.Close() }()

	diag.Format = "ELF"
	diag.Class = elfClassName(ef.Class)
	diag.Arch = elfMachineName(ef.Machine)
	diag.Endianness = elfDataName(ef.Data)
	diag.EntryPoint = fmt.Sprintf("0x%x", ef.Entry)

	var (
		hasRelro   bool
		hasDynamic bool
		interp     string
	)
	for _, p := range ef.Progs {
		switch p.Type {
		case elf.PT_INTERP:
			interp = readELFInterp(r, p)
		case elf.PT_DYNAMIC:
			hasDynamic = true
		case elf.PT_GNU_STACK:
			nx := (p.Flags & elf.PF_X) == 0
			diag.NX = &nx
		case elf.PT_GNU_RELRO:
			hasRelro = true
		}
	}
	diag.Interpreter = interp

	needed, dfFlags, df1Flags, hasBindNow, hasSoname := readELFDynamicInfo(r, ef)
	if len(needed) > 0 {
		diag.NeededLibs = needed
	}

	bindNow := hasBindNow || (dfFlags&uint64(elf.DF_BIND_NOW)) != 0 || (df1Flags&uint64(elf.DF_1_NOW)) != 0
	if !hasRelro {
		diag.RELRO = "none"
	} else if bindNow {
		diag.RELRO = "full"
	} else {
		diag.RELRO = "partial"
	}

	hasDF1PIE := (df1Flags & elfFlag1PIE) != 0
	classifyELFLinkage(ef, interp, needed, hasDynamic, hasSoname, hasDF1PIE, hasELFExports(ef), diag)

	var hasGoSection bool
	for _, s := range ef.Sections {
		if s.Type == elf.SHT_SYMTAB || s.Name == ".symtab" {
			diag.HasSymtab = true
		}
		if strings.HasPrefix(s.Name, ".debug_") || strings.HasPrefix(s.Name, ".zdebug_") {
			diag.HasDebug = true
		}
		if s.Name == ".go.buildinfo" || s.Name == ".gopclntab" || s.Name == ".note.go.buildid" {
			hasGoSection = true
		}
	}
	diag.Stripped = !diag.HasSymtab && !diag.HasDebug
	diag.Go = inspectGoMetadata(r, hasGoSection)
	return nil
}

func classifyELFLinkage(ef *elf.File, interp string, needed []string, hasDynamic, hasSoname, hasDF1PIE, hasExports bool, diag *BinaryDiag) {
	switch ef.Type {
	case elf.ET_REL:
		diag.Linkage = "relocatable"
	case elf.ET_EXEC:
		if interp != "" || len(needed) > 0 || hasDynamic {
			diag.Linkage = "dynamic"
		} else {
			diag.Linkage = "static"
			diag.Static = true
		}
	case elf.ET_DYN:
		if interp != "" {
			diag.Linkage = "dynamic-pie"
			diag.PIE = true
		} else if hasDF1PIE || (!hasSoname && ef.Entry != 0 && len(needed) == 0 && !hasExports) {
			diag.Linkage = "static-pie"
			diag.Static = true
			diag.PIE = true
			diag.StaticPIE = true
		} else {
			diag.Linkage = "shared-object"
		}
	default:
		diag.Linkage = strings.ToLower(ef.Type.String())
	}
}

func hasELFExports(ef *elf.File) bool {
	syms, err := ef.DynamicSymbols()
	if err != nil {
		return false
	}
	for _, s := range syms {
		if s.Name == "" || s.Section == elf.SHN_UNDEF {
			continue
		}
		bind := elf.ST_BIND(s.Info)
		if bind == elf.STB_GLOBAL || bind == elf.STB_WEAK {
			return true
		}
	}
	return false
}

func readELFDynamicInfo(r io.ReaderAt, ef *elf.File) (needed []string, dfFlags, df1Flags uint64, hasBindNow, hasSoname bool) {
	if ef.SectionByType(elf.SHT_DYNAMIC) != nil {
		needed, _ = ef.ImportedLibraries()
		if vals, err := ef.DynValue(elf.DT_FLAGS); err == nil {
			for _, v := range vals {
				dfFlags |= v
			}
		}
		if vals, err := ef.DynValue(elf.DT_FLAGS_1); err == nil {
			for _, v := range vals {
				df1Flags |= v
			}
		}
		if vals, err := ef.DynValue(elf.DT_BIND_NOW); err == nil && len(vals) > 0 {
			hasBindNow = true
		}
		if vals, err := ef.DynValue(elf.DT_SONAME); err == nil && len(vals) > 0 {
			hasSoname = true
		}
		return needed, dfFlags, df1Flags, hasBindNow, hasSoname
	}

	var (
		neededOffs []uint64
		strtabVA   uint64
		strtabSize uint64
		hasStrtab  bool
	)
	for _, p := range ef.Progs {
		if p.Type != elf.PT_DYNAMIC || p.Filesz == 0 || p.Filesz > maxELFDynamicSize || p.Off > math.MaxInt64 {
			continue
		}
		buf := make([]byte, p.Filesz)
		if _, err := r.ReadAt(buf, int64(p.Off)); err != nil && !errors.Is(err, io.EOF) {
			continue
		}
		entSize := 16
		if ef.Class == elf.ELFCLASS32 {
			entSize = 8
		}
		for off := 0; off+entSize <= len(buf); off += entSize {
			var tag uint64
			var val uint64
			if ef.Class == elf.ELFCLASS32 {
				tag = uint64(ef.ByteOrder.Uint32(buf[off : off+4]))
				val = uint64(ef.ByteOrder.Uint32(buf[off+4 : off+8]))
			} else {
				tag = ef.ByteOrder.Uint64(buf[off : off+8])
				val = ef.ByteOrder.Uint64(buf[off+8 : off+16])
			}
			switch tag {
			case uint64(elf.DT_NULL):
				goto resolveNeeded
			case uint64(elf.DT_NEEDED):
				neededOffs = append(neededOffs, val)
			case uint64(elf.DT_STRTAB):
				strtabVA = val
				hasStrtab = true
			case uint64(elf.DT_STRSZ):
				strtabSize = val
			case uint64(elf.DT_FLAGS):
				dfFlags |= val
			case uint64(elf.DT_FLAGS_1):
				df1Flags |= val
			case uint64(elf.DT_BIND_NOW):
				hasBindNow = true
			case uint64(elf.DT_SONAME):
				hasSoname = true
			}
		}
	}

resolveNeeded:
	if hasStrtab && len(neededOffs) > 0 {
		strOff, ok := elfVaddrToFileOffset(ef, strtabVA)
		if ok {
			if strtabSize == 0 || strtabSize > maxELFDynamicSize {
				strtabSize = maxELFDynamicSize
			}
			strBuf := make([]byte, strtabSize)
			n, err := r.ReadAt(strBuf, strOff)
			if err == nil || errors.Is(err, io.EOF) || n > 0 {
				strBuf = strBuf[:n]
				for _, noff := range neededOffs {
					if noff >= uint64(len(strBuf)) {
						continue
					}
					rest := strBuf[noff:]
					if nul := bytes.IndexByte(rest, 0); nul >= 0 {
						rest = rest[:nul]
					}
					if len(rest) > 0 {
						needed = append(needed, string(rest))
					}
				}
			}
		}
	}
	return needed, dfFlags, df1Flags, hasBindNow, hasSoname
}

func elfVaddrToFileOffset(ef *elf.File, vaddr uint64) (int64, bool) {
	for _, p := range ef.Progs {
		if p.Type != elf.PT_LOAD || p.Filesz == 0 || p.Off > math.MaxInt64 {
			continue
		}
		if vaddr >= p.Vaddr && vaddr-p.Vaddr < p.Filesz {
			delta := vaddr - p.Vaddr
			if delta > math.MaxInt64 || int64(delta) > math.MaxInt64-int64(p.Off) {
				return 0, false
			}
			return int64(p.Off) + int64(delta), true
		}
	}
	return 0, false
}

func readELFInterp(r io.ReaderAt, p *elf.Prog) string {
	if p.Filesz == 0 || p.Filesz > maxInterpLen || p.Off > math.MaxInt64 {
		return ""
	}
	buf := make([]byte, p.Filesz)
	if _, err := r.ReadAt(buf, int64(p.Off)); err != nil && !errors.Is(err, io.EOF) {
		return ""
	}
	return strings.TrimRight(string(buf), "\x00")
}

func inspectPE(r readerAtSeeker, diag *BinaryDiag) error {
	pf, err := pe.NewFile(r)
	if err != nil {
		return fmt.Errorf("parse PE: %w", err)
	}
	defer func() { _ = pf.Close() }()

	opt := summarizePEOptional(pf)
	diag.Format = "PE"
	diag.Class = opt.class
	diag.Arch = peMachineName(pf.Machine)
	diag.Endianness = "little"
	diag.EntryPoint = fmt.Sprintf("0x%x", opt.entryPoint)
	diag.Subsystem = peSubsystemName(opt.subsystem)

	signed := hasPEAuthenticode(pf)
	diag.Signed = &signed

	nx := (opt.dllChars & peDllCharsNXCompat) != 0
	diag.NX = &nx
	highEnt := (opt.dllChars & peDllCharsHighEntropyVA) != 0
	diag.HighEntASLR = &highEnt
	cfg := (opt.dllChars & peDllCharsGuardCF) != 0
	diag.CFG = &cfg

	hasReloc := opt.hasRelocDir || pf.Section(".reloc") != nil
	relocsStripped := (pf.Characteristics & peFileRelocsStripped) != 0
	diag.PIE = (opt.dllChars&peDllCharsDynamicBase) != 0 && hasReloc && !relocsStripped

	needed := readPEImportedDLLs(r, pf, opt.importDir)
	if len(needed) > 0 {
		diag.NeededLibs = needed
		for _, lib := range needed {
			if !isWindowsSystemDLL(lib) {
				diag.NonSysDLLs = append(diag.NonSysDLLs, lib)
			}
		}
	}

	isDLL := (pf.Characteristics & peFileDLL) != 0
	switch {
	case isDLL:
		diag.Linkage = "dll"
	case len(diag.NonSysDLLs) == 0:
		diag.Linkage = "static"
		diag.Static = true
	default:
		diag.Linkage = "dynamic"
	}

	diag.HasSymtab = pf.NumberOfSymbols > 0 && pf.PointerToSymbolTable > 0
	diag.HasDebug = opt.hasDebugDir
	for _, s := range pf.Sections {
		if strings.HasPrefix(s.Name, ".debug_") {
			diag.HasDebug = true
			break
		}
	}
	diag.Stripped = !diag.HasSymtab && !diag.HasDebug
	diag.Go = inspectGoMetadata(r, hasPEGoMarker(r, pf))
	return nil
}

func hasPEGoMarker(r io.ReaderAt, pf *pe.File) bool {
	var goBuildIDPrefix = []byte("\xff Go build ID: \"")
	for _, s := range pf.Sections {
		if s.Name == ".go.buildinfo" || s.Name == ".gopclntab" {
			return true
		}
		if s.Name == ".text" && s.Offset > 0 && int64(s.Size) >= int64(len(goBuildIDPrefix)) {
			const headerProbe = 256
			probeLen := int64(s.Size)
			if probeLen > headerProbe {
				probeLen = headerProbe
			}
			buf := make([]byte, probeLen)
			n, err := r.ReadAt(buf, int64(s.Offset))
			if (err == nil || errors.Is(err, io.EOF)) && bytes.Contains(buf[:n], goBuildIDPrefix) {
				return true
			}
		}
	}
	return false
}

func summarizePEOptional(pf *pe.File) peOptSummary {
	hasDir := func(dirs [16]pe.DataDirectory, count uint32, idx int) bool {
		return count > uint32(idx) && idx < len(dirs) && dirs[idx].Size > 0 // #nosec G115 -- idx is small non-negative constant (1..6)
	}
	getDir := func(dirs [16]pe.DataDirectory, count uint32, idx int) pe.DataDirectory {
		if hasDir(dirs, count, idx) {
			return dirs[idx]
		}
		return pe.DataDirectory{}
	}
	switch oh := pf.OptionalHeader.(type) {
	case *pe.OptionalHeader64:
		return peOptSummary{
			class:       "PE32+",
			entryPoint:  uint64(oh.AddressOfEntryPoint),
			subsystem:   oh.Subsystem,
			dllChars:    oh.DllCharacteristics,
			importDir:   getDir(oh.DataDirectory, oh.NumberOfRvaAndSizes, peDirImport),
			hasRelocDir: hasDir(oh.DataDirectory, oh.NumberOfRvaAndSizes, peDirBaseReloc),
			hasDebugDir: hasDir(oh.DataDirectory, oh.NumberOfRvaAndSizes, peDirDebug),
		}
	case *pe.OptionalHeader32:
		return peOptSummary{
			class:       "PE32",
			entryPoint:  uint64(oh.AddressOfEntryPoint),
			subsystem:   oh.Subsystem,
			dllChars:    oh.DllCharacteristics,
			importDir:   getDir(oh.DataDirectory, oh.NumberOfRvaAndSizes, peDirImport),
			hasRelocDir: hasDir(oh.DataDirectory, oh.NumberOfRvaAndSizes, peDirBaseReloc),
			hasDebugDir: hasDir(oh.DataDirectory, oh.NumberOfRvaAndSizes, peDirDebug),
		}
	default:
		return peOptSummary{class: "PE"}
	}
}

func readPEImportedDLLs(r io.ReaderAt, pf *pe.File, importDir pe.DataDirectory) []string {
	if importDir.VirtualAddress == 0 || importDir.Size == 0 {
		return nil
	}
	dirOff, ok := peRVAToFileOffset(pf, importDir.VirtualAddress)
	if !ok {
		return nil
	}
	const (
		descSize   = 20
		maxDescs   = 4096
		maxNameLen = 512
	)
	readSize := int64(importDir.Size)
	if maxBytes := int64(maxDescs * descSize); readSize > maxBytes {
		readSize = maxBytes
	}
	if readSize < descSize {
		return nil
	}
	buf := make([]byte, readSize)
	n, err := r.ReadAt(buf, dirOff)
	if err != nil && !errors.Is(err, io.EOF) {
		return nil
	}
	buf = buf[:n]

	var libs []string
	seen := make(map[string]struct{})
	for off := 0; off+descSize <= len(buf); off += descSize {
		origThunk := binary.LittleEndian.Uint32(buf[off : off+4])
		nameRVA := binary.LittleEndian.Uint32(buf[off+12 : off+16])
		firstThunk := binary.LittleEndian.Uint32(buf[off+16 : off+20])
		if origThunk == 0 && nameRVA == 0 && firstThunk == 0 {
			break
		}
		if nameRVA == 0 {
			continue
		}
		nameOff, found := peRVAToFileOffset(pf, nameRVA)
		if !found {
			continue
		}
		dllName := readCStringAt(r, nameOff, maxNameLen)
		if dllName == "" {
			continue
		}
		low := strings.ToLower(dllName)
		if _, dup := seen[low]; !dup {
			seen[low] = struct{}{}
			libs = append(libs, dllName)
		}
	}
	return libs
}

func peRVAToFileOffset(pf *pe.File, rva uint32) (int64, bool) {
	for _, s := range pf.Sections {
		if s.Offset == 0 {
			continue
		}
		span := s.VirtualSize
		if s.Size > span {
			span = s.Size
		}
		if rva >= s.VirtualAddress && rva-s.VirtualAddress < span {
			delta := rva - s.VirtualAddress
			if delta >= s.Size {
				return 0, false
			}
			return int64(s.Offset) + int64(delta), true
		}
	}
	return 0, false
}

func readCStringAt(r io.ReaderAt, offset int64, maxLen int) string {
	buf := make([]byte, maxLen)
	n, err := r.ReadAt(buf, offset)
	if err != nil && !errors.Is(err, io.EOF) && n == 0 {
		return ""
	}
	buf = buf[:n]
	if idx := bytes.IndexByte(buf, 0); idx >= 0 {
		buf = buf[:idx]
	}
	return string(buf)
}

func isWindowsSystemDLL(name string) bool {
	low := strings.ToLower(filepath.Base(name))
	if strings.HasPrefix(low, "api-ms-win-") || strings.HasPrefix(low, "ext-ms-win-") {
		return true
	}
	_, ok := windowsSystemDLLs[low]
	return ok
}

func inspectGoMetadata(r io.ReaderAt, hasGoSection bool) *GoDiag {
	bi, err := buildinfo.Read(r)
	if err != nil {
		if hasGoSection {
			return &GoDiag{Detected: true, BuildInfo: "stripped"}
		}
		return &GoDiag{Detected: false, BuildInfo: "absent"}
	}

	gd := &GoDiag{
		Detected:   true,
		BuildInfo:  "present",
		GoVersion:  bi.GoVersion,
		ModulePath: bi.Main.Path,
		ModuleVer:  bi.Main.Version,
	}
	for _, s := range bi.Settings {
		switch s.Key {
		case "CGO_ENABLED":
			gd.CGOEnabled = s.Value
		case "-buildmode":
			gd.BuildMode = s.Value
		case "-trimpath":
			if v, parseErr := strconv.ParseBool(s.Value); parseErr == nil {
				gd.Trimpath = &v
			}
		case "vcs", "vcs.revision", "vcs.time", "vcs.modified":
			gd.VCSPresent = true
		}
	}
	return gd
}

func formatBinaryDiag(w io.Writer, d *BinaryDiag) {
	_, _ = fmt.Fprintf(w, "File          : %s\n", d.Path)
	_, _ = fmt.Fprintf(w, "Format        : %s (%s, %s, %s-endian)\n", d.Format, d.Class, d.Arch, d.Endianness)
	_, _ = fmt.Fprintf(w, "Size          : %d bytes\n", d.SizeBytes)
	_, _ = fmt.Fprintf(w, "SHA256        : %s\n", d.SHA256)
	_, _ = fmt.Fprintf(w, "Linkage       : %s (static=%t, pie=%t, static_pie=%t)\n", d.Linkage, d.Static, d.PIE, d.StaticPIE)
	if d.EntryPoint != "" {
		_, _ = fmt.Fprintf(w, "Entry Point   : %s\n", d.EntryPoint)
	}
	if d.Subsystem != "" {
		_, _ = fmt.Fprintf(w, "Subsystem     : %s\n", d.Subsystem)
	}
	if d.Interpreter != "" {
		_, _ = fmt.Fprintf(w, "Interpreter   : %s\n", d.Interpreter)
	}
	if d.RELRO != "" {
		_, _ = fmt.Fprintf(w, "RELRO         : %s\n", d.RELRO)
	}
	if d.NX != nil {
		_, _ = fmt.Fprintf(w, "NX            : %t\n", *d.NX)
	}
	if d.HighEntASLR != nil {
		_, _ = fmt.Fprintf(w, "HighEnt ASLR  : %t\n", *d.HighEntASLR)
	}
	if d.CFG != nil {
		_, _ = fmt.Fprintf(w, "Guard CFG     : %t\n", *d.CFG)
	}
	if d.Signed != nil {
		_, _ = fmt.Fprintf(w, "Authenticode  : %t\n", *d.Signed)
	}
	_, _ = fmt.Fprintf(w, "Stripped      : %t (symtab=%t, debug=%t)\n", d.Stripped, d.HasSymtab, d.HasDebug)
	if len(d.NeededLibs) > 0 {
		_, _ = fmt.Fprintf(w, "Dependencies  : %s\n", strings.Join(d.NeededLibs, ", "))
	}
	if d.Format == "PE" {
		if len(d.NonSysDLLs) > 0 {
			_, _ = fmt.Fprintf(w, "Non-Sys DLLs  : %s\n", strings.Join(d.NonSysDLLs, ", "))
		} else {
			_, _ = fmt.Fprintf(w, "Non-Sys DLLs  : none\n")
		}
	}
	if d.Go != nil {
		switch d.Go.BuildInfo {
		case "present":
			mod := d.Go.ModulePath
			if mod == "" {
				mod = "(unknown)"
			}
			_, _ = fmt.Fprintf(w, "Go BuildInfo  : present (%s, module=%s", d.Go.GoVersion, mod)
			if d.Go.BuildMode != "" {
				_, _ = fmt.Fprintf(w, ", buildmode=%s", d.Go.BuildMode)
			}
			if d.Go.CGOEnabled != "" {
				_, _ = fmt.Fprintf(w, ", cgo=%s", d.Go.CGOEnabled)
			}
			if d.Go.Trimpath != nil {
				_, _ = fmt.Fprintf(w, ", trimpath=%t", *d.Go.Trimpath)
			}
			_, _ = fmt.Fprintf(w, ", vcs=%t)\n", d.Go.VCSPresent)
		case "stripped":
			_, _ = fmt.Fprintln(w, "Go BuildInfo  : stripped (Go runtime sections remain)")
		default:
			_, _ = fmt.Fprintln(w, "Go BuildInfo  : absent / non-Go")
		}
	}
}

func elfClassName(c elf.Class) string {
	switch c {
	case elf.ELFCLASS64:
		return "ELF64"
	case elf.ELFCLASS32:
		return "ELF32"
	default:
		return c.String()
	}
}

func elfDataName(d elf.Data) string {
	switch d {
	case elf.ELFDATA2LSB:
		return "little"
	case elf.ELFDATA2MSB:
		return "big"
	default:
		return d.String()
	}
}

func elfMachineName(m elf.Machine) string {
	switch m {
	case elf.EM_X86_64:
		return "x86_64"
	case elf.EM_386:
		return "x86"
	case elf.EM_AARCH64:
		return "arm64"
	case elf.EM_ARM:
		return "arm"
	case elf.EM_RISCV:
		return "riscv64"
	case elf.EM_PPC64:
		return "ppc64"
	case elf.EM_S390:
		return "s390x"
	default:
		return m.String()
	}
}

func peMachineName(m uint16) string {
	switch m {
	case pe.IMAGE_FILE_MACHINE_AMD64:
		return "x86_64"
	case pe.IMAGE_FILE_MACHINE_I386:
		return "x86"
	case pe.IMAGE_FILE_MACHINE_ARM64:
		return "arm64"
	case pe.IMAGE_FILE_MACHINE_ARMNT:
		return "arm"
	default:
		return fmt.Sprintf("0x%x", m)
	}
}

func peSubsystemName(sub uint16) string {
	switch sub {
	case peSubsystemNative:
		return "native"
	case peSubsystemWindowsGUI:
		return "gui"
	case peSubsystemWindowsCUI:
		return "console"
	default:
		return fmt.Sprintf("0x%x", sub)
	}
}
