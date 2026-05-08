# sloppyscripts
Collection of "Vibe" scripts i use for various purposes. 

## encode_av1_qsv.sh

This is a **batch video re-encoder** that converts video files using GPU acceleration via QSV (Quick Sync Video) to 10-Bit AV1.

It's designed to run unattended on large media libraries.

### Core Functionality

**Input:** Scans a directory (recursively by default) for video files (MKV, MP4, MOV, AVI, TS, M2TS, WMV, FLV, WEBM, MPG, MPEG, M4V)

**Processing:**
- Skips files already in HVEC encoding (unless `--include-hevc`)
- Uses Intel QSV hardware encoding for fast, efficient re-encoding
- Preserves all subtitles, chapters, metadata, and HDR information
- Detects HDR formats (Dolby Vision, HDR10+, HDR10) and reports them
- Falls back to software decoding for edge cases (10-bit H.264, variable resolution)
- Tests filter compatibility before full encode to prevent silent failures

**Output:** Replaces source files in-place (or writes to separate directory with `--outdir`)

### Key Features

| Feature | Benefit |
|---------|---------|
| **Quality control** | Only keeps encodes that save ≥10% file size (configurable); auto-skips poor candidates |
| **Persistent skip list** | Remembers files that won't compress well, avoiding retry on future runs |
| **Live ETA** | Shows time remaining based on average encode speed of completed files |
| **Graceful error handling** | Continues on encode failures, path length errors, permission issues |
| **HDR preservation** | Detects and preserves HDR metadata in output container |
| **Variable resolution** | Automatically falls back to software decode if file has mid-stream resolution changes |
| **Dry-run mode** | Preview what would be encoded without actually encoding |
| **Debug diagnostics** | Full system info, FFmpeg versions, DRI device check, QSV smoke-test |
| **NFS-safe moves** | Falls back to cp+rm for cross-filesystem moves (NFS shares) |

### Typical Use Cases

1. **Compress large media libraries** — Re-encode your entire movie/show collection to AV1 for ~30-50% space savings
2. **Future-proof archival** — Convert older formats (H.264, HEVC) to modern, efficient AV1 codec
3. **Storage optimization** — Run overnight on a dedicated encode box; frees up disk space without quality loss
4. **Server archival** — To consolidate all video files to a single codec

### Example Workflows

```bash
# Encode entire library in-place (replaces source files)
./encode_av1_qsv.sh /mnt/media/movies

# Encode to separate directory (keeps originals)
./encode_av1_qsv.sh --outdir /mnt/archive /mnt/media/movies

# Include HEVC sources (by default skipped)
./encode_av1_qsv.sh --include-hevc /mnt/media

# Shallow scan (don't recurse subdirs)
./encode_av1_qsv.sh --shallow /mnt/media

# Preview what would be encoded
./encode_av1_qsv.sh --dry-run /mnt/media

# Full debug diagnostics
./encode_av1_qsv.sh --debug /mnt/media/one_file.mkv

# Encoding with settings persistence
./encode_av1_qsv.sh /mnt/media  # First run
./encode_av1_qsv.sh /mnt/media  # Resumes, skips completed + failed files
