// The save/switch/restore pattern libgfortran uses around each formatted I/O
// statement when uselocale is unavailable (libgfortran/io/transfer.c,
// data_transfer_init_worker / finalize_transfer, !HAVE_POSIX_2008_LOCALE).
//
// The C standard allows the string returned by setlocale(cat, NULL) to be
// overwritten by a later setlocale call. UCRT frees it; msvcrt and glibc's "C"
// happen to keep it alive.
//
// Exit code: 0 = pointer still valid and restore worked, 1 = bug observed.
// With a release CRT the symptom depends on heap reuse; build with MSVC /MTd
// (freed memory filled with 0xDD) or /fsanitize=address for a deterministic result.
#define _CRT_SECURE_NO_WARNINGS
#include <locale.h>
#include <stdio.h>
#include <string.h>

int main(void) {
  char *old_locale = setlocale(LC_NUMERIC, NULL);
  char saved_copy[256];
  strncpy(saved_copy, old_locale, sizeof saved_copy - 1);
  saved_copy[sizeof saved_copy - 1] = '\0';
  printf("saved:    %p \"%s\"\n", (void *)old_locale, saved_copy);

  setlocale(LC_NUMERIC, "C");
  int changed = strcmp(old_locale, saved_copy) != 0;
  printf("after C:  %p \"%s\"   <- same pointer, contents %s\n", (void *)old_locale, old_locale,
         changed ? "CHANGED" : "unchanged");

  char *restored = setlocale(LC_NUMERIC, old_locale);
  printf("restored: \"%s\"   (expected \"%s\")\n", restored ? restored : "(null: restore failed)", saved_copy);

  int bug = changed || restored == NULL || strcmp(restored, saved_copy) != 0;
  printf("%s\n", bug ? "BUG: saved locale pointer was invalidated" : "OK");
  return bug;
}
