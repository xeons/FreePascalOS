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
  The runtime: what all realms of one engine share.

  The heap, the atom table, the root shape, the well-known symbols, the
  one-character strings, the exception being thrown, the interrupt
  request and the temporary roots of native code.

  An exception travels as JsException returned up the calls, the value
  thrown waiting here (Exception). Termination - an interrupt, the
  memory limit - is an exception that no catch or finally stops
  (Terminating).

  Temporary roots: native code that holds a value in a Pascal variable
  across anything that may run JavaScript pushes it here
  (Mark := PushRoot(V); ... PopRoots(Mark)) so a collection keeps it.
}
unit Js.Runtime;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  Js.Values,
  Js.Heap,
  Js.Strings,
  Js.Symbols,
  Js.Atoms,
  Js.Shapes;

type
  TJsRuntime = class
  private
    FTempRoots: TJsValueList;
    FTempRootCount: Integer;
    FCharacterStrings: array[0..255] of TJsString;
    procedure MarkRoots(Tracer: TJsTracer);
  public
    Heap: TJsHeap;
    Atoms: TJsAtomTable;
    RootShape: TJsShape;
    WellKnownSymbols: array[TJsWellKnownSymbol] of TJsSymbol;
    EmptyString: TJsString;
    { The value being thrown, while HasException. }
    Exception: TJsValue;
    HasException: Boolean;
    { The exception is an uncatchable termination. }
    Terminating: Boolean;
    { Set by any thread to stop the running script at its next check. }
    InterruptRequested: LongBool;
    { Bumped when a prototype gains an accessor or read-only property or
      an object's prototype changes: caches of property additions that
      assumed no setter on the chain compare it. }
    PrototypeEpoch: LongWord;
    constructor Create;
    destructor Destroy; override;
    function PushRoot(Value: TJsValue): Integer;
    procedure PopRoots(Mark: Integer); inline;
    { Replaces a pushed root's value. }
    procedure SetRoot(Index: Integer; Value: TJsValue); inline;
    function CharacterString(Code: Word): TJsString;
    function Intern(const Text: string): TJsValue;
    function AtomValue(Name: TJsAtomName): TJsValue; inline;
    function SymbolValue(Symbol: TJsWellKnownSymbol): TJsValue; inline;
    function NewString(const Text: string): TJsValue;
    function NewStringValue(Text: TJsString): TJsValue; inline;
    { Takes the pending exception. }
    function TakeException: TJsValue;
  end;

function JsAsString(Value: TJsValue): TJsString; inline;
function JsStringValue(Text: TJsString): TJsValue; inline;

implementation

function JsAsString(Value: TJsValue): TJsString;
begin
  Result := TJsString(Pointer(PtrUInt(Value and JsPayloadMask)));
end;

function JsStringValue(Text: TJsString): TJsValue;
begin
  Result := JsStringBase or QWord(PtrUInt(Text));
end;

constructor TJsRuntime.Create;
var
  Symbol: TJsWellKnownSymbol;
begin
  inherited Create;
  Heap := TJsHeap.Create;
  Atoms := TJsAtomTable.Create(Heap);
  RootShape := NewRootShape(Heap);
  EmptyString := Atoms.Name(anEmpty);
  for Symbol := Low(TJsWellKnownSymbol) to High(TJsWellKnownSymbol) do
    WellKnownSymbols[Symbol] := NewSymbol(Heap, Atoms.InternUtf8('Symbol.' + WellKnownSymbolNames[Symbol]));
  Heap.AddRootProvider(@MarkRoots);
  Exception := JsUndefined;
end;

destructor TJsRuntime.Destroy;
begin
  Atoms.Free;
  Heap.Free;
  inherited Destroy;
end;

procedure TJsRuntime.MarkRoots(Tracer: TJsTracer);
var
  Symbol: TJsWellKnownSymbol;
  Index: Integer;
begin
  Tracer.MarkCell(RootShape);
  for Symbol := Low(TJsWellKnownSymbol) to High(TJsWellKnownSymbol) do
    Tracer.MarkCell(WellKnownSymbols[Symbol]);
  for Index := 0 to 255 do
    if FCharacterStrings[Index] <> nil then
      Tracer.MarkCell(FCharacterStrings[Index]);
  Tracer.MarkValue(Exception);
  Tracer.MarkValues(@FTempRoots[0], FTempRootCount);
end;

function TJsRuntime.PushRoot(Value: TJsValue): Integer;
begin
  Result := FTempRootCount;
  if FTempRootCount >= Length(FTempRoots) then
    SetLength(FTempRoots, Length(FTempRoots) * 2 + 64);
  FTempRoots[FTempRootCount] := Value;
  Inc(FTempRootCount);
end;

procedure TJsRuntime.PopRoots(Mark: Integer);
begin
  FTempRootCount := Mark;
end;

procedure TJsRuntime.SetRoot(Index: Integer; Value: TJsValue);
begin
  FTempRoots[Index] := Value;
end;

function TJsRuntime.CharacterString(Code: Word): TJsString;
var
  Unit16: Word;
begin
  if Code < 256 then
  begin
    if FCharacterStrings[Code] = nil then
    begin
      Unit16 := Code;
      FCharacterStrings[Code] := Atoms.Intern(NewUtf16String(Heap, @Unit16, 1));
    end;
    Exit(FCharacterStrings[Code]);
  end;
  Unit16 := Code;
  Result := NewUtf16String(Heap, @Unit16, 1);
end;

function TJsRuntime.Intern(const Text: string): TJsValue;
begin
  Result := JsStringValue(Atoms.InternUtf8(Text));
end;

function TJsRuntime.AtomValue(Name: TJsAtomName): TJsValue;
begin
  Result := JsStringValue(Atoms.Name(Name));
end;

function TJsRuntime.SymbolValue(Symbol: TJsWellKnownSymbol): TJsValue;
begin
  Result := JsSymbolValue(WellKnownSymbols[Symbol]);
end;

function TJsRuntime.NewString(const Text: string): TJsValue;
begin
  Result := JsStringValue(NewStringFromUtf8(Heap, Text));
end;

function TJsRuntime.NewStringValue(Text: TJsString): TJsValue;
begin
  Result := JsStringValue(Text);
end;

function TJsRuntime.TakeException: TJsValue;
begin
  Result := Exception;
  Exception := JsUndefined;
  HasException := False;
end;

end.
