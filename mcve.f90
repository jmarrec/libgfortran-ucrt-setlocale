! libgfortran (no uselocale, e.g. MinGW-w64) saves the pointer returned by
! setlocale(LC_NUMERIC, NULL) and restores through it after setlocale(LC_NUMERIC, "C").
! With UCRT that pointer dangles: after one formatted I/O statement the process
! LC_NUMERIC is no longer "C", and every later I/O statement pays for two real
! locale switches.
!
! gfortran -O2 -static mcve.f90 -o mcve.exe && mcve.exe
! Exit code: 0 = LC_NUMERIC unchanged, 1 = bug observed.
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
  end interface
  integer(c_int), parameter :: LC_NUMERIC = 4  ! Windows value
  integer, parameter :: n = 200000
  character(len=32) :: buf
  character(len=:), allocatable :: before, after
  integer :: i
  integer(8) :: c0, c1, rate

  ! query outside of any I/O statement: during a transfer libgfortran forces "C"
  before = numeric_locale()
  write(buf, '(I0)') 1
  after = numeric_locale()
  print '(A,A)', 'LC_NUMERIC before any I/O: ', before
  print '(A,A)', 'LC_NUMERIC after one I/O:  ', after

  call system_clock(c0, rate)
  do i = 1, n
    write(buf, '(I0)') i
  end do
  call system_clock(c1)
  print '(A,F7.0,A)', 'internal write: ', real(c1 - c0, 8) / rate / n * 1.0d9, ' ns/stmt'

  if (after /= before) then
    print '(A)', 'BUG: one formatted I/O statement changed the process LC_NUMERIC'
    stop 1
  end if
  print '(A)', 'OK'

contains
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
