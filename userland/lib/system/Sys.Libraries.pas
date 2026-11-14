{
  Loading shared libraries at run time.

  LoadLibrary maps a shared library (and the libraries it needs) into the
  program; a bare name such as 'libplugin.so' is looked for in /lib.
  FindSymbol returns the address of an exported symbol, which can be cast
  to a procedure or function type of the right signature.

  Free Pascal exports routines under mangled names; a library meant for
  run time loading should give its entry points plain names with
  "public name '...'" or "alias".
}
unit Sys.Libraries;

{$mode objfpc}

interface

{ Returns a library handle (zero or more) or a negative error code. }
function LoadLibrary(Name: PChar): Int64;
{ Returns nil if the symbol does not exist. }
function FindSymbol(LibraryHandle: Int64; Name: PChar): Pointer;

implementation

uses
  Sys.Kernel;

function LoadLibrary(Name: PChar): Int64;
begin
  Result := KernelLoadLibrary(Name);
end;

function FindSymbol(LibraryHandle: Int64; Name: PChar): Pointer;
var
  Address: Int64;
begin
  Address := KernelFindSymbol(LibraryHandle, Name);
  if Address <= 0 then
    Result := nil
  else
    Result := Pointer(Address);
end;

end.
