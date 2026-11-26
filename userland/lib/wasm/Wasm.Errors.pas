{
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
}

{
  The errors the engine raises, one class for each way the spec lets a
  module or a call fail, so that an embedder can map them (the JS API:
  CompileError, LinkError, RuntimeError, RangeError):

    EWasmMalformed      the binary does not decode (spec: malformed)
    EWasmInvalid        it decodes but does not validate (invalid)
    EWasmLinkError      instantiation finds an import missing or of the
                        wrong kind or type (unlinkable)
    EWasmTrap           execution traps; Kind says why, StackTrace where
    EWasmResourceError  an implementation limit at run time: a memory or
                        table that cannot be allocated

  The messages follow the reference interpreter's wording where the spec
  tests look at them ("type mismatch", "out of bounds memory access").
}
unit Wasm.Errors;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  EWasmError = class(Exception);

  EWasmMalformed = class(EWasmError)
  public
    Offset: SizeInt;
    constructor CreateAt(AOffset: SizeInt; const AMessage: AnsiString);
  end;

  EWasmInvalid = class(EWasmError)
  public
    Offset: SizeInt;
    constructor CreateAt(AOffset: SizeInt; const AMessage: AnsiString);
  end;

  EWasmLinkError = class(EWasmError);
  EWasmResourceError = class(EWasmError);

  TWasmTrapKind = (
    tkUnreachable,
    tkIntegerDivideByZero,
    tkIntegerOverflow,
    tkInvalidConversion,
    tkMemoryOutOfBounds,
    tkTableOutOfBounds,
    tkIndirectCallTypeMismatch,
    tkUndefinedElement,
    tkUninitializedElement,
    tkCallStackExhausted,
    tkInterrupted,
    tkHostError
  );

  { One frame of a trap's stack trace, innermost first: the function's
    index in its module, its name from the name section ('' if none) and
    the byte offset in the module of the instruction that was running. }
  TWasmStackFrame = record
    FunctionIndex: Cardinal;
    FunctionName: AnsiString;
    ModuleName: AnsiString;
    ByteOffset: SizeInt;
  end;
  TWasmStackTrace = array of TWasmStackFrame;

  EWasmTrap = class(EWasmError)
  public
    Kind: TWasmTrapKind;
    StackTrace: TWasmStackTrace;
    constructor CreateTrap(AKind: TWasmTrapKind; const AMessage: AnsiString = '');
    { The trace as text, one "at name (wasm-function[i]:0xoffset)" line
      per frame. }
    function StackTraceText: AnsiString;
  end;

function TrapKindMessage(Kind: TWasmTrapKind): AnsiString;

implementation

constructor EWasmMalformed.CreateAt(AOffset: SizeInt; const AMessage: AnsiString);
begin
  inherited Create(AMessage);
  Offset := AOffset;
end;

constructor EWasmInvalid.CreateAt(AOffset: SizeInt; const AMessage: AnsiString);
begin
  inherited Create(AMessage);
  Offset := AOffset;
end;

function TrapKindMessage(Kind: TWasmTrapKind): AnsiString;
begin
  case Kind of
    tkUnreachable: Result := 'unreachable';
    tkIntegerDivideByZero: Result := 'integer divide by zero';
    tkIntegerOverflow: Result := 'integer overflow';
    tkInvalidConversion: Result := 'invalid conversion to integer';
    tkMemoryOutOfBounds: Result := 'out of bounds memory access';
    tkTableOutOfBounds: Result := 'out of bounds table access';
    tkIndirectCallTypeMismatch: Result := 'indirect call type mismatch';
    tkUndefinedElement: Result := 'undefined element';
    tkUninitializedElement: Result := 'uninitialized element';
    tkCallStackExhausted: Result := 'call stack exhausted';
    tkInterrupted: Result := 'execution interrupted';
  else
    Result := 'host error';
  end;
end;

constructor EWasmTrap.CreateTrap(AKind: TWasmTrapKind; const AMessage: AnsiString);
begin
  if AMessage = '' then
    inherited Create(TrapKindMessage(AKind))
  else
    inherited Create(AMessage);
  Kind := AKind;
end;

function EWasmTrap.StackTraceText: AnsiString;
var
  Index: Integer;
  Name: AnsiString;
begin
  Result := '';
  for Index := 0 to High(StackTrace) do
  begin
    Name := StackTrace[Index].FunctionName;
    if Name = '' then
      Name := Format('wasm-function[%d]', [StackTrace[Index].FunctionIndex]);
    Result := Result + Format('    at %s (wasm-function[%d]:0x%x)', [Name, StackTrace[Index].FunctionIndex,
      StackTrace[Index].ByteOffset]) + LineEnding;
  end;
end;

end.
