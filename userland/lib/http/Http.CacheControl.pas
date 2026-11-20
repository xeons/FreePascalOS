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
  Cache-Control (RFC 9111 section 5.2), request and response directives
  read into one record: no-store, no-cache, private, public, max-age,
  s-maxage, must-revalidate, immutable, stale-while-revalidate,
  max-stale, min-fresh and only-if-cached; Pragma: no-cache counts as
  no-cache when Cache-Control is absent. Delta-seconds larger than
  2^31 are taken as 2^31 (section 1.2.2).

  Plain Pascal (the RTL only), checked on the host by tools/HttpTest.
}
unit Http.CacheControl;

{$mode objfpc}
{$H+}

interface

uses
  Http.HeaderFields;

const
  DeltaSecondsCeiling = 2147483648;

type
  TCacheDirectives = record
    NoStore: Boolean;
    NoCache: Boolean;
    PrivateResponse: Boolean;
    PublicResponse: Boolean;
    MustRevalidate: Boolean;
    Immutable: Boolean;
    OnlyIfCached: Boolean;
    { -1 when absent. }
    MaxAge: Int64;
    SharedMaxAge: Int64;
    StaleWhileRevalidate: Int64;
    MinFresh: Int64;
    { -1 when absent; DeltaSecondsCeiling for "max-stale" without a value. }
    MaxStale: Int64;
  end;

function ParseCacheControl(const Value: string): TCacheDirectives;
{ Cache-Control (and Pragma) of a field list. }
function CacheDirectivesOf(constref Fields: THttpHeaderFieldArray): TCacheDirectives;

implementation

uses
  SysUtils,
  Http.FieldValues;

function DeltaSeconds(constref Parameter: THttpParameter): Int64;
var
  Value: Int64;
  Character: Char;
begin
  Result := -1;
  if not Parameter.HasValue or (Parameter.Value = '') then
    Exit;
  Value := 0;
  for Character in Parameter.Value do
  begin
    if not (Character in ['0'..'9']) then
      Exit;
    if Value < DeltaSecondsCeiling then
      Value := Value * 10 + Ord(Character) - Ord('0');
  end;
  if Value > DeltaSecondsCeiling then
    Value := DeltaSecondsCeiling;
  Result := Value;
end;

function ParseCacheControl(const Value: string): TCacheDirectives;
var
  Parameter: THttpParameter;
begin
  Result := Default(TCacheDirectives);
  Result.MaxAge := -1;
  Result.SharedMaxAge := -1;
  Result.StaleWhileRevalidate := -1;
  Result.MinFresh := -1;
  Result.MaxStale := -1;
  for Parameter in ParseParameters(Value, ',') do
    if Parameter.Name = 'no-store' then
      Result.NoStore := True
    else if Parameter.Name = 'no-cache' then
      Result.NoCache := True
    else if Parameter.Name = 'private' then
      Result.PrivateResponse := True
    else if Parameter.Name = 'public' then
      Result.PublicResponse := True
    else if Parameter.Name = 'must-revalidate' then
      Result.MustRevalidate := True
    else if Parameter.Name = 'immutable' then
      Result.Immutable := True
    else if Parameter.Name = 'only-if-cached' then
      Result.OnlyIfCached := True
    else if Parameter.Name = 'max-age' then
      Result.MaxAge := DeltaSeconds(Parameter)
    else if Parameter.Name = 's-maxage' then
      Result.SharedMaxAge := DeltaSeconds(Parameter)
    else if Parameter.Name = 'stale-while-revalidate' then
      Result.StaleWhileRevalidate := DeltaSeconds(Parameter)
    else if Parameter.Name = 'min-fresh' then
      Result.MinFresh := DeltaSeconds(Parameter)
    else if Parameter.Name = 'max-stale' then
    begin
      if Parameter.HasValue then
        Result.MaxStale := DeltaSeconds(Parameter)
      else
        Result.MaxStale := DeltaSecondsCeiling;
    end;
end;

function CacheDirectivesOf(constref Fields: THttpHeaderFieldArray): TCacheDirectives;
var
  Field: THttpHeaderField;
  Combined: string;
  HasCacheControl: Boolean;
begin
  Combined := '';
  HasCacheControl := False;
  for Field in Fields do
    if Field.Name = 'cache-control' then
    begin
      HasCacheControl := True;
      if Combined <> '' then
        Combined := Combined + ', ';
      Combined := Combined + Field.Value;
    end;
  Result := ParseCacheControl(Combined);
  if not HasCacheControl and ListHasToken(FieldsValue(Fields, 'pragma'), 'no-cache') then
    Result.NoCache := True;
end;

end.
