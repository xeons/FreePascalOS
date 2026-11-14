{
  Error codes and their messages.

  System calls report failure as a negative result; the error code is
  the negated value. These messages follow the wording Unix users know.
}
unit Sys.Errors;

{$mode objfpc}

interface

{ Turns a negative system call result into its error code (0 if the
  result is not an error). }
function ErrorCodeOf(CallResult: Int64): LongInt;

function ErrorMessage(Code: LongInt): PChar;

implementation

uses
  Abi.SystemCalls;

function ErrorCodeOf(CallResult: Int64): LongInt;
begin
  if CallResult < 0 then
    Result := LongInt(-CallResult)
  else
    Result := 0;
end;

{$include Abi.ErrorMessages.inc}

function ErrorMessage(Code: LongInt): PChar;
begin
  Result := AbiErrorMessage(Code);
end;

end.
