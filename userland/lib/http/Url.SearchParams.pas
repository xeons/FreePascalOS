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
  URLSearchParams (URL Standard section 6.2): an ordered list of
  name-value pairs from a query, with append, delete (by name, or name
  and value), get, getAll, has, set (the first replaced, the others
  removed), sort (stable, by the names' UTF-16 code units) and
  serialization. Tied to a URL through Url.Accessors' query, the
  owner copies ToString back after a change (Changed is called).

  Plain Pascal (the RTL only), checked on the host by tools/HttpTest.
}
unit Url.SearchParams;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Url.FormEncoding;

type
  TUrlSearchParams = class;

  TSearchParamsChanged = procedure(Sender: TUrlSearchParams) of object;

  TUrlSearchParams = class
  private
    FList: TNameValueList;
    FOnChanged: TSearchParamsChanged;
    procedure Changed;
    function GetCount: Integer;
    function GetPair(Index: Integer): TNameValuePair;
  public
    { Init: a query with or without its "?". }
    constructor Create(const Init: string = '');
    { Replaces the list from a query, without telling the owner. }
    procedure Assign(const Query: string);
    procedure Append(const Name, Value: string);
    procedure Delete(const Name: string); overload;
    procedure Delete(const Name, Value: string); overload;
    { The first value of Name, False if there is none. }
    function Get(const Name: string; out Value: string): Boolean;
    function GetAll(const Name: string): TStringArray;
    function Has(const Name: string): Boolean; overload;
    function Has(const Name, Value: string): Boolean; overload;
    procedure SetValue(const Name, Value: string);
    procedure Sort;
    function ToString: string; override;
    property Count: Integer read GetCount;
    property Pairs[Index: Integer]: TNameValuePair read GetPair; default;
    property OnChanged: TSearchParamsChanged read FOnChanged write FOnChanged;
  end;

implementation

constructor TUrlSearchParams.Create(const Init: string);
begin
  inherited Create;
  Assign(Init);
end;

procedure TUrlSearchParams.Assign(const Query: string);
begin
  if (Query <> '') and (Query[1] = '?') then
    FList := ParseFormEncoded(Copy(Query, 2, MaxInt))
  else
    FList := ParseFormEncoded(Query);
end;

procedure TUrlSearchParams.Changed;
begin
  if Assigned(FOnChanged) then
    FOnChanged(Self);
end;

function TUrlSearchParams.GetCount: Integer;
begin
  Result := Length(FList);
end;

function TUrlSearchParams.GetPair(Index: Integer): TNameValuePair;
begin
  Result := FList[Index];
end;

procedure TUrlSearchParams.Append(const Name, Value: string);
begin
  SetLength(FList, Length(FList) + 1);
  FList[High(FList)].Name := Name;
  FList[High(FList)].Value := Value;
  Changed;
end;

procedure TUrlSearchParams.Delete(const Name: string);
var
  Index: Integer;
begin
  Index := High(FList);
  while Index >= 0 do
  begin
    if FList[Index].Name = Name then
      System.Delete(FList, Index, 1);
    Dec(Index);
  end;
  Changed;
end;

procedure TUrlSearchParams.Delete(const Name, Value: string);
var
  Index: Integer;
begin
  Index := High(FList);
  while Index >= 0 do
  begin
    if (FList[Index].Name = Name) and (FList[Index].Value = Value) then
      System.Delete(FList, Index, 1);
    Dec(Index);
  end;
  Changed;
end;

function TUrlSearchParams.Get(const Name: string; out Value: string): Boolean;
var
  Pair: TNameValuePair;
begin
  Value := '';
  for Pair in FList do
    if Pair.Name = Name then
    begin
      Value := Pair.Value;
      Exit(True);
    end;
  Result := False;
end;

function TUrlSearchParams.GetAll(const Name: string): TStringArray;
var
  Pair: TNameValuePair;
begin
  Result := nil;
  for Pair in FList do
    if Pair.Name = Name then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Pair.Value;
    end;
end;

function TUrlSearchParams.Has(const Name: string): Boolean;
var
  Pair: TNameValuePair;
begin
  for Pair in FList do
    if Pair.Name = Name then
      Exit(True);
  Result := False;
end;

function TUrlSearchParams.Has(const Name, Value: string): Boolean;
var
  Pair: TNameValuePair;
begin
  for Pair in FList do
    if (Pair.Name = Name) and (Pair.Value = Value) then
      Exit(True);
  Result := False;
end;

procedure TUrlSearchParams.SetValue(const Name, Value: string);
var
  Index: Integer;
  Found: Boolean;
begin
  Found := False;
  Index := 0;
  while Index < Length(FList) do
  begin
    if FList[Index].Name = Name then
    begin
      if Found then
      begin
        System.Delete(FList, Index, 1);
        Continue;
      end;
      FList[Index].Value := Value;
      Found := True;
    end;
    Inc(Index);
  end;
  if Found then
    Changed
  else
    Append(Name, Value);
end;

{ By UTF-16 code units, as the standard sorts. }
function NameGoesBefore(const First, Second: string): Boolean;
var
  FirstUnits, SecondUnits: UnicodeString;
begin
  FirstUnits := UTF8Decode(First);
  SecondUnits := UTF8Decode(Second);
  Result := FirstUnits < SecondUnits;
end;

procedure TUrlSearchParams.Sort;
var
  Index, Inner: Integer;
  Moving: TNameValuePair;
begin
  { Insertion sort: stable, and the lists are short. }
  for Index := 1 to High(FList) do
  begin
    Moving := FList[Index];
    Inner := Index - 1;
    while (Inner >= 0) and NameGoesBefore(Moving.Name, FList[Inner].Name) do
    begin
      FList[Inner + 1] := FList[Inner];
      Dec(Inner);
    end;
    FList[Inner + 1] := Moving;
  end;
  Changed;
end;

function TUrlSearchParams.ToString: string;
begin
  Result := SerializeFormEncoded(FList);
end;

end.
