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
  Symbols: unique property keys with an optional description.

  Private names (#field) are symbols too, marked private: they key
  properties like any symbol, but no reflection (Object.keys,
  getOwnPropertySymbols, Reflect.ownKeys, proxies) ever sees them.
  Symbols made by Symbol.for keep their registry key.
}
unit Js.Symbols;

{$mode objfpc}{$H+}

interface

uses
  Js.Values,
  Js.Heap,
  Js.Strings;

type
  TJsSymbol = class(TJsCell)
  public
    Description: TJsString;
    IsPrivate: Boolean;
    IsRegistered: Boolean;
    procedure Trace(Tracer: TJsTracer); override;
  end;

  { The well-known symbols (Symbol.iterator and the others). }
  TJsWellKnownSymbol = (
    wsAsyncIterator, wsHasInstance, wsIsConcatSpreadable, wsIterator, wsMatch,
    wsMatchAll, wsReplace, wsSearch, wsSpecies, wsSplit, wsToPrimitive,
    wsToStringTag, wsUnscopables);

const
  WellKnownSymbolNames: array[TJsWellKnownSymbol] of string = (
    'asyncIterator', 'hasInstance', 'isConcatSpreadable', 'iterator', 'match',
    'matchAll', 'replace', 'search', 'species', 'split', 'toPrimitive',
    'toStringTag', 'unscopables');

function NewSymbol(Heap: TJsHeap; Description: TJsString): TJsSymbol;
function JsSymbolValue(Symbol: TJsSymbol): TJsValue; inline;
function JsAsSymbol(Value: TJsValue): TJsSymbol; inline;

implementation

procedure TJsSymbol.Trace(Tracer: TJsTracer);
begin
  if Description <> nil then
    Tracer.MarkCell(Description);
end;

function NewSymbol(Heap: TJsHeap; Description: TJsString): TJsSymbol;
begin
  Result := TJsSymbol.Create;
  Heap.Register(Result, ckSymbol);
  Result.Description := Description;
end;

function JsSymbolValue(Symbol: TJsSymbol): TJsValue;
begin
  Result := JsSymbolBase or QWord(PtrUInt(Symbol));
end;

function JsAsSymbol(Value: TJsValue): TJsSymbol;
begin
  Result := TJsSymbol(Pointer(PtrUInt(Value and JsPayloadMask)));
end;

end.
