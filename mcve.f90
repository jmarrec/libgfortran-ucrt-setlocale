! libgfortran (no uselocale, e.g. MinGW-w64) saves the pointer returned by
! setlocale(LC_NUMERIC, NULL) and restores through it after setlocale(LC_NUMERIC, "C").
! With UCRT that pointer dangles (UCRT frees it on the next setlocale call, even
! a query), so the restore after each formatted I/O statement reads freed memory.
!
! Whether a given restore lands on the right locale, on another one (e.g. the
! user locale) or fails (locale stays "C") depends on what the freed memory
! holds. So the check starts from a non-"C" locale and verifies, over many I/O
! statements, that each one leaves LC_NUMERIC exactly as it found it.
!
! gfortran -O2 -static mcve.f90 -o mcve.exe && mcve.exe
! Exit code: 0 = OK, 1 = bug observed, 2 = test locale unavailable.
program mcve
  use iso_c_binding
  implicit none
  interface
    function setlocale(category, locale) bind(C, name='setlocale')
      import :: c_int, c_ptr
      integer(c_int), value :: category
      type(c_ptr), value :: locale
      type(c_ptr) :: setlocale
    end function setlocale
    function strlen(s) bind(C, name='strlen')
      import :: c_ptr, c_size_t
      type(c_ptr), value :: s
      integer(c_size_t) :: strlen
    end function strlen
    function malloc(size) bind(C, name='malloc')
      import :: c_ptr, c_size_t
      integer(c_size_t), value :: size
      type(c_ptr) :: malloc
    end function malloc
    subroutine free(p) bind(C, name='free')
      import :: c_ptr
      type(c_ptr), value :: p
    end subroutine free
    function memset(p, c, n) bind(C, name='memset')
      import :: c_ptr, c_int, c_size_t
      type(c_ptr), value :: p
      integer(c_int), value :: c
      integer(c_size_t), value :: n
      type(c_ptr) :: memset
    end function memset
  end interface
  integer(c_int), parameter :: LC_NUMERIC = 4  ! Windows value
  integer, parameter :: n = 200000, ncheck = 1000
  character(len=32) :: buf
  character(kind=c_char, len=:), allocatable, target :: cname
  character(len=:), allocatable :: before, after_one, expected, current, first_bad
  integer :: i, nbad
  integer(8) :: c0, c1, rate

  ! 1) default "C" locale: what one statement leaves behind, and the cost per statement.
  ! Query outside of any I/O statement: during a transfer libgfortran forces "C".
  before = numeric_locale()
  write(buf, '(I0)') 1
  after_one = numeric_locale()
  print '(A,A)', 'LC_NUMERIC before any I/O: ', before
  print '(A,A)', 'LC_NUMERIC after one I/O:  ', after_one

  call system_clock(c0, rate)
  do i = 1, n
    write(buf, '(I0)') i
  end do
  call system_clock(c1)
  print '(A,F7.0,A)', 'internal write: ', real(c1 - c0, 8) / rate / n * 1.0d9, ' ns/stmt'

  ! 2) start from a non-"C" locale, which libgfortran has to switch away from and restore
  cname = 'French' // c_null_char
  if (.not. c_associated(setlocale(LC_NUMERIC, c_loc(cname)))) then
    print '(A)', 'SKIP: setlocale(LC_NUMERIC, "French") failed'
    stop 2
  end if
  expected = numeric_locale()
  cname = expected // c_null_char
  nbad = 0
  do i = 1, ncheck
    ! clobber() runs inside the transfer, between libgfortran's switch to "C"
    ! (which frees the saved name with UCRT) and its restore
    write(buf, '(I0,A)') i, clobber()
    current = numeric_locale()
    if (current /= expected) then
      if (nbad == 0) first_bad = current
      nbad = nbad + 1
      if (.not. c_associated(setlocale(LC_NUMERIC, c_loc(cname)))) stop 3
    end if
  end do
  print '(A,A,A,I0,A,I0,A)', 'LC_NUMERIC "', expected, '" restored correctly after ', &
    ncheck - nbad, '/', ncheck, ' I/O statements'

  if (after_one /= before) then
    print '(A)', 'BUG: one formatted I/O statement changed the process LC_NUMERIC'
    stop 1
  end if
  if (nbad > 0) then
    print '(A,A,A)', 'BUG: libgfortran restored the wrong LC_NUMERIC (first: "', first_bad, '")'
    stop 1
  end if
  print '(A)', 'OK'

contains
  ! Reuse freed small heap blocks and fill them, so that a restore through a
  ! freed locale name sees garbage instead of the old contents.
  function clobber() result(s)
    character(len=1) :: s
    type(c_ptr) :: blocks(256), unused
    integer :: k
    integer(c_size_t) :: sz
    do k = 1, size(blocks)
      sz = int(8 + mod(k, 64), c_size_t)
      blocks(k) = malloc(sz)
      unused = memset(blocks(k), ichar('Z'), sz)
    end do
    do k = 1, size(blocks)
      call free(blocks(k))
    end do
    s = ' '
  end function clobber

  function numeric_locale() result(name)
    character(len=:), allocatable :: name
    type(c_ptr) :: p
    character(kind=c_char), pointer :: chars(:)
    integer :: k
    p = setlocale(LC_NUMERIC, c_null_ptr)
    call c_f_pointer(p, chars, [strlen(p)])
    allocate(character(len=size(chars)) :: name)
    do k = 1, size(chars)
      name(k:k) = chars(k)
    end do
  end function numeric_locale
end program mcve
