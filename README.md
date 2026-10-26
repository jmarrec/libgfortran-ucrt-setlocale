# libgfortran: use-after-free of the saved `LC_NUMERIC` name on UCRT

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
overwritten by a later `setlocale` call. UCRT frees it when the category
changes, so the restore reads freed memory. msvcrt (and glibc for `"C"`) happen
to keep the string alive, which is why this went unnoticed.

## Consequences with MinGW-w64 UCRT builds of gfortran

- After the first formatted I/O statement, the restore through the dangling
  pointer typically lands on the user's locale (here `English_United States.1252`)
  instead of `"C"`. The process `LC_NUMERIC` stays wrong for any C code in the
  same process.
- From then on every I/O statement performs two real locale switches
  (user → C → user). Measured cost: about 2.5 µs/statement with msvcrt vs
  6.8 µs/statement with UCRT (GCC 16.2.0). An I/O-heavy program
  (EnergyPlus `ReadVarsESO`) runs about 3x slower.
- With the debug CRT the restore fails instead (`NULL`). With ASan it is
  reported as `heap-use-after-free`, freed in `ucrt\src\appcrt\locale\setlocale.cpp`.

## Files

| File | What it shows | Exit code |
|---|---|---|
| `mcve.f90` | One `write(buf,'(I0)')` changes the process `LC_NUMERIC`; times internal writes | 1 = bug |
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

With a release CRT (`/MT`, or MinGW-w64 UCRT) the symptom depends on whether
the freed block has been reused, so `mcve.c` can occasionally print `OK`. The
`/MTd` and ASan builds are deterministic.

On Compiler Explorer, use `x64 msvc v19.latest` with `/MTd`. ASan does not run
there, because the ASan runtime DLL is missing (`0xC0000135`).

## Expected results

| Toolchain | `mcve.f90` | `mcve.c` |
|---|---|---|
| MinGW-w64 GCC 16.2.0 posix-seh-**ucrt** | BUG (`LC_NUMERIC` → user locale) | BUG |
| MinGW-w64 GCC 16.2.0 posix-seh-**msvcrt** | OK | OK |
| MSVC `/MT` | — | BUG (heap dependent) |
| MSVC `/MTd` | — | BUG (restore returns `NULL`) |
| MSVC `/fsanitize=address` | — | heap-use-after-free |
| Linux glibc | not affected (`uselocale` path) | OK (`"C"` is a static string) |

## Suggested fix

Copy the name before switching, for example into a static buffer guarded by
`old_locale_lock`:

```c
static char old_locale_buf[256];  // replaces the char *old_locale
...
if (!old_locale_ctr++)
  {
    strncpy (old_locale_buf, setlocale (LC_NUMERIC, NULL), sizeof old_locale_buf - 1);
    setlocale (LC_NUMERIC, "C");
  }
...
if (!--old_locale_ctr)
  setlocale (LC_NUMERIC, old_locale_buf);
```

On Windows, `_configthreadlocale(_ENABLE_PER_THREAD_LOCALE)` together with
`_create_locale`/`_free_locale` would avoid the global switch altogether (and
the race with other threads calling `setlocale`).

## Background

Found while investigating the slower `ReadVarsESO` in EnergyPlus 25.2, which is
built with MinGW-w64 GCC 14.2 UCRT instead of GCC 8.1 msvcrt:
<https://github.com/NatLabRockies/EnergyPlus/issues/11876>.
