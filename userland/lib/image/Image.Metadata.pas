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
  An image's metadata: text keys with text values, in the order they
  were set; setting a key again replaces its value. Keys are compared
  without regard to case. Decoders use keys such as 'Comment',
  'HotspotX', 'HotspotY', 'Software' (MetadataKey* below).
}
unit Image.Metadata;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

const
  MetadataKeyComment = 'Comment';
  MetadataKeyHotspotX = 'HotspotX';
  MetadataKeyHotspotY = 'HotspotY';
  MetadataKeyColorSpace = 'ColorSpace';
  MetadataKeyDescription = 'Description';
  MetadataKeySoftware = 'Software';
  MetadataKeyDateTime = 'DateTime';
  { How many pages a file of several (a TIFF) has; the image is the
    first (Image.Tiff.Codec picks others). }
  MetadataKeyPageCount = 'PageCount';
  { How the pixels were compressed when a format has several ways (a
    WebP's 'lossy' or 'lossless'). }
  MetadataKeyCompression = 'Compression';

type
  TImageMetadataEntry = record
    Key: string;
    Value: string;
  end;

  TImageMetadata = class
  private
    FEntries: array of TImageMetadataEntry;
    function GetCount: LongInt;
    function GetKey(Index: LongInt): string;
    function GetValueAt(Index: LongInt): string;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    procedure Assign(Other: TImageMetadata);
    { The index of Key, or -1. }
    function IndexOf(const Key: string): LongInt;
    function Contains(const Key: string): Boolean;
    { The value of Key, or Default when there is none. }
    function GetValue(const Key: string; const Default: string = ''): string;
    procedure SetValue(const Key, Value: string);
    procedure Remove(const Key: string);
    property Count: LongInt read GetCount;
    property Keys[Index: LongInt]: string read GetKey;
    property Values[Index: LongInt]: string read GetValueAt;
  end;

implementation

constructor TImageMetadata.Create;
begin
  inherited Create;
  FEntries := nil;
end;

destructor TImageMetadata.Destroy;
begin
  FEntries := nil;
  inherited Destroy;
end;

procedure TImageMetadata.Clear;
begin
  FEntries := nil;
end;

procedure TImageMetadata.Assign(Other: TImageMetadata);
begin
  FEntries := Copy(Other.FEntries);
end;

function TImageMetadata.GetCount: LongInt;
begin
  Result := Length(FEntries);
end;

function TImageMetadata.GetKey(Index: LongInt): string;
begin
  Result := FEntries[Index].Key;
end;

function TImageMetadata.GetValueAt(Index: LongInt): string;
begin
  Result := FEntries[Index].Value;
end;

function TImageMetadata.IndexOf(const Key: string): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to Length(FEntries) - 1 do
    if SameText(FEntries[Index].Key, Key) then
      Exit(Index);
  Result := -1;
end;

function TImageMetadata.Contains(const Key: string): Boolean;
begin
  Result := IndexOf(Key) >= 0;
end;

function TImageMetadata.GetValue(const Key: string; const Default: string): string;
var
  Index: LongInt;
begin
  Index := IndexOf(Key);
  if Index < 0 then
    Result := Default
  else
    Result := FEntries[Index].Value;
end;

procedure TImageMetadata.SetValue(const Key, Value: string);
var
  Entry: TImageMetadataEntry;
  Index: LongInt;
begin
  Entry.Key := Key;
  Entry.Value := Value;
  Index := IndexOf(Key);
  if Index < 0 then
  begin
    Index := Length(FEntries);
    SetLength(FEntries, Index + 1);
  end;
  FEntries[Index] := Entry;
end;

procedure TImageMetadata.Remove(const Key: string);
var
  Index: LongInt;
begin
  Index := IndexOf(Key);
  if Index >= 0 then
    Delete(FEntries, Index, 1);
end;

end.
