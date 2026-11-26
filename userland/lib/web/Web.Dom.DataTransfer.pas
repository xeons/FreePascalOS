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
  DataTransfer's string data (HTML Standard 6.11.3) and ClipboardEvent
  (Clipboard API and events 4): a drag data store of formats and
  strings in the order they were set, its mode (read/write while a copy
  or cut event is dispatched, read-only for paste, protected otherwise),
  getData, setData and clearData with their format rules ("text" is
  text/plain, "url" is text/uri-list of which getData gives the first
  URL), and the clipboard event carrying one.
}
unit Web.Dom.DataTransfer;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Web.Dom.Events;

type
  TDataTransferMode = (DataTransferReadWrite, DataTransferReadOnly, DataTransferProtected);

  TDataTransfer = class
  private
    FFormats: array of string;
    FValues: array of string;
    function IndexOf(const Format: string): Integer;
  public
    Mode: TDataTransferMode;
    DropEffect: string;
    EffectAllowed: string;
    constructor Create;
    function GetData(const Format: string): string;
    procedure SetData(const Format, Data: string);
    { All formats when Format is ''. }
    procedure ClearData(const Format: string);
    function Types: TStringArray;
    function HasData: Boolean;
  end;

  TClipboardEvent = class(TEvent)
  public
    { The event's data (nil: none); freed with the event when OwnsData. }
    ClipboardData: TDataTransfer;
    OwnsData: Boolean;
    destructor Destroy; override;
  end;

{ The format a script names: lower case, "text" and "url" as the
  standard maps them. }
function NormalizeDataFormat(const Format: string): string;

implementation

function NormalizeDataFormat(const Format: string): string;
var
  Index: Integer;
begin
  Result := Format;
  for Index := 1 to Length(Result) do
    if Result[Index] in ['A'..'Z'] then
      Result[Index] := Chr(Ord(Result[Index]) + 32);
  if Result = 'text' then
    Result := 'text/plain'
  else if Result = 'url' then
    Result := 'text/uri-list';
end;

constructor TDataTransfer.Create;
begin
  inherited Create;
  DropEffect := 'none';
  EffectAllowed := 'none';
end;

function TDataTransfer.IndexOf(const Format: string): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(FFormats) do
    if FFormats[Index] = Format then
      Exit(Index);
  Result := -1;
end;

{ The first URL of a text/uri-list (lines starting with # are comments). }
function FirstUrl(const List: string): string;
var
  Lines: TStringArray;
  Index: Integer;
  Line: string;
begin
  Result := '';
  Lines := StringReplace(List, #13#10, #10, [rfReplaceAll]).Split([#10]);
  for Index := 0 to High(Lines) do
  begin
    Line := Lines[Index];
    if (Line <> '') and (Line[1] <> '#') then
      Exit(Line);
  end;
end;

function TDataTransfer.GetData(const Format: string): string;
var
  Index: Integer;
  Wanted: string;
begin
  Result := '';
  if Mode = DataTransferProtected then
    Exit;
  Wanted := NormalizeDataFormat(Format);
  Index := IndexOf(Wanted);
  if Index < 0 then
    Exit;
  Result := FValues[Index];
  if LowerCase(Format) = 'url' then
    Result := FirstUrl(Result);
end;

procedure TDataTransfer.SetData(const Format, Data: string);
var
  Index: Integer;
  Wanted: string;
begin
  if Mode <> DataTransferReadWrite then
    Exit;
  Wanted := NormalizeDataFormat(Format);
  Index := IndexOf(Wanted);
  if Index >= 0 then
  begin
    { Set again: it moves to the end. }
    Delete(FFormats, Index, 1);
    Delete(FValues, Index, 1);
  end;
  SetLength(FFormats, Length(FFormats) + 1);
  SetLength(FValues, Length(FValues) + 1);
  FFormats[High(FFormats)] := Wanted;
  FValues[High(FValues)] := Data;
end;

procedure TDataTransfer.ClearData(const Format: string);
var
  Index: Integer;
begin
  if Mode <> DataTransferReadWrite then
    Exit;
  if Format = '' then
  begin
    FFormats := nil;
    FValues := nil;
    Exit;
  end;
  Index := IndexOf(NormalizeDataFormat(Format));
  if Index >= 0 then
  begin
    Delete(FFormats, Index, 1);
    Delete(FValues, Index, 1);
  end;
end;

function TDataTransfer.Types: TStringArray;
begin
  Result := Copy(FFormats);
end;

function TDataTransfer.HasData: Boolean;
begin
  Result := Length(FFormats) > 0;
end;

destructor TClipboardEvent.Destroy;
begin
  if OwnsData then
    ClipboardData.Free;
  inherited Destroy;
end;

end.
