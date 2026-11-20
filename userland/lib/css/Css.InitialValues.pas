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
  The initial value of every longhand, parsed once from the property
  table with the property's own grammar and shared from then on.
}
unit Css.InitialValues;

{$mode objfpc}
{$H+}

interface

uses
  Css.Values, Css.PropertyIds;

{ The parsed initial value (not referenced for the caller: AddRef to keep it). }
function InitialValue(Id: TCssPropertyId): TCssValue;

implementation

uses
  SysUtils, Css.Tokens, Css.Tokenizer, Css.Grammar, Css.PropertyTable, Css.Properties, Css.PropertyParsers;

var
  Values: array[TCssPropertyId] of TCssValue;

function InitialValue(Id: TCssPropertyId): TCssValue;
begin
  if (Values[Id] = nil) and IsLonghand(Id) then
  begin
    Values[Id] := ParseLonghandValue(Id, TCssTokenCursor.Create(TokenizeCss(PropertyTable[Id].Initial)));
    if Values[Id] = nil then
      raise Exception.Create('libcss: the initial value of ' + PropertyName(Id) + ' does not parse');
  end;
  Result := Values[Id];
end;

procedure ReleaseAll;
var
  Id: TCssPropertyId;
begin
  for Id := Low(TCssPropertyId) to High(TCssPropertyId) do
    ReleaseValue(Values[Id]);
end;

finalization
  ReleaseAll;
end.
