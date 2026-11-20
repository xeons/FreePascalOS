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
  Extensible priorities (RFC 9218): an urgency from 0 (most urgent) to
  7, 3 by default, and whether a response can be used in pieces
  (incremental, off by default). They travel as the Priority field, a
  Structured Fields dictionary ("u=1, i"), in a request, and later in
  HTTP/2 PRIORITY_UPDATE frames (and HTTP/3's) to change them. The
  same for every protocol, so it is here and not in the HTTP/2 code.

  Plain Pascal (the RTL only), checked on the host by tools/HttpTest.
}
unit Http.Priorities;

{$mode objfpc}
{$H+}

interface

const
  DefaultUrgency = 3;
  LowestUrgency = 7;

type
  THttpPriority = record
    Urgency: Byte;
    Incremental: Boolean;
  end;

function DefaultPriority: THttpPriority;
function MakePriority(Urgency: Byte; Incremental: Boolean): THttpPriority;
function PriorityIsDefault(constref Priority: THttpPriority): Boolean;
{ The Priority field's value ('' for the default, which is not sent). }
function FormatPriorityField(constref Priority: THttpPriority): string;
{ Unknown members and bad values are ignored (RFC 9218 section 4). }
function ParsePriorityField(const Value: string): THttpPriority;

implementation

uses
  SysUtils;

function DefaultPriority: THttpPriority;
begin
  Result.Urgency := DefaultUrgency;
  Result.Incremental := False;
end;

function MakePriority(Urgency: Byte; Incremental: Boolean): THttpPriority;
begin
  if Urgency > LowestUrgency then
    Urgency := LowestUrgency;
  Result.Urgency := Urgency;
  Result.Incremental := Incremental;
end;

function PriorityIsDefault(constref Priority: THttpPriority): Boolean;
begin
  Result := (Priority.Urgency = DefaultUrgency) and not Priority.Incremental;
end;

function FormatPriorityField(constref Priority: THttpPriority): string;
begin
  Result := '';
  if Priority.Urgency <> DefaultUrgency then
    Result := 'u=' + IntToStr(Priority.Urgency);
  if Priority.Incremental then
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + 'i';
  end;
end;

function ParsePriorityField(const Value: string): THttpPriority;
var
  Member, Key, Item: string;
  Equals, Number: Integer;
begin
  Result := DefaultPriority;
  for Member in Value.Split([',']) do
  begin
    Equals := Pos('=', Member);
    if Equals > 0 then
    begin
      Key := Trim(Copy(Member, 1, Equals - 1));
      Item := Trim(Copy(Member, Equals + 1, MaxInt));
    end
    else
    begin
      Key := Trim(Member);
      Item := '?1';
    end;
    { Parameters of a member (";a=b") are ignored. }
    if Pos(';', Item) > 0 then
      Item := Trim(Copy(Item, 1, Pos(';', Item) - 1));
    if Pos(';', Key) > 0 then
    begin
      Key := Trim(Copy(Key, 1, Pos(';', Key) - 1));
      Item := '?1';
    end;
    if Key = 'u' then
    begin
      if TryStrToInt(Item, Number) and (Number >= 0) and (Number <= LowestUrgency) and (Pos('.', Item) = 0) then
        Result.Urgency := Number;
    end
    else if Key = 'i' then
    begin
      if Item = '?1' then
        Result.Incremental := True
      else if Item = '?0' then
        Result.Incremental := False;
    end;
  end;
end;

end.
