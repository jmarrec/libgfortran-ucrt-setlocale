# libgfortran: formatted I/O restores `LC_NUMERIC` through an invalidated pointer (MinGW-w64)

[![mcve](https://github.com/jmarrec/libgfortran-ucrt-setlocale/actions/workflows/mcve.yml/badge.svg)](https://github.com/jmarrec/libgfortran-ucrt-setlocale/actions/workflows/mcve.yml)
(failing = bug reproduced)

On targets without `uselocale` (MinGW-w64), libgfortran wraps every formatted
I/O statement in a global locale switch (`libgfortran/io/transfer.c`,
`#ifndef HAVE_POSIX_2008_LOCALE` branches, unchanged on trunk as of 2026-10):

```c
// data_transfer_init_worker()
old_locale = setlocale (LC_NUMERIC, NULL);   // keeps the returned pointer, no copy
setlocale (LC_NUMERIC, "C");
...
// finalize_transfer()
setlocale (LC_NUMERIC, old_locale);          // restores through that pointer
```

C11 7.11.1.1p8 allows the string returned by `setlocale(cat, NULL)` to be
overwritten by a later `setlocale` call. Both Windows C runtimes invalidate it,
in different ways:

- **msvcrt** returns a static buffer that `setlocale(LC_NUMERIC, "C")`
  overwrites with `"C"`. So libgfortran always "restores" `"C"`: a program that
  set a non-C `LC_NUMERIC` is silently reset to `"C"` by its first formatted I/O
  statement. This is deterministic. It goes unnoticed because most programs
  never call `setlocale`, so the locale is `"C"` anyway.
- **UCRT** returns a heap buffer and frees it on the next `setlocale` call
  (even a query: consecutive `setlocale(LC_NUMERIC, NULL)` calls alternate
  between two buffers). So the restore reads freed memory on every formatted
  I/O statement.

## Consequences with MinGW-w64 UCRT builds of gfortran

- What a restore through freed memory does depends on what the memory holds:
  - The garbage may resolve to the user's locale (here `English_United States.1252`),
    even when the program never called `setlocale`. The process `LC_NUMERIC` then
    stays wrong for any C code in the same process, and every later statement
    performs two real locale switches (user → C → user).
  - Or the restore fails (`NULL`) and the locale stays `"C"`. This was seen on
    GitHub's `windows-latest` runners.
  - Or the freed memory still holds the old name, and the restore works by luck.
- UCRT's `setlocale` is also much more expensive than msvcrt's. Measured per
  internal write with GCC 16.2.0: 2.5 µs (msvcrt) vs 6.8 µs (UCRT, user-locale
  case) locally, and 1.0 µs vs 2.5 µs (UCRT, failed-restore case) on GitHub
  runners. An I/O-heavy program (EnergyPlus `ReadVarsESO`) runs about 3x slower.
- With the debug CRT the restore fails (`NULL`). With ASan it is reported as
  `heap-use-after-free`, freed in `ucrt\src\appcrt\locale\setlocale.cpp`.

## Files

| File | What it shows | Exit code |
|---|---|---|
| `mcve.f90` | (1) From the default `"C"` locale: whether one `write` changes `LC_NUMERIC`, and the cost per internal write. (2) From `LC_NUMERIC` = `French`: whether each of 1000 `write` statements leaves it unchanged | 1 = bug |
| `mcve.c` | The exact save/switch/restore sequence, without Fortran | 1 = bug |
| `.github/workflows/mcve.yml` | Runs both against niXman mingw-builds GCC 16.2.0 (`posix-seh-ucrt`, `posix-seh-msvcrt`) and the C MCVE against MSVC | failing job = bug reproduced |

## Run locally

MinGW-w64 (pick a `ucrt` and an `msvcrt` build from
<https://github.com/niXman/mingw-builds-binaries/releases>):

```sh
gfortran -O2 -static mcve.f90 -o mcve_f.exe && ./mcve_f.exe
gcc -O2 -static mcve.c -o mcve_c.exe && ./mcve_c.exe
```

MSVC (UCRT), from a "x64 Native Tools" prompt:

```bat
cl /nologo /MTd mcve.c && mcve.exe                     :: deterministic: freed memory is 0xDD
cl /nologo /Zi /fsanitize=address mcve.c && mcve.exe   :: heap-use-after-free report
```

### How the checks avoid depending on luck

- `mcve.f90` part (2) calls a function in the output list
  (`write(buf, '(I0,A)') i, clobber()`). gfortran evaluates it inside the
  transfer, after libgfortran switched to `"C"` (freeing the saved name with
  UCRT) and before it restores. `clobber()` allocates and fills small heap
  blocks, so the freed name is reliably garbage by the time libgfortran
  restores through it. Over 10 runs: stock UCRT restored correctly 0/1000 every
  time, msvcrt 0/1000 (always `"C"`), patched libgfortran 1000/1000.
- `mcve.c` compares the pointer returned by `setlocale(LC_NUMERIC, "C")` with
  the saved one, which never reads freed memory. That was 20/20 with MinGW-w64
  UCRT and MSVC `/MT`, and 0/20 with msvcrt. Do not add a
  `setlocale(LC_NUMERIC, NULL)` query in between. UCRT then allocates at the
  just-freed address, which hides the symptoms.

On Compiler Explorer, use `x64 msvc v19.latest` with `/MTd`. ASan does not run
there, because the ASan runtime DLL is missing (`0xC0000135`).

## Results

### CI, first version of `mcve.f90`

Observed on GitHub `windows-latest`, commit `c33d076`, 2026-10-26
([run 40340157299](https://github.com/jmarrec/libgfortran-ucrt-setlocale/actions/runs/40340157299);
Actions logs expire after 90 days, so the key output is reproduced here). At
that commit `mcve.f90` only had the default-locale check, plus a name-buffer
address check. That address check was dropped later because the patched
libgfortran's own query also moves the buffer under UCRT.

| Toolchain | Program | Expected | Observed |
|---|---|---|---|
| MinGW-w64 GCC 16.2.0 posix-seh-**ucrt** | `mcve.f90` | BUG | BUG: name buffer replaced (`…ADE44` → `…B1334`), `LC_NUMERIC` stayed `"C"`, 2185 ns/stmt |
| | `mcve.c` | BUG | BUG: buffer replaced, stale contents `"m\x02"`, restore returned `NULL` |
| MinGW-w64 GCC 16.2.0 posix-seh-**msvcrt** | `mcve.f90` | OK at that commit (the `French` check did not exist yet) | OK: same static buffer throughout, 925 ns/stmt |
| | `mcve.c` | OK | OK |
| MSVC `/O2 /MT` | `mcve.c` | BUG | BUG: buffer replaced. The stale contents still read `"C"` and the restore "worked", so only the address check catches it here |
| MSVC `/MTd` | `mcve.c` | BUG | BUG: stale contents `0xDD` fill, restore returned `NULL` |
| MSVC `/Zi /fsanitize=address` | `mcve.c` | heap-use-after-free | heap-use-after-free (below) |
| Linux glibc | either | not affected | not run in CI. libgfortran takes the `uselocale` path, and `"C"` is a static string |

AddressSanitizer output (MSVC, same run):

```
ERROR: AddressSanitizer: heap-use-after-free on address 0x12153e9a0194
SUMMARY: AddressSanitizer: heap-use-after-free D:\a\libgfortran-ucrt-setlocale\libgfortran-ucrt-setlocale\mcve.c:29 in main
```

### Locally, current `mcve.f90`, with and without the fix

Windows 10, user locale `English_United States.1252`, GCC 16.2.0. "Patched" is
niXman's UCRT `libgfortran.a` with `io/transfer.o` and `io/unit.o` rebuilt from
16.2.0 sources plus the fix below.

| Build | Default `"C"`: after one I/O | From `French`: restored correctly | ns per internal write | Exit |
|---|---|---|---|---|
| UCRT, stock | `English_United States.1252` | 0/1000 | 6845 | 1 (bug) |
| UCRT, **patched** | `C` | 1000/1000 | **1795** | 0 |
| msvcrt, stock | `C` | 0/1000 (reset to `"C"`) | 2931 | 1 (bug) |

EnergyPlus `ReadVarsESO` on an annual 5ZoneAirCooled ESO (11.5 MB), median of
8 runs, identical CSV output:

| Build | Median | vs 25.1 |
|---|---|---|
| GCC 16.2 UCRT + patched libgfortran | **2.98 s** | 0.86x |
| EnergyPlus 25.1 shipped (GCC 8.1 msvcrt) | 3.47 s | 1.00x |
| GCC 16.2 msvcrt, stock | 4.04 s | 1.17x |
| GCC 16.2 UCRT, stock | 11.10 s | 3.20x |

## Fix

Copy the name, and skip the switch when `LC_NUMERIC` is already `"C"` (the
common case), which saves two `setlocale` calls per data transfer statement:

```diff
       if (!old_locale_ctr++)
 	{
-	  old_locale = setlocale (LC_NUMERIC, NULL);
-	  setlocale (LC_NUMERIC, "C");
+	  /* The next setlocale call may free this string; keep a copy.  */
+	  const char *cur_locale = setlocale (LC_NUMERIC, NULL);
+	  if (cur_locale != NULL && strcmp (cur_locale, "C") != 0)
+	    {
+	      old_locale = strdup (cur_locale);
+	      setlocale (LC_NUMERIC, "C");
+	    }
 	}
 ...
-  if (!--old_locale_ctr)
+  if (!--old_locale_ctr && old_locale != NULL)
     {
       setlocale (LC_NUMERIC, old_locale);
+      free (old_locale);
       old_locale = NULL;
     }
```

On Windows, `_configthreadlocale(_ENABLE_PER_THREAD_LOCALE)` together with
`_create_locale`/`_free_locale` would avoid the global switch altogether (and
the race with other threads calling `setlocale`).

## Background

Found while investigating the slower `ReadVarsESO` in EnergyPlus 25.2, which is
built with MinGW-w64 GCC 14.2 UCRT instead of GCC 8.1 msvcrt:
<https://github.com/NatLabRockies/EnergyPlus/issues/11876>.
